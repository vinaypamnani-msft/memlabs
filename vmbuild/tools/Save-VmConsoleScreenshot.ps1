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

.EXAMPLE
    .\Save-VmConsoleScreenshot.ps1 -VmName ZZ-TOFU
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ns = 'root\virtualization\v2'

$vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$($VmName -replace "'", "''")'" -ErrorAction Stop
if (-not $vm) { throw "VM '$VmName' not found in $ns on $env:COMPUTERNAME" }
if ($vm.EnabledState -ne 2) {
    Write-Warning "VM '$VmName' EnabledState=$($vm.EnabledState) (2=Running). A powered-off VM has no framebuffer to capture."
}

# The thumbnail request must not exceed the guest's current video resolution, so
# ask the video head rather than guessing.
$w = 1024; $h = 768
$head = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VideoHead -ErrorAction SilentlyContinue | Select-Object -First 1
if ($head -and $head.CurrentHorizontalResolution -and $head.CurrentVerticalResolution) {
    $w = [int]$head.CurrentHorizontalResolution
    $h = [int]$head.CurrentVerticalResolution
    Write-Host "video head reports $($w)x$($h)"
}
else {
    Write-Warning "no Msvm_VideoHead resolution available; trying $($w)x$($h)"
}

$settings = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData -ErrorAction Stop |
    Where-Object { $_.VirtualSystemType -like 'Microsoft:Hyper-V:System:Realized*' } | Select-Object -First 1
if (-not $settings) { throw "could not resolve Msvm_VirtualSystemSettingData for '$VmName'" }

$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService -ErrorAction Stop
$res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
    TargetSystem = [ciminstance]$settings
    WidthPixels  = [uint16]$w
    HeightPixels = [uint16]$h
} -ErrorAction Stop

if ($res.ReturnValue -ne 0) { throw "GetVirtualSystemThumbnailImage failed with ReturnValue=$($res.ReturnValue)" }
$bytes = $res.ImageData
if (-not $bytes -or $bytes.Count -eq 0) { throw 'thumbnail returned no image data' }

$expected = $w * $h * 2
if ($bytes.Count -ne $expected) {
    Write-Warning "image is $($bytes.Count) bytes, expected $expected for RGB565 at $($w)x$($h); rendering what arrived"
    $h = [int][math]::Floor($bytes.Count / (2 * $w))
    if ($h -lt 1) { throw "image data too small to render at width $w" }
}

# Thumbnail data is RGB565, little-endian, top-left origin.
$bmp = [System.Drawing.Bitmap]::new($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$rect = [System.Drawing.Rectangle]::new(0, 0, $w, $h)
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
try {
    $row = [byte[]]::new($data.Stride)
    for ($y = 0; $y -lt $h; $y++) {
        $si = $y * $w * 2
        for ($x = 0; $x -lt $w; $x++) {
            $v = [int]$bytes[$si + ($x * 2)] -bor ([int]$bytes[$si + ($x * 2) + 1] -shl 8)
            $di = $x * 3
            $row[$di] = [byte](((($v -band 0x001F)) * 255) / 31)        # B
            $row[$di + 1] = [byte](((($v -shr 5) -band 0x003F) * 255) / 63)  # G
            $row[$di + 2] = [byte](((($v -shr 11) -band 0x001F) * 255) / 31) # R
        }
        [System.Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]::Add($data.Scan0, $y * $data.Stride), $data.Stride)
    }
}
finally { $bmp.UnlockBits($data) }

if (-not $Path) {
    $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\linux-diag'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Path = Join-Path $dir "$VmName-console-$(Get-Date -Format 'yyyyMMdd-HHmmss').png"
}
$bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$fi = Get-Item -LiteralPath $Path
"saved: $($fi.FullName) ($($fi.Length) bytes, $($w)x$($h))"

# An all-black frame is a real result (blanked console), not a failure -- say so
# rather than let the caller read a valid-looking PNG as "nothing was captured".
$nonZero = 0
foreach ($b in $bytes) { if ($b -ne 0) { $nonZero++; if ($nonZero -gt 64) { break } } }
if ($nonZero -le 64) {
    Write-Warning 'framebuffer is essentially all-black: the console is blanked or the guest never drew to it. That is evidence, not a capture failure.'
}
