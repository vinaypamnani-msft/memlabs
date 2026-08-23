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
            ~4698  target join    : PkgServers INNER JOIN DistributionPoints ON NALPath; a missing DP row
                                                            silently removes the child site before the send decision is evaluated
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

.PARAMETER SecondaryContentHop
    The OTHER hop. -WatchSendChain follows CAS -> child primary; this follows child primary ->
    SECONDARY, which is where burnin's client package stalls (HUB00004 = ContentValidating on
    BI-SECONDARY, site SEC, while the three DPs under the primary are Installed).

    Reads three independent witnesses, because each one alone has already been wrong here:
      summarizer  SMS_PackageStatusDistPointsSummarizer State per DP -- deliberately the SAME
                  oracle Phase 11 fails on, so "fixed" here means that check would now pass.
      database    PkgServers_G / PkgStatus_G for the secondary's site code. Per the send-chain
                  notes above, distmgr logs NOTHING when it declines to send, so the database is
                  the only witness and absence of a log line proves nothing.
      physical    the secondary's own SCCMContentLib\PkgLib, and the depth of despoolr.box\receive.
                  A DP parked at ContentValidating with the package absent from PkgLib never
                  received content at all -- that state is a phantom initial row, not progress.

.PARAMETER RepairSecondaryContent
    INTERVENES on the lab. Sets RefreshNow on the parent primary's SMS_DistributionPoint row for
    the package + secondary DP, i.e. asks the parent to re-send. Pre-registered like
    -FlushExperiment so the result cannot be rationalised afterwards:
      precondition  the secondary DP is readable AND not already Installed. Otherwise abort.
      baseline      watch -BaselineSeconds with NO intervention; if it clears on its own the
                    repair was NOT tested and the run says so.
      intervention  RefreshNow on the parent primary's row.
      measure       poll the summarizer for up to -PostSeconds for State=0 (Installed).
    ONE TRIAL. phase8-clientpkg-coverage-secondary-inactive.md already found that RefreshNow acts
    on the PARENT's targeting rows and does not drive the send-to-child path, so a negative result
    here is the expected one and is worth recording; a positive one is the rung worth shipping.
.PARAMETER PostSeconds      How long to watch after the flush (default 900).

.PARAMETER ProveWedgeFix
    INTERVENES on the lab. Tests END TO END the one thing the distmgr-wedge work never established:
    that restarting SMS_EXECUTIVE actually CURES the wedge. InstallBoundaryGroups.ps1 calls that
    restart "the proven cure"; the historical logs do not show it. The 4.5h after the only real
    firing (08-21 10:54:57) contains ~77 distmgr lines, all clustered at 15:24-15:26, so that
    window is absence of evidence, not evidence of a cure.

    The wedge itself IS established: m_bShutdownRequest is a static set at distmgr.cpp:8190 when
    the process thread exits, passed as the cancel flag to CreatePackageBundle / SnapshotPackage /
    TakeContentSnapshot, and cleared only by the CDistributionManager constructor -- so only a
    FRESH PROCESS clears it. The guest log shows the recycle path verbatim:
      SMS_EXECUTIVE started SMS_DISTRIBUTION_MANAGER as thread ID 6784
      SMS_EXECUTIVE signalled SMS_DISTRIBUTION_MANAGER to stop.
    Same PID, new thread, flag survives.

    Pre-registered so the result cannot be rationalised afterwards:
      precondition  the parent primary reads WEDGED on the SAME predicate InstallBoundaryGroups.ps1
                    ships (>=5 content aborts and no real send since the last one). Otherwise abort
                    -- there is nothing to test.
      baseline      watch -BaselineSeconds with NO intervention. A send or an Installed DP during
                    this means THE RESTART WAS NOT TESTED, and the run says exactly that.
      intervention  Restart-Service SMS_EXECUTIVE on the parent.
      instrument    the PID must CHANGE. The whole mechanism claim is "only a fresh process clears
                    it", so an unchanged PID makes the trial void rather than negative.
      measure       new aborts, any real send, the stranded package's own send, the secondary's
                    PkgLib, and the summarizer state.
      stimulus      a PASSIVE watch cannot decide this, and the first run proved it. burnin
                    2026-08-23 returned INCONCLUSIVE with lastSend=-1 BEFORE and AFTER -- the
                    success signal has never fired on that site (0 'Created minijob' in the whole
                    3987-line log), so its absence carried no information. The stranding is
                    self-perpetuating: IsPkgSendingNeeded declines, nothing else needs sending, no
                    bundle is ever attempted, and the cancel flag is never exercised. So when the
                    passive window yields nothing, RefreshPkgSource bumps SourceVersion to FORCE a
                    bundle attempt. That discriminates either way -- still wedged emits a NEW
                    0x800704d3, cured emits a send. -StimulusSeconds bounds the second watch. The
                    stimulus is VOID only if the CALL could not be issued: SourceVersion is
                    READ-ONLY and server-maintained, so gating on it is circular -- distmgr moves
                    that column and distmgr is what is under test. Gating on it produced a VOID on
                    2026-08-23 ("changed=False") that decided nothing.

    Runtime: every watch returns the moment an outcome is decisive -- a send, this package's send,
    or a NEW abort all end it, not just an Installed DP. The first run burned 908s after the
    restart to reach a conclusion its first minute already contained. -PassiveSeconds (default 180)
    is deliberately short because that phase only answers "did the restart alone resume queued
    work", which distmgr does within seconds; with nothing queued, waiting longer cannot help.
    Typical run is now a few minutes; the ceiling is BaselineSeconds + PassiveSeconds +
    StimulusSeconds.

    Four distinguishable outcomes, and each points at a different script:
      CURED + package moved   -> the gate in InstallBoundaryGroups.ps1 is right and sufficient.
      CURED, package stranded -> the wedge fix works but distmgr.cpp:17252 never re-armed THIS
                                 send, so the package needs its source version moved. Separate fix.
      NOT CURED               -> the restart is NOT the cure. Do not widen the gate; 060c30cb makes
                                 memlabs restart SMS_EXECUTIVE more often for no benefit and should
                                 be reconsidered.
      VOID                    -> instrument failure, decides nothing.
.PARAMETER IntervalSeconds  Poll interval for -WatchSendChain (default 20).
.PARAMETER MaxMinutes   Give up after this long under -WatchSendChain (default 120). Counts from ARMING, not from launch: arming lands at child site install, and the rest of Phase 8 still has to run before the coverage wait, whose own worst case is 2622s.
.PARAMETER ArmWaitMinutes
    Let -WatchSendChain be started at ANY phase. It polls once a minute until ConfigMgr answers on the
    CAS and on every child primary, then resolves the package and begins the real watch. 0 (default)
    means everything must already be installed, i.e. you are starting during Phase 8.
    Use this to start the watch in Phase 2 and walk away -- the transition being chased is a single
    unlogged decision, so being late to it costs the whole run.

.PARAMETER EnableDrsTracing
    CHANGES SITE CONFIGURATION on the CAS and every child primary. Turns on the DRS diagnostics that
    are OFF by default and whose absence is why DrsSendHistory/DRSSentMessages have been empty:

      DRS Replication Group Message Logging = 'Configuration Data'  -> populates vDRSSentMessages /
        vDRSReceivedMessages with the per-operation XML (@TableName, @Type), which is the only way to
        see WHICH rows a sync actually carried. Off by default for every group.
      DRS Logging Level = 2, Verbose Logging = 2                    -> verbose vLogs / rcmctrl.
      Tracing DebugLogging = 1, LoggingLevel = 0, MaxFileSize = 50MB.
      fnIsDebugLoggingEnabled() -> RETURN 1 (ALTER, so there is no window where the function is
        missing; the shipped body is 'RETURN 0', verified in Core/Functions/fnIsDebugLoggingEnabled.sql).

    The prior value AND whether each value existed at all is captured to C:\Windows\Temp on each VM, so
    -DisableDrsTracing restores exactly what was there and REMOVES values that it created, rather than
    writing documented defaults over settings the site may not have had.

    Run this BEFORE the build whose replication you want to explain. Verbose DRS logging can fill a
    disk, so turn it back off afterwards.

.PARAMETER DisableDrsTracing
    Reverses -EnableDrsTracing from the captured prior state. If the capture file is missing it falls
    back to the documented defaults and says so, rather than silently claiming a clean restore.

.EXAMPLE
    cd C:\memlabs\vmbuild\tools ; .\Get-DrsLogs.ps1
.EXAMPLE
    .\Get-DrsLogs.ps1 -Domain cstest8.com
.EXAMPLE
    .\Get-DrsLogs.ps1 -WatchSendChain
.EXAMPLE
    # start during Phase 2 of an add-child-primary run and let it arm itself
    .\Get-DrsLogs.ps1 -WatchSendChain -ArmWaitMinutes 300
.EXAMPLE
    # measure only -- reads the three witnesses and writes logs\secondary-content-hop-<stamp>.log
    .\Get-DrsLogs.ps1 -SecondaryContentHop -Domain burnin.sandwich.lab
.EXAMPLE
    # measure, then intervene if the precondition holds
    .\Get-DrsLogs.ps1 -RepairSecondaryContent -Domain burnin.sandwich.lab -BaselineSeconds 120
