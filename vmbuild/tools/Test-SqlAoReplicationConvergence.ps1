#requires -Version 5.1
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$Path has $($errors.Count) parse error(s)." }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

$functionalPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
. (Import-TestFunction -Path $functionalPath -Name 'Wait-SqlAoReplicatedTestValue')

$script:ReadAttempts = 0
$script:DelayCalls = 0
$script:ReadServer = ''
$script:ReadQuery = ''
$replicatedValue = "ab'cd"
$eventualRead = {
    param($ServerInstance, $Query)
    $script:ReadAttempts++
    $script:ReadServer = $ServerInstance
    $script:ReadQuery = $Query
    if ($script:ReadAttempts -ge 3) {
        return [pscustomobject]@{ TestValue = $replicatedValue }
    }
    return @()
}
$recordDelay = {
    param($Seconds)
    $script:DelayCalls++
}

$eventualResult = Wait-SqlAoReplicatedTestValue -ServerInstance 'FAB-PS1SQLAO2' -TestValue $replicatedValue `
    -MaxAttempts 5 -RetrySeconds 5 -ReadOperation $eventualRead -DelayOperation $recordDelay
Assert-Equal $true $eventualResult.Success 'secondary redo lag converges within the bounded retry'
Assert-Equal 3 $eventualResult.Attempts 'successful retry reports its attempt count'
Assert-Equal 3 $script:ReadAttempts 'secondary read is retried until the row appears'
Assert-Equal 2 $script:DelayCalls 'delay runs only between failed reads'
Assert-Equal 'FAB-PS1SQLAO2' $script:ReadServer 'configured secondary target is preserved'
Assert-Equal $true ($script:ReadQuery -match "ab''cd") 'test value is escaped in the read query'

$script:ReadAttempts = 0
$script:DelayCalls = 0
$failedRead = {
    param($ServerInstance, $Query)
    $script:ReadAttempts++
    throw 'injected secondary read failure'
}
$failedResult = Wait-SqlAoReplicatedTestValue -ServerInstance 'FAB-PS1SQLAO2' -TestValue 'never-visible' `
    -MaxAttempts 3 -RetrySeconds 5 -ReadOperation $failedRead -DelayOperation $recordDelay
Assert-Equal $false $failedResult.Success 'persistent secondary read errors remain a hard failure'
Assert-Equal 3 $failedResult.Attempts 'persistent read errors stop at the configured bound'
Assert-Equal 'injected secondary read failure' $failedResult.LastError 'terminal failure retains the last query error'
Assert-Equal 3 $script:ReadAttempts 'persistent read errors use every bounded attempt'
Assert-Equal 2 $script:DelayCalls 'persistent read errors do not sleep after the final attempt'

$source = Get-Content -LiteralPath $functionalPath -Raw
Assert-Equal $true ($source -match 'Wait-SqlAoReplicatedTestValue.+?-ServerInstance \$secondaryConnStr') 'shipped Phase 11 validation calls the retry helper'
Assert-Equal $true ($source -match 'redo_queue_size AS RedoQueueKB' -and $source -match 'log_send_queue_size AS LogSendQueueKB') 'timeout diagnostics include send and redo queues'
Assert-Equal $true ($source -match "(?s)availability_databases_cluster adc.+?adc\.database_name = N'TESTDB'") 'timeout diagnostics identify TESTDB by AG database identity'

if ($script:Failures -gt 0) { throw "$script:Failures SQLAO replication convergence assertion(s) failed." }
Write-Host 'PASS: SQLAO replication convergence is bounded, retryable, and diagnostic.'
