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

# This script is the only caller that requires a deterministic Windows
# PowerShell module view. Keep the override local to this process; merely
# dot-sourcing Common.Prereqs.ps1 must never hide a user's modules.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $env:PSModulePath = Get-MemLabsWindowsPowerShellModulePath -AllUsersOnly:((-not $DryRun) -and (Test-MemLabsElevated))
}

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
$releaseBuildCompleted = $false
$releaseTransactionStarted = $false
$releaseMutex = $null
$releaseMutexHeld = $false
$stagedVersionPath = $null
$stagedReceiptPath = $null
$stagedDummyConfigPath = $null
$sameVolumeZipTemp = $null
$sameVolumeVersionTemp = $null
$sameVolumeReceiptTemp = $null
$transactionMarkerTemp = $null
$dryRunHyperV = $false
$dryRunHyperVWhy = 'Hyper-V cmdlets are not installed'
$scratchDrive = Get-PSDrive -PSProvider FileSystem |
    Where-Object {
        try { [IO.DriveInfo]::new($_.Root).DriveType -eq [IO.DriveType]::Fixed }
        catch { $false }
    } |
    Sort-Object Free -Descending |
    Select-Object -First 1
if (-not $scratchDrive -or $scratchDrive.Free -lt 512MB) {
    throw 'No filesystem has at least 512 MB free for the DSC package build.'
}
$buildScratchBase = Join-Path $scratchDrive.Root 'MemLabsBuildScratch'
$buildRunRoot = Join-Path $buildScratchBase ("dsczip-" + [guid]::NewGuid().ToString('N'))
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
if ($DryRun) {
    $dryRunRoot = $buildRunRoot
    New-Item -ItemType Directory -Path $dryRunRoot -Force | Out-Null
    Write-Host "DRYRUN: writing everything to $dryRunRoot" -ForegroundColor Yellow
    Write-Host "DRYRUN: repo DSC.zip, Common.ps1 and installed modules will not be touched." -ForegroundColor Yellow

    # Probed up front so a box without Hyper-V reports itself as the wrong machine rather
    # than looking like a script fault when the first VM query fails.
    if (Get-Command Get-VMHost -ErrorAction SilentlyContinue) {
        try { $null = Get-VMHost -ErrorAction Stop; $dryRunHyperV = $true }
        catch { $dryRunHyperVWhy = $_.Exception.Message }
    }
    $dryRunAz = @((Get-Module -ListAvailable Az.Compute -ErrorAction SilentlyContinue) |
        Where-Object { $_.Version -eq [version]'8.1.0' }).Count -gt 0
    Write-Host ("DRYRUN: Hyper-V usable : {0}" -f $(if ($dryRunHyperV) { 'yes' } else { "NO - $dryRunHyperVWhy" })) -ForegroundColor Yellow
    Write-Host ("DRYRUN: Az.Compute     : {0}" -f $(if ($dryRunAz) { 'yes' } else { 'NO - the zip step cannot run' })) -ForegroundColor Yellow
    if (-not $dryRunHyperV) {
        Write-Host "DRYRUN: without Hyper-V this validates the config path and then stops at the first VM query." -ForegroundColor Yellow
    }
}