.EXAMPLE
    # end-to-end proof that the SMS_EXECUTIVE restart cures a wedged distmgr
    .\Get-DrsLogs.ps1 -ProveWedgeFix -Domain burnin.sandwich.lab
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
    [int]$ExpectPrimaries = 0,
    [switch]$FlushExperiment,
    [switch]$ResetChildPackageState,
    [switch]$SecondaryContentHop,
    [switch]$RepairSecondaryContent,
    [switch]$ProveWedgeFix,
    [int]$StimulusSeconds = 600,
    [int]$PassiveSeconds = 180,
    [switch]$DrsProbe,
    [switch]$EnableDrsTracing,
    [switch]$DisableDrsTracing,
    [int]$SettleSeconds = 120,
    [int]$StallSnapshotEverySeconds = 300,
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

# SMSProv.log records every provider Put/method call with its caller, which is the only log that
# names WHO wrote a PkgServers row -- the one thing the 2026-08-14 cstest2 analysis could not
# establish from DRS capture alone.
# sched.log is the gap between distmgr deciding to send and sender transmitting: it is where the
# site-to-site send request is created, so a package absent from it never became a job at all.
# PkgXferMgr.log is the site-server -> remote-DP transfer, i.e. the hop after the content arrives.
$logNames = @('rcmctrl.log', 'rcmctrl.lo_', 'smsexec.log', 'hman.log', 'sender.log', 'despool.log', 'despoolr.log', 'replmgr.log', 'dataldr.log', 'ConfigMgrSetup.log', 'SMSProv.log', 'SMSProv.lo_', 'distmgr.log', 'distmgr.lo_', 'sched.log', 'sched.lo_', 'PkgXferMgr.log', 'PkgXferMgr.lo_')

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
# Secondaries are the second content hop and were never resolved here, so despool.log on the one
# machine a Primary->Secondary stall is about was the one log this tool did not collect.
$secList = @($allVms | Where-Object { $_.role -eq 'Secondary' -and $_.domain -eq $dom -and $_.parentSiteCode -in @($priList | Select-Object -ExpandProperty siteCode) })

