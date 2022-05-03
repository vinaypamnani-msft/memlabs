param(
    $configName,
    $vmName,
    [switch]$force
)

if (-not $configName) {
    Write-Host "Using test config: CSTest1-A-CSPS.json, and test VM Name: CT1-DC1"
    $configName = "CSTest1-A-CSPS.json"
    $vmName = "CT1-DC1"
}

if (-not $vmName) {
    Write-Host "Specify configName and vmName."
    return
}

# Prepare DSC ZIP files
Set-Location $PSScriptRoot

#####################
### Install modules
#####################
# Az.Compute module, install once to use Publish-AzVMDscConfiguration
# Install-Module Az.Compute -Force

# Modules used by VM Guests, include all so the ZIP contains all required modules to make it easier to move them to guest VMs.

try {
    Write-Host "Importing Modules.."
    $modules = @(
        'Az.Compute',
        'PSDesiredStateConfiguration',
        'ActiveDirectoryDsc',
        'xDscDiagnostics',
        'ComputerManagementDsc',
        'DnsServerDsc',
        'SqlServerDsc',
        'xDhcpServer',
        'NetworkingDsc',
        'xFailOverCluster',
        'AccessControlDsc',
        'UpdateServicesDsc'
    )

    foreach ($module in $modules) {
        if (Get-Module -ListAvailable -Name $module) {
            if ($force) {
                Write-Host "Module exists: $module. Updating..."
                Update-Module $module -Force
            }
            else {
                Write-Host "Module exists: $module "
            }
        }
        else {
            Write-Host "Import Module: $module "
            Install-Module $module -Force
        }
    }

    # Tell common to re-init
    if ($Common.Initialized) {
        $Common.Initialized = $false
    }
    . "..\Common.ps1"
    $ConfirmPreference = $false

    # Create dummy file so config doesn't fail
    $userConfig = Get-UserConfiguration -Configuration $configName
    $result = Test-Configuration -InputObject $userConfig.Config
    $ThisVM = $result.DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $vmName }
    $deployConfigCopy = $result.DeployConfig

    # Dump config to file, for debugging
    #$result.DeployConfig | ConvertTo-Json | Set-Clipboard
    $filePath = "C:\temp\deployConfig.json"
    $deployConfigCopy.parameters.ThisMachineName = $vmName
    $deployConfigCopy | ConvertTo-Json -Depth 5 | Out-File $filePath -Force

    # Create local compressed file and inject appropriate appropriate TemplateHelpDSC
    Write-Host "Creating DSC.zip..."
    Publish-AzVMDscConfiguration .\DummyConfig.ps1 -OutputArchivePath .\DSC.zip -Force -Confirm:$false
    Write-Host "Adding TemplateHelpDSC to DSC.ZIP.."
    Compress-Archive -Path .\TemplateHelpDSC -Update -DestinationPath .\DSC.zip

    # install templatehelpdsc module on this machine
    Write-Host "Installing TemplateHelpDSC on this machine.."
    Copy-Item .\TemplateHelpDSC "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force

    # Create test config, for testing if the config definition is good.
    $role = $ThisVM.role
    # Set current role
    $dscRole = "Phase2"
    switch (($role)) {
        "DC" { $dscRole += "DC" }
        "BDC" { $dscRole += "BDC" }
        "WorkgroupMember" { $dscRole += "WorkgroupMember" }
        "AADClient" { $dscRole += "WorkgroupMember" }
        "InternetClient" { $dscRole += "WorkgroupMember" }
        default { $dscRole += "DomainMember" }
    }
    Write-Host "Creating a test config for $role in C:\Temp"

    if ($Common.LocalAdmin) { $adminCreds = $Common.LocalAdmin }
    else { $adminCreds = Get-Credential }

    $dscFolder = "phases"
    . ".\$dscFolder\$($dscRole).ps1"

    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName                    = 'LOCALHOST'
                PSDscAllowPlainTextPassword = $true
                PSDscAllowDomainUser        = $true
            }
        )
    }
write-host "Running ""$($dscRole)"" -DeployConfigPath $filePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath ""C:\Temp\$($role)-Config"" "
    & "$($dscRole)" -DeployConfigPath $filePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath "C:\Temp\$($role)-Config" | out-host
}
finally {
    $parentDir = Split-Path -Path $PSScriptRoot -Parent
    Set-Location $parentDir
}