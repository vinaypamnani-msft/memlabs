<#
.SYNOPSIS
    Read-only deep diagnostic for the SQL replication half of ConfigMgr MP database
    replicas (publication -> snapshot -> pull distribution -> replica DB). Explains
    WHY the initial snapshot is / isn't applying to each replica DB.

.DESCRIPTION
    Run this ON THE MEMLABS HOST (like New-WsusCategoriesBaseline.ps1). It dot-sources
    vmbuild\Common.ps1, finds the primary/CAS site server VM, then uses Invoke-VmCommand
    to run the diagnostic INSIDE the site server (which can reach every replica SQL box).
    The remote scriptblock mirrors ConfigureMPReplica.ps1 exactly:
      * reads the site SQL instance / DB / site code from the site server's registry;
      * rebuilds the replica targets from C:\staging\DSC\deployConfig.json (same logic);
      * uses System.Data.SqlClient (NOT Invoke-Sqlcmd -- absent on a remote-SQL site
        server), integrated auth, TrustServerCertificate.

    It is STRICTLY READ-ONLY. It never creates, drops, alters, reinitializes, or starts
    anything.

    Focus (current failure = "Distribution Agent history stuck at runstatus 0, replica DB
    never receives XMLConfigStore"):
      SITE/PUBLISHER : SQL Agent state, publication + article count + immediate_sync, the
                       Publication Access List (PAL), registered subscribers, distributor
                       machine-account logins.
      DISTRIBUTION   : Snapshot + Distribution agent history from CMDistribution.
      EACH REPLICA   : reachability, MSreplication_subscriptions status, the pull
                       Distribution Agent JOB (enabled + schedule), that job's
                       msdb.sysjobhistory (the REAL per-run error), replicated table count,
                       and XMLConfigStore presence.

.PARAMETER SiteServer
    Site server VM name. Auto-discovered (Primary/CAS from Get-List) when omitted.

.PARAMETER DomainName
    Domain of the site server. Auto-discovered when omitted.

.PARAMETER DeployConfigPath
    deployConfig.json path ON THE GUEST. Default: C:\staging\DSC\deployConfig.json

.EXAMPLE
    .\Fixes\Test-MPReplicaReplicationDiagnostic.ps1

.EXAMPLE
    .\Fixes\Test-MPReplicaReplicationDiagnostic.ps1 -SiteServer MR1-PS1SITE -DomainName mpreplica.com
#>

[CmdletBinding()]
param(
    [string] $SiteServer,
    [string] $DomainName,
    [string] $DeployConfigPath = 'C:\staging\DSC\deployConfig.json'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Bootstrap: dot-source vmbuild\Common.ps1 (same pattern as New-WsusCategoriesBaseline.ps1).
# ---------------------------------------------------------------------------
$RootPath = Split-Path -Path $PSScriptRoot -Parent
. $RootPath\Common.ps1
if ($Common.FatalError) {
    Write-Host "Critical Failure! $($Common.FatalError)" -ForegroundColor Red
    return
}

# ---------------------------------------------------------------------------
# Resolve the site server VM + domain.
# ---------------------------------------------------------------------------
if (-not $SiteServer) {
    $siteVMs = @(Get-List -Type VM | Where-Object { $_.Role -eq 'Primary' -or $_.Role -eq 'CAS' })
    if ($DomainName) { $siteVMs = @($siteVMs | Where-Object { $_.Domain -eq $DomainName }) }
    if ($siteVMs.Count -eq 0) { throw "No Primary/CAS site server VMs found. Pass -SiteServer and -DomainName." }
    if ($siteVMs.Count -gt 1) {
        Write-Host "Multiple site servers found -- specify one with -SiteServer:" -ForegroundColor Yellow
        $siteVMs | ForEach-Object { Write-Host "    $($_.vmName)   domain=$($_.Domain)   role=$($_.Role)" -ForegroundColor Gray }
        throw "Ambiguous site server. Re-run with -SiteServer <name> [-DomainName <domain>]."
    }
    $SiteServer = $siteVMs[0].vmName
    $DomainName = $siteVMs[0].Domain
}
elseif (-not $DomainName) {
    $vm = Get-List -Type VM | Where-Object { $_.vmName -eq $SiteServer } | Select-Object -First 1
    if ($vm) { $DomainName = $vm.Domain }
}
if (-not $DomainName) { throw "Could not determine the domain for $SiteServer; pass -DomainName." }

Write-Host "Running MP replica replication diagnostic inside $SiteServer (domain $DomainName)..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# The diagnostic scriptblock runs ON the site server (PS 5.1). It returns an
# array of report lines (Write-Host inside a remote session is not reliably
# captured, so we accumulate strings and return them).
# ---------------------------------------------------------------------------
$diag = {
    param($DeployConfigPath)

    $out = New-Object System.Collections.Generic.List[string]
    function Emit { param($s) [void]$out.Add([string]$s) }
    function Section { param($t) Emit ''; Emit ('=' * 78); Emit $t; Emit ('=' * 78) }
    function Item { param($l, $v) Emit ('  {0,-30} {1}' -f $l, $v) }

    function Get-SqlConnString {
        param([string]$Server, [string]$Instance, [object]$Port)
        $c = $Server
        if ($Instance -and $Instance -ne 'MSSQLSERVER') { $c = "$Server\$Instance" }
        if ($Port -and "$Port" -ne '1433') { $c = "$c,$Port" }
        return $c
    }

    function Invoke-ReplSql {
        param([Parameter(Mandatory)][string]$Instance, [Parameter(Mandatory)][string]$Query, [string]$Database = 'master')
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
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) { [void]$table.Columns.Add($reader.GetName($i), [object]) }
                    while ($reader.Read()) {
                        $row = $table.NewRow()
                        for ($i = 0; $i -lt $reader.FieldCount; $i++) { $row[$i] = $reader.GetValue($i) }
                        [void]$table.Rows.Add($row)
                    }
                }
                while ($reader.NextResult()) { }
            }
            finally { $reader.Dispose() }
            if ($table.Rows.Count -gt 0) { return , $table.Rows }
        }
        finally { $conn.Dispose() }
    }

    # --- Discover site SQL / DB / site code from registry ---
    try {
        $SiteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
        $sqlReg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -ErrorAction Stop
        $siteSqlServer = $sqlReg.Server
        $siteDbRaw = $sqlReg.'Database Name'
    }
    catch {
        Emit "FATAL: could not read ConfigMgr registry (is this the site server?): $($_.Exception.Message)"
        return , $out.ToArray()
    }
    if ($siteDbRaw -match '\\') {
        $siteSqlConn = "$siteSqlServer\$($siteDbRaw.Split('\')[0])"
        $siteDbName = $siteDbRaw.Split('\')[1]
    }
    else {
        $siteSqlConn = $siteSqlServer
        $siteDbName = $siteDbRaw
    }

    if (-not (Test-Path $DeployConfigPath)) {
        Emit "FATAL: deployConfig not found at $DeployConfigPath on the guest."
        return , $out.ToArray()
    }
    $deployConfig = Get-Content $DeployConfigPath | ConvertFrom-Json
    $DomainFullName = $deployConfig.vmOptions.domainName

    # --- Rebuild replica targets (same logic as ConfigureMPReplica.ps1) ---
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
                ReplicaConn     = (Get-SqlConnString -Server $replicaFqdn -Instance $replicaInstance -Port $replicaPort)
                ReplicaSqlName  = (Get-SqlConnString -Server $replicaFqdn -Instance $replicaInstance -Port 1433)
                ReplicaDbName   = $replicaDbName
                IsLocalToMP     = ($replicaVMName -eq $mp.vmName)
            })
    }

    Section "SITE / PUBLISHER  ($siteSqlConn / $siteDbName, site $SiteCode)"
    Item 'Replica MPs discovered' "$($targets.Count)"
    foreach ($t in $targets) { Item "  $($t.MPName)" "-> $($t.ReplicaConn) / $($t.ReplicaDbName)  (subscriber name: $($t.ReplicaSqlName))" }

    try {
        $agent = Invoke-ReplSql -Instance $siteSqlConn -Query "SELECT status = CONVERT(int, ISNULL((SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status = 4), 0))"
        Item 'SQL Agent running' "$(if ([int]$agent.status -eq 1) { 'YES' } else { 'NO (snapshot/log-reader agents cannot run)' })"
    }
    catch { Item 'SQL Agent running' "query failed: $($_.Exception.Message)" }

    try {
        $pub = Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query @"
IF OBJECT_ID('dbo.syspublications') IS NOT NULL
    SELECT name, immediate_sync, allow_pull, status, arts = (SELECT COUNT(*) FROM dbo.sysarticles a WHERE a.pubid = p.pubid)
    FROM dbo.syspublications p WHERE p.name = 'ConfigMgr_MPReplica'
ELSE SELECT name = CAST(NULL AS sysname), immediate_sync = 0, allow_pull = 0, status = 0, arts = 0
"@
        if ($pub -and $pub.name) { Item 'Publication' "ConfigMgr_MPReplica  status=$($pub.status)  articles=$($pub.arts)  immediate_sync=$($pub.immediate_sync)  allow_pull=$($pub.allow_pull)" }
        else { Item 'Publication' 'NOT PRESENT' }
    }
    catch { Item 'Publication' "query failed: $($_.Exception.Message)" }

    try {
        $pal = Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "EXEC sys.sp_help_publication_access @publication = N'ConfigMgr_MPReplica'"
        Emit '  Publication Access List (PAL) -- who may connect to pull the snapshot:'
        if ($pal) { foreach ($row in @($pal)) { Emit "      $($row.loginname)" } } else { Emit '      (empty)' }
    }
    catch { Item 'PAL' "query failed: $($_.Exception.Message)" }

    try {
        $subs = Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query @"
IF OBJECT_ID('dbo.syssubscriptions') IS NOT NULL
    SELECT subscriber = srv.name, s.dest_db, s.status, s.sync_type, s.subscription_type
    FROM (SELECT DISTINCT srvid, dest_db, status, sync_type, subscription_type FROM dbo.syssubscriptions) s
    LEFT JOIN master.sys.servers srv ON srv.server_id = s.srvid
ELSE SELECT subscriber = CAST(NULL AS sysname), dest_db = CAST(NULL AS sysname), status = 0, sync_type = 0, subscription_type = 0
"@
        Emit '  Registered subscribers (syssubscriptions) -- status: 0=Inactive 1=Subscribed 2=Active:'
        foreach ($row in @($subs)) { if ($null -ne $row.subscriber) { Emit "      $($row.subscriber)  db=$($row.dest_db)  status=$($row.status)  sync_type=$($row.sync_type)  sub_type=$($row.subscription_type)" } }
    }
    catch { Item 'Subscribers' "query failed: $($_.Exception.Message)" }

    try {
        $logins = Invoke-ReplSql -Instance $siteSqlConn -Query "SELECT name, type_desc FROM sys.server_principals WHERE (name LIKE '%ConfigMgr_MPReplicaAccess%' OR name LIKE '%$') AND type IN ('U','G') ORDER BY name"
        Emit '  Distributor Windows logins (machine accounts / access group):'
        foreach ($row in @($logins)) { Emit "      $($row.name)  [$($row.type_desc)]" }
    }
    catch { Item 'Distributor logins' "query failed: $($_.Exception.Message)" }

    Section "DISTRIBUTION DB  (CMDistribution on $siteSqlConn)"
    try {
        $snap = Invoke-ReplSql -Instance $siteSqlConn -Database 'CMDistribution' -Query "SELECT TOP 6 runstatus, [time], cm = LEFT(ISNULL(comments,''),320) FROM dbo.MSsnapshot_history ORDER BY [time] DESC"
        Emit '  Snapshot Agent history (runstatus 1=Start 2=Succeed 3=InProgress 4=Idle 5=Retry 6=Fail):'
        foreach ($row in @($snap)) { Emit "      [$($row.time)] rs=$($row.runstatus): $($row.cm)" }
    }
    catch { Item 'Snapshot history' "query failed: $($_.Exception.Message)" }
    try {
        $dist = Invoke-ReplSql -Instance $siteSqlConn -Database 'CMDistribution' -Query @"
SELECT TOP 12 h.runstatus, h.[time], sub = da.subscriber_db, cm = LEFT(ISNULL(h.comments,''),320)
FROM dbo.MSdistribution_history h
LEFT JOIN dbo.MSdistribution_agents da ON da.id = h.agent_id
ORDER BY h.[time] DESC
"@
        Emit '  Distribution Agent history (distributor side):'
        foreach ($row in @($dist)) { Emit "      [$($row.time)] rs=$($row.runstatus) db=$($row.sub): $($row.cm)" }
    }
    catch { Item 'Distribution history' "query failed: $($_.Exception.Message)" }

    foreach ($t in $targets) {
        Section "REPLICA  $($t.MPName)  ($($t.ReplicaConn) / $($t.ReplicaDbName))"
        try { [void](Invoke-ReplSql -Instance $t.ReplicaConn -Query "SELECT 1 AS c"); Item 'Reachable' 'YES' }
        catch { Item 'Reachable' "NO: $($_.Exception.Message)"; continue }

        try {
            $ra = Invoke-ReplSql -Instance $t.ReplicaConn -Query "SELECT status = CONVERT(int, ISNULL((SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status = 4), 0))"
            Item 'SQL Agent running' "$(if ([int]$ra.status -eq 1) { 'YES' } else { 'NO (distribution agent job cannot run)' })"
        }
        catch { Item 'SQL Agent running' "query failed: $($_.Exception.Message)" }

        try {
            $db = Invoke-ReplSql -Instance $t.ReplicaConn -Query @"
SELECT present = CONVERT(int, ISNULL((SELECT 1 FROM sys.databases WHERE name = N'$($t.ReplicaDbName)'),0)),
       broker  = CONVERT(int, ISNULL((SELECT CONVERT(int, is_broker_enabled) FROM sys.databases WHERE name = N'$($t.ReplicaDbName)'),-1)),
       trust   = CONVERT(int, ISNULL((SELECT CONVERT(int, is_trustworthy_on) FROM sys.databases WHERE name = N'$($t.ReplicaDbName)'),-1))
"@
            Item 'Replica DB' "present=$($db.present)  broker_enabled=$($db.broker)  trustworthy=$($db.trust)"
        }
        catch { Item 'Replica DB' "query failed: $($_.Exception.Message)" }

        try {
            $sub = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
IF OBJECT_ID('dbo.MSreplication_subscriptions') IS NOT NULL
    SELECT publisher, publisher_db, subscription_type, status, last_updated, immediate_sync
    FROM dbo.MSreplication_subscriptions WHERE publication = 'ConfigMgr_MPReplica'
ELSE SELECT publisher = CAST(NULL AS sysname), publisher_db = CAST(NULL AS sysname), subscription_type = 0, status = -1, last_updated = CAST(NULL AS datetime), immediate_sync = 0
"@
            Emit '  MSreplication_subscriptions (status: 0=Inactive 1=Subscribed 2=Active):'
            $anySub = $false
            foreach ($row in @($sub)) { if ($null -ne $row.publisher) { $anySub = $true; Emit "      publisher=$($row.publisher) db=$($row.publisher_db) status=$($row.status) last_updated=$($row.last_updated) immediate_sync=$($row.immediate_sync)" } }
            if (-not $anySub) { Emit '      (no subscription row)' }
        }
        catch { Item 'Subscription' "query failed: $($_.Exception.Message)" }

        try {
            $job = Invoke-ReplSql -Instance $t.ReplicaConn -Query @"
SELECT TOP 1 jobname = j.name, j.enabled, freq_type = sc.freq_type, freq_subday_type = sc.freq_subday_type,
       freq_subday_interval = sc.freq_subday_interval, sched_enabled = sc.enabled
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps st ON st.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id
WHERE st.subsystem = 'Distribution' AND st.command LIKE '%ConfigMgr_MPReplica%'
"@
            if ($job -and $job.jobname) {
                Item 'Dist Agent job' "$($job.jobname)  enabled=$($job.enabled)  sched_enabled=$($job.sched_enabled)"
                Item '  schedule' "freq_type=$($job.freq_type) (4=daily 64=on-agent-start)  subday_type=$($job.freq_subday_type) (4=minutes)  every=$($job.freq_subday_interval)"
            }
            else { Item 'Dist Agent job' 'NOT FOUND (subscription/agent not created)' }
        }
        catch { Item 'Dist Agent job' "query failed: $($_.Exception.Message)" }

        try {
            $jh = Invoke-ReplSql -Instance $t.ReplicaConn -Query @"
SELECT TOP 8 h.run_status, rd = h.run_date, rt = h.run_time, msg = LEFT(ISNULL(h.[message],''),400)
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobsteps st ON st.job_id = h.job_id AND st.step_id = h.step_id
WHERE st.subsystem = 'Distribution' AND st.command LIKE '%ConfigMgr_MPReplica%' AND h.step_id > 0
ORDER BY h.run_date DESC, h.run_time DESC
"@
            Emit '  Dist Agent job history (run_status: 0=Fail 1=Succeed 2=Retry 3=Cancel 4=InProgress):'
            $anyH = $false
            foreach ($row in @($jh)) { $anyH = $true; Emit "      [$($row.rd) $($row.rt)] run_status=$($row.run_status): $($row.msg)" }
            if (-not $anyH) { Emit '      (no job-history rows -- the Distribution Agent has never actually run)' }
        }
        catch { Item 'Dist Agent history' "query failed: $($_.Exception.Message)" }

        try {
            $tabs = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
SELECT tables = (SELECT COUNT(*) FROM sys.tables),
       xml_present = CONVERT(int, CASE WHEN OBJECT_ID('dbo.XMLConfigStore') IS NOT NULL THEN 1 ELSE 0 END),
       xml_rows = CONVERT(int, ISNULL((SELECT COUNT(*) FROM dbo.XMLConfigStore WHERE Name = 'MPReplicaServiceBrokerConfiguration'), 0))
"@
            Item 'Replicated tables' "$($tabs.tables)  (a full CM DB has ~1000s; a low number = snapshot only partly applied)"
            Item 'XMLConfigStore' "table_present=$($tabs.xml_present)  MPReplicaServiceBrokerConfiguration_rows=$($tabs.xml_rows)"
        }
        catch { Item 'Replica tables' "query failed: $($_.Exception.Message)" }
    }

    Emit ''
    Emit 'Key signal: each replica''s "Dist Agent job history" message reveals WHY the snapshot'
    Emit 'is not applying (login/permission/snapshot-share/connectivity to the distributor).'
    return , $out.ToArray()
}

$result = Invoke-VmCommand -VmName $SiteServer -VmDomainName $DomainName -ScriptBlock $diag -ArgumentList $DeployConfigPath -DisplayName "MP replica replication diagnostic" -SuppressLog

if (-not $result -or $result.ScriptBlockFailed) {
    Write-Host "Invoke-VmCommand failed against ${SiteServer}: $($result.ScriptBlockOutput)" -ForegroundColor Red
    return
}
foreach ($line in @($result.ScriptBlockOutput)) { Write-Host $line }
