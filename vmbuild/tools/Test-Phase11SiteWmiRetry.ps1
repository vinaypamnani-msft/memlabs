<#
.SYNOPSIS
    Verifies bounded Phase 11 retries for transient ConfigMgr provider query failures.
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

$retryFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-CmWmiQueryWithRetry'
        }, $true))
if ($retryFunctions.Count -ne 1) {
    throw "Expected one Invoke-CmWmiQueryWithRetry function; found $($retryFunctions.Count)."
}
Invoke-Expression $retryFunctions[0].Extent.Text

$ns = 'root\SMS\site_TST'
$results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
$script:WmiAttempts = 0
$script:AlwaysFail = $false

function Get-WmiObject {
    param([string]$Namespace, [string]$Class, [string]$Filter, $ErrorAction)
    $script:WmiAttempts++
    if ($script:AlwaysFail -or $script:WmiAttempts -eq 1) { throw 'Generic failure' }
    [pscustomobject]@{ Name = 'TST' }
}

function Start-Sleep {
    param([int]$Seconds)
}

$rows = @(Invoke-CmWmiQueryWithRetry -Class 'SMS_BoundaryGroup' -Label 'SMS_BoundaryGroup')
if ($rows.Count -ne 1 -or $rows[0].Name -ne 'TST' -or $script:WmiAttempts -ne 2) {
    throw "Transient provider query did not recover on retry: rows=$($rows.Count) attempts=$script:WmiAttempts."
}
if (@($results.Details | Where-Object { $_ -like 'RECOVERED: SMS_BoundaryGroup query succeeded on attempt 2/3*' }).Count -ne 1) {
    throw 'Recovered provider query was not logged explicitly.'
}

$script:WmiAttempts = 0
$script:AlwaysFail = $true
$failure = $null
try { $null = @(Invoke-CmWmiQueryWithRetry -Class 'SMS_BoundaryGroup' -Label 'SMS_BoundaryGroup') }
catch { $failure = $_.Exception.Message }
if ($script:WmiAttempts -ne 3 -or
    $failure -notmatch 'failed after 3 attempts' -or
    $failure -notmatch 'Type=' -or
    $failure -notmatch 'HResult=' -or
    $failure -notmatch 'FQID=') {
    throw "Exhausted provider retries did not retain actionable diagnostics: attempts=$script:WmiAttempts error='$failure'."
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
if ($sourceText -notmatch '\$bgs = @\(Invoke-CmWmiQueryWithRetry -Class ''SMS_BoundaryGroup''') {
    throw 'Boundary-group validation does not use the retry helper.'
}
if ($sourceText -notmatch "Invoke-CmWmiQueryWithRetry -Class 'SMS_SCI_Component'[\s\S]{0,180}-Label 'Client push pipeline component'") {
    throw 'Client-push pipeline validation does not use the retry helper.'
}
if ($sourceText -notmatch 'if \(\$isPrimary\) \{\s*\$results\.Passed = \$false\s*\$results\.Details\.Add\("FAIL: Required Primary boundary groups could not be measured') {
    throw 'Required Primary boundary-group measurement does not fail closed after retry exhaustion.'
}

Write-Host 'PASS -- Phase 11 retries transient site WMI failures and fails closed with diagnostics.'
