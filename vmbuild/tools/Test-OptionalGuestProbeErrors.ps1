<#
.SYNOPSIS
    Ensures optional guest probes do not leak expected errors to Invoke-VmCommand.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePaths = @(
    (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'),
    (Join-Path $RootPath 'common\Common.DownloadCache.ps1'),
    (Join-Path $RootPath 'DSC\phases\ScriptWorkFlow.ps1'),
    (Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1')
)
$sourcePaths += @(Get-ChildItem -LiteralPath (Join-Path $RootPath 'Fixes') -Filter '*.ps1' -File |
        Select-Object -ExpandProperty FullName)

$patterns = @(
    '(?im)^\s*(?:\$[^=]+?=\s*)?\(?Get-ItemProperty(?:Value)?\b[^\r\n]*-ErrorAction\s+(?:SilentlyContinue|Ignore)',
    '(?im)^\s*Remove-ItemProperty\b[^\r\n]*-ErrorAction\s+(?:SilentlyContinue|Ignore)',
    '(?im)^\s*(?:\$[^=]+?=\s*)?Get-Service\b[^\r\n]*-ErrorAction\s+(?:SilentlyContinue|Ignore)'
)
foreach ($sourcePath in $sourcePaths) {
    $sourceText = Get-Content -LiteralPath $sourcePath -Raw
    foreach ($pattern in $patterns) {
        $matches = @([regex]::Matches($sourceText, $pattern))
        if ($matches.Count -gt 0) {
            throw "Optional guest probe in '$sourcePath' can pollute the error stream: $($matches[0].Value.Trim())"
        }
    }
}

Write-Host 'PASS -- optional guest registry/service probes do not emit expected-missing errors.'
