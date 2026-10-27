<#
.SYNOPSIS
    Grep a VMBuild jsonl and print "time lvl comp msg" for matching records.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Match,
    [int]$Width = 170
)

foreach ($line in [System.IO.File]::ReadLines((Resolve-Path -LiteralPath $Path))) {
    if (-not $line) { continue }
    if ($line -notmatch $Match) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    $m = ([string]$o.msg -replace '\s+', ' ').Trim()
    if ($m.Length -gt $Width) { $m = $m.Substring(0, $Width) + '...' }
    '{0} {1,-5} {2,-24} {3}' -f ([datetime]$o.t).ToString('HH:mm:ss'), $o.lvl, $o.comp, $m
}
