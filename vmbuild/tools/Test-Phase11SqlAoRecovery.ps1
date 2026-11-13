#requires -Version 5.1
<#
.SYNOPSIS
    Exercises guarded SQLAO rejoin and Phase 11 health verdicts without guest changes.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production scriptblocks consume fixture variables dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath parse errors: $($errors -join '; ')" }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-TestFunction {
    param([string]$Name)
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    Assert-True ($definitions.Count -eq 1) "Expected one $Name definition."
    return $definitions[0]
}

$sqlAoDefinition = Get-TestFunction 'Test-SQLAOFunctionality'
. ([scriptblock]::Create((Get-TestFunction 'Get-SqlAoConfigValue').Extent.Text))
$configAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Config.ps1'), [ref]$null, [ref]$null)
$prefixHelper = @($configAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-VmNamePrefix'
        }, $true))
Assert-True ($prefixHelper.Count -eq 1) 'Expected one shared prefix helper.'
. ([scriptblock]::Create($prefixHelper[0].Extent.Text))
. ([scriptblock]::Create((Get-TestFunction 'Repair-SqlAoReplicaJoin').Extent.Text))
. ([scriptblock]::Create((Get-TestFunction 'Test-SqlAoReplicaHealth').Extent.Text))

function Invoke-RejoinScenario {
    param([string]$Mode)

    $state = [pscustomobject]@{
        Mode = $Mode; Reads = 0; Joins = 0; PrimaryReads = 0
        Queries = [Collections.Generic.List[string]]::new()
    }
    $groupId = [guid]'11111111-1111-1111-1111-111111111111'
    $replicaId = [guid]'22222222-2222-2222-2222-222222222222'
    $details = [Collections.Generic.List[string]]::new()
    $groupName = "Lab ] AG's"
    function Invoke-Sqlcmd {
        param($ServerInstance, $Query, $ConnectionTimeout, $QueryTimeout, [switch]$TrustServerCertificate, $ErrorAction)

        Assert-True ($ConnectionTimeout -eq 10 -and $QueryTimeout -eq 30 -and
            $TrustServerCertificate -and $ErrorAction -eq 'Stop') 'Rejoin lost bounded SQL calls or explicit error handling.'
        Assert-True ($Query -notmatch '\b(DROP|RESTORE|FAILOVER|SEEDING_MODE)\b') 'Rejoin attempted destructive recovery or reseeding.'
        $state.Queries.Add($Query)
        if ($Query -match 'AS PrimaryRole') {
            $state.PrimaryReads++
            Assert-True ($ServerInstance -eq 'NODE1.lab.test\LAB,5143') 'Primary confirmation did not use the physical partner instance and port.'
            Assert-True ($Query.Contains("ag.name = N'Lab ] AG''s'") -and
                $Query.Contains("ar.replica_server_name = N'NODE2\LAB'") -and
                $Query.Contains('rs.is_local = 1')) 'Primary confirmation is not scoped to the exact AG and secondary.'
            if ($Mode -eq 'PrimaryQueryFailure') { throw 'synthetic primary query failure' }
            if ($Mode -eq 'NoPrimary') { return }
            $role = if ($Mode -eq 'PartnerSecondary') { 'SECONDARY' } else { 'PRIMARY' }
            $primaryName = if ($Mode -eq 'WrongPartner') { 'OTHER\LAB' } else { 'NODE1\LAB' }
            $confirmedGroup = if ($Mode -eq 'WrongGroup') { [guid]::Empty } else { $groupId }
            $confirmedReplica = if ($Mode -eq 'WrongReplica') { [guid]::Empty } else { $replicaId }
            $row = [pscustomobject]@{
                GroupId = $confirmedGroup; ReplicaId = $confirmedReplica
                PrimaryRole = $role; PrimaryReplica = $primaryName
            }
            if ($Mode -eq 'DuplicatePrimary') { return @($row, $row) }
            return $row
        }
        Assert-True ($ServerInstance -eq 'localhost\LAB') 'Membership or JOIN used a different local SQL instance.'
        if ($Query -match 'ALTER AVAILABILITY GROUP') {
            $state.Joins++
            Assert-True ($state.PrimaryReads -eq 1 -and $state.Reads -eq 1) 'JOIN ran before both independent membership checks.'
            Assert-True ($Query.Contains("group_id = '$groupId'") -and
                $Query.Contains("replica_id = '$replicaId' AND join_state = 0") -and
                $Query.Contains("SERVERPROPERTY('ServerName')") -and
                $Query.Contains("is_local = 1 AND role_desc = 'PRIMARY'") -and
                $Query.Contains("ALTER AVAILABILITY GROUP [Lab ]] AG's] JOIN;")) 'JOIN lost its identifiers, concurrent-state guard, or escaped AG identifier.'
            if ($Mode -eq 'JoinFailure') { throw 'synthetic JOIN failure' }
            return
        }
        $state.Reads++
        Assert-True ($Query.Contains('sys.availability_groups_cluster') -and
            $Query.Contains('sys.dm_hadr_availability_replica_cluster_states') -and
            $Query.Contains("ag.name = N'Lab ] AG''s'") -and
            $Query.Contains("SERVERPROPERTY('ServerName')")) 'Membership query is not bound to the configured AG and actual SQL instance.'
        if ($Mode -eq 'MembershipQueryFailure') { throw 'synthetic membership query failure' }
        if ($Mode -eq 'NoMembership' -or ($Mode -eq 'NoReadback' -and $state.Reads -gt 1)) { return }
        $joinState = if ($Mode -eq 'Joined' -or ($state.Reads -gt 1 -and $Mode -ne 'Unchanged')) { 1 } else { 0 }
        if ($Mode -eq 'JoinedFci') { $joinState = 2 }
        if ($Mode -eq 'NullState') { $joinState = $null }
        if ($Mode -eq 'DbNullState') { $joinState = [DBNull]::Value }
        if ($Mode -eq 'UnknownState') { $joinState = 3 }
        $localRole = if ($Mode -eq 'LocalPrimary') { 'PRIMARY' } else { $null }
        $name = if ($Mode -eq 'WrongLocal') { 'OTHER\LAB' } else { 'NODE2\LAB' }
        $readbackGroup = if ($Mode -eq 'ChangedGroup' -and $state.Reads -gt 1) { [guid]::Empty } else { $groupId }
        $row = [pscustomobject]@{
            GroupId = $readbackGroup; ReplicaId = $replicaId; Replica = $name
            JoinState = $joinState; JoinStateDescription = "state=$joinState"; LocalRole = $localRole
        }
        if ($Mode -eq 'DuplicateMembership') { return @($row, $row) }
        return $row
    }

    $failure = ''
    $output = @()
    try {
        $output = @(Repair-SqlAoReplicaJoin -ServerInstance 'localhost\LAB' -ReplicaName 'NODE2\LAB' `
            -PartnerServerInstance 'NODE1.lab.test\LAB,5143' -PartnerReplicaName 'NODE1\LAB' `
            -GroupName $groupName -Details $details)
    }
    catch { $failure = $_.Exception.Message }
    Assert-True ($output.Count -eq 0) "$Mode polluted the validation output stream."
    if ($Mode -in @('Joined', 'JoinedFci')) {
        Assert-True (-not $failure -and $state.Reads -eq 1 -and $state.PrimaryReads -eq 0 -and
            $state.Joins -eq 0) "$Mode unnecessarily changed an existing membership: $failure"
    }
    elseif ($Mode -eq 'Rejoin') {
        Assert-True (-not $failure -and $state.Joins -eq 1 -and $state.Reads -eq 2 -and
            @($details | Where-Object { $_ -like 'RECOVERED:*synchronization health still requires validation*' }).Count -eq 1) "Confirmed NOT_JOINED membership was not repaired and read back: $failure"
    }
    else {
        Assert-True ([bool]$failure -and @($details | Where-Object { $_ -like 'RECOVERED:*' }).Count -eq 0) "$Mode was accepted as repaired."
        $expectedJoins = if ($Mode -in @('JoinFailure', 'Unchanged', 'NoReadback', 'ChangedGroup')) { 1 } else { 0 }
        Assert-True ($state.Joins -eq $expectedJoins) "$Mode attempted an unconfirmed or repeated JOIN."
        if ($Mode -like '*QueryFailure' -or $Mode -eq 'JoinFailure') {
            Assert-True ($failure -match 'synthetic') "$Mode lost the original SQL error."
        }
    }
}
foreach ($mode in @('Joined', 'JoinedFci', 'Rejoin', 'NoMembership', 'DuplicateMembership',
        'NullState', 'DbNullState', 'UnknownState', 'WrongLocal', 'LocalPrimary', 'NoPrimary',
        'DuplicatePrimary', 'PartnerSecondary', 'WrongPartner', 'WrongGroup', 'WrongReplica',
        'MembershipQueryFailure', 'PrimaryQueryFailure', 'JoinFailure', 'Unchanged', 'NoReadback', 'ChangedGroup')) {
    Invoke-RejoinScenario -Mode $mode
}

