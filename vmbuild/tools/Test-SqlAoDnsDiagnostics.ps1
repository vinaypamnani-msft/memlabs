<#
.SYNOPSIS
    Verifies SQLAO DNS management/data-plane diagnostics and artifact persistence.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Common.Validation.Functional.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$sqlAoFunction = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-SQLAOFunctionality'
        }, $true))
if ($sqlAoFunction.Count -ne 1) {
    throw "Expected one Test-SQLAOFunctionality definition; found $($sqlAoFunction.Count)."
}
$sqlAoText = $sqlAoFunction[0].Extent.Text

$requiredPatterns = @(
    'DnsDiagnostics',
    'ManagementTargets',
    'ManagementQueries',
    'DataQueries',
    'FailureEvidence',
    'Get-DnsServerResourceRecord',
    'Get-DnsClientNrptPolicy',
    'Microsoft-Windows-WMI-Activity/Operational',
    'Microsoft-Windows-WinRM/Operational',
    'ManagementPlaneUnavailableDataPlaneHealthy',
    'SqlAoDnsMatrix\.json'
)
foreach ($pattern in $requiredPatterns) {
    if ($sqlAoText -notmatch $pattern) {
        throw "SQLAO DNS diagnostics are missing '$pattern'."
    }
}

$fqdnInsert = $sqlAoText.IndexOf('$dnsManagementTargets.Add($logonFqdn)', [StringComparison]::Ordinal)
$ipInsert = $sqlAoText.IndexOf('foreach ($candidate in $dnsCandidates)', [StringComparison]::Ordinal)
if ($fqdnInsert -lt 0 -or $ipInsert -lt 0 -or $fqdnInsert -gt $ipInsert) {
    throw 'DNS management targets are not ordered hostname/FQDN before IP candidates.'
}

$errorFunctions = @($sqlAoFunction[0].FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-DnsWatchdogError'
        }, $true))
if ($errorFunctions.Count -ne 1) {
    throw "Expected one Get-DnsWatchdogError helper; found $($errorFunctions.Count)."
}
Invoke-Expression $errorFunctions[0].Extent.Text

$record = [System.Management.Automation.ErrorRecord]::new(
    [InvalidOperationException]::new('synthetic management failure'),
    'SyntheticDnsManagementFailure',
    [System.Management.Automation.ErrorCategory]::ConnectionError,
    'dc1.contoso.test')
$detail = Get-DnsWatchdogError ([pscustomobject]@{
        Status     = 'Error'
        Attempts   = 2
        Errors     = @($record)
        AttemptLog = @('attempt 1 failed')
    })
if ($detail.Message -ne 'synthetic management failure' -or
    $detail.ExceptionType -ne 'System.InvalidOperationException' -or
    $detail.FullyQualifiedErrorId -ne 'SyntheticDnsManagementFailure' -or
    $detail.Category -ne 'ConnectionError') {
    throw "DNS management errors did not retain actionable metadata: $($detail | ConvertTo-Json -Compress)"
}

$queryFunctions = @($sqlAoFunction[0].FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-DnsManagementQuery'
        }, $true))
if ($queryFunctions.Count -ne 1) {
    throw "Expected one Invoke-DnsManagementQuery helper; found $($queryFunctions.Count)."
}
Invoke-Expression $queryFunctions[0].Extent.Text

$script:ProbeTargets = [System.Collections.Generic.List[string]]::new()
$script:FailureEvidenceCalls = 0
$dnsDiagnostics = [ordered]@{
    ManagementQueries = [System.Collections.Generic.List[object]]::new()
}
Set-Variable -Name results -Scope Script -Value @{
    Details = [System.Collections.Generic.List[string]]::new()
}
function Invoke-WithWatchdog {
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList, [int]$TimeoutSec, [int]$MaxAttempts)
    $target = "$($ArgumentList[2])"
    $script:ProbeTargets.Add($target)
    if ($target -eq 'dc1.contoso.test') {
        return [pscustomobject]@{
            Status     = 'Error'
            Output     = @()
            Errors     = @($record)
            Attempts   = 1
            AttemptLog = @()
        }
    }
    [pscustomobject]@{
        Status     = 'OK'
        Output     = @('192.0.2.55')
        Errors     = @()
        Attempts   = 1
        AttemptLog = @()
    }
}
function Add-DnsManagementFailureEvidence {
    param([string]$Purpose)
    $script:FailureEvidenceCalls++
}

$probe = Invoke-DnsManagementQuery -Purpose Listener -Zone 'contoso.test' -Name 'sql-listener' `
    -Targets @('dc1.contoso.test', '192.0.2.10')
if ($probe.Status -ne 'OK' -or $probe.Target -ne '192.0.2.10' -or
    ($script:ProbeTargets -join ',') -ne 'dc1.contoso.test,192.0.2.10' -or
    $dnsDiagnostics.ManagementQueries.Count -ne 2 -or $script:FailureEvidenceCalls -ne 1) {
    throw "DNS management fallback did not preserve hostname-first probe order and evidence: $($probe | ConvertTo-Json -Compress)"
}

Write-Host 'PASS -- SQLAO DNS diagnostics prefer hostnames and preserve transport failure evidence.'
