<#
.SYNOPSIS
    Verify / enable Windows Data Deduplication on a MemLabs Hyper-V VM-storage
    volume using settings that are SAFE for running VMs -- or disable it.

.DESCRIPTION
    Data Deduplication saves a large amount of space on a MemLabs host (every VM
    derives from the same base image), but two dedup settings will SILENTLY
    CORRUPT a running VM's VHDX:

      OptimizeInUseFiles = $true   -> dedup optimizes a VHDX WHILE a VM is writing
                                      to it. This is the default for the 'HyperV'
                                      and (partially) 'Backup' usage types. A live
                                      SQL / ConfigMgr VM whose disk is chunked
                                      mid-write bugchecks (0x1E / triple fault) on
                                      its next boot with NO memory dump -- the
                                      guest is unrecoverable and must be recreated.
      MinimumFileAgeDays = 0       -> no settle window; an actively-deploying VM's
                                      VHDX becomes eligible the instant it's
                                      written.

    chkdsk CANNOT detect this: it validates NTFS structure, not file *contents* or
    the dedup chunk store. The authoritative detector is a dedup Scrubbing job
    (see -Scrub).

    The SAFE profile this script applies keeps essentially all the space savings
    but makes dedup skip any disk that is currently open by a running VM:

      OptimizeInUseFiles   = $false   (never touch an open/running VM's VHDX)
      OptimizePartialFiles = $false   (don't optimize mid-file ranges)
      MinimumFileAgeDays   >= 3       (settle window; default 3)
      ExcludeFileType      = iso      (don't waste cycles on install media)

    Only powered-off VMs and the static base images get deduped -- which is where
    almost all of the savings come from anyway.

.PARAMETER Volume
    Drive letter of the VM-storage volume (e.g. 'E:'). Auto-detected when omitted:
    the largest fixed volume containing a 'VirtualMachines' folder (E: preferred).

.PARAMETER MinimumFileAgeDays
    Settle window (days) before a closed file becomes eligible for optimization.
    Default 3. Must be >= 1.

.PARAMETER CheckOnly
    Report the current dedup configuration and whether it is SAFE, then exit.
    Makes NO changes. Exit code 0 = safe, 2 = unsafe/not-enabled.

.PARAMETER Optimize
    After applying the safe settings, kick a background Optimization job now.

.PARAMETER Scrub
    Start a full Scrubbing job to detect (and repair where possible) already
    corrupted deduped data. Runs in the background; monitor with Get-DedupJob.

.PARAMETER Disable
    Disable deduplication on the volume: stop any running dedup jobs,
    Disable-DedupVolume, and disable all dedup schedules. Already-optimized files
    remain readable (they are NOT rehydrated unless you also pass -Unoptimize).

.PARAMETER Unoptimize
    Only meaningful with -Disable. Additionally rehydrate (un-dedup) every
    optimized file on the volume. This needs enough free space to undo the
    reported SavedSpace and is I/O heavy -- run it in a maintenance window with
    non-critical VMs stopped.

.EXAMPLE
    .\Set-MemlabsDedup.ps1
    Auto-detect the VM volume, install the dedup feature if needed, enable dedup,
    and force the safe settings.

.EXAMPLE
    .\Set-MemlabsDedup.ps1 -CheckOnly
    Just report whether the current dedup config is safe (no changes).

.EXAMPLE
    .\Set-MemlabsDedup.ps1 -Volume E: -Scrub
    Apply safe settings and start a full scrub to hunt for latent corruption.

.EXAMPLE
    .\Set-MemlabsDedup.ps1 -Disable
    Turn dedup off on the VM volume (leaves existing files deduped/readable).

.NOTES
    Run elevated. Data Deduplication is a Windows Server feature; it is not
    available on client SKUs.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Volume,
    [ValidateRange(1, 365)][int]$MinimumFileAgeDays = 3,
    [switch]$CheckOnly,
    [switch]$Optimize,
    [switch]$Scrub,
    [switch]$Disable,
    [switch]$Unoptimize
)

$ErrorActionPreference = 'Stop'

function Write-Ok { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Bad { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Warn2 { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Info2 { param([string]$m) Write-Host "  $m" -ForegroundColor Gray }
function Write-Head { param([string]$m) Write-Host "`n$m" -ForegroundColor Cyan }

function Resolve-VmVolume {
    param([string]$Requested)

    if ($Requested) {
        $letter = $Requested.Trim().TrimEnd('\').TrimEnd(':')
        if (-not $letter) { return $null }
        return ($letter.ToUpper() + ':')
    }

    # Auto-detect: fixed volumes that host a 'VirtualMachines' folder, E: preferred,
    # then largest by free space.
    $candidates = @()
    $fixed = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Sort-Object -Property FreeSpace -Descending
    foreach ($disk in $fixed) {
        $root = $disk.DeviceID + '\'
        if (Test-Path (Join-Path $root 'VirtualMachines')) {
            $candidates += $disk.DeviceID
        }
    }
    if ($candidates -contains 'E:') { return 'E:' }
    if ($candidates.Count -ge 1) { return $candidates[0] }
    if (Test-Path 'E:\VirtualMachines') { return 'E:' }
    return $null
}

function Get-DedupSafety {
    param([string]$Vol)

    $present = $false
    $enabled = $false
    $usage = ''
    $oiuf = $null
    $opf = $null
    $mfad = $null
    $savedGB = 0
    $excluded = @()

    $dv = $null
    try { $dv = Get-DedupVolume -Volume $Vol -ErrorAction Stop } catch { $dv = $null }

    if ($dv) {
        $present = $true
        $enabled = [bool]$dv.Enabled
        $usage = [string]$dv.UsageType
        $oiuf = $dv.OptimizeInUseFiles
        $opf = $dv.OptimizePartialFiles
        $mfad = $dv.MinimumFileAgeDays
        if ($dv.SavedSpace) { $savedGB = [math]::Round(($dv.SavedSpace / 1GB), 1) }
        if ($dv.ExcludeFileType) { $excluded = @($dv.ExcludeFileType) }
    }

    $issues = New-Object System.Collections.Generic.List[string]
    if ($present) {
        if ($oiuf -eq $true) { $issues.Add('OptimizeInUseFiles=True -> WILL optimize the VHDX of a RUNNING VM (corruption risk)') }
        if ($opf -eq $true) { $issues.Add('OptimizePartialFiles=True -> optimizes mid-file ranges of large VHDXs') }
        if ($null -ne $mfad -and [int]$mfad -lt 1) { $issues.Add("MinimumFileAgeDays=$mfad -> no settle window for freshly-written disks") }
    }

    $safe = ($present -and $enabled -and $issues.Count -eq 0)

    return [PSCustomObject]@{
        Volume               = $Vol
        Present              = $present
        Enabled              = $enabled
        UsageType            = $usage
        OptimizeInUseFiles   = $oiuf
        OptimizePartialFiles = $opf
        MinimumFileAgeDays   = $mfad
        SavedSpaceGB         = $savedGB
        ExcludeFileType      = $excluded
        Issues               = $issues
        IsSafe               = $safe
    }
}

function Show-DedupState {
    param([string]$Title, $State)

    Write-Head $Title
    if (-not $State.Present) {
        Write-Info2 "Deduplication is NOT enabled on $($State.Volume)."
        return
    }
    Write-Info2 ("Enabled              : {0}" -f $State.Enabled)
    Write-Info2 ("UsageType            : {0}" -f $State.UsageType)
    Write-Info2 ("OptimizeInUseFiles   : {0}" -f $State.OptimizeInUseFiles)
    Write-Info2 ("OptimizePartialFiles : {0}" -f $State.OptimizePartialFiles)
    Write-Info2 ("MinimumFileAgeDays   : {0}" -f $State.MinimumFileAgeDays)
    if ($State.ExcludeFileType.Count -gt 0) {
        Write-Info2 ("ExcludeFileType      : {0}" -f ($State.ExcludeFileType -join ', '))
    }
    Write-Info2 ("SavedSpace           : {0} GB" -f $State.SavedSpaceGB)

    if ($State.IsSafe) {
        Write-Ok "Configuration is SAFE for running VMs."
    }
    elseif (-not $State.Enabled) {
        Write-Warn2 "Deduplication is present but not Enabled on this volume."
    }
    else {
        foreach ($i in $State.Issues) { Write-Bad $i }
    }
}

function Import-DedupModuleNative {
    # On PS7 the Deduplication module is edition-flagged 'Desktop' and loads through a
    # WinPSCompatSession remoting proxy by default. That proxy DESERIALIZES objects and
    # mis-binds [bool] parameters -- e.g. 'Set-DedupVolume -OptimizeInUseFiles $false'
    # fails with 'A positional parameter cannot be found that accepts argument False'.
    # -SkipEditionCheck loads the (CIM/CDXML-backed) module natively in-process, which
    # binds bool params correctly AND removes the WinPSCompat warning. Fall back to the
    # default (compat) import if the native load isn't possible.
    if (Get-Module -Name Deduplication) { return }
    try {
        Import-Module Deduplication -SkipEditionCheck -ErrorAction Stop -WarningAction SilentlyContinue
    }
    catch {
        Import-Module Deduplication -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }
}

function Assert-DedupAvailable {
    if (Get-Command -Name Get-DedupVolume -ErrorAction SilentlyContinue) {
        Import-DedupModuleNative
        return
    }

    Write-Warn2 "Deduplication cmdlets not found. Attempting to install the FS-Data-Deduplication feature..."
    if (-not (Get-Command -Name Install-WindowsFeature -ErrorAction SilentlyContinue)) {
        throw "Data Deduplication is a Windows Server role and is not available on this host (Install-WindowsFeature not present)."
    }

    $r = Install-WindowsFeature -Name FS-Data-Deduplication -IncludeManagementTools
    if ($r -and $r.RestartNeeded -and $r.RestartNeeded.ToString() -ne 'No') {
        Write-Warn2 "The dedup feature install reports a reboot is required to fully activate."
    }
    Import-DedupModuleNative
    if (-not (Get-Command -Name Get-DedupVolume -ErrorAction SilentlyContinue)) {
        throw "Failed to load the Deduplication module after installing FS-Data-Deduplication."
    }
    Write-Ok "FS-Data-Deduplication feature installed."
}

# ---------------------------------------------------------------------------

Write-Head "MemLabs Data Deduplication manager"

if ($Disable -and ($Optimize -or $Scrub)) {
    throw "-Disable cannot be combined with -Optimize or -Scrub."
}
if ($Unoptimize -and -not $Disable) {
    throw "-Unoptimize is only valid together with -Disable."
}

$vol = Resolve-VmVolume -Requested $Volume
if (-not $vol) {
    throw "Could not auto-detect a VM-storage volume (no fixed drive contains a 'VirtualMachines' folder). Pass -Volume, e.g. -Volume E:"
}
if (-not (Test-Path ($vol + '\'))) {
    throw "Volume '$vol' does not exist or is not accessible."
}
Write-Info2 "Target volume: $vol"

# ReFS shares base-image blocks natively via block cloning, with no chunk store that
# can rot independently of the files pointing at it. Layering dedup on top is
# redundant and reintroduces exactly the corruption class ReFS avoids.
$volFsType = $null
try { $volFsType = (Get-Volume -DriveLetter $vol.TrimEnd(':') -ErrorAction Stop).FileSystemType } catch {}
if ($volFsType -and $volFsType -ne 'NTFS') {
    Write-Warn2 "$vol is $volFsType, not NTFS."
    if (-not ($CheckOnly -or $Disable)) {
        Write-Bad "Refusing to enable deduplication on a $volFsType volume. Re-run with -CheckOnly to inspect, or -Disable to turn dedup off."
        exit 2
    }
    Write-Info2 "Continuing: -CheckOnly / -Disable are read-only or cleanup paths."
}

Assert-DedupAvailable

$before = Get-DedupSafety -Vol $vol
Show-DedupState -Title "Current state" -State $before

# --- Check-only ------------------------------------------------------------
if ($CheckOnly) {
    Write-Head "Result"
    if ($before.IsSafe) {
        Write-Ok "SAFE - no action needed."
        exit 0
    }
    if (-not $before.Enabled) {
        Write-Warn2 "Dedup is not enabled on $vol. Run without -CheckOnly to enable it with safe settings."
    }
    else {
        Write-Bad "UNSAFE - run without -CheckOnly to remediate to safe settings."
    }
    exit 2
}

# --- Disable ---------------------------------------------------------------
if ($Disable) {
    Write-Head "Disabling deduplication on $vol"

    try {
        $running = Get-DedupJob -Volume $vol -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }
        foreach ($job in $running) {
            Write-Info2 "Stopping running $($job.Type) job..."
            Stop-DedupJob -Volume $vol -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch { Write-Warn2 "Could not enumerate/stop running jobs: $($_.Exception.Message)" }

    if ($Unoptimize) {
        $free = 0
        try { $free = (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$vol'").FreeSpace } catch { $free = 0 }
        $freeGB = [math]::Round(($free / 1GB), 1)
        Write-Warn2 "Rehydration (-Unoptimize) needs ~$($before.SavedSpaceGB) GB to undo dedup; free space now: $freeGB GB."
        if ($free -gt 0 -and ($before.SavedSpaceGB * 1GB) -gt $free) {
            throw "Not enough free space on $vol to rehydrate ($($before.SavedSpaceGB) GB needed, $freeGB GB free). Free space first, then retry."
        }
        Write-Info2 "Starting Unoptimization job (background). This is I/O heavy; monitor with: Get-DedupJob -Volume $vol"
        Start-DedupJob -Volume $vol -Type Unoptimization -Priority Normal | Out-Null
    }

    try {
        Disable-DedupVolume -Volume $vol -ErrorAction Stop
        Write-Ok "Disable-DedupVolume completed (future optimization stopped)."
    }
    catch { Write-Warn2 "Disable-DedupVolume: $($_.Exception.Message)" }

    try {
        Get-DedupSchedule -ErrorAction SilentlyContinue | ForEach-Object {
            Set-DedupSchedule -Name $_.Name -Enabled:$false -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Ok "Dedup schedules disabled."
    }
    catch { Write-Warn2 "Could not disable schedules: $($_.Exception.Message)" }

    if (-not $Unoptimize) {
        Write-Info2 "Existing files remain deduped and readable. To fully rehydrate later, re-run with -Disable -Unoptimize."
    }

    Show-DedupState -Title "Final state" -State (Get-DedupSafety -Vol $vol)
    exit 0
}

# --- Enable + apply safe settings -----------------------------------------
Write-Head "Enabling deduplication with SAFE settings on $vol"

if (-not $before.Enabled) {
    Write-Info2 "Enabling dedup (UsageType Default -- has safe defaults)..."
    Enable-DedupVolume -Volume $vol -UsageType Default | Out-Null
}
else {
    Write-Info2 "Dedup already enabled (UsageType $($before.UsageType)); overriding the risky flags explicitly."
}

# Explicit flag overrides win regardless of UsageType preset.
# Use -Param:$false colon syntax so the [bool] value binds correctly even if the
# module was loaded through the WinPS compat proxy (bare '$false' binds positionally).
try {
    Set-DedupVolume -Volume $vol `
        -OptimizeInUseFiles:$false `
        -OptimizePartialFiles:$false `
        -MinimumFileAgeDays $MinimumFileAgeDays `
        -ExcludeFileType 'iso' -ErrorAction Stop | Out-Null
    Write-Ok "Applied: OptimizeInUseFiles=False, OptimizePartialFiles=False, MinimumFileAgeDays=$MinimumFileAgeDays, ExcludeFileType=iso"
}
catch {
    Write-Bad "Set-DedupVolume failed: $($_.Exception.Message)"
}

# Make sure the maintenance schedules are on so savings are actually realized.
try {
    Get-DedupSchedule -ErrorAction SilentlyContinue | ForEach-Object {
        Set-DedupSchedule -Name $_.Name -Enabled:$true -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Ok "Dedup schedules enabled."
}
catch { Write-Warn2 "Could not enable schedules: $($_.Exception.Message)" }

$after = Get-DedupSafety -Vol $vol
Show-DedupState -Title "New state" -State $after

if ($Optimize) {
    Write-Info2 "Starting background Optimization job (monitor with: Get-DedupJob -Volume $vol)..."
    Start-DedupJob -Volume $vol -Type Optimization -Priority Normal | Out-Null
}
if ($Scrub) {
    Write-Info2 "Starting full Scrubbing job to hunt for latent corruption (monitor with: Get-DedupJob -Volume $vol)..."
    Start-DedupJob -Volume $vol -Type Scrubbing -Full | Out-Null
}

Write-Head "Result"
if ($after.IsSafe) {
    Write-Ok "SAFE - dedup is enabled and configured to skip running VMs' disks."
    exit 0
}
else {
    Write-Bad "Settings did not verify as safe. Review the issues above."
    exit 2
}
