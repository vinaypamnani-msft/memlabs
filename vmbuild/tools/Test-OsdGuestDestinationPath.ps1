#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $ScriptBlocksPath
)

$ErrorActionPreference = 'Stop'
if (-not $ScriptBlocksPath) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $vmbuildRoot = Split-Path -Parent (Split-Path -Parent $scriptPath)
    $ScriptBlocksPath = Join-Path $vmbuildRoot 'common\Common.ScriptBlocks.ps1'
}
$source = Get-Content -LiteralPath $ScriptBlocksPath -Raw
$expected = '$dirname = "$driveLetter\OSD\$($isoFile.id)"'
if ($source -notmatch [regex]::Escape($expected)) {
    throw 'OSD destination is not built as a literal guest path.'
}
if ($source -match '\$dirname\s*=\s*\(\s*join-path\s+\$driveLetter') {
    throw 'OSD destination still uses host provider resolution through Join-Path.'
}

$driveLetter = 'E:'
$isoFile = [pscustomobject]@{ id = 'Windows 11 24h2' }
$dirname = "$driveLetter\OSD\$($isoFile.id)"
if ($dirname -ne 'E:\OSD\Windows 11 24h2') {
    throw "Unexpected guest destination '$dirname'."
}
if (Test-Path 'E:\') {
    throw 'This regression control requires E: to be absent on the host.'
}
Write-Host "PASS: guest destination '$dirname' is produced while host E: is absent."
