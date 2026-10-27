# New-LinuxBaseImage.ps1
# Builds the Ubuntu Server cloud-image VHDX consumed by memlabs Linux VMs
# (Proxy role, etc.). The cloud image ships as a qcow2; we convert it to
# VHDX via qemu-img and resize to leave room for installed packages and
# logs. Output lands at $Common.AzureImagePath\<VhdxFileName>, matching
# the catalog entry in azureFiles\_filelist[_develop].json.
#
# Re-run safe: skips download / convert when artefacts already exist.
# Pass -ForceDownload or -ForceNewVhdx to rebuild.
#
# -Desktop: switch builds a SECOND VHDX (UbuntuDesktop2404.vhdx) that
# additionally bakes in `ubuntu-desktop-minimal` + GDM3 + NetworkManager
# + xrdp on top of the same Ubuntu cloud image. Used by the LinuxClient
# role to provision a true Ubuntu Desktop workstation suitable for MDM /
# EDR testing (Intune for Linux, Defender for Endpoint, etc.). Server and
# Desktop VHDX outputs coexist; pick which one(s) to build by running this
# script once per variant.
#
# Required tooling: qemu-img.exe. Looked up in this order:
#   1. $Common.AzureToolsPath\qemu\qemu-img.exe          (vendored)
#   2. qemu-img.exe on PATH
#   3. C:\Program Files\qemu\qemu-img.exe                (default installer location)
# If not found, the script logs a clear failure with the install hint.

param (
    [Parameter(Mandatory = $false, HelpMessage = "Ubuntu release codename. Currently only 'noble' (24.04 LTS) is supported.")]
    [ValidateSet("noble")]
    [string]$Release = "noble",

    [Parameter(Mandatory = $false, HelpMessage = "Build the Ubuntu Desktop variant (UbuntuDesktop2404.vhdx). Overrides -VhdxFileName and bumps -DiskSizeGB / -BakeTimeoutMinutes defaults if those weren't explicitly set.")]
    [switch]$Desktop,

    [Parameter(Mandatory = $false, HelpMessage = "Output VHDX filename, written to azureFiles\os. Defaults to UbuntuServer2404.vhdx, or UbuntuDesktop2404.vhdx when -Desktop is set.")]
    [string]$VhdxFileName,

    [Parameter(Mandatory = $false, HelpMessage = "Final size of the output VHDX in GB. Defaults to 30 (Server) / 50 (Desktop).")]
    [ValidateRange(8, 256)]
    [int]$DiskSizeGB,

    [Parameter(Mandatory = $false, HelpMessage = "Force re-download of the upstream qcow2 source image.")]
    [switch]$ForceDownload,

    [Parameter(Mandatory = $false, HelpMessage = "Force re-convert and overwrite the existing output VHDX.")]
    [switch]$ForceNewVhdx,

    [Parameter(Mandatory = $false, HelpMessage = "Skip SHA256 verification of the downloaded qcow2 (not recommended).")]
    [switch]$SkipChecksum,

    [Parameter(Mandatory = $false, HelpMessage = "Path to qemu-img.exe. Overrides the auto-discovery search order.")]
    [string]$QemuImgPath,

    [Parameter(Mandatory = $false, HelpMessage = "Skip the first-boot bake (apt install of Hyper-V daemons + qemu-guest-agent). Use when iterating on conversion logic.")]
    [switch]$SkipBake,

    [Parameter(Mandatory = $false, HelpMessage = "Hyper-V switch name for the bake VM. Must have outbound internet.")]
    [string]$BakeSwitchName = 'Default Switch',

    [Parameter(Mandatory = $false, HelpMessage = "Wall-clock timeout for the bake VM. Defaults to 30 min (Server) / 90 min (Desktop: GNOME + Edge + Intune + dash-to-panel + system updates).")]
    [ValidateRange(5, 240)]
    [int]$BakeTimeoutMinutes
)

