<#
.SYNOPSIS
    Verifies that Phase 4 SQL media checks bypass stale PowerShell drive-provider state.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$phase4Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\Phase4.ps1'
$phase4Text = Get-Content -LiteralPath $phase4Path -Raw
$start = $phase4Text.IndexOf('Script AssignSqlIsoDriveLetter {', [StringComparison]::Ordinal)
if ($start -lt 0) {
    throw 'Could not isolate the AssignSqlIsoDriveLetter DSC resource.'
}
$end = $phase4Text.IndexOf('WriteStatus InstallSQL {', $start, [StringComparison]::Ordinal)
if ($end -le $start) { throw 'Could not find the end of the AssignSqlIsoDriveLetter DSC resource.' }

$assignText = $phase4Text.Substring($start, $end - $start)
$nativeChecks = [regex]::Matches($assignText, '\[System\.IO\.File\]::Exists\(').Count
if ($nativeChecks -ne 4) {
    throw "Expected four native SQL-media checks in AssignSqlIsoDriveLetter; found $nativeChecks."
}

$providerChecks = [regex]::Matches($assignText, '(?im)^(?!\s*#)[^\r\n]*\bTest-Path\b[^\r\n]*setup\.exe')
if ($providerChecks.Count -gt 0) {
    throw 'AssignSqlIsoDriveLetter still validates newly assigned media through Test-Path.'
}

Write-Host 'PASS -- all Phase 4 SQL-media probes use native file access.'
