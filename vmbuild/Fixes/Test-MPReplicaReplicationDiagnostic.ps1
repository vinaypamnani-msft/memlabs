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
    $siteSqlVMShort = ''
    $replicaVMs = @()

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
        return @{ Report = $out.ToArray(); SiteSqlVM = $siteSqlVMShort; Domain = ''; Replicas = $replicaVMs }
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
        return @{ Report = $out.ToArray(); SiteSqlVM = $siteSqlVMShort; Domain = ''; Replicas = $replicaVMs }
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
    $replicaVMs = @($targets | ForEach-Object { $_.ReplicaVMName } | Select-Object -Unique)
    $replicaConnMap = @{}
    foreach ($t in $targets) { if (-not $replicaConnMap.ContainsKey($t.ReplicaVMName)) { $replicaConnMap[$t.ReplicaVMName] = $t.ReplicaConn } }
    $siteSqlVMShort = (($siteSqlServer -split '\\')[0] -split '\.')[0]

    Section "SITE / PUBLISHER  ($siteSqlConn / $siteDbName, site $SiteCode)"
    Item 'Replica MPs discovered' "$($targets.Count)"
    foreach ($t in $targets) { Item "  $($t.MPName)" "-> $($t.ReplicaConn) / $($t.ReplicaDbName)  (subscriber name: $($t.ReplicaSqlName))" }

    try {
        $agent = Invoke-ReplSql -Instance $siteSqlConn -Query "SELECT status = CONVERT(int, ISNULL((SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status = 4), 0))"
        Item 'SQL Agent running' "$(if ([int]$agent.status -eq 1) { 'YES' } else { 'NO (snapshot/log-reader agents cannot run)' })"
    }
    catch { Item 'SQL Agent running' "query failed: $($_.Exception.Message)" }

    try {
        $spn = Invoke-ReplSql -Instance $siteSqlConn -Query "SELECT n = @@SERVERNAME"
        Item 'Publisher @@SERVERNAME' "$($spn.n)  (replication SP names / registered subscribers must match THIS, not the FQDN)"
    }
    catch { Item 'Publisher @@SERVERNAME' "query failed: $($_.Exception.Message)" }

    try {
        $pub = Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query @"
IF OBJECT_ID('dbo.syspublications') IS NOT NULL
    SELECT name, immediate_sync, allow_pull, status, snap_default = snapshot_in_defaultfolder, alt_snap = ISNULL(alt_snapshot_folder,''),
           arts = (SELECT COUNT(*) FROM dbo.sysarticles a WHERE a.pubid = p.pubid)
    FROM dbo.syspublications p WHERE p.name = 'ConfigMgr_MPReplica'
ELSE SELECT name = CAST(NULL AS sysname), immediate_sync = 0, allow_pull = 0, status = 0, snap_default = 0, alt_snap = '', arts = 0
"@
        if ($pub -and $pub.name) {
            Item 'Publication' "ConfigMgr_MPReplica  status=$($pub.status)  articles=$($pub.arts)  immediate_sync=$($pub.immediate_sync)  allow_pull=$($pub.allow_pull)"
            Item 'Snapshot folder' "snapshot_in_defaultfolder=$($pub.snap_default)  alt_snapshot_folder=$($pub.alt_snap)  (pull agents need the snapshot in the UNC share)"
        }
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

        try { $rn = Invoke-ReplSql -Instance $t.ReplicaConn -Query "SELECT n = @@SERVERNAME"; Item 'Subscriber @@SERVERNAME' "$($rn.n)  (must match the publisher's registered subscriber name)" }
        catch { Item 'Subscriber @@SERVERNAME' "query failed: $($_.Exception.Message)" }

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
    SELECT publisher, publisher_db, subscription_type, update_mode, immediate_sync, last_sync = [time]
    FROM dbo.MSreplication_subscriptions WHERE publication = 'ConfigMgr_MPReplica'
ELSE SELECT publisher = CAST(NULL AS sysname), publisher_db = CAST(NULL AS sysname), subscription_type = 0, update_mode = 0, immediate_sync = 0, last_sync = CAST(NULL AS datetime)
"@
            Emit '  MSreplication_subscriptions (subscriber-side config):'
            $anySub = $false
            foreach ($row in @($sub)) { if ($null -ne $row.publisher) { $anySub = $true; Emit "      publisher=$($row.publisher) db=$($row.publisher_db) sub_type=$($row.subscription_type) update_mode=$($row.update_mode) immediate_sync=$($row.immediate_sync) last_sync=$($row.last_sync)" } }
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
SELECT TOP 10 h.run_status, rd = h.run_date, rt = h.run_time, msg = LEFT(ISNULL(h.[message],''),2500)
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobsteps st ON st.job_id = h.job_id AND st.step_id = h.step_id
WHERE st.subsystem = 'Distribution' AND st.command LIKE '%ConfigMgr_MPReplica%' AND h.step_id > 0
ORDER BY h.run_date DESC, h.run_time DESC
"@
            Emit '  Dist Agent job history (run_status: 0=Fail 1=Succeed 2=Retry 3=Cancel 4=InProgress):'
            $anyH = $false
            foreach ($row in @($jh)) { $anyH = $true; Emit "      --- [$($row.rd) $($row.rt)] run_status=$($row.run_status) ---"; Emit "      $($row.msg)" }
            if (-not $anyH) { Emit '      (no job-history rows -- the Distribution Agent has never actually run)' }
        }
        catch { Item 'Dist Agent history' "query failed: $($_.Exception.Message)" }

        try {
            $tabs = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
DECLARE @xmlr int = 0;
IF OBJECT_ID('dbo.XMLConfigStore') IS NOT NULL SET @xmlr = (SELECT COUNT(*) FROM dbo.XMLConfigStore WHERE Name = 'MPReplicaServiceBrokerConfiguration');
SELECT tables = (SELECT COUNT(*) FROM sys.tables),
       xml_present = CONVERT(int, CASE WHEN OBJECT_ID('dbo.XMLConfigStore') IS NOT NULL THEN 1 ELSE 0 END),
       xml_rows = @xmlr
"@
            Item 'Replicated tables' "$($tabs.tables)  (a full CM DB has ~1000s; a low number = snapshot only partly applied)"
            Item 'XMLConfigStore' "table_present=$($tabs.xml_present)  MPReplicaServiceBrokerConfiguration_rows=$($tabs.xml_rows)"
        }
        catch { Item 'Replica tables' "query failed: $($_.Exception.Message)" }
    }

    Emit ''
    Emit 'Key signal: each replica''s "Dist Agent job history" message reveals WHY the snapshot'
    Emit 'is not applying (login/permission/snapshot-share/connectivity to the distributor).'
    return @{ Report = $out.ToArray(); SiteSqlVM = $siteSqlVMShort; Domain = $DomainFullName; Replicas = $replicaVMs; ReplicaConns = $replicaConnMap }
}

