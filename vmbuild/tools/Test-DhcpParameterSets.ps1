#Requires -Version 5.1
<#
.SYNOPSIS
    Fails when a DhcpServer cmdlet is called with -ScopeId and -IPAddress together.

.DESCRIPTION
    Get-DhcpServerv4Reservation, Get-DhcpServerv4Lease and Remove-DhcpServerv4Reservation put
    -ScopeId and -IPAddress in different parameter sets. Passing both throws
    "Parameter set cannot be resolved using the specified named parameters." BEFORE the server is
    contacted, so the call can never succeed in any environment.

    This is invisible three ways at once, which is why it survived: PowerShell's parser accepts it,
    PSScriptAnalyzer has no view of CDXML parameter sets, and every call site in this repo wraps the
    call in -ErrorAction SilentlyContinue plus an empty catch. The result is a guard that silently
    evaluates to $null forever -- Add-DHCPReservationIsolated's idempotent-success, in-lab-collision
    and orphan-reclaim branches were all unreachable, costing ~60s per re-run on the Phase 2
    critical path.

    Reflection does NOT catch this: (Get-Command Get-DhcpServerv4Reservation).ParameterSets reports
    a single __AllParameterSets containing both parameters. Only invoking it reveals the conflict.

    Add-DhcpServerv4Reservation legitimately takes both and is not flagged.

.PARAMETER SelfTest
    Verify the gate fires, by scanning a synthetic sample containing the bad combination.
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) ''),
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# -ScopeId and -IPAddress are mutually exclusive on these. Add-* is deliberately absent: it
# requires both.
$conflicting = @(
    'Get-DhcpServerv4Reservation'
    'Get-DhcpServerv4Lease'
    'Remove-DhcpServerv4Reservation'
    'Remove-DhcpServerv4Lease'
    'Set-DhcpServerv4Reservation'
)

function Get-Violation {
    param([string]$Text, [string]$File)
    $found = @()
    foreach ($cmd in $conflicting) {
        # Match the invocation plus any continuation lines, so a call split with a backtick is
        # still seen as one statement. Stop at the first line that starts a new statement.
        foreach ($m in [regex]::Matches($Text, "(?im)^[^\r\n#]*?\b$cmd\b(?<args>(?:[^\r\n]|`` *\r?\n)*)")) {
            $argText = $m.Groups['args'].Value
            if ($argText -match '-ScopeId' -and $argText -match '-IPAddress') {
                $line = ($Text.Substring(0, $m.Index) -split "`n").Count
                $found += [pscustomobject]@{
                    File = $File
                    Line = $line
                    Cmd  = $cmd
                    Text = ($m.Value -replace '\s+', ' ').Trim()
                }
            }
        }
    }
    $found
}

if ($SelfTest) {
    $sample = @'
        try { $existing = Get-DhcpServerv4Reservation -ScopeId $scopeId -IPAddress $ip -ErrorAction SilentlyContinue } catch { }
        Add-DhcpServerv4Reservation -ScopeId $scopeId -IPAddress $ip -ClientId $mac -ErrorAction Stop
'@
    $hits = @(Get-Violation -Text $sample -File '<selftest>')
    if ($hits.Count -eq 1 -and $hits[0].Cmd -eq 'Get-DhcpServerv4Reservation') {
        Write-Host '[Test-DhcpParameterSets] SELFTEST PASS - fires on Get-*, ignores Add-*.' -ForegroundColor Green
        exit 0
    }
    Write-Host "[Test-DhcpParameterSets] SELFTEST FAIL - expected exactly 1 Get-* hit, got $($hits.Count)." -ForegroundColor Red
    foreach ($h in $hits) { Write-Host "    $($h.Cmd): $($h.Text)" }
    exit 1
}

$root = if ($Path) { $Path } else { Split-Path -Parent $PSScriptRoot }
$files = @(Get-ChildItem -LiteralPath $root -Recurse -Include '*.ps1', '*.psm1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\temp\\|\\\.git\\' -and $_.Name -ne 'Test-DhcpParameterSets.ps1' })

$violations = @()
foreach ($f in $files) {
    $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    $violations += Get-Violation -Text $text -File $f.FullName
}

if ($violations.Count) {
    Write-Host "[Test-DhcpParameterSets] FAILED - $($violations.Count) call(s) pass -ScopeId and -IPAddress together:" -ForegroundColor Red
    foreach ($v in $violations) {
        $rel = $v.File.Replace((Split-Path -Parent $PSScriptRoot), '').TrimStart('\')
        Write-Host ("    {0}:{1}" -f $rel, $v.Line) -ForegroundColor Red
        Write-Host ("        {0}" -f $v.Text.Substring(0, [Math]::Min(130, $v.Text.Length)))
    }
    Write-Host "    These throw 'Parameter set cannot be resolved' before reaching the server. Drop -ScopeId: an" -ForegroundColor Yellow
    Write-Host "    IP belongs to exactly one scope, so -IPAddress alone is already unambiguous." -ForegroundColor Yellow
    exit 1
}

Write-Host "[Test-DhcpParameterSets] OK - no DhcpServer call combines -ScopeId with -IPAddress ($($files.Count) file(s))."
exit 0
