<#
.SYNOPSIS
    Extract cloud-init / system logs from a memlabs Linux VM's EFI System
    Partition without booting the guest.

.DESCRIPTION
    cloud-init's memlabs-loggrab.service copies key diagnostic files to
    /boot/efi/memlabs/ on every boot. The ESP is FAT32 and readable by
    Windows directly via Mount-VHD -- no ext4/WSL required.

    This script:
        1. Stops the VM if running (read-only mount is safer with VM off)
        2. Mounts the OS VHDX read-only
        3. Locates the ESP (FAT/FAT32 partition with \EFI\Boot present)
        4. Copies the \memlabs\ folder to a host destination
        5. Dismounts and (optionally) restarts the VM

    Pair this with Get-LinuxSerialTap.ps1 (live console capture) for full
    post-mortem coverage when cloud-init or the guest networking fails.

.PARAMETER VmName
    The Hyper-V VM name.

.PARAMETER Destination
    Folder to copy logs into. Defaults to vmbuild\logs\linux-diag\<VmName>\.

.PARAMETER LeaveRunning
    Don't auto-stop/start the VM. The script will only mount if the VM is
    already powered off (a running VM holds a write lock on the VHDX).

.PARAMETER RestartAfter
    Start the VM again after extraction (only meaningful if we stopped it).

.EXAMPLE
    .\Get-LinuxVmDiagnostics.ps1 -VmName ADA-PROXY1 -RestartAfter
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$Destination,

    [Parameter(Mandatory = $false)]
    [switch]$LeaveRunning,

    [Parameter(Mandatory = $false)]
    [switch]$RestartAfter
)

$ErrorActionPreference = 'Stop'

function Get-WslMountCapability {
    # wsl.exe ships with Windows as a stub even when WSL is not installed, so its
    # mere presence proves nothing -- `wsl --mount` needs a real WSL2 distro to
    # mount into. Report a reason either way so a skip is never mysterious.
    $r = [pscustomobject]@{ Available = $false; Reason = '' }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        $r.Reason = 'wsl.exe not present'; return $r
    }
    # Without this wsl emits UTF-16 and every captured string looks empty.
    $env:WSL_UTF8 = '1'
    try {
        $help = & wsl.exe --help 2>&1
        if (("$help" -join ' ') -notmatch '--mount') { $r.Reason = 'this wsl.exe has no --mount support'; return $r }
        $distros = @(& wsl.exe -l -q 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($distros.Count -eq 0) { $r.Reason = 'WSL present but no distro installed (--mount mounts INTO a distro)'; return $r }
        $r.Available = $true
        $r.Reason = "distro '$($distros[0])'"
    }
    catch { $r.Reason = "wsl probe failed: $($_.Exception.Message)" }
    return $r
}

