<#
.SYNOPSIS
    Read-only deep diagnostic for the SQL replication half of ConfigMgr MP database
    replicas (publication -> snapshot -> pull distribution -> replica DB). Explains
    WHY the initial snapshot is / isn't applying to each replica DB.

.DESCRIPTION
    Run this ON THE PRIMARY SITE SERVER (the box that runs ConfigureMPReplica.ps1 in
    Phase 8). It mirrors that script exactly:
      * reads the site SQL instance / DB / site code from this server's registry;
      * rebuilds the replica targets from C:\staging\DSC\deployConfig.json (same logic);
      * uses System.Data.SqlClient (NOT Invoke-Sqlcmd -- absent on a remote-SQL site
        server), integrated auth, TrustServerCertificate.

    It is STRICTLY READ-ONLY (SELECT / sp_help_publication_access / EXEC sp_helptext-free).
    It never creates, drops, alters, reinitializes, or starts anything.

    Focus areas (the current failure = "Distribution Agent history stuck at runstatus 0,
    XMLConfigStore never replicated"):
      SITE/PUBLISHER : SQL Agent state, publication + article count + immediate_sync,
                       the Publication Access List (PAL), registered subscribers, and
                       whether the replica machine accounts have a login on the distributor.
      DISTRIBUTION   : Snapshot Agent + Distribution Agent rows and their recent history
                       from the CMDistribution database.
      EACH REPLICA   : reachability, MSreplication_subscriptions status, the pull
                       Distribution Agent JOB (exists? enabled? schedule?), that job's
                       msdb.sysjobhistory (the REAL per-run error), replicated table count,
                       and XMLConfigStore presence.

.PARAMETER DeployConfigPath
    Override for the deployConfig.json used to discover replica targets.
    Default: C:\staging\DSC\deployConfig.json

.EXAMPLE
    .\Test-MPReplicaReplicationDiagnostic.ps1
#>

[CmdletBinding()]
param(
    [string] $DeployConfigPath = 'C:\staging\DSC\deployConfig.json'
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
}

function Write-Item {
    param([string] $Label, [string] $Value, [string] $Color = 'Gray')
    Write-Host ('  {0,-30} {1}' -f $Label, $Value) -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# System.Data.SqlClient wrapper (identical pattern to ConfigureMPReplica.ps1).
# Returns DataRow objects for result-set queries, or nothing.
# ---------------------------------------------------------------------------
function Invoke-ReplSql {
    param(
        [Parameter(Mandatory)][string] $Instance,
        [Parameter(Mandatory)][string] $Query,
        [string] $Database = 'master'
    )
    $connStr = "Server=$Instance;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=30;Application Name=MemLabs-MPReplicaDiag"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 120
        $reader = $cmd.ExecuteReader()
        try {
            $table = New-Object System.Data.DataTable
            if ($reader.FieldCount -gt 0) {
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    [void]$table.Columns.Add($reader.GetName($i), [object])
                }
                while ($reader.Read()) {
                    $row = $table.NewRow()
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                        $row[$i] = $reader.GetValue($i)
                    }
                    [void]$table.Rows.Add($row)
                }
            }
            while ($reader.NextResult()) { }
        }
        finally {
            $reader.Dispose()
        }
        if ($table.Rows.Count -gt 0) {
            return , $table.Rows
        }
    }
    finally {
        $conn.Dispose()
    }
}

function Get-SqlConnString {
    param([string] $Server, [string] $Instance, [object] $Port)
    $c = $Server
    if ($Instance -and $Instance -ne 'MSSQLSERVER') { $c = "$Server\$Instance" }
    if ($Port -and "$Port" -ne '1433') { $c = "$c,$Port" }
    return $c
}

