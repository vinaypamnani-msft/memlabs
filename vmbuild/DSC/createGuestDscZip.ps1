# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
#CreateGuestDscZip.ps1
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
        'UpdateServicesDsc',
        'LanguageDsc',
        'GroupPolicyDsc',
        'CertificateDsc'
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
    . "..\Common.ps1" -InJob:$true
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

    # PS5.1 parse-check all phase scripts and TemplateHelpDSC module.
    # Guest VMs run PS 5.1 which reads files without a UTF-8 BOM as Windows-1252.
    # Non-ASCII characters (em-dashes, smart quotes, etc.) in string literals
    # silently break parsing, causing dot-sourced scripts to fail with no output.
    #
    # Run as a background job so the test config compilation can proceed in parallel.
    # Results are checked at the end after the test config finishes.
    Write-Host "`nStarting PS5.1 parse-check in background..."
    $parseCheckDirs = @((Resolve-Path '.\phases').Path, (Resolve-Path '.\TemplateHelpDSC').Path)
    $parseCheckJob = Start-Job -ScriptBlock {
        param($dirs)
        $failures = @()
        foreach ($dir in $dirs) {
            foreach ($f in Get-ChildItem -Path $dir -Include '*.ps1', '*.psm1' -Recurse) {
                $t = $null; $e = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
                if ($e.Count -gt 0) {
                    $failures += [PSCustomObject]@{
                        File   = $f.FullName
                        Errors = ($e | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
                    }
                }
            }
        }
        $checked = ($dirs | ForEach-Object { Get-ChildItem -Path $_ -Include '*.ps1', '*.psm1' -Recurse }).Count
        [PSCustomObject]@{ Failures = $failures; CheckedCount = $checked }
    } -ArgumentList (,$parseCheckDirs)

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
    Add-CmdHistory "$($dscRole) -DeployConfigPath $filePath -AdminCreds (Get-Credential) -ConfigurationData $cd -OutputPath `"C:\Temp\$($role)-Config`""

    # Wait for the background parse-check job to finish and report results.
    if ($parseCheckJob) {
        Write-Host "`nWaiting for PS5.1 parse-check to complete..."
        $parseResult = $parseCheckJob | Receive-Job -Wait -AutoRemoveJob
        $parseFailures = $parseResult.Failures
        if ($parseFailures.Count -gt 0) {
            Write-Host ""
            Write-Host "ERROR: $($parseFailures.Count) file(s) failed PS5.1 parse check!" -ForegroundColor Red
            Write-Host "These files will silently fail when dot-sourced on guest VMs." -ForegroundColor Red
            Write-Host "Common cause: non-ASCII characters (em-dash, smart quotes) in files without UTF-8 BOM." -ForegroundColor Red
            Write-Host ""
            foreach ($f in $parseFailures) {
                Write-Host "  $($f.File)" -ForegroundColor Yellow
                Write-Host "    $($f.Errors)" -ForegroundColor DarkYellow
            }
            Write-Host ""
            throw "PS5.1 parse check failed. Fix the above files before deploying to guest VMs."
        }
        else {
            Write-Host "All $($parseResult.CheckedCount) guest scripts passed PS5.1 parse check." -ForegroundColor Green
        }
    }
}
finally {
    if ($parseCheckJob -and $parseCheckJob.State -eq 'Running') {
        $parseCheckJob | Stop-Job -PassThru | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    $parentDir = Split-Path -Path $PSScriptRoot -Parent
    Set-Location $parentDir
}