$logTargets = @($cas) + $priList + $secList + $siteSystems | Sort-Object vmName -Unique
Write-Host "Domain  : $dom" -ForegroundColor Gray
Write-Host "CAS     : $($cas.vmName) (site $($cas.siteCode))  SQL: $((Resolve-SqlVm $cas $allVms).vmName)" -ForegroundColor Gray
foreach ($p in $priList) { Write-Host "Primary : $($p.vmName) (site $($p.siteCode))  SQL: $((Resolve-SqlVm $p $allVms).vmName)" -ForegroundColor Gray }
foreach ($s in $secList) { Write-Host "Secondary: $($s.vmName) (site $($s.siteCode), parent $($s.parentSiteCode))" -ForegroundColor Gray }
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
            # Attaching parameters makes ADO.NET route the batch through sp_executesql, where DDL such
            # as ALTER FUNCTION will not parse ("A RETURN statement with a return value cannot be used
            # in this context"). Only bind what the statement actually references.
            if ($ExecSql -match '@p\b') { [void]$cmd.Parameters.AddWithValue('@p', "$PkgId") }
            if ($ExecSql -match '@s\b') { [void]$cmd.Parameters.AddWithValue('@s', "$ExecSite") }
            if ($ExecSql -match '^\s*SELECT\b') {
                $v = $cmd.ExecuteScalar()
                $cn.Close()
                $out.Add("EXEC value=$v :: $ExecSql")
                return $out
            }
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
            if ($q -match '@site\b') { [void]$cmd.Parameters.AddWithValue('@site', $siteCode) }
            $r = $cmd.ExecuteReader()
            # Procs like spDiagDRS return MANY result sets; reading only the first silently drops the
            # rest and looks like a complete answer.
            $set = 0
            do {
                $set++
                if (-not $keep -and $set -gt 1) { $out.Add("  ---- result set $set ----") }
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
            } while ($r.NextResult())
            $r.Close(); $cn.Close()
            # Absence is evidence here -- no row in PkgStatus_G is what makes IsPkgSendingNeeded return TRUE.
            if ($keep -and $rows -eq 0) { $out.Add("$title NO ROWS") }
        }
        catch { if ($keep) { $out.Add("$title ERROR: " + $_.Exception.Message) } else { $out.Add('  ERROR: ' + $_.Exception.Message) } }
    }
    if ($PkgId) {
        $keep = 'Action|Mask|Version|SiteCode|SourceSite|Flags|Status|Refresh|Type|PkgID|^ID$|Priority|Time|Date|NALPath|DPID|ServerName|DistmgrJoin|SiteNumber|Available|Operation|RowXml|SendingSite|TargetSite|ProcessedTime'
        Q "SELECT * FROM PkgStatus_G WHERE ID = @p" 'PkgStatus_G' $keep $PkgId
        Q "SELECT PkgID, SiteNumber, PkgVersion FROM dbo.PkgStatusHist WHERE PkgID = @p ORDER BY PkgVersion, SiteNumber" 'PkgStatusHist' $keep $PkgId
        Q "SELECT p.PkgID, p.SourceVersion, dbo.fnIsPkgVersionAvailable(@p, @site, p.SourceVersion) AS Available FROM dbo.SMSPackages AS p WHERE p.PkgID = @p" 'fnIsPkgVersionAvailable' $keep $PkgId
        Q "SELECT * FROM PkgServers_G WHERE PkgID = @p" 'PkgServers_G' $keep $PkgId
        Q "SELECT * FROM PkgServers_L WHERE PkgID = @p" 'PkgServers_L' $keep $PkgId
        # This is the exact INNER JOIN prerequisite used by distmgr's
        # FindFirstPkgServer. LEFT JOIN here so the diagnostic preserves the
        # PkgServers row and names a missing DistributionPoints partner instead
        # of reproducing the product's silent zero-row result.
        Q @"
SELECT ps.PkgID, ps.NALPath, ps.SiteCode AS PkgServerSiteCode,
       ps.SourceSite, ps.LastRefresh, ps.RefreshTrigger, ps.UpdateMask, ps.Action,
       CASE WHEN dp.NALPath IS NULL THEN 'BLOCKED_NO_DISTRIBUTIONPOINT' ELSE 'JOINABLE' END AS DistmgrJoin,
       dp.*
FROM dbo.PkgServers_L AS ps
LEFT JOIN dbo.DistributionPoints AS dp ON dp.NALPath = ps.NALPath
WHERE ps.PkgID = @p
"@ 'PkgServerDistmgrJoin' $keep $PkgId
        Q "SELECT * FROM SMSPackages WHERE PkgID = @p" 'SMSPackages' $keep $PkgId
        # distmgr.cpp:27851 drops a CHILD-SITE package server from the send array unless the site's
        # Status is SITE_STATUS_ACTIVE(1) -- site.cpp:1448. SELECT * because the column names here are
        # not guessable: 'ReportingSiteCode'/'Type' do not exist and cost a run to an Invalid column name.
        Q "SELECT * FROM dbo.Sites" 'Sites' $keep $PkgId
        # Type: 1 Package, 2 Program, 4 Package Server (DP), 8 Access account (PkgNotification.h).
        Q "SELECT * FROM PkgNotification WHERE PkgID = @p" 'PkgNotification' $keep $PkgId
    # The child can retain the PCK forever while fnIsPkgVersionAvailable is
    # false. Preserve the exact package-status rows offered by the CAS so a
    # missing child row can be attributed to extraction versus apply.
    Q "SELECT m.ID, m.SendingSite, m.TargetSite, m.ProcessedTime, T.X.value('./@Type','NVARCHAR(64)') AS Operation, LEFT(CONVERT(NVARCHAR(MAX), R.Y.query('.')), 400) AS RowXml FROM dbo.DRSSentMessages AS m WITH (NOLOCK) CROSS APPLY m.MessageData.nodes('/DRS_SyncData/Operation') T(X) CROSS APPLY T.X.nodes('row') R(Y) WHERE T.X.value('./@TableName','NVARCHAR(256)') = 'PkgStatus_G' AND R.Y.value('./@ID','NVARCHAR(8)') = @p ORDER BY m.ID" 'DRSSentMessages-PkgStatus_G' $keep $PkgId
    Q "SELECT m.ID, m.SendingSite, m.TargetSite, m.ProcessedTime, T.X.value('./@Type','NVARCHAR(64)') AS Operation, LEFT(CONVERT(NVARCHAR(MAX), R.Y.query('.')), 400) AS RowXml FROM dbo.DRSSentMessages AS m WITH (NOLOCK) CROSS APPLY m.MessageData.nodes('/DRS_SyncData/Operation') T(X) CROSS APPLY T.X.nodes('row') R(Y) WHERE T.X.value('./@TableName','NVARCHAR(256)') = 'PkgStatusHist' AND R.Y.value('./@PkgID','NVARCHAR(8)') = @p ORDER BY m.ID" 'DRSSentMessages-PkgStatusHist' $keep $PkgId
        # Second mode of the same proc: all three params non-null jumps to SEARCHFORDATA, which reports
        # this specific row's replication state rather than the site's general state.
        Q "EXEC dbo.spDiagDRS N'PkgServers_G', N'PkgID', @p" 'spDiagDRS-PkgServers_G' $keep $PkgId
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
    # Measured on cstest2: at 18:45 EVERY group on the new child still showed LastSendStartTime
    # 18:21:4x -- the sender had produced nothing for 24 min while our code kept writing the row.
    # A single number that covers all groups is the fastest way to see that state again.
    Q "SELECT rd.ReplicationGroup, ma.SiteCode, ma.Active, ma.LastSendResult, ma.LastVersionSent, ma.LastSendStartTime, DATEDIFF(SECOND, ma.LastSendStartTime, GETUTCDATE()) AS SecsSinceSendStart, rd.SyncInterval*60 AS DueAfterSecs FROM DRS_MessageActivity_Send ma INNER JOIN ReplicationData rd ON rd.ID = ma.ReplicationID ORDER BY SecsSinceSendStart DESC" "STALL: seconds since each group last STARTED a send (all groups high = sender idle)"
    # Reproduces the gate in spDRSInitiateSynchronizations: it queues a group only once
    # (60*SyncInterval) seconds have passed since LastSendStartTime and ma.Active=1. Rows here are
    # groups the product itself considers due, so a non-empty list with nothing being sent is the
    # stall, not a schedule.
    Q "SELECT rd.ReplicationGroup, ma.SiteCode, DATEDIFF(SECOND, ma.LastSendStartTime, GETUTCDATE()) AS AgeSecs, rd.SyncInterval*60 AS ThresholdSecs, ma.LastSendResult FROM DRS_MessageActivity_Send ma INNER JOIN ReplicationData rd ON rd.ID = ma.ReplicationID WHERE ma.Active = 1 AND DATEDIFF(SECOND, ma.LastSendStartTime, GETUTCDATE()) > rd.SyncInterval*60 ORDER BY AgeSecs DESC" "STALL: groups OVERDUE by the product's own rule (60*SyncInterval elapsed, Active=1)"
    # A DRS_StartMsgBuilder still sitting here makes spDRSInitiateSynchronizations skip the group
    # entirely -- one un-finished extraction stalls every later send for that group.
    Q "SELECT message_type_name, COUNT(*) AS Msgs FROM ConfigMgrDRSMsgBuilderQueue WITH (NOLOCK) GROUP BY message_type_name" "STALL: ConfigMgrDRSMsgBuilderQueue depth (a stuck DRS_StartMsgBuilder blocks re-queue)"
    # spDRSMsgBuilderActivation refuses to start an extraction while a context for that group is
    # still running, so the blocker chain is the thing to capture, not just the runner.
    Q "SELECT r.session_id, s.program_name, r.status, r.command, r.wait_type, r.wait_time, r.blocking_session_id, CONVERT(NVARCHAR(300), SUBSTRING(t.text, 1, 300)) AS Stmt FROM sys.dm_exec_requests r INNER JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE s.program_name LIKE '%REPLICATION%' OR s.program_name LIKE '%SMS%' OR r.blocking_session_id <> 0 ORDER BY r.blocking_session_id DESC, r.wait_time DESC" "STALL: running DRS/SMS requests and anything blocking them"
    Q "SELECT to_service_name, transmission_status, COUNT(*) AS Msgs, MIN(enqueue_time) AS Oldest FROM sys.transmission_queue GROUP BY to_service_name, transmission_status" "STALL: sys.transmission_queue (outgoing SSB backlog; transmission_status names the error)"
    Q "SELECT state_desc, COUNT(*) AS Dialogs, MIN(security_timestamp) AS Oldest FROM sys.conversation_endpoints GROUP BY state_desc" "STALL: conversation endpoints by state (DISCONNECTED/ERROR dialogs wedge a group)"
    Q 'EXEC spDiagMessagesInQueue' 'spDiagMessagesInQueue (incoming backlog per group; multiple result sets)'
    # 'Configuration Data' message capture is ON by default in this build, so these can hold history
    # from before -EnableDrsTracing was ever run. The count runs first so that an empty detail list
    # cannot be misread as "nothing was sent" when it means "capture is off". Columns verified in
    # Core/Tables/DRSSentMessages.h.
    Q "SELECT COUNT(*) AS MessagesCaptured, MIN(ProcessedTime) AS Earliest, MAX(ProcessedTime) AS Latest FROM DRSSentMessages" "DRSSentMessages: is per-group message capture even on? (0 = OFF, not 'nothing sent')"
    Q "SELECT TOP 40 m.ID, m.SendingSite, m.TargetSite, m.ProcessedTime, T.X.value('./@TableName','NVARCHAR(256)') AS TableName, T.X.value('./@Type','NVARCHAR(64)') AS Operation FROM DRSSentMessages m WITH (NOLOCK) CROSS APPLY m.MessageData.nodes('/DRS_SyncData/Operation') T(X) WHERE T.X.value('./@TableName','NVARCHAR(256)') LIKE 'Pkg%' OR T.X.value('./@TableName','NVARCHAR(256)') LIKE 'SMSPackages%' ORDER BY m.ID DESC" "DRSSentMessages: which Pkg*/SMSPackages* rows were actually SENT, and when"
    # Unbounded and OLDEST FIRST on purpose: the question is when this table's rows actually moved,
    # and a TOP..DESC list only ever shows the most recent traffic. Capture predates the coverage
    # wait, so this reaches back to the event itself instead of to whatever happened most recently.
    Q "SELECT m.ID, m.SendingSite, m.TargetSite, m.ProcessedTime, T.X.value('./@Type','NVARCHAR(64)') AS Operation FROM DRSSentMessages m WITH (NOLOCK) CROSS APPLY m.MessageData.nodes('/DRS_SyncData/Operation') T(X) WHERE T.X.value('./@TableName','NVARCHAR(256)') = 'PkgServers_G' ORDER BY m.ID" "DRSSentMessages: EVERY PkgServers_G send captured, oldest first"
    # Dumps the row element verbatim rather than naming attributes, so WHICH row moved is read off the
    # message instead of inferred from a timestamp lining up.
    Q "SELECT m.ID, m.ProcessedTime, T.X.value('./@Type','NVARCHAR(64)') AS Operation, CONVERT(NVARCHAR(400), R.Y.query('.')) AS RowXml FROM DRSSentMessages m WITH (NOLOCK) CROSS APPLY m.MessageData.nodes('/DRS_SyncData/Operation') T(X) CROSS APPLY T.X.nodes('row') R(Y) WHERE T.X.value('./@TableName','NVARCHAR(256)') = 'PkgServers_G' ORDER BY m.ID" "DRSSentMessages: the PkgServers_G rows themselves (which package, which site)"
    # The product's own diagnostic, and the entry point the support wiki tells engineers to use.
    # With no arguments it emits a USAGE banner as result set 1 and the general-state sections after
    # it, so the sets are offset by one from the wiki's numbering: general status (SiteStatus, cert
    # thumbprint), queue depths, global group init % (must be 100), link status, SSB certs+routes,
    # hierarchy, per-group LastSentStatus. The section headings are PRINT output, which ADO.NET does
    # not return, so sets are numbered rather than named.
    Q 'EXEC dbo.spDiagDRS' 'spDiagDRS (product diagnostic; set 1 is a USAGE banner, the state sections follow)'
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
    # The CAS HMAN transition creates the DistributionPoints join partner.
    # It is site-scoped rather than package-scoped, so it never contains PkgId.
    $hman = Join-Path $d 'Logs\hman.log'
    if (Test-Path $hman) {
        foreach ($x in @(Get-Content -LiteralPath $hman -Tail 1000 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match 'Distribution Points of site' } | Select-Object -Last 20)) {
            $o.Add("LOG hman.log :: " + (($x -replace '\s+', ' ').Trim()))
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

# The oracle Phase 11 fails on. Returned verbatim so "WMI did not answer" and "no DP has this
# package" cannot be confused -- they mean opposite things and both look like an empty list.
$dpStateBlock = {
    param($SiteCode, $PkgId)
    $names = @{ 0 = 'Installed'; 1 = 'InstallPending'; 2 = 'InstallRetrying'; 3 = 'InstallFailed'; 4 = 'RemovalPending'; 5 = 'RemovalRetrying'; 6 = 'RemovalFailed'; 7 = 'ContentValidating'; 8 = 'ContentValidationFailed' }
    $ns = "root\SMS\site_$SiteCode"
    $o = New-Object System.Collections.Generic.List[string]
    $rows = $null
    try { $rows = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$PkgId'" -ErrorAction Stop) }
    catch { $o.Add("DPSTATE ERROR $ns : $($_.Exception.Message)"); return $o.ToArray() }
    if ($rows.Count -eq 0) { $o.Add("DPSTATE NO ROWS in $ns for $PkgId"); return $o.ToArray() }
    foreach ($r in $rows) {
        $nal = "$($r.ServerNALPath)"
        $dp = if ($nal -match '\\\\([^\\"\]]+)') { $Matches[1] } else { $nal }
        $sn = $names[[int]$r.State]; if (-not $sn) { $sn = "State$($r.State)" }
        $o.Add(("DPSTATE[{0}] site={1} state={2}({3}) srcVer={4} dpSrcVer={5}" -f $dp, $r.SiteCode, [int]$r.State, $sn, $r.SourceVersion, $r.DPSourceVersion))
    }
    return $o.ToArray()
}

# Physical ground truth on the secondary. A DP sitting at ContentValidating with the package absent
# from PkgLib never received anything -- the summarizer row is a phantom, not progress.
$secContentBlock = {
    param($PkgId)
    $o = New-Object System.Collections.Generic.List[string]
    $sawLib = $false
    foreach ($d in @('E', 'D', 'F', 'G', 'C')) {
        $pl = "${d}:\SCCMContentLib\PkgLib"
        if (-not (Test-Path $pl)) { continue }
        $sawLib = $true
        $inis = @(Get-ChildItem -LiteralPath $pl -Filter '*.INI' -ErrorAction SilentlyContinue)
        $mine = @($inis | Where-Object { $_.BaseName -like "$PkgId*" })
        $o.Add("PKGLIB $pl count=$($inis.Count) hasPackage=$($mine.Count -gt 0)")
    }
    if (-not $sawLib) { $o.Add('PKGLIB NONE on E,D,F,G,C -- no content library on this machine') }
    $dir = $null
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $dir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch { }
        if ($dir) { break }
    }
    if (-not $dir) { $o.Add('INBOX UNKNOWN -- SMS install dir not found, inbox depth NOT measured'); return $o.ToArray() }
    foreach ($box in @('despoolr.box\receive', 'despoolr.box', 'distmgr.box')) {
        $p = Join-Path $dir "inboxes\$box"
        if (-not (Test-Path $p)) { $o.Add("INBOX $box ABSENT"); continue }
        $f = @(Get-ChildItem -LiteralPath $p -File -ErrorAction SilentlyContinue)
        $oldest = if ($f.Count) { (($f | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime).ToString('MM-dd HH:mm:ss') } else { '-' }
        $o.Add("INBOX $box files=$($f.Count) oldest=$oldest")
    }
    return $o.ToArray()
}

# INTERVENTION: ask the parent to re-send this package to one DP.
$dpRefreshBlock = {
    param($SiteCode, $PkgId, $DpMatch)
    $ns = "root\SMS\site_$SiteCode"
    $o = New-Object System.Collections.Generic.List[string]
    $rows = $null
    try { $rows = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$PkgId'" -ErrorAction Stop) }
    catch { $o.Add("REFRESH ERROR $ns : $($_.Exception.Message)"); return $o.ToArray() }
    $o.Add("REFRESH rows=$($rows.Count) in $ns for $PkgId")
    $hit = 0
    # Anchored on the NAL's \\<name> so a longer DP name cannot be refreshed by mistake.
    $nalRe = '\\\\' + [regex]::Escape($DpMatch) + '(\.|\\)'
    foreach ($r in $rows) {
        $nal = "$($r.ServerNALPath)"
        if ($nal -notmatch $nalRe) { continue }
        $hit++
        try { $r.RefreshNow = $true; $null = $r.Put(); $o.Add("REFRESH SET $nal") }
        catch { $o.Add("REFRESH FAILED $nal : $($_.Exception.Message)") }
    }
    if ($hit -eq 0) { $o.Add("REFRESH NO MATCH for '$DpMatch' -- this site does not target that DP for this package") }
    return $o.ToArray()
}

# The ONE decision on the send-to-child path that does log. distmgr.cpp:27851 prints this exact
# string and RemoveAt()s the package server when the child site is not SITE_STATUS_ACTIVE, which
# is the documented reason a secondary's DP never receives content (pushlab 2026-07-28).
$distmgrDecisionBlock = {
    param($PkgId, $DpMatch)
    $o = New-Object System.Collections.Generic.List[string]
    $dir = $null
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $dir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch { }
        if ($dir) { break }
    }
    if (-not $dir) { $o.Add('DISTMGR UNKNOWN -- SMS install dir not found, distmgr.log NOT read'); return $o.ToArray() }
    $files = @()
    foreach ($n in @('distmgr.log', 'distmgr.lo_')) {
        $p = Join-Path $dir "Logs\$n"
        if (Test-Path $p) { $files += $p }
    }
    if ($files.Count -eq 0) { $o.Add("DISTMGR NO LOG under $dir\Logs -- NOT read, which is not the same as no decision"); return $o.ToArray() }
    $pats = [ordered]@{
        'not-active-site' = 'is not an active site'
        'bundle-failed'   = 'Error creating package bundle'
        'request-aborted' = '0x800704d3'
        'delete-instruct' = 'to delete package'
        'pkg-id'          = [regex]::Escape("$PkgId")
        'dp-name'         = [regex]::Escape("$DpMatch")
    }
    foreach ($k in @($pats.Keys)) {
        $hits = @()
        foreach ($f in $files) {
            try { $hits += @(Select-String -LiteralPath $f -Pattern $pats[$k] -ErrorAction Stop) } catch { }
        }
        $o.Add("DISTMGR pattern '$k' hits=$($hits.Count)")
        foreach ($h in @($hits | Select-Object -Last 6)) {
            $t = ("$($h.Line)" -replace '^<!\[LOG\[', '' -replace '\]LOG\]!>.*', '').Trim()
            if ($t.Length -gt 220) { $t = $t.Substring(0, 220) + '...' }
            $o.Add("  $t")
        }
    }
    return $o.ToArray()
}

# KEEP IN SYNC with the wedge gate in DSC/phases/InstallBoundaryGroups.ps1 -- proving a lookalike
# predicate proves nothing about what ships. temp/test-wedge-gate-sync.ps1 asserts they match.
$wedgeStateBlock = {
    param($PkgId, $SecSite)
    $o = New-Object System.Collections.Generic.List[string]
    $dir = $null
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $dir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch { }
        if ($dir) { break }
    }
    if (-not $dir) { $o.Add('WEDGE UNREADABLE -- SMS install dir not found'); return $o.ToArray() }
    $p = Join-Path $dir 'Logs\distmgr.log'
    if (-not (Test-Path $p)) { $o.Add("WEDGE UNREADABLE -- no distmgr.log at $p"); return $o.ToArray() }
    $tail = @(Get-Content -LiteralPath $p -Tail 4000 -ErrorAction SilentlyContinue)
    if ($tail.Count -eq 0) { $o.Add('WEDGE UNREADABLE -- distmgr.log read returned nothing'); return $o.ToArray() }
    $aborts = 0; $lastAbort = -1; $lastSend = -1; $lastPkgSend = -1
    for ($i = 0; $i -lt $tail.Count; $i++) {
        $ln = $tail[$i]
        if ($ln -match '0x800704d3' -and $ln -match 'CopyFileExW|CreatePackageBundle|TakeContentSnapshot|AddContentToBundle|SnapshotPackage|BundleLegacyContentFiles') { $lastAbort = $i; $aborts++ }
        if ($ln -match 'Created minijob to send compressed copy') {
            $lastSend = $i
            if ($ln -match [regex]::Escape("$PkgId") -and $ln -match ('to site {0}\.' -f [regex]::Escape("$SecSite"))) { $lastPkgSend = $i }
        }
    }
    $wedged = ($aborts -ge 5 -and $lastAbort -gt $lastSend)
    $o.Add("WEDGE lines=$($tail.Count) aborts=$aborts lastAbort=$lastAbort lastSend=$lastSend lastPkgSend=$lastPkgSend wedged=$wedged")
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='SMS_EXECUTIVE'" -ErrorAction Stop
        $svcPid = [int]$svc.ProcessId
        $start = '-'
        if ($svcPid -gt 0) { $pr = Get-Process -Id $svcPid -ErrorAction SilentlyContinue; if ($pr) { $start = $pr.StartTime.ToString('MM-dd HH:mm:ss') } }
        $o.Add("EXEC state=$($svc.State) pid=$svcPid start=$start")
    }
    catch { $o.Add("EXEC UNREADABLE $($_.Exception.Message)") }
    return $o.ToArray()
}

# INTERVENTION. The PID must change: the mechanism claim is that only a fresh process clears the
# static cancel flag, so a restart that reused the process would make the trial void, not negative.
$execRestartBlock = {
    $o = New-Object System.Collections.Generic.List[string]
    $before = 0
    try { $before = [int](Get-CimInstance Win32_Service -Filter "Name='SMS_EXECUTIVE'" -ErrorAction Stop).ProcessId } catch { }
    $o.Add("EXEC-RESTART before pid=$before")
    try { Restart-Service -Name SMS_EXECUTIVE -Force -ErrorAction Stop; $o.Add('EXEC-RESTART issued') }
    catch { $o.Add("EXEC-RESTART FAILED $($_.Exception.Message)"); return $o.ToArray() }
    Start-Sleep -Seconds 30
    $after = 0
    $state = '?'
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='SMS_EXECUTIVE'" -ErrorAction Stop
        $after = [int]$svc.ProcessId; $state = "$($svc.State)"
    }
    catch { }
    $o.Add("EXEC-RESTART after pid=$after state=$state pidChanged=$($after -gt 0 -and $after -ne $before)")
    return $o.ToArray()
}