$result = Invoke-VmCommand -VmName $SiteServer -VmDomainName $DomainName -ScriptBlock $diag -ArgumentList $DeployConfigPath -DisplayName "MP replica replication diagnostic" -SuppressLog

if (-not $result -or $result.ScriptBlockFailed) {
    Write-Host "Invoke-VmCommand failed against ${SiteServer}: $($result.ScriptBlockOutput)" -ForegroundColor Red
    return
}
$so = $result.ScriptBlockOutput
$report = if ($null -ne $so.Report) { $so.Report } else { $so }
foreach ($line in @($report)) { Write-Host $line }

# ---------------------------------------------------------------------------
# OS-level: the snapshot + SSB cert exchange all go through the ConfigMgr_MPReplica
# share on the site SQL host. Dump the local group membership + share/NTFS ACLs so
# we can see whether the replica machine accounts are members AND whether the .cer
# files created by BACKUP CERTIFICATE actually inherit the group's Read ACE (a
# missing/broken inherit is why a replica's SQL service can't read the site cert).
# Run directly against the SQL host from the HOST (single-hop PSDirect) to avoid the
# site-server -> SQL-host double hop.
# ---------------------------------------------------------------------------
$siteSqlVM = $so.SiteSqlVM
$dom = if ($so.Domain) { $so.Domain } else { $DomainName }
if ($siteSqlVM) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host "SHARE / GROUP ACLs on the site SQL host ($siteSqlVM)" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
    $aclSb = {
        $o = New-Object System.Collections.Generic.List[string]
        try {
            $g = Get-LocalGroupMember -Group 'ConfigMgr_MPReplicaAccess' -ErrorAction Stop
            $o.Add('  Local group ConfigMgr_MPReplicaAccess members:')
            foreach ($m in $g) { $o.Add("      $($m.Name)  [$($m.ObjectClass)]") }
        }
        catch { $o.Add("  Local group ConfigMgr_MPReplicaAccess: $($_.Exception.Message)") }
        try {
            $share = Get-SmbShare -Name 'ConfigMgr_MPReplica' -ErrorAction Stop
            $o.Add("  Share ConfigMgr_MPReplica -> $($share.Path)")
            $o.Add('  Share-level access (Get-SmbShareAccess):')
            foreach ($a in (Get-SmbShareAccess -Name 'ConfigMgr_MPReplica')) { $o.Add("      $($a.AccountName)  $($a.AccessRight)  $($a.AccessControlType)") }
            $o.Add('  NTFS ACL on the share folder:')
            foreach ($ace in (Get-Acl -Path $share.Path).Access) { $o.Add("      $($ace.IdentityReference)  $($ace.FileSystemRights)  $($ace.AccessControlType)  inherited=$($ace.IsInherited)") }
            foreach ($cf in @(Get-ChildItem -Path (Join-Path $share.Path '*.cer') -ErrorAction SilentlyContinue)) {
                $o.Add("  NTFS ACL on $($cf.Name):")
                foreach ($ace in (Get-Acl -Path $cf.FullName).Access) { $o.Add("      $($ace.IdentityReference)  $($ace.FileSystemRights)  $($ace.AccessControlType)  inherited=$($ace.IsInherited)") }
            }
        }
        catch { $o.Add("  Share ConfigMgr_MPReplica: $($_.Exception.Message)") }
        return , $o.ToArray()
    }
    $aclRes = Invoke-VmCommand -VmName $siteSqlVM -VmDomainName $dom -ScriptBlock $aclSb -DisplayName "MP replica ACL dump" -SuppressLog
    if ($aclRes -and -not $aclRes.ScriptBlockFailed) { foreach ($line in @($aclRes.ScriptBlockOutput)) { Write-Host $line } }
    else { Write-Host "  (ACL dump failed against ${siteSqlVM}: $($aclRes.ScriptBlockOutput))" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
# The pull Distribution Agent runs ON THE REPLICA and connects OUT to the
# distributor by its bare @@SERVERNAME (e.g. -Distributor PT1-PS1SITE). "Agent
# message code 20084 - the process could not connect to Distributor" after ~15s is
# a CONNECT timeout, not a login rejection, so probe the same hop from the same
# box: name resolution, raw TCP, and a real SqlClient login (reporting which port /
# transport actually answered). Also dump the agent job's verbatim command line --
# the switches baked into it (notably -DistributorSecurityMode) decide how it
# authenticates. Read-only.
# ---------------------------------------------------------------------------
$replicaVMs = @($so.Replicas)
$replicaConns = $so.ReplicaConns
if ($replicaVMs.Count -gt 0 -and $siteSqlVM) {
    $probeSb = {
        param($distShort, $domain, $localConn)
        $o = New-Object System.Collections.Generic.List[string]
        $distFqdn = "$distShort.$domain"
        foreach ($n in @($distShort, $distFqdn)) {
            try { $o.Add("  DNS $n -> " + (@([System.Net.Dns]::GetHostAddresses($n) | ForEach-Object { $_.IPAddressToString }) -join ', ')) }
            catch { $o.Add("  DNS $n -> FAILED: $($_.Exception.Message)") }
        }
        foreach ($p in 1433, 4022, 445) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $tc = New-Object System.Net.Sockets.TcpClient
            try {
                $ok = $tc.BeginConnect($distShort, $p, $null, $null).AsyncWaitHandle.WaitOne(6000)
                $o.Add("  TCP ${distShort}:$p -> $(if ($ok -and $tc.Connected) { 'OPEN' } else { 'NO ANSWER (dropped/not listening)' })  [$([int]$sw.ElapsedMilliseconds) ms]")
            }
            catch { $o.Add("  TCP ${distShort}:$p -> ERROR $($_.Exception.Message)  [$([int]$sw.ElapsedMilliseconds) ms]") }
            finally { $tc.Close(); $sw.Stop() }
        }
        foreach ($srv in @($distShort, $distFqdn)) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $c = New-Object System.Data.SqlClient.SqlConnection "Server=$srv;Database=master;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=15"
            try {
                $c.Open()
                $cmd = $c.CreateCommand()
                $cmd.CommandText = "SELECT CONVERT(nvarchar(64), SERVERPROPERTY('MachineName')) + ' port=' + CONVERT(nvarchar(12), ISNULL((SELECT TOP 1 local_tcp_port FROM sys.dm_exec_connections WHERE session_id = @@SPID), 0)) + ' transport=' + ISNULL((SELECT TOP 1 net_transport FROM sys.dm_exec_connections WHERE session_id = @@SPID), '?')"
                $o.Add("  SQL login '$srv' -> OK [$([int]$sw.ElapsedMilliseconds) ms]  $($cmd.ExecuteScalar())")
            }
            catch { $o.Add("  SQL login '$srv' -> FAILED [$([int]$sw.ElapsedMilliseconds) ms]: $($_.Exception.Message)") }
            finally { $c.Dispose(); $sw.Stop() }
        }
        $o.Add('  (probe ran as the diagnostic account; the agent runs as the SQL Agent service account)')
        foreach ($key in 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\MSSQLServer\Client\ConnectTo') {
            try {
                $p = Get-ItemProperty -Path $key -ErrorAction Stop
                $names = @($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
                if ($names.Count -eq 0) { $o.Add("  SQL client aliases ($key): (none)") }
                else { foreach ($n in $names) { $o.Add("  SQL client alias ($key): $($n.Name) = $($n.Value)") } }
            }
            catch { $o.Add("  SQL client aliases ($key): (key not present)") }
        }
        try {
            $c = New-Object System.Data.SqlClient.SqlConnection "Server=$localConn;Database=msdb;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=15"
            $c.Open()
            $cmd = $c.CreateCommand()
            $cmd.CommandText = "SELECT TOP 1 s.command FROM dbo.sysjobsteps s WHERE s.subsystem = 'Distribution' AND s.command LIKE '%ConfigMgr_MPReplica%'"
            $v = $cmd.ExecuteScalar()
            $c.Dispose()
            $o.Add('  Dist Agent job step command line:')
            $o.Add("      $v")
        }
        catch { $o.Add("  Dist Agent job step command: query failed: $($_.Exception.Message)") }
        return , $o.ToArray()
    }
    foreach ($rvm in $replicaVMs) {
        Write-Host ''
        Write-Host ('=' * 78) -ForegroundColor Cyan
        Write-Host "DISTRIBUTOR CONNECTIVITY from replica $rvm  ->  $siteSqlVM" -ForegroundColor Cyan
        Write-Host ('=' * 78) -ForegroundColor Cyan
        $localConn = if ($replicaConns -and $replicaConns[$rvm]) { $replicaConns[$rvm] } else { 'localhost' }
        $pr = Invoke-VmCommand -VmName $rvm -VmDomainName $dom -ScriptBlock $probeSb -ArgumentList $siteSqlVM, $dom, $localConn -DisplayName "Distributor connectivity probe" -SuppressLog
        if ($pr -and -not $pr.ScriptBlockFailed) { foreach ($line in @($pr.ScriptBlockOutput)) { Write-Host $line } }
        else { Write-Host "  (probe failed against ${rvm}: $($pr.ScriptBlockOutput))" -ForegroundColor Yellow }
    }
}