# Apply Desktop-variant defaults for any parameters the caller didn't explicitly
# set. Done in code (rather than as Param defaults) so explicit values still win.
$bakeVariant = if ($Desktop.IsPresent) { 'Desktop' } else { 'Server' }
if (-not $PSBoundParameters.ContainsKey('VhdxFileName')) {
    $VhdxFileName = if ($Desktop.IsPresent) { 'UbuntuDesktop2404.vhdx' } else { 'UbuntuServer2404.vhdx' }
}
if (-not $PSBoundParameters.ContainsKey('DiskSizeGB') -or $DiskSizeGB -eq 0) {
    $DiskSizeGB = if ($Desktop.IsPresent) { 50 } else { 30 }
}
if (-not $PSBoundParameters.ContainsKey('BakeTimeoutMinutes') -or $BakeTimeoutMinutes -eq 0) {
    # Desktop: SSH-driven bake installs GNOME + Edge + Intune + dash-to-panel +
    # system updates + validation; 90 min accommodates slow mirrors.
    # Server: 30 min covers the service-trim (snapd purge) and sshd-hardening
    # steps added alongside the boot-time work.
    $BakeTimeoutMinutes = if ($Desktop.IsPresent) { 90 } else { 30 }
}

# Check for admin rights (qemu-img doesn't strictly require it, but Hyper-V mounts later will)
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host
    Write-Host "This script must run as Administrator." -ForegroundColor Red
    Write-Host
    return
}

# Set Verbose
$enableVerbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# Dot source common
$RootPath = Split-Path -Path $PSScriptRoot -Parent
. $RootPath\Common.ps1 -VerboseEnabled:$enableVerbose

if ($Common.FatalError) {
    Write-Log "Critical Failure! $($Common.FatalError)" -Failure
    return
}

# ---------------------------------------------------------------------------
# 0. Host prerequisites (self-installing)
# ---------------------------------------------------------------------------
Write-Log "Checking host prerequisites..." -Activity

# Resize-VHD and the bake VM need Hyper-V. New-Lab installs it, but on a brand-new lab host
# this script can be the first thing ever run.
Install-HyperV

# The bake drives the temp VM over SSH.
$sshExeForBake = Get-OpenSshToolPath -Name 'ssh.exe'
if (-not $sshExeForBake) {
    Write-Log "The Windows OpenSSH Client is required to bake the image and could not be installed automatically. Install it (Settings > Apps > Optional features > OpenSSH Client) and re-run." -Failure
    return
}
Write-Log "Using ssh: $sshExeForBake" -LogOnly

# Optional: gives the seed ISO builder real YAML parsing instead of the regex heuristic.
if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    $yamlResult = Install-MemLabsModule -Name 'powershell-yaml'
    if ($yamlResult.Failed.Count -gt 0) {
        Write-Log "powershell-yaml could not be installed; user-data falls back to heuristic validation." -Warning
    }
}

# Release -> upstream image map. Only one release for now; extend by adding rows.
$releaseInfo = switch ($Release) {
    "noble" {
        [PSCustomObject]@{
            Codename      = "noble"
            Version       = "24.04"
            ImageFileName = "ubuntu-24.04-server-cloudimg-amd64.img"
            BaseUrl       = "https://cloud-images.ubuntu.com/releases/24.04/release"
        }
    }
}

$qcow2Url = "$($releaseInfo.BaseUrl)/$($releaseInfo.ImageFileName)"
$sha256Url = "$($releaseInfo.BaseUrl)/SHA256SUMS"

Write-Log "### START Linux base image build ($($releaseInfo.Codename) / $($releaseInfo.Version) / variant=$bakeVariant -> $VhdxFileName)." -Success
$timer = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# 1. Locate qemu-img.exe
# ---------------------------------------------------------------------------
Write-Log "Locating qemu-img.exe..." -Activity

$resolvedQemu = $null
$candidates = @()
if ($QemuImgPath) { $candidates += $QemuImgPath }
$candidates += (Join-Path $Common.AzureToolsPath "qemu\qemu-img.exe")
$onPath = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
if ($onPath) { $candidates += $onPath.Source }
$candidates += "C:\Program Files\qemu\qemu-img.exe"

foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate -PathType Leaf)) {
        $resolvedQemu = (Resolve-Path $candidate).Path
        break
    }
}

