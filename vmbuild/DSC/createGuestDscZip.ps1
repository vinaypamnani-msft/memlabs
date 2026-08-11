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
    Write-Host "Checking Modules.."
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
        'FailoverClusterDsc',
        'AccessControlDsc',
        'UpdateServicesDsc',
        'LanguageDsc',
        'GroupPolicyDsc',
        'CertificateDsc'
    )

    # Single Get-Module call instead of 15 individual lookups
    $allAvailable = @(Get-Module -ListAvailable).Name | Sort-Object -Unique
    $missing = @()
    foreach ($module in $modules) {
        if ($allAvailable -contains $module) {
            if ($force) {
                Write-Host "Module exists: $module. Updating..."
                Update-Module $module -Force
            }
            else {
                Write-Host "Module exists: $module "
            }
        }
        else {
            $missing += $module
        }
    }

    foreach ($module in $missing) {
        Write-Host "Installing Module: $module "
        Install-Module $module -Force
    }

    # Install TemplateHelpDSC module on this machine (needed before test compilation)
    Write-Host "Installing TemplateHelpDSC on this machine.."
    Copy-Item .\TemplateHelpDSC "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force

    # Start ZIP creation as a background job — runs in parallel with everything below.
    # Nothing else depends on DSC.zip; we wait for it at the very end.
    Write-Host "Starting DSC.zip creation in background..."
    $dscDir = $PSScriptRoot
    $zipJob = Start-Job -ScriptBlock {
        param($dir)
        Set-Location $dir
        Write-Output "Creating DSC.zip..."
        Publish-AzVMDscConfiguration .\DummyConfig.ps1 -OutputArchivePath .\DSC.zip -Force -Confirm:$false
        Write-Output "Adding TemplateHelpDSC to DSC.zip..."
        Compress-Archive -Path .\TemplateHelpDSC -Update -DestinationPath .\DSC.zip
        Write-Output "DSC.zip creation complete."
    } -ArgumentList $dscDir

    # Tell common to re-init (runs in parallel with ZIP creation above)
    if ($Common.Initialized) {
        $Common.Initialized = $false
    }
    # Not -InJob: this is host-side tooling and needs Test-Configuration, which Common.ps1
    # only loads outside a job. StartupProfile Fast already skips the expensive host probes.
    . "..\Common.ps1" -StartupProfile Fast
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
    else {
        # Non-interactive: create a dummy credential for test compilation (never used for auth)
        $ss = New-Object System.Security.SecureString
        $ss.AppendChar('x')
        $adminCreds = New-Object System.Management.Automation.PSCredential('admin', $ss)
    }

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
            # Delete the zip so the next run rebuilds it
            $dscZipPath = Join-Path $PSScriptRoot "DSC.zip"
            if (Test-Path $dscZipPath) {
                Remove-Item $dscZipPath -Force -ErrorAction SilentlyContinue
                Write-Host "Deleted DSC.zip so next run will rebuild." -ForegroundColor Yellow
            }
            throw "PS5.1 parse check failed. Fix the above files before deploying to guest VMs."
        }
        else {
            Write-Host "All $($parseResult.CheckedCount) guest scripts passed PS5.1 parse check." -ForegroundColor Green
        }
    }

    # Wait for background ZIP creation job to finish.
    if ($zipJob) {
        Write-Host "`nWaiting for DSC.zip background job..."
        $zipOutput = $zipJob | Receive-Job -Wait -AutoRemoveJob
        $zipJob = $null
        $zipOutput | ForEach-Object { Write-Host "  $_" }
        Write-Host "DSC.zip ready."
    }

    # Auto-bump MemLabsVersion now that the DSC build succeeded.
    # Format: YYMMDD.n — if today's date matches the current prefix, increment n; otherwise reset to .0
    $commonPs1Path = Join-Path $PSScriptRoot "..\Common.ps1"
    $commonPs1Path = (Resolve-Path $commonPs1Path).Path
    $todayPrefix = (Get-Date).ToString("yyMMdd")
    $oldVersion = $Common.MemLabsVersion

    if ($oldVersion -match "^$todayPrefix\.(\d+)$") {
        $newVersion = "$todayPrefix.$([int]$Matches[1] + 1)"
    }
    else {
        $newVersion = "$todayPrefix.0"
    }

    $content = Get-Content $commonPs1Path -Raw
    # Update both MemLabsVersion and LatestHotfixVersion
    $content = $content -replace "MemLabsVersion\s*=\s*`"$([regex]::Escape($oldVersion))`"", "MemLabsVersion              = `"$newVersion`""
    $content = $content -replace "LatestHotfixVersion\s*=\s*`"$([regex]::Escape($oldVersion))`"", "LatestHotfixVersion         = `"$newVersion`""
    # Write with UTF-8 BOM — PS5.1 needs the BOM to parse non-ASCII characters
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($commonPs1Path, $content, $utf8Bom)
    Write-Host "MemLabsVersion updated: $oldVersion -> $newVersion" -ForegroundColor Cyan
}
finally {
    if ($zipJob -and $zipJob.State -eq 'Running') {
        $zipJob | Stop-Job -PassThru | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    if ($parseCheckJob -and $parseCheckJob.State -eq 'Running') {
        $parseCheckJob | Stop-Job -PassThru | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    # If we terminated with an error, delete DSC.zip so the next run rebuilds
    if (-not $?) {
        $dscZipPath = Join-Path $PSScriptRoot "DSC.zip"
        if (Test-Path $dscZipPath) {
            Remove-Item $dscZipPath -Force -ErrorAction SilentlyContinue
            Write-Host "Deleted DSC.zip due to build failure." -ForegroundColor Yellow
        }
    }
    $parentDir = Split-Path -Path $PSScriptRoot -Parent
    Set-Location $parentDir
}