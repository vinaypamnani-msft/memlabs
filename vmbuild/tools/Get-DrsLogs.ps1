<#
.SYNOPSIS
    Collects the DRS / replication diagnostic logs and a SQL replication-state snapshot from a CAS+Primary
    hierarchy (CAS, child Primary, and their MP/DP site systems) into logs\drs-investigation\<VM>\.

    CONFIG-DRIVEN: resolves the VMs and each site's SQL host (honoring remoteSQLVM) from Get-List and
    connects with Get-VmSession (PowerShell Direct, credential-managed). No hardcoded VM names/domains.
    Logs are pulled from the SITE SERVERS (where rcmctrl etc. live); the SQL snapshot runs on each site's
    SQL host (which may be a remote SQL VM, e.g. CST-PRISITE -> CST-PRISQL).

.PARAMETER Domain        Domain FQDN to scope to. Auto-detected if only one CAS hierarchy exists.
.PARAMETER PrimaryName   Limit collection to a specific child-primary VM. Omit to collect from ALL child primaries under the CAS.
.PARAMETER TailLines     Tail size for the on-screen preview of rcmctrl.log (default 30; 0 = no preview).

.PARAMETER WatchSendChain
    Instead of a one-shot collection, poll every table the CAS send decision actually reads -- on the CAS
    AND every child primary -- until the content lands, and log only what CHANGED. This exists because the
    child-primary client-package coverage wait costs 579-2622s (mean 1718s) and distmgr logs NOTHING when it
    decides not to send. Start it as Phase 8 begins on the child; run the plain collection afterwards.

    Decision chain, source-verified in distmgr.cpp -- this is what the poll is aimed at:
      ~14640 outer gate     : pkg.SourceSite == thisSite && Action != DELETE && StoreFlag != NO_SRC
      ~27862 bServerChange  : FALSE iff PkgSrvAction == NONE, or (UPDATE && UpdateMask == 0)
      ~27908 bResendPkg     : TRUE iff pkgUpdateMask & PKG_UPDATE_SOURCE, or
                              (& PKG_UPDATE_LASTREFRESH && StoreFlag == PKG_STORAGE_DIRECT)
      ~14663 send iff       : bResendPkg || IsPkgSendingNeeded(...)
      ~23172 IsPkgSendingNeeded reads PkgStatus_G(Type=PKG_TYPE_MAIN, SiteCode): no row -> send;
             version match && INSTALLED/RECEIVED -> no; SENT within 1 day -> no; else send.
    The declining path falls out of the else-if and IsPkgSendingNeeded has no logging at all, so the
    database is the only witness. Do NOT read absence of a distmgr line as absence of a decision.

    Queries are SELECT * with the COLUMN NAMES filtered at runtime, so no column name is ever guessed.
    Read-only throughout.

.PARAMETER PackageId    Package to follow under -WatchSendChain. Auto-resolved to the Configuration Manager Client Package if omitted.

.PARAMETER FlushExperiment
    INTERVENES on the lab. Tests the one thing left unexplained: a child primary's PkgServers row can
    sit for 20+ minutes without reaching the CAS, and the reverted 8527f678 flushed the correct group
    ('Configuration Data', measured from ArticleData) yet did not speed anything up.

    Pre-registered, so the result cannot be rationalised afterwards:
      precondition  child HAS its own PkgServers_G row and the CAS does NOT. Otherwise abort --
                    there is nothing to test.
      baseline      poll the CAS every 15s for -BaselineSeconds with NO intervention. If the row
                    arrives during this, the flush was NOT tested and the run says exactly that.
      intervention  EXEC dbo.spDRSSendChangesForGroup @ReplicationGroup='Configuration Data' on the CHILD.
      measure       flush -> row visible at CAS, then row -> send in the CAS distmgr log.
    Requires -PrimaryName. ONE trial is not proof. It discriminates "a flush cannot move this row"
    from "8527f678 simply ran at the wrong moment", which is the fork the investigation is stuck on.

.PARAMETER BaselineSeconds  No-intervention baseline before the flush (default 180).
.PARAMETER PostSeconds      How long to watch after the flush (default 900).
.PARAMETER IntervalSeconds  Poll interval for -WatchSendChain (default 20).
.PARAMETER MaxMinutes   Give up after this long under -WatchSendChain (default 120). Counts from ARMING, not from launch: arming lands at child site install, and the rest of Phase 8 still has to run before the coverage wait, whose own worst case is 2622s.
.PARAMETER ArmWaitMinutes
    Let -WatchSendChain be started at ANY phase. It polls once a minute until ConfigMgr answers on the
    CAS and on every child primary, then resolves the package and begins the real watch. 0 (default)
    means everything must already be installed, i.e. you are starting during Phase 8.
    Use this to start the watch in Phase 2 and walk away -- the transition being chased is a single
    unlogged decision, so being late to it costs the whole run.

.EXAMPLE
    cd C:\memlabs\vmbuild\tools ; .\Get-DrsLogs.ps1
.EXAMPLE
    .\Get-DrsLogs.ps1 -Domain cstest8.com
.EXAMPLE
    .\Get-DrsLogs.ps1 -WatchSendChain
.EXAMPLE
    # start during Phase 2 of an add-child-primary run and let it arm itself
    .\Get-DrsLogs.ps1 -WatchSendChain -ArmWaitMinutes 300
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string]$PrimaryName,
    [int]$TailLines = 30,
    [switch]$WatchSendChain,
    [string]$PackageId,
    [int]$IntervalSeconds = 20,
    [int]$MaxMinutes = 120,
    [int]$ArmWaitMinutes = 0,
    [switch]$FlushExperiment,
    [switch]$ResetChildPackageState,
    [switch]$DrsProbe,
    [int]$BaselineSeconds = 180,
    [int]$PostSeconds = 900
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$vmbuildRoot = Split-Path -Parent $scriptRoot
Set-Location $vmbuildRoot

$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
$bom = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM (PS5.1 parse hazard). Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Red
    exit 1
}
. $commonPath -InJob

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logsRoot = Join-Path $vmbuildRoot 'logs'
$destRoot = Join-Path $logsRoot 'drs-investigation'
New-Item -ItemType Directory -Path $destRoot -Force | Out-Null

$logNames = @('rcmctrl.log', 'rcmctrl.lo_', 'smsexec.log', 'hman.log', 'sender.log', 'despool.log', 'despoolr.log', 'replmgr.log', 'dataldr.log', 'ConfigMgrSetup.log')

# ---- resolve topology ----
function Resolve-SqlVm {
    param($SiteVm, $AllVms)
    if ([string]::IsNullOrWhiteSpace($SiteVm.remoteSQLVM)) { return $SiteVm }
    $r = @($AllVms | Where-Object { $_.domain -eq $SiteVm.domain -and $_.vmName -eq $SiteVm.remoteSQLVM })
    if ($r.Count -eq 0) { $r = @($AllVms | Where-Object { $_.domain -eq $SiteVm.domain -and ($_.vmName -like "*$($SiteVm.remoteSQLVM)") }) }
    if ($r.Count -gt 0) { return $r[0] }
    return $SiteVm
}

Write-Host "================ Get-DrsLogs  $stamp ================" -ForegroundColor Cyan
$allVms = @(Get-List -Type VM -SmartUpdate)
if ($Domain) { $allVms = @($allVms | Where-Object { $_.domain -eq $Domain }) }

$casList = @($allVms | Where-Object { $_.role -eq 'CAS' })
if ($casList.Count -eq 0) { Write-Host "FATAL: no CAS found$(if ($Domain) { " in domain $Domain" })." -ForegroundColor Red; return }
$casDomains = @($casList | Select-Object -ExpandProperty domain -Unique)
if ($casDomains.Count -gt 1) { Write-Host "FATAL: CAS in multiple domains ($($casDomains -join ', ')). Re-run with -Domain." -ForegroundColor Red; return }
$cas = $casList[0]
$dom = $cas.domain

