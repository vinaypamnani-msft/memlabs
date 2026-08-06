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
    $r = [pscustomobject]@{ Available = $false; Reason = ''; Distro = $null }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        $r.Reason = 'wsl.exe not present'; return $r
    }
    # Without this wsl emits UTF-16 and every captured string looks empty.
    $env:WSL_UTF8 = '1'
    try {
        $help = & wsl.exe --help 2>&1
        if (("$help" -join ' ') -notmatch '--mount') { $r.Reason = 'this wsl.exe has no --mount support'; return $r }
        $all = @(& wsl.exe -l -q 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($all.Count -eq 0) { $r.Reason = 'WSL present but no distro installed (--mount mounts INTO a distro)'; return $r }
        # docker-desktop* are the default distro on many hosts but ship a busybox
        # userland with no usable tar/lsblk; prefer a real distro when one exists.
        $real = $all | Where-Object { $_ -notmatch '^docker-desktop' } | Select-Object -First 1
        if (-not $real) { $r.Reason = "only docker-desktop distro(s) present ($($all -join ', ')); no usable userland"; return $r }
        $r.Available = $true
        $r.Distro = $real
        $r.Reason = "distro '$real'"
    }
    catch { $r.Reason = "wsl probe failed: $($_.Exception.Message)" }
    return $r
}

