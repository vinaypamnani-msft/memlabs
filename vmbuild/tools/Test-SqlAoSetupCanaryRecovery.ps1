#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$installPath = Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "$installPath has parse errors: $($errors -join '; ')" }
$definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-SqlAoSetupCanary'
        }, $true))
if ($definition.Count -ne 1) { throw "Expected one Invoke-SqlAoSetupCanary definition; found $($definition.Count)." }
. ([scriptblock]::Create($definition[0].Extent.Text))

$script:StatusMessages = [System.Collections.Generic.List[string]]::new()
function Write-DscStatus {
    param([string]$Message, [switch]$Failure)
    [void]$script:StatusMessages.Add("$(if ($Failure) { 'FAIL' } else { 'INFO' }):$Message")
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-TestServer {
    param([string]$ConnectionString)
    if ($ConnectionString -match '(?i)(?:^|;)Server=([^,;]+)') { return $Matches[1] }
    return 'LISTENER'
}

function Invoke-RecoveryScenario {
    param([Parameter(Mandatory)][string]$FailureStage)

    $script:StatusMessages.Clear()
    $script:Scenario = [ordered]@{
        FailureStage             = $FailureStage
        Primary                  = 'NODE1'
        ListenerFailuresRemaining = if ($FailureStage -eq 'ListenerStabilization') { 2 } elseif ($FailureStage -eq 'FailbackStabilization') { 2 } else { 0 }
        ReplicaFailuresRemaining = if ($FailureStage -eq 'ReplicaHealth') { 2 } else { 0 }
        PostDdlFailuresRemaining = if ($FailureStage -eq 'PostFailoverDdl') { 1 } else { 0 }
        FailbackFailuresRemaining = if ($FailureStage -eq 'FailbackCommand') { 1 } else { 0 }
        FailoverCommands         = [System.Collections.Generic.List[string]]::new()
        DropAttempts             = [System.Collections.Generic.List[string]]::new()
        TuningCommands           = [System.Collections.Generic.List[string]]::new()
    }

    $commandHook = {
        param($ConnectionString, $CommandText, $TimeoutSeconds, $Scalar)

        $server = Get-TestServer -ConnectionString $ConnectionString
        if ($CommandText -match 'ComputerNamePhysicalNetBIOS') {
            if ($script:Scenario.Primary -eq 'NODE2' -and $script:Scenario.ListenerFailuresRemaining -gt 0) {
                $script:Scenario.ListenerFailuresRemaining--
                return 'WRONGNODE'
            }
            return $script:Scenario.Primary
        }
        if ($CommandText -match 'SESSION_TIMEOUT = 30' -and $CommandText -match 'HEALTH_CHECK_TIMEOUT = 60000') {
            [void]$script:Scenario.TuningCommands.Add($CommandText)
            return
        }
        if ($CommandText -match 'dm_hadr_availability_replica_states') {
            $role = if ($server -ieq $script:Scenario.Primary) { 'PRIMARY' } else { 'SECONDARY' }
            if ($script:Scenario.Primary -eq 'NODE2' -and $server -ieq 'NODE2' -and
                $script:Scenario.ReplicaFailuresRemaining -gt 0) {
                $script:Scenario.ReplicaFailuresRemaining--
                return "$role|DISCONNECTED|NOT_HEALTHY|NOT SYNCHRONIZING|NOT_HEALTHY"
            }
            return "$role|CONNECTED|HEALTHY|SYNCHRONIZED|HEALTHY"
        }
        if ($CommandText -match 'ALTER AVAILABILITY GROUP.+FAILOVER') {
            [void]$script:Scenario.FailoverCommands.Add($server)
            if ($server -ieq 'NODE1' -and $script:Scenario.FailbackFailuresRemaining -gt 0) {
                $script:Scenario.FailbackFailuresRemaining--
                throw 'Synthetic failback command failure.'
            }
            $script:Scenario.Primary = $server
            return
        }
        if ($CommandText -match 'CREATE TABLE dbo\.\[MemLabsAgCanaryAfter_' -and
            $script:Scenario.PostDdlFailuresRemaining -gt 0) {
            $script:Scenario.PostDdlFailuresRemaining--
            throw 'Synthetic post-failover DDL failure.'
        }
        if ($CommandText -match 'DROP TABLE dbo\.\[(MemLabsAgCanary(?:Before|After)_[^\]]+)\]') {
            [void]$script:Scenario.DropAttempts.Add($Matches[1])
            if ($script:Scenario.FailureStage -eq 'Cleanup') {
                throw "Synthetic cleanup failure for $($Matches[1])."
            }
        }
    }

    $result = Invoke-SqlAoSetupCanary `
        -ListenerConnectionString 'Driver={SQL Server};Server=LISTENER,1500;Database=master' `
        -ListenerName 'LISTENER' `
        -Node1 'NODE1' `
        -Node2 'NODE2' `
        -Port '1500' `
        -AvailabilityGroupName 'Test AG' `
        -TestHooks @{
            Command      = $commandHook
            PollAttempts = 2
            PollSeconds  = 0
        }

    return [pscustomobject]@{
        Result   = [bool]$result
        State    = $script:Scenario
        Messages = @($script:StatusMessages)
    }
}

foreach ($stage in @(
        'ListenerStabilization',
        'ReplicaHealth',
        'PostFailoverDdl',
        'FailbackCommand',
        'FailbackStabilization'
    )) {
    $scenario = Invoke-RecoveryScenario -FailureStage $stage
    Assert-True (-not $scenario.Result) "$stage failure was reported as success."
    Assert-True ($scenario.State.Primary -eq 'NODE1') "$stage failure left $($scenario.State.Primary) primary instead of restoring NODE1."
    Assert-True ($scenario.State.FailoverCommands.Count -ge 2) "$stage failure did not attempt a recovery failback."
    Assert-True ($scenario.State.DropAttempts.Count -eq 2) "$stage failure did not attempt both table cleanups."
    Assert-True (@($scenario.Messages | Where-Object { $_ -match 'recovery:.+restored original primary' }).Count -eq 1) `
        "$stage failure did not report successful original-primary recovery."
}

$cleanupScenario = Invoke-RecoveryScenario -FailureStage 'Cleanup'
Assert-True (-not $cleanupScenario.Result) 'Cleanup failures were reported as success.'
Assert-True ($cleanupScenario.State.Primary -eq 'NODE1') 'Cleanup failure changed the final primary.'
Assert-True ($cleanupScenario.State.DropAttempts.Count -eq 2) 'The first cleanup failure prevented the second cleanup attempt.'
Assert-True (@($cleanupScenario.Messages | Where-Object { $_ -match 'cleanup failed for' }).Count -eq 2) `
    'Cleanup failures were not reported independently for both tables.'

$successScenario = Invoke-RecoveryScenario -FailureStage 'None'
Assert-True $successScenario.Result 'The healthy SQLAO rehearsal did not succeed.'
Assert-True ($successScenario.State.Primary -eq 'NODE1') 'The healthy SQLAO rehearsal did not return to the original primary.'
Assert-True ($successScenario.State.DropAttempts.Count -eq 2) 'The healthy SQLAO rehearsal did not remove both canary tables.'
Assert-True ($successScenario.State.TuningCommands.Count -eq 1) 'The healthy SQLAO rehearsal did not apply slow-host timeout tuning.'

Write-Host 'PASS -- SQLAO canary restores the original primary and independently cleans both tables after every post-failover failure.'
