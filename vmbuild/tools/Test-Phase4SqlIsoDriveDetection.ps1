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
if ($nativeChecks -lt 5) {
    throw "Expected at least five native SQL-media checks in AssignSqlIsoDriveLetter; found $nativeChecks."
}

$providerChecks = [regex]::Matches($assignText, '(?im)^(?!\s*#)[^\r\n]*\bTest-Path\b[^\r\n]*setup\.exe')
if ($providerChecks.Count -ne 2 -or @($providerChecks | Where-Object { $_.Value -notmatch '\$providerSeesMedia\s*=' }).Count -ne 0) {
    throw 'Test-Path must be diagnostic-only; System.IO must remain authoritative for SQL media.'
}
if ($assignText -notmatch 'SQL ISO S: confirmation succeeded: System\.IO=True; Test-Path=\$providerSeesMedia') {
    throw 'Successful SQL media recovery does not log native/provider visibility.'
}
if ($assignText -notmatch 'System\.IO\.Exists=\$nativeSeesMedia; Test-Path=\$providerSeesMedia; PSDrive\.S\.Root=') {
    throw 'SQL media assignment failure does not preserve native/provider/PSDrive diagnostics.'
}

Write-Host 'PASS -- all Phase 4 SQL-media probes use native file access.'