function Copy-LinuxRootLogViaWsl {
    # Reads the ext4 root that Windows cannot: attach the VHDX bare, mount the
    # biggest ext4 partition read-only, copy the logs the ESP loggrab never gets
    # when cloud-init dies before runcmd.
    param([string]$VhdPath, [string]$WindowsDestination)

    # Pin this off: with it on (PS7.4+ hosts can default it on, or a profile can set
    # it), a non-zero wsl.exe exit throws past the explicit $LASTEXITCODE checks below
    # and turns a precise "mount failed, needs elevation" into a generic catch.
    $PSNativeCommandUseErrorActionPreference = $false

    # WSL auto-mounts local drives under /mnt/<letter>; a UNC destination has no
    # such mapping, so bail rather than build a path that silently goes nowhere.
    if ($WindowsDestination -notmatch '^[A-Za-z]:\\') {
        Write-Host "  destination '$WindowsDestination' is not a local drive path; skipping ext4 collection." -ForegroundColor Yellow
        return
    }
    $wslDest = '/mnt/' + $WindowsDestination.Substring(0, 1).ToLower() + ($WindowsDestination.Substring(2) -replace '\\', '/')
    $mountPoint = '/mnt/memlabs-diag'
    $attached = $false
    try {
        & wsl.exe --mount "$VhdPath" --vhd --bare 2>&1 | ForEach-Object { Write-Host "  wsl> $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { Write-Host "  wsl --mount failed (needs an elevated shell); skipping ext4 collection." -ForegroundColor Yellow; return }
        $attached = $true

        # Pick the largest ext4 partition -- that is the root fs on the cloud image.
        $lsblk = @(& wsl.exe -u root -- lsblk -rno NAME,FSTYPE,SIZE 2>$null)
        $toBytes = {
            param($s)
            # lsblk prints 20G / 512M / 1.5T -- a plain string sort puts "9G" above "20G".
            if ("$s" -notmatch '^([\d.]+)([KMGTP]?)') { return 0 }
            $mult = @{ '' = 1; 'K' = 1KB; 'M' = 1MB; 'G' = 1GB; 'T' = 1TB; 'P' = 1PB }[$Matches[2]]
            return [double]$Matches[1] * $mult
        }
        $root = $lsblk | Where-Object { $_ -match '\sext4\s' } |
            Sort-Object { & $toBytes ([regex]::Match($_, 'ext4\s+(\S+)').Groups[1].Value) } -Descending |
            Select-Object -First 1
        if (-not $root) {
            Write-Host "  no ext4 partition found on the attached disk; skipping." -ForegroundColor Yellow
            $lsblk | Select-Object -First 12 | ForEach-Object { Write-Host "    lsblk> $_" -ForegroundColor DarkGray }
            return
        }
        $dev = '/dev/' + ($root -split '\s+')[0]
        Write-Host "  ext4 root: $dev" -ForegroundColor Green

        & wsl.exe -u root -- mkdir -p $mountPoint 2>&1 | Out-Null
        & wsl.exe -u root -- mount -o ro,noload $dev $mountPoint 2>&1 | ForEach-Object { Write-Host "  wsl> $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { Write-Host "  mount failed; skipping ext4 collection." -ForegroundColor Yellow; return }

        try {
            & wsl.exe -u root -- mkdir -p "$wslDest/rootfs" 2>&1 | Out-Null
            foreach ($src in @('var/log/cloud-init.log', 'var/log/cloud-init-output.log', 'var/log/syslog', 'var/log/memlabs-dpkg-guard.log')) {
                & wsl.exe -u root -- sh -c "test -f $mountPoint/$src && cp -f $mountPoint/$src $wslDest/rootfs/ && echo copied $src" 2>&1 |
                    ForEach-Object { if ("$_".Trim()) { Write-Host "    $_" -ForegroundColor Gray } }
            }
            # cloud-init's own verdict, if it got far enough to write one.
            & wsl.exe -u root -- sh -c "test -d $mountPoint/run/cloud-init && cp -f $mountPoint/run/cloud-init/*.json $wslDest/rootfs/ 2>/dev/null; true" 2>&1 | Out-Null
            & wsl.exe -u root -- sh -c "test -d $mountPoint/var/log/journal && tar czf $wslDest/rootfs/journal.tar.gz -C $mountPoint/var/log journal 2>/dev/null; true" 2>&1 | Out-Null
        }
        finally {
            & wsl.exe -u root -- umount $mountPoint 2>&1 | Out-Null
        }
    }
    catch {
        Write-Host "  ext4 collection failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    finally {
        if ($attached) { & wsl.exe --unmount "$VhdPath" 2>&1 | Out-Null }
    }
}

$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) { throw "VM '$VmName' not found." }

$osDisk = $vm.HardDrives | Where-Object { $_.Path -like '*_OS.vhdx' } | Select-Object -First 1
if (-not $osDisk) { $osDisk = $vm.HardDrives | Select-Object -First 1 }
if (-not $osDisk) { throw "VM '$VmName' has no hard disks attached." }
$vhdPath = $osDisk.Path
Write-Host "OS disk: $vhdPath" -ForegroundColor DarkGray

if (-not $Destination) {
    $Destination = Join-Path $PSScriptRoot "logs\linux-diag\$VmName"
}
if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
Write-Host "Destination: $Destination" -ForegroundColor DarkGray

$weStopped = $false
if ($vm.State -ne 'Off') {
    if ($LeaveRunning) {
        throw "VM is $($vm.State) and -LeaveRunning specified; cannot mount a locked VHDX. Stop the VM or omit -LeaveRunning."
    }
    Write-Host "Stopping $VmName ..." -ForegroundColor Yellow
    Stop-VM -Name $VmName -Force -ErrorAction Stop
    $weStopped = $true
}

$mounted = $null
try {
    $mounted = Mount-VHD -Path $vhdPath -ReadOnly -Passthru -ErrorAction Stop
    Start-Sleep -Milliseconds 500  # let Volume objects materialize

    $disk = $mounted | Get-Disk
    $parts = $disk | Get-Partition
    Write-Host "Found $($parts.Count) partition(s) on mounted VHDX:" -ForegroundColor DarkGray
    foreach ($p in $parts) {
        $vol = $p | Get-Volume -ErrorAction SilentlyContinue
        $fs = if ($vol) { $vol.FileSystemType } else { '?' }
        $dl = if ($vol -and $vol.DriveLetter) { "$($vol.DriveLetter):" } else { '(no letter)' }
        Write-Host ("  Part {0}: {1,-6} {2,-10} size={3:N0} MB" -f $p.PartitionNumber, $dl, $fs, ($p.Size / 1MB)) -ForegroundColor DarkGray
    }

    # ESP = FAT/FAT32, has \EFI\ folder. On Ubuntu cloudimg layout it's typically partition 15.
    $espDrive = $null
    foreach ($p in $parts) {
        $vol = $p | Get-Volume -ErrorAction SilentlyContinue
        if (-not $vol -or -not $vol.DriveLetter) { continue }
        if ($vol.FileSystemType -notmatch 'FAT') { continue }
        $candidate = "$($vol.DriveLetter):\"
        if (Test-Path (Join-Path $candidate 'EFI')) {
            $espDrive = $candidate
            break
        }
    }

    if (-not $espDrive) {
        Write-Host "Could not locate ESP. Listing all drive contents:" -ForegroundColor Red
        foreach ($p in $parts) {
            $vol = $p | Get-Volume -ErrorAction SilentlyContinue
            if ($vol -and $vol.DriveLetter) {
                Write-Host "  $($vol.DriveLetter):\ ->" -ForegroundColor Yellow
                Get-ChildItem "$($vol.DriveLetter):\" -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { Write-Host "    $($_.Name)" }
            }
        }
        throw "ESP not found on mounted VHDX."
    }

    Write-Host "ESP: $espDrive" -ForegroundColor Green
    $memlabsDir = Join-Path $espDrive 'memlabs'
    if (-not (Test-Path $memlabsDir)) {
        Write-Host "No \memlabs\ folder on ESP -- loggrab never ran (cloud-init likely failed before runcmd)." -ForegroundColor Red
        Write-Host "Copying \EFI\ layout instead for reference:" -ForegroundColor Yellow
        Get-ChildItem $espDrive | ForEach-Object { Write-Host "  $($_.Name)" }
    }
    else {
        Write-Host "Copying $memlabsDir -> $Destination" -ForegroundColor Cyan
        Copy-Item -Path (Join-Path $memlabsDir '*') -Destination $Destination -Recurse -Force
        Get-ChildItem $Destination | ForEach-Object {
            Write-Host ("  {0,-30} {1,10:N0} bytes" -f $_.Name, $_.Length) -ForegroundColor Gray
        }
        Write-Host "`nDone. Logs at: $Destination" -ForegroundColor Green
    }
}
finally {
    if ($mounted) {
        try { Dismount-VHD -Path $vhdPath -ErrorAction Stop } catch { Write-Host "Dismount failed: $_" -ForegroundColor Red }
    }

    # The ESP copy above only works if loggrab ran, which needs cloud-init to reach
    # runcmd -- exactly what fails in the case worth diagnosing. The real logs are on
    # the ext4 root, which Windows cannot read, so use WSL when it is usable. Must
    # come AFTER Dismount-VHD: Windows and WSL cannot both hold the VHDX.
    $wsl = Get-WslMountCapability
    if (-not $wsl.Available) {
        Write-Host "Skipping ext4 log collection -- $($wsl.Reason)." -ForegroundColor DarkGray
    }
    else {
        Write-Host "Collecting ext4 root logs via WSL ($($wsl.Reason)) ..." -ForegroundColor Cyan
        Copy-LinuxRootLogViaWsl -VhdPath $vhdPath -WindowsDestination $Destination
    }

    if ($weStopped -and $RestartAfter) {
        Write-Host "Restarting $VmName ..." -ForegroundColor Yellow
        Start-VM -Name $VmName
    }
}
