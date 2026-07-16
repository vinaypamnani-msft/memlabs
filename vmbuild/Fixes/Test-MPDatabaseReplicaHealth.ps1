<#
.SYNOPSIS
    Read-only health check for ConfigMgr Management Point database replicas and their
    SQL Server Service Broker (BGB / client-notification) plumbing.

.DESCRIPTION
    Run this ON THE PRIMARY SITE SERVER. It auto-discovers everything it needs:
      * the site database SQL instance, database name, and site code (from this server's
        ConfigMgr registry), then connects to the site DB;
      * every Management Point and, for each MP configured to "Use a database replica",
        the replica SQL instance + database (from the MP role properties in the site DB);
      * connects to each replica DB and validates it end-to-end.

    It validates every requirement described in:
      https://learn.microsoft.com/en-us/mem/configmgr/core/servers/deploy/configure/database-replicas-for-management-points

    The script is STRICTLY READ-ONLY. It runs only SELECTs, runtime 'show' of sys.configurations,
    and read-only replication-monitor views. It never CREATE/ALTER/DROP/EXECs anything that
    changes state, and it never touches sys.routes, certificates, or the MP role.

    It answers: "Is each MP database replica correctly configured end-to-end, and why is BGB
    (SMS_NOTIFICATION_MANAGER) throwing 'Route is not defined for ConfigMgrBGB_Site<hash>'?"

.PARAMETER SiteServerSqlInstance
    Optional override. SQL instance hosting the PRIMARY SITE database. Auto-detected from this
    site server's registry (HKLM:\SOFTWARE\Microsoft\SMS\SQL Server) when omitted.

.PARAMETER SiteDbName
    Optional override for the site database name (auto-detected when omitted).

.PARAMETER SiteCode
    Optional override for the three-character site code (auto-detected when omitted).

.PARAMETER RunOSChecks
    Also perform OS-level checks over PowerShell remoting / WMI (local group, file share on the
    site server; SQL identity certificate + local Administrators on each replica server).
    Requires WinRM to the replica servers.

.EXAMPLE
    # On the primary site server, everything auto-detected:
    .\Test-MPDatabaseReplicaHealth.ps1

.EXAMPLE
    # Include OS-level checks over WinRM:
    .\Test-MPDatabaseReplicaHealth.ps1 -RunOSChecks

.NOTES
    Requires the SqlServer (preferred) or SQLPS module for Invoke-Sqlcmd. Run with a login that
    is at least db_datareader on the site + each replica DB (sysadmin gives the fullest picture;
    a few checks note "insufficient permission" otherwise).
#>

