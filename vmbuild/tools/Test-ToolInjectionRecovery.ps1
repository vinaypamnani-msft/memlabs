<#
.SYNOPSIS
    Verifies Phase 2 reports tool injection only after guarded recovery is exhausted.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$sourcePath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw

$initial = [regex]::Match(
    $source,
    '(?s)if \(-not \$injectedOk\)\s*\{\s*Write-Log "([^"]*Initial tool injection[^"]*)"([^\r\n]*)'
)
if (-not $initial.Success) {
    throw 'Phase 2 is missing the initial tool-injection recovery diagnostic.'
}
if ($initial.Groups[2].Value -match '-Warning|-Failure|-OutputStream') {
    throw 'Initial tool-injection failure is classified before guarded recovery finishes.'
}
if ($source -notmatch '(?s)if \(-not \$injectedOk\)\s*\{.+?Wait-ForVM.+?Install-Tools.+?Tool injection recovered successfully after guarded guest recovery\." -OutputStream') {
    throw 'Phase 2 does not report successful guarded tool-injection recovery.'
}
if ($source -notmatch '(?s)Tool injection still failing after guarded guest recovery\." -Warning -OutputStream.+?Tool injection FAILED.+?-Failure -OutputStream') {
    throw 'Terminal tool-injection failure is not surfaced after recovery is exhausted.'
}

Write-Host 'PASS -- Phase 2 classifies tool injection only after guarded recovery completes.'
