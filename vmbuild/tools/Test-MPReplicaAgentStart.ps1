<#
.SYNOPSIS
    Verifies MP-replica SQL Agent starts are idempotent under schedule races.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\ConfigureMPReplica.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "ConfigureMPReplica.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

function Import-MPReplicaFunction {
    param([string]$Name)
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-MPReplicaFunction -Name 'Get-MPReplicaAgentJobState')
. (Import-MPReplicaFunction -Name 'Start-MPReplicaAgentJob')
. (Import-MPReplicaFunction -Name 'Remove-StaleMPReplicaSiteArtifacts')

$script:StateQueue = [System.Collections.Generic.Queue[object]]::new()
$script:StateQueries = [System.Collections.Generic.List[string]]::new()
$script:StartCalls = 0
$script:StartFailure = ''
$script:CleanupMode = $false
$script:CleanupQueries = [System.Collections.Generic.List[string]]::new()
$script:CleanupPublicationCount = 1
$script:CleanupSubscriptionCount = 0
$script:CleanupPublicationCatalogPresent = 1
$script:CleanupSubscriptionCatalogComplete = 1
$script:CleanupDatabaseIsPublished = 1
$script:CleanupAgentJobCount = 2
function Invoke-ReplSql {
    param([string]$Instance, [string]$Query, [string]$Database)
    if ($script:CleanupMode) {
        $script:CleanupQueries.Add($Query)
        if ($script:CleanupQueries.Count -eq 1) {
            return [pscustomobject]@{
                PublicationCount = $script:CleanupPublicationCount
                SubscriptionCount = $script:CleanupSubscriptionCount
                PublicationCatalogPresent = $script:CleanupPublicationCatalogPresent
                SubscriptionCatalogComplete = $script:CleanupSubscriptionCatalogComplete
                DatabaseIsPublished = $script:CleanupDatabaseIsPublished
                AgentJobCount = $script:CleanupAgentJobCount
            }
        }
        return [pscustomobject]@{
            PublicationCount = 0
            AgentJobCount = 0
        }
    }
    if ($Query -match 'sysjobactivity') {
        $script:StateQueries.Add($Query)
        if ($script:StateQueue.Count -eq 0) { return }
        return , $script:StateQueue.Dequeue()
    }
    if ($Query -match 'sp_start_job') {
        $script:StartCalls++
        if ($script:StartFailure) { throw $script:StartFailure }
        return
    }
    throw "Unexpected SQL query: $Query"
}
function Start-Sleep { param([int]$Seconds) }
function Write-DscStatus { param([string]$Message) }
function Invoke-Command {
    param(
        [string]$ComputerName,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [string]$ErrorAction
    )
    return @('removed share ConfigMgr_MPReplica', 'removed local group ConfigMgr_MPReplicaAccess')
}
function New-State {
    param(
        [bool]$Running,
        [long]$HistoryId = 10,
        [int]$RunStatus = 1,
        [string]$JobName = 'SITE-CM_PRI-ConfigMgr_MPReplica-1',
        [bool]$AgentRunning = $true,
        [bool]$ActivitySaysRunning = $Running,
        [int]$MatchCount = 1,
        [int]$CandidateCount = $MatchCount,
        [string]$SelectionMethod = 'MSreplication_subscriptions'
    )
    $table = [System.Data.DataTable]::new()
    foreach ($columnName in @(
            'JobName', 'MatchCount', 'CandidateCount', 'SelectionMethod',
            'AgentRunning', 'ActivitySaysRunning',
            'IsRunning', 'LastStartTime', 'LastStopTime',
            'LastHistoryInstanceId', 'LastRunStatus'
        )) {
        [void]$table.Columns.Add($columnName, [object])
    }
    $row = $table.NewRow()
    $row.JobName = $JobName
    $row.MatchCount = $MatchCount
    $row.CandidateCount = $CandidateCount
    $row.SelectionMethod = $SelectionMethod
    $row.AgentRunning = [int]$AgentRunning
    $row.ActivitySaysRunning = [int]$ActivitySaysRunning
    $row.IsRunning = [int]$Running
    $row.LastStartTime = [DBNull]::Value
    $row.LastStopTime = [DBNull]::Value
    $row.LastHistoryInstanceId = $HistoryId
    $row.LastRunStatus = $RunStatus
    [void]$table.Rows.Add($row)
    return , $table.Rows
}
function New-EmptyState {
    $table = [System.Data.DataTable]::new()
    [void]$table.Columns.Add('JobName', [object])
    return , $table.Rows
}
function Reset-TestState {
    while ($script:StateQueue.Count -gt 0) { $null = $script:StateQueue.Dequeue() }
    $script:StateQueries.Clear()
    $script:StartCalls = 0
    $script:StartFailure = ''
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $true))
$result = Start-MPReplicaAgentJob -Instance site -Subsystem Snapshot -ReadbackSeconds 0
if ($result.Status -ne 'AlreadyRunning' -or $script:StartCalls -ne 0) {
    throw 'A job already running before the request was not treated as an idempotent success.'
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $true -HistoryId 11))
$script:StateQueue.Enqueue((New-State -Running $false -HistoryId 12 -RunStatus 1))
$result = Start-MPReplicaAgentJob -Instance site -Subsystem Snapshot -RestartIfAlreadyRunning -RunningWaitAttempts 1 -ReadbackSeconds 0
if ($result.Status -ne 'Started' -or $script:StartCalls -ne 1 -or $script:StateQueue.Count -ne 0) {
    throw 'A Snapshot run that predated the subscription was not followed by a fresh run.'
}
if ($script:StateQueries[0] -match 'SubscriberDB|MSreplication_subscriptions') {
    throw "Snapshot job lookup was incorrectly scoped with Distribution-agent metadata: $($script:StateQueries[0])"
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $false))
$result = Start-MPReplicaAgentJob -Instance replica -Database CM_PRI -Subsystem Distribution -ReadbackSeconds 0
if ($result.Status -ne 'Started' -or $script:StartCalls -ne 1) {
    throw 'A stopped agent job was not started normally.'
}
if ($script:StateQueries[0] -notmatch 'MSreplication_subscriptions' -or
    $script:StateQueries[0] -notmatch [regex]::Escape('-SubscriberDB [CM_PRI]')) {
    throw 'Distribution job lookup did not prefer subscription identity and subscriber-database command scope.'
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $false -HistoryId 20))
$script:StateQueue.Enqueue((New-State -Running $true -HistoryId 20))
$script:StartFailure = 'SQLServerAgent Error: Request to run job refused because the job is already running from a request by Schedule 17.'
$snapshotResult = Start-MPReplicaAgentJob -Instance site -Subsystem Snapshot -ReadbackSeconds 0
$script:StartFailure = ''
$script:StateQueue.Enqueue((New-State -Running $false -JobName 'REPLICA-CM_PRI-ConfigMgr_MPReplica-1'))
$distributionResult = Start-MPReplicaAgentJob -Instance replica -Database CM_PRI -Subsystem Distribution -ReadbackSeconds 0
if ($snapshotResult.Status -ne 'RecoveredAlreadyRunning' -or $distributionResult.Status -ne 'Started' -or $script:StartCalls -ne 2) {
    throw 'A scheduled-job collision was not recovered by live job-state readback.'
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $false -HistoryId 30))
$script:StateQueue.Enqueue((New-State -Running $false -HistoryId 31 -RunStatus 1))
$script:StartFailure = 'SQLServerAgent Error: Request to run job refused because the job is already running.'
$result = Start-MPReplicaAgentJob -Instance replica -Subsystem Distribution -ReadbackSeconds 0
if ($result.Status -ne 'RecoveredCompleted') {
    throw 'A job that completed successfully during collision readback was not accepted.'
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $false -HistoryId 40))
$script:StateQueue.Enqueue((New-State -Running $false -HistoryId 40))
$script:StartFailure = 'SQLServerAgent Error: Request to run job refused because the job is already running.'
$collisionFailure = $null
try {
    $null = Start-MPReplicaAgentJob -Instance site -Subsystem Snapshot -ReadbackAttempts 1 -ReadbackSeconds 0
}
catch { $collisionFailure = $_.Exception.Message }
if ($collisionFailure -notmatch 'neither a running job nor a newer successful outcome') {
    throw "An unconfirmed collision did not fail closed: '$collisionFailure'."
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $false -HistoryId 50))
$script:StateQueue.Enqueue((New-State -Running $false -HistoryId 51 -RunStatus 0))
$script:StartFailure = 'SQLServerAgent Error: Request to run job refused because the job is already running.'
$failedOutcome = $null
try {
    $null = Start-MPReplicaAgentJob -Instance replica -Subsystem Distribution -ReadbackSeconds 0
}
catch { $failedOutcome = $_.Exception.Message }
if ($failedOutcome -notmatch 'completed with run_status=0') {
    throw "A collided job with a failed outcome did not fail closed: '$failedOutcome'."
}