if (-not $resolvedQemu) {
    Write-Log "qemu-img.exe not found. Attempting install via winget (qemu.qemu)..." -Warning
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        try {
            # Force --source winget; the msstore source is often blocked on
            # locked-down corporate boxes and would otherwise fail the whole call.
            # No -e: some installs of the winget source require a looser match.
            & $winget.Source install --id qemu.qemu --source winget --accept-source-agreements --accept-package-agreements --silent
            if ($LASTEXITCODE -ne 0) {
                Write-Log "winget install returned exit code $LASTEXITCODE." -Warning
            }
        }
        catch {
            Write-Log "winget install threw: $_" -Warning
        }

        # Re-probe default install location and PATH (current session PATH won't pick up changes)
        $reProbe = @(
            "C:\Program Files\qemu\qemu-img.exe",
            (Join-Path ${env:ProgramFiles} 'qemu\qemu-img.exe')
        ) | Select-Object -Unique
        foreach ($candidate in $reProbe) {
            if (Test-Path $candidate -PathType Leaf) {
                $resolvedQemu = (Resolve-Path $candidate).Path
                Write-Log "qemu-img installed via winget: $resolvedQemu" -Success
                break
            }
        }
    }
    else {
        Write-Log "winget.exe not available on this system." -Warning
    }
}

if (-not $resolvedQemu) {
    # Fallback: download the latest qemu-w64-setup-YYYYMMDD.exe from weilnetz.de
    # and run it silently. NSIS installer supports /S for unattended install.
    Write-Log "Falling back to direct download from https://qemu.weilnetz.de/w64/ ..." -Warning
    try {
        $indexUrl = "https://qemu.weilnetz.de/w64/"
        $html = (Invoke-WebRequest -Uri $indexUrl -UseBasicParsing -ErrorAction Stop).Content
        $matches = [regex]::Matches($html, 'qemu-w64-setup-(\d{8})\.exe')
        if ($matches.Count -gt 0) {
            $latest = $matches | Sort-Object { [int]$_.Groups[1].Value } -Descending | Select-Object -First 1
            $installerName = $latest.Value
            $installerUrl = "$indexUrl$installerName"
            $installerPath = Join-Path $env:TEMP $installerName
            Write-Log "Downloading $installerUrl" -Activity
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
            Write-Log "Running $installerName /S (silent install)..." -Activity
            $proc = Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -ne 0) {
                Write-Log "Installer exited with code $($proc.ExitCode)." -Warning
            }
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            $defaultQemu = "C:\Program Files\qemu\qemu-img.exe"
            if (Test-Path $defaultQemu -PathType Leaf) {
                $resolvedQemu = (Resolve-Path $defaultQemu).Path
                Write-Log "qemu-img installed via weilnetz installer: $resolvedQemu" -Success
            }
        }
        else {
            Write-Log "Could not find qemu-w64-setup-*.exe in directory listing at $indexUrl." -Warning
        }
    }
    catch {
        Write-Log "Direct-download fallback failed: $_" -Warning
    }
}

if (-not $resolvedQemu) {
    Write-Log "qemu-img.exe not found." -Failure
    Write-Log "Install QEMU for Windows via 'winget install --id qemu.qemu'," -Failure
    Write-Log "or download from https://qemu.weilnetz.de/w64/ (any recent build is fine)," -Failure
    Write-Log "or drop qemu-img.exe (and its required DLLs) at: $(Join-Path $Common.AzureToolsPath 'qemu\qemu-img.exe')." -Failure
    return
}
Write-Log "Using qemu-img: $resolvedQemu"

# Quick sanity check
try {
    $qemuVersion = & $resolvedQemu --version 2>&1 | Select-Object -First 1
    Write-Log "qemu-img version: $qemuVersion"
}
catch {
    Write-Log "qemu-img.exe found at $resolvedQemu but failed to execute: $_" -Failure
    return
}

# ---------------------------------------------------------------------------
# 2. Decide whether to (re)build
# ---------------------------------------------------------------------------
$outputVhdx = Join-Path $Common.AzureImagePath $VhdxFileName
if ((Test-Path $outputVhdx) -and -not $ForceNewVhdx.IsPresent) {
    $existingSizeGB = [math]::Round((Get-Item $outputVhdx).Length / 1GB, 2)
    Write-Log "Output VHDX already exists: $outputVhdx ($existingSizeGB GB). Use -ForceNewVhdx to rebuild." -Warning
    return
}

# ---------------------------------------------------------------------------
# 3. Download qcow2 (cached in staging dir)
# ---------------------------------------------------------------------------
$linuxStagingDir = Join-Path $Common.StagingImagePath "linux"
if (-not (Test-Path $linuxStagingDir)) {
    New-Item -ItemType Directory -Path $linuxStagingDir -Force | Out-Null
}
$qcow2Path = Join-Path $linuxStagingDir $releaseInfo.ImageFileName

