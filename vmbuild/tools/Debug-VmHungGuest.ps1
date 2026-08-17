<#
.SYNOPSIS
    Make a hung guest say where it is stuck: screenshot, inject an NMI, screenshot again.

.DESCRIPTION
    When a Linux guest freezes before networking there is nothing left to ask --
    no sshd, no KVP, and the serial tap only ever shows the last line printed.
    An NMI is the one channel the host still has into a wedged kernel: it is
    non-maskable, so it lands even when the guest is spinning with interrupts
    off, and Linux prints a backtrace naming the stuck function.

    Why this is needed at all: these VMs report
    "NMI watchdog: Perf NMI watchdog permanently disabled" at boot, because the
    synthetic CPU exposes no PMU. The hardware lockup detector is therefore
    NEVER armed, which is why a hard hang produces total silence instead of a
    "hard LOCKUP" splat. Injecting by hand replaces the watchdog we do not have.

    Captures the console before AND after so the difference is the evidence,
    and compares them: an UNCHANGED screen is reported as a result (the kernel
    was too far gone to respond, or unknown-NMI printing is off) rather than
    being passed off as a successful capture.

    DESTRUCTIVE ON A HEALTHY GUEST: an NMI can panic a running VM. This refuses
    to fire at a guest whose heartbeat is answering unless -Force is given.

.PARAMETER VmName
    The Hyper-V VM name.

.PARAMETER Force
    Inject even when the guest heartbeat looks healthy.

.PARAMETER SettleSeconds
    How long to let the guest print its backtrace before the second capture.

.PARAMETER OutputDir
    Where to write the PNGs. Defaults to vmbuild\logs\linux-diag.

.EXAMPLE
    .\Debug-VmHungGuest.ps1 -VmName ZZ-TOFU
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [int]$SettleSeconds = 10,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VmName -ErrorAction Stop
if ($vm.State -ne 'Running') {
    throw "VM '$VmName' is $($vm.State). An NMI only means something against a Running VM."
}

$hb = "$($vm.Heartbeat)"
if ($hb -like 'Ok*' -and -not $Force) {
    throw "VM '$VmName' heartbeat is '$hb' -- it is answering, so it is not the hung guest this tool is for, and an NMI could panic it. Re-run with -Force if you really mean it."
}
Write-Host "VM '$VmName' state=$($vm.State) heartbeat='$hb'" -ForegroundColor DarkGray

if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\linux-diag' }
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$shot = Join-Path $PSScriptRoot 'Save-VmConsoleScreenshot.ps1'
if (-not (Test-Path -LiteralPath $shot)) { throw "Save-VmConsoleScreenshot.ps1 not found next to this script ($shot)" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$before = Join-Path $OutputDir "$VmName-nmi-$stamp-1-before.png"
$after = Join-Path $OutputDir "$VmName-nmi-$stamp-2-after.png"

Write-Host "Capturing console BEFORE the NMI ..." -ForegroundColor Cyan
& $shot -VmName $VmName -Path $before
if (-not (Test-Path -LiteralPath $before)) { throw "pre-NMI capture did not produce $before; refusing to inject without a baseline to compare against" }

Write-Host "Injecting NMI ..." -ForegroundColor Yellow
try {
    Debug-VM -Name $VmName -InjectNonMaskableInterrupt -Force -ErrorAction Stop
}
catch {
    throw "Debug-VM -InjectNonMaskableInterrupt failed: $($_.Exception.Message). (Requires an elevated session on the Hyper-V host.)"
}

Write-Host "Waiting ${SettleSeconds}s for the guest to print ..." -ForegroundColor DarkGray
Start-Sleep -Seconds $SettleSeconds

Write-Host "Capturing console AFTER the NMI ..." -ForegroundColor Cyan
& $shot -VmName $VmName -Path $after
if (-not (Test-Path -LiteralPath $after)) { throw "post-NMI capture did not produce $after" }

$h1 = (Get-FileHash -LiteralPath $before -Algorithm SHA256).Hash
$h2 = (Get-FileHash -LiteralPath $after -Algorithm SHA256).Hash

''
Write-Host "before: $before" -ForegroundColor Gray
Write-Host "after : $after" -ForegroundColor Gray
if ($h1 -eq $h2) {
    # Not a tooling failure, and not "nothing is wrong" either -- say which.
    Write-Warning "Console is UNCHANGED after the NMI. The guest did not print anything, so either the kernel is too far gone to service an NMI, or unknown-NMI reporting is off in this image. This is a measurement, not a failed capture: it rules OUT a guest that is merely busy."
    Write-Host "To make the next one talk, bake unknown_nmi_panic=1 / softlockup_panic=1 into the kernel cmdline -- they must be in the IMAGE, because the hang happens on first boot before any runcmd could set them." -ForegroundColor Yellow
}
else {
    Write-Host "Console CHANGED after the NMI -- the guest printed something. Open the 'after' PNG; the backtrace names the stuck function." -ForegroundColor Green
}
