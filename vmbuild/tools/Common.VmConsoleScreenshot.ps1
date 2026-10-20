function Convert-MemLabsVmConsoleImage {
    param(
        [Parameter(Mandatory)][byte[]]$ImageData,
        [Parameter(Mandatory)][ValidateRange(1, 4096)][int]$Width,
        [Parameter(Mandatory)][ValidateRange(1, 2160)][int]$Height,
        [Parameter(Mandatory)][string]$Path
    )

    $expected = [long]$Width * $Height * 2
    if ($expected -gt 16MB -or $ImageData.Length -ne $expected) {
        throw "Invalid RGB565 framebuffer length: got $($ImageData.Length), expected $expected."
    }
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $bitmap = [Drawing.Bitmap]::new($Width, $Height, [Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    $png = $null
    try {
        $rectangle = [Drawing.Rectangle]::new(0, 0, $Width, $Height)
        $bits = $bitmap.LockBits($rectangle, [Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmap.PixelFormat)
        try {
            for ($row = 0; $row -lt $Height; $row++) {
                [Runtime.InteropServices.Marshal]::Copy($ImageData, $row * $Width * 2,
                    [IntPtr]::Add($bits.Scan0, $row * $bits.Stride), $Width * 2)
            }
        }
        finally { $bitmap.UnlockBits($bits) }
        $png = [Drawing.Bitmap]::new($Width, $Height, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [Drawing.Graphics]::FromImage($png)
        try { $graphics.DrawImageUnscaled($bitmap, 0, 0) }
        finally { $graphics.Dispose() }
        $png.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($png) { $png.Dispose() }
        $bitmap.Dispose()
    }
}

function Save-MemLabsVmConsoleScreenshot {
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Name')][string]$VmName,
        [Parameter(Mandatory, ParameterSetName = 'Id')][guid]$VMId,
        [Parameter(Mandatory)][string]$Path
    )

    $namespace = 'root\virtualization\v2'
    $filter = if ($PSCmdlet.ParameterSetName -eq 'Id') { "Name='$($VMId.ToString('D'))'" } else {
        if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($VmName)) { throw 'Specify an exact VM name, not a wildcard.' }
        "ElementName='$($VmName.Replace("'", "''"))'"
    }
    $systems = @(Get-CimInstance -Namespace $namespace -ClassName Msvm_ComputerSystem `
        -Filter $filter -OperationTimeoutSec 10 -ErrorAction Stop)
    if ($systems.Count -ne 1) { throw 'Console capture requires exactly one matching Hyper-V VM.' }
    $system = $systems[0]
    if ($PSCmdlet.ParameterSetName -eq 'Id' -and $system.Name -ine $VMId.ToString('D')) {
        throw 'The console provider returned a different VM ID.'
    }
    $result = [pscustomobject]@{
        Status = 'UnavailableNotRunning'; VMId = $system.Name; VMName = $system.ElementName
        EnabledState = $system.EnabledState; Path = $null; Width = $null; Height = $null
        AllBlack = $null; UsedFallbackResolution = $false
    }
    if ($system.EnabledState -notin @(2, 32768)) { return $result }

    $width = 640; $height = 480
    $heads = @(Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_VideoHead `
        -OperationTimeoutSec 10 -ErrorAction Stop)
    $head = $heads | Where-Object { $_.CurrentHorizontalResolution -gt 0 -and $_.CurrentVerticalResolution -gt 0 } | Select-Object -First 1
    if ($head) {
        $scale = [Math]::Min(1.0, [Math]::Min(1280.0 / $head.CurrentHorizontalResolution, 800.0 / $head.CurrentVerticalResolution))
        $width = [Math]::Max(1, [int][Math]::Floor($head.CurrentHorizontalResolution * $scale))
        $height = [Math]::Max(1, [int][Math]::Floor($head.CurrentVerticalResolution * $scale))
    }
    else {
        $result.UsedFallbackResolution = $true
        Write-Warning 'VM video resolution is unavailable; attempting a 640x480 console thumbnail.'
    }
    $settings = @(Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_VirtualSystemSettingData `
        -OperationTimeoutSec 10 -ErrorAction Stop |
        Where-Object { $_.VirtualSystemType -like 'Microsoft:Hyper-V:System:Realized*' })
    if ($settings.Count -ne 1) { throw 'The selected VM current settings could not be identified uniquely.' }
    $services = @(Get-CimInstance -Namespace $namespace -ClassName Msvm_VirtualSystemManagementService `
        -OperationTimeoutSec 10 -ErrorAction Stop)
    if ($services.Count -ne 1) { throw 'The Hyper-V thumbnail service could not be identified uniquely.' }
    $response = Invoke-CimMethod -InputObject $services[0] -MethodName GetVirtualSystemThumbnailImage `
        -Arguments @{ TargetSystem = [ciminstance]$settings[0]; WidthPixels = [uint16]$width; HeightPixels = [uint16]$height } `
        -OperationTimeoutSec 10 -ErrorAction Stop
    if ($response.ReturnValue -ne 0) { throw "Hyper-V console capture failed with ReturnValue=$($response.ReturnValue)." }
    $bytes = [byte[]]$response.ImageData
    Convert-MemLabsVmConsoleImage -ImageData $bytes -Width $width -Height $height -Path $Path
    $nonzero = 0
    foreach ($value in $bytes) {
        if ($value -ne 0) { $nonzero++; if ($nonzero -gt 64) { break } }
    }
    $result.Status = 'Captured'
    $result.Path = $Path
    $result.Width = $width
    $result.Height = $height
    $result.AllBlack = $nonzero -eq 0
    return $result
}