$priList = @($allVms | Where-Object { $_.role -eq 'Primary' -and $_.domain -eq $dom -and $_.parentSiteCode -eq $cas.siteCode })
if ($priList.Count -eq 0) { Write-Host "FATAL: no child Primary under CAS $($cas.vmName) (site $($cas.siteCode))." -ForegroundColor Red; return }
if ($PrimaryName) { $priList = @($priList | Where-Object { $_.vmName -eq $PrimaryName }) }
if ($priList.Count -eq 0) { Write-Host "FATAL: -PrimaryName '$PrimaryName' did not match." -ForegroundColor Red; return }
# Multiple child primaries are fine - we collect from all of them (use -PrimaryName to narrow to one).

$siteCodes = @($cas.siteCode) + @($priList | Select-Object -ExpandProperty siteCode)
$siteSystems = @($allVms | Where-Object { $_.role -in @('SiteSystem', 'DPMP') -and $_.domain -eq $dom -and ($_.siteCode -in $siteCodes -or $_.parentSiteCode -in $siteCodes) })

$logTargets = @($cas) + $priList + $siteSystems | Sort-Object vmName -Unique
Write-Host "Domain  : $dom" -ForegroundColor Gray
Write-Host "CAS     : $($cas.vmName) (site $($cas.siteCode))  SQL: $((Resolve-SqlVm $cas $allVms).vmName)" -ForegroundColor Gray
foreach ($p in $priList) { Write-Host "Primary : $($p.vmName) (site $($p.siteCode))  SQL: $((Resolve-SqlVm $p $allVms).vmName)" -ForegroundColor Gray }
if ($siteSystems.Count) { Write-Host "SiteSys : $($siteSystems.vmName -join ', ')" -ForegroundColor Gray }
Write-Host ""

