<#
.SYNOPSIS
    Verifies bounded Phase 11 CRL retrieval retries.
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

$definitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-CertutilRevocationCheckWithRetry'
        }, $true))
if ($definitions.Count -ne 1) {
    throw "Expected one Invoke-CertutilRevocationCheckWithRetry function; found $($definitions.Count)."
}
Invoke-Expression $definitions[0].Extent.Text

$script:SleepCalls = 0
$script:SleepSeconds = 0
$script:CacheResetCalls = 0
function Start-Sleep {
    param([int]$Seconds)
    $script:SleepCalls++
    $script:SleepSeconds += $Seconds
}
$cacheReset = {
    param($Path)
    $script:CacheResetCalls++
    [pscustomobject]@{ ExitCode = 0; Output = @('cache cleared') }
}

$script:VerifyCalls = 0
$recoveringVerifier = {
    param($Path)
    $script:VerifyCalls++
    if ($script:VerifyCalls -lt 3) {
        return [pscustomobject]@{
            ExitCode = 0
            Output   = @('CERT_TRUST_IS_OFFLINE_REVOCATION')
        }
    }
    [pscustomobject]@{
        ExitCode = 0
        Output   = @('Leaf certificate revocation check passed')
    }
}

$recovered = Invoke-CertutilRevocationCheckWithRetry -CertificatePath 'test.cer' `
    -Attempts 4 -RetrySeconds 15 -Verifier $recoveringVerifier -BeforeRetry $cacheReset
if (-not $recovered.Passed -or $recovered.Attempts -ne 3 -or
    $script:VerifyCalls -ne 3 -or $script:SleepCalls -ne 2 -or $script:SleepSeconds -ne 30) {
    throw "Transient CRL retrieval did not recover with bounded waits: passed=$($recovered.Passed) attempts=$($recovered.Attempts) verifyCalls=$script:VerifyCalls sleepCalls=$script:SleepCalls sleepSeconds=$script:SleepSeconds."
}
if ($script:CacheResetCalls -ne 2) {
    throw "Transient CRL retrieval did not clear the negative CRL cache between attempts: resets=$script:CacheResetCalls."
}

$script:VerifyCalls = 0
$script:SleepCalls = 0
$script:SleepSeconds = 0
$script:CacheResetCalls = 0
$failingVerifier = {
    param($Path)
    $script:VerifyCalls++
    [pscustomobject]@{
        ExitCode = 0
        Output   = @("offline attempt $script:VerifyCalls")
    }
}

$failed = Invoke-CertutilRevocationCheckWithRetry -CertificatePath 'test.cer' `
    -Attempts 4 -RetrySeconds 15 -Verifier $failingVerifier -BeforeRetry $cacheReset
if ($failed.Passed -or $failed.Attempts -ne 4 -or $failed.ExitCode -ne 0 -or
    $failed.Output[-1] -ne 'offline attempt 4' -or $script:SleepCalls -ne 3 -or
    $script:SleepSeconds -ne 45) {
    throw "Exhausted CRL retries did not fail closed with final evidence: passed=$($failed.Passed) attempts=$($failed.Attempts) exit=$($failed.ExitCode) output='$($failed.Output -join '; ')' sleepCalls=$script:SleepCalls sleepSeconds=$script:SleepSeconds."
}
if ($script:CacheResetCalls -ne 3) {
    throw "Exhausted CRL retries did not clear the negative CRL cache between attempts: resets=$script:CacheResetCalls."
}

$script:VerifyCalls = 0
$script:SleepCalls = 0
$script:SleepSeconds = 0
$failingCacheReset = {
    param($Path)
    [pscustomobject]@{ ExitCode = 7; Output = @('cache clear failed') }
}
$cacheFailure = Invoke-CertutilRevocationCheckWithRetry -CertificatePath 'test.cer' `
    -Attempts 3 -RetrySeconds 15 -Verifier $failingVerifier -BeforeRetry $failingCacheReset
if ($cacheFailure.Passed -or @($cacheFailure.RetryDiagnostics).Count -ne 2 -or
    @($cacheFailure.RetryDiagnostics | Where-Object { $_ -match 'exit 7.*cache clear failed' }).Count -ne 2) {
    throw "Native CRL cache-clear failures were not preserved: $($cacheFailure.RetryDiagnostics -join '; ')"
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
if ($sourceText -notmatch 'Invoke-CertutilRevocationCheckWithRetry -CertificatePath \$tmpCer') {
    throw 'Phase 11 certificate validation does not use the bounded CRL retry helper.'
}
if ($sourceText -notmatch 'never reported a passing revocation check after \$\(\$verifyResult\.Attempts\) attempts') {
    throw 'Exhausted CRL diagnostics do not report the measured attempt count.'
}
if ($sourceText -notmatch '(?s)finally \{\s*Remove-Item \$tmpCer') {
    throw 'Phase 11 CRL validation does not clean up the exported certificate in a finally block.'
}
if ($sourceText -notmatch 'certutil\.exe -urlcache CRL delete') {
    throw 'Phase 11 CRL retries do not clear CryptNet negative CRL cache entries.'
}
if ($sourceText -notmatch '\[int\]\$cacheReset\.ExitCode -ne 0') {
    throw 'Phase 11 CRL retries do not inspect the native cache-clear exit code.'
}

Write-Host 'PASS -- Phase 11 retries transient CRL retrieval and fails closed after the bounded attempts.'