# INTERVENTION. The stimulus: force distmgr to attempt a content bundle.
# SourceVersion is READ-ONLY and server-maintained, so it cannot be the gate for "did the stimulus
# land" -- distmgr moves it, and distmgr is the component under test. Judging the stimulus by that
# column is circular and produced a VOID on 2026-08-23. The call's own ReturnValue is the only
# direct evidence it ran; a WMI method can fail by return value without throwing.
$refreshPkgSourceBlock = {
    param($SiteCode, $PkgId)
    $ns = "root\SMS\site_$SiteCode"
    $o = New-Object System.Collections.Generic.List[string]
    $pkg = $null
    try { $pkg = @(Get-WmiObject -Namespace $ns -Class SMS_Package -Filter "PackageID='$PkgId'" -ErrorAction Stop) | Select-Object -First 1 }
    catch { $o.Add("REFRESHPKG UNREADABLE $($_.Exception.Message)"); return $o.ToArray() }
    if (-not $pkg) { $o.Add("REFRESHPKG NO PACKAGE $PkgId in $ns"); return $o.ToArray() }
    $v0 = [int]$pkg.SourceVersion
    $d0 = "$($pkg.SourceDate)"
    $o.Add("REFRESHPKG before SourceVersion=$v0 SourceDate=$d0")

    $issued = $false
    try {
        $r = $pkg.RefreshPkgSource()
        $rv = if ($null -ne $r -and $null -ne $r.ReturnValue) { [int]$r.ReturnValue } else { 0 }
        $o.Add("REFRESHPKG method ReturnValue=$rv")
        if ($rv -eq 0) { $issued = $true }
    }
    catch { $o.Add("REFRESHPKG method threw: $($_.Exception.Message)") }

    # Documented as having the same effect as the method, and it is a property write so there is no
    # ContextID argument to get wrong. Tried only if the method did not report success.
    if (-not $issued) {
        try {
            $pkg.RefreshPkgSourceFlag = $true
            $null = $pkg.Put()
            $o.Add('REFRESHPKG flag+Put issued')
            $issued = $true
        }
        catch { $o.Add("REFRESHPKG flag+Put threw: $($_.Exception.Message)") }
    }
    if (-not $issued) { $o.Add('REFRESHPKG NOT ISSUED -- neither lever succeeded'); return $o.ToArray() }
    $o.Add('REFRESHPKG ISSUED')

    # Reported for interest only. It is NOT the pass/fail gate: the server may not move it while
    # distmgr is wedged, which is precisely the state being tested.
    for ($i = 0; $i -lt 6; $i++) {
        Start-Sleep -Seconds 10
        try {
            $p2 = @(Get-WmiObject -Namespace $ns -Class SMS_Package -Filter "PackageID='$PkgId'" -ErrorAction Stop) | Select-Object -First 1
            if ($p2 -and ([int]$p2.SourceVersion -gt $v0 -or "$($p2.SourceDate)" -ne $d0)) {
                $o.Add("REFRESHPKG server moved: SourceVersion=$([int]$p2.SourceVersion) SourceDate=$($p2.SourceDate)")
                return $o.ToArray()
            }
        }
        catch { }
    }
    $o.Add("REFRESHPKG server has not moved SourceVersion in 60s (still $v0). Expected while distmgr is wedged; the verdict comes from distmgr's own log, not from this column.")
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

# Value names/types are as documented by the DRS support wiki. Prior state (including ABSENCE) is
# captured so the disable path restores what was there instead of writing documented defaults over it.
$drsTracingBlock = {
    param($Mode)
    $out = New-Object System.Collections.Generic.List[string]
    $comp = 'HKLM:\SOFTWARE\Microsoft\SMS\COMPONENTS\SMS_REPLICATION_CONFIGURATION_MONITOR'
    $trace = 'HKLM:\SOFTWARE\Microsoft\SMS\Tracing\SMS_REPLICATION_CONFIGURATION_MONITOR'
    $backup = 'C:\Windows\Temp\drs-tracing-prior.json'
    $spec = @(
        @{ Key = $comp; Name = 'DRS Replication Group Message Logging'; Type = 'String'; On = 'Configuration Data'; Off = '' },
        @{ Key = $comp; Name = 'DRS Logging Level'; Type = 'DWord'; On = 2; Off = 1 },
        @{ Key = $comp; Name = 'Verbose Logging'; Type = 'DWord'; On = 2; Off = 0 },
        @{ Key = $trace; Name = 'DebugLogging'; Type = 'DWord'; On = 1; Off = 0 },
        @{ Key = $trace; Name = 'LoggingLevel'; Type = 'DWord'; On = 0; Off = 1 },
        @{ Key = $trace; Name = 'MaxFileSize'; Type = 'DWord'; On = 52428800; Off = 2621440 }
    )
    $prior = @()
    if ($Mode -eq 'disable') {
        if (Test-Path -LiteralPath $backup) {
            # Assign BEFORE wrapping: on PS5.1 @(<pipeline ending in ConvertFrom-Json>) yields ONE
            # element holding the whole array, which silently restores nothing. PS7 hides this.
            try { $parsed = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json; $prior = @($parsed) }
            catch { $out.Add("PRIOR STATE UNREADABLE ($($_.Exception.Message)) -- falling back to documented defaults") }
        }
        else { $out.Add('NO PRIOR STATE FILE -- restoring documented defaults, not the values this site actually had') }
    }
    $capture = New-Object System.Collections.Generic.List[object]
    foreach ($s in $spec) {
        $existed = $false
        $was = $null
        if (Test-Path -LiteralPath $s.Key) {
            $p = Get-ItemProperty -LiteralPath $s.Key -ErrorAction SilentlyContinue
            if ($p -and $p.PSObject.Properties[$s.Name]) { $existed = $true; $was = $p.PSObject.Properties[$s.Name].Value }
        }
        else {
            if ($Mode -eq 'enable') { New-Item -Path $s.Key -Force -ErrorAction SilentlyContinue | Out-Null; $out.Add("KEY CREATED $($s.Key)") }
            else { $out.Add("KEY ABSENT $($s.Key) -- nothing to restore"); continue }
        }
        $capture.Add([pscustomobject]@{ Key = $s.Key; Name = $s.Name; Existed = $existed; Was = $was })
        $remove = $false
        if ($Mode -eq 'enable') {
            $target = $s.On
            # This value ships NON-EMPTY (observed: 'Site Control Data,Configuration Data,CMUpdates,
            # CMUpdates Status'), so replacing it would silently switch capture OFF for the other groups.
            if ($s.Name -eq 'DRS Replication Group Message Logging') {
                $groups = @()
                if ($existed -and "$was".Trim()) { $groups = @("$was" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                if ($groups -notcontains $s.On) { $groups += $s.On }
                $target = ($groups -join ',')
            }
        }
        else {
            $target = $s.Off
            $rec = @($prior | Where-Object { $_.Key -eq $s.Key -and $_.Name -eq $s.Name }) | Select-Object -First 1
            if ($rec) { if (-not $rec.Existed) { $remove = $true } else { $target = $rec.Was } }
        }
        try {
            if ($remove) {
                Remove-ItemProperty -LiteralPath $s.Key -Name $s.Name -Force -ErrorAction Stop
                $out.Add(("{0,-38} REMOVED (did not exist before)" -f $s.Name))
                continue
            }
            Set-ItemProperty -LiteralPath $s.Key -Name $s.Name -Value $target -Type $s.Type -Force -ErrorAction Stop
        }
        catch { $out.Add(("{0,-38} FAILED: {1}" -f $s.Name, $_.Exception.Message)); continue }
        $rb = Get-ItemProperty -LiteralPath $s.Key -ErrorAction SilentlyContinue
        $now = if ($rb -and $rb.PSObject.Properties[$s.Name]) { $rb.PSObject.Properties[$s.Name].Value } else { '<MISSING AFTER WRITE>' }
        $before = if ($existed) { "$was" } else { '<absent>' }
        $flag = if ("$now" -eq "$target") { 'ok' } else { 'READBACK MISMATCH' }
        $out.Add(("{0,-38} {1} -> {2}  [{3}]" -f $s.Name, $before, $now, $flag))
    }
    if ($Mode -eq 'enable') {
        # Never overwrite an earlier capture: it holds the state from before this tool first ran, and
        # a second enable would replace it with values this tool already changed.
        if (Test-Path -LiteralPath $backup) { $out.Add("prior state ALREADY captured, left untouched -> $backup") }
        else {
            try { $capture | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backup -Encoding UTF8 -ErrorAction Stop; $out.Add("prior state saved -> $backup") }
            catch { $out.Add("COULD NOT SAVE PRIOR STATE ($($_.Exception.Message)) -- disable will only be able to use defaults") }
        }
    }
    else { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    return $out
}

if ($EnableDrsTracing -and $DisableDrsTracing) {
    Write-Host 'FATAL: pass only one of -EnableDrsTracing / -DisableDrsTracing.' -ForegroundColor Red
    return
}
if ($EnableDrsTracing -or $DisableDrsTracing) {
    $mode = if ($EnableDrsTracing) { 'enable' } else { 'disable' }
    $bit = if ($EnableDrsTracing) { '1' } else { '0' }
    $fnSql = "ALTER FUNCTION dbo.fnIsDebugLoggingEnabled() RETURNS BIT AS BEGIN RETURN $bit; END"
    Write-Host "==== DRS tracing: $mode ====" -ForegroundColor Cyan
    foreach ($t in (@($cas) + @($priList))) {
        Write-Host "---- $($t.vmName) [$($t.siteCode)] ----" -ForegroundColor Cyan
        foreach ($l in (Get-GuestOutput -VmName $t.vmName -DomainName $dom -Block $drsTracingBlock -ArgList @($mode) -Tag "trace-$($t.siteCode)")) { Write-Host "    $l" }
        $sq = Resolve-SqlVm -SiteVm $t -AllVms $allVms
        foreach ($l in (Get-GuestOutput -VmName $sq.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($t.siteCode, $null, $null, $fnSql, $t.siteCode) -Tag "fn-$($t.siteCode)")) { Write-Host "    $l" }
        # ExecuteNonQuery reports -1 for DDL, which says nothing about what the function now returns.
        foreach ($l in (Get-GuestOutput -VmName $sq.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($t.siteCode, $null, $null, 'SELECT dbo.fnIsDebugLoggingEnabled()', $t.siteCode) -Tag "fnread-$($t.siteCode)")) { Write-Host "    readback $l" }
    }
    Write-Host ''
    Write-Host 'SMS_REPLICATION_CONFIGURATION_MONITOR picks these up on its next cycle; no service is restarted here.' -ForegroundColor Yellow
    if ($mode -eq 'enable') {
        Write-Host 'Verbose DRS logging can fill a disk -- re-run with -DisableDrsTracing when the run is done.' -ForegroundColor Yellow
        if ($SettleSeconds -gt 0) {
            Write-Host "Waiting ${SettleSeconds}s for the component to pick the settings up before you start a measurement..." -ForegroundColor Yellow
            Start-Sleep -Seconds $SettleSeconds
            Write-Host 'Settled. Safe to start the probe or the build now.' -ForegroundColor Green
        }
    }
    return
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

# Returns the summarizer line for a secondary, or Readable=$false when it could not be READ -- the
# caller must never treat those the same. Module scope: both intervening modes need it.
$readSecState = {
    param($Sec, $Parent)
    $lines = @(Get-GuestOutput -VmName $Parent.vmName -DomainName $dom -Block $dpStateBlock -ArgList @($Parent.siteCode, $PackageId) -Tag "dpstate-$($Parent.siteCode)")
    $short = ($Sec.vmName -split '\.')[0]
    $rows = @($lines | Where-Object { $_ -like 'DPSTATE`[*' })
    # Anchored to the bracketed name: a bare substring lets 'BI-SECONDARY' match a
    # 'BI-SECONDARY-DP' row and report a different machine's state as this one's.
    $nameRe = '^DPSTATE\[' + [regex]::Escape($short) + '(\.|\])'
    $mine = @($rows | Where-Object { $_ -match $nameRe })
    return [pscustomobject]@{
        Readable  = ($rows.Count -gt 0)
        Row       = (@($mine) | Select-Object -First 1)
        Installed = (@($mine | Where-Object { $_ -match 'state=0\(' }).Count -gt 0)
        Lines     = $lines
    }
}

if ($SecondaryContentHop -or $RepairSecondaryContent) {
    $hopLog = Join-Path $logsRoot ("secondary-content-hop-{0}.log" -f $stamp)
    $hsay = {
        param($t)
        $l = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $t
        Write-Host $l -ForegroundColor Gray
        try { Add-Content -LiteralPath $hopLog -Value $l -Encoding utf8 -ErrorAction Stop } catch { }
    }
    & $hsay "log -> $hopLog"
    if ($secList.Count -eq 0) { & $hsay 'FATAL: no Secondary site under any child primary in this domain. Nothing to measure.'; return }
    if ($secList.Count -ne 1 -and $RepairSecondaryContent) { & $hsay "FATAL: -RepairSecondaryContent needs exactly one secondary; got $($secList.vmName -join ', ')."; return }

    if (-not $PackageId) {
        $cand = @(Get-GuestOutput -VmName $cas.vmName -DomainName $dom -Block $pkgFindBlock -ArgList @($cas.siteCode) -Tag 'find-clientpkg')
        $ids = @($cand | Where-Object { $_ -match '^[A-Z0-9]{8} ' })
        if ($ids.Count -ne 1) { & $hsay 'FATAL: could not resolve the client package. Re-run with -PackageId.'; return }
        $PackageId = $ids[0].Split(' ')[0]
    }
    & $hsay "package=$PackageId  cas=$($cas.vmName)/$($cas.siteCode)  secondaries=$($secList.vmName -join ', ')"

    # The summarizer is hierarchy-wide, so the parent primary is the natural place to read it and is
    # also the site that owns the send to its secondary.
    $parentOf = @{}
    foreach ($s in $secList) {
        $p = @($priList | Where-Object { $_.siteCode -eq $s.parentSiteCode }) | Select-Object -First 1
        if (-not $p) { & $hsay "WARN: no parent primary resolved for $($s.vmName) (parentSiteCode=$($s.parentSiteCode)) -- skipping"; continue }
        $parentOf[$s.vmName] = $p
    }

    # Returns the summarizer line for this secondary, or $null when it could not be READ -- the
    # caller must never treat those the same.

    foreach ($s in $secList) {
        $parent = $parentOf[$s.vmName]
        if (-not $parent) { continue }
        & $hsay ''
        & $hsay "================ $($s.vmName) (site $($s.siteCode)) under $($parent.vmName) (site $($parent.siteCode)) ================"

        $st = & $readSecState $s $parent
        foreach ($l in $st.Lines) { & $hsay "    $l" }
        if (-not $st.Readable) { & $hsay '    SUMMARIZER NOT READ -- that is an instrument failure, not evidence that no DP holds the package.' }
        elseif (-not $st.Row) { & $hsay "    NO SUMMARIZER ROW names $($s.vmName) -- the secondary is not even targeted for this package." }

        foreach ($l in (Get-GuestOutput -VmName $parent.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($parent.siteCode, $PackageId) -Tag 'parent-db')) { & $hsay "    PARENT-DB $l" }
        foreach ($l in (Get-GuestOutput -VmName $s.vmName -DomainName $dom -Block $secContentBlock -ArgList @($PackageId) -Tag 'sec-content')) { & $hsay "    SEC $l" }

        $secShortName = ($s.vmName -split '\.')[0]
        $dmg = @(Get-GuestOutput -VmName $parent.vmName -DomainName $dom -Block $distmgrDecisionBlock -ArgList @($PackageId, $secShortName) -Tag 'parent-distmgr')
        foreach ($l in $dmg) { & $hsay "    PARENT-LOG $l" }
        $naHits = -1
        $abHits = -1
        foreach ($l in $dmg) {
            if ($l -match "^DISTMGR pattern 'not-active-site' hits=(\d+)") { $naHits = [int]$Matches[1] }
            if ($l -match "^DISTMGR pattern 'request-aborted' hits=(\d+)") { $abHits = [int]$Matches[1] }
        }
        if ($naHits -lt 0) {
            & $hsay '    VERDICT: distmgr.log was NOT read, so both gates below are UNTESTED -- do not record this run as ruling anything out.'
        }
        elseif ($naHits -gt 0) {
            & $hsay "    VERDICT: the parent printed 'is not an active site, ignore it'. distmgr.cpp:27851 RemoveAt()s the package server there, BEFORE bServerChange/bResendPkg are evaluated -- so no RefreshNow can reach it. Fix Sites.Status for $($s.siteCode) first."
        }
        elseif ($abHits -gt 0) {
            # distmgr.cpp:17252 guards the auto-recovery with `if (hr != HRESULT_FROM_WIN32(ERROR_REQUEST_ABORTED))`,
            # and 0x800704D3 IS that HRESULT -- so this one failure is the only one that recovers nothing.
            & $hsay "    VERDICT: CreatePackageBundle to $($s.siteCode) failed with 0x800704D3 (ERROR_REQUEST_ABORTED). distmgr.cpp:17252 SKIPS its auto-recovery for exactly this HRESULT, so StoredPkgPath is not cleared, Action is not reset to UPDATE, and no backdated PkgStatus row is written to re-arm IsPkgSendingNeeded. The send is abandoned and never retried. RefreshNow cannot fix this; the package's source version has to move."
        }
        else {
            & $hsay "    VERDICT: the parent has NOT declined $($s.siteCode) as inactive and no aborted bundle was logged."
        }
    }

    if (-not $RepairSecondaryContent) {
        & $hsay ''
        & $hsay 'LEGEND (distsrc.h / site.h, do not guess these): PkgServers Action 0=NONE 1=UPDATE 2=ADD 3=DELETE 4=VALIDATE 5=CANCEL. Sites.Status 1=ACTIVE 2=PENDING 3=FAILED 4=DELETED 5=UPGRADE. An Action that is still ADD with LastRefresh at the 1970 epoch is an ADD that was never processed, not an ADD in flight.'
        & $hsay 'READ: PKGLIB hasPackage=False with a summarizer row means the row is a phantom -- content never arrived, so nothing on the DP side can fix it. distmgr logs NOTHING when it declines to send, so do not read a quiet distmgr.log as "no decision was made".'
        Write-Host "Hop log: $hopLog" -ForegroundColor Green
        return
    }

    # ---- pre-registered repair, same contract as -FlushExperiment ----
    $sec = $secList[0]
    $parent = $parentOf[$sec.vmName]
    if (-not $parent) { & $hsay 'ABORT: no parent primary for the secondary. NOT A RESULT.'; return }
    $secShort = ($sec.vmName -split '\.')[0]
    & $hsay ''
    & $hsay "REPAIR (pre-registered): baseline ${BaselineSeconds}s with NO intervention, then RefreshNow on $($parent.vmName), then watch ${PostSeconds}s."

    $pre = & $readSecState $sec $parent
    if (-not $pre.Readable) { & $hsay 'ABORT: could not READ the summarizer. Instrument failure, NOT evidence. NOT A RESULT.'; return }
    if (-not $pre.Row) { & $hsay "ABORT: no summarizer row names $secShort, so there is no DP state to repair. NOT A RESULT."; return }
    if ($pre.Installed) { & $hsay "ABORT: $secShort already reads Installed -- nothing to repair. NOT A RESULT."; return }
    & $hsay "precondition met: $($pre.Row)"

    $tBase = Get-Date
    $clearedInBaseline = $false
    while (((Get-Date) - $tBase).TotalSeconds -lt $BaselineSeconds) {
        Start-Sleep -Seconds 20
        if ((& $readSecState $sec $parent).Installed) { $clearedInBaseline = $true; break }
    }
    if ($clearedInBaseline) {
        & $hsay "CLEARED DURING BASELINE after $([int]((Get-Date) - $tBase).TotalSeconds)s, with no intervention."
        & $hsay 'THE REPAIR WAS NOT TESTED. This says the content was still moving on its own, nothing more.'
        return
    }
    & $hsay "baseline done: ${BaselineSeconds}s with no change and no intervention."

    $tFix = Get-Date
    foreach ($l in (Get-GuestOutput -VmName $parent.vmName -DomainName $dom -Block $dpRefreshBlock -ArgList @($parent.siteCode, $PackageId, $secShort) -Tag 'refresh')) { & $hsay "    $l" }
    & $hsay "intervened at $($tFix.ToString('HH:mm:ss')); polling every 20s for up to ${PostSeconds}s"

    $tClear = $null
    while (((Get-Date) - $tFix).TotalSeconds -lt $PostSeconds) {
        Start-Sleep -Seconds 20
        if ((& $readSecState $sec $parent).Installed) { $tClear = Get-Date; break }
    }
    $post = & $readSecState $sec $parent
    foreach ($l in $post.Lines) { & $hsay "    $l" }
    foreach ($l in (Get-GuestOutput -VmName $sec.vmName -DomainName $dom -Block $secContentBlock -ArgList @($PackageId) -Tag 'sec-content-after')) { & $hsay "    SEC $l" }
    # Without this the failure path only knows THAT it did not work. The PkgServers row says whether
    # RefreshNow even reached it: UpdateMask/LastRefresh unchanged means the write never landed here.
    foreach ($l in (Get-GuestOutput -VmName $parent.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($parent.siteCode, $PackageId) -Tag 'parent-db-after')) { & $hsay "    PARENT-DB-AFTER $l" }

    if ($tClear) {
        & $hsay "RESULT: $secShort reached Installed $([int]($tClear - $tFix).TotalSeconds)s after RefreshNow, having not moved during a ${BaselineSeconds}s baseline."
        & $hsay 'ONE TRIAL. If it reproduces, this is the rung to add to $ensureClientPkgCoverage (InstallBoundaryGroups.ps1).'
    }
    else {
        & $hsay "RESULT: still not Installed ${PostSeconds}s after RefreshNow."
        & $hsay 'That matches phase8-clientpkg-coverage-secondary-inactive.md: RefreshNow acts on the PARENT targeting rows and does not drive the send-to-child path. Do NOT ship a rung that cannot work -- check PKGLIB/INBOX above and the link state instead.'
    }
    Write-Host "Hop log: $hopLog" -ForegroundColor Green
    return
}

if ($ProveWedgeFix) {
    $pwLog = Join-Path $logsRoot ("prove-wedge-fix-{0}.log" -f $stamp)
    $psay = {
        param($t)
        $l = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $t
        Write-Host $l -ForegroundColor Gray
        try { Add-Content -LiteralPath $pwLog -Value $l -Encoding utf8 -ErrorAction Stop } catch { }
    }
    & $psay "log -> $pwLog"
    if ($secList.Count -ne 1) { & $psay "ABORT: need exactly one Secondary; got $($secList.Count). NOT A RESULT."; return }
    $sec = $secList[0]
    $parent = @($priList | Where-Object { $_.siteCode -eq $sec.parentSiteCode }) | Select-Object -First 1
    if (-not $parent) { & $psay "ABORT: no parent primary for $($sec.vmName). NOT A RESULT."; return }

    if (-not $PackageId) {
        $cand = @(Get-GuestOutput -VmName $cas.vmName -DomainName $dom -Block $pkgFindBlock -ArgList @($cas.siteCode) -Tag 'find-clientpkg')
        $ids = @($cand | Where-Object { $_ -match '^[A-Z0-9]{8} ' })
        if ($ids.Count -ne 1) { & $psay 'ABORT: could not resolve the client package. Re-run with -PackageId. NOT A RESULT.'; return }
        $PackageId = $ids[0].Split(' ')[0]
    }
    & $psay "package=$PackageId  parent=$($parent.vmName)/$($parent.siteCode)  secondary=$($sec.vmName)/$($sec.siteCode)"

    $readWedge = {
        $lines = @(Get-GuestOutput -VmName $parent.vmName -DomainName $dom -Block $wedgeStateBlock -ArgList @($PackageId, $sec.siteCode) -Tag 'wedge')
        $row = @($lines | Where-Object { $_ -like 'WEDGE *' }) | Select-Object -First 1
        $exec = @($lines | Where-Object { $_ -like 'EXEC *' }) | Select-Object -First 1
        $num = {
            param($t, $k)
            if ("$t" -match ($k + '=(-?\d+)')) { [int]$Matches[1] } else { $null }
        }
        [pscustomobject]@{
            Readable    = ($row -and $row -notlike '*UNREADABLE*')
            Wedged      = ("$row" -match 'wedged=True')
            Aborts      = (& $num $row 'aborts')
            LastAbort   = (& $num $row 'lastAbort')
            LastSend    = (& $num $row 'lastSend')
            LastPkgSend = (& $num $row 'lastPkgSend')
            ExecPid     = (& $num $exec 'pid')
            Lines       = $lines
        }
    }

    $pre = & $readWedge
    foreach ($l in $pre.Lines) { & $psay "    $l" }
    if (-not $pre.Readable) { & $psay 'ABORT: distmgr.log was NOT read. Instrument failure, NOT evidence. NOT A RESULT.'; return }
    if (-not $pre.Wedged) { & $psay "ABORT: the parent does not read WEDGED (aborts=$($pre.Aborts), lastAbort=$($pre.LastAbort), lastSend=$($pre.LastSend)). There is nothing to test. NOT A RESULT."; return }
    & $psay "precondition met: WEDGED on the same predicate InstallBoundaryGroups.ps1 ships."

    $dpPre = & $readSecState $sec $parent
    foreach ($l in $dpPre.Lines) { & $psay "    $l" }
    if ($dpPre.Installed) { & $psay "ABORT: $($sec.vmName) already reads Installed for $PackageId. NOT A RESULT."; return }

    & $psay ''
    & $psay "BASELINE: ${BaselineSeconds}s with NO intervention."
    $tBase = Get-Date
    $movedInBaseline = $false
    while (((Get-Date) - $tBase).TotalSeconds -lt $BaselineSeconds) {
        Start-Sleep -Seconds 30
        $b = & $readWedge
        if ($b.Readable -and ($b.LastSend -gt $pre.LastSend -or -not $b.Wedged)) { $movedInBaseline = $true; break }
        if ((& $readSecState $sec $parent).Installed) { $movedInBaseline = $true; break }
    }
    if ($movedInBaseline) {
        & $psay "MOVED DURING BASELINE after $([int]((Get-Date) - $tBase).TotalSeconds)s, with no intervention."
        & $psay 'THE RESTART WAS NOT TESTED. This says the site was recovering on its own, nothing more.'
        Write-Host "Proof log: $pwLog" -ForegroundColor Green
        return
    }
    & $psay "baseline done: ${BaselineSeconds}s, still wedged, no send, DP not Installed."

    & $psay ''
    $tFix = Get-Date
    foreach ($l in (Get-GuestOutput -VmName $parent.vmName -DomainName $dom -Block $execRestartBlock -ArgList @() -Tag 'exec-restart')) { & $psay "    $l" }
    $post0 = & $readWedge
    if (-not $post0.Readable -or -not $post0.ExecPid -or $post0.ExecPid -eq $pre.ExecPid) {
        & $psay "VOID: SMS_EXECUTIVE pid did not change ($($pre.ExecPid) -> $($post0.ExecPid)). Only a fresh process clears the flag, so this trial decides NOTHING."
        Write-Host "Proof log: $pwLog" -ForegroundColor Green
        return
    }
    & $psay "process replaced: pid $($pre.ExecPid) -> $($post0.ExecPid). The flag should now be clear."
    # Short on purpose. This phase only answers "did the restart alone resume work already queued",
    # which distmgr does within seconds of picking up an inbox file. The 900s the first run spent
    # here bought nothing: with no queued work the signal can never appear, however long you wait.
    & $psay "watching ${PassiveSeconds}s for work the restart alone resumes."

    # Mutable state in a hashtable: a scriptblock that did `$sawSend = $true` would write to its own
    # child scope and the result would be lost, which is the same trap as += inside Where-Object.
    $st = @{ SawSend = $false; SawPkgSend = $false; Installed = $false; Aborts = $pre.Aborts }
    $watch = {
        param($Seconds)
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
            Start-Sleep -Seconds 20
            $w = & $readWedge
            if (-not $w.Readable) { continue }
            # Compare indexes only WITHIN one read: the tail window slides, so an index from an
            # earlier read is not comparable. Measured: lastAbort moved 3991 -> 3645 with no new
            # aborts at all, purely from the window sliding.
            if ($w.LastSend -gt $w.LastAbort) { $st.SawSend = $true }
            if ($w.LastPkgSend -gt $w.LastAbort) { $st.SawPkgSend = $true }
            $st.Aborts = $w.Aborts
            # A new abort is as decisive as a send. Polling on after either one only burns clock --
            # the first run spent 908s to learn something the first 60s could have told it.
            if ($st.SawSend -or $st.SawPkgSend -or $st.Aborts -gt $pre.Aborts) { return }
            if ((& $readSecState $sec $parent).Installed) { $st.Installed = $true; return }
        }
    }
    & $watch $PassiveSeconds

    # Nothing was exercised, so nothing has been decided. Force an attempt rather than reporting a
    # non-result: the stranded package alone will never trigger one.
    $stimulated = $false
    if (-not ($st.SawSend -or $st.SawPkgSend -or $st.Installed) -and $st.Aborts -le $pre.Aborts) {
        & $psay ''
        & $psay "STIMULUS (pre-registered): the passive window exercised nothing. Bumping SourceVersion on $PackageId at $($cas.vmName)/$($cas.siteCode) so a bundle MUST be attempted. Still wedged emits a new 0x800704d3; cured emits a send."
        $stim = @(Get-GuestOutput -VmName $cas.vmName -DomainName $dom -Block $refreshPkgSourceBlock -ArgList @($cas.siteCode, $PackageId) -Tag 'refresh-pkgsource')
        foreach ($l in $stim) { & $psay "    $l" }
        # VOID only when the CALL failed. Whether the server moved SourceVersion is not the gate --
        # distmgr moves that column and distmgr is what is under test.
        if (@($stim | Where-Object { $_ -match 'REFRESHPKG ISSUED' }).Count -eq 0) {
            & $psay 'VOID: neither RefreshPkgSource nor RefreshPkgSourceFlag could be issued, so no bundle attempt was forced. This trial decides NOTHING.'
            Write-Host "Proof log: $pwLog" -ForegroundColor Green
            return
        }
        $stimulated = $true
        & $psay "stimulus landed; watching a further ${StimulusSeconds}s."
        & $watch $StimulusSeconds
    }

    $sawSend = $st.SawSend; $sawPkgSend = $st.SawPkgSend; $installed = $st.Installed; $newAborts = $st.Aborts
    $post = & $readWedge
    foreach ($l in $post.Lines) { & $psay "    $l" }
    foreach ($l in (Get-GuestOutput -VmName $sec.vmName -DomainName $dom -Block $secContentBlock -ArgList @($PackageId) -Tag 'sec-after')) { & $psay "    SEC $l" }
    $dpPost = & $readSecState $sec $parent
    foreach ($l in $dpPost.Lines) { & $psay "    $l" }

    & $psay ''
    $elapsed = [int]((Get-Date) - $tFix).TotalSeconds
    if ($dpPost.Installed -or $installed) {
        & $psay "RESULT: CURED + PACKAGE INSTALLED. $($sec.vmName) reached Installed ${elapsed}s after the restart, having not moved during a ${BaselineSeconds}s baseline."
        & $psay 'ACTION: the gate in InstallBoundaryGroups.ps1 (060c30cb) is right and sufficient. Nothing further to fix.'
    }
    elseif ($sawPkgSend -or $post.LastPkgSend -gt $post.LastAbort) {
        & $psay "RESULT: CURED + PACKAGE SENT, summarizer not yet Installed after ${elapsed}s. The parent did emit 'Created minijob to send compressed copy of package $PackageId to site $($sec.siteCode)'."
        & $psay 'ACTION: the wedge fix works and this package is moving. Re-check the summarizer before concluding anything about the DP; content transfer is downstream of the send.'
    }
    elseif ($sawSend -or $post.LastSend -gt $post.LastAbort) {
        & $psay "RESULT: CURED, PACKAGE STILL STRANDED. Real sends resumed after the restart, but $PackageId never went to $($sec.siteCode) in ${elapsed}s."
        & $psay 'ACTION: the wedge fix works. The stranded package is the SEPARATE defect -- distmgr.cpp:17252 skips its auto-recovery for exactly 0x800704D3, so this send was never re-armed and IsPkgSendingNeeded still declines. The remaining fix must move the package source version; RefreshNow cannot.'
    }
    elseif ($post.Wedged -and $newAborts -gt $pre.Aborts) {
        & $psay "RESULT: NOT CURED. Still wedged ${elapsed}s after a confirmed process replacement, and aborts went $($pre.Aborts) -> $newAborts$(if ($stimulated) { ' under a forced bundle attempt' })."
        & $psay 'ACTION: the SMS_EXECUTIVE restart is NOT the cure. Do NOT keep 060c30cb as-is -- a wider gate then restarts the service more often for no benefit. Reconsider both the gate and the claim in the InstallBoundaryGroups.ps1 comment.'
    }
    elseif ($stimulated) {
        & $psay "RESULT: NO CONTENT ACTIVITY AT ALL. SourceVersion was bumped and ${elapsed}s later distmgr has emitted neither a send nor a new abort."
        & $psay 'ACTION: this is not about the cancel flag -- distmgr is not processing the package at all. Look upstream of the send decision (is the version change replicating to the parent, is the package targeted at the secondary) before touching the wedge gate.'
    }
    else {
        & $psay "RESULT: INCONCLUSIVE after ${elapsed}s -- no send newer than the last abort, no new abort, DP not Installed, and the stimulus did not run."
        & $psay 'ACTION: re-run. Do NOT record this as either a pass or a failure.'
    }
    Write-Host "Proof log: $pwLog" -ForegroundColor Green
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
        if ($ExpectPrimaries -gt 0) { & $say "  also waiting for the child-primary count to reach $ExpectPrimaries (currently $($priList.Count))" }
        while (((Get-Date) -lt $armDeadline) -and (($armed.Count -lt $needArm.Count) -or ($ExpectPrimaries -gt 0 -and $priList.Count -lt $ExpectPrimaries))) {
            $armCycle++
            # Get-List is read ONCE at launch, so a primary that does not exist yet can never join the
            # watch. Re-read it here or starting before the new site is created silently watches only
            # the old ones -- which is exactly what a run against an in-progress add-primary did.
            if ($ExpectPrimaries -gt 0) {
                $allVms = @(Get-List -Type VM -SmartUpdate)
                if ($Domain) { $allVms = @($allVms | Where-Object { $_.domain -eq $Domain }) }
                $fresh = @($allVms | Where-Object { $_.role -eq 'Primary' -and $_.domain -eq $dom -and $_.parentSiteCode -eq $cas.siteCode })
                if ($PrimaryName) { $fresh = @($fresh | Where-Object { $_.vmName -eq $PrimaryName }) }
                foreach ($f in $fresh) {
                    if ($priList.vmName -contains $f.vmName) { continue }
                    $priList += $f
                    $needArm += $f
                    & $say "  NEW child primary appeared: $($f.vmName) (site $($f.siteCode)) -- added to the watch"
                }
            }
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
            if ($armed.Count -lt $needArm.Count -or ($ExpectPrimaries -gt 0 -and $priList.Count -lt $ExpectPrimaries)) { Start-Sleep -Seconds 60 }
        }
        if ($ExpectPrimaries -gt 0 -and $priList.Count -lt $ExpectPrimaries) {
            & $say "NOT ARMED within ${ArmWaitMinutes}m: only $($priList.Count) of $ExpectPrimaries child primaries ever appeared. Nothing was watched."
            return
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
    $lastStallSnap = $null
    $t0 = Get-Date
    $deadline = $t0.AddMinutes($MaxMinutes)

    while ((Get-Date) -lt $deadline -and $pending.Count -gt 0) {
        # sys.dm_exec_requests, the blocking chain and the queue depths only exist WHILE the stall is
        # happening; a snapshot taken afterwards shows a healthy site and explains nothing. The
        # per-package poll below cannot carry them because it runs the PkgId mode of the same block.
        if ($StallSnapshotEverySeconds -gt 0 -and (-not $lastStallSnap -or ((Get-Date) - $lastStallSnap).TotalSeconds -ge $StallSnapshotEverySeconds)) {
            $lastStallSnap = Get-Date
            foreach ($w in $watchSites) {
                & $say "--- stall snapshot $($w.SiteCode) ---"
                foreach ($l in (Get-GuestOutput -VmName $w.SqlVm.vmName -DomainName $dom -Block $sqlSnapBlock -ArgList @($w.SiteCode) -Tag "stall-$($w.SiteCode)")) { & $say "    $($w.Tag) $l" }
            }
        }
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
            $snap = Invoke-Command -Session $sqlSession -ScriptBlock $sqlSnapBlock -ArgumentList $vm.siteCode, $PackageId
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
