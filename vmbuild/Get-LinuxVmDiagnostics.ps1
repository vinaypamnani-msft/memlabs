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
    if ($weStopped -and $RestartAfter) {
        Write-Host "Restarting $VmName ..." -ForegroundColor Yellow
        Start-VM -Name $VmName
    }
}
