#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.VmConsoleScreenshot.ps1')
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$root = Join-Path ([IO.Path]::GetTempPath()) "memlabs-console-image-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $root -ItemType Directory
try {
    $colors = [byte[]]@(0, 248, 224, 7, 31, 0, 255, 255)
    $path = Join-Path $root 'colors.png'
    Convert-MemLabsVmConsoleImage -ImageData $colors -Width 2 -Height 2 -Path $path
    $image = [Drawing.Bitmap]::new($path)
    try {
        Assert-True ($image.Width -eq 2 -and $image.Height -eq 2 -and
            $image.GetPixel(0, 0).R -eq 255 -and $image.GetPixel(0, 0).G -eq 0 -and
            $image.GetPixel(1, 0).G -eq 255 -and $image.GetPixel(0, 1).B -eq 255 -and
            $image.GetPixel(1, 1).R -eq 255 -and $image.GetPixel(1, 1).G -eq 255) `
            'RGB565 conversion lost color, pixel dimensions, or top-to-bottom orientation.'
    }
    finally { $image.Dispose() }
    $prefixedColors = [byte[]](@(0, 0, 0, 12) + $colors)
    $layout = Get-MemLabsVmConsoleFrameLayout -ImageData $prefixedColors -Width 2 -Height 2
    Assert-True ($layout.BufferLayout -eq 'BigEndianLengthPrefixedRgb565' -and
        $layout.PrefixBytes -eq 4 -and $layout.PixelBytes -eq 8 -and $layout.SourceBytes -eq 12) `
        'A validated big-endian total-length frame was not classified exactly.'
    $path = Join-Path $root 'prefixed-colors.png'
    Convert-MemLabsVmConsoleImage -ImageData $prefixedColors -Width 2 -Height 2 -Path $path
    $image = [Drawing.Bitmap]::new($path)
    try {
        Assert-True ($image.GetPixel(0, 0).R -eq 255 -and $image.GetPixel(1, 0).G -eq 255 -and
            $image.GetPixel(0, 1).B -eq 255 -and $image.GetPixel(1, 1).R -eq 255) `
            'Length-prefix handling shifted pixels, colors, or row orientation.'
    }
    finally { $image.Dispose() }
    $path = Join-Path $root 'odd-stride.png'
    Convert-MemLabsVmConsoleImage -ImageData ([byte[]]@(0, 248, 224, 7, 31, 0)) -Width 3 -Height 1 -Path $path
    $image = [Drawing.Bitmap]::new($path)
    try { Assert-True ($image.GetPixel(2, 0).B -eq 255) 'Odd-width source rows were corrupted by bitmap stride padding.' }
    finally { $image.Dispose() }
    $path = Join-Path $root 'prefixed-odd-stride.png'
    Convert-MemLabsVmConsoleImage -ImageData ([byte[]]@(0, 0, 0, 10, 0, 248, 224, 7, 31, 0)) `
        -Width 3 -Height 1 -Path $path
    $image = [Drawing.Bitmap]::new($path)
    try { Assert-True ($image.GetPixel(0, 0).R -eq 255 -and $image.GetPixel(2, 0).B -eq 255) 'Prefixed odd-width rows were corrupted.' }
    finally { $image.Dispose() }
    $actualSize = [byte[]]::new(2048004)
    [Array]::Copy([byte[]]@(0, 31, 64, 4), $actualSize, 4)
    $actualSize[5] = 248; $actualSize[$actualSize.Length - 2] = 31
    $path = Join-Path $root 'observed-1280x800.png'
    Convert-MemLabsVmConsoleImage -ImageData $actualSize -Width 1280 -Height 800 -Path $path
    $image = [Drawing.Bitmap]::new($path)
    try {
        Assert-True ($image.Width -eq 1280 -and $image.Height -eq 800 -and $image.GetPixel(0, 0).R -eq 255 -and
            $image.GetPixel(1279, 799).B -eq 255) 'The observed 2048004-byte provider layout did not preserve exact dimensions and endpoint pixels.'
    }
    finally { $image.Dispose() }
    $failure = $null
    try { Convert-MemLabsVmConsoleImage -ImageData ([byte[]]@(0)) -Width 2 -Height 2 -Path (Join-Path $root 'invalid.png') }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'length' -and -not (Test-Path -LiteralPath (Join-Path $root 'invalid.png'))) `
        'Malformed image data was silently rendered as a successful capture.'
    $extra = [byte[]]@(8, 0, 0, 0, 0, 248, 224, 7, 31, 0, 255, 255)
    $failure = $null
    try { Convert-MemLabsVmConsoleImage -ImageData $extra -Width 2 -Height 2 -Path (Join-Path $root 'extra-four.png') }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'got 12, expected 8 for 2x2' -and $failure -match '0x00000008/0xFFFF001F' -and
        $failure -match 'No bytes were discarded' -and -not (Test-Path -LiteralPath (Join-Path $root 'extra-four.png'))) `
        'Unverified four-byte framebuffer data was trimmed or lost its layout diagnostics.'
    foreach ($malformed in @(
            [byte[]](@(0, 0, 0, 8) + $colors),
            [byte[]](@(12, 0, 0, 0) + $colors),
            [byte[]]@(0, 0, 0, 12, 0, 248, 224, 7, 31, 0, 255),
            [byte[]](@(0, 0, 0, 13) + $colors + @(0))
        )) {
        $failure = $null
        try { Convert-MemLabsVmConsoleImage -ImageData $malformed -Width 2 -Height 2 -Path (Join-Path $root 'bad-prefix.png') }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'No bytes were discarded' -and
            -not (Test-Path -LiteralPath (Join-Path $root 'bad-prefix.png'))) 'Invalid, little-endian, truncated, or oversized framing became a successful image.'
    }

    $script:VMId = [guid]::NewGuid()
    $script:Settings = [Microsoft.Management.Infrastructure.CimInstance]::new('Msvm_VirtualSystemSettingData')
    $script:Settings.CimInstanceProperties.Add([Microsoft.Management.Infrastructure.CimProperty]::Create(
            'VirtualSystemType', 'Microsoft:Hyper-V:System:Realized', [Microsoft.Management.Infrastructure.CimType]::String,
            [Microsoft.Management.Infrastructure.CimFlags]::None))
    function Reset-CaptureFixture {
        $script:EnabledState = 2; $script:QueryCount = 0; $script:MethodCalls = 0; $script:ReturnValue = 0
        $script:WrongId = $false; $script:Duplicate = $false; $script:BadLength = $false
        $script:VideoWidth = 2; $script:VideoHeight = 2; $script:NoHead = $false; $script:Black = $false
        $script:Prefixed = $false
    }
    function Get-CimInstance {
        param($Namespace, $ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        Assert-True ($Namespace -eq 'root\virtualization\v2' -and $OperationTimeoutSec -eq 10) 'Capture queried another namespace or lost its bound.'
        $script:QueryCount++
        if ($ClassName -eq 'Msvm_VirtualSystemManagementService') { return [pscustomobject]@{ Service = 'Thumbnail' } }
        Assert-True ($ClassName -eq 'Msvm_ComputerSystem' -and
            ($Filter -eq "Name='$($script:VMId.ToString('D'))'" -or $Filter -eq "ElementName='EXACT-VM'")) `
            'Capture did not use an exact VM identifier/name filter.'
        $id = if ($script:WrongId) { [guid]::NewGuid().ToString('D') } else { $script:VMId.ToString('D') }
        $system = [pscustomobject]@{ Name = $id; ElementName = 'EXACT-VM'; EnabledState = $script:EnabledState }
        $system
        if ($script:Duplicate) { $system }
    }
    function Get-CimAssociatedInstance {
        param($InputObject, $ResultClassName, $OperationTimeoutSec, $ErrorAction)
        Assert-True ($InputObject.Name -eq $script:VMId.ToString('D') -and $OperationTimeoutSec -eq 10) 'Associated data belongs to another VM.'
        if ($ResultClassName -eq 'Msvm_VideoHead') {
            if (-not $script:NoHead) { [pscustomobject]@{ CurrentHorizontalResolution = $script:VideoWidth; CurrentVerticalResolution = $script:VideoHeight } }
            return
        }
        Assert-True ($ResultClassName -eq 'Msvm_VirtualSystemSettingData') 'Capture queried unrelated associated guest data.'
        return $script:Settings
    }
    function Invoke-CimMethod {
        param($InputObject, $MethodName, $Arguments, $OperationTimeoutSec, $ErrorAction)
        Assert-True ($MethodName -eq 'GetVirtualSystemThumbnailImage' -and $OperationTimeoutSec -eq 10 -and
            [object]::ReferenceEquals($Arguments.TargetSystem, $script:Settings)) 'Capture invoked another method or VM settings.'
        $script:MethodCalls++
        $size = [int]$Arguments.WidthPixels * [int]$Arguments.HeightPixels * 2
        $bytes = if ($script:BadLength) { [byte[]]@(1) } elseif ($size -eq 8 -and -not $script:Black) { $colors } else { [byte[]]::new($size) }
        if ($script:Prefixed) {
            $header = [BitConverter]::GetBytes([Net.IPAddress]::HostToNetworkOrder([int]($bytes.Length + 4)))
            $bytes = [byte[]]($header + $bytes)
        }
        [pscustomobject]@{ ReturnValue = $script:ReturnValue; ImageData = $bytes }
    }
    function Get-VM {
        param($Id, $ErrorAction)
        Assert-True ($Id -eq $script:VMId) 'Console evidence wrapper targeted another VM.'
        [pscustomobject]@{ Name = 'EXACT-VM'; Id = $script:VMId; State = 'Running' }
    }
    Reset-CaptureFixture
    $capture = Save-MemLabsVmConsoleScreenshot -VMId $script:VMId -Path (Join-Path $root 'by-id.png')
    Assert-True ($capture.Status -eq 'Captured' -and $capture.VMId -eq $script:VMId.ToString('D') -and
        $capture.Width -eq 2 -and $capture.Height -eq 2 -and -not $capture.AllBlack) 'Exact-ID capture did not preserve its image metadata.'
    Reset-CaptureFixture
    $script:Black = $true
    $capture = Save-MemLabsVmConsoleScreenshot -VmName EXACT-VM -Path (Join-Path $root 'black.png')
    Assert-True ($capture.Status -eq 'Captured' -and $capture.AllBlack) 'An all-black frame was hidden as a capture failure.'
    Reset-CaptureFixture
    $script:Black = $true; $script:Prefixed = $true; $script:VideoWidth = 16; $script:VideoHeight = 16
    $capture = Save-MemLabsVmConsoleScreenshot -VmName EXACT-VM -Path (Join-Path $root 'prefixed-black.png')
    Assert-True ($capture.AllBlack -and $capture.SourceBytes -eq 516 -and $capture.PrefixBytes -eq 4 -and
        $capture.BufferLayout -eq 'BigEndianLengthPrefixedRgb565') 'Header bytes were counted as visible pixels or the observed 516-byte format was not supported.'
    foreach ($disabled in @(3, 32769)) {
        Reset-CaptureFixture
        $script:EnabledState = $disabled
        $capture = Save-MemLabsVmConsoleScreenshot -VMId $script:VMId -Path (Join-Path $root "off-$disabled.png")
        Assert-True ($capture.Status -eq 'UnavailableNotRunning' -and $script:MethodCalls -eq 0 -and
            $null -eq $capture.Path) 'An unavailable framebuffer was claimed as a successful screenshot.'
    }
    foreach ($scenario in @('WrongId', 'Duplicate', 'BadLength', 'Denied', 'Async')) {
        Reset-CaptureFixture
        if ($scenario -eq 'WrongId') { $script:WrongId = $true }
        if ($scenario -eq 'Duplicate') { $script:Duplicate = $true }
        if ($scenario -eq 'BadLength') { $script:BadLength = $true }
        if ($scenario -eq 'Denied') { $script:ReturnValue = 32769 }
        if ($scenario -eq 'Async') { $script:ReturnValue = 4096 }
        $failure = $null
        try { $null = Save-MemLabsVmConsoleScreenshot -VMId $script:VMId -Path (Join-Path $root "$scenario.png") }
        catch { $failure = $_.Exception.Message }
        Assert-True ([bool]$failure -and -not (Test-Path -LiteralPath (Join-Path $root "$scenario.png"))) "$scenario became a false successful capture."
    }
    Reset-CaptureFixture
    $script:VideoWidth = 3840; $script:VideoHeight = 2160
    $capture = Save-MemLabsVmConsoleScreenshot -VMId $script:VMId -Path (Join-Path $root 'bounded.png')
    Assert-True ($capture.Width -eq 1280 -and $capture.Height -eq 720) 'Large console resolution did not respect exact output bounds/aspect ratio.'
    Reset-CaptureFixture
    $script:NoHead = $true
    $capture = Save-MemLabsVmConsoleScreenshot -VMId $script:VMId -Path (Join-Path $root 'fallback.png')
    Assert-True ($capture.UsedFallbackResolution -and $capture.Width -eq 640 -and $capture.Height -eq 480) `
        'An unavailable video-head resolution did not retain its explicit fallback status.'

    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Get-WindowsVmSetupDiagnostics.ps1'), [ref]$tokens, [ref]$errors)
    $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Add-MemLabsSetupConsoleScreenshot' }, $true)[0]
    $wrapperText = $definition.Extent.Text.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")
    . ([scriptblock]::Create($wrapperText))
    $records = [Collections.Generic.List[object]]::new()
    $captureErrors = [Collections.Generic.List[string]]::new()
    Reset-CaptureFixture
    $vm = [pscustomobject]@{ Name = 'EXACT-VM'; Id = $script:VMId }
    $record = Add-MemLabsSetupConsoleScreenshot -VM $vm -Bundle $root -Stage Wrapper `
        -Records $records -Errors $captureErrors
    Assert-True ($record.Status -eq 'Captured' -and $records.Count -eq 1 -and $captureErrors.Count -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $root 'Console-Wrapper.png'))) 'The archive wrapper did not record a captured console.'
    Reset-CaptureFixture
    $script:Prefixed = $true
    $record = Add-MemLabsSetupConsoleScreenshot -VM $vm -Bundle $root -Stage Prefixed `
        -Records $records -Errors $captureErrors
    Assert-True ($record.BufferLayout -eq 'BigEndianLengthPrefixedRgb565' -and $record.SourceBytes -eq 12 -and
        $record.PrefixBytes -eq 4 -and $records.Count -eq 2 -and $captureErrors.Count -eq 0) 'Protected archive metadata lost validated framebuffer layout information.'
    Reset-CaptureFixture
    $script:ReturnValue = 32769
    $record = Add-MemLabsSetupConsoleScreenshot -VM $vm -Bundle $root -Stage Failed `
        -Records $records -Errors $captureErrors
    Assert-True ($record.Status -eq 'Error' -and $records.Count -eq 3 -and $captureErrors.Count -eq 1) `
        'Console failure was not retained as explicit partial evidence.'
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Common.VmConsoleScreenshot.ps1') -Raw
    Assert-True ($source -notmatch 'CopyFromScreen|Start-VM|Stop-VM|Restart-VM|Save-VM|Debug-VM') `
        'Console capture can access the host desktop or change guest power state.'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
Write-Host 'PASS -- raw/validated big-endian RGB565 colors/stride, observed frame sizes, exact VM targeting, bounded capture, pixel-only black detection, and malformed-frame rejection.'