$needDownload = $ForceDownload.IsPresent -or -not (Test-Path $qcow2Path)
if ($needDownload) {
    Write-Log "Downloading cloud image: $qcow2Url" -Activity
    if (Test-Path $qcow2Path) { Remove-Item $qcow2Path -Force }
    try {
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # ~10x faster Invoke-WebRequest for large files
        Invoke-WebRequest -Uri $qcow2Url -OutFile $qcow2Path -UseBasicParsing
    }
    catch {
        Write-Log "Failed to download $qcow2Url`: $_" -Failure
        return
    }
    finally {
        $ProgressPreference = $oldProgress
    }
    $sizeMB = [math]::Round((Get-Item $qcow2Path).Length / 1MB, 1)
    Write-Log "Downloaded $sizeMB MB to $qcow2Path"
}
else {
    Write-Log "Reusing existing qcow2 at $qcow2Path (use -ForceDownload to refresh)."
}

# ---------------------------------------------------------------------------
# 4. Verify SHA256 against upstream SHA256SUMS
# ---------------------------------------------------------------------------
if (-not $SkipChecksum.IsPresent) {
    Write-Log "Verifying SHA256 against $sha256Url..." -Activity
    try {
        $sumsResponse = Invoke-WebRequest -Uri $sha256Url -UseBasicParsing
        # .Content can be byte[] when server sends application/octet-stream;
        # coerce to UTF-8 string in that case.
        if ($sumsResponse.Content -is [byte[]]) {
            $sumsText = [System.Text.Encoding]::UTF8.GetString($sumsResponse.Content)
        }
        else {
            $sumsText = [string]$sumsResponse.Content
        }
    }
    catch {
        Write-Log "Failed to fetch SHA256SUMS from $sha256Url`: $_" -Warning
        Write-Log "Continuing without checksum verification. Re-run with -SkipChecksum to silence this message." -Warning
        $sumsText = $null
    }

    if ($sumsText) {
        # Lines look like: "<hash>  *<filename>" (BSD style) or "<hash>  <filename>".
        # Match filename at end of line, optionally preceded by '*', anchored to avoid
        # partial hits on .manifest / .squashfs / etc.
        $escaped = [regex]::Escape($releaseInfo.ImageFileName)
        $expectedLine = $sumsText -split "`n" |
            Where-Object { $_ -match "^(?<hash>[0-9a-fA-F]{64})\s+\*?$escaped\s*$" } |
            Select-Object -First 1
        if (-not $expectedLine) {
            Write-Log "SHA256SUMS does not contain an entry for $($releaseInfo.ImageFileName). Aborting." -Failure
            Write-Log "First 200 chars of fetched content: $($sumsText.Substring(0, [Math]::Min(200, $sumsText.Length)))" -Failure
            return
        }
        $expectedHash = ($expectedLine -split '\s+')[0].ToLower()
        Write-Log "Computing SHA256 of downloaded image (this can take ~30s on slow disks)..."
        $actualHash = (Get-FileHash -Algorithm SHA256 -Path $qcow2Path).Hash.ToLower()
        if ($actualHash -ne $expectedHash) {
            Write-Log "SHA256 mismatch! expected=$expectedHash actual=$actualHash" -Failure
            Write-Log "The downloaded file is corrupt or upstream has rotated. Delete $qcow2Path and re-run with -ForceDownload." -Failure
            return
        }
        Write-Log "SHA256 OK ($actualHash)"
    }
}
else {
    Write-Log "Skipping SHA256 verification (-SkipChecksum)." -Warning
}

# ---------------------------------------------------------------------------
# 5. Convert qcow2 -> dynamic VHDX
# ---------------------------------------------------------------------------
# Use a temp filename next to the final output so the move is atomic.
# Resize-VHD requires the file to have a .vhd/.vhdx extension, so we can't
# append .partial; instead prefix the basename.
$tempVhdx = Join-Path $linuxStagingDir ("_partial_" + $VhdxFileName)