# ---- in-guest replication-state snapshot (runs on the SQL VM) ----
# With -PkgId this switches to send-chain mode and returns the package's rows instead of the site
# replication state. Same block on purpose: the instance/port discovery below is the part that was
# hard to get right, and a second copy of it would drift.
$sqlSnapBlock = {
    param($siteCode, $PkgId, $FlushGroup, $ExecSql, $ExecSite)
    $out = New-Object System.Collections.Generic.List[string]
    # 'localhost' silently means default-instance-on-1433. CS2-PS2SQL is MSSQL instance 'BOB'
    # on port 41223, so every query failed with "Named Pipes ... error 40" and the snapshot
    # came back empty -- which reads exactly like a site with nothing to report.
    $candidates = New-Object System.Collections.Generic.List[string]
    $psMeta = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    try {
        $names = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
        foreach ($p in $names.PSObject.Properties) {
            if ($psMeta -contains $p.Name) { continue }
            $instId = "$($p.Value)"; $port = $null
            foreach ($sub in @('IPAll')) {
                $tcp = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\MSSQLServer\SuperSocketNetLib\Tcp\$sub"
                try { $t = Get-ItemProperty -Path $tcp -ErrorAction Stop
                    if ($t.TcpPort) { $port = "$($t.TcpPort)".Split(',')[0] }
                    elseif ($t.TcpDynamicPorts) { $port = "$($t.TcpDynamicPorts)".Split(',')[0] } }
                catch { }
            }
            $base = if ($p.Name -ieq 'MSSQLSERVER') { 'localhost' } else { "localhost\$($p.Name)" }
            if ($port) { $candidates.Add("$base,$port") }
            $candidates.Add($base)
        }
    }
    catch { }
    $candidates.Add('localhost')
    $server = $null
    $db = $null
    foreach ($c in $candidates) {
        try {
            $cs = "Server=$c;Initial Catalog=master;Integrated Security=True;Connect Timeout=10;Encrypt=False;TrustServerCertificate=True"
            $cn = New-Object System.Data.SqlClient.SqlConnection $cs; $cn.Open()
            $cmd = $cn.CreateCommand(); $cmd.CommandText = "SELECT TOP 1 name FROM sys.databases WHERE name = 'CM_$siteCode' OR name LIKE 'CM[_]%' ORDER BY CASE WHEN name='CM_$siteCode' THEN 0 ELSE 1 END, name"
            $found = $cmd.ExecuteScalar(); $cn.Close()
            if ($found) { $server = $c; $db = $found; break }
        }
        catch { }
    }
    if (-not $db) { $out.Add("Could not resolve CM database. Tried: $($candidates -join ' | ')"); return $out }
    if ($ExecSql) {
        # @p = package, @s = site code. Rows affected is reported so the caller can verify the write
        # landed instead of assuming it did.
        try {
            $cs = "Server=$server;Initial Catalog=$db;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
            $cn = New-Object System.Data.SqlClient.SqlConnection $cs
            $cn.Open()
            $cmd = $cn.CreateCommand()
            $cmd.CommandText = $ExecSql
            $cmd.CommandTimeout = 120
            [void]$cmd.Parameters.AddWithValue('@p', "$PkgId")
            [void]$cmd.Parameters.AddWithValue('@s', "$ExecSite")
            $n = $cmd.ExecuteNonQuery()
            $cn.Close()
            $out.Add("EXEC rows=$n :: $ExecSql")
        }
        catch { $out.Add("EXEC FAILED :: $ExecSql :: " + $_.Exception.Message) }
        return $out
    }
    if ($FlushGroup) {
        # The one write this tool makes. spDRSSendChangesForGroup is the same proc ConfigMgr's own
        # RCM calls; scope is CAS_OR_PRIMARY_OR_SECONDARY (verified in source).
        try {
            $cs = "Server=$server;Initial Catalog=$db;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
            $cn = New-Object System.Data.SqlClient.SqlConnection $cs
            $cn.Open()
            $cmd = $cn.CreateCommand()
            $cmd.CommandText = 'dbo.spDRSSendChangesForGroup'
            $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
            $cmd.CommandTimeout = 180
            [void]$cmd.Parameters.AddWithValue('@ReplicationGroup', $FlushGroup)
            [void]$cmd.ExecuteNonQuery()
            $cn.Close()
            $out.Add("FLUSH OK '$FlushGroup' on $db ($server)")
        }
        catch { $out.Add("FLUSH FAILED '$FlushGroup': " + $_.Exception.Message) }
        return $out
    }
    function Q {
        param($q, $title, $keep, $p)
        $rows = 0
        if (-not $keep) { $out.Add("---- $title ----") }
        try {
            $cs = "Server=$server;Initial Catalog=$db;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
            $cn = New-Object System.Data.SqlClient.SqlConnection $cs
            $cn.Open()
            $cmd = $cn.CreateCommand(); $cmd.CommandText = $q; $cmd.CommandTimeout = 60
            if ($p) { [void]$cmd.Parameters.AddWithValue('@p', $p) }
            $r = $cmd.ExecuteReader()
            while ($r.Read()) {
                $rows++
                $line = @()
                for ($i = 0; $i -lt $r.FieldCount; $i++) {
                    $nm = $r.GetName($i)
                    if ($keep -and $nm -notmatch $keep) { continue }
                    $v = $r.GetValue($i)
                    if ($keep -and $v -is [DBNull]) { continue }
                    $line += ("{0}={1}" -f $nm, $v)
                }
                if ($keep) { $out.Add("$title[$rows] " + ($line -join ' ')) } else { $out.Add('  ' + ($line -join '  ')) }
            }
            $r.Close(); $cn.Close()
            # Absence is evidence here -- no row in PkgStatus_G is what makes IsPkgSendingNeeded return TRUE.
            if ($keep -and $rows -eq 0) { $out.Add("$title NO ROWS") }
        }
        catch { if ($keep) { $out.Add("$title ERROR: " + $_.Exception.Message) } else { $out.Add('  ERROR: ' + $_.Exception.Message) } }
    }
    if ($PkgId) {
        $keep = 'Action|Mask|Version|SiteCode|SourceSite|Flags|Status|Refresh|Type|PkgID|^ID$|Priority|Time|Date'
        Q "SELECT * FROM PkgStatus_G WHERE ID = @p" 'PkgStatus_G' $keep $PkgId
        Q "SELECT * FROM PkgServers_G WHERE PkgID = @p" 'PkgServers_G' $keep $PkgId
        Q "SELECT * FROM PkgServers_L WHERE PkgID = @p" 'PkgServers_L' $keep $PkgId
        Q "SELECT * FROM SMSPackages WHERE PkgID = @p" 'SMSPackages' $keep $PkgId
        # Type: 1 Package, 2 Program, 4 Package Server (DP), 8 Access account (PkgNotification.h).
        Q "SELECT * FROM PkgNotification WHERE PkgID = @p" 'PkgNotification' $keep $PkgId
        return $out
    }
    $out.Add("CM database: $db  (server $server)")
    Q "SELECT SiteCode, SiteStatus FROM ServerData ORDER BY SiteCode" "ServerData (SiteStatus per site)"
    # SyncInterval is MINUTES and it is the whole schedule: spDRSInitiateSynchronizations only queues
    # a group once (60*SyncInterval) seconds have passed since LastSendStartTime, so a change lands at
    # a random point in that cycle and waits, on average, half of it.
    Q "SELECT ReplicationGroup, ReplicationPattern, SyncInterval, IsPush, ReplicationPriority, TransportType, Flags FROM ReplicationData ORDER BY SyncInterval DESC, ReplicationGroup" "ReplicationData (SyncInterval in MINUTES = the send cadence)"
    Q "SELECT TOP 60 rd.ReplicationGroup, rd.ReplicationPattern, s.SiteCode, s.Active, s.LastSendResult, s.LastVersionSent, s.LastSendStartTime, s.LastSendEndTime FROM DRS_MessageActivity_Send s INNER JOIN ReplicationData rd ON rd.ID = s.ReplicationID ORDER BY s.LastSendStartTime DESC" "DRS_MessageActivity_Send (per-group send status; LastSendResult<0 = error)"
    Q "SELECT rd.ReplicationGroup, rd.ReplicationPattern, s.SiteCode, s.Active, s.LastSendResult FROM DRS_MessageActivity_Send s INNER JOIN ReplicationData rd ON rd.ID = s.ReplicationID WHERE s.LastSendResult < 0 ORDER BY rd.ReplicationGroup" "Send groups with an ERROR result (LastSendResult<0)"
    # Per-group link status both directions. spGetLinkOverAllStatus takes MAX(Status) across
    # groups, so one lagging group is what turns the whole link Degraded (7816) / Failed (7822).
    Q "SELECT rd.ReplicationGroup, rd.ReplicationPattern, s.SiteSending, s.SiteReceiving, s.Status FROM RCM_ReplicationLinkStatus s INNER JOIN ReplicationData rd ON rd.ID = s.ReplicationID ORDER BY s.Status DESC, s.SiteSending, rd.ReplicationGroup" "RCM_ReplicationLinkStatus (per-group, both directions)"
    # A child primary's own PkgServers row is what tells the CAS the site needs content; until it
    # replicates UP, the CAS finds no such site and declines to send WITHOUT LOGGING ANYTHING.
    # Measured: these all sit in 'Configuration Data' (global), which is exactly what the reverted
    # 8527f678 flushed -- so a correctly targeted flush that did transmit still did not help, and why
    # is still unknown. Confirm the group here before anyone proposes flushing again.
    # SyncInterval=1 and healthy links mean transport is NOT the delay, so the question becomes
    # whether the change is even offered to the sender: FilterColumn can exclude rows from a site's
    # send, and IsColumnTracked/CCARPopulated govern how change tracking picks the row up.
    # spLogEntry writes DRS's own reasons into the Logs TABLE, not rcmctrl.log -- searching the file
    # log for "Not sending changes to sites" returns nothing because it was never written there.
    # Columns verified in Core/Tables/Logs.h.
    # TOP 200 unfiltered spans only minutes -- Hardware_Inventory_* floods this table every cycle.
    # Scoping to the group that carries PkgServers_G makes 200 rows reach back hours instead.
    # 'No changes detected for group.' at a moment the child HAS the row and the CAS does not is
    # DRS stating that change tracking never offered it.
    Q "SELECT TOP 200 LogTime, ProcedureName, LogText FROM Logs WHERE LogText LIKE '%[[]Configuration Data]%' ORDER BY LogLine DESC" "Logs: Configuration Data (the group carrying PkgServers_G)"
    Q "SELECT TOP 60 LogTime, ProcedureName, LogText FROM Logs WHERE (ProcedureName LIKE 'spDRS%' OR ProcedureName LIKE 'spRcm%') AND (LogText LIKE '%Not sending changes%' OR LogText LIKE '%previous sync has not completed%' OR LogText LIKE '%Scheduling is off%' OR LogText LIKE '%re-init%' OR LogText LIKE '%invalid subscription%') ORDER BY LogLine DESC" "Logs: DRS refusals (throttle / changed dialog / schedule / reinit)"
    Q "SELECT ad.ArticleName, ad.Type, rd.ReplicationGroup, rd.ReplicationPattern, ad.FilterColumn, ad.IsColumnTracked, ad.CCARPopulated, ad.FireTriggersOnBCP, ad.OptionalFlag FROM ArticleData ad INNER JOIN ReplicationData rd ON rd.ID = ad.ReplicationID WHERE ad.ArticleName LIKE 'Pkg%' OR ad.ArticleName LIKE 'SMSPackages%' ORDER BY ad.ArticleName" "Replication group per Pkg*/SMSPackages* article"
    # ChangeCount is how many changes the extraction actually FOUND for that sync, so a run of
    # ChangeCount=0 rows while the row provably exists locally is DRS saying change tracking never
    # offered it -- which separates "not extracted" from "extracted but not delivered". Columns
    # verified in Core/Tables/DrsSendHistory.h.
    Q "SELECT TOP 40 h.ID, h.TargetSite, h.ChangeCount, h.MessageCount, h.StartTime, h.EndTime, h.ProcessedTime, h.SyncCompleteTime FROM DrsSendHistory h INNER JOIN ReplicationData rd ON rd.ID = h.ReplicationGroupID WHERE rd.ReplicationGroup = 'Configuration Data' ORDER BY h.ID DESC" "DrsSendHistory: Configuration Data (ChangeCount per sync = was anything offered)"
    Q "SELECT TOP 40 h.ID, rd.ReplicationGroup, h.TargetSite, h.ChangeCount, h.MessageCount, h.StartTime, h.EndTime FROM DrsSendHistory h INNER JOIN ReplicationData rd ON rd.ID = h.ReplicationGroupID WHERE h.ProcessedTime IS NULL ORDER BY h.ID DESC" "DrsSendHistory: sends still unprocessed (ProcessedTime IS NULL)"
    # Status 6 = DRS_INIT_ACTIVE, 7 = aborted-but-historical; anything else means a group is still
    # initializing and the site is in Maintenance Mode. Core/Tables/RCM_DrsInitializationTracking.h.
    Q "SELECT SiteRequesting, SiteFulfilling, ReplicationGroup, InitializationStatus, InitializationPercent, TryCount, CreatedTime, ModifiedTime FROM RCM_DrsInitializationTracking WHERE InitializationStatus NOT IN (6,7) ORDER BY ModifiedTime DESC" "RCM_DrsInitializationTracking: groups NOT active (init still pending)"
    Q "SELECT s.SiteSending, s.SiteReceiving, rd.ReplicationGroup, s.Status, s.StatusName, s.SnapshotApplied, s.SnapshotAppliedTime FROM RCM_ReplicationLinkStatus s INNER JOIN ReplicationData rd ON rd.ID = s.ReplicationID WHERE s.SnapshotApplied IS NULL OR s.SnapshotApplied <> 1 ORDER BY rd.ReplicationGroup" "RCM_ReplicationLinkStatus: snapshot NOT applied (waiting on init)"
    # rcmctrl logs 'Changed the status of ConfigMgrDRSQueue to OFF' on entering Maintenance Mode;
    # this is the live state rather than the last logged transition.
    Q "SELECT name, is_receive_enabled, is_enqueue_enabled, is_activation_enabled FROM sys.service_queues WHERE name LIKE 'ConfigMgr%' ORDER BY name" "Service Broker queues (is_receive_enabled=0 means DRS is halted)"
    return $out
}