$script:CleanupMode = $true
$script:CleanupQueries.Clear()
$siteSqlServer = 'REMOTE-SQL'
$siteSqlConn = 'REMOTE-SQL'
$siteDbName = 'CM_PRI'
$DomainFullName = 'lab.test'
$Tag = '[test]'
$cleanupResult = Remove-StaleMPReplicaSiteArtifacts
$script:CleanupMode = $false
if (-not $cleanupResult -or $script:CleanupQueries.Count -ne 2) {
    throw 'Zero-subscription stale MP replica artifacts were not removed and verified.'
}
if ($script:CleanupQueries[0] -notmatch 'JOIN dbo\.sysarticles' -or
    $script:CleanupQueries[0] -notmatch 'EXEC sys\.sp_executesql' -or
    $script:CleanupQueries[1] -notmatch 'sp_droppublication' -or
    $script:CleanupQueries[1] -notmatch 'EXEC sys\.sp_executesql' -or
    $script:CleanupQueries[1] -notmatch 'sp_replicationdboption' -or
    $script:CleanupQueries[1] -notmatch 'sp_delete_job') {
    throw 'Stale MP replica cleanup did not inventory subscriptions or remove every owned SQL artifact.'
}
foreach ($unsafeStaticCatalogPattern in @(
        'PublicationCount\s*=\s*CASE\s+WHEN\s+OBJECT_ID',
        'DECLARE\s+@remainingPublications\s+int\s*=\s*CASE',
        'ELSE\s+\(SELECT\s+COUNT\(\*\)\s+FROM\s+dbo\.syspublications'
    )) {
    if ($script:CleanupQueries[0] -match $unsafeStaticCatalogPattern -or
        $script:CleanupQueries[1] -match $unsafeStaticCatalogPattern) {
        throw "Absent replication catalogs can still fail SQL batch compilation: $unsafeStaticCatalogPattern"
    }
}