# Always build away from the repository. The tracked archive is replaced only
# after ZIP validation, guest parsing and representative MOF compilation pass.
if (-not (Test-Path -LiteralPath $buildRunRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $buildRunRoot -Force | Out-Null
}
$buildTemp = Join-Path $buildRunRoot 'temp'
New-Item -ItemType Directory -Path $buildTemp -Force | Out-Null
$env:TEMP = $buildTemp
$env:TMP = $buildTemp
Write-Host "DSC build temporary path: $buildTemp"
$zipTarget = Join-Path $buildRunRoot 'DSC.zip'
$releaseZipPath = Join-Path $PSScriptRoot 'DSC.zip'
$receiptFilePath = Join-Path $PSScriptRoot 'DSC.build.json'
$versionFilePath = (Resolve-Path (Join-Path $PSScriptRoot '..\version.json')).Path
$transactionMarkerPath = Join-Path $PSScriptRoot '.memlabs-dsc-release-transaction.json'
$archiveBackupPath = "$releaseZipPath.memlabs-release.bak"
$versionBackupPath = "$versionFilePath.memlabs-release.bak"
$receiptBackupPath = "$receiptFilePath.memlabs-release.bak"
$archiveSwapBackupPath = "$releaseZipPath.memlabs-swap.bak"
$versionSwapBackupPath = "$versionFilePath.memlabs-swap.bak"
$receiptSwapBackupPath = "$receiptFilePath.memlabs-swap.bak"

function Restore-MemLabsReleaseTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $MarkerPath)

    $transaction = Get-Content -LiteralPath $MarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $items = @(
        [pscustomobject]@{ Name = 'DSC archive'; Target = [string]$transaction.ArchiveTarget; Backup = [string]$transaction.ArchiveBackup; Existed = [bool]$transaction.ArchiveExisted }
        [pscustomobject]@{ Name = 'version file'; Target = [string]$transaction.VersionTarget; Backup = [string]$transaction.VersionBackup; Existed = [bool]$transaction.VersionExisted }
    )
    if ($transaction.PSObject.Properties['ReceiptTarget']) {
        $items += [pscustomobject]@{ Name = 'DSC build receipt'; Target = [string]$transaction.ReceiptTarget; Backup = [string]$transaction.ReceiptBackup; Existed = [bool]$transaction.ReceiptExisted }
    }

    # A validated promotion can outlive a transient marker-delete failure. If
    # every live target still has the committed hash recorded in the marker,
    # finish cleanup instead of rolling the successful release back.
    if ($transaction.PSObject.Properties['State'] -and $transaction.State -eq 'Committed') {
        $committedHashes = @{
            ([string]$transaction.ArchiveTarget) = [string]$transaction.ArchiveSha256
            ([string]$transaction.VersionTarget) = [string]$transaction.VersionSha256
            ([string]$transaction.ReceiptTarget) = [string]$transaction.ReceiptSha256
        }
        $matchesCommitted = $true
        foreach ($target in $committedHashes.Keys) {
            if ([string]::IsNullOrWhiteSpace($target) -or
                [string]::IsNullOrWhiteSpace($committedHashes[$target]) -or
                -not (Test-Path -LiteralPath $target -PathType Leaf) -or
                (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash -ne $committedHashes[$target]) {
                $matchesCommitted = $false
                break
            }
        }
        if ($matchesCommitted) {
            Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction Stop
            foreach ($backup in @($items.Backup)) {
                if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
            }
            return
        }
    }

    foreach ($item in $items) {
        if ([string]::IsNullOrWhiteSpace($item.Target) -or [string]::IsNullOrWhiteSpace($item.Backup)) {
            throw "Release transaction marker '$MarkerPath' is incomplete."
        }
        if ($item.Existed) {
            if (-not (Test-Path -LiteralPath $item.Backup -PathType Leaf)) {
                throw "Cannot restore the prior $($item.Name): transaction backup '$($item.Backup)' is missing."
            }
            Copy-Item -LiteralPath $item.Backup -Destination $item.Target -Force -ErrorAction Stop
        }
        elseif (Test-Path -LiteralPath $item.Target) {
            Remove-Item -LiteralPath $item.Target -Force -ErrorAction Stop
        }
    }

    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction Stop
    foreach ($backup in @($items.Backup)) {
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
    }
}

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