# ---------------------------------------------------------------------------
# Discover site SQL / DB / site code from registry (same as ConfigureMPReplica).
# ---------------------------------------------------------------------------
$SiteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
$sqlReg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -ErrorAction Stop
$siteSqlServer = $sqlReg.Server
$siteDbRaw = $sqlReg.'Database Name'
if ($siteDbRaw -match '\\') {
    $siteSqlConn = "$siteSqlServer\$($siteDbRaw.Split('\')[0])"
    $siteDbName = $siteDbRaw.Split('\')[1]
}
else {
    $siteSqlConn = $siteSqlServer
    $siteDbName = $siteDbRaw
}

if (-not (Test-Path $DeployConfigPath)) {
    throw "deployConfig not found at $DeployConfigPath (run this on the site server, or pass -DeployConfigPath)."
}
$deployConfig = Get-Content $DeployConfigPath | ConvertFrom-Json
$DomainFullName = $deployConfig.vmOptions.domainName

# ---------------------------------------------------------------------------
# Rebuild replica targets (same logic as ConfigureMPReplica.ps1).
# ---------------------------------------------------------------------------
$replicaMPs = @($deployConfig.virtualMachines | Where-Object {
        $_.role -eq 'SiteSystem' -and $_.installMP -and $_.useDatabaseReplica -and $_.siteCode -eq $SiteCode
    })

$targets = New-Object System.Collections.Generic.List[object]
foreach ($mp in ($replicaMPs | Sort-Object vmName)) {
    $replicaVMName = $mp.replicaSqlServerVM
    $replicaVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $replicaVMName } | Select-Object -First 1
    $replicaInstance = if ($replicaVM -and $replicaVM.sqlInstanceName) { $replicaVM.sqlInstanceName } else { 'MSSQLSERVER' }
    $replicaPort = if ($replicaVM -and $replicaVM.sqlPort) { $replicaVM.sqlPort } else { 1433 }
    $replicaFqdn = "$replicaVMName.$DomainFullName"
    $replicaDbName = if ($mp.replicaDbName) { $mp.replicaDbName } else { "CM_$SiteCode" }
    $targets.Add([pscustomobject]@{
            MPName          = $mp.vmName
            MPAccount       = "$env:USERDOMAIN\$($mp.vmName)`$"
            ReplicaVMName   = $replicaVMName
            ReplicaFqdn     = $replicaFqdn
            ReplicaInstance = $replicaInstance
            ReplicaConn     = (Get-SqlConnString -Server $replicaFqdn -Instance $replicaInstance -Port $replicaPort)
            ReplicaSqlName  = (Get-SqlConnString -Server $replicaFqdn -Instance $replicaInstance -Port 1433)
            ReplicaDbName   = $replicaDbName
            IsLocalToMP     = ($replicaVMName -eq $mp.vmName)
        })
}

Write-Section "SITE / PUBLISHER  ($siteSqlConn / $siteDbName, site $SiteCode)"
Write-Item 'Replica MPs discovered' "$($targets.Count)" 'White'
foreach ($t in $targets) {
    Write-Item "  $($t.MPName)" "-> $($t.ReplicaConn) / $($t.ReplicaDbName)  (subscriber name: $($t.ReplicaSqlName))" 'White'
}

# --- SQL Agent on the distributor ---
try {
    $agent = Invoke-ReplSql -Instance $siteSqlConn -Query "SELECT status = CONVERT(int, ISNULL((SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status = 4), 0))"
    Write-Item 'SQL Agent running' "$(if ([int]$agent.status -eq 1) { 'YES' } else { 'NO (snapshot/log-reader agents cannot run)' })" $(if ([int]$agent.status -eq 1) { 'Green' } else { 'Red' })
}
catch { Write-Item 'SQL Agent running' "query failed: $($_.Exception.Message)" 'Yellow' }

# --- Publication + article count + immediate_sync + allow_pull ---
try {
    $pub = Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query @"
IF OBJECT_ID('dbo.syspublications') IS NOT NULL
    SELECT name, immediate_sync, allow_pull, status,
           arts = (SELECT COUNT(*) FROM dbo.sysarticles a WHERE a.pubid = p.pubid)
    FROM dbo.syspublications p WHERE p.name = 'ConfigMgr_MPReplica'
ELSE SELECT name = CAST(NULL AS sysname), immediate_sync = 0, allow_pull = 0, status = 0, arts = 0
"@
    if ($pub -and $pub.name) {
        Write-Item 'Publication' "ConfigMgr_MPReplica  status=$($pub.status)  articles=$($pub.arts)  immediate_sync=$($pub.immediate_sync)  allow_pull=$($pub.allow_pull)" $(if ([int]$pub.arts -gt 0) { 'Green' } else { 'Red' })
    }
    else { Write-Item 'Publication' 'NOT PRESENT' 'Red' }
}
catch { Write-Item 'Publication' "query failed: $($_.Exception.Message)" 'Yellow' }

