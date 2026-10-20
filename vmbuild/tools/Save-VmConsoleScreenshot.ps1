#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Save a PNG of a VM's console screen without touching the VM.

.DESCRIPTION
    When a Linux guest wedges before networking, every channel we normally use is
    already gone: no sshd, no KVP, and the serial tap stops the moment the guest
    stops printing. The framebuffer is the only place left that can still be
    showing an fsck prompt, an emergency shell, or a panic -- and
    Get-LinuxVmDiagnostics.ps1 powers the VM off, which destroys it.

    So run this FIRST, before any autopsy that stops the VM.

    Read-only: it calls GetVirtualSystemThumbnailImage and writes a file. It does
    not pause, save, stop or otherwise touch guest state.

.PARAMETER VmName
    Hyper-V VM name.

.PARAMETER Path
    Output PNG. Defaults to vmbuild\logs\linux-diag\<VmName>-console-<stamp>.png
.PARAMETER VMId
    Exact Hyper-V VM ID, as an alternative to VmName.
.PARAMETER PassThru
    Returns structured capture, unavailable-frame, resolution, and black-frame status.

.EXAMPLE
    .\Save-VmConsoleScreenshot.ps1 -VmName ZZ-TOFU
#>
[CmdletBinding(DefaultParameterSetName = 'Name')]
param (
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Name')]
    [string]$VmName,
    [Parameter(Mandatory = $true, ParameterSetName = 'Id')]
    [guid]$VMId,
    [Parameter(Mandatory = $false)]
    [string]$Path,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.VmConsoleScreenshot.ps1')

if (-not $Path) {
    $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\linux-diag'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $label = if ($PSCmdlet.ParameterSetName -eq 'Id') { "$VMId" } else { $VmName -replace '[\\/:*?"<>|]', '_' }
    $Path = Join-Path $dir "$label-console-$(Get-Date -Format 'yyyyMMdd-HHmmss').png"
}
$arguments = @{ Path = $Path }
if ($PSCmdlet.ParameterSetName -eq 'Id') { $arguments.VMId = $VMId } else { $arguments.VmName = $VmName }
$capture = Save-MemLabsVmConsoleScreenshot @arguments
if ($capture.Status -ne 'Captured') { Write-Warning "No console framebuffer available: $($capture.Status) (EnabledState=$($capture.EnabledState))." }
elseif ($capture.AllBlack) {
    Write-Warning 'framebuffer is essentially all-black: the console is blanked or the guest never drew to it. That is evidence, not a capture failure.'
}
if ($PassThru) { $capture }
elseif ($capture.Status -eq 'Captured') { "saved: $($capture.Path) ($($capture.Width)x$($capture.Height))" }