$logCollectBlock = {
    param($logNames)
    $dir = $null
    try { $inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction Stop).'Installation Directory'; if ($inst) { $dir = Join-Path $inst 'Logs' } } catch {}
    if (-not $dir) { foreach ($c in @('E:\ConfigMgr\Logs', 'D:\Program Files\Microsoft Configuration Manager\Logs', 'C:\Program Files\Microsoft Configuration Manager\Logs')) { if (Test-Path $c) { $dir = $c; break } } }
    $found = @()
    if ($dir) { foreach ($n in $logNames) { $p = Join-Path $dir $n; if (Test-Path $p) { $found += $p } } }
    # ConfigMgrSetup.log lives at the system drive root
    foreach ($c in @('C:\ConfigMgrSetup.log', 'D:\ConfigMgrSetup.log', 'E:\ConfigMgrSetup.log')) { if (Test-Path $c) { $found += $c } }
    return [pscustomobject]@{ LogDir = $dir; Files = $found }
}

# ---- send-chain watch (-WatchSendChain) ----
# distmgr writes PkgStatus SENT at ~14900 and consumes it at ~23219; sender moves the .PCK; despool on the
# child receives it. Watch all three logs plus the file itself, because the DECLINE path logs nothing.
$pkgLogBlock = {
    param($PkgId)
    $o = New-Object System.Collections.Generic.List[string]
    $d = $null
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $d = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch { }
        if ($d) { break }
    }
    if (-not $d) { return @('LOG ERROR: no install dir') }
    foreach ($n in @('distmgr.log', 'sender.log', 'despool.log')) {
        $f = Join-Path $d "Logs\$n"
        if (-not (Test-Path $f)) { continue }
        foreach ($x in @(Get-Content -LiteralPath $f -Tail 400 -ErrorAction SilentlyContinue | Where-Object { $_ -match [regex]::Escape($PkgId) })) {
            $o.Add("LOG $n :: " + (($x -replace '\s+', ' ').Trim()))
        }
    }
    foreach ($base in @($d, 'E:\SMSPKG', 'C:\SMSPKG', (Join-Path $d 'inboxes\despoolr.box\receive'))) {
        if (-not $base -or -not (Test-Path $base)) { continue }
        foreach ($g in @(Get-ChildItem -LiteralPath $base -Filter "$PkgId*" -File -ErrorAction SilentlyContinue)) {
            $o.Add("PCK $($g.FullName) $([int]($g.Length / 1MB))MB $($g.LastWriteTime.ToString('HH:mm:ss'))")
        }
    }
    return $o.ToArray()
}

# StoredPkgVersion lives in SMSPackages_L (local, never replicated) and flips LAST, so it is a good
# arrival oracle. It explains nothing about the delay -- do not reason backwards from it.
$pkgWmiBlock = {
    param($PkgId, $SiteCode)
    try {
        $k = Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_Package -Filter "PackageID='$PkgId'" -ErrorAction Stop | Select-Object -First 1
        if ($k) { return @("WMI StoredPkgVersion=$($k.StoredPkgVersion) SourceVersion=$($k.SourceVersion)") }
        return @('WMI no row')
    }
    catch { return @("WMI ERROR: $($_.Exception.Message)") }
}

$pkgFindBlock = {
    param($SiteCode)
    try {
        $p = @(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_Package -ErrorAction Stop | Where-Object { $_.Name -eq 'Configuration Manager Client Package' })
        return @($p | ForEach-Object { "$($_.PackageID) $($_.Name)" })
    }
    catch { return @("ERROR: $($_.Exception.Message)") }
}

# Deliberately reuses SMS_Package -- the one class in this namespace already proven to work here.
# A site with no packages returns empty without throwing, so this tests the namespace, not the data.
$cmReadyBlock = {
    param($SiteCode)
    try {
        $null = @(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_Package -ErrorAction Stop | Select-Object -First 1)
        return @('CMREADY')
    }
    catch { return @("CMWAIT: $($_.Exception.Message)") }
}

$script:watchSessions = @{}
# SMS_DistributionPoint is the targeting table InstallBoundaryGroups.ps1 already drives; going
# through it (and Start-CMContentDistribution) keeps the re-add on the real provider path rather
# than hand-writing a PkgServers row that ConfigMgr would never produce.
$dpTargetingBlock = {
    param($SiteCode, $PkgId, $Mode, $DpFqdn)
    $o = New-Object System.Collections.Generic.List[string]
    $ns = "root\SMS\site_$SiteCode"
    $fqdnOf = { param($nal) if ("$nal" -match '\\\\([^\\"\]]+)') { $Matches[1] } else { "$nal" } }
    if ($Mode -eq 'add') {
        try {
            $ui = $env:SMS_ADMIN_UI_PATH
            if (-not $ui) { return @('ADD ERROR: SMS_ADMIN_UI_PATH not set') }
            Import-Module (Join-Path (Split-Path $ui -Parent) 'ConfigurationManager.psd1') -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root "$env:COMPUTERNAME.$env:USERDNSDOMAIN" -ErrorAction Stop
            }
            Push-Location "$($SiteCode):" -ErrorAction Stop
            try { Start-CMContentDistribution -PackageId $PkgId -DistributionPointName $DpFqdn -ErrorAction Stop; $o.Add("ADDED $DpFqdn") }
            finally { Pop-Location }
        }
        catch { $o.Add("ADD ERROR: " + $_.Exception.Message) }
        return $o.ToArray()
    }
    try {
        $t = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$PkgId'" -ErrorAction Stop)
        if ($t.Count -eq 0) { $o.Add('TARGET none') }
        foreach ($x in $t) {
            $f = & $fqdnOf $x.ServerNALPath
            if ($Mode -eq 'delete') { $x.Delete(); $o.Add("DELETED $f") } else { $o.Add("TARGET $f") }
        }
    }
    catch { $o.Add("WMI ERROR: " + $_.Exception.Message) }
    return $o.ToArray()
}

# Creates/removes a throwaway package on the child. SMSPackages_G rides the SAME replication group
# as PkgServers_G ('Configuration Data', global), so this exercises the exact article set and
# direction under investigation without touching DP targeting.
$cmPackageBlock = {
    param($SiteCode, $Mode, $NameOrId)
    $o = New-Object System.Collections.Generic.List[string]
    try {
        $ui = $env:SMS_ADMIN_UI_PATH
        if (-not $ui) { return @('CM ERROR: SMS_ADMIN_UI_PATH not set') }
        Import-Module (Join-Path (Split-Path $ui -Parent) 'ConfigurationManager.psd1') -ErrorAction Stop
        if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
            $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root "$env:COMPUTERNAME.$env:USERDNSDOMAIN" -ErrorAction Stop
        }
        Push-Location "$($SiteCode):" -ErrorAction Stop
        try {
            if ($Mode -eq 'create') {
                $p = New-CMPackage -Name $NameOrId -ErrorAction Stop
                $o.Add("CREATED PackageID=$($p.PackageID) Name=$NameOrId")
            }
            elseif ($Mode -eq 'delete') {
                Remove-CMPackage -Id $NameOrId -Force -ErrorAction Stop
                $o.Add("DELETED PackageID=$NameOrId")
            }
        }
        finally { Pop-Location }
    }
    catch { $o.Add("CM ERROR ($Mode): " + $_.Exception.Message) }
    return $o.ToArray()
}

function Get-GuestOutput {
    param($VmName, $DomainName, [scriptblock]$Block, [object[]]$ArgList, $Tag)
    # Invoke-VmCommand -AsJob bootstraps a job AND a session on every call (~1-2 min each), which
    # swamped a 20s poll into 7-15 min -- too coarse to time a transition that lasts minutes. Reuse
    # one session per VM and get the timeout from a job ON that session instead.
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $s = $script:watchSessions[$VmName]
        if (-not $s -or $s.State -ne 'Opened') {
            $s = Get-VmSession -VmName $VmName -VmDomainName $DomainName
            if (-not $s) { return @("ERROR: $Tag no session to $VmName") }
            $script:watchSessions[$VmName] = $s
        }
        $j = $null
        try {
            $j = Invoke-Command -Session $s -ScriptBlock $Block -ArgumentList $ArgList -AsJob -ErrorAction Stop
            if (Wait-Job -Job $j -Timeout 90) {
                $out = @(Receive-Job -Job $j -ErrorAction SilentlyContinue)
                Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
                # An empty result is legitimate for the log block; only the table block is required
                # to speak, and it always emits at least a NO ROWS line.
                return $out
            }
            Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
            return @("ERROR: $Tag timed out after 90s")
        }
        catch {
            if ($j) { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue }
            $script:watchSessions.Remove($VmName)
            if ($attempt -eq 2) { return @("ERROR: $Tag $($_.Exception.Message)") }
        }
    }
}

