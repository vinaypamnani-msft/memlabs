<#
.SYNOPSIS
    Verifies SQL Always On DNS cleanup retries errors and verifies record removal.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.ScriptBlocks.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.ScriptBlocks.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$watchdogs = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-WithWatchdog'
        }, $true))
if ($watchdogs.Count -ne 1) {
    throw "Expected one DNS scrub Invoke-WithWatchdog function; found $($watchdogs.Count)."
}
Invoke-Expression $watchdogs[0].Extent.Text

$script:WatchdogAttempts = 0
$script:AlwaysFail = $false
function Start-ThreadJob {
    param([scriptblock] $ScriptBlock, [object[]] $ArgumentList, $ErrorAction)
    $script:WatchdogAttempts++
    [pscustomobject]@{ State = 'Completed' }
}
function Wait-Job {
    param($Job, [int] $Timeout)
    return $Job
}
function Receive-Job {
    param($Job, $ErrorAction, [string] $ErrorVariable)
    if ($script:AlwaysFail -or $script:WatchdogAttempts -eq 1) {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('synthetic DNS RPC error'),
            'SyntheticDnsFailure',
            [System.Management.Automation.ErrorCategory]::OperationStopped,
            $null)
        Set-Variable -Name $ErrorVariable -Scope 1 -Value @($record)
    }
}
function Remove-Job {
    param($Job, [switch] $Force, $ErrorAction)
}
function Stop-Job {
    param($Job, $ErrorAction)
}
function Start-Sleep {
    param([int] $Seconds)
}

$watchdogResult = Invoke-WithWatchdog -ScriptBlock {} -MaxAttempts 2 -TimeoutSec 1
if ($watchdogResult.Status -ne 'OK' -or $watchdogResult.Attempts -ne 2 -or $script:WatchdogAttempts -ne 2) {
    throw "Completed job errors were not retried: $($watchdogResult | ConvertTo-Json -Compress)"
}

$script:WatchdogAttempts = 0
$script:AlwaysFail = $true
$watchdogResult = Invoke-WithWatchdog -ScriptBlock {} -MaxAttempts 2 -TimeoutSec 1
if ($watchdogResult.Status -ne 'Error' -or $watchdogResult.Attempts -ne 2 -or
    $watchdogResult.Detail -notmatch 'synthetic DNS RPC error') {
    throw "Final watchdog errors did not retain actionable detail: $($watchdogResult | ConvertTo-Json -Compress)"
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
if ($sourceText -notmatch 'Remove-DnsServerResourceRecord[\s\S]{0,250}-InputObject\s+\$record[\s\S]{0,250}-ErrorAction\s+Stop') {
    throw 'DNS scrub does not remove the exact authoritative DNS record with terminating errors.'
}
if ($sourceText -notmatch 'DNS record \$n\.\$z -> \$rip still exists after removal') {
    throw 'DNS scrub does not verify that stale record removal completed.'
}
if ($sourceText -notmatch 'Resolve-DnsName -Name \$fqdn -Type A -Server \$server -DnsOnly -QuickTimeout -ErrorAction Stop') {
    throw 'DNS scrub pre-check is not pinned to the configured DNS server.'
}
if ($sourceText -notmatch '(?s)elseif \("\$\(\$result\.ScriptBlockOutput\)" -match ''DNS record cleanup skipped\|removal did not complete''\) \{.{0,300}?Write-Log.{0,180}?-Warning') {
    throw 'Incomplete DNS scrub results are not promoted to host warnings.'
}

Write-Host 'PASS -- SQLAO DNS cleanup retries, verifies, and surfaces failures.'