function Copy-LinuxRootLogViaWsl {
    # Reads the ext4 root that Windows cannot: attach the VHDX bare, mount the
    # biggest ext4 partition read-only, copy the logs the ESP loggrab never gets
    # when cloud-init dies before runcmd.
    param([string]$VhdPath, [string]$WindowsDestination, [string]$Distro)

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
    # Per-VM mount point: two of these running at once would otherwise stack on the
    # same path and one script's umount would yank the other's filesystem.
    $tag = (Split-Path $WindowsDestination -Leaf) -replace '[^A-Za-z0-9._-]', '_'
    $mountPoint = "/mnt/memlabs-diag-$tag"
    $attached = $false
    try {
        & wsl.exe --mount "$VhdPath" --vhd --bare 2>&1 | ForEach-Object { Write-Host "  wsl> $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { Write-Host "  wsl --mount failed (needs an elevated shell); skipping ext4 collection." -ForegroundColor Yellow; return }
        $attached = $true

        # lsblk lists the WSL distro's OWN disks alongside the attached VHDX, and
        # WSL's root is a large ext4 -- picking "largest ext4" grabs /dev/sd? that is
        # already mounted on /. Require an unmounted partition. -P is used because
        # raw mode collapses the empty MOUNTPOINT field and misaligns the columns.
        $rows = @(& wsl.exe -d $Distro -u root -- lsblk -Pno NAME,FSTYPE,SIZE,MOUNTPOINT,TYPE 2>$null)
        $toBytes = {
            param($s)
            # lsblk prints 20G / 512M / 1.5T -- a plain string sort puts "9G" above "20G".
            if ("$s" -notmatch '^([\d.]+)([KMGTP]?)') { return 0 }
            $mult = @{ '' = 1; 'K' = 1KB; 'M' = 1MB; 'G' = 1GB; 'T' = 1TB; 'P' = 1PB }[$Matches[2]]
            return [double]$Matches[1] * $mult
        }
        $cands = foreach ($row in $rows) {
            $f = @{}
            foreach ($m in [regex]::Matches("$row", '(\w+)="([^"]*)"')) { $f[$m.Groups[1].Value] = $m.Groups[2].Value }
            if ($f['FSTYPE'] -ne 'ext4') { continue }
            if ($f['MOUNTPOINT']) { continue }
            [pscustomobject]@{ Name = $f['NAME']; Type = $f['TYPE']; Bytes = (& $toBytes $f['SIZE']) }
        }
        $root = $cands | Sort-Object @{ e = { $_.Type -eq 'part' } }, Bytes -Descending | Select-Object -First 1
        if (-not $root) {
            Write-Host "  no unmounted ext4 partition found on the attached disk; skipping." -ForegroundColor Yellow
            $rows | Select-Object -First 14 | ForEach-Object { Write-Host "    lsblk> $_" -ForegroundColor DarkGray }
            return
        }
        $dev = '/dev/' + $root.Name
        Write-Host "  ext4 root: $dev ($($root.Type), $([math]::Round($root.Bytes / 1GB, 1)) GB)" -ForegroundColor Green

        & wsl.exe -d $Distro -u root -- mkdir -p $mountPoint 2>&1 | Out-Null
        # noload skips journal replay on a fs that was force-stopped mid-write.
        & wsl.exe -d $Distro -u root -- mount -o ro,noload $dev $mountPoint 2>&1 | ForEach-Object { Write-Host "  wsl> $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            & wsl.exe -d $Distro -u root -- mount -o ro $dev $mountPoint 2>&1 | ForEach-Object { Write-Host "  wsl> $_" -ForegroundColor DarkGray }
            if ($LASTEXITCODE -ne 0) { Write-Host "  mount failed; skipping ext4 collection." -ForegroundColor Yellow; return }
        }

        try {
            # Generated as a file rather than passed to `sh -c`: the quoting survives
            # intact, and it must be LF -- CRLF makes sh fail on every line.
            $sh = @'
#!/bin/sh
MP="$1"; OUT="$2/rootfs"
mkdir -p "$OUT/loose"
{
  echo "collected(UTC): $(date -u)"
  echo "=== os-release ==="; cat "$MP/etc/os-release" 2>/dev/null
  echo "=== lsblk ==="; lsblk -f 2>/dev/null
  echo "=== cloud-init modules that COMPLETED (sem) ==="; ls -la "$MP/var/lib/cloud/sem" 2>/dev/null
  echo "=== cloud-init instance dir ==="; ls -la "$MP/var/lib/cloud/instance/" 2>/dev/null
  echo "=== netplan ==="; ls -la "$MP/etc/netplan" 2>/dev/null; cat "$MP"/etc/netplan/* 2>/dev/null
  echo "=== ssh host keys (absent => sshd cannot start) ==="; ls -la "$MP/etc/ssh" 2>/dev/null
  echo "=== authorized_keys ==="; find "$MP/home" "$MP/root" -name authorized_keys -exec ls -la {} \; -exec cat {} \; 2>/dev/null
  echo "=== fstab ==="; cat "$MP/etc/fstab" 2>/dev/null
  echo "=== hostname/hosts/resolv ==="; cat "$MP/etc/hostname" "$MP/etc/hosts" "$MP/etc/resolv.conf" 2>/dev/null
  echo "=== enabled units ==="; ls -la "$MP/etc/systemd/system/multi-user.target.wants" 2>/dev/null
} > "$OUT/00-manifest.txt" 2>&1

for d in etc var/log var/lib/cloud root home boot; do
  if [ -e "$MP/$d" ]; then
    n=$(echo "$d" | tr / -)
    printf '  %-14s %6s ... ' "$d" "$(du -sh "$MP/$d" 2>/dev/null | cut -f1)"
    tar czf "$OUT/$n.tar.gz" -C "$MP" "$d" 2>/dev/null
    echo "-> $n.tar.gz $(du -h "$OUT/$n.tar.gz" 2>/dev/null | cut -f1)"
  fi
done

for f in var/log/cloud-init.log var/log/cloud-init-output.log var/log/syslog \
         var/log/kern.log var/log/auth.log var/log/dpkg.log var/log/dmesg \
         etc/hostname etc/fstab etc/resolv.conf etc/ssh/sshd_config; do
  [ -f "$MP/$f" ] && cp -f "$MP/$f" "$OUT/loose/$(echo "$f" | tr / -)" 2>/dev/null
done
cp -f "$MP"/var/lib/cloud/instance/user-data.txt "$OUT/loose/" 2>/dev/null
find "$MP/var/lib/cloud/seed" -type f -exec cp -f {} "$OUT/loose/" \; 2>/dev/null
echo "  loose files: $(ls -1 "$OUT/loose" 2>/dev/null | wc -l)"
'@
            $shPath = Join-Path $WindowsDestination 'collect.sh'
            [System.IO.File]::WriteAllText($shPath, ($sh -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
            # Deliberately NOT piped: through a pipe sh block-buffers stdout and the
            # whole (slow) collection looks hung until it finishes.
            & wsl.exe -d $Distro -u root -- sh "$wslDest/collect.sh" "$mountPoint" "$wslDest"
            Remove-Item $shPath -ErrorAction SilentlyContinue
        }
        finally {
            & wsl.exe -d $Distro -u root -- umount $mountPoint 2>&1 | Out-Null
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
    # Script lives in vmbuild\tools, logs live in vmbuild\logs.
    $Destination = Join-Path (Split-Path $PSScriptRoot -Parent) "logs\linux-diag\$VmName"
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
        # Not fatal: Windows only sees the ESP if it got a drive letter, and the ext4
        # collection is the real payload anyway.
        Write-Host "ESP not readable from Windows (FAT32 partition got no drive letter)." -ForegroundColor Yellow
        Write-Host "Continuing -- the WSL ext4 collection below is the real payload." -ForegroundColor Yellow
    }
    else {
        Write-Host "ESP: $espDrive" -ForegroundColor Green
        $memlabsDir = Join-Path $espDrive 'memlabs'
        if (-not (Test-Path $memlabsDir)) {
            Write-Host "No \memlabs\ folder on ESP -- loggrab never ran (cloud-init likely failed before runcmd)." -ForegroundColor Red
            Get-ChildItem $espDrive | ForEach-Object { Write-Host "  $($_.Name)" }
        }
        else {
            Write-Host "Copying $memlabsDir -> $Destination" -ForegroundColor Cyan
            Copy-Item -Path (Join-Path $memlabsDir '*') -Destination $Destination -Recurse -Force
            Get-ChildItem $Destination | ForEach-Object {
                Write-Host ("  {0,-30} {1,10:N0} bytes" -f $_.Name, $_.Length) -ForegroundColor Gray
            }
        }
    }
}
finally {
    if ($mounted) {
        try { Dismount-VHD -Path $vhdPath -ErrorAction Stop } catch { Write-Host "Dismount failed: $_" -ForegroundColor Red }
    }

    # Host-side artifacts die with the VM too, so bank them regardless of WSL.
    try {
        $serial = Join-Path (Split-Path $PSScriptRoot -Parent) "logs\linux-serial\$VmName.log"
        if (Test-Path $serial) {
            Copy-Item $serial (Join-Path $Destination "serial-console.log") -Force
            Write-Host "Saved serial console capture ($((Get-Item $serial).Length) bytes)." -ForegroundColor Green
        }
        else { Write-Host "No serial capture at $serial." -ForegroundColor DarkGray }

        $vmNow = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($vmNow) {
            $vmNow | Select-Object * | Format-List | Out-File (Join-Path $Destination 'vm-config.txt') -Encoding utf8
            $vmNow | Get-VMNetworkAdapter | Format-List * | Out-File (Join-Path $Destination 'vm-config.txt') -Append -Encoding utf8
            $vmNow.Notes | Out-File (Join-Path $Destination 'vm-notes.txt') -Encoding utf8
        }
    }
    catch { Write-Host "Host-side artifact collection failed: $($_.Exception.Message)" -ForegroundColor Yellow }

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
        Copy-LinuxRootLogViaWsl -VhdPath $vhdPath -WindowsDestination $Destination -Distro $wsl.Distro
    }

    if ($weStopped -and $RestartAfter) {
        Write-Host "Restarting $VmName ..." -ForegroundColor Yellow
        Start-VM -Name $VmName
    }

    $got = @(Get-ChildItem $Destination -Recurse -File -ErrorAction SilentlyContinue)
    $mb = [math]::Round((($got | Measure-Object Length -Sum).Sum / 1MB), 1)
    if ($got.Count) {
        Write-Host "`nCollected $($got.Count) file(s), $mb MB -> $Destination" -ForegroundColor Green
        $got | Sort-Object Length -Descending | Select-Object -First 12 |
            ForEach-Object { Write-Host ("  {0,-34} {1,9:N0} KB" -f $_.Name, ($_.Length / 1KB)) -ForegroundColor Gray }
    }
    else { Write-Host "`nNOTHING COLLECTED -> $Destination" -ForegroundColor Red }
}