# --- Publication Access List (who may connect to pull the snapshot) ---
try {
    $pal = Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "EXEC sys.sp_help_publication_access @publication = N'ConfigMgr_MPReplica'"
    Write-Host '  Publication Access List (PAL):' -ForegroundColor White
    if ($pal) { foreach ($row in @($pal)) { Write-Host "      $($row.loginname)" -ForegroundColor Gray } }
    else { Write-Host '      (empty)' -ForegroundColor Red }
}
catch { Write-Item 'PAL' "query failed: $($_.Exception.Message)" 'Yellow' }

# --- Registered subscribers ---
try {
    $subs = Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query @"
IF OBJECT_ID('dbo.syssubscriptions') IS NOT NULL
    SELECT subscriber = srv.name, s.dest_db, s.status, s.sync_type, s.subscription_type
    FROM (SELECT DISTINCT srvid, dest_db, status, sync_type, subscription_type FROM dbo.syssubscriptions) s
    LEFT JOIN master.sys.servers srv ON srv.server_id = s.srvid
ELSE SELECT subscriber = CAST(NULL AS sysname), dest_db = CAST(NULL AS sysname), status = 0, sync_type = 0, subscription_type = 0
"@
    Write-Host '  Registered subscribers (syssubscriptions):' -ForegroundColor White
    Write-Host '      status: 0=Inactive 1=Subscribed 2=Active | sync_type: 1=auto 2=none | sub_type: 0=push 1=pull' -ForegroundColor DarkGray
    foreach ($row in @($subs)) {
        if ($null -ne $row.subscriber) { Write-Host "      $($row.subscriber)  db=$($row.dest_db)  status=$($row.status)  sync_type=$($row.sync_type)  sub_type=$($row.subscription_type)" -ForegroundColor Gray }
    }
}
catch { Write-Item 'Subscribers' "query failed: $($_.Exception.Message)" 'Yellow' }

# --- Distributor logins for the replica machine accounts / access group ---
try {
    $logins = Invoke-ReplSql -Instance $siteSqlConn -Query "SELECT name, type_desc FROM sys.server_principals WHERE (name LIKE '%ConfigMgr_MPReplicaAccess%' OR name LIKE '%$') AND type IN ('U','G') ORDER BY name"
    Write-Host '  Distributor Windows logins (machine accounts / groups):' -ForegroundColor White
    foreach ($row in @($logins)) { Write-Host "      $($row.name)  [$($row.type_desc)]" -ForegroundColor Gray }
}
catch { Write-Item 'Distributor logins' "query failed: $($_.Exception.Message)" 'Yellow' }

# ---------------------------------------------------------------------------
# DISTRIBUTION DATABASE (CMDistribution on the site SQL server)
# ---------------------------------------------------------------------------
Write-Section "DISTRIBUTION DB  (CMDistribution on $siteSqlConn)"
try {
    $snap = Invoke-ReplSql -Instance $siteSqlConn -Database 'CMDistribution' -Query "SELECT TOP 6 runstatus, [time], cm = LEFT(ISNULL(comments,''),320) FROM dbo.MSsnapshot_history ORDER BY [time] DESC"
    Write-Host '  Snapshot Agent history (runstatus 1=Start 2=Succeed 3=InProgress 4=Idle 5=Retry 6=Fail):' -ForegroundColor White
    foreach ($row in @($snap)) { Write-Host "      [$($row.time)] rs=$($row.runstatus): $($row.cm)" -ForegroundColor Gray }
}
catch { Write-Item 'Snapshot history' "query failed: $($_.Exception.Message)" 'Yellow' }
try {
    $dist = Invoke-ReplSql -Instance $siteSqlConn -Database 'CMDistribution' -Query @"
SELECT TOP 12 h.runstatus, h.[time], sub = da.subscriber_db, cm = LEFT(ISNULL(h.comments,''),320)
FROM dbo.MSdistribution_history h
LEFT JOIN dbo.MSdistribution_agents da ON da.id = h.agent_id
ORDER BY h.[time] DESC
"@
    Write-Host '  Distribution Agent history (distributor side):' -ForegroundColor White
    foreach ($row in @($dist)) { Write-Host "      [$($row.time)] rs=$($row.runstatus) db=$($row.sub): $($row.cm)" -ForegroundColor Gray }
}
catch { Write-Item 'Distribution history' "query failed: $($_.Exception.Message)" 'Yellow' }

