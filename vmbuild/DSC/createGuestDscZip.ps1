param(
    $vmName,
    $configPath,
    [System.Management.Automation.PSCredential]$creds,
    [switch]$force
)

if (-not $vmName) {
    Write-Host "Specify VMName."
    return
}

if (-not $configPath) {
    Write-Host "Specify configPath."
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

Write-Host "Importing Modules.."
$modules = @(
    'Az.Compute',
    'ActiveDirectoryDsc',
    'xDscDiagnostics',
    'ComputerManagementDsc',
    'DnsServerDsc',
    'SqlServerDsc',
    'xDhcpServer',
    'NetworkingDsc'
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

# Create dummy file so config doesn't fail
$result = Test-Configuration -FilePath $ConfigPath
$ThisVM = $result.DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $vmName }
$result.DeployConfig.parameters.ThisMachineName = $ThisVM.vmName
$result.DeployConfig.parameters.ThisMachineRole = $ThisVM.role
$role  = $ThisVM.role

# Dump config to file, for debugging
#$result.DeployConfig | ConvertTo-Json | Set-Clipboard
$filePath = "C:\temp\deployConfig.json"
$result.DeployConfig | ConvertTo-Json -Depth 3 | Out-File $filePath -Force

# DSC folder name
$dscFolder = "configmgr"

# Create local compressed file and inject appropriate appropriate TemplateHelpDSC
Write-Host "Creating DSC.zip for $dscFolder.."
Publish-AzVMDscConfiguration .\DummyConfig.ps1 -OutputArchivePath .\$dscFolder\DSC.zip -Force
Write-Host "Adding $dscFolder TemplateHelpDSC to DSC.ZIP.."
Compress-Archive -Path .\$dscFolder\TemplateHelpDSC -Update -DestinationPath .\$dscFolder\DSC.zip

# install templatehelpdsc module on this machine
Write-Host "Installing $dscFolder TemlateHelpDSC on this machine.."
Copy-Item .\$dscFolder\TemplateHelpDSC "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force

# Create test config, for testing if the config definition is good.
$role = if ($role -eq "DPMP") { "DomainMember" } else { $role }
Write-Host "Creating a test config for $role in C:\Temp"

if ($creds) { $adminCreds = $creds }
else { $adminCreds = Get-Credential }
. ".\$dscFolder\$($role)Configuration.ps1"

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

& "$($role)Configuration" -ConfigFilePath $filePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath "C:\Temp\$($role)-Config"