function New-TestReplica {
    param([string]$Name, [string]$Role, [int]$IsLocal, [string]$Connection = 'CONNECTED', [string]$Health = 'HEALTHY', [int]$JoinState = 1)
    [pscustomobject]@{ GroupName = 'Lab AG'; Replica = $Name; Role = $Role; IsLocal = $IsLocal; ConnState = $Connection; Health = $Health; JoinState = $JoinState }
}
$primary = New-TestReplica 'NODE1\LAB' 'PRIMARY' 1
$secondary = New-TestReplica 'NODE2\LAB' 'SECONDARY' 0
$localSecondary = New-TestReplica 'NODE1\LAB' 'SECONDARY' 1
Assert-True (Test-SqlAoReplicaHealth -Replicas @($primary, $secondary) -LocalReplica 'NODE1\LAB' -PartnerReplica 'NODE2\LAB') 'Healthy primary coverage was rejected.'
Assert-True (Test-SqlAoReplicaHealth -Replicas @($localSecondary) -LocalReplica 'NODE1\LAB' -PartnerReplica 'NODE2\LAB') 'A secondary must validate its local DMV row, not require remote DMV rows.'
foreach ($rows in @(
        @{ Rows = @() },
        @{ Rows = @($primary) },
        @{ Rows = @($secondary) },
        @{ Rows = @($primary, $primary) },
        @{ Rows = @($primary, (New-TestReplica 'OTHER\LAB' 'SECONDARY' 0)) },
        @{ Rows = @($primary, (New-TestReplica 'NODE2\LAB' 'PRIMARY' 0)) },
        @{ Rows = @($primary, (New-TestReplica 'NODE2\LAB' 'SECONDARY' 0 'DISCONNECTED' 'HEALTHY')) },
        @{ Rows = @($primary, (New-TestReplica 'NODE2\LAB' 'SECONDARY' 0 'CONNECTED' 'NOT_HEALTHY')) },
        @{ Rows = @($primary, (New-TestReplica 'NODE2\LAB' 'SECONDARY' 0 'CONNECTED' 'HEALTHY' 0)) },
        @{ Rows = @((New-TestReplica 'NODE1\LAB' 'RESOLVING' 1)) },
        @{ Rows = @($localSecondary, $secondary) }
    )) {
    Assert-True (-not (Test-SqlAoReplicaHealth -Replicas $rows.Rows -LocalReplica 'NODE1\LAB' -PartnerReplica 'NODE2\LAB')) 'Missing, unexpected, disconnected, or unhealthy replica coverage was accepted.'
}