# ---------------------------------------------------------------------------
# PER REPLICA (subscriber side -- this is where the real error lives)
# ---------------------------------------------------------------------------
foreach ($t in $targets) {
    Write-Section "REPLICA  $($t.MPName)  ($($t.ReplicaConn) / $($t.ReplicaDbName))"

    try { [void](Invoke-ReplSql -Instance $t.ReplicaConn -Query "SELECT 1 AS c"); Write-Item 'Reachable' 'YES' 'Green' }
    catch { Write-Item 'Reachable' "NO: $($_.Exception.Message)" 'Red'; continue }

    # SQL Agent on the subscriber
    try {
        $ra = Invoke-ReplSql -Instance $t.ReplicaConn -Query "SELECT status = CONVERT(int, ISNULL((SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status = 4), 0))"
        Write-Item 'SQL Agent running' "$(if ([int]$ra.status -eq 1) { 'YES' } else { 'NO (distribution agent job cannot run)' })" $(if ([int]$ra.status -eq 1) { 'Green' } else { 'Red' })
    }
    catch { Write-Item 'SQL Agent running' "query failed: $($_.Exception.Message)" 'Yellow' }

    # Replica DB state
    try {
        $db = Invoke-ReplSql -Instance $t.ReplicaConn -Query @"
SELECT present = CONVERT(int, ISNULL((SELECT 1 FROM sys.databases WHERE name = N'$($t.ReplicaDbName)'),0)),
       broker  = CONVERT(int, ISNULL((SELECT CONVERT(int, is_broker_enabled) FROM sys.databases WHERE name = N'$($t.ReplicaDbName)'),-1)),
       trust   = CONVERT(int, ISNULL((SELECT CONVERT(int, is_trustworthy_on) FROM sys.databases WHERE name = N'$($t.ReplicaDbName)'),-1))
"@
        Write-Item 'Replica DB' "present=$($db.present)  broker_enabled=$($db.broker)  trustworthy=$($db.trust)"
    }
    catch { Write-Item 'Replica DB' "query failed: $($_.Exception.Message)" 'Yellow' }

    # Subscription status on the subscriber
    try {
        $sub = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
IF OBJECT_ID('dbo.MSreplication_subscriptions') IS NOT NULL
    SELECT publisher, publisher_db, subscription_type, status, last_updated, immediate_sync
    FROM dbo.MSreplication_subscriptions WHERE publication = 'ConfigMgr_MPReplica'
ELSE SELECT publisher = CAST(NULL AS sysname), publisher_db = CAST(NULL AS sysname), subscription_type = 0, status = -1, last_updated = CAST(NULL AS datetime), immediate_sync = 0
"@
        Write-Host '  MSreplication_subscriptions (status: 0=Inactive 1=Subscribed 2=Active):' -ForegroundColor White
        $anySub = $false
        foreach ($row in @($sub)) {
            if ($null -ne $row.publisher) { $anySub = $true; Write-Host "      publisher=$($row.publisher) db=$($row.publisher_db) status=$($row.status) last_updated=$($row.last_updated) immediate_sync=$($row.immediate_sync)" -ForegroundColor Gray }
        }
        if (-not $anySub) { Write-Host '      (no subscription row)' -ForegroundColor Red }
    }
    catch { Write-Item 'Subscription' "query failed: $($_.Exception.Message)" 'Yellow' }

    # The pull Distribution Agent JOB: exists? enabled? schedule?
    try {
        $job = Invoke-ReplSql -Instance $t.ReplicaConn -Query @"
SELECT TOP 1 jobname = j.name, j.enabled,
       freq_type = sc.freq_type, freq_subday_type = sc.freq_subday_type,
       freq_subday_interval = sc.freq_subday_interval, sched_enabled = sc.enabled
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps st ON st.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id
WHERE st.subsystem = 'Distribution' AND st.command LIKE '%ConfigMgr_MPReplica%'
"@
        if ($job -and $job.jobname) {
            Write-Item 'Dist Agent job' "$($job.jobname)  enabled=$($job.enabled)  sched_enabled=$($job.sched_enabled)"
            Write-Item '  schedule' "freq_type=$($job.freq_type) (4=daily 64=on-agent-start)  subday_type=$($job.freq_subday_type) (4=minutes)  every=$($job.freq_subday_interval)" $(if ([int]$job.freq_type -eq 4) { 'Green' } else { 'Yellow' })
        }
        else { Write-Item 'Dist Agent job' 'NOT FOUND (subscription/agent not created)' 'Red' }
    }
    catch { Write-Item 'Dist Agent job' "query failed: $($_.Exception.Message)" 'Yellow' }

    # Distribution Agent JOB HISTORY on the subscriber -- the REAL per-run error.
    try {
        $jh = Invoke-ReplSql -Instance $t.ReplicaConn -Query @"
SELECT TOP 8 h.run_status, rd = h.run_date, rt = h.run_time, msg = LEFT(ISNULL(h.[message],''),400)
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobsteps st ON st.job_id = h.job_id AND st.step_id = h.step_id
WHERE st.subsystem = 'Distribution' AND st.command LIKE '%ConfigMgr_MPReplica%' AND h.step_id > 0
ORDER BY h.run_date DESC, h.run_time DESC
"@
        Write-Host '  Dist Agent job history (run_status: 0=Fail 1=Succeed 2=Retry 3=Cancel 4=InProgress):' -ForegroundColor White
        $anyH = $false
        foreach ($row in @($jh)) { $anyH = $true; Write-Host "      [$($row.rd) $($row.rt)] run_status=$($row.run_status): $($row.msg)" -ForegroundColor Gray }
        if (-not $anyH) { Write-Host '      (no job-history rows -- the Distribution Agent has never actually run)' -ForegroundColor Red }
    }
    catch { Write-Item 'Dist Agent history' "query failed: $($_.Exception.Message)" 'Yellow' }

    # How much of the snapshot arrived + the specific table STEP 5 needs.
    try {
        $tabs = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
SELECT tables = (SELECT COUNT(*) FROM sys.tables),
       xml_present = CONVERT(int, CASE WHEN OBJECT_ID('dbo.XMLConfigStore') IS NOT NULL THEN 1 ELSE 0 END),
       xml_rows = CONVERT(int, ISNULL((SELECT COUNT(*) FROM dbo.XMLConfigStore WHERE Name = 'MPReplicaServiceBrokerConfiguration'), 0))
"@
        Write-Item 'Replicated tables' "$($tabs.tables)  (a full CM DB has ~1000s; a low number = snapshot only partly applied)"
        Write-Item 'XMLConfigStore' "table_present=$($tabs.xml_present)  MPReplicaServiceBrokerConfiguration_rows=$($tabs.xml_rows)" $(if ([int]$tabs.xml_rows -gt 0) { 'Green' } else { 'Red' })
    }
    catch { Write-Item 'Replica tables' "query failed: $($_.Exception.Message)" 'Yellow' }
}

Write-Host ''
Write-Host 'Done. Key signal: each replica''s "Dist Agent job history" message reveals why the' -ForegroundColor Cyan
Write-Host 'snapshot is not applying (login/permission/snapshot-share/connectivity to distributor).' -ForegroundColor Cyan