# Clean up any stale bake VMs from a previous interrupted run.  Ctrl+C can
# bypass the bake function's finally block, leaving an orphan VM that holds
# the _partial_ VHDX file lock.  Must happen here (before Remove-Item) rather
# than inside Invoke-LinuxBaseImageBake, because the lock blocks us before we
# even reach the bake call.
$staleVMs = @(Get-VM -Name 'memlabs-bake-*' -ErrorAction SilentlyContinue)
foreach ($staleVM in $staleVMs) {
    Write-Log "Removing stale bake VM '$($staleVM.Name)' (state=$($staleVM.State))." -Warning
    if ($staleVM.State -ne 'Off') {
        Stop-VM -VM $staleVM -TurnOff -Force -ErrorAction SilentlyContinue
    }
    Remove-VM -VM $staleVM -Force -ErrorAction SilentlyContinue
}

if (Test-Path $tempVhdx) { Remove-Item $tempVhdx -Force }

Write-Log "Converting qcow2 to VHDX (dynamic, subformat=dynamic)..." -Activity
$convertArgs = @(
    'convert',
    '-p',
    '-f', 'qcow2',
    '-O', 'vhdx',
    '-o', 'subformat=dynamic',
    $qcow2Path,
    $tempVhdx
)
& $resolvedQemu @convertArgs
if ($LASTEXITCODE -ne 0) {
    Write-Log "qemu-img convert failed with exit code $LASTEXITCODE." -Failure
    return
}
if (-not (Test-Path $tempVhdx)) {
    Write-Log "qemu-img convert exited 0 but $tempVhdx was not produced." -Failure
    return
}

# ---------------------------------------------------------------------------
# 6. Resize VHDX to the requested final size
# ---------------------------------------------------------------------------
# qemu-img's VHDX driver does NOT support 'resize' ("Image format driver does
# not support resize"). Use Hyper-V's Resize-VHD instead, which works on
# dynamic VHDX. Note: we're only growing the virtual size; Linux will pick up
# the extra unallocated space on first boot via cloud-init growpart.
Write-Log "Resizing VHDX to ${DiskSizeGB}G via Resize-VHD..." -Activity
try {
    # qemu-img creates the VHDX as a sparse file on NTFS, which Resize-VHD
    # rejects with 0xC03A001A ("must not be sparse"). Clear the sparse
    # attribute first; this is a metadata-only flip, not a rewrite.
    & fsutil sparse setflag $tempVhdx 0 | Out-Null
    $targetBytes = [int64]$DiskSizeGB * 1GB
    Resize-VHD -Path $tempVhdx -SizeBytes $targetBytes -ErrorAction Stop
}
catch {
    Write-Log "Resize-VHD failed: $_" -Failure
    return
}

# ---------------------------------------------------------------------------
# 7. First-boot bake: install Hyper-V integration daemons + qemu-guest-agent
#    while the bake VM still has internet, then cloud-init clean so the next
#    boot (with a fresh deploy seed) re-runs first-boot from scratch.
#    memlabs lab subnets can't resolve archive.ubuntu.com (DC isn't up yet
#    when Linux VMs are created in phase 1), so apt at deploy time fails.
# ---------------------------------------------------------------------------
if (-not $SkipBake) {
    Write-Log "Baking $tempVhdx via temp VM on switch '$BakeSwitchName' (variant=$bakeVariant, timeout ${BakeTimeoutMinutes}m)..." -Activity
    try {
        Invoke-LinuxBaseImageBake -VhdxPath $tempVhdx -SwitchName $BakeSwitchName -TimeoutMinutes $BakeTimeoutMinutes -Variant $bakeVariant | Out-Null
    }
    catch {
        Write-Log "Bake failed: $_" -Failure
        Write-Log "The VHDX at $tempVhdx is left in place for inspection. Re-run with -SkipBake to publish without baking." -Warning
        return
    }
}
else {
    Write-Log "-SkipBake specified; publishing raw VHDX (Hyper-V KVP daemon will NOT be installed)." -Warning
}

# ---------------------------------------------------------------------------
# 8. Move into AzureImagePath as the final VHDX
# ---------------------------------------------------------------------------
if (Test-Path $outputVhdx) {
    Remove-Item $outputVhdx -Force
}
Move-Item -Path $tempVhdx -Destination $outputVhdx -Force
$finalSizeGB = [math]::Round((Get-Item $outputVhdx).Length / 1GB, 2)
Write-Log "Linux base VHDX ready: $outputVhdx ($finalSizeGB GB on disk, ${DiskSizeGB}G virtual)" -Success

$timer.Stop()
Write-Log "### DONE in $([math]::Round($timer.Elapsed.TotalSeconds, 1)) seconds." -Success
