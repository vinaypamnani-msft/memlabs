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
    '(?im)^\s*(?:\$[^=]+?=\s*)?\(?Get-ItemProperty(?:Value)?\b[^\r\n]*-ErrorAction\s+SilentlyContinue',
    '(?im)^\s*Remove-ItemProperty\b[^\r\n]*-ErrorAction\s+SilentlyContinue',
    '(?im)^\s*(?:\$[^=]+?=\s*)?Get-Service\b[^\r\n]*-ErrorAction\s+SilentlyContinue'
)
foreach ($pattern in $patterns) {
    $matches = @([regex]::Matches($sourceText, $pattern))
    if ($matches.Count -gt 0) {
        throw "Optional guest probe still uses SilentlyContinue and can pollute the error stream: $($matches[0].Value.Trim())"
    }
}

$probeErrors = @()
$value = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\MemLabs-OptionalProbe-Test' `
    -Name 'MissingValue' -ErrorAction Ignore -ErrorVariable +probeErrors
if ($null -ne $value -or $probeErrors.Count -ne 0) {
    throw "PowerShell Ignore semantics did not suppress the expected missing-value error: value='$value' errors=$($probeErrors.Count)"
}

Write-Host 'PASS -- optional guest registry/service probes do not emit expected-missing errors.'