if ($DrsProbe) {
    $probeLog = Join-Path $logsRoot ("drs-probe-{0}.log" -f $stamp)
    $psay = {
        param($t)
        $l = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $t
        Write-Host $l -ForegroundColor Gray
        try { Add-Content -LiteralPath $probeLog -Value $l -Encoding utf8 -ErrorAction Stop } catch { }
    }
    if ($priList.Count -ne 1) { Write-Host "FATAL: -DrsProbe needs exactly one child primary. Use -PrimaryName." -ForegroundColor Red; return }
    $child = $priList[0]
    $childSql = Resolve-SqlVm -SiteVm $child -AllVms $allVms
    $casSql = Resolve-SqlVm -SiteVm $cas -AllVms $allVms

    # Does a given site's DB have this package yet? SMSPackages is the global article under test.
    $hasPkg = {
        param($SqlVm, $SiteCode, $PkgId)
        $l = @(Get-GuestOutput -VmName $SqlVm -DomainName $dom -Block $sqlSnapBlock -ArgList @($SiteCode, $PkgId) -Tag "rows-$SiteCode")
        $spoke = @($l | Where-Object { $_ -match '^SMSPackages' })
        return [pscustomobject]@{ Readable = ($spoke.Count -gt 0); Present = (@($spoke | Where-Object { $_ -match '^SMSPackages\[' }).Count -gt 0) }
    }

    & $psay "log -> $probeLog"
    & $psay "DRS PROBE  child=$($child.vmName)/$($child.siteCode)  cas=$($cas.vmName)/$($cas.siteCode)"
    & $psay "Creates a throwaway package at BOTH sites and times each direction. SMSPackages_G rides the same"
    & $psay "group as PkgServers_G ('Configuration Data', global), so this is the article set under investigation."
    & $psay "child->parent is the suspect direction (the missing row was SourceSite=$($child.siteCode)); parent->child is the CONTROL."

    $tag = Get-Date -Format 'yyyyMMdd-HHmmss'
    $created = @()
    try {
        foreach ($side in @(
                @{ Name = 'CHILD->CAS'; Vm = $child; Site = $child.siteCode; WatchSql = $casSql.vmName; WatchSite = $cas.siteCode },
                @{ Name = 'CAS->CHILD'; Vm = $cas; Site = $cas.siteCode; WatchSql = $childSql.vmName; WatchSite = $child.siteCode })) {

            $pkgName = "DRSPROBE-$($side.Site)-$tag"
            $res = @(Get-GuestOutput -VmName $side.Vm.vmName -DomainName $dom -Block $cmPackageBlock -ArgList @($side.Site, 'create', $pkgName) -Tag "create-$($side.Site)")
            foreach ($r in $res) { & $psay "    $r" }
            $id = ($res | Where-Object { $_ -match 'CREATED PackageID=(\S+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
            if (-not $id) { & $psay "$($side.Name): could not create the probe package. NOT A RESULT."; continue }
            $created += [pscustomobject]@{ Vm = $side.Vm; Site = $side.Site; Id = $id }

            $t0 = Get-Date
            $local = & $hasPkg $(if ($side.Name -eq 'CHILD->CAS') { $childSql.vmName } else { $casSql.vmName }) $side.Site $id
            & $psay "$($side.Name): created $id, present at origin=$($local.Present)"

            $arrived = $null
            while (((Get-Date) - $t0).TotalSeconds -lt $PostSeconds) {
                $far = & $hasPkg $side.WatchSql $side.WatchSite $id
                if (-not $far.Readable) { & $psay "    WARN: cannot read SMSPackages at $($side.WatchSql) -- instrument failure, not evidence"; break }
                if ($far.Present) { $arrived = Get-Date; break }
                Start-Sleep -Seconds 10
            }
            if ($arrived) { & $psay "*** $($side.Name): package $id visible after $([int]($arrived - $t0).TotalSeconds)s ***" }
            else { & $psay "$($side.Name): package $id NOT visible within ${PostSeconds}s." }
        }
    }
    finally {
        foreach ($c in $created) {
            foreach ($r in (Get-GuestOutput -VmName $c.Vm.vmName -DomainName $dom -Block $cmPackageBlock -ArgList @($c.Site, 'delete', $c.Id) -Tag "del-$($c.Id)")) { & $psay "    cleanup: $r" }
        }
    }

    & $psay "--- what DRS logged, child ---"
    foreach ($l in (Get-GuestOutput -VmName $childSql.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($child.siteCode) -Tag 'child-logs')) {
        if ($l -match 'Configuration Data|Not sending|No changes detected|Starting scan|LastVersionSent') { & $psay "    CHILD $l" }
    }
    Write-Host "Probe log: $probeLog" -ForegroundColor Green
    return
}

if ($ResetChildPackageState) {
    $resetLog = Join-Path $logsRoot ("reset-childpkg-{0}.log" -f $stamp)
    $rsay = {
        param($t)
        $l = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $t
        Write-Host $l -ForegroundColor Gray
        try { Add-Content -LiteralPath $resetLog -Value $l -Encoding utf8 -ErrorAction Stop } catch { }
    }
    if ($priList.Count -ne 1) {
        Write-Host "FATAL: -ResetChildPackageState needs exactly one child primary. Use -PrimaryName." -ForegroundColor Red
        return
    }
    $child = $priList[0]
    $childSql = Resolve-SqlVm -SiteVm $child -AllVms $allVms
    $casSql = Resolve-SqlVm -SiteVm $cas -AllVms $allVms
    if (-not $PackageId) {
        $cand = @(Get-GuestOutput -VmName $cas.vmName -DomainName $dom -Block $pkgFindBlock -ArgList @($cas.siteCode) -Tag 'find-clientpkg')
        $ids = @($cand | Where-Object { $_ -match '^[A-Z0-9]{8} ' })
        if ($ids.Count -ne 1) { Write-Host "FATAL: could not resolve the client package. Re-run with -PackageId." -ForegroundColor Red; return }
        $PackageId = $ids[0].Split(' ')[0]
    }

    $rows = {
        param($Tag, $VmName, $SiteCode)
        $l = @(Get-GuestOutput -VmName $VmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($SiteCode, $PackageId) -Tag $Tag)
        foreach ($x in $l) { if ($x -match '^Pkg|^SMSPackages') { & $rsay "    $Tag $x" } }
        return $l
    }
    $childHasFor = { param($Lines, $Site) return (@($Lines | Where-Object { $_ -match '^PkgServers_[GL]\[' -and $_ -match "SiteCode=$Site(\s|$)" }).Count -gt 0) }

    & $rsay "log -> $resetLog"
    & $rsay "RESET  pkg=$PackageId  child=$($child.vmName)/$($child.siteCode)  cas=$($cas.vmName)/$($cas.siteCode)"
    & $rsay "This WRITES to the lab: it deletes the child's DP targeting, clears PkgServers/PkgStatus rows for $($child.siteCode) on both sides, zeroes StoredPkgVersion, then re-adds the targeting to restart the wait."

    $tgt = @(Get-GuestOutput -VmName $child.vmName -DomainName $dom -Block $dpTargetingBlock -ArgList @($child.siteCode, $PackageId, 'list', $null) -Tag 'tgt-list')
    foreach ($x in $tgt) { & $rsay "    CHILD $x" }
    $dpFqdns = @($tgt | Where-Object { $_ -match '^TARGET \S' } | ForEach-Object { ($_ -split ' ', 2)[1] })
    if ($dpFqdns.Count -eq 0) { & $rsay "ABORT: no DP targeting found on the child, so there is nothing to reset and re-add."; return }

    & $rsay "--- before ---"
    $null = & $rows 'CHILD' $childSql.vmName $child.siteCode
    $null = & $rows 'CAS  ' $casSql.vmName $cas.siteCode

    foreach ($x in (Get-GuestOutput -VmName $child.vmName -DomainName $dom -Block $dpTargetingBlock -ArgList @($child.siteCode, $PackageId, 'delete', $null) -Tag 'tgt-del')) { & $rsay "    CHILD $x" }

    $childSite = $child.siteCode
    $execs = @(
        @{ Vm = $childSql.vmName; Site = $child.siteCode; Sql = "DELETE FROM PkgServers_G WHERE PkgID = @p AND SiteCode = @s" },
        @{ Vm = $childSql.vmName; Site = $child.siteCode; Sql = "DELETE FROM PkgServers_L WHERE PkgID = @p AND SiteCode = @s" },
        @{ Vm = $childSql.vmName; Site = $child.siteCode; Sql = "DELETE FROM PkgStatus_G WHERE ID = @p AND SiteCode = @s" },
        @{ Vm = $childSql.vmName; Site = $child.siteCode; Sql = "UPDATE SMSPackages_L SET StoredPkgVersion = 0 WHERE PkgID = @p" },
        @{ Vm = $casSql.vmName; Site = $cas.siteCode; Sql = "DELETE FROM PkgServers_G WHERE PkgID = @p AND SiteCode = @s" },
        @{ Vm = $casSql.vmName; Site = $cas.siteCode; Sql = "DELETE FROM PkgServers_L WHERE PkgID = @p AND SiteCode = @s" },
        @{ Vm = $casSql.vmName; Site = $cas.siteCode; Sql = "DELETE FROM PkgStatus_G WHERE ID = @p AND SiteCode = @s" }
    )
    foreach ($e in $execs) {
        foreach ($l in (Get-GuestOutput -VmName $e.Vm -DomainName $dom -Block $sqlSnapBlock -ArgList @($e.Site, $PackageId, $null, $e.Sql, $childSite) -Tag 'exec')) { & $rsay "    $($e.Vm) $l" }
    }

    & $rsay "--- after clearing (both sides must show no $childSite row) ---"
    $childAfter = & $rows 'CHILD' $childSql.vmName $child.siteCode
    $casAfter = & $rows 'CAS  ' $casSql.vmName $cas.siteCode
    $stillChild = & $childHasFor $childAfter $childSite
    $stillCas = & $childHasFor $casAfter $childSite
    if ($stillChild -or $stillCas) {
        & $rsay "ABORT: rows for $childSite survived the clear (child=$stillChild cas=$stillCas). NOT reset -- do not measure this."
        return
    }

    $tReAdd = Get-Date
    foreach ($f in $dpFqdns) {
        foreach ($x in (Get-GuestOutput -VmName $child.vmName -DomainName $dom -Block $dpTargetingBlock -ArgList @($child.siteCode, $PackageId, 'add', $f) -Tag 'tgt-add')) { & $rsay "    CHILD $x" }
    }
    & $rsay "--- after re-add (clock starts $($tReAdd.ToString('HH:mm:ss'))) ---"
    $null = & $rows 'CHILD' $childSql.vmName $child.siteCode
    $null = & $rows 'CAS  ' $casSql.vmName $cas.siteCode
    if (-not $FlushExperiment) {
        & $rsay "RESET COMPLETE. Now run, in two windows:"
        & $rsay "  .\Get-DrsLogs.ps1 -PrimaryName $($child.vmName) -WatchSendChain -PackageId $PackageId"
        & $rsay "  .\Get-DrsLogs.ps1 -PrimaryName $($child.vmName) -FlushExperiment -PackageId $PackageId -ArmWaitMinutes 60"
        Write-Host "Reset log: $resetLog" -ForegroundColor Green
        return
    }
    # The window opens the instant the re-add lands, so hand straight over rather than making a
    # human start the experiment inside it -- that hand-off is what was missed on the last run.
    & $rsay "RESET COMPLETE -- continuing into the flush experiment while the window is open."
}

if ($FlushExperiment) {
    $expLog = Join-Path $logsRoot ("flush-experiment-{0}.log" -f $stamp)
    $esay = {
        param($t)
        $l = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $t
        Write-Host $l -ForegroundColor Gray
        try { Add-Content -LiteralPath $expLog -Value $l -Encoding utf8 -ErrorAction Stop } catch { }
    }
    if ($priList.Count -ne 1) {
        Write-Host "FATAL: -FlushExperiment needs exactly one child primary. Use -PrimaryName. Got: $($priList.vmName -join ', ')" -ForegroundColor Red
        return
    }
    $child = $priList[0]
    $childSql = Resolve-SqlVm -SiteVm $child -AllVms $allVms
    $casSql = Resolve-SqlVm -SiteVm $cas -AllVms $allVms

    if (-not $PackageId) {
        $cand = @(Get-GuestOutput -VmName $cas.vmName -DomainName $dom -Block $pkgFindBlock -ArgList @($cas.siteCode) -Tag 'find-clientpkg')
        $ids = @($cand | Where-Object { $_ -match '^[A-Z0-9]{8} ' })
        if ($ids.Count -ne 1) { Write-Host "FATAL: could not resolve the client package. Re-run with -PackageId." -ForegroundColor Red; return }
        $PackageId = $ids[0].Split(' ')[0]
    }

    # Reads the CAS's own PkgServers_G and answers one question: is the child's row there yet.
    # Returns every line, because "the query failed" and "there is no row" must not look alike.
    function Test-CasHasChildRow {
        $lines = @(Get-GuestOutput -VmName $casSql.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($cas.siteCode, $PackageId) -Tag 'cas-rows')
        $spoke = @($lines | Where-Object { $_ -match '^PkgServers_G' })
        $hit = @($spoke | Where-Object { $_ -match '^PkgServers_G\[' -and $_ -match "SiteCode=$($child.siteCode)(\s|$)" })
        return [pscustomobject]@{ Readable = ($spoke.Count -gt 0); Present = ($hit.Count -gt 0); Lines = $lines }
    }

    & $esay "log -> $expLog"
    & $esay "FLUSH EXPERIMENT  pkg=$PackageId  child=$($child.vmName)/$($child.siteCode) (sql $($childSql.vmName))  cas=$($cas.vmName)/$($cas.siteCode) (sql $($casSql.vmName))"
    & $esay "pre-registered: baseline ${BaselineSeconds}s with NO intervention, then flush 'Configuration Data' on the CHILD, then watch ${PostSeconds}s."
    $armStartExp = Get-Date

    # The window this experiment needs -- child has its row, CAS does not -- opens and closes on its
    # own. Run by hand and you will almost always arrive after it shut, so -ArmWaitMinutes waits for it.
    if ($ArmWaitMinutes -gt 0) {
        $expArmDeadline = (Get-Date).AddMinutes($ArmWaitMinutes)
        $armCycles = 0
        while ((Get-Date) -lt $expArmDeadline) {
            $childRows = @(Get-GuestOutput -VmName $childSql.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($child.siteCode, $PackageId) -Tag 'child-rows')
            $childSpoke = @($childRows | Where-Object { $_ -match '^PkgServers_G' })
            $childHas = @($childSpoke | Where-Object { $_ -match '^PkgServers_G\[' -and $_ -match "SiteCode=$($child.siteCode)(\s|$)" }).Count -gt 0
            $casState = Test-CasHasChildRow
            if ($childSpoke.Count -eq 0 -or -not $casState.Readable) {
                & $esay "arming: could not read PkgServers_G (child readable=$($childSpoke.Count -gt 0), CAS readable=$($casState.Readable)); retrying"
            }
            elseif ($childHas -and $casState.Present) {
                & $esay "WINDOW MISSED: the child's row is already at the CAS, so the pending state this experiment needs is over. Start it earlier next run. NOT A RESULT."
                return
            }
            elseif ($childHas) { & $esay "armed: child has its row and the CAS does not."; break }
            $armCycles++
            if ($armCycles % 10 -eq 0) { & $esay "  arming +$([int]((Get-Date) - $armStartExp).TotalMinutes)m: child has not written its PkgServers_G row yet" }
            Start-Sleep -Seconds 30
        }
        if ((Get-Date) -ge $expArmDeadline) { & $esay "NOT ARMED within ${ArmWaitMinutes}m. NOT A RESULT."; return }
    }

    $childRows = @(Get-GuestOutput -VmName $childSql.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($child.siteCode, $PackageId) -Tag 'child-rows')
    $childSpoke = @($childRows | Where-Object { $_ -match '^PkgServers_G' })
    $childHas = @($childSpoke | Where-Object { $_ -match '^PkgServers_G\[' -and $_ -match "SiteCode=$($child.siteCode)(\s|$)" }).Count -gt 0
    $casState = Test-CasHasChildRow
    foreach ($r in $childRows) { & $esay "    CHILD $r" }
    foreach ($r in $casState.Lines) { & $esay "    CAS   $r" }
    & $esay "precondition: child readable=$($childSpoke.Count -gt 0) hasOwnRow=$childHas ; CAS readable=$($casState.Readable) hasChildRow=$($casState.Present)"
    if ($childSpoke.Count -eq 0 -or -not $casState.Readable) {
        & $esay "ABORT: could not READ PkgServers_G on $(if ($childSpoke.Count -eq 0) { $childSql.vmName } else { $casSql.vmName }). That is an instrument failure, NOT evidence about the row. See the lines above."
        return
    }
    if (-not $childHas) { & $esay "ABORT: the child's database is readable and genuinely has no PkgServers_G row of its own yet. Nothing to flush. NOT A RESULT."; return }
    if ($casState.Present) { & $esay "ABORT: the CAS already has the child's row, so there is no pending replication to accelerate. NOT A RESULT."; return }

    $tBase = Get-Date
    $arrivedInBaseline = $false
    while (((Get-Date) - $tBase).TotalSeconds -lt $BaselineSeconds) {
        Start-Sleep -Seconds 15
        if ((Test-CasHasChildRow).Present) { $arrivedInBaseline = $true; break }
    }
    if ($arrivedInBaseline) {
        & $esay "ROW ARRIVED DURING BASELINE after $([int]((Get-Date) - $tBase).TotalSeconds)s, with no intervention."
        & $esay "THE FLUSH WAS NOT TESTED. Do not read this as the flush working, and do not read it as the lag being short -- it only means this trial started too late."
        return
    }
    & $esay "baseline done: ${BaselineSeconds}s with no arrival and no intervention."

    $tFlush = Get-Date
    foreach ($l in (Get-GuestOutput -VmName $childSql.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($child.siteCode, $null, 'Configuration Data') -Tag 'child-flush')) { & $esay "    $l" }
    & $esay "flushed at $($tFlush.ToString('HH:mm:ss')); watching the CAS every 15s for up to ${PostSeconds}s"

    $tArrive = $null
    while (((Get-Date) - $tFlush).TotalSeconds -lt $PostSeconds) {
        Start-Sleep -Seconds 15
        if ((Test-CasHasChildRow).Present) { $tArrive = Get-Date; break }
    }
    if (-not $tArrive) {
        & $esay "RESULT: no arrival at the CAS within ${PostSeconds}s of a flush of the correct group."
        & $esay "That is evidence the flush cannot move this row, and the delay is NOT on the child's send side."
        return
    }
    $dFlush = [int]($tArrive - $tFlush).TotalSeconds
    & $esay "RESULT: row visible at the CAS ${dFlush}s after the flush (baseline had ${BaselineSeconds}s with nothing)."
    foreach ($r in (Test-CasHasChildRow).Lines) { & $esay "    CAS   $r" }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $tSendDeadline = $tArrive.AddSeconds(600)
    $sent = $false
    while ((Get-Date) -lt $tSendDeadline -and -not $sent) {
        foreach ($l in (Get-GuestOutput -VmName $cas.vmName -DomainName $dom -Block $pkgLogBlock -ArgList @($PackageId) -Tag 'cas-log')) {
            if ($seen.Add("$l")) { & $esay "    CAS $l" }
            if ($l -match 'Needs to send|Created minijob|distribution point has been changed') { $sent = $true }
        }
        if (-not $sent) { Start-Sleep -Seconds 15 }
    }
    if ($sent) { & $esay "RESULT: send started $([int]((Get-Date) - $tArrive).TotalSeconds)s after the row became visible at the CAS." }
    else { & $esay "RESULT: row reached the CAS but NO send within 600s -- arrival of the row is therefore NOT sufficient on its own." }
    & $esay "ONE TRIAL. It separates 'a flush cannot move this row' from '8527f678 ran at the wrong moment'. It does not establish a fix."
    Write-Host "Experiment log: $expLog" -ForegroundColor Green
    return
}

if ($WatchSendChain) {
    $watchLog = Join-Path $logsRoot ("send-chain-watch-{0}.log" -f $stamp)
    $say = {
        param($t)
        $l = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $t
        Write-Host $l -ForegroundColor Gray
        try { Add-Content -LiteralPath $watchLog -Value $l -Encoding utf8 -ErrorAction Stop } catch { }
    }

    if ($ArmWaitMinutes -gt 0) {
        $armStart = Get-Date
        $armDeadline = $armStart.AddMinutes($ArmWaitMinutes)
        $needArm = @($cas) + $priList
        $armed = @{}
        $answered = @{}
        $armCycle = 0
        & $say "arming: waiting up to ${ArmWaitMinutes}m for ConfigMgr on $($needArm.vmName -join ', ')"
        while ($armed.Count -lt $needArm.Count -and (Get-Date) -lt $armDeadline) {
            $armCycle++
            foreach ($v in $needArm) {
                if ($armed.ContainsKey($v.vmName)) { continue }
                $r = @(Get-GuestOutput -VmName $v.vmName -DomainName $dom -Block $cmReadyBlock -ArgList @($v.siteCode) -Tag "arm-$($v.siteCode)")
                if ($r -contains 'CMREADY') { $armed[$v.vmName] = $true; & $say "  armed: $($v.vmName) (site $($v.siteCode))"; continue }
                if ($r -match '^CMWAIT') { $answered[$v.vmName] = $true }
            }
            # Silence while arming is indistinguishable from progress, and a VM that is in the domain
            # but not in this build never answers at all -- so say which is which, out loud.
            if ($armed.Count -lt $needArm.Count -and $armCycle % 5 -eq 0) {
                $outstanding = @()
                foreach ($v in $needArm) {
                    if ($armed.ContainsKey($v.vmName)) { continue }
                    $outstanding += if ($answered.ContainsKey($v.vmName)) { "$($v.vmName)=building" } else { "$($v.vmName)=NEVER-ANSWERED" }
                }
                & $say "  arming +$([int]((Get-Date) - $armStart).TotalMinutes)m: $($outstanding -join '  ')"
                if ($outstanding -match 'NEVER-ANSWERED') {
                    & $say "  ^ that VM is probably not part of this build. Restart with -PrimaryName <vm> to scope the watch, or it will block arming for the full ${ArmWaitMinutes}m."
                }
            }
            if ($armed.Count -lt $needArm.Count) { Start-Sleep -Seconds 60 }
        }
        if ($armed.Count -lt $needArm.Count) {
            $missing = @($needArm | Where-Object { -not $armed.ContainsKey($_.vmName) } | Select-Object -ExpandProperty vmName)
            & $say "NOT ARMED within ${ArmWaitMinutes}m: $($missing -join ', ') never reached ConfigMgr. Nothing was watched."
            return
        }
    }

    if (-not $PackageId) {
        $cand = @(Get-GuestOutput -VmName $cas.vmName -DomainName $dom -Block $pkgFindBlock -ArgList @($cas.siteCode) -Tag 'find-clientpkg')
        $ids = @($cand | Where-Object { $_ -match '^[A-Z0-9]{8} ' })
        if ($ids.Count -ne 1) {
            Write-Host "FATAL: could not resolve the client package on $($cas.vmName) (site $($cas.siteCode))." -ForegroundColor Red
            $cand | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
            Write-Host "Re-run with -PackageId <id>, or with -ArmWaitMinutes if ConfigMgr is not installed yet." -ForegroundColor Red
            return
        }
        $PackageId = $ids[0].Split(' ')[0]
    }

    $watchSites = @()
    $watchSites += [pscustomobject]@{ Tag = 'CAS '; Vm = $cas; SqlVm = (Resolve-SqlVm -SiteVm $cas -AllVms $allVms); SiteCode = $cas.siteCode; IsChild = $false }
    foreach ($p in $priList) {
        $watchSites += [pscustomobject]@{ Tag = $p.siteCode.PadRight(4); Vm = $p; SqlVm = (Resolve-SqlVm -SiteVm $p -AllVms $allVms); SiteCode = $p.siteCode; IsChild = $true }
    }

    & $say "log -> $watchLog"
    & $say "send-chain watch: pkg=$PackageId every=${IntervalSeconds}s max=${MaxMinutes}m"
    foreach ($w in $watchSites) { & $say "  $($w.Tag) site=$($w.SiteCode) server=$($w.Vm.vmName) sql=$($w.SqlVm.vmName)" }

    $seenLog = New-Object 'System.Collections.Generic.HashSet[string]'
    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($w in $watchSites) { if ($w.IsChild) { $pending.Add($w.SiteCode) } }
    $prev = ''
    $firstPoll = $true
    $measured = 0
    $t0 = Get-Date
    $deadline = $t0.AddMinutes($MaxMinutes)

    while ((Get-Date) -lt $deadline -and $pending.Count -gt 0) {
        $lines = @()
        foreach ($w in $watchSites) {
            foreach ($l in (Get-GuestOutput -VmName $w.SqlVm.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($w.SiteCode, $PackageId) -Tag "tables-$($w.SiteCode)")) {
                $lines += "$($w.Tag) $l"
            }
        }
        $arrived = @()
        foreach ($w in $watchSites) {
            if (-not $w.IsChild) { continue }
            foreach ($l in (Get-GuestOutput -VmName $w.Vm.vmName -DomainName $dom -Block $pkgWmiBlock -ArgList @($PackageId, $w.SiteCode) -Tag "wmi-$($w.SiteCode)")) {
                $lines += "$($w.Tag) $l"
                if ($l -match 'StoredPkgVersion=[1-9]') { $arrived += $w.SiteCode }
            }
        }

        # Change-only logging: a signature that includes anything time-varying (a poll counter, a
        # timestamp) defeats the whole point and prints every cycle.
        $sig = ($lines -join '|')
        if ($sig -ne $prev) {
            & $say "CHANGE (+$([int]((Get-Date) - $t0).TotalSeconds)s)"
            foreach ($l in $lines) { & $say "    $l" }
            $prev = $sig
        }

        foreach ($w in $watchSites) {
            foreach ($l in (Get-GuestOutput -VmName $w.Vm.vmName -DomainName $dom -Block $pkgLogBlock -ArgList @($PackageId) -Tag "logs-$($w.SiteCode)")) {
                if ($seenLog.Add("$($w.Tag)$l")) { & $say "    $($w.Tag) $l" }
            }
        }

        # A package that was already there when the watch started is not an arrival. Reporting it as
        # one turns "this run measured nothing" into something that reads like a successful capture.
        foreach ($s in $arrived) {
            if (-not $pending.Contains($s)) { continue }
            [void]$pending.Remove($s)
            if ($firstPoll) { & $say "$s ALREADY had the package when the watch started -- nothing to measure there." }
            else {
                $measured++
                & $say "*** $s CONTENT ARRIVED after $([int]((Get-Date) - $t0).TotalSeconds)s ***"
            }
        }
        $firstPoll = $false
        if ($pending.Count -gt 0) { Start-Sleep -Seconds $IntervalSeconds }
    }

    if ($pending.Count -gt 0) {
        & $say "NOT CAPTURED: no arrival at $($pending -join ', ') within $MaxMinutes min -- this file does not explain the transition."
    }
    elseif ($measured -eq 0) {
        & $say "NOTHING MEASURED: every child already had the package before the watch started. Needs a primary that has not run Phase 8."
    }
    Write-Host "Watch log: $watchLog" -ForegroundColor Green
    return
}

foreach ($vm in $logTargets) {
    Write-Host "==== $($vm.vmName) (role $($vm.role), site $($vm.siteCode)) ====" -ForegroundColor Yellow
    $dest = Join-Path $destRoot $vm.vmName
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    $session = Get-VmSession -VmName $vm.vmName -VmDomainName $dom
    if (-not $session) { Write-Host "  could not open a session (is it running?) - skipping" -ForegroundColor Red; continue }

    $info = Invoke-Command -Session $session -ScriptBlock $logCollectBlock -ArgumentList (, $logNames)
    Write-Host "  log dir: $($info.LogDir)" -ForegroundColor DarkGray
    foreach ($f in $info.Files) {
        try { Copy-Item -FromSession $session -Path $f -Destination $dest -Force; Write-Host "  pulled $(Split-Path $f -Leaf)" -ForegroundColor Gray }
        catch { Write-Host "  FAILED $(Split-Path $f -Leaf): $($_.Exception.Message)" -ForegroundColor Red }
    }

    # Also drop a flat, clearly-named copy of rcmctrl.log (and its rotated .lo_) straight into the main logs\
    # folder, next to the build's InstallCMLog / ConfigMgrSetup tail, so it's easy to find and syncs across
    # checkouts. Only the site servers (CAS/Primary) run RCM, so only flat-copy for them.
    if ($vm.role -in @('CAS', 'Primary')) {
        foreach ($rn in @('rcmctrl.log', 'rcmctrl.lo_')) {
            $localRcm = Join-Path $dest $rn
            if (Test-Path $localRcm) {
                $suffix = if ($rn -eq 'rcmctrl.lo_') { 'rcmctrl-prev.log' } else { 'rcmctrl.log' }
                $flat = Join-Path $logsRoot ("{0}-{1}-{2}" -f $vm.vmName, $stamp, $suffix)
                try { Copy-Item -Path $localRcm -Destination $flat -Force; Write-Host "  flat copy -> $(Split-Path $flat -Leaf)" -ForegroundColor Gray }
                catch { Write-Host "  flat copy FAILED ($rn): $($_.Exception.Message)" -ForegroundColor Red }
            }
        }
    }

    if ($TailLines -gt 0 -and -not [string]::IsNullOrWhiteSpace($info.LogDir)) {
        $tail = Invoke-Command -Session $session -ScriptBlock { param($d, $n) $f = Join-Path $d 'rcmctrl.log'; if (Test-Path $f) { Get-Content $f -Tail $n } else { @('(no rcmctrl.log)') } } -ArgumentList $info.LogDir, $TailLines
        Write-Host "  --- rcmctrl tail ($TailLines) ---" -ForegroundColor DarkGray
        $tail | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    elseif ($TailLines -gt 0) {
        Write-Host "  (no CM log dir on this VM - skipping rcmctrl tail; site systems like MP/DP don't run RCM)" -ForegroundColor DarkGray
    }

    # SQL snapshot from this site's SQL host
    if ($vm.role -in @('CAS', 'Primary')) {
        $sqlVm = Resolve-SqlVm -SiteVm $vm -AllVms $allVms
        $sqlSession = if ($sqlVm.vmName -eq $vm.vmName) { $session } else { Get-VmSession -VmName $sqlVm.vmName -VmDomainName $dom }
        if ($sqlSession) {
            Write-Host "  SQL snapshot from $($sqlVm.vmName)..." -ForegroundColor DarkGray
            $snap = Invoke-Command -Session $sqlSession -ScriptBlock $sqlSnapBlock -ArgumentList $vm.siteCode
            $snapPath = Join-Path $dest "replication-state-$stamp.txt"
            Set-Content -Path $snapPath -Value $snap -Encoding utf8
            Write-Host "  wrote $(Split-Path $snapPath -Leaf)" -ForegroundColor Gray
            # Flat copy of the snapshot into the main logs\ folder too.
            $flatSnap = Join-Path $logsRoot ("{0}-replication-state-{1}.txt" -f $vm.vmName, $stamp)
            try { Copy-Item -Path $snapPath -Destination $flatSnap -Force } catch {}
        }
        else { Write-Host "  could not open SQL session to $($sqlVm.vmName)" -ForegroundColor Red }
    }
    Write-Host ""
}

Write-Host "Done. Logs under: $destRoot" -ForegroundColor Green