$healthQuery = @($sqlAoDefinition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$healthQuery'
        }, $true))
$healthLoop = @($sqlAoDefinition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ForStatementAst] -and
            $node.Initializer.Extent.Text -eq '$attempt = 1' -and $node.Extent.Text.Contains('Test-SqlAoReplicaHealth')
        }, $true))
$restart = @($sqlAoDefinition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '-not $healthy -and -not $agHealthDeferred -and $env:COMPUTERNAME -ieq $recoveryOwner' -and
            $node.Extent.Text.Contains('$stillDisconnected')
        }, $true))
$finalVerdict = @($sqlAoDefinition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '-not $healthy -and -not $agHealthDeferred' -and $node.Extent.Text.Contains('$dbStateQuery')
        }, $true))
Assert-True ($healthQuery.Count -eq 1 -and $healthLoop.Count -eq 1 -and $restart.Count -eq 1 -and
    $finalVerdict.Count -eq 1) 'Expected one shipped health loop, restart recovery, and final verdict.'
$healthInitialization = foreach ($variableName in @('$normalizeReplica', '$expectedReplicaSet', '$isLocalReplica')) {
    $assignments = @($sqlAoDefinition.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq $variableName
            }, $true))
    Assert-True ($assignments.Count -eq 1) "Expected one shipped $variableName assignment."
    $assignments[0].Extent.Text
}
$healthPath = [scriptblock]::Create(@"
$($healthInitialization -join "`n")
$($healthQuery[0].Extent.Text)
`$maxRetries = 5
`$healthy = `$false
`$agHealthDeferred = `$false
$($healthLoop[0].Extent.Text)
$($restart[0].Extent.Text)
$($finalVerdict[0].Extent.Text)
"@)

function Invoke-HealthScenario {
    param([string]$Mode, [bool]$InitiallyPassed = $true)

    $state = [pscustomobject]@{ Reads = 0; Sleeps = 0; AfterHostRecovery = $false }
    $results = @{ Passed = $InitiallyPassed; Details = [Collections.Generic.List[string]]::new() }
    if (-not $InitiallyPassed) { $results.Details.Add('FAIL: independent cluster resource check') }
    $localSqlTarget = 'localhost\LAB'
    $healthSqlTarget = $localSqlTarget
    $localReplicaName = 'NODE1\LAB'
    $otherReplicaName = 'NODE2\LAB'
    $sqlServiceName = 'MSSQL$LAB'
    $otherNode = 'NODE2'
    $agName = "Lab AG's"
    $escapedAgName = $agName.Replace("'", "''")
    $sqlInstName = 'LAB'
    $isDefaultInstance = $false
    $expectedReplicaCsv = 'NODE1\LAB,NODE2\LAB'
    $recoveryOwner = if ($Mode -eq 'NotRecoveryOwner') { 'NODE2' } else { 'NODE1' }
    function Write-Progress { param($Activity, $Status) }
    function Start-Sleep { param($Seconds) $state.Sleeps++ }
    function Restart-Service {
        param($Name, [switch]$Force, $ErrorAction)
        throw 'Guest validation must request host-mediated recovery, not restart SQL directly.'
    }
    function Invoke-Command {
        param($ComputerName, [scriptblock]$ScriptBlock, [object[]]$ArgumentList, $ErrorAction)
        throw 'Guest validation must not use a WinRM second hop for SQL recovery.'
    }
    function Invoke-Sqlcmd {
        param($ServerInstance, $Query, $QueryTimeout, [switch]$TrustServerCertificate, $ErrorAction)
        Assert-True ($ServerInstance -eq 'localhost\LAB' -and $QueryTimeout -eq 30 -and
            $TrustServerCertificate -and $ErrorAction -eq 'Stop') 'Health/recovery query lost its instance, timeout, or explicit error handling.'
        Assert-True ($Query.Contains("ag.name = N'Lab AG''s'")) 'Health or diagnostic query is not scoped to the configured AG.'
        if ($Query -match 'suspend_reason_desc') { return }
        $state.Reads++
        if ($Mode -eq 'InitiallyEmpty' -and $state.Reads -eq 1) { return }
        if ($Mode -eq 'AlwaysEmpty' -or ($Mode -eq 'EmptyAfterRestart' -and $state.AfterHostRecovery)) { return }
        if ($Mode -eq 'PartialCoverage') { return $primary }
        if ($Mode -eq 'HealthyOnSecondary') {
            return @((New-TestReplica 'NODE2\LAB' 'PRIMARY' 1), (New-TestReplica 'NODE1\LAB' 'SECONDARY' 0))
        }
        if ($Mode -in @('InitiallyEmpty', 'InitiallyHealthy') -or
            $state.AfterHostRecovery) { return @($primary, $secondary) }
        if ($Mode -eq 'LocalRestart') {
            return @((New-TestReplica 'NODE1\LAB' 'PRIMARY' 1 'DISCONNECTED' 'NOT_HEALTHY'), $secondary)
        }
        if ($Mode -eq 'UnjoinedPartner') { return @($primary, (New-TestReplica 'NODE2\LAB' 'SECONDARY' 0 'DISCONNECTED' 'NOT_HEALTHY' 0)) }
        return @($primary, (New-TestReplica 'NODE2\LAB' 'SECONDARY' 0 'DISCONNECTED' 'NOT_HEALTHY'))
    }
    $originalComputerName = $env:COMPUTERNAME
    try {
        $env:COMPUTERNAME = 'NODE1'
        . $healthPath
        $shouldRequestRecovery = $Mode -in @('Recovered', 'EmptyAfterRestart', 'StillDisconnected', 'LocalRestart')
        if ($shouldRequestRecovery) {
            $expectedTarget = if ($Mode -eq 'LocalRestart') { 'NODE1' } else { 'NODE2' }
            Assert-True (-not $healthy -and -not $results.Passed -and
                $results.RecoveryTarget -eq $expectedTarget -and
                $results.RecoveryService -eq 'MSSQL$LAB') "$Mode did not request the configured host-mediated SQL restart."
        }
        else {
            Assert-True (-not $results.RecoveryTarget) "$Mode requested a speculative or non-owner restart."
        }
        if ($Mode -in @('Recovered', 'EmptyAfterRestart', 'LocalRestart')) {
            $state.AfterHostRecovery = $true
            $results = @{ Passed = $InitiallyPassed; Details = [Collections.Generic.List[string]]::new() }
            if (-not $InitiallyPassed) { $results.Details.Add('FAIL: independent cluster resource check') }
            . $healthPath
        }
    }
    finally { $env:COMPUTERNAME = $originalComputerName }
    $shouldRecover = $Mode -in @('InitiallyEmpty', 'InitiallyHealthy', 'HealthyOnSecondary', 'Recovered', 'LocalRestart')
    Assert-True ($healthy -eq $shouldRecover -and $results.Passed -eq ($InitiallyPassed -and $shouldRecover)) "$Mode produced an incorrect verdict or erased a prior failure."
    $failures = @($results.Details | Where-Object { $_ -like 'FAIL:*' })
    if ($shouldRecover) {
        Assert-True ($failures.Count -eq [int](-not $InitiallyPassed)) "$Mode logged stale or missing failure verdicts."
    }
    else {
        Assert-True ($failures.Count -gt 0) "$Mode failed without an actionable verdict."
    }
    if ($Mode -eq 'InitiallyEmpty') { Assert-True ($state.Reads -eq 2 -and $state.Sleeps -eq 1) 'A transient empty DMV result did not use the bounded retry.' }
    if ($Mode -in @('AlwaysEmpty', 'PartialCoverage', 'UnjoinedPartner', 'NotRecoveryOwner')) {
        Assert-True ($state.Reads -eq 5 -and -not $results.RecoveryTarget) 'Missing state caused success or a speculative restart.'
    }
    if ($Mode -eq 'EmptyAfterRestart') { Assert-True ($state.Reads -eq 10) 'Empty post-restart state was not retried and failed closed.' }
}
foreach ($mode in @('InitiallyHealthy', 'HealthyOnSecondary', 'InitiallyEmpty', 'AlwaysEmpty', 'PartialCoverage',
        'Recovered', 'EmptyAfterRestart', 'StillDisconnected', 'LocalRestart', 'UnjoinedPartner', 'NotRecoveryOwner')) {
    Invoke-HealthScenario -Mode $mode
}
Invoke-HealthScenario -Mode 'Recovered' -InitiallyPassed $false

$membershipCheck = @($sqlAoDefinition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$agName' -and $node.Extent.Text.Contains('$localTestDb')
        }, $true))
Assert-True ($membershipCheck.Count -eq 1) 'Required local TESTDB membership is not verified.'
& {
    $agName = "Lab AG's"
    $escapedAgName = $agName.Replace("'", "''")
    $localSqlTarget = 'localhost\LAB'
    $progressActivity = 'fixture'
    function Write-Progress { param($Activity, $Status) }
    function Invoke-Sqlcmd {
        param($ServerInstance, $Query, $QueryTimeout, [switch]$TrustServerCertificate, $ErrorAction)
        Assert-True ($ServerInstance -eq 'localhost\LAB' -and $Query.Contains('drs.is_local = 1') -and
            $Query.Contains("ag.name = N'Lab AG''s'")) 'TESTDB membership is not local to the configured AG/instance.'
        if ($Mode -eq 'Missing') { return }
        $id = if ($Mode -eq 'Local') { 5 } elseif ($Mode -eq 'ClusterOnly') { [DBNull]::Value } else { $null }
        [pscustomobject]@{ database_name = 'TESTDB'; LocalDatabaseId = $id }
    }
    foreach ($mode in @('Local', 'ClusterOnly', 'NullLocal', 'Missing')) {
        $results = @{ Passed = $true; Details = [Collections.Generic.List[string]]::new() }
        . ([scriptblock]::Create($membershipCheck[0].Extent.Text))
        Assert-True ($results.Passed -eq ($mode -eq 'Local')) "$mode confused cluster-wide TESTDB metadata with local database membership."
    }
}

$guestAssignment = @($sqlAoDefinition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$scriptBlock'
        }, $true))
Assert-True ($guestAssignment.Count -eq 1) 'Expected one shipped SQLAO guest block.'
$guest = & ([scriptblock]::Create("$($guestAssignment[0].Extent.Text)`n`$scriptBlock"))
$firstHelper = $guest.Ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | Select-Object -First 1
$initializationText = ($guest.Ast.EndBlock.Statements | Where-Object {
        $_.Extent.StartOffset -lt $firstHelper.Extent.StartOffset
    } | ForEach-Object { $_.Extent.Text }) -join "`n"
$targetStart = $guest.ToString().IndexOf('$domain = (Get-CimInstance Win32_ComputerSystem).Domain', [StringComparison]::Ordinal)
$targetEnd = $guest.ToString().IndexOf('$dnsCandidates = @(', $targetStart, [StringComparison]::Ordinal)
Assert-True ($targetStart -ge 0 -and $targetEnd -gt $targetStart) 'Physical partner SQL target setup was not found.'
$targetSetup = [scriptblock]::Create($guest.ToString().Substring($targetStart, $targetEnd - $targetStart))
& {
    function Get-CimInstance { param($ClassName) [pscustomobject]@{ Domain = 'lab.test' } }
    $otherNode = 'NODE2'
    $agName = 'Lab AG'
    foreach ($case in @(
            @{ Instance = 'MSSQLSERVER'; Port = ''; Local = 'localhost'; Partner = 'NODE2.lab.test'; Service = 'MSSQLSERVER' },
            @{ Instance = 'MSSQLSERVER'; Port = '5143'; Local = 'localhost'; Partner = 'NODE2.lab.test,5143'; Service = 'MSSQLSERVER' },
            @{ Instance = 'LAB'; Port = '5144'; Local = 'localhost\LAB'; Partner = 'NODE2.lab.test\LAB,5144'; Service = 'MSSQL$LAB' }
        )) {
        $sqlInstName = $case.Instance
        $otherSqlPort = $case.Port
        . ([scriptblock]::Create($initializationText))
        . $targetSetup
        Assert-True ($localSqlTarget -eq $case.Local -and $otherSqlTarget -eq $case.Partner -and
            $sqlServiceName -eq $case.Service) 'The shipped target setup lost a named instance or physical partner port.'
    }
}

. ([scriptblock]::Create($sqlAoDefinition.Extent.Text))
& {
    $state = [pscustomobject]@{ Calls = 0; Arguments = @(); Guest = $null }
    function Test-SQLFunctionality { param($VMName, $CurrentItem, $DeployConfig) return $true }
    function Write-Log { param($Message, [switch]$LogOnly, [switch]$Warning) }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, [scriptblock]$ScriptBlock, [string[]]$ArgumentList,
            $DisplayName, [switch]$SuppressLog, [switch]$AsJob, $TimeoutSeconds, [switch]$PollProgress)
        Assert-True ($AsJob -and $TimeoutSeconds -eq 600 -and $PollProgress) 'The SQLAO guest call lost its bounded monitored execution.'
        $state.Calls++
        $state.Arguments = $ArgumentList
        $state.Guest = $ScriptBlock
        [pscustomobject]@{ ScriptBlockOutput = @{ Passed = $true; DnsDiagnostics = $null } }
    }
    function Format-TestResult { param($VMName, $RoleLabel, $Result) return $Result.ScriptBlockOutput.Passed }
    $node1 = [pscustomobject]@{
        vmName = 'NODE1'; role = 'SQLAO'; OtherNode = 'NODE2'; sqlInstanceName = 'LAB'; sqlPort = 5143
        AlwaysOnListenerName = 'LISTENER'; AlwaysOnGroupName = 'Lab AG'; AGIPAddress = '192.0.2.20'
        ClusterName = 'LAB-CLUSTER'; ClusterIPAddress = '192.0.2.21'; FileServerVM = 'FS1'
    }
    $node2 = [pscustomobject]@{ vmName = 'NODE2'; role = 'SQLAO'; sqlInstanceName = 'LAB'; sqlPort = 5144 }
    $config = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'lab.test'; prefix = 'LAB-' }
        virtualMachines = @($node1, $node2)
    }
    foreach ($node in @($node1, $node2)) {
        $priorCalls = $state.Calls
        Assert-True (Test-SQLAOFunctionality -VMName $node.vmName -CurrentItem $node -DeployConfig $config) 'The host-to-guest result handoff changed.'
        if ($node.vmName -eq 'NODE1') {
            Assert-True ($state.Arguments.Count -eq 17 -and $state.Arguments[16] -eq '5144' -and
                $state.Guest.Ast.ParamBlock.Parameters.Count -eq 17 -and
                $state.Guest.Ast.ParamBlock.Parameters[16].Name.VariablePath.UserPath -eq 'otherSqlPort' -and
                $state.Guest.ToString().Contains('Repair-SqlAoReplicaJoin -ServerInstance $localSqlTarget')) 'The actual host call dropped the physical partner port or guarded recovery.'
        }
        else {
            Assert-True ($state.Calls -eq $priorCalls) 'The partner repeated shared AG validation or recovery owned by NODE1.'
        }
    }
    $config.virtualMachines = @($node2)
    Assert-True (Test-SQLAOFunctionality -VMName 'NODE2' -CurrentItem $node2 -DeployConfig $config) 'A retained single-node instance no longer uses basic SQL validation.'
    Assert-True ($state.Calls -eq 1) 'The single-node path attempted to repair an absent partner.'
}

Write-Host 'PASS -- SQLAO rejoin requires confirmed NOT_JOINED metadata and an independent primary; exact replica coverage, retries, named instances, local TESTDB membership, and prior failures are verified.'