if (-not $DryRun) {
    $releaseMutex = [Threading.Mutex]::new($false, 'Global\MemLabsDscPackageBuildLock')
    try { $releaseMutexHeld = $releaseMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $releaseMutexHeld = $true }
    if (-not $releaseMutexHeld) {
        $releaseMutex.Dispose()
        $env:TEMP = $originalTemp
        $env:TMP = $originalTmp
        Set-Location (Split-Path -Path $PSScriptRoot -Parent)
        if ($buildRunRoot -and (Test-Path -LiteralPath $buildRunRoot)) {
            Remove-Item -LiteralPath $buildRunRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw 'Another DSC package build owns the release transaction lock.'
    }
}

#####################
### Install modules
#####################
# Az.Compute module, install once to use Publish-AzVMDscConfiguration
# Install-Module Az.Compute -Force

# Modules used by VM Guests, include all so the ZIP contains all required modules to make it easier to move them to guest VMs.

try {
    if (-not $DryRun) {
        if (Test-Path -LiteralPath $transactionMarkerPath -PathType Leaf) {
            Write-Host "Recovering an interrupted prior DSC release transaction." -ForegroundColor Yellow
            Restore-MemLabsReleaseTransaction -MarkerPath $transactionMarkerPath
        }
        else {
            foreach ($orphanedBackup in @($archiveBackupPath, $versionBackupPath, $receiptBackupPath, $archiveSwapBackupPath, $versionSwapBackupPath, $receiptSwapBackupPath)) {
                if (Test-Path -LiteralPath $orphanedBackup) { Remove-Item -LiteralPath $orphanedBackup -Force -ErrorAction Stop }
            }
        }
        foreach ($orphanedSwapBackup in @($archiveSwapBackupPath, $versionSwapBackupPath, $receiptSwapBackupPath)) {
            if (Test-Path -LiteralPath $orphanedSwapBackup) { Remove-Item -LiteralPath $orphanedSwapBackup -Force -ErrorAction Stop }
        }
    }

    Write-Host "Checking Modules.."
    $modules = @(
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

    if ($DryRun) {
        $missingDryRunBuildTools = @()
        if (@(Get-Module -ListAvailable Az.Accounts -Verbose:$false |
                Where-Object { $_.Version -ge [version]'3.0.1' }).Count -eq 0) {
            $missingDryRunBuildTools += 'Az.Accounts >= 3.0.1'
        }
        if (@(Get-Module -ListAvailable Az.Compute -Verbose:$false |
                Where-Object { $_.Version -eq [version]'8.1.0' }).Count -eq 0) {
            $missingDryRunBuildTools += 'Az.Compute 8.1.0'
        }
        $missingDryRunModules = @($modules | Where-Object { $allAvailable -notcontains $_ })
        if ($missingDryRunBuildTools.Count -gt 0 -or $missingDryRunModules.Count -gt 0) {
            $missingDescription = @($missingDryRunBuildTools + $missingDryRunModules) -join ', '
            Write-Host "DRYRUN STOPPED BY ENVIRONMENT: required module(s) are not installed and dry run will not install them: $missingDescription." -ForegroundColor Yellow
            $dryRunCompleted = $true
            return
        }
    }

    # Publish-AzVMDscConfiguration is build tooling, not a guest dependency. Pin
    # the last version verified under Windows PowerShell 5.1; current Az.Compute
    # releases can install into WindowsPowerShell\Modules yet fail import on 5.1
    # with missing generated model types. Do not let Update-Module silently move
    # the package builder onto an incompatible version.
    $azAccountsBuildVersion = '3.0.1'
    $azComputeBuildVersion = '8.1.0'
    $allUsersModuleRoot = Get-MemLabsModuleInstallPath -Scope 'AllUsers'
    $buildToolModuleRoot = Join-Path $buildScratchBase 'WindowsPowerShell\Modules'
    $env:PSModulePath = "$buildToolModuleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"

    # Az.Compute 8.1.0 declares Az.Accounts >= 3.0.1. Install both exact,
    # known-compatible build-tool versions into the isolated cache so a newer
    # machine-wide Az.Accounts cannot silently change Windows PowerShell 5.1
    # packaging behavior.
    foreach ($buildTool in @(
            [pscustomobject]@{ Name = 'Az.Accounts'; Version = $azAccountsBuildVersion }
            [pscustomobject]@{ Name = 'Az.Compute'; Version = $azComputeBuildVersion }
        )) {
        $cachedBuildTool = @(Get-Module -ListAvailable $buildTool.Name -Verbose:$false |
                Where-Object {
                    $_.Version -eq [version]$buildTool.Version -and
                    $_.ModuleBase.StartsWith($buildToolModuleRoot, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)
        if ($cachedBuildTool.Count -eq 0 -and -not $DryRun) {
            if (-not (Initialize-PSGallery)) { throw "PSGallery is unavailable; cannot install pinned build tool $($buildTool.Name) $($buildTool.Version)." }
            Write-Host "Installing $($buildTool.Name) $($buildTool.Version) into build-tool cache '$buildToolModuleRoot'..."
            $installedBuildTool = Install-ModuleFromNupkg -Name $buildTool.Name -Scope AllUsers `
                -RequiredVersion $buildTool.Version -DestinationRoot $buildToolModuleRoot
            if (-not $installedBuildTool) {
                throw "Could not install $($buildTool.Name) $($buildTool.Version) into the build-tool cache."
            }
        }
    }

    if ($DryRun) {
        $azAccountsBuildModule = @(Get-Module -ListAvailable Az.Accounts -Verbose:$false |
                Where-Object { $_.Version -ge [version]$azAccountsBuildVersion } |
                Sort-Object Version -Descending |
                Select-Object -First 1)
        $azComputeBuildModule = @(Get-Module -ListAvailable Az.Compute -Verbose:$false |
                Where-Object { $_.Version -eq [version]$azComputeBuildVersion } |
                Select-Object -First 1)
    }
    else {
        $azAccountsBuildModule = @(Get-Module -ListAvailable Az.Accounts -Verbose:$false |
                Where-Object {
                    $_.Version -eq [version]$azAccountsBuildVersion -and
                    $_.ModuleBase.StartsWith($buildToolModuleRoot, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)
        $azComputeBuildModule = @(Get-Module -ListAvailable Az.Compute -Verbose:$false |
                Where-Object {
                    $_.Version -eq [version]$azComputeBuildVersion -and
                    $_.ModuleBase.StartsWith($buildToolModuleRoot, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)
    }
    if ($azAccountsBuildModule.Count -ne 1 -or $azComputeBuildModule.Count -ne 1) {
        if ($azAccountsBuildModule.Count -ne 1) {
            throw "Az.Accounts $azAccountsBuildVersion is required in '$buildToolModuleRoot' for deterministic PS5.1 DSC packaging."
        }
        throw "Az.Compute $azComputeBuildVersion is required in '$buildToolModuleRoot' for deterministic PS5.1 DSC packaging."
    }

    # Materialize one and only one discoverable version of every guest module.
    # Import-DscResource fails when the same module exists in multiple roots or
    # when several versions are visible under one root. Per-run junctions avoid
    # copying large modules while making discovery deterministic.
    $selectedGuestModules = [ordered]@{}
    $missingBuildModules = @()
    foreach ($module in $modules) {
        $selected = @(Get-Module -ListAvailable -Name $module -Verbose:$false |
                Sort-Object Version -Descending |
                Select-Object -First 1)
        if ($selected.Count -ne 1) {
            $missingBuildModules += $module
            continue
        }
        $selectedGuestModules[$module] = $selected[0]
    }
    if ($missingBuildModules.Count -gt 0) {
        throw "Required guest module(s) are unavailable for the isolated build: $($missingBuildModules -join ', ')."
    }

    $isolatedGuestModuleRoot = Join-Path $buildRunRoot 'WindowsPowerShell\Modules'
    New-Item -ItemType Directory -Path $isolatedGuestModuleRoot -Force -ErrorAction Stop | Out-Null
    foreach ($module in $selectedGuestModules.Keys) {
        # Keep the in-box PSDesiredStateConfiguration visible from PSHOME.
        # Junctioning that same module into the isolated root produces duplicate
        # CIM schema definitions during configuration compilation.
        if ($module -eq 'PSDesiredStateConfiguration') { continue }
        $moduleInfo = $selectedGuestModules[$module]
        $moduleNameRoot = Join-Path $isolatedGuestModuleRoot $module
        New-Item -ItemType Directory -Path $moduleNameRoot -Force -ErrorAction Stop | Out-Null
        $moduleVersionPath = Join-Path $moduleNameRoot ([string]$moduleInfo.Version)
        New-Item -ItemType Junction -Path $moduleVersionPath -Target $moduleInfo.ModuleBase -ErrorAction Stop | Out-Null
        Write-Host "DSC guest module: $module $($moduleInfo.Version) -> $($moduleInfo.ModuleBase)"
    }

    $guestModulePackageRoot = Join-Path $buildRunRoot 'GuestModules'
    New-Item -ItemType Directory -Path $guestModulePackageRoot -Force -ErrorAction Stop | Out-Null
    foreach ($module in @($selectedGuestModules.Keys | Where-Object { $_ -ne 'PSDesiredStateConfiguration' })) {
        $moduleTarget = Join-Path $guestModulePackageRoot $module
        New-Item -ItemType Directory -Path $moduleTarget -Force -ErrorAction Stop | Out-Null
        Get-ChildItem -LiteralPath $selectedGuestModules[$module].ModuleBase -Force -ErrorAction Stop |
            Copy-Item -Destination $moduleTarget -Recurse -Force -ErrorAction Stop
    }
    $expectedArchiveModules = @($selectedGuestModules.Keys | Where-Object { $_ -ne 'PSDesiredStateConfiguration' }) + 'TemplateHelpDSC'

    $templateManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'TemplateHelpDSC\TemplateHelpDSC.psd1')
    $templateVersionPath = Join-Path (Join-Path $isolatedGuestModuleRoot 'TemplateHelpDSC') ([string]$templateManifest.ModuleVersion)
    New-Item -ItemType Directory -Path (Split-Path $templateVersionPath -Parent) -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'TemplateHelpDSC') -Destination $templateVersionPath -Recurse -Force -ErrorAction Stop

    $builtInModuleRoot = Join-Path $PSHOME 'Modules'
    $env:PSModulePath = @($isolatedGuestModuleRoot, $buildToolModuleRoot, $builtInModuleRoot) -join [IO.Path]::PathSeparator
    $isolatedModulePath = $env:PSModulePath
    Write-Host "DSC build module path: $env:PSModulePath"

    # Publish-AzVMDscConfiguration reparses the configuration in a child
    # process whose default module paths can expose duplicate versions. Build a
    # scratch configuration with every guest import pinned to the exact version
    # selected above.
    $moduleSpecs = @(
        foreach ($module in $selectedGuestModules.Keys) {
            $moduleInfo = $selectedGuestModules[$module]
            "@{ ModuleName = '$module'; ModuleVersion = '$($moduleInfo.Version)' }"
        }
    )
    $dummyConfigSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'DummyConfig.ps1') -Raw -ErrorAction Stop
    $importPattern = [regex]::new('(?m)^\s*Import-DscResource\s+-ModuleName\s+.+$')
    $qualifiedImport = '    Import-DscResource -ModuleName ' + ($moduleSpecs -join ', ')
    $stagedDummySource = $importPattern.Replace($dummyConfigSource, $qualifiedImport, 1)
    if ($stagedDummySource -eq $dummyConfigSource) {
        throw 'Could not replace DummyConfig.ps1 module imports with pinned versions.'
    }
    $stagedDummyConfigPath = Join-Path $buildRunRoot 'DummyConfig.ps1'
    [IO.File]::WriteAllText($stagedDummyConfigPath, $stagedDummySource, [Text.UTF8Encoding]::new($true))

    Import-Module $azAccountsBuildModule[0].Path -Force -ErrorAction Stop
    Import-Module $azComputeBuildModule[0].Path -Force -ErrorAction Stop
    if (-not (Get-Command Publish-AzVMDscConfiguration -ErrorAction SilentlyContinue)) {
        throw 'Publish-AzVMDscConfiguration is unavailable after importing Az.Compute from the isolated build path.'
    }

    # Start ZIP creation as a background job - runs in parallel with everything below.
    # Nothing else depends on DSC.zip; we wait for it at the very end.
    Write-Host "Starting DSC.zip creation in background ($zipTarget)..."
    $dscDir = $PSScriptRoot
    $zipJob = Start-Job -ScriptBlock {
        param($dir, $configurationPath, $modulePackageRoot, $target, $accountsModulePath, $computeModulePath, $modulePath)
        $ErrorActionPreference = 'Stop'
        $env:PSModulePath = $modulePath
        Set-Location $dir
        Import-Module $accountsModulePath -Force -ErrorAction Stop
        Import-Module $computeModulePath -Force -ErrorAction Stop
        Write-Output "Creating DSC.zip at $target..."
        Publish-AzVMDscConfiguration $configurationPath -OutputArchivePath $target -Force -Confirm:$false
        Write-Output "Removing publisher-generated module payloads..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $publishedArchive = [IO.Compression.ZipFile]::Open($target, [IO.Compression.ZipArchiveMode]::Update)
        try {
            foreach ($entry in @($publishedArchive.Entries)) {
                if ($entry.FullName -notin @('dscmetadata.json', 'DummyConfig.ps1')) {
                    $entry.Delete()
                }
            }
        }
        finally { $publishedArchive.Dispose() }
        Write-Output "Adding selected guest module payloads to DSC.zip..."
        Compress-Archive -Path (Join-Path $modulePackageRoot '*') -Update -DestinationPath $target
        Write-Output "Adding TemplateHelpDSC to DSC.zip..."
        Compress-Archive -Path .\TemplateHelpDSC -Update -DestinationPath $target
        Write-Output "DSC.zip creation complete."
    } -ArgumentList $dscDir, $stagedDummyConfigPath, $guestModulePackageRoot, $zipTarget, $azAccountsBuildModule[0].Path, $azComputeBuildModule[0].Path, $isolatedModulePath

    # Tell common to re-init (runs in parallel with ZIP creation above)
    if ($Common.Initialized) {
        $Common.Initialized = $false
    }
    # Not -InJob: this is host-side tooling and needs Test-Configuration, which Common.ps1
    # only loads outside a job. Storage initialization is required because it populates the
    # supported CM/SQL catalogs consumed by Test-Configuration below.
    . "..\Common.ps1" -SkipMaintenanceRefresh -SkipEnvironmentDetection -SkipHostPreparation
    # Common initialization and module auto-loading may expand the process module
    # view. Reassert the one-version build path before compiling the Configuration
    # so a stale machine-wide guest module cannot shadow this run's selected copy.
    $env:PSModulePath = $isolatedModulePath
    # ConfirmImpact enum, not a bool -- $false threw a MetadataError on every run.
    $ConfirmPreference = 'None'

    # Create dummy file so config doesn't fail
    $userConfig = Get-UserConfiguration -Configuration $configName
    $result = Test-Configuration -InputObject $userConfig.Config
    if (-not $result -or -not $result.DeployConfig) {
        $validationMessage = if ($result -and $result.Message) { "$($result.Message)".Trim() } else { 'no validation result' }
        throw "DSC compile configuration did not produce a deployConfig: $validationMessage"
    }
    $matchingVm = @($result.DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $vmName })
    if ($matchingVm.Count -ne 1) {
        throw "DSC compile VM '$vmName' resolved to $($matchingVm.Count) VM(s). Use the full deployed VM name, including the configured prefix."
    }
    $ThisVM = $matchingVm[0]
    $deployConfigCopy = $result.DeployConfig

    # Dump config to file, for debugging
    #$result.DeployConfig | ConvertTo-Json | Set-Clipboard
    $filePath = Join-Path $buildRunRoot 'deployConfig.json'
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
    $parseCheckDirs = @(
        (Resolve-Path (Join-Path $PSScriptRoot 'phases')).Path
        (Resolve-Path (Join-Path $PSScriptRoot 'TemplateHelpDSC')).Path
    )
    $parseCheckJob = Start-Job -ScriptBlock {
        param($dirs, $modulePath)
        $env:PSModulePath = $modulePath
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
        [PSCustomObject]@{ ResultType = 'MemLabsParseCheck'; Failures = $failures; CheckedCount = $checked }
    } -ArgumentList (,$parseCheckDirs), $isolatedModulePath

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

    . (Join-Path $PSScriptRoot "phases\$($dscRole).ps1")

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
    $configOutPath = Join-Path $buildRunRoot "$($role)-Config"
    write-host "Running ""$($dscRole)"" -DeployConfigPath $filePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath ""$configOutPath"" "
    & "$($dscRole)" -DeployConfigPath $filePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath $configOutPath | out-host
    $compiledMofs = @(Get-ChildItem -LiteralPath $configOutPath -Filter '*.mof' -File -ErrorAction SilentlyContinue)
    if ($compiledMofs.Count -eq 0) {
        throw "Representative DSC compilation produced no MOF in '$configOutPath'."
    }
    Write-Host "Representative DSC compilation produced $($compiledMofs.Count) MOF file(s)." -ForegroundColor Green
    if (-not $DryRun) {
        Add-CmdHistory "$($dscRole) -DeployConfigPath $filePath -AdminCreds (Get-Credential) -ConfigurationData $cd -OutputPath `"$configOutPath`""
    }

    # Wait for the background parse-check job to finish and report results.
    if ($parseCheckJob) {
        Write-Host "`nWaiting for PS5.1 parse-check to complete..."
        $parseCheckJob | Wait-Job | Out-Null
        $parseState = $parseCheckJob.State
        $parseReason = $parseCheckJob.ChildJobs[0].JobStateInfo.Reason
        if ($parseState -ne 'Completed') {
            $parseCheckJob | Remove-Job -Force -ErrorAction SilentlyContinue
            $parseCheckJob = $null
            throw "PS5.1 parse-check job ended in state $parseState`: $parseReason"
        }
        $parseOutput = @($parseCheckJob | Receive-Job -ErrorAction Stop)
        $parseCheckJob | Remove-Job -Force -ErrorAction Stop
        $parseCheckJob = $null
        $parseResults = @($parseOutput | Where-Object { $_.ResultType -eq 'MemLabsParseCheck' })
        if ($parseResults.Count -ne 1) {
            throw "PS5.1 parse-check returned $($parseResults.Count) structured result(s); expected exactly one."
        }
        $parseResult = $parseResults[0]
        if ([int]$parseResult.CheckedCount -le 0) {
            throw 'PS5.1 parse-check examined zero guest scripts.'
        }
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
        $zipJob | Wait-Job | Out-Null
        $zipState = $zipJob.State
        $zipReason = $zipJob.ChildJobs[0].JobStateInfo.Reason
        if ($zipState -ne 'Completed') {
            $zipJob | Remove-Job -Force -ErrorAction SilentlyContinue
            $zipJob = $null
            throw "DSC.zip background job ended in state $zipState`: $zipReason"
        }
        $zipOutput = $zipJob | Receive-Job -ErrorAction Stop
        $zipJob | Remove-Job -Force -ErrorAction Stop
        $zipJob = $null
        $zipOutput | ForEach-Object { Write-Host "  $_" }
        & (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Update-LanguageDscArchive.ps1') -ArchivePath $zipTarget
        if (-not (Test-Path -LiteralPath $zipTarget -PathType Leaf)) {
            throw "DSC archive job produced no file at '$zipTarget'."
        }
        $zipCheck = [IO.Compression.ZipFile]::OpenRead($zipTarget)
        try {
            if ($zipCheck.Entries.Count -le 0) { throw 'DSC archive contains no entries.' }
            $archiveTopLevel = @($zipCheck.Entries | ForEach-Object { ($_.FullName -split '[\\/]')[0] } | Sort-Object -Unique)
            $missingArchiveModules = @($expectedArchiveModules | Where-Object { $_ -notin $archiveTopLevel })
            if ($missingArchiveModules.Count -gt 0) {
                throw "DSC archive is missing expected guest module(s): $($missingArchiveModules -join ', ')."
            }
            $allowedArchiveRoots = @($expectedArchiveModules) + @('dscmetadata.json', 'DummyConfig.ps1')
            $unexpectedArchiveRoots = @($archiveTopLevel | Where-Object { $_ -notin $allowedArchiveRoots })
            if ($unexpectedArchiveRoots.Count -gt 0) {
                throw "DSC archive contains unexpected top-level path(s): $($unexpectedArchiveRoots -join ', ')."
            }
            Write-Host "DSC.zip staged with $($zipCheck.Entries.Count) entries." -ForegroundColor Green
        }
        finally { $zipCheck.Dispose() }
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
    $stagedVersionPath = Join-Path $buildRunRoot 'version.json'
    $versionJson = ($versionDoc | ConvertTo-Json) + [Environment]::NewLine
    [IO.File]::WriteAllText($stagedVersionPath, $versionJson, (New-Object Text.UTF8Encoding($true)))

    $stagedVersion = Get-Content -LiteralPath $stagedVersionPath -Raw | ConvertFrom-Json
    if ($stagedVersion.memLabsVersion -ne $newVersion -or $stagedVersion.latestHotfixVersion -ne $newVersion) {
        throw "Staged version file reads memLabs=$($stagedVersion.memLabsVersion) hotfix=$($stagedVersion.latestHotfixVersion), expected $newVersion."
    }
    if (-not ($stagedVersion.memLabsVersion -is [string])) {
        throw "Staged version is not a string; Common.ps1 requires a quoted value."
    }

    $stagedReceiptPath = Join-Path $buildRunRoot 'DSC.build.json'
    Write-MemLabsDscArtifactReceipt -DscRoot $PSScriptRoot -ArchivePath $zipTarget `
        -VersionPath $stagedVersionPath -ReceiptPath $stagedReceiptPath

    # File.Replace is atomic only when source and destination share a volume.
    # Copy each already-validated staged file beside its final destination before
    # opening the recoverable three-file transaction.
    $sameVolumeZipTemp = "$releaseZipPath.$PID.tmp"
    $sameVolumeVersionTemp = "$versionFilePath.$PID.tmp"
    $sameVolumeReceiptTemp = "$receiptFilePath.$PID.tmp"
    Copy-Item -LiteralPath $zipTarget -Destination $sameVolumeZipTemp -Force -ErrorAction Stop
    Copy-Item -LiteralPath $stagedVersionPath -Destination $sameVolumeVersionTemp -Force -ErrorAction Stop
    Copy-Item -LiteralPath $stagedReceiptPath -Destination $sameVolumeReceiptTemp -Force -ErrorAction Stop
    $stagedZipHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $sameVolumeZipTemp -Algorithm SHA256).Hash
    $stagedVersionHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $sameVolumeVersionTemp -Algorithm SHA256).Hash
    $stagedReceiptHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $sameVolumeReceiptTemp -Algorithm SHA256).Hash

    $releaseTransaction = [ordered]@{
        SchemaVersion  = 1
        State          = 'Pending'
        ArchiveTarget  = $releaseZipPath
        ArchiveBackup  = $archiveBackupPath
        ArchiveExisted = Test-Path -LiteralPath $releaseZipPath -PathType Leaf
        VersionTarget  = $versionFilePath
        VersionBackup  = $versionBackupPath
        VersionExisted = Test-Path -LiteralPath $versionFilePath -PathType Leaf
        ReceiptTarget  = $receiptFilePath
        ReceiptBackup  = $receiptBackupPath
        ReceiptExisted = Test-Path -LiteralPath $receiptFilePath -PathType Leaf
        NewVersion     = $newVersion
    }
    if ($releaseTransaction.ArchiveExisted) { Copy-Item -LiteralPath $releaseZipPath -Destination $archiveBackupPath -Force -ErrorAction Stop }
    if ($releaseTransaction.VersionExisted) { Copy-Item -LiteralPath $versionFilePath -Destination $versionBackupPath -Force -ErrorAction Stop }
    if ($releaseTransaction.ReceiptExisted) { Copy-Item -LiteralPath $receiptFilePath -Destination $receiptBackupPath -Force -ErrorAction Stop }

    $transactionMarkerTemp = "$transactionMarkerPath.$PID.tmp"
    [IO.File]::WriteAllText($transactionMarkerTemp, ($releaseTransaction | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $transactionMarkerTemp -Destination $transactionMarkerPath -Force -ErrorAction Stop
    $releaseTransactionStarted = $true

    if ($releaseTransaction.VersionExisted) { [IO.File]::Replace($sameVolumeVersionTemp, $versionFilePath, $versionSwapBackupPath) }
    else { Move-Item -LiteralPath $sameVolumeVersionTemp -Destination $versionFilePath -Force -ErrorAction Stop }
    if ($releaseTransaction.ArchiveExisted) { [IO.File]::Replace($sameVolumeZipTemp, $releaseZipPath, $archiveSwapBackupPath) }
    else { Move-Item -LiteralPath $sameVolumeZipTemp -Destination $releaseZipPath -Force -ErrorAction Stop }
    if ($releaseTransaction.ReceiptExisted) { [IO.File]::Replace($sameVolumeReceiptTemp, $receiptFilePath, $receiptSwapBackupPath) }
    else { Move-Item -LiteralPath $sameVolumeReceiptTemp -Destination $receiptFilePath -Force -ErrorAction Stop }

    $verify = Get-Content -LiteralPath $versionFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $releaseZipHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $releaseZipPath -Algorithm SHA256).Hash
    $releaseVersionHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $versionFilePath -Algorithm SHA256).Hash
    $releaseReceiptHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $receiptFilePath -Algorithm SHA256).Hash
    if ($verify.memLabsVersion -ne $newVersion -or $verify.latestHotfixVersion -ne $newVersion -or
        $releaseZipHash -ne $stagedZipHash -or $releaseVersionHash -ne $stagedVersionHash -or
        $releaseReceiptHash -ne $stagedReceiptHash) {
        throw 'Promoted DSC.zip, version.json and DSC.build.json did not match their validated staged files.'
    }
    $artifactState = Get-MemLabsDscArtifactState -DscRoot $PSScriptRoot
    if (-not $artifactState.Current) {
        throw "Promoted DSC artifact set failed receipt validation: $($artifactState.Reason)"
    }

    # Persist the verified post-promotion hashes before deleting the marker.
    # If marker deletion is transiently blocked, the next run can prove that
    # the live release already committed and finish cleanup without rollback.
    $releaseTransaction.State = 'Committed'
    $releaseTransaction.ArchiveSha256 = $releaseZipHash
    $releaseTransaction.VersionSha256 = $releaseVersionHash
    $releaseTransaction.ReceiptSha256 = $releaseReceiptHash
    $transactionMarkerTemp = "$transactionMarkerPath.$PID.committed.tmp"
    [IO.File]::WriteAllText($transactionMarkerTemp, ($releaseTransaction | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $transactionMarkerTemp -Destination $transactionMarkerPath -Force -ErrorAction Stop

    Write-Host "Promoted validated DSC.zip, version.json and DSC.build.json as one recoverable release transaction." -ForegroundColor Green
    Write-Host "MemLabsVersion updated: $oldVersion -> $newVersion (verified in version.json)" -ForegroundColor Cyan
    $releaseBuildCompleted = $true
}
finally {
    if ($zipJob) {
        if ($zipJob.State -eq 'Running') { $zipJob | Stop-Job -ErrorAction SilentlyContinue }
        $zipJob | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    if ($parseCheckJob) {
        if ($parseCheckJob.State -eq 'Running') { $parseCheckJob | Stop-Job -ErrorAction SilentlyContinue }
        $parseCheckJob | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    # The build always targets scratch, so failure cleanup can never delete the
    # last known-good tracked release archive.
    if (-not $?) {
        if ($zipTarget -and (Test-Path $zipTarget)) {
            Remove-Item $zipTarget -Force -ErrorAction SilentlyContinue
            Write-Host "Deleted $zipTarget due to build failure." -ForegroundColor Yellow
        }
    }
    $parentDir = Split-Path -Path $PSScriptRoot -Parent
    Set-Location $parentDir
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp

    $releaseCleanupFailure = $null
    try {
        if ($releaseTransactionStarted -and -not $releaseBuildCompleted -and (Test-Path -LiteralPath $transactionMarkerPath)) {
            Restore-MemLabsReleaseTransaction -MarkerPath $transactionMarkerPath
            foreach ($swapBackup in @($archiveSwapBackupPath, $versionSwapBackupPath, $receiptSwapBackupPath)) {
                if (Test-Path -LiteralPath $swapBackup) { Remove-Item -LiteralPath $swapBackup -Force -ErrorAction Stop }
            }
            Write-Host 'Restored the previous DSC.zip, version.json and DSC.build.json after release finalization failed.' -ForegroundColor Yellow
        }
        elseif ($releaseBuildCompleted -and (Test-Path -LiteralPath $transactionMarkerPath)) {
            # Remove the marker first: if the process terminates before this point, the
            # next build restores both backups. Once it is gone, the new pair is committed.
            Remove-Item -LiteralPath $transactionMarkerPath -Force -ErrorAction Stop
            foreach ($backup in @($archiveBackupPath, $versionBackupPath, $receiptBackupPath, $archiveSwapBackupPath, $versionSwapBackupPath, $receiptSwapBackupPath)) {
                if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
            }
        }
    }
    catch {
        $releaseCleanupFailure = $_
        Write-Host "CRITICAL: DSC release transaction cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    foreach ($temporaryPath in @($sameVolumeZipTemp, $sameVolumeVersionTemp, $sameVolumeReceiptTemp, $stagedVersionPath, $stagedReceiptPath, $stagedDummyConfigPath, $transactionMarkerTemp)) {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }

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
    if (-not $DryRun -and $buildRunRoot -and (Test-Path -LiteralPath $buildRunRoot)) {
        Remove-Item -LiteralPath $buildRunRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($releaseMutexHeld) {
        try { $releaseMutex.ReleaseMutex() } catch { }
    }
    if ($releaseMutex) { $releaseMutex.Dispose() }
    if ($releaseCleanupFailure) { throw $releaseCleanupFailure }
}