[CmdletBinding()]
param(
    [string] $SiteServerSqlInstance,
    [string] $SiteDbName,
    [string] $SiteCode,
    [switch] $RunOSChecks
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[object]

# Cross-section scenario state. Site values are captured once; replica values are
# reset and re-captured for each replica so the restore-vs-replica detector can run
# per replica.
$script:SiteIsPublished     = $null
$script:SiteBrokerGuid      = $null
$script:ReplicaIsSubscribed = $null
$script:ReplicaBrokerGuid   = $null

function Add-Result {
    param(
        [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')] [string] $Status,
        [string] $Area,
        [string] $Check,
        [string] $Detail
    )
    $script:Results.Add([pscustomobject]@{
            Status = $Status; Area = $Area; Check = $Check; Detail = $Detail
        })
    $color = switch ($Status) {
        'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' }
    }
    Write-Host ("[{0,-4}] {1,-22} {2}" -f $Status, $Area, $Check) -ForegroundColor $color
    if ($Detail) { Write-Host ("        -> {0}" -f $Detail) -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------
# SQL helper (read-only)
# ---------------------------------------------------------------------------
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    try { Import-Module SqlServer -ErrorAction Stop }
    catch {
        try { Import-Module SQLPS -DisableNameChecking -ErrorAction Stop }
        catch { throw "Neither the 'SqlServer' nor 'SQLPS' module is available; Invoke-Sqlcmd is required." }
    }
}

function Invoke-Sql {
    param(
        [Parameter(Mandatory)] [string] $Instance,
        [Parameter(Mandatory)] [string] $Query,
        [string] $Database = 'master'
    )
    # TrustServerCertificate for replicas serving Encrypt=True with a self-signed identity cert.
    Invoke-Sqlcmd -ServerInstance $Instance -Database $Database -Query $Query `
        -TrustServerCertificate -QueryTimeout 60 -ErrorAction Stop
}

function Test-SqlConnect {
    param([string] $Instance, [string] $Label)
    try {
        $r = Invoke-Sql -Instance $Instance -Query "SELECT @@SERVERNAME AS ServerName, SERVERPROPERTY('ProductVersion') AS Ver, SERVERPROPERTY('Edition') AS Edition, SERVERPROPERTY('InstanceName') AS Inst"
        Add-Result PASS 'Connectivity' "$Label reachable" "$($r.ServerName)  v$($r.Ver)  $($r.Edition)  instance=$($r.Inst)"
        return $true
    }
    catch {
        Add-Result FAIL 'Connectivity' "$Label unreachable" $_.Exception.Message
        return $false
    }
}

# ---------------------------------------------------------------------------
# Auto-detect the site DB SQL instance, database, and site code from this
# site server's registry. Explicit parameters override the detected values.
#
# Verified against ConfigMgr-Main recoverymanager.cpp (ReadReferenceSite...),
# which is CM's own "read a site server's SQL config from the registry" path:
#   * key   HKLM\SOFTWARE\Microsoft\SMS\SQL Server   (the parent key, NOT the
#           'Site System SQL Account' subkey)
#   * Server         -> SQL server name
#   * 'Database Name' -> "DbNameWithSqlInstance": for a NAMED instance it is
#           stored as 'INSTANCE\DBNAME' -- CM splits on '\' and takes the LEFT
#           part as the instance name and the RIGHT part as the database name
#           (default instance = no backslash, so Database Name is the DB only).
#   * Site code      -> HKLM\SOFTWARE\Microsoft\SMS\Identification : 'Site Code'
# ---------------------------------------------------------------------------
function Get-LocalSiteInfo {
    try {
        $siteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
        $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -ErrorAction Stop
        $server = $p.Server
        $dbRaw = $p.'Database Name'
        if ($dbRaw -match '\\') {
            $instance = "$server\$($dbRaw.Split('\')[0])"
            $db = $dbRaw.Split('\')[1]
        }
        else {
            $instance = $server
            $db = $dbRaw
        }
        return [pscustomobject]@{ Instance = $instance; Database = $db; SiteCode = $siteCode }
    }
    catch { return $null }
}

Write-Host "`n===== ConfigMgr MP Database Replica Health Check =====" -ForegroundColor Cyan

$detected = Get-LocalSiteInfo
if ($detected) {
    Add-Result INFO 'Discovery' 'Site auto-detected from registry' "instance=$($detected.Instance) db=$($detected.Database) site=$($detected.SiteCode)"
    if (-not $SiteServerSqlInstance) { $SiteServerSqlInstance = $detected.Instance }
    if (-not $SiteDbName) { $SiteDbName = $detected.Database }
    if (-not $SiteCode) { $SiteCode = $detected.SiteCode }
}

if (-not $SiteServerSqlInstance -or -not $SiteDbName -or -not $SiteCode) {
    Write-Host "`nCould not auto-detect the site database (not running on a site server?)." -ForegroundColor Red
    Write-Host "Supply -SiteServerSqlInstance, -SiteDbName and -SiteCode explicitly." -ForegroundColor Red
    return
}

Write-Host ("Site DB   : {0} / {1}   (site {2})`n" -f $SiteServerSqlInstance, $SiteDbName, $SiteCode)

if (-not (Test-SqlConnect -Instance $SiteServerSqlInstance -Label 'Site DB SQL')) {
    Write-Host "`nCannot continue without connectivity to the site database." -ForegroundColor Red
    return
}

# ---------------------------------------------------------------------------
# 1. PREREQUISITES (per-instance)
# ---------------------------------------------------------------------------
function Test-InstancePrereqs {
    param([string] $Instance, [string] $DbName, [string] $Label, [bool] $IsReplica)

    # 1a. SQL Server Agent running (sys.dm_server_services)
    try {
        $svc = Invoke-Sql -Instance $Instance -Query @"
SELECT servicename, status_desc, service_account, startup_type_desc
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server Agent%' OR servicename LIKE 'SQL Server (%'
"@
        $agent = $svc | Where-Object { $_.servicename -like 'SQL Server Agent*' }
        if ($agent) {
            if ($agent.status_desc -eq 'Running') {
                Add-Result PASS "$Label Prereq" 'SQL Server Agent running' "$($agent.servicename) [$($agent.startup_type_desc)] as $($agent.service_account)"
            }
            else {
                Add-Result FAIL "$Label Prereq" 'SQL Server Agent NOT running' "$($agent.servicename) status=$($agent.status_desc) startup=$($agent.startup_type_desc) (doc: set to automatic + running)"
            }
        }
        else {
            Add-Result WARN "$Label Prereq" 'SQL Server Agent status unknown' 'Agent service not returned by sys.dm_server_services'
        }

        # 1b. SQL Server service account (doc: replica SQL service MUST run as System)
        $engine = $svc | Where-Object { $_.servicename -like 'SQL Server (*' } | Select-Object -First 1
        if ($engine) {
            $acct = $engine.service_account
            if ($IsReplica) {
                if ($acct -match '(?i)LocalSystem|NT AUTHORITY\\SYSTEM') {
                    Add-Result PASS "$Label Prereq" 'SQL engine runs as System' $acct
                }
                else {
                    Add-Result WARN "$Label Prereq" 'SQL engine NOT running as System' "$acct  (doc requires the replica SQL Server service to run as the System account; if it uses another account, share ACLs must name that account instead of SYSTEM)"
                }
            }
            else {
                Add-Result INFO "$Label Prereq" 'SQL engine service account' $acct
            }
        }
    }
    catch {
        Add-Result WARN "$Label Prereq" 'Service state query failed' "$($_.Exception.Message) (needs VIEW SERVER STATE)"
    }

    # 1c. max text repl size = 2 GB (2147483647)
    try {
        $cfg = Invoke-Sql -Instance $Instance -Query "SELECT name, CAST(value_in_use AS bigint) AS v FROM sys.configurations WHERE name = 'max text repl size (B)'"
        if ($cfg) {
            if ([int64]$cfg.v -eq 2147483647 -or [int64]$cfg.v -eq -1) {
                Add-Result PASS "$Label Prereq" "'max text repl size' = 2 GB" "value_in_use=$($cfg.v)"
            }
            else {
                Add-Result FAIL "$Label Prereq" "'max text repl size' NOT 2 GB" "value_in_use=$($cfg.v)  (doc: configure both SQL Servers to 2147483647)"
            }
        }
    }
    catch { Add-Result WARN "$Label Prereq" "'max text repl size' query failed" $_.Exception.Message }

    # 1d. CLR enabled = 1 (doc: enable on the replica)
    try {
        $clr = Invoke-Sql -Instance $Instance -Query "SELECT CAST(value_in_use AS int) AS v FROM sys.configurations WHERE name = 'clr enabled'"
        if ($clr) {
            if ([int]$clr.v -eq 1) { Add-Result PASS "$Label Prereq" "'clr enabled' = 1" '' }
            elseif ($IsReplica) { Add-Result FAIL "$Label Prereq" "'clr enabled' = 0 on replica" "doc Step 2.5: exec sp_configure 'clr enabled',1; RECONFIGURE WITH OVERRIDE" }
            else { Add-Result INFO "$Label Prereq" "'clr enabled' = 0" 'CLR is only mandated on the replica' }
        }
    }
    catch { Add-Result WARN "$Label Prereq" "'clr enabled' query failed" $_.Exception.Message }

    # 1e. Service Broker enabled + honor priority on the DB
    try {
        $db = Invoke-Sql -Instance $Instance -Query @"
SELECT name, is_broker_enabled, is_honor_broker_priority_on, is_trustworthy_on,
       service_broker_guid, is_published, is_subscribed, is_merge_published, is_distributor
FROM sys.databases WHERE name = N'$DbName'
"@
        if (-not $db) {
            Add-Result FAIL "$Label Prereq" "Database '$DbName' not found on $Instance" ''
            return
        }
        # Capture scenario state for the restore-vs-replica detector.
        if ($IsReplica) {
            $script:ReplicaIsSubscribed = [bool]$db.is_subscribed
            $script:ReplicaBrokerGuid = [string]$db.service_broker_guid
        }
        else {
            $script:SiteIsPublished = [bool]$db.is_published
            $script:SiteBrokerGuid = [string]$db.service_broker_guid
        }
        if ($db.is_broker_enabled) { Add-Result PASS "$Label SSB" "Service Broker ENABLED on '$DbName'" "broker_guid=$($db.service_broker_guid)" }
        else { Add-Result FAIL "$Label SSB" "Service Broker DISABLED on '$DbName'" "doc Step 5.1: ALTER DATABASE [$DbName] SET ENABLE_BROKER, HONOR_BROKER_PRIORITY ON WITH ROLLBACK IMMEDIATE" }

        if ($db.is_honor_broker_priority_on) { Add-Result PASS "$Label SSB" 'HONOR_BROKER_PRIORITY ON' '' }
        else { Add-Result WARN "$Label SSB" 'HONOR_BROKER_PRIORITY not ON' "doc Step 5.1 sets HONOR_BROKER_PRIORITY ON" }

        # 1f. TRUSTWORTHY (doc: ON for the replica DB)
        if ($IsReplica) {
            if ($db.is_trustworthy_on) { Add-Result PASS "$Label Prereq" 'TRUSTWORTHY ON (replica)' '' }
            else { Add-Result FAIL "$Label Prereq" 'TRUSTWORTHY OFF on replica' "doc Step 2.3: ALTER DATABASE [$DbName] SET TRUSTWORTHY ON;" }
        }

        # 1g. Replication flags (publisher must publish; replica must subscribe)
        if ($IsReplica) {
            if ($db.is_subscribed) { Add-Result PASS "$Label Repl" "Replica DB is a subscriber" '' }
            else { Add-Result FAIL "$Label Repl" "Replica DB is NOT subscribed" 'No transactional-replication subscription found. A plain RESTORE is not a replica — doc Step 2 (New Subscription Wizard) was not completed.' }
        }
        else {
            if ($db.is_published) { Add-Result PASS "$Label Repl" 'Site DB is published' '' }
            else { Add-Result FAIL "$Label Repl" 'Site DB is NOT published' 'doc Step 1.5: EXEC spCreateMPReplicaPublication — publication missing.' }
        }
    }
    catch { Add-Result WARN "$Label SSB" 'sys.databases query failed' $_.Exception.Message }
}

# ---------------------------------------------------------------------------
# 2. SQL SERVICE BROKER ENDPOINT (TCP 4022)
# ---------------------------------------------------------------------------
function Test-SsbEndpoint {
    param([string] $Instance, [string] $Label)
    try {
        $ep = Invoke-Sql -Instance $Instance -Query @"
SELECT e.name, e.state_desc, e.is_message_forwarding_enabled, e.connection_auth_desc,
       hasCert = CASE WHEN e.certificate_id > 0 THEN 1 ELSE 0 END, t.port
FROM sys.service_broker_endpoints e
JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id
"@
        if (-not $ep) {
            Add-Result WARN "$Label SSB" 'No Service Broker TCP endpoint returned' 'Either no SSB endpoint exists (BGB replica routing needs ''ConfigMgrEndpoint'' on TCP 4022 with certificate auth) OR the login lacks VIEW ANY DEFINITION to see endpoint metadata. Re-run as sysadmin to be certain.'
            return $null
        }
        foreach ($e in @($ep)) {
            $st = if ($e.state_desc -eq 'STARTED') { 'PASS' } else { 'FAIL' }
            $authNote = "auth=$($e.connection_auth_desc) cert=$(if ($e.hasCert) {'yes'} else {'NO'})"
            Add-Result $st "$Label SSB" "SSB endpoint '$($e.name)' port $($e.port)" "state=$($e.state_desc)  $authNote"
            if (-not $e.hasCert) { Add-Result WARN "$Label SSB" "Endpoint '$($e.name)' has no certificate auth" 'BGB replica SSB requires certificate transport auth (ConfigMgrEndpointCert).' }
        }
        return (@($ep)[0].port)
    }
    catch {
        Add-Result WARN "$Label SSB" 'Endpoint query failed' $_.Exception.Message
        return $null
    }
}

# ---------------------------------------------------------------------------
# 3. Discover MPs and their configured replicas from the SITE DB.
#    v_BgbMP is the SINGLE SOURCE OF TRUTH (verified from ConfigMgr-Main
#    Core/Views/v_BgbMP.sql): BGB opens a conversation to service
#    'ConfigMgrBGB_Site' + v_BgbMP.DBID, where
#      DBID = CASE WHEN SQLServerName='' OR DatabaseName='' THEN SiteCode
#             ELSE fn_varbintohexstr(HASHBYTES('MD5',
#                  UPPER(DatabaseName + '.' + CAST(SQLServerName AS NCHAR(256))))) END
#    DBID is already the exact lowercase '0x..' string (replica) or 3-char site
#    code -- read it straight from v_BgbMP; never recompute/cast. The MP-role
#    SQLServerName/DatabaseName (SC_SysResUse RoleTypeID=6 + Value2) give the
#    replica instance + DB to connect to.
# ---------------------------------------------------------------------------
function Get-ReplicaTargets {
    $targets = New-Object System.Collections.Generic.List[object]
    try {
        $bgbMp = Invoke-Sql -Instance $SiteServerSqlInstance -Database $SiteDbName -Query "SELECT ServerName, DBID FROM v_BgbMP"
        $mpProps = Invoke-Sql -Instance $SiteServerSqlInstance -Database $SiteDbName -Query @"
SELECT ServerName = dbo.fnGetSiteSystemName(sys_res.NALPath),
       SQLServerName = MAX(CASE WHEN prop.Name = N'SQLServerName' THEN prop.Value2 END),
       DatabaseName  = MAX(CASE WHEN prop.Name = N'DatabaseName'  THEN prop.Value2 END)
FROM SC_SysResUse sys_res
JOIN SC_SysResUse_Property prop ON prop.SysResUseID = sys_res.ID
WHERE sys_res.RoleTypeID = 6
GROUP BY dbo.fnGetSiteSystemName(sys_res.NALPath)
"@
        foreach ($b in @($bgbMp)) {
            $dbid = [string]$b.DBID
            $isReplica = $dbid -and $dbid.ToLower().StartsWith('0x')
            $mp = @($mpProps) | Where-Object { $_.ServerName -eq $b.ServerName } | Select-Object -First 1
            $sqlName = if ($mp) { [string]$mp.SQLServerName } else { '' }
            $dbName = if ($mp) { [string]$mp.DatabaseName } else { '' }

            if ($isReplica) {
                Add-Result INFO 'Discovery' "MP '$($b.ServerName)' = REPLICA" "SQLServerName='$sqlName' DatabaseName='$dbName' DBID=$dbid (BGB targets ConfigMgrBGB_Site$dbid)"
                if (-not [string]::IsNullOrWhiteSpace($sqlName) -and -not [string]::IsNullOrWhiteSpace($dbName)) {
                    $targets.Add([pscustomobject]@{
                            MPServerName = [string]$b.ServerName
                            Instance     = $sqlName
                            Database     = $dbName
                            DBID         = $dbid.ToLower()
                        })
                }
                else {
                    Add-Result WARN 'Discovery' "MP '$($b.ServerName)' replica props incomplete" 'v_BgbMP shows a replica hash but the MP role SQLServerName/DatabaseName are empty; cannot connect to the replica.'
                }
            }
            else {
                Add-Result INFO 'Discovery' "MP '$($b.ServerName)' = SITE DB" "DBID=$dbid (site code -> local route ConfigMgrBGBRoute_Local)"
            }
        }
    }
    catch { Add-Result WARN 'Discovery' 'v_BgbMP / MP-role query failed' $_.Exception.Message }
    return $targets
}

# ---------------------------------------------------------------------------
# 4. SERVICE BROKER OBJECTS (verified against ConfigMgr-Main source:
#    sp_BgbConfigSSBForReplicaDB.sql, sp_BgbConfigSSBForRemoteService.sql).
#    - master DB : endpoint 'ConfigMgrEndpoint' (TCP 4022, certificate auth),
#                  transport cert 'ConfigMgrEndpointCert', imported remote-site
#                  certs 'ConfigMgrEndPointCert<hash>', login 'ConfigMgrEndpointLogin<hash>'.
#    - CM DB     : message types BGB_ChannelStart / BGB_ResourceTaskPush,
#                  contract 'HighPriority', queue 'ConfigMgrBGBQueue',
#                  service 'ConfigMgrBGB_Site<hash|sitecode>',
#                  routes 'ConfigMgrBGBRoute_Local' + 'ConfigMgrBGBRoute_Site<hash>'.
#    NOTE: BGB uses TRANSPORT security (endpoint cert). There are NO
#          remote_service_bindings -- do not check for them.
# ---------------------------------------------------------------------------
function Test-SsbObjects {
    param([string] $Instance, [string] $DbName, [string] $Label)

    # 4a. SSB transport certificates live in MASTER (not the CM DB).
    try {
        $certs = Invoke-Sql -Instance $Instance -Database 'master' -Query @"
SELECT name, start_date, expiry_date, thumbprint = CONVERT(varchar(70), thumbprint, 1)
FROM sys.certificates
WHERE name LIKE 'ConfigMgrEndpoint%' OR name LIKE 'ConfigMgrEndPoint%'
"@
        if ($certs) {
            foreach ($c in @($certs)) {
                $exp = [datetime]$c.expiry_date
                $st = if ($exp -gt (Get-Date)) { 'PASS' } else { 'FAIL' }
                Add-Result $st "$Label SSB" "master cert '$($c.name)'" "expires $($exp.ToString('yyyy-MM-dd'))"
            }
        }
        else {
            Add-Result FAIL "$Label SSB" 'No SSB transport certificate in master' "Expected 'ConfigMgrEndpointCert' (+ imported 'ConfigMgrEndPointCert<hash>'). sp_BgbConfigSSBForReplicaDB / sp_BgbConfigSSBForRemoteService create these in master; absence means SSB config never ran on this instance."
        }
    }
    catch { Add-Result WARN "$Label SSB" 'master certificate query failed' "$($_.Exception.Message) (needs VIEW DEFINITION in master / sysadmin)" }

    # 4a2. Endpoint login(s) in master (ConfigMgrEndpointLogin<hash>) -- proof sp_BgbConfigSSBForRemoteService ran.
    try {
        $logins = Invoke-Sql -Instance $Instance -Database 'master' -Query "SELECT name FROM sys.server_principals WHERE name LIKE 'ConfigMgrEndpointLogin%'"
        if ($logins) { Add-Result PASS "$Label SSB" "Endpoint login(s) present ($((@($logins)).Count))" (@($logins).name -join ', ') }
        else { Add-Result WARN "$Label SSB" 'No ConfigMgrEndpointLogin in master' 'sp_BgbConfigSSBForRemoteService creates ConfigMgrEndpointLogin<hash> + grants CONNECT on the endpoint; none found -> remote SSB config not applied on this instance.' }
    }
    catch { Add-Result WARN "$Label SSB" 'Endpoint login query failed' $_.Exception.Message }

    # 4b. Message types + contract (CM DB) -- created by sp_BgbConfigSSBForReplicaDB.
    try {
        $mt = Invoke-Sql -Instance $Instance -Database $DbName -Query "SELECT name FROM sys.service_message_types WHERE name IN ('BGB_ChannelStart','BGB_ResourceTaskPush')"
        $mtCount = @($mt).Count
        if ($mtCount -ge 2) { Add-Result PASS "$Label SSB" 'BGB message types present' (@($mt).name -join ', ') }
        else { Add-Result WARN "$Label SSB" "BGB message types incomplete ($mtCount/2)" 'Expected BGB_ChannelStart + BGB_ResourceTaskPush.' }

        $ct = Invoke-Sql -Instance $Instance -Database $DbName -Query "SELECT name FROM sys.service_contracts WHERE name = 'HighPriority'"
        if ($ct) { Add-Result PASS "$Label SSB" "Contract 'HighPriority' present" '' }
        else { Add-Result WARN "$Label SSB" "Contract 'HighPriority' missing" '' }
    }
    catch { Add-Result WARN "$Label SSB" 'Message type/contract query failed' $_.Exception.Message }

    # 4c. Service(s) -- ConfigMgrBGB_Site<hash|sitecode> (CM DB).
    try {
        $svcs = Invoke-Sql -Instance $Instance -Database $DbName -Query "SELECT name FROM sys.services WHERE name LIKE 'ConfigMgrBGB[_]Site%'"
        if ($svcs) { Add-Result PASS "$Label SSB" "BGB service(s) present ($((@($svcs)).Count))" (@($svcs).name -join ', ') }
        else { Add-Result FAIL "$Label SSB" 'No ConfigMgrBGB_Site service' 'sys.services has no ConfigMgrBGB_Site* service -- SSB config never ran in this DB.' }
    }
    catch { Add-Result WARN "$Label SSB" 'Service query failed' $_.Exception.Message }

    # 4d. Queue ConfigMgrBGBQueue (CM DB).
    try {
        $q = Invoke-Sql -Instance $Instance -Database $DbName -Query "SELECT name, is_receive_enabled, is_enqueue_enabled FROM sys.service_queues WHERE name = 'ConfigMgrBGBQueue'"
        if ($q) {
            foreach ($qq in @($q)) {
                $st = if ($qq.is_receive_enabled -and $qq.is_enqueue_enabled) { 'PASS' } else { 'WARN' }
                Add-Result $st "$Label SSB" "Queue '$($qq.name)'" "receive=$($qq.is_receive_enabled) enqueue=$($qq.is_enqueue_enabled)"
            }
        }
        else { Add-Result WARN "$Label SSB" 'ConfigMgrBGBQueue missing' '' }
    }
    catch { Add-Result WARN "$Label SSB" 'Queue query failed' $_.Exception.Message }

    # 4e. Routes (THE key object for 'Route is not defined'). Local ConfigMgrBGBRoute_Local +
    #     remote route(s) ConfigMgrBGBRoute_Site<hash> -> address TCP://<sql, instance stripped>:<port>.
    try {
        $routes = Invoke-Sql -Instance $Instance -Database $DbName -Query @"
SELECT name, remote_service_name, address, broker_instance
FROM sys.routes
WHERE remote_service_name LIKE 'ConfigMgrBGB%' OR name LIKE 'ConfigMgrBGB%'
"@
        if ($routes) {
            foreach ($r in @($routes)) {
                Add-Result INFO "$Label SSB" "Route '$($r.name)'" "-> service '$($r.remote_service_name)' address '$($r.address)'"
            }
        }
        else {
            Add-Result FAIL "$Label SSB" 'No ConfigMgrBGB routes' "Direct cause of 'Route is not defined for ConfigMgrBGB_Site<hash>'."
        }
        return @($routes)
    }
    catch { Add-Result WARN "$Label SSB" 'Route query failed' $_.Exception.Message; return @() }
}

# ===========================================================================
# SITE-SIDE CHECKS (run once)
# ===========================================================================
Test-InstancePrereqs -Instance $SiteServerSqlInstance -DbName $SiteDbName -Label 'Site' -IsReplica $false
$null = Test-SsbEndpoint -Instance $SiteServerSqlInstance -Label 'Site'
$siteRoutes = Test-SsbObjects -Instance $SiteServerSqlInstance -DbName $SiteDbName -Label 'Site'

# 6. BGB_Server registration (site DB) — the rows SMS_NOTIFICATION_MANAGER needs.
try {
    $bgb = Invoke-Sql -Instance $SiteServerSqlInstance -Database $SiteDbName -Query @"
SELECT ServerID, ServerName, DBID, ConversationID, LastOnlineVersion
FROM BGB_Server
"@
    if (-not $bgb) {
        Add-Result FAIL 'BGB' 'BGB_Server is EMPTY' 'sp_BgbSetupQueue rolls back on the missing route, so no server row is ever committed — matches "Cannot find server ID".'
    }
    else {
        foreach ($b in @($bgb)) {
            if ($b.ConversationID) { Add-Result PASS 'BGB' "BGB_Server row for $($b.ServerName)" "DBID=$($b.DBID) ConversationID present" }
            else { Add-Result FAIL 'BGB' "BGB_Server row for $($b.ServerName) has NULL ConversationID" 'Conversation never opened (missing route).' }
        }
    }
}
catch { Add-Result WARN 'BGB' 'BGB_Server query failed' $_.Exception.Message }

# 8-site. Publications on the publisher (site DB).
try {
    $pubs = Invoke-Sql -Instance $SiteServerSqlInstance -Database $SiteDbName -Query "SELECT name, status, immediate_sync, allow_pull FROM syspublications"
    if ($pubs) { Add-Result PASS 'Replication' "Publication(s) on site DB ($((@($pubs)).Count))" (@($pubs).name -join ', ') }
    else { Add-Result FAIL 'Replication' 'No publications on site DB' 'ConfigMgr_MPReplica publication missing (doc Step 1.5 spCreateMPReplicaPublication).' }
}
catch { Add-Result WARN 'Replication' 'syspublications query failed' "$($_.Exception.Message) (run against the published DB with replication permissions)" }

# ===========================================================================
# DISCOVER + VALIDATE EVERY REPLICA
# ===========================================================================
$replicaTargets = Get-ReplicaTargets

if (@($replicaTargets).Count -eq 0) {
    Add-Result INFO 'Discovery' 'No MP database replicas configured' 'No MP is configured to use a database replica (all MPs use the site database). Replica-specific checks skipped.'
}

foreach ($rt in @($replicaTargets)) {
    Write-Host ("`n----- Replica: MP '{0}' -> {1} / {2} (DBID {3}) -----" -f $rt.MPServerName, $rt.Instance, $rt.Database, $rt.DBID) -ForegroundColor Cyan
    $label = "Replica[$($rt.MPServerName)]"

    # Reset per-replica scenario state.
    $script:ReplicaIsSubscribed = $null
    $script:ReplicaBrokerGuid = $null

    if (-not (Test-SqlConnect -Instance $rt.Instance -Label "$label SQL")) {
        Add-Result FAIL 'Connectivity' "Replica '$($rt.Instance)' unreachable" "MP '$($rt.MPServerName)' points at this replica but it cannot be reached — validation for this replica is skipped."
        continue
    }

    Test-InstancePrereqs -Instance $rt.Instance -DbName $rt.Database -Label $label -IsReplica $true
    $replPort = Test-SsbEndpoint -Instance $rt.Instance -Label $label
    $replRoutes = Test-SsbObjects -Instance $rt.Instance -DbName $rt.Database -Label $label

    # 5. DIRECTIONAL ROUTE VALIDATION.
    #    Site DB must route to this replica's ConfigMgrBGB_Site<DBID> at TCP://<replica host>:<port>.
    #    Replica DB must route back to the site's ConfigMgrBGB_Site<siteCode>.
    try {
        $wantSvc = "ConfigMgrBGB_Site$($rt.DBID)"
        $match = @($siteRoutes) | Where-Object { $_.remote_service_name -and ($_.remote_service_name.ToLower() -eq $wantSvc.ToLower()) }
        $replHostShort = ($rt.Instance.Split('\')[0]).Split(',')[0]
        if ($match) {
            $addrOk = $false
            foreach ($m in $match) {
                if ($m.address -match [regex]::Escape($replHostShort)) { $addrOk = $true }
            }
            if ($addrOk) { Add-Result PASS 'Route match' "Site DB -> replica route exists" "service '$wantSvc' address '$((@($match)[0]).address)'" }
            else { Add-Result WARN 'Route match' "Site DB -> replica route address suspect" "service '$wantSvc' present but address '$((@($match)[0]).address)' does not reference the replica host '$replHostShort'." }
        }
        else {
            $portShown = if ($replPort) { $replPort } else { 4022 }
            Add-Result FAIL 'Route match' "Site DB missing route to replica '$($rt.MPServerName)'" "Expected service '$wantSvc' (address TCP://${replHostShort}:${portShown}) — NOT found. Root cause of the BGB error for this MP."
        }

        $wantBack = "ConfigMgrBGB_Site$SiteCode"
        $matchBack = @($replRoutes) | Where-Object { $_.remote_service_name -and ($_.remote_service_name.ToLower() -eq $wantBack.ToLower()) }
        if ($matchBack) { Add-Result PASS 'Route match' 'Replica DB -> site route exists' "service '$wantBack' address '$((@($matchBack)[0]).address)'" }
        else { Add-Result WARN 'Route match' 'Replica DB -> site route missing' "Expected '$wantBack' on the replica (doc Step 5.5: sp_BgbConfigSSBForRemoteService '<SiteCode>', ...)." }
    }
    catch { Add-Result WARN 'Route match' 'Directional route validation failed' $_.Exception.Message }

    # 7. db_datareader for the MP machine account on this replica DB.
    $mpShort = ($rt.MPServerName.Split('.')[0])
    $mpAccount = "$mpShort`$"
    try {
        $rows = Invoke-Sql -Instance $rt.Instance -Database $rt.Database -Query @"
SELECT dp.name AS member, r.name AS role
FROM sys.database_role_members drm
JOIN sys.database_principals dp ON dp.principal_id = drm.member_principal_id
JOIN sys.database_principals r  ON r.principal_id  = drm.role_principal_id
WHERE r.name = 'db_datareader' AND dp.name LIKE '%$mpShort$'
"@
        if ($rows) { Add-Result PASS 'Replica Perms' "MP '$mpAccount' in db_datareader" (@($rows).member -join ', ') }
        else { Add-Result FAIL 'Replica Perms' "MP '$mpAccount' NOT in db_datareader on replica" 'doc Step 3: add the MP computer account to db_datareader on the replica DB.' }
    }
    catch { Add-Result WARN 'Replica Perms' "db_datareader check failed for $mpAccount" $_.Exception.Message }

    # 8-replica. Subscription on the subscriber (replica DB).
    try {
        $subs = Invoke-Sql -Instance $rt.Instance -Database $rt.Database -Query @"
SELECT publisher, publisher_db, publication, subscription_type, [time], transaction_timestamp
FROM dbo.MSreplication_subscriptions
"@
        if ($subs) {
            foreach ($s in @($subs)) {
                $subType = switch ([int]$s.subscription_type) { 0 { 'push' } 1 { 'pull' } 2 { 'anonymous' } default { "$($s.subscription_type)" } }
                Add-Result PASS 'Replication' "Subscription $($s.publication)" "publisher=$($s.publisher) db=$($s.publisher_db) type=$subType lastSync=$($s.time)"
            }
        }
        else { Add-Result FAIL 'Replication' 'No subscriptions on replica DB' 'The replica has no transactional-replication subscription (doc Step 2 wizard not completed / DB only restored).' }
    }
    catch { Add-Result WARN 'Replication' 'Subscription query failed' "$($_.Exception.Message) (MSreplication_subscriptions exists only in a real subscriber DB)" }

    # 8b. SCENARIO DETECTION -- unsupported "restored copy used as a replica".
    #     Signatures: MP is configured as a replica (DBID is a hash) AND the replica DB is
    #     NOT a subscriber, and/or the site DB is not published, and/or the replica shares the
    #     site DB's service_broker_guid (a RESTORE keeps the source GUID; a wizard-created
    #     subscription DB gets its own -- verified against ConfigMgr-Main SetupDbUtils.cpp,
    #     which only regenerates the broker GUID (SET NEW_BROKER) when broker is not already
    #     enabled, so a restored, already-broker-enabled DB keeps the source GUID).
    $smells = New-Object System.Collections.Generic.List[string]
    if ($script:ReplicaIsSubscribed -eq $false) {
        $smells.Add('the replica DB is NOT a transactional-replication subscriber (sys.databases.is_subscribed = 0)')
    }
    if ($script:SiteIsPublished -eq $false) {
        $smells.Add('the site DB is NOT published (no ConfigMgr_MPReplica publication from spCreateMPReplicaPublication)')
    }
    if ($script:SiteBrokerGuid -and $script:ReplicaBrokerGuid -and
        ($script:SiteBrokerGuid -eq $script:ReplicaBrokerGuid)) {
        $smells.Add("the replica shares the site DB's service_broker_guid ($($script:ReplicaBrokerGuid)) -- a RESTORE keeps the source database's broker GUID, whereas a wizard-created subscription DB gets its own")
    }

    if ($smells.Count -gt 0) {
        $detail = "MP '$($rt.MPServerName)' is configured to use a database replica, but this is a RESTORED COPY of the site database, not a configured MP database replica. Evidence: " +
            (($smells | ForEach-Object { "($_)" }) -join '; ') + '. ' +
            'This configuration is NOT SUPPORTED and is why BGB throws "Route is not defined for ConfigMgrBGB_Site<hash>" -- the Service Broker plumbing between the two databases was never built. ' +
            'A supported MP database replica requires SQL Server transactional replication (Step 1: site DB publishes via spCreateMPReplicaPublication; Step 2: replica subscribes via the New Subscription Wizard) PLUS the SSB steps (Step 4/5). ' +
            'Fix options: (A) revert the MP to "Use the site database" (Management Point role > Properties > Management Point Database) -- BGB then self-heals on the next SMS_NOTIFICATION_MANAGER cycle; or (B) tear down the restored DB and configure a real replica end-to-end per the doc. ' +
            'Docs: https://learn.microsoft.com/en-us/mem/configmgr/core/servers/deploy/configure/database-replicas-for-management-points'
        Add-Result FAIL 'Scenario' "UNSUPPORTED: restored site DB used as MP '$($rt.MPServerName)' replica" $detail
    }
    else {
        Add-Result PASS 'Scenario' "Replica for MP '$($rt.MPServerName)' looks like a real subscriber" 'The replica DB is subscribed / site DB is published with distinct broker GUIDs -- consistent with a properly configured database replica (verify the SSB routes above are also present).'
    }

    # 9b. OS-level checks for this replica server (SQL identity cert + local admins).
    if ($RunOSChecks) {
        $replicaServer = $replHostShort
        try {
            $cert = Invoke-Command -ComputerName $replicaServer -ScriptBlock {
                $fn = 'ConfigMgr SQL Server Identification Certificate'
                Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object { $_.FriendlyName -eq $fn } |
                    Select-Object Thumbprint, NotBefore, NotAfter, Subject
            } -ErrorAction Stop
            if ($cert) {
                $valid = @($cert | Where-Object { $_.NotBefore -lt (Get-Date) -and $_.NotAfter -gt (Get-Date) })
                if ($valid) { Add-Result PASS 'Replica OS' "SQL identity cert present & valid ($replicaServer)" "thumb=$($valid[0].Thumbprint) exp=$($valid[0].NotAfter.ToString('yyyy-MM-dd'))" }
                else { Add-Result FAIL 'Replica OS' "SQL identity cert EXPIRED/NOT-YET-VALID ($replicaServer)" "$($cert[0].NotBefore) - $($cert[0].NotAfter)" }
            }
            else { Add-Result FAIL 'Replica OS' "SQL identity cert missing on $replicaServer (LocalMachine\My)" "doc Step 4: CreateMPReplicaCert.ps1 creates 'ConfigMgr SQL Server Identification Certificate'." }
        }
        catch { Add-Result WARN 'Replica OS' "Certificate check failed ($replicaServer)" $_.Exception.Message }

        try {
            $admins = Invoke-Command -ComputerName $replicaServer -ScriptBlock {
                (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue).Name
            } -ErrorAction Stop
            $hit = @($admins) | Where-Object { $_ -match "\\$mpShort\$?$" -or $_ -match "$mpShort\$$" }
            if ($hit) { Add-Result PASS 'Replica OS' "MP '$mpAccount' in local Administrators ($replicaServer)" ($hit -join ', ') }
            else { Add-Result WARN 'Replica OS' "MP '$mpAccount' NOT in local Administrators on $replicaServer" 'doc Step 2.6: add each MP computer account to local Administrators on the replica (skip if MP runs on the replica server).' }
        }
        catch { Add-Result WARN 'Replica OS' "Local Administrators check failed ($replicaServer)" $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# 8-distribution. Distribution / latency (best effort; needs the distribution DB).
# ---------------------------------------------------------------------------
if (@($replicaTargets).Count -gt 0) {
    try {
        $mon = Invoke-Sql -Instance $SiteServerSqlInstance -Database 'distribution' -Query @"
SELECT TOP 50 da.publisher_db, da.publication, da.subscriber_name, da.subscriber_db,
       da.subscription_type, da.status AS statuscode,
       latency = dh.current_delivery_latency, lastSync = dh.[time]
FROM dbo.MSdistribution_agents da
OUTER APPLY (
    SELECT TOP 1 current_delivery_latency, [time]
    FROM dbo.MSdistribution_history h
    WHERE h.agent_id = da.id
    ORDER BY [time] DESC
) dh
WHERE da.subscriber_name IS NOT NULL
"@
        if ($mon) {
            foreach ($m in @($mon)) {
                $sc = [int]$m.statuscode
                $statusText = switch ($sc) { 1 { 'Started' } 2 { 'Succeeded' } 3 { 'InProgress' } 4 { 'Idle' } 5 { 'Retrying' } 6 { 'Failed' } default { "$sc" } }
                $st = if ($sc -in 1, 2, 3, 4) { 'PASS' } elseif ($sc -in 5, 6) { 'WARN' } else { 'INFO' }
                Add-Result $st 'Replication' "Distribution $($m.publication) -> $($m.subscriber_name)" "status=$statusText latency=$($m.latency)ms lastSync=$($m.lastSync) db=$($m.publisher_db)->$($m.subscriber_db)"
            }
        }
        else { Add-Result INFO 'Replication' 'No distribution agents found' 'No MSdistribution_agents rows (distributor may be elsewhere, or no subscriptions).' }
    }
    catch { Add-Result INFO 'Replication' 'Distributor check skipped' "distribution DB not accessible from here: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# 9a. OPTIONAL OS-LEVEL CHECKS on the SITE SERVER (this box): local group
#     ConfigMgr_MPReplicaAccess + share ConfigMgr_MPReplica.
# ---------------------------------------------------------------------------
if ($RunOSChecks -and @($replicaTargets).Count -gt 0) {
    try {
        $g = Get-LocalGroup -Name 'ConfigMgr_MPReplicaAccess' -ErrorAction SilentlyContinue
        if ($g) {
            $members = (Get-LocalGroupMember -Group 'ConfigMgr_MPReplicaAccess' -ErrorAction SilentlyContinue).Name
            Add-Result PASS 'Site OS' 'Group ConfigMgr_MPReplicaAccess exists' "members: $((@($members)) -join ', ')"
        }
        else { Add-Result WARN 'Site OS' 'Group ConfigMgr_MPReplicaAccess not found (or domain group used)' 'doc Step 1.2 (local or domain group). If domain, ignore.' }
    }
    catch { Add-Result WARN 'Site OS' 'Local group check failed' $_.Exception.Message }

    try {
        $share = Get-SmbShare -Name 'ConfigMgr_MPReplica' -ErrorAction SilentlyContinue | Select-Object Name, Path
        if ($share) { Add-Result PASS 'Site OS' 'Share ConfigMgr_MPReplica exists' "path=$($share.Path)" }
        else { Add-Result FAIL 'Site OS' 'Share ConfigMgr_MPReplica missing' 'doc Step 1.3/1.4: file share used for replica snapshot sync.' }
    }
    catch { Add-Result WARN 'Site OS' 'Share check failed' $_.Exception.Message }
}
elseif (-not $RunOSChecks) {
    Add-Result INFO 'OS Checks' 'OS-level checks skipped' 'Pass -RunOSChecks to verify the site group/share and each replica''s SQL identity cert + local admins over WinRM.'
}

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
Write-Host "`n===== SUMMARY =====" -ForegroundColor Cyan
$fail = @($script:Results | Where-Object Status -eq 'FAIL')
$warn = @($script:Results | Where-Object Status -eq 'WARN')
$pass = @($script:Results | Where-Object Status -eq 'PASS')
Write-Host ("PASS={0}  WARN={1}  FAIL={2}" -f $pass.Count, $warn.Count, $fail.Count) -ForegroundColor White

if ($fail.Count -gt 0) {
    Write-Host "`nFAILURES (fix these first):" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host ("  - [{0}] {1}: {2}" -f $_.Area, $_.Check, $_.Detail) -ForegroundColor Red }
}
if ($warn.Count -gt 0) {
    Write-Host "`nWARNINGS:" -ForegroundColor Yellow
    $warn | ForEach-Object { Write-Host ("  - [{0}] {1}: {2}" -f $_.Area, $_.Check, $_.Detail) -ForegroundColor Yellow }
}
