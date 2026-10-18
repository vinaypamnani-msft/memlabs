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
$helperTokens = $null
$helperErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'), [ref]$helperTokens, [ref]$helperErrors)
if ($helperErrors.Count) { throw "ScriptFunctions.ps1 has parse errors: $($helperErrors -join '; ')" }
foreach ($name in @('New-SqlAoNodeConnectionString', 'Invoke-SqlAoCommand')) {
    $helper = @($helperAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true))
    if ($helper.Count -ne 1) { throw "Expected one $name definition." }
    . ([scriptblock]::Create($helper[0].Extent.Text))
}
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

function Get-TestPort {
    param([string]$ConnectionString)
    if ($ConnectionString -match '(?i)(?:^|;)Server=[^,;]+,([^;]+)') { return $Matches[1] }
    return '1433'
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
        NodePorts                = [System.Collections.Generic.List[string]]::new()
        MergeCommands            = [System.Collections.Generic.List[string]]::new()
    }

    $commandHook = {
        param($ConnectionString, $CommandText, $TimeoutSeconds, $Scalar)

        $server = Get-TestServer -ConnectionString $ConnectionString
        if ($server -in @('NODE1', 'NODE2')) {
            [void]$script:Scenario.NodePorts.Add((Get-TestPort -ConnectionString $ConnectionString))
        }
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
        if ($CommandText -match 'MERGE dbo\.\[MemLabsAgCanaryBefore_') {
            [void]$script:Scenario.MergeCommands.Add($CommandText)
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
        -Node1Port '1433' `
        -Node2Port '1433' `
        -AvailabilityGroupName 'Test AG' `
        -TestHooks @{
            Command              = $commandHook
            PollAttempts         = 2
            PollSeconds          = 0
            StabilizationSeconds = 60
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
    if ($stage -eq 'ReplicaHealth') {
        Assert-True (@($scenario.Messages | Where-Object {
                    $_ -match 'replica \[NODE2\] did not reach PRIMARY/CONNECTED/HEALTHY/SYNCHRONIZED' -and
                    $_ -match 'Last state: PRIMARY\|DISCONNECTED\|NOT_HEALTHY'
                }).Count -eq 1) 'Replica-health failure did not preserve the exact node and final DMV state.'
    }
}

Assert-True ($definition[0].Extent.Text -match
    '(?s)\$initialDeadline\s*=\s*New-CanaryStageDeadline.+?PRIMARY.+?-DeadlineUtc \$initialDeadline.+?SECONDARY.+?-DeadlineUtc \$initialDeadline') `
    'Initial replica checks do not share one bounded stabilization window.'
Assert-True ($definition[0].Extent.Text -match
    '(?s)\$failoverDeadline\s*=\s*New-CanaryStageDeadline.+?Wait-CanaryListenerOwner.+?\$failoverDeadline.+?PRIMARY.+?\$failoverDeadline.+?SECONDARY.+?\$failoverDeadline') `
    'Post-failover listener and replica checks do not share one bounded stabilization window.'
Assert-True ($definition[0].Extent.Text -match 'listener \[\$ListenerName\] owner attempt') `
    'Listener stabilization does not emit progress heartbeats.'

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
Assert-True ($successScenario.State.NodePorts.Count -gt 0) 'The healthy SQLAO rehearsal did not connect directly to either physical node.'
Assert-True (@($successScenario.State.NodePorts | Where-Object { $_ -ne '1433' }).Count -eq 0) `
    "Physical SQLAO node commands did not consistently use node port 1433: $($successScenario.State.NodePorts -join ', ')."
Assert-True ($successScenario.State.MergeCommands.Count -eq 1) `
    'The healthy SQLAO rehearsal did not exercise synchronized MERGE DML after failover.'
Assert-True ($successScenario.State.MergeCommands[0] -match 'TOP \(8192\)') `
    'The SQLAO MERGE rehearsal no longer uses a substantial source row set.'
Assert-True ($successScenario.State.MergeCommands[0] -match 'DBCC CHECKTABLE') `
    'The SQLAO MERGE rehearsal no longer verifies the target table afterward.'

$cstest5 = Get-Content -LiteralPath (Join-Path $RootPath 'config\tests\CSTest5-A-CSPS-PSHA.json') -Raw |
    ConvertFrom-Json
$cstest5SqlAoNodes = @($cstest5.virtualMachines | Where-Object { $_.role -eq 'SQLAO' })
Assert-True ($cstest5SqlAoNodes.Count -eq 2) 'CSTest5 no longer contains the expected SQLAO pair.'
Assert-True (@($cstest5SqlAoNodes | Where-Object { $_.sqlVersion -ne 'SQL Server 2022' }).Count -eq 0) `
    'CSTest5 SQLAO nodes must use SQL Server 2022 after repeated SQL Server 2019 severity-22 engine failures.'
Assert-True (@($cstest5SqlAoNodes | Where-Object { $_.memory -ne '12GB' }).Count -eq 0) `
    'CSTest5 SQLAO nodes must retain the 12 GB reliability allocation.'

Write-Host 'PASS -- SQLAO canary covers synchronized MERGE, restores the original primary, and independently cleans both tables after every post-failover failure.'
