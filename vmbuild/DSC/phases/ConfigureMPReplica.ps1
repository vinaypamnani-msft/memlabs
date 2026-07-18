#ConfigureMPReplica.ps1
# Configures a supported ConfigMgr Management Point database replica (SQL Server
# transactional replication + Service Broker), so BGB / client-notification runs
# against the replica DB instead of the site DB. Runs ON THE SITE SERVER, after
# InstallRoles.ps1, for every SiteSystem MP in this site that has
# useDatabaseReplica=true. Mirrors the documented Steps 1-6:
#   https://learn.microsoft.com/en-us/mem/configmgr/core/servers/deploy/configure/database-replicas-for-management-points
# Every object name it builds is the spec verified by
# vmbuild\Fixes\Test-MPDatabaseReplicaHealth.ps1. The ConfigMgr stored procedures
# it calls (spCreateMPReplicaPublication, sp_BgbConfigSSBForReplicaDB,
# sp_BgbConfigSSBForRemoteService, sp_BgbCreateAndBackupSQLCert) ship in the CM DB.
# All steps are idempotent (check-then-act) so this re-runs cleanly each pass.
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

$Tag = "[MPReplica]"

if (-not $ConfigFilePath) {
    $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
}

$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

$DomainFullName = $deployConfig.vmOptions.domainName

# Service Broker port (memlabs hardcodes 4022 during site setup).
$SSBPort = "4022"

