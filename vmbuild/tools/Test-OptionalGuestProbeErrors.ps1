<#
.SYNOPSIS
    Ensures optional guest probes do not leak expected errors to Invoke-VmCommand.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$sourceText = Get-Content -LiteralPath $sourcePath -Raw

$patterns = @(
    '(?im)^\s*(?:\$[^=]+?=\s*)?\(?Get-ItemProperty(?:Value)?\b[^\r\n]*-ErrorAction\s+(?:SilentlyContinue|Ignore)',
    '(?im)^\s*Remove-ItemProperty\b[^\r\n]*-ErrorAction\s+(?:SilentlyContinue|Ignore)',
    '(?im)^\s*(?:\$[^=]+?=\s*)?Get-Service\b[^\r\n]*-ErrorAction\s+(?:SilentlyContinue|Ignore)'
)
foreach ($pattern in $patterns) {
    $matches = @([regex]::Matches($sourceText, $pattern))
    if ($matches.Count -gt 0) {
        throw "Optional guest probe still uses SilentlyContinue and can pollute the error stream: $($matches[0].Value.Trim())"
    }
}

Write-Host 'PASS -- optional guest registry/service probes do not emit expected-missing errors.'