$script:CleanupMode = $true
$script:CleanupQueries.Clear()
$script:CleanupPublicationCount = 0
$script:CleanupSubscriptionCount = 0
$script:CleanupPublicationCatalogPresent = 0
$script:CleanupSubscriptionCatalogComplete = 0
$script:CleanupDatabaseIsPublished = 0
$script:CleanupAgentJobCount = 0
$freshDatabaseResult = Remove-StaleMPReplicaSiteArtifacts
if (-not $freshDatabaseResult -or $script:CleanupQueries.Count -ne 1) {
    throw 'A fresh unpublished site database did not converge as a zero-artifact cleanup state.'
}

$script:CleanupQueries.Clear()
$script:CleanupPublicationCount = 1
$script:CleanupSubscriptionCount = 0
$script:CleanupPublicationCatalogPresent = 1
$script:CleanupSubscriptionCatalogComplete = 0
$script:CleanupDatabaseIsPublished = 1
$script:CleanupAgentJobCount = 0
$incompleteCatalogFailure = $null
try { $null = Remove-StaleMPReplicaSiteArtifacts }
catch { $incompleteCatalogFailure = $_.Exception.Message }
if ($incompleteCatalogFailure -notmatch 'live subscriptions cannot be ruled out') {
    throw "Incomplete replication catalogs did not fail closed: '$incompleteCatalogFailure'."
}

$script:CleanupQueries.Clear()
$script:CleanupPublicationCount = 0
$script:CleanupSubscriptionCount = 0
$script:CleanupPublicationCatalogPresent = 0
$script:CleanupSubscriptionCatalogComplete = 0
$script:CleanupDatabaseIsPublished = 1
$publishedCatalogFailure = $null
try { $null = Remove-StaleMPReplicaSiteArtifacts }
catch { $publishedCatalogFailure = $_.Exception.Message }
if ($publishedCatalogFailure -notmatch 'site database is marked published') {
    throw "A published database with an unavailable publication catalog did not fail closed: '$publishedCatalogFailure'."
}
$script:CleanupPublicationCount = 1
$script:CleanupSubscriptionCount = 0
$script:CleanupPublicationCatalogPresent = 1
$script:CleanupSubscriptionCatalogComplete = 1
$script:CleanupDatabaseIsPublished = 1
$script:CleanupAgentJobCount = 2
$script:CleanupMode = $false

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $true -AgentRunning $false -ActivitySaysRunning $true))
$agentDownFailure = $null
try {
    $null = Start-MPReplicaAgentJob -Instance site -Subsystem Snapshot -ReadbackSeconds 0
}
catch { $agentDownFailure = $_.Exception.Message }
if ($agentDownFailure -notmatch 'SQL Server Agent is not Running' -or $script:StartCalls -ne 0) {
    throw "Stale sysjobactivity with a stopped Agent did not fail closed: '$agentDownFailure'."
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $false -MatchCount 2))
$ambiguousFailure = $null
try {
    $null = Start-MPReplicaAgentJob -Instance replica -Database CM_PRI -Subsystem Distribution -ReadbackSeconds 0
}
catch { $ambiguousFailure = $_.Exception.Message }
if ($ambiguousFailure -notmatch 'Expected one best SQL Agent job' -or $ambiguousFailure -notmatch 'found 2') {
    throw "Ambiguous Distribution job selection did not fail closed: '$ambiguousFailure'."
}