# ---------------------------------------------------------------------------
# ScriptWorkflow status helper (mirrors InstallRoles.ps1 InstallSUP flip). The
# step self-skips when nothing to do, so registration is unconditional; guard on
# the property existing for older ScriptWorkflow.json files.
# ---------------------------------------------------------------------------
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
function Set-MPReplicaStatus {
    param([string]$Status)
    try {
        $cfg = Get-Content -Path $ConfigurationFile -ErrorAction Stop | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -notcontains 'ConfigureMPReplica') { return }
        $cfg.ConfigureMPReplica.Status = $Status
        if ($Status -eq 'Running') { $cfg.ConfigureMPReplica.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss" }
        else { $cfg.ConfigureMPReplica.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss" }
        $cfg | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }
    catch {
        Write-DscStatus "$Tag WARNING: could not update ConfigureMPReplica status to '$Status': $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Read the site DB SQL instance / database / site code from THIS server's
# registry (same detection ConfigMgr uses; see Test-MPDatabaseReplicaHealth
# Get-LocalSiteInfo). Named instance: 'Database Name' is 'INSTANCE\DB'.
# ---------------------------------------------------------------------------
try {
    $SiteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
    $sqlReg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -ErrorAction Stop
    $siteSqlServer = $sqlReg.Server
    $siteDbRaw = $sqlReg.'Database Name'
}
catch {
    Write-DscStatus "$Tag Could not read site SQL info from registry (not a site server?). Skipping. $($_.Exception.Message)"
    return
}
if ($siteDbRaw -match '\\') {
    $siteSqlConn = "$siteSqlServer\$($siteDbRaw.Split('\')[0])"
    $siteDbName = $siteDbRaw.Split('\')[1]
}
else {
    $siteSqlConn = $siteSqlServer
    $siteDbName = $siteDbRaw
}

# ---------------------------------------------------------------------------
# Discover the replica MPs for THIS site from deployConfig (local-recovery safe;
# do not depend on $AllNodes). Only SiteSystem MPs with useDatabaseReplica whose
# siteCode is this site. CAS never runs this step (not dot-sourced there).
# ---------------------------------------------------------------------------
$replicaMPs = @($deployConfig.virtualMachines | Where-Object {
        $_.role -eq 'SiteSystem' -and $_.installMP -and $_.useDatabaseReplica -and $_.siteCode -eq $SiteCode
    })

if ($replicaMPs.Count -eq 0) {
    Write-DscStatus "$Tag No MP database replicas configured for site $SiteCode. Nothing to do."
    Set-MPReplicaStatus -Status 'Completed'
    return
}

Set-MPReplicaStatus -Status 'Running'
Write-DscStatus "$Tag Configuring $($replicaMPs.Count) MP database replica(s) for site $SiteCode (site DB $siteSqlConn\$siteDbName)."

# ---------------------------------------------------------------------------
# Build per-MP targets. Per-server ordinal (group by replica SQL VM, ordered by
# MP vmName) drives the SSB cert friendly-name suffix (0 = default name).
# ---------------------------------------------------------------------------
function Get-SqlConnString {
    param([string]$Server, [string]$Instance, [object]$Port)
    $c = $Server
    if ($Instance -and $Instance -ne 'MSSQLSERVER') { $c = "$Server\$Instance" }
    if ($Port -and "$Port" -ne '1433') { $c = "$c,$Port" }
    return $c
}

$targets = New-Object System.Collections.Generic.List[object]
foreach ($mp in ($replicaMPs | Sort-Object vmName)) {
    $replicaVMName = $mp.replicaSqlServerVM
    $replicaVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $replicaVMName } | Select-Object -First 1
    $replicaInstance = if ($replicaVM -and $replicaVM.sqlInstanceName) { $replicaVM.sqlInstanceName } else { 'MSSQLSERVER' }
    $replicaPort = if ($replicaVM -and $replicaVM.sqlPort) { $replicaVM.sqlPort } else { 1433 }
    $replicaFqdn = "$replicaVMName.$DomainFullName"
    $replicaDbName = if ($mp.replicaDbName) { $mp.replicaDbName } else { "CM_$SiteCode" }
    $mpShort = $mp.vmName
    $mpFqdn = "$($mp.vmName).$DomainFullName"

    $targets.Add([pscustomobject]@{
            MPName          = $mp.vmName
            MPShort         = $mpShort
            MPFqdn          = $mpFqdn
            MPAccount       = "$env:USERDOMAIN\$mpShort`$"
            ReplicaVMName   = $replicaVMName
            ReplicaShort    = $replicaVMName
            ReplicaFqdn     = $replicaFqdn
            ReplicaInstance = $replicaInstance
            ReplicaPort     = $replicaPort
            ReplicaConn     = (Get-SqlConnString -Server $replicaFqdn -Instance $replicaInstance -Port $replicaPort)
            # Server[\instance] WITHOUT the port -- replication @subscriber/@publisher
            # names must not embed a port (the agent resolves a named instance's port
            # via SQL Browser). ReplicaConn (with port) is only for direct connections.
            ReplicaSqlName  = (Get-SqlConnString -Server $replicaFqdn -Instance $replicaInstance -Port 1433)
            ReplicaDbName   = $replicaDbName
            IsLocalToMP     = ($replicaVMName -eq $mp.vmName)
            NotReady        = $false
            CertOrdinal     = 0
        })
}

# Assign per-server cert ordinals (0 = first on that SQL server = default cert name).
foreach ($grp in ($targets | Group-Object ReplicaVMName)) {
    $i = 0
    foreach ($t in ($grp.Group | Sort-Object MPName)) {
        $t.CertOrdinal = $i
        $i++
    }
}

# ---------------------------------------------------------------------------
# Small SQL wrapper (integrated auth; the DSC run account is sysadmin on the lab
# SQL servers). Uses System.Data.SqlClient directly rather than Invoke-Sqlcmd:
# the SqlServer/SQLPS module is NOT present on a site server that uses remote SQL
# (no SQL tooling installed locally), whereas System.Data.SqlClient always is.
# Returns DataRow objects for result-set queries (so callers can read columns by
# name, e.g. $r.c), or nothing for non-query batches. TrustServerCertificate for
# replicas serving Encrypt=True.
# ---------------------------------------------------------------------------
function Invoke-ReplSql {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master'
    )
    $connStr = "Server=$Instance;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=30;Application Name=MemLabs-MPReplica"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
    try {
        # Retry the connection OPEN a few times -- it is idempotent (nothing has run
        # yet) and this rides out transient blips: a replica SQL still coming up, or
        # the SQL service restart that STEP 4 performs after applying the identity cert.
        $openTry = 0
        while ($true) {
            try { $conn.Open(); break }
            catch {
                $openTry++
                if ($openTry -ge 3) { throw }
                Start-Sleep -Seconds 4
            }
        }
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 300
        $reader = $cmd.ExecuteReader()
        try {
            # Read ONLY the first result set into a disconnected DataTable, then
            # drain any remaining result sets. (Replication/BGB procs emit several
            # result sets; DataTable.Load would try to merge them and can throw on
            # schema mismatch.)
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
            # Return disconnected DataRow objects (fully materialized in memory).
            return , $table.Rows
        }
    }
    finally {
        $conn.Dispose()
    }
}

# Collect an actionable diagnostic snapshot on failure (state that explains WHY the
# replica isn't working) so it's captured in the DSC log without a manual health run.
function Write-MPReplicaDiagnostics {
    param([string]$SiteInstance, [string]$SiteDb, [object]$Targets)
    Write-DscStatus "$Tag ===== MP replica failure diagnostics ====="
    try {
        $q = "SELECT broker = (SELECT is_broker_enabled FROM sys.databases WHERE name = DB_NAME()), pubs = (CASE WHEN OBJECT_ID('dbo.syspublications') IS NOT NULL THEN (SELECT COUNT(*) FROM dbo.syspublications WHERE name='ConfigMgr_MPReplica') ELSE 0 END), subs = (CASE WHEN OBJECT_ID('dbo.syssubscriptions') IS NOT NULL THEN (SELECT COUNT(DISTINCT srvid) FROM dbo.syssubscriptions) ELSE 0 END)"
        $r = Invoke-ReplSql -Instance $SiteInstance -Database $SiteDb -Query $q
        Write-DscStatus "$Tag [Diag][Site $SiteDb] broker_enabled=$($r.broker) publication=$($r.pubs) subscribers=$($r.subs)"
    }
    catch { Write-DscStatus "$Tag [Diag][Site] state query failed: $($_.Exception.Message)" }
    try {
        $tq = Invoke-ReplSql -Instance $SiteInstance -Database $SiteDb -Query "SELECT TOP 3 st = ISNULL(transmission_status,'') FROM sys.transmission_queue WHERE transmission_status <> '' ORDER BY enqueue_time DESC"
        foreach ($row in @($tq)) { if ($row.st) { Write-DscStatus "$Tag [Diag][Site SSB] stuck transmission: $($row.st)" } }
    }
    catch { }
    # Replication agent history from the distribution DB explains WHY the snapshot
    # did not apply (runstatus 2=Succeed, 5=Retry, 6=Fail; comments has the error).
    try {
        $sh = Invoke-ReplSql -Instance $SiteInstance -Database 'CMDistribution' -Query "SELECT TOP 3 rs = runstatus, cm = LEFT(ISNULL(comments,''),300) FROM dbo.MSsnapshot_history ORDER BY [time] DESC"
        foreach ($row in @($sh)) { Write-DscStatus "$Tag [Diag][SnapshotAgent] runstatus=$($row.rs): $($row.cm)" }
        $dh = Invoke-ReplSql -Instance $SiteInstance -Database 'CMDistribution' -Query "SELECT TOP 5 rs = runstatus, cm = LEFT(ISNULL(comments,''),300) FROM dbo.MSdistribution_history ORDER BY [time] DESC"
        foreach ($row in @($dh)) { Write-DscStatus "$Tag [Diag][DistAgent] runstatus=$($row.rs): $($row.cm)" }
    }
    catch { Write-DscStatus "$Tag [Diag] agent-history query failed: $($_.Exception.Message)" }
    foreach ($t in @($Targets)) {
        try {
            $rb = Invoke-ReplSql -Instance $t.ReplicaConn -Query "SELECT b = ISNULL((SELECT CONVERT(int, is_broker_enabled) FROM sys.databases WHERE name = N'$($t.ReplicaDbName)'), -1)"
            $sub = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query "IF OBJECT_ID('dbo.MSreplication_subscriptions') IS NOT NULL SELECT c = COUNT(*) FROM dbo.MSreplication_subscriptions WHERE publication = 'ConfigMgr_MPReplica' ELSE SELECT c = 0"
            $xc = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query "IF OBJECT_ID('dbo.XMLConfigStore') IS NOT NULL SELECT c = COUNT(*) FROM dbo.XMLConfigStore WHERE Name = 'MPReplicaServiceBrokerConfiguration' ELSE SELECT c = 0"
            Write-DscStatus "$Tag [Diag][Replica $($t.MPName)/$($t.ReplicaDbName)] broker_enabled=$($rb.b) pull_subscriptions=$($sub.c) replicated_XMLConfigStore=$($xc.c) (0 XMLConfigStore = initial snapshot not applied)"
        }
        catch { Write-DscStatus "$Tag [Diag][Replica $($t.MPName)] state query failed: $($_.Exception.Message)" }
        # Subscriber-side SQL Agent job history for the pull Distribution Agent. This is
        # the ONLY place the real failure shows up: a pull agent that cannot connect to
        # the distributor (login/PAL/snapshot-share) fails on the subscriber and never
        # writes to the distributor's MSdistribution_history (which then stays at the
        # initial "subscription added" row). run_status 0=Fail 1=Succeed 2=Retry 3=Cancel.
        try {
            $jh = Invoke-ReplSql -Instance $t.ReplicaConn -Query @"
SELECT TOP 4 st = h.run_status, msg = LEFT(ISNULL(h.[message],''),350)
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobsteps s ON s.job_id = h.job_id AND s.step_id = h.step_id
WHERE s.subsystem = 'Distribution' AND s.command LIKE '%ConfigMgr_MPReplica%' AND h.step_id > 0
ORDER BY h.run_date DESC, h.run_time DESC
"@
            $any = $false
            foreach ($row in @($jh)) { $any = $true; Write-DscStatus "$Tag [Diag][Replica $($t.MPName)][DistAgentJob] run_status=$($row.st): $($row.msg)" }
            if (-not $any) { Write-DscStatus "$Tag [Diag][Replica $($t.MPName)][DistAgentJob] no job-history rows (Distribution Agent has not run yet)." }
        }
        catch { Write-DscStatus "$Tag [Diag][Replica $($t.MPName)] job-history query failed: $($_.Exception.Message)" }
    }
    Write-DscStatus "$Tag ===== end diagnostics (run Test-MPDatabaseReplicaHealth.ps1 for the full report) ====="
}

$hardFailed = $false

# ===========================================================================
# STEP 1 - Prerequisites on the site + each replica SQL instance.
# ===========================================================================
# A replica SQL host may still be booting when this step runs (its VM was just
# started/restored), so wait for BOTH its SQL Engine (a bare connection) and WinRM
# (Set-InstancePrereqs / STEP 3-4 use Invoke-Command) before configuring it.
function Wait-ReplicaReady {
    param([string]$Instance, [string]$Computer, [string]$Label, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $sqlOk = $false
    $winrmOk = $false
    $announced = $false
    while ($true) {
        if (-not $sqlOk) {
            $c = $null
            try {
                $c = New-Object System.Data.SqlClient.SqlConnection "Server=$Instance;Database=master;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=5"
                $c.Open()
                $sqlOk = $true
            }
            catch { }
            finally { if ($c) { $c.Dispose() } }
        }
        if (-not $winrmOk) {
            try { [void](Test-WSMan -ComputerName $Computer -ErrorAction Stop); $winrmOk = $true }
            catch { }
        }
        if ($sqlOk -and $winrmOk) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        if (-not $announced) { Write-DscStatus "$Tag [$Label] waiting up to $([int]($TimeoutSec/60)) min for replica to become ready (SQL=$sqlOk WinRM=$winrmOk)..."; $announced = $true }
        Start-Sleep -Seconds 15
    }
}

function Set-InstancePrereqs {
    param([string]$Instance, [bool]$IsReplica, [string]$Label, [string]$SqlHost)

    # max text repl size (B) = 2 GB on BOTH instances.
    try {
        Invoke-ReplSql -Instance $Instance -Query "EXEC sp_configure 'show advanced options',1; RECONFIGURE; EXEC sp_configure 'max text repl size (B)', 2147483647; RECONFIGURE;"
        Write-DscStatus "$Tag [$Label] max text repl size set to 2GB."
    }
    catch { Write-DscStatus "$Tag WARNING [$Label] could not set 'max text repl size': $($_.Exception.Message)" }

    if ($IsReplica) {
        # clr enabled = 1 on the replica (required by the replicated CM SPs).
        try {
            Invoke-ReplSql -Instance $Instance -Query "EXEC sp_configure 'clr enabled', 1; RECONFIGURE WITH OVERRIDE;"
            Write-DscStatus "$Tag [$Label] clr enabled set on replica."
        }
        catch { Write-DscStatus "$Tag WARNING [$Label] could not enable clr: $($_.Exception.Message)" }
    }

    # SQL Server Agent Automatic + running on this SQL host. Required on BOTH the
    # site (distributor: snapshot / log reader / distribution agents) AND each
    # replica (pull subscription agent). Warn if the engine is not System.
    if ($SqlHost) {
        try {
            $svcResult = Invoke-Command -ComputerName $SqlHost -ArgumentList $Instance -ScriptBlock {
                param($inst)
                $instanceName = 'MSSQLSERVER'
                if ($inst -match '\\') { $instanceName = $inst.Split('\')[1].Split(',')[0] }
                if ($instanceName -eq 'MSSQLSERVER') { $agent = 'SQLSERVERAGENT'; $engine = 'MSSQLSERVER' }
                else { $agent = "SQLAgent`$$instanceName"; $engine = "MSSQL`$$instanceName" }
                $out = @{}
                $a = Get-Service -Name $agent -ErrorAction SilentlyContinue
                if ($a) {
                    Set-Service -Name $agent -StartupType Automatic -ErrorAction SilentlyContinue
                    if ($a.Status -ne 'Running') { Start-Service -Name $agent -ErrorAction SilentlyContinue }
                    $out.Agent = (Get-Service -Name $agent).Status
                }
                $e = Get-CimInstance Win32_Service -Filter "Name='$engine'" -ErrorAction SilentlyContinue
                if ($e) { $out.EngineAccount = $e.StartName }
                return $out
            } -ErrorAction Stop
            Write-DscStatus "$Tag [$Label] SQL Agent status=$($svcResult.Agent) engineAcct=$($svcResult.EngineAccount)."
            if ($svcResult.EngineAccount -and $svcResult.EngineAccount -notmatch '(?i)LocalSystem|NT AUTHORITY\\SYSTEM') {
                Write-DscStatus "$Tag WARNING [$Label] SQL engine runs as $($svcResult.EngineAccount), not System; share ACLs assume SYSTEM."
            }
        }
        catch { Write-DscStatus "$Tag WARNING [$Label] could not configure SQL Agent on $SqlHost`: $($_.Exception.Message)" }
    }
}

# Site DB SQL server machine (physical NetBIOS): used for STEP 1 (start SQL Agent
# on the distributor), STEP 2 (the access group + share must be on the SQL server),
# and $shareUnc.
$siteSqlMachine = ($siteSqlServer -split '\\')[0]
$siteSqlShort = ($siteSqlMachine -split '\.')[0]
$siteSqlMachineFqdn = if ($siteSqlMachine -like '*.*') { $siteSqlMachine } else { "$siteSqlMachine.$DomainFullName" }
$isSiteSqlLocal = ($siteSqlShort -ieq $env:COMPUTERNAME)

Set-InstancePrereqs -Instance $siteSqlConn -IsReplica $false -Label 'Site' -SqlHost $siteSqlMachineFqdn
foreach ($t in $targets) {
    $rl = "Replica[$($t.MPName)]"
    if (-not (Wait-ReplicaReady -Instance $t.ReplicaConn -Computer $t.ReplicaShort -Label $rl)) {
        Write-DscStatus "$Tag WARNING [$rl] replica SQL/WinRM not reachable after waiting; skipping this replica (bring $($t.ReplicaShort) online and re-run)."
        $t.NotReady = $true
        continue
    }
    Set-InstancePrereqs -Instance $t.ReplicaConn -IsReplica $true -Label $rl -SqlHost $t.ReplicaShort
}

# ===========================================================================
# STEP 2 - Publish the site DB (distributor + distribution DB + publication).
# ===========================================================================
# The local group ConfigMgr_MPReplicaAccess and the snapshot share must live on
# the SITE DB SQL SERVER (spCreateMPReplicaPublication builds the login name and
# @SnapshotSharePath from SERVERPROPERTY('ComputerNamePhysicalNetBIOS'), i.e. the
# machine running the SP). With a REMOTE site DB SQL that is NOT the site server,
# so create them there (the site server's machine account is a local admin on its
# SQL server, so Invoke-Command works). The share also backs SSB cert exchange, so
# the site SQL machine account itself needs access for its own UNC cert backup.
# ($siteSqlMachine / $siteSqlShort / $siteSqlMachineFqdn / $isSiteSqlLocal computed
# above, before STEP 1.)
$shareAccts = @(@($targets | ForEach-Object { "$($_.ReplicaShort)`$" }) + "$siteSqlShort`$" | Sort-Object -Unique)

$shareSetupSb = {
    param($accts, $domainNb)
    $out = @()
    try {
        if (-not (Get-LocalGroup -Name 'ConfigMgr_MPReplicaAccess' -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name 'ConfigMgr_MPReplicaAccess' -Description 'ConfigMgr MP replica snapshot/cert access' | Out-Null
            $out += 'created local group ConfigMgr_MPReplicaAccess'
        }
        foreach ($acct in $accts) {
            $member = "$domainNb\$acct"
            if (-not (Get-LocalGroupMember -Group 'ConfigMgr_MPReplicaAccess' -Member $member -ErrorAction SilentlyContinue)) {
                try { Add-LocalGroupMember -Group 'ConfigMgr_MPReplicaAccess' -Member $member -ErrorAction Stop; $out += "added $member" }
                catch { $out += "WARN could not add ${member}: $($_.Exception.Message)" }
            }
        }
    }
    catch { $out += "WARN group: $($_.Exception.Message)" }
    $shareRoot = if (Test-Path 'E:\') { 'E:\ConfigMgr_MPReplica' } else { "$env:SystemDrive\ConfigMgr_MPReplica" }
    try {
        if (-not (Test-Path $shareRoot)) { New-Item -Path $shareRoot -ItemType Directory -Force | Out-Null }
        if (-not (Get-SmbShare -Name 'ConfigMgr_MPReplica' -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name 'ConfigMgr_MPReplica' -Path $shareRoot -FullAccess 'SYSTEM' -ChangeAccess 'ConfigMgr_MPReplicaAccess' -ErrorAction Stop | Out-Null
            $out += "created share ConfigMgr_MPReplica -> $shareRoot"
        }
        $acl = Get-Acl $shareRoot
        $rules = @(
            (New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')),
            (New-Object System.Security.AccessControl.FileSystemAccessRule("$env:COMPUTERNAME\ConfigMgr_MPReplicaAccess", 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        )
        foreach ($r in $rules) { try { $acl.AddAccessRule($r) } catch {} }
        try { Set-Acl -Path $shareRoot -AclObject $acl } catch { $out += "WARN NTFS ACL: $($_.Exception.Message)" }
    }
    catch { $out += "WARN share: $($_.Exception.Message)" }
    return $out
}

try {
    if ($isSiteSqlLocal) {
        $shareMsgs = & $shareSetupSb $shareAccts $env:USERDOMAIN
    }
    else {
        $shareMsgs = Invoke-Command -ComputerName $siteSqlMachineFqdn -ScriptBlock $shareSetupSb -ArgumentList $shareAccts, $env:USERDOMAIN -ErrorAction Stop
    }
    foreach ($m in @($shareMsgs)) { Write-DscStatus "$Tag [SiteSqlHost $siteSqlShort] $m" }
}
catch { Write-DscStatus "$Tag WARNING: snapshot/cert share setup on $siteSqlShort failed: $($_.Exception.Message)" }

$shareUnc = "\\$siteSqlMachineFqdn\ConfigMgr_MPReplica"

# 2c. Create the publication (the SP does distributor + distribution DB + articles).
try {
    $pubState = Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "IF OBJECT_ID('dbo.syspublications') IS NOT NULL SELECT pubs = (SELECT COUNT(*) FROM dbo.syspublications WHERE name='ConfigMgr_MPReplica'), arts = (SELECT COUNT(*) FROM dbo.sysarticles a JOIN dbo.syspublications p ON a.pubid = p.pubid WHERE p.name='ConfigMgr_MPReplica') ELSE SELECT pubs = 0, arts = 0"
    $pubCount = [int]$pubState.pubs
    $artCount = [int]$pubState.arts
    if ($pubCount -gt 0 -and $artCount -eq 0) {
        # A prior run created the publication but failed before adding articles.
        # Drop the incomplete publication so it is rebuilt cleanly (no subscriptions
        # exist yet at this point). Otherwise sp_addsubscription later fails with
        # 'A publication must have at least one article before a subscription...'.
        Write-DscStatus "$Tag Publication ConfigMgr_MPReplica exists but has 0 articles (incomplete prior run); dropping to recreate."
        try { Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "EXEC sp_droppublication @publication = N'ConfigMgr_MPReplica'" }
        catch { Write-DscStatus "$Tag WARNING: sp_droppublication failed: $($_.Exception.Message)" }
        $pubCount = 0
    }
    if ($pubCount -gt 0) {
        Write-DscStatus "$Tag Publication ConfigMgr_MPReplica already exists on site DB ($artCount articles)."
    }
    else {
        Write-DscStatus "$Tag Creating publication via spCreateMPReplicaPublication..."
        Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "EXEC spCreateMPReplicaPublication"
        Write-DscStatus "$Tag spCreateMPReplicaPublication completed (distributor + CMDistribution + ConfigMgr_MPReplica publication)."
    }
    # NOTE: the Snapshot Agent is (re)started per-subscription in STEP 3, AFTER the
    # subscription is added. The publication is @immediate_sync = 0, so a snapshot
    # generated before any subscription exists has nothing to apply -- the initial
    # sync is driven per replica once its subscription is in place.
}
catch {
    Write-DscStatus "$Tag Failed to publish the site database (spCreateMPReplicaPublication): $($_.Exception.Message)" -Failure
    $hardFailed = $true
}

# ===========================================================================
# STEP 3..6 - per replica MP.
# ===========================================================================
if (-not $hardFailed) {
    # Replication SPs identify the publisher/distributor and each subscriber by the
    # server's OWN @@SERVERNAME (how SQL registered them), NOT the FQDN used for direct
    # connections. Passing the FQDN makes the pull Distribution Agent fail to validate
    # the publisher (agent message 14080: "the remote server ... does not exist, or has
    # not been designated as a valid Publisher"), so the snapshot never applies. Resolve
    # the publisher's real name once.
    $sitePublisherName = $siteSqlServer
    try {
        $spn = Invoke-ReplSql -Instance $siteSqlConn -Query "SELECT n = @@SERVERNAME"
        if ($spn -and $spn.n) { $sitePublisherName = [string]$spn.n }
    }
    catch { Write-DscStatus "$Tag WARNING: could not read site @@SERVERNAME; using $siteSqlServer for replication names." }

    foreach ($t in $targets) {
        $rlabel = "Replica[$($t.MPName)]"
        if ($t.NotReady) {
            Write-DscStatus "$Tag [$rlabel] skipped -- replica SQL host was not reachable in STEP 1 (bring $($t.ReplicaShort) online and re-run)." -Failure
            $hardFailed = $true
            continue
        }
        Write-DscStatus "$Tag ===== $($t.MPName) -> $($t.ReplicaConn) / $($t.ReplicaDbName) (ordinal $($t.CertOrdinal)) ====="

        # -------------------------------------------------------------------
        # STEP 3 - Subscribe the replica DB (create DB, pull subscription, perms).
        # -------------------------------------------------------------------
        try {
            $dbExists = Invoke-ReplSql -Instance $t.ReplicaConn -Query "SELECT COUNT(*) AS c FROM sys.databases WHERE name = N'$($t.ReplicaDbName)'"
            if ([int]$dbExists.c -eq 0) {
                Invoke-ReplSql -Instance $t.ReplicaConn -Query "CREATE DATABASE [$($t.ReplicaDbName)]"
                Write-DscStatus "$Tag [$rlabel] created replica database $($t.ReplicaDbName)."
            }
            # TRUSTWORTHY ON (doc Step 2.3) now that the DB exists.
            Invoke-ReplSql -Instance $t.ReplicaConn -Query "ALTER DATABASE [$($t.ReplicaDbName)] SET TRUSTWORTHY ON;"

            # The subscriber identifies itself to the distributor by its own @@SERVERNAME
            # (e.g. MR1-MPLOCAL, or MR1-REPLSQL2\REPLICA for a named instance), not the
            # FQDN. Use that as the @subscriber name so the publisher's registered
            # subscription matches the name the pull Distribution Agent reports.
            $replicaServerName = $t.ReplicaSqlName
            try {
                $rsn = Invoke-ReplSql -Instance $t.ReplicaConn -Query "SELECT n = @@SERVERNAME"
                if ($rsn -and $rsn.n) { $replicaServerName = [string]$rsn.n }
            }
            catch { }

            # -------------------------------------------------------------------
            # Subscription: SELF-HEALING (not just "create if missing"). A replica that
            # has already synced (XMLConfigStore replicated) is left completely untouched
            # -> idempotent no-op on re-run. Otherwise the subscription is rebuilt from
            # clean: any leftover pull subscription (subscriber) and publisher entry from
            # a prior/failed run are dropped, then re-added FRESH. This is deliberate --
            # a subscription left half-initialized by a prior run gets marked "initialized"
            # WITHOUT data, so the Snapshot Agent reports "no subscriptions needed
            # initialization" and the replica stays empty forever. A freshly added
            # @sync_type='automatic' subscription is always PENDING initialization, so the
            # Snapshot Agent generates a snapshot for it. Re-running the phase therefore
            # repairs a stuck replica instead of skipping over the broken state.
            # -------------------------------------------------------------------
            $alreadySynced = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query "IF OBJECT_ID('dbo.XMLConfigStore') IS NOT NULL SELECT c = COUNT(*) FROM dbo.XMLConfigStore WHERE Name = N'MPReplicaServiceBrokerConfiguration' ELSE SELECT c = 0"
            if ([int]$alreadySynced.c -gt 0) {
                Write-DscStatus "$Tag [$rlabel] replica already synced (XMLConfigStore present); leaving subscription untouched."
            }
            else {
                # Drop any leftover pull subscription on the subscriber (also removes its
                # Distribution Agent job) so we can re-add a clean, pending one. Try both
                # the @@SERVERNAME and the legacy FQDN publisher name so a subscription
                # left by an older build (which used the FQDN) is also cleaned up.
                # NOTE: nested IF -- a freshly CREATEd replica DB has no
                # MSreplication_subscriptions table; referencing it in the same predicate
                # as the OBJECT_ID guard fails to compile ("Invalid object name"), so the
                # EXISTS must live inside the outer IF block (deferred compilation).
                Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
IF OBJECT_ID('dbo.MSreplication_subscriptions') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.MSreplication_subscriptions WHERE publication = 'ConfigMgr_MPReplica')
    BEGIN
        BEGIN TRY EXEC sp_droppullsubscription @publisher = N'$sitePublisherName', @publisher_db = N'$siteDbName', @publication = N'ConfigMgr_MPReplica'; END TRY
        BEGIN CATCH IF ERROR_MESSAGE() NOT LIKE '%does not exist%' AND ERROR_MESSAGE() NOT LIKE '%not exist%' AND ERROR_MESSAGE() NOT LIKE '%could not find%' THROW; END CATCH
        BEGIN TRY EXEC sp_droppullsubscription @publisher = N'$siteSqlServer', @publisher_db = N'$siteDbName', @publication = N'ConfigMgr_MPReplica'; END TRY
        BEGIN CATCH IF ERROR_MESSAGE() NOT LIKE '%does not exist%' AND ERROR_MESSAGE() NOT LIKE '%not exist%' AND ERROR_MESSAGE() NOT LIKE '%could not find%' THROW; END CATCH
    END
END
"@
                # Drop any leftover publisher-side subscription for this replica, under
                # either the @@SERVERNAME or the legacy FQDN subscriber name.
                Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query @"
IF OBJECT_ID('dbo.syspublications') IS NOT NULL
BEGIN
    BEGIN TRY EXEC sp_dropsubscription @publication = N'ConfigMgr_MPReplica', @article = N'all', @subscriber = N'$replicaServerName', @destination_db = N'$($t.ReplicaDbName)'; END TRY
    BEGIN CATCH IF ERROR_MESSAGE() NOT LIKE '%does not exist%' AND ERROR_MESSAGE() NOT LIKE '%not exist%' AND ERROR_MESSAGE() NOT LIKE '%could not find%' THROW; END CATCH
    BEGIN TRY EXEC sp_dropsubscription @publication = N'ConfigMgr_MPReplica', @article = N'all', @subscriber = N'$($t.ReplicaSqlName)', @destination_db = N'$($t.ReplicaDbName)'; END TRY
    BEGIN CATCH IF ERROR_MESSAGE() NOT LIKE '%does not exist%' AND ERROR_MESSAGE() NOT LIKE '%not exist%' AND ERROR_MESSAGE() NOT LIKE '%could not find%' THROW; END CATCH
END
"@
                # Add fresh subscription on the publisher (pending initialization). Use the
                # subscriber's @@SERVERNAME so it matches the name the pull agent reports.
                Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "EXEC sp_addsubscription @publication = N'ConfigMgr_MPReplica', @subscriber = N'$replicaServerName', @destination_db = N'$($t.ReplicaDbName)', @subscription_type = N'pull', @sync_type = N'automatic', @article = N'all', @update_mode = N'read only', @subscriber_type = 0;"
                # Add fresh pull subscription + Distribution Agent on the subscriber. The
                # @publisher/@distributor MUST be the publisher's @@SERVERNAME (not the
                # FQDN) or the agent fails with 14080 "not a valid Publisher". Scheduled
                # every 5 minutes with no end date (frequency_type=4 daily, subday=4
                # minutes, interval=5), as the documented New Subscription Wizard does; the
                # default (@frequency_type=64) runs once at SQL Agent startup, so with
                # @immediate_sync=0 it would run before the snapshot is ready and never retry.
                Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
EXEC sp_addpullsubscription @publisher = N'$sitePublisherName', @publication = N'ConfigMgr_MPReplica', @publisher_db = N'$siteDbName', @independent_agent = N'True', @subscription_type = N'pull', @update_mode = N'read only', @immediate_sync = 0;
EXEC sp_addpullsubscription_agent @publisher = N'$sitePublisherName', @publisher_db = N'$siteDbName', @publication = N'ConfigMgr_MPReplica', @distributor = N'$sitePublisherName', @job_login = NULL, @job_password = NULL, @distributor_security_mode = 1, @frequency_type = 4, @frequency_interval = 1, @frequency_relative_interval = 0, @frequency_recurrence_factor = 0, @frequency_subday = 4, @frequency_subday_interval = 5, @active_start_time_of_day = 0, @active_end_time_of_day = 235959;
"@
                Write-DscStatus "$Tag [$rlabel] pull subscription (re)created clean."

                # Start the Snapshot Agent (distributor) to generate the snapshot for the
                # now-pending subscription, then start the pull Distribution Agent (replica;
                # created stopped -> only runs at SQL Agent startup) to apply it.
                Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query @"
DECLARE @job SYSNAME;
SELECT TOP 1 @job = j.name FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id WHERE s.subsystem = 'Snapshot' AND s.command LIKE '%ConfigMgr_MPReplica%';
IF @job IS NOT NULL BEGIN BEGIN TRY EXEC msdb.dbo.sp_start_job @job_name = @job; END TRY BEGIN CATCH IF ERROR_MESSAGE() NOT LIKE '%already running%' THROW; END CATCH END
"@
                Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
DECLARE @job SYSNAME;
SELECT TOP 1 @job = j.name FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id WHERE s.subsystem = 'Distribution' AND s.command LIKE '%ConfigMgr_MPReplica%';
IF @job IS NOT NULL BEGIN BEGIN TRY EXEC msdb.dbo.sp_start_job @job_name = @job; END TRY BEGIN CATCH IF ERROR_MESSAGE() NOT LIKE '%already running%' THROW; END CATCH END
"@
                Write-DscStatus "$Tag [$rlabel] snapshot + distribution agents started."
            }

            # MP machine account: login + db_datareader on the replica DB.
            $mpLogin = $t.MPAccount
            Invoke-ReplSql -Instance $t.ReplicaConn -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$mpLogin')
    CREATE LOGIN [$mpLogin] FROM WINDOWS;
"@
            Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$mpLogin')
    CREATE USER [$mpLogin] FOR LOGIN [$mpLogin];
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id WHERE r.name = 'db_datareader' AND m.name = N'$mpLogin')
    ALTER ROLE db_datareader ADD MEMBER [$mpLogin];
"@
            Write-DscStatus "$Tag [$rlabel] MP account $mpLogin granted db_datareader."

            # MP machine account -> local Administrators on the replica server (skip if MP == replica).
            if (-not $t.IsLocalToMP) {
                try {
                    Invoke-Command -ComputerName $t.ReplicaShort -ArgumentList $t.MPAccount -ScriptBlock {
                        param($mpAcct)
                        $member = $mpAcct
                        $exists = Get-LocalGroupMember -Group 'Administrators' -Member $member -ErrorAction SilentlyContinue
                        if (-not $exists) { Add-LocalGroupMember -Group 'Administrators' -Member $member -ErrorAction SilentlyContinue }
                    } -ErrorAction Stop
                    Write-DscStatus "$Tag [$rlabel] MP account added to local Administrators on $($t.ReplicaShort)."
                }
                catch { Write-DscStatus "$Tag WARNING [$rlabel] could not add MP acct to Administrators on $($t.ReplicaShort): $($_.Exception.Message)" }
            }
        }
        catch {
            Write-DscStatus "$Tag [$rlabel] subscription setup failed: $($_.Exception.Message)" -Failure
            $hardFailed = $true
            continue
        }

        # -------------------------------------------------------------------
        # STEP 4 - SQL identity certificate on the replica (per instance).
        # -------------------------------------------------------------------
        try {
            $friendly = 'ConfigMgr SQL Server Identification Certificate'
            if ($t.CertOrdinal -gt 0) { $friendly = "ConfigMgr SQL Server Identification Certificate$($t.CertOrdinal)" }
            $skipDelete = ($t.CertOrdinal -gt 0)
            Invoke-Command -ComputerName $t.ReplicaShort -ArgumentList $t.ReplicaInstance, $friendly, $skipDelete -ScriptBlock {
                param($SQLInstance, $FriendlyName, $SkipDelete)
                $sqlServerName = [System.Net.Dns]::GetHostByName("localhost").HostName
                $sqlInstanceName = 'MSSQLSERVER'
                $SQLServiceName = 'MSSQLSERVER'
                if ($SQLInstance -and $SQLInstance -ne 'MSSQLSERVER') {
                    $sqlInstanceName = $SQLInstance
                    $SQLServiceName = "MSSQL`$$SQLInstance"
                }
                function Get-CertStore($storename) {
                    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storename, 'LocalMachine')
                    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                    $store
                }
                if (-not $SkipDelete) {
                    foreach ($sn in 'My', 'TrustedPeople') {
                        $store = Get-CertStore $sn
                        $store.Certificates | Where-Object { $_.FriendlyName -eq $FriendlyName } | ForEach-Object { $store.Remove($_) }
                        $store.Close()
                    }
                }
                # Reuse an existing valid cert with this friendly name (idempotent).
                $existing = (Get-CertStore 'My').Certificates | Where-Object { $_.FriendlyName -eq $FriendlyName -and $_.NotAfter -gt (Get-Date) }
                if (-not $existing) {
                    $name = New-Object -ComObject 'X509Enrollment.CX500DistinguishedName.1'
                    $name.Encode("CN=" + $sqlServerName, 0)
                    $key = New-Object -ComObject 'X509Enrollment.CX509PrivateKey.1'
                    $key.ProviderName = 'Microsoft RSA SChannel Cryptographic Provider'
                    $key.KeySpec = 1
                    $key.Length = 2048
                    $key.SecurityDescriptor = 'D:PAI(A;;0xd01f01ff;;;SY)(A;;0xd01f01ff;;;BA)(A;;0x80120089;;;NS)'
                    $key.MachineContext = 1
                    $key.Create()
                    $serverauthoid = New-Object -ComObject 'X509Enrollment.CObjectId.1'
                    $serverauthoid.InitializeFromValue('1.3.6.1.5.5.7.3.1')
                    $ekuoids = New-Object -ComObject 'X509Enrollment.CObjectIds.1'
                    $ekuoids.Add($serverauthoid)
                    $ekuext = New-Object -ComObject 'X509Enrollment.CX509ExtensionEnhancedKeyUsage.1'
                    $ekuext.InitializeEncode($ekuoids)
                    $certreq = New-Object -ComObject 'X509Enrollment.CX509CertificateRequestCertificate.1'
                    $certreq.InitializeFromPrivateKey(2, $key, "")
                    $certreq.Subject = $name
                    $certreq.Issuer = $certreq.Subject
                    $certreq.NotBefore = Get-Date
                    $certreq.NotAfter = $certreq.NotBefore.AddDays(3650)
                    $certreq.X509Extensions.Add($ekuext)
                    $certreq.Encode()
                    $enrollment = New-Object -ComObject 'X509Enrollment.CX509Enrollment.1'
                    $enrollment.InitializeFromRequest($certreq)
                    $enrollment.CertificateFriendlyName = $FriendlyName
                    $certdata = $enrollment.CreateRequest(0x1)
                    $enrollment.InstallResponse(0x2, $certdata, 0x1, "")
                    [Byte[]]$bytes = [System.Convert]::FromBase64String($certdata)
                    $tp = New-Object System.Security.Cryptography.X509Certificates.X509Store 'TrustedPeople', 'LocalMachine'
                    $tp.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                    $tp.Add([Security.Cryptography.X509Certificates.X509Certificate2]$bytes)
                    $tp.Close()
                    $thumb = ([Security.Cryptography.X509Certificates.X509Certificate2]$bytes).Thumbprint.ToLower()
                }
                else {
                    $thumb = $existing[0].Thumbprint.ToLower()
                }
                # Point SQL at the cert (per-instance) and restart so it takes effect.
                $path = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                $subKey = (Get-ItemProperty $path).$sqlInstanceName
                $realPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\' + $subKey + '\MSSQLServer\SuperSocketNetLib'
                $current = (Get-ItemProperty -Path $realPath -Name 'Certificate' -ErrorAction SilentlyContinue).'Certificate'
                if ($current -ne $thumb) {
                    Set-ItemProperty -Path $realPath -Name 'Certificate' -Type String -Value $thumb
                    Restart-Service $SQLServiceName -Force
                }
            } -ErrorAction Stop
            Write-DscStatus "$Tag [$rlabel] SQL identity cert '$friendly' ensured on $($t.ReplicaShort)."
        }
        catch { Write-DscStatus "$Tag WARNING [$rlabel] SQL identity cert step failed: $($_.Exception.Message)" }

        # -------------------------------------------------------------------
        # STEP 5 - Service Broker wiring + directional routes.
        #   @ServerName / @DestSQLServerName MUST match the Step-6 -SqlServerFqdn
        #   (ReplicaFqdn) so the DBID hash lines up.
        # -------------------------------------------------------------------
        try {
            $replicaCert = "$shareUnc\replica_$($t.MPShort).cer"
            $siteCert = "$shareUnc\site_$SiteCode.cer"
            $replicaSrvForHash = $t.ReplicaFqdn

            # 5.0 Wait for the initial replication snapshot to populate the replica DB.
            # sp_BgbConfigSSBForReplicaDB reads the 'MPReplicaServiceBrokerConfiguration'
            # row from the REPLICATED XMLConfigStore table; until the snapshot applies,
            # that table does not exist in the replica DB and the SP would silently
            # create no SSB objects (its WHILE loops run 0 times on a NULL config).
            $syncDeadline = (Get-Date).AddMinutes(20)
            $replicaSynced = $false
            $pollCount = 0
            while ((Get-Date) -lt $syncDeadline) {
                try {
                    $chk = Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query "IF OBJECT_ID('dbo.XMLConfigStore') IS NOT NULL SELECT COUNT(*) AS c FROM dbo.XMLConfigStore WHERE Name = N'MPReplicaServiceBrokerConfiguration' ELSE SELECT 0 AS c"
                    if ([int]$chk.c -gt 0) { $replicaSynced = $true; break }
                }
                catch { }
                $pollCount++
                # Every ~2.5 min, re-nudge both agents (the Distribution Agent may have
                # run once before the snapshot was ready and then exited).
                if ($pollCount % 5 -eq 0) {
                    try {
                        Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "DECLARE @job SYSNAME; SELECT TOP 1 @job = j.name FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id WHERE s.subsystem = 'Snapshot' AND s.command LIKE '%ConfigMgr_MPReplica%'; IF @job IS NOT NULL BEGIN BEGIN TRY EXEC msdb.dbo.sp_start_job @job_name = @job; END TRY BEGIN CATCH END END"
                        Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query "DECLARE @job SYSNAME; SELECT TOP 1 @job = j.name FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id WHERE s.subsystem = 'Distribution' AND s.command LIKE '%ConfigMgr_MPReplica%'; IF @job IS NOT NULL BEGIN BEGIN TRY EXEC msdb.dbo.sp_start_job @job_name = @job; END TRY BEGIN CATCH END END"
                    }
                    catch { }
                }
                Start-Sleep -Seconds 30
            }
            if (-not $replicaSynced) {
                throw "Replica DB [$($t.ReplicaDbName)] did not receive the replicated XMLConfigStore ('MPReplicaServiceBrokerConfiguration') within 20 minutes; the initial replication snapshot did not apply (see the Snapshot/Distribution Agent history in the diagnostics below). Service Broker cannot be configured."
            }
            Write-DscStatus "$Tag [$rlabel] replica DB initial replication synced (XMLConfigStore present)."

            # 5.1 Enable broker on the replica DB.
            Invoke-ReplSql -Instance $t.ReplicaConn -Query "ALTER DATABASE [$($t.ReplicaDbName)] SET ENABLE_BROKER, HONOR_BROKER_PRIORITY ON WITH ROLLBACK IMMEDIATE;"

            # 5.2 Build replica SSB objects + back up the replica transport cert.
            Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query "EXEC sp_BgbConfigSSBForReplicaDB N'$replicaSrvForHash', N'$($t.ReplicaDbName)', N'$replicaCert'"

            # 5.3 Site imports the replica cert + builds route site -> replica.
            Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "EXEC sp_BgbConfigSSBForRemoteService N'REPLICA', N'$SSBPort', N'$replicaCert', N'$replicaSrvForHash', N'$($t.ReplicaDbName)'"

            # 5.4 Back up the site transport cert.
            Invoke-ReplSql -Instance $siteSqlConn -Database $siteDbName -Query "EXEC sp_BgbCreateAndBackupSQLCert N'$siteCert'"

            # 5.5 Replica imports the site cert + builds route replica -> site.
            Invoke-ReplSql -Instance $t.ReplicaConn -Database $t.ReplicaDbName -Query "EXEC sp_BgbConfigSSBForRemoteService N'$SiteCode', N'$SSBPort', N'$siteCert'"

            Write-DscStatus "$Tag [$rlabel] Service Broker wired (routes both directions)."
        }
        catch {
            Write-DscStatus "$Tag [$rlabel] Service Broker wiring failed: $($_.Exception.Message)" -Failure
            $hardFailed = $true
            continue
        }
    }
}

# ===========================================================================
# STEP 6 - Point each MP at its replica DB (site server, via the CM PS drive).
#          Done LAST; flips v_BgbMP.DBID to the hash so BGB uses the new route.
# ===========================================================================
if (-not $hardFailed) {
    try {
        . $PSScriptRoot\Connect-CMSite.ps1 -Tag $Tag
        foreach ($t in $targets) {
            $rlabel = "Replica[$($t.MPName)]"
            $instanceForCmdlet = if ($t.ReplicaInstance) { $t.ReplicaInstance } else { 'MSSQLSERVER' }
            try {
                Set-CMManagementPoint -SiteSystemServerName $t.MPFqdn -SiteCode $SiteCode -UseSiteDatabase $false -SqlServerFqdnName $t.ReplicaFqdn -SqlServerInstanceName $instanceForCmdlet -DatabaseName $t.ReplicaDbName -ErrorAction Stop
                Write-DscStatus "$Tag [$rlabel] MP repointed to replica DB $($t.ReplicaFqdn)\$instanceForCmdlet / $($t.ReplicaDbName)."
            }
            catch {
                Write-DscStatus "$Tag [$rlabel] Set-CMManagementPoint to replica failed: $($_.Exception.Message)" -Failure
                $hardFailed = $true
            }
        }
    }
    catch {
        Write-DscStatus "$Tag MP-role wiring failed (Connect-CMSite): $($_.Exception.Message)" -Failure
        $hardFailed = $true
    }
}

if ($hardFailed) {
    try { Write-MPReplicaDiagnostics -SiteInstance $siteSqlConn -SiteDb $siteDbName -Targets $targets }
    catch { Write-DscStatus "$Tag WARNING: diagnostics collection failed: $($_.Exception.Message)" }
    Write-DscStatus "$Tag Completed with failures. See ConfigMgrSetup / DSC logs and run Test-MPDatabaseReplicaHealth.ps1." -Failure
    Set-MPReplicaStatus -Status 'Failed'
    return
}

Write-DscStatus "$Tag All MP database replicas configured for site $SiteCode."
Set-MPReplicaStatus -Status 'Completed'
