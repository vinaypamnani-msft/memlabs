# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
#CreateGuestDscZip.ps1
param(
    $configName,
    $vmName,
    [switch]$force,
    # Exercise the real build -- zip, config compile, parse check -- against a scratch
    # folder instead of the repo. Nothing under vmbuild is written, no module is installed,
    # and MemLabsVersion is not bumped.
    [switch]$DryRun,
    # Mark this host as the DSC build server and exit.
    [switch]$DesignateBuildServer
)

# Self-installing prerequisite helpers (PSGallery bootstrap) plus the build-server gate.
# Dot-sourced before Common.ps1 because the module install below has to work on a lab host
# that has never used PSGallery.
$prereqScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'common\Common.Prereqs.ps1'
if (-not (Test-Path $prereqScript -PathType Leaf)) {
    throw "Cannot find $prereqScript. Run this from a full memlabs clone."
}
. $prereqScript

if ($DesignateBuildServer) {
    Set-MemLabsBuildServer
    return
}

# -DryRun writes only to a scratch folder, so it stays allowed everywhere.
if (-not $DryRun -and -not (Test-MemLabsBuildServer)) {
    Deny-MemLabsNonBuildServer -ScriptName 'createGuestDscZip.ps1'
    return
}

$dryRunRoot = $null
$dryRunCompleted = $false
$dryRunHyperV = $false
$dryRunHyperVWhy = 'Hyper-V cmdlets are not installed'
if ($DryRun) {
    $dryRunRoot = Join-Path $env:TEMP ("memlabs-dsczip-test-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $dryRunRoot -Force | Out-Null
    Write-Host "DRYRUN: writing everything to $dryRunRoot" -ForegroundColor Yellow
    Write-Host "DRYRUN: repo DSC.zip, Common.ps1 and installed modules will not be touched." -ForegroundColor Yellow

    # Probed up front so a box without Hyper-V reports itself as the wrong machine rather
    # than looking like a script fault when the first VM query fails.
    if (Get-Command Get-VMHost -ErrorAction SilentlyContinue) {
        try { $null = Get-VMHost -ErrorAction Stop; $dryRunHyperV = $true }
        catch { $dryRunHyperVWhy = $_.Exception.Message }
    }
    $dryRunAz = [bool](Get-Command Publish-AzVMDscConfiguration -ErrorAction SilentlyContinue)
    Write-Host ("DRYRUN: Hyper-V usable : {0}" -f $(if ($dryRunHyperV) { 'yes' } else { "NO - $dryRunHyperVWhy" })) -ForegroundColor Yellow
    Write-Host ("DRYRUN: Az.Compute     : {0}" -f $(if ($dryRunAz) { 'yes' } else { 'NO - the zip step cannot run' })) -ForegroundColor Yellow
    if (-not $dryRunHyperV) {
        Write-Host "DRYRUN: without Hyper-V this validates the config path and then stops at the first VM query." -ForegroundColor Yellow
    }
}

# Defined before the try so the finally block can never fall back to the repo copy.
$zipTarget = if ($DryRun) { Join-Path $dryRunRoot 'DSC.zip' } else { Join-Path $PSScriptRoot 'DSC.zip' }

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

# Install-Module -Scope AllUsers and the TemplateHelpDSC copy into Program Files both need it.
if (-not $DryRun -and -not (Test-MemLabsElevated)) {
    Write-Host
    Write-Host "This script must run as Administrator (it installs modules machine-wide)." -ForegroundColor Red
    Write-Host
    return
}

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

    if ($DryRun) {
        $allAvailable = @(Get-Module -ListAvailable).Name | Sort-Object -Unique
        foreach ($module in $modules) {
            if ($allAvailable -contains $module) { Write-Host "Module exists: $module " }
            else { Write-Host "DRYRUN: would install module: $module" -ForegroundColor Yellow }
        }
    }
    else {
        $moduleResult = Install-MemLabsModule -Name $modules -Update:$force
        foreach ($module in $moduleResult.Present) { Write-Host "Module exists: $module " }
        if ($moduleResult.Failed.Count -gt 0) {
            # A missing module surfaces much later as an unreadable Publish-AzVMDscConfiguration
            # or DSC compile error, so stop here and name the modules.
            throw "These modules could not be installed: $($moduleResult.Failed -join ', '). Install-Module, a package-cache purge and a direct PSGallery nupkg download all failed - see the warnings above for which one failed and why."
        }
    }

    # Install TemplateHelpDSC module on this machine (needed before test compilation)
    if ($DryRun) {
        Write-Host "DRYRUN: skipping TemplateHelpDSC install into Program Files (machine-wide)." -ForegroundColor Yellow
    }
    else {
        Write-Host "Installing TemplateHelpDSC on this machine.."
        Copy-Item .\TemplateHelpDSC "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force
    }

    # Start ZIP creation as a background job - runs in parallel with everything below.
    # Nothing else depends on DSC.zip; we wait for it at the very end.
    Write-Host "Starting DSC.zip creation in background ($zipTarget)..."
    $dscDir = $PSScriptRoot
    $zipJob = Start-Job -ScriptBlock {
        param($dir, $target)
        Set-Location $dir
        Write-Output "Creating DSC.zip at $target..."
        Publish-AzVMDscConfiguration .\DummyConfig.ps1 -OutputArchivePath $target -Force -Confirm:$false
        Write-Output "Adding TemplateHelpDSC to DSC.zip..."
        Compress-Archive -Path .\TemplateHelpDSC -Update -DestinationPath $target
        Write-Output "DSC.zip creation complete."
    } -ArgumentList $dscDir, $zipTarget

    # Tell common to re-init (runs in parallel with ZIP creation above)
    if ($Common.Initialized) {
        $Common.Initialized = $false
    }
    # Not -InJob: this is host-side tooling and needs Test-Configuration, which Common.ps1
    # only loads outside a job. StartupProfile Fast already skips the expensive host probes.
    . "..\Common.ps1" -StartupProfile Fast
    # ConfirmImpact enum, not a bool -- $false threw a MetadataError on every run.
    $ConfirmPreference = 'None'

    # Create dummy file so config doesn't fail
    $userConfig = Get-UserConfiguration -Configuration $configName
    $result = Test-Configuration -InputObject $userConfig.Config
    $ThisVM = $result.DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $vmName }
    $deployConfigCopy = $result.DeployConfig

    # Dump config to file, for debugging
    #$result.DeployConfig | ConvertTo-Json | Set-Clipboard
    $filePath = if ($DryRun) { Join-Path $dryRunRoot 'deployConfig.json' } else { "C:\temp\deployConfig.json" }
    # Out-File -Force does not create missing directories, and a new lab host has no C:\temp.
    $filePathDir = Split-Path $filePath -Parent
    if (-not (Test-Path $filePathDir -PathType Container)) {
        New-Item -ItemType Directory -Path $filePathDir -Force | Out-Null
    }
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
    Write-Host "Creating a test config for $role"

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
    $configOutPath = if ($DryRun) { Join-Path $dryRunRoot "$($role)-Config" } else { "C:\Temp\$($role)-Config" }
    write-host "Running ""$($dscRole)"" -DeployConfigPath $filePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath ""$configOutPath"" "
    & "$($dscRole)" -DeployConfigPath $filePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath $configOutPath | out-host
    if (-not $DryRun) {
        Add-CmdHistory "$($dscRole) -DeployConfigPath $filePath -AdminCreds (Get-Credential) -ConfigurationData $cd -OutputPath `"$configOutPath`""
    }

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
            # Delete the zip so the next run rebuilds it. $zipTarget, not the repo copy --
            # a dry run must never remove the real DSC.zip.
            if (Test-Path $zipTarget) {
                Remove-Item $zipTarget -Force -ErrorAction SilentlyContinue
                Write-Host "Deleted $zipTarget so next run will rebuild." -ForegroundColor Yellow
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
    # Format: YYMMDD.n - if today's date matches the current prefix, increment n; otherwise reset to .0
    if ($DryRun) {
        Write-Host ""
        Write-Host "DRYRUN COMPLETE - the real build ran, nothing in the repo was touched." -ForegroundColor Green
        Write-Host "  scratch folder : $dryRunRoot" -ForegroundColor Green
        Write-Host "  MemLabsVersion : left at $($Common.MemLabsVersion) (not bumped)" -ForegroundColor Green
        Get-ChildItem -LiteralPath $dryRunRoot -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host ("  produced       : {0} ({1:n0} KB)" -f $_.Name, ($_.Length / 1KB)) -ForegroundColor Green }
        Write-Host "  remove it with : Remove-Item -Recurse -Force '$dryRunRoot'" -ForegroundColor DarkGray
        $dryRunCompleted = $true
        return
    }

    $versionFilePath = Join-Path $PSScriptRoot "..\version.json"
    $versionFilePath = (Resolve-Path $versionFilePath).Path
    $todayPrefix = (Get-Date).ToString("yyMMdd")
    $oldVersion = $Common.MemLabsVersion

    if ($oldVersion -match "^$todayPrefix\.(\d+)$") {
        $newVersion = "$todayPrefix.$([int]$Matches[1] + 1)"
    }
    else {
        $newVersion = "$todayPrefix.0"
    }

    # Read-modify-write the whole document rather than regex-patching a source file. The old
    # approach anchored a -replace on the loaded version string: when that anchor did not match
    # (file already bumped, hand-edited, or the loaded value stale) the replace was a no-op, the
    # file was rewritten byte-identical, and it still printed "updated". Read back and compare.
    $versionDoc = Get-Content -LiteralPath $versionFilePath -Raw | ConvertFrom-Json
    $versionDoc.memLabsVersion = $newVersion
    $versionDoc.latestHotfixVersion = $newVersion
    $versionDoc | ConvertTo-Json | Set-Content -LiteralPath $versionFilePath -Encoding utf8

    $verify = Get-Content -LiteralPath $versionFilePath -Raw | ConvertFrom-Json
    if ($verify.memLabsVersion -ne $newVersion -or $verify.latestHotfixVersion -ne $newVersion) {
        throw "Version bump did not take: $versionFilePath still reads memLabs=$($verify.memLabsVersion) hotfix=$($verify.latestHotfixVersion), expected $newVersion."
    }
    if (-not ($verify.memLabsVersion -is [string])) {
        throw "Version bump wrote a non-string to $versionFilePath; Common.ps1 requires a quoted value."
    }
    Write-Host "MemLabsVersion updated: $oldVersion -> $newVersion (verified in version.json)" -ForegroundColor Cyan
}
finally {
    if ($zipJob -and $zipJob.State -eq 'Running') {
        $zipJob | Stop-Job -PassThru | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    if ($parseCheckJob -and $parseCheckJob.State -eq 'Running') {
        $parseCheckJob | Stop-Job -PassThru | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    # If we terminated with an error, delete the zip so the next run rebuilds. Uses
    # $zipTarget, so a dry run reaching here removes only its scratch copy -- this runs on
    # every exit path, including the dry run's own return.
    if (-not $?) {
        if ($zipTarget -and (Test-Path $zipTarget)) {
            Remove-Item $zipTarget -Force -ErrorAction SilentlyContinue
            Write-Host "Deleted $zipTarget due to build failure." -ForegroundColor Yellow
        }
    }
    $parentDir = Split-Path -Path $PSScriptRoot -Parent
    Set-Location $parentDir

    # Say which of the two it was, because they need different responses.
    if ($DryRun -and -not $dryRunCompleted) {
        Write-Host ""
        if (-not $dryRunHyperV) {
            Write-Host "DRYRUN STOPPED BY ENVIRONMENT: no usable Hyper-V here ($dryRunHyperVWhy)." -ForegroundColor Yellow
            Write-Host "  The config path was exercised; the build stages were not. Re-run on the lab host." -ForegroundColor Yellow
        }
        else {
            Write-Host "DRYRUN FAILED with Hyper-V available -- this is a real failure, see the error above." -ForegroundColor Red
        }
    }
}