Reset-TestState
$script:StateQueue.Enqueue((New-State -Running $false))
$script:StartFailure = 'SQLServerAgent is not currently running so it cannot be notified of this action.'
$nonCollisionFailure = $null
try {
    $null = Start-MPReplicaAgentJob -Instance site -Subsystem Snapshot -ReadbackSeconds 0
}
catch { $nonCollisionFailure = $_.Exception.Message }
if ($nonCollisionFailure -notmatch 'SQLServerAgent is not currently running') {
    throw "A non-collision start failure was swallowed: '$nonCollisionFailure'."
}

Reset-TestState
$script:StateQueue.Enqueue((New-EmptyState))
$missingFailure = $null
try {
    $null = Start-MPReplicaAgentJob -Instance site -Subsystem Snapshot -ReadbackSeconds 0
}
catch { $missingFailure = $_.Exception.Message }
if ($missingFailure -notmatch 'No SQL Agent job was found') {
    throw "A missing replication job did not fail immediately: '$missingFailure'."
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
if ($sourceText -notmatch 'Test-MPReplicaEnabled -Value \$_.useDatabaseReplica') {
    throw 'ConfigureMPReplica still treats non-empty string False as enabled.'
}
if ($sourceText -notmatch '(?s)\$explicitReplicaIntent.+?\$cleanupRequested.+?useDatabaseReplica=false' -or
    $sourceText -notmatch '(?s)if \(\$cleanupRequested\).+?Remove-StaleMPReplicaSiteArtifacts') {
    throw 'Explicitly disabled MP replicas do not invoke ownership-scoped stale-artifact cleanup.'
}
if ($sourceText -notmatch 'Refusing automatic MP replica teardown:.+subscription') {
    throw 'Stale MP replica cleanup can remove a publication that still has live subscriptions.'
}
foreach ($requiredCleanupSignal in @(
        'sp_droppublication',
        'sp_replicationdboption',
        'sp_delete_job'
    )) {
    if ($sourceText -notmatch [regex]::Escape($requiredCleanupSignal)) {
        throw "Stale MP replica cleanup lost required ownership boundary '$requiredCleanupSignal'."
    }
}
if ($sourceText -notmatch
    "(?s)GetFileName\(\`$sharePath\.TrimEnd\(.+?\)\)\s+-ieq\s+'ConfigMgr_MPReplica'") {
    throw 'Stale MP replica cleanup can recursively delete a directory not owned by the exact ConfigMgr_MPReplica share.'
}
if ($sourceText -notmatch '(?s)replicaSqlServerVM is missing.+?Stopping before STEP 1.+?-Failure') {
    throw 'ConfigureMPReplica no longer fails invalid replica targets before STEP 1.'
}
if ($sourceText -notmatch 'Start-MPReplicaAgentJob -Instance \$siteSqlConn.+-Subsystem Snapshot -RestartIfAlreadyRunning' -or
    $sourceText -notmatch 'Start-MPReplicaAgentJob -Instance \$t\.ReplicaConn.+-Subsystem Distribution') {
    throw 'ConfigureMPReplica does not use the idempotent helper for both agent jobs.'
}
if ($sourceText -notmatch 'MSreplication_subscriptions' -or
    $sourceText -notmatch 'CHARINDEX\(N''-SubscriberDB \[\$databaseSql\]''' -or
    $sourceText -notmatch 'CandidateCount' -or
    $sourceText -notmatch 'sys\.dm_server_services') {
    throw 'Agent state lookup is not ranked by subscription identity/database and live SQL Agent service state.'
}
if ($sourceText -notmatch '(?s)STEP 4.+?if \(\$subscriptionCreated\).+?Start-MPReplicaAgentJob') {
    throw 'Replication agents are started before MP replica permissions are granted.'
}
if ($sourceText -notmatch 'initial replication-agent start did not complete.+bounded initial-sync recovery loop' -or
    $sourceText -notmatch 'Distribution Agent recovery nudge') {
    throw 'Initial agent-start failures do not continue into the bounded recovery loop using the shared helper.'
}

Write-Host 'PASS -- MP replica SQL Agent starts tolerate only read-back-confirmed schedule collisions.'
