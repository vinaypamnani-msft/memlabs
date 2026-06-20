<#
.SYNOPSIS
    Detects and (optionally) breaks the CAS<->Primary DRS "Publisher not active" wedge in Phase 8 by
    force-sending the primary's pending GLOBAL replication changes (incl. its ServerData SiteStatus row)
    to the CAS via the supported spDRSSendChangesForGroup sproc. Collects before/after state, monitors
    whether it worked, and writes a full report into logs\drs-investigation\.

.DESCRIPTION
    Background (proven via log capture + ConfigMgr source review):
      - The primary (e.g. PS1) flips its own ServerData.SiteStatus to 125 (ReplicationActive) ~10 min after
        install, but the CAS reads PS1's status from its OWN replicated copy of ServerData
        (ReplicationConfigurationAndMonitoring.cs builds SiteData from the LOCAL db). Until DRS delivers the
        updated row, the CAS logs "Publisher PS1 is not active" and refuses to request site data -> the link
        sits NotStarted for ~50 min even though both sides are idle.
      - Forcing the primary to send its pending global changes (spDRSSendChangesForGroup over every global
        replication group) flushes that ServerData row to the CAS, which applies it within a Service-Broker
        drain and unblocks the link on its next 60s RCM cycle.

    DETECTION (so it only runs when genuinely wedged, never while a real sync is in progress):
      - Primary local ServerData.SiteStatus MUST be 125 (ReplicationActive). If it's 115/120 the primary is
        still applying its global snapshot -> NOT wedged, this aborts (the send would be premature/useless).
      - CAS copy of the primary's ServerData.SiteStatus MUST be < 125 (stale "not active"). If it's already
        125 the link has recovered -> nothing to do.
      - The wedge must be STABLE: it re-samples after -StabilizeSeconds; if the CAS copy advanced to 125 on
        its own during that window, it was just the normal brief propagation and this aborts.
      - -Force bypasses all gates. -DetectOnly reports state and exits without sending.

    SAFETY: the only write is the supported spDRSSendChangesForGroup sproc (no-op when there are no pending
    changes, guarded against concurrent runs via context_info). No service restarts, no re-init, no schema
    or row edits. Everything else is read-only.

.PARAMETER CASVM        Hyper-V name of the CAS site server (default CT7-CS1SITE).
.PARAMETER PrimaryVM    Hyper-V name of the child Primary site server (default CT7-PS1SITE).
.PARAMETER Credential   Domain/local admin for PowerShell Direct (default user cstest7\admin; prompts).
.PARAMETER StabilizeSeconds  Re-sample gap to confirm the wedge is stable before acting (default 90).
.PARAMETER MaxWaitMinutes    How long to monitor for recovery after the force-send (default 15).
.PARAMETER PollSeconds       Poll interval while monitoring (default 20).
.PARAMETER Force         Skip detection gates and force-send anyway.
.PARAMETER DetectOnly    Collect + report state and the run/skip decision, but do NOT send.

.EXAMPLE
    .\Force-DrsResync.ps1
    # prompts for cstest7\admin, checks if wedged, and if so force-sends + monitors + reports.

.EXAMPLE
    .\Force-DrsResync.ps1 -DetectOnly
    # just tells you whether it's wedged and what it would do.
#>
[CmdletBinding()]
param(
    [string]$CASVM = 'CT7-CS1SITE',
    [string]$PrimaryVM = 'CT7-PS1SITE',
    [pscredential]$Credential,
    [int]$StabilizeSeconds = 90,
    [int]$MaxWaitMinutes = 15,
    [int]$PollSeconds = 20,
    [switch]$Force,
    [switch]$DetectOnly
)

$ErrorActionPreference = 'Stop'

# ---- output / report setup (logs live under vmbuild\logs; this script is in vmbuild\tools) ----
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$vmbuildRoot = Split-Path -Parent $scriptRoot
$destRoot = Join-Path $vmbuildRoot 'logs\drs-investigation'
New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $destRoot "Force-DrsResync-$stamp.txt"

$script:report = New-Object System.Collections.Generic.List[string]
function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $script:report.Add($Text)
}
function SaveReport { Set-Content -Path $reportPath -Value $script:report -Encoding utf8 }

$statusName = @{
    100 = 'SiteInstalling'; 105 = 'SiteInstallationComplete'; 110 = 'ReplicationInactive';
    115 = 'ReplicationInitializing'; 120 = 'ReplicationMaintenance'; 125 = 'ReplicationActive'
}
function StatusText { param($v) if ($null -eq $v) { return 'unknown' } if ($statusName.ContainsKey([int]$v)) { return ("{0} ({1})" -f [int]$v, $statusName[[int]$v]) } return "$v" }

if (-not $Credential) {
    $Credential = Get-Credential -UserName 'cstest7\admin' -Message 'Admin for the CAS/Primary guests (PowerShell Direct)'
}

# ---- in-guest SQL helpers (run against localhost CM_<site> over PowerShell Direct) ----
$sqlQueryBlock = {
    param($db, $q)
    $rows = @()
    try {
        $cs = "Server=localhost;Initial Catalog=$db;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $cn.Open()
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $q; $cmd.CommandTimeout = 90
        $r = $cmd.ExecuteReader()
        while ($r.Read()) {
            $o = [ordered]@{}
            for ($i = 0; $i -lt $r.FieldCount; $i++) { $o[$r.GetName($i)] = $r.GetValue($i) }
            $rows += [pscustomobject]$o
        }
        $r.Close(); $cn.Close()
    }
    catch { $rows = @([pscustomobject]@{ __error = $_.Exception.Message }) }
    return , $rows
}
$sqlExecBlock = {
    param($db, $q)
    $msgs = New-Object System.Collections.Generic.List[string]
    $err = $null
    try {
        $cs = "Server=localhost;Initial Catalog=$db;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] { param($s, $e) foreach ($l in $e.Errors) { $msgs.Add($l.Message) } }
        $cn.add_InfoMessage($handler)
        $cn.Open()
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $q; $cmd.CommandTimeout = 120
        [void]$cmd.ExecuteNonQuery()
        $cn.Close()
    }
    catch { $err = $_.Exception.Message }
    return [pscustomobject]@{ Messages = ($msgs -join '; '); Error = $err }
}
function GuestSql { param($Session, $Db, $Query) return @(Invoke-Command -Session $Session -ScriptBlock $sqlQueryBlock -ArgumentList $Db, $Query) }
function GuestExec { param($Session, $Db, $Query) return Invoke-Command -Session $Session -ScriptBlock $sqlExecBlock -ArgumentList $Db, $Query }

function ResolveCmDb {
    param($Session)
    $r = GuestSql -Session $Session -Db 'master' -Query "SELECT TOP 1 name AS db FROM sys.databases WHERE name LIKE 'CM[_]%' ORDER BY name"
    if ($r.Count -gt 0 -and $r[0].PSObject.Properties.Name -contains 'db') { return $r[0].db }
    return $null
}
function GetServerData {
    param($Session, $Db)
    return @(GuestSql -Session $Session -Db $Db -Query "SELECT SiteCode, SiteStatus, Name FROM ServerData")
}
function GetPrimaryStatusFor {
    param($Rows, $SiteCode)
    foreach ($row in $Rows) {
        if (($row.PSObject.Properties.Name -contains 'SiteCode') -and ("$($row.SiteCode)".Trim() -eq $SiteCode)) { return [int]$row.SiteStatus }
    }
    return $null
}
function TailRcm {
    param($Session, $Lines = 40)
    return Invoke-Command -Session $Session -ScriptBlock {
        param($n)
        $dir = $null
        try { $inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction Stop).'Installation Directory'; if ($inst) { $dir = Join-Path $inst 'Logs' } } catch {}
        if (-not $dir) { foreach ($c in @('E:\ConfigMgr\Logs', 'D:\Program Files\Microsoft Configuration Manager\Logs', 'C:\Program Files\Microsoft Configuration Manager\Logs')) { if (Test-Path $c) { $dir = $c; break } } }
        if (-not $dir) { return @('(rcmctrl.log not found)') }
        $f = Join-Path $dir 'rcmctrl.log'
        if (-not (Test-Path $f)) { return @('(rcmctrl.log not found)') }
        return Get-Content $f -Tail $n
    } -ArgumentList $Lines
}

# ===================================================================================================
Say "================ Force-DrsResync  $stamp ================" 'Cyan'
Say "CAS=$CASVM  Primary=$PrimaryVM  StabilizeSeconds=$StabilizeSeconds  MaxWaitMinutes=$MaxWaitMinutes  Force=$Force  DetectOnly=$DetectOnly"
Say ""

$casSession = $null; $priSession = $null
try {
    try { $priSession = New-PSSession -VMName $PrimaryVM -Credential $Credential -ErrorAction Stop }
    catch { Say "FATAL: cannot open PowerShell Direct to Primary $PrimaryVM : $($_.Exception.Message)" 'Red'; SaveReport; return }
    try { $casSession = New-PSSession -VMName $CASVM -Credential $Credential -ErrorAction Stop }
    catch { Say "FATAL: cannot open PowerShell Direct to CAS $CASVM : $($_.Exception.Message)" 'Red'; SaveReport; return }

    $priDb = ResolveCmDb -Session $priSession
    $casDb = ResolveCmDb -Session $casSession
    if (-not $priDb -or -not $casDb) { Say "FATAL: could not resolve CM_ database (priDb=$priDb casDb=$casDb)." 'Red'; SaveReport; return }
    Say "Primary CM db: $priDb   CAS CM db: $casDb"

    # site code of the primary (its own ThisSiteCode)
    $priSiteRows = GuestSql -Session $priSession -Db $priDb -Query "SELECT ThisSiteCode AS sc FROM SMSData"
    $casSiteRows = GuestSql -Session $casSession -Db $casDb -Query "SELECT ThisSiteCode AS sc FROM SMSData"
    $primarySite = if ($priSiteRows.Count -gt 0) { "$($priSiteRows[0].sc)".Trim() } else { $null }
    $casSite = if ($casSiteRows.Count -gt 0) { "$($casSiteRows[0].sc)".Trim() } else { $null }
    if (-not $primarySite) { Say "FATAL: could not resolve primary site code." 'Red'; SaveReport; return }
    Say "Primary site code: $primarySite   CAS site code: $casSite"
    Say ""

    # ---- collect before-state ----
    Say "---- BEFORE: ServerData.SiteStatus snapshots ----" 'Cyan'
    $priSdv = GetServerData -Session $priSession -Db $priDb
    $casSdv = GetServerData -Session $casSession -Db $casDb
    $priLocal = GetPrimaryStatusFor -Rows $priSdv -SiteCode $primarySite      # primary's view of itself
    $casCopy = GetPrimaryStatusFor -Rows $casSdv -SiteCode $primarySite       # CAS's replicated copy of primary
    Say ("Primary's own status (on {0}, db {1}) : {2}" -f $PrimaryVM, $priDb, (StatusText $priLocal))
    Say ("CAS's copy of {0}'s status (on {1})    : {2}" -f $primarySite, $CASVM, (StatusText $casCopy))

    # list global groups + any in-progress sends on the primary
    $globalGroups = @(GuestSql -Session $priSession -Db $priDb -Query "SELECT ReplicationGroup FROM ReplicationData WHERE ReplicationPattern='global' ORDER BY ReplicationGroup")
    $globalGroupNames = @()
    foreach ($g in $globalGroups) { if ($g.PSObject.Properties.Name -contains 'ReplicationGroup') { $globalGroupNames += "$($g.ReplicationGroup)" } }
    Say ("Primary global replication groups: {0}" -f $globalGroupNames.Count)
    $inflight = @(GuestSql -Session $priSession -Db $priDb -Query "SELECT ReplicationGroup, LastSendStartTime, LastSendEndTime FROM DRS_MessageActivity_Send WHERE LastSendStartTime > LastSendEndTime")
    $inflightReal = @($inflight | Where-Object { $_.PSObject.Properties.Name -notcontains '__error' })
    Say ("Primary sends currently in-flight (LastSendStartTime > LastSendEndTime): {0}" -f $inflightReal.Count)
    foreach ($x in $inflightReal) { Say ("   in-flight: {0}  start={1} end={2}" -f $x.ReplicationGroup, $x.LastSendStartTime, $x.LastSendEndTime) }
    Say ""

    # ---- detection ----
    Say "---- DETECTION ----" 'Cyan'
    $wedged = $false
    $reason = ''
    if ($null -eq $priLocal) {
        $reason = "Could not read primary's own SiteStatus; cannot safely decide."
    }
    elseif ($priLocal -lt 125) {
        $reason = "Primary is $($statusName[$priLocal]) (not yet ReplicationActive=125): it is STILL applying its global snapshot. Not wedged - a real sync is in progress. Forcing now would be premature."
    }
    elseif ($null -ne $casCopy -and $casCopy -ge 125) {
        $reason = "CAS already sees the primary as ReplicationActive (status $casCopy). The link has recovered. Nothing to do."
    }
    else {
        $wedged = $true
        $reason = "Primary is ReplicationActive (125) but the CAS's copy is $(StatusText $casCopy) (< 125). This is the stale-status wedge."
    }
    Say $reason ($(if ($wedged) { 'Yellow' } else { 'Green' }))

    if ($inflightReal.Count -gt 0 -and -not $Force) {
        $wedged = $false
        Say "A DRS send is currently in-flight on the primary -> deferring (a sync IS happening). Re-run after it settles, or use -Force." 'Yellow'
    }

    if (-not $wedged -and -not $Force) {
        Say ""
        Say "DECISION: not running (not wedged / sync in progress / already recovered). Use -Force to override." 'Green'
        SaveReport; Say "`nReport: $reportPath" 'Green'; return
    }

    if ($DetectOnly) {
        Say ""
        Say ("DECISION (DetectOnly): would {0} force-send {1} global group(s) on {2}." -f $(if ($Force) { 'FORCE' } else { 'wedged ->' }), $globalGroupNames.Count, $PrimaryVM) 'Yellow'
        SaveReport; Say "`nReport: $reportPath" 'Green'; return
    }

    # ---- stabilize: confirm the wedge didn't just self-resolve (skip under -Force) ----
    if (-not $Force) {
        Say ""
        Say "Confirming the wedge is stable (waiting $StabilizeSeconds s, then re-sampling)..." 'Yellow'
        Start-Sleep -Seconds $StabilizeSeconds
        $casCopy2 = GetPrimaryStatusFor -Rows (GetServerData -Session $casSession -Db $casDb) -SiteCode $primarySite
        Say ("CAS copy of {0} after stabilize: {1}" -f $primarySite, (StatusText $casCopy2))
        if ($null -ne $casCopy2 -and $casCopy2 -ge 125) {
            Say "DECISION: recovered on its own during the stabilize window (normal propagation). Not sending." 'Green'
            SaveReport; Say "`nReport: $reportPath" 'Green'; return
        }
    }

    # capture rcm tails before action
    Say ""
    Say "---- rcmctrl tail BEFORE force-send ----" 'DarkGray'
    Say "[CAS] last lines:"; foreach ($l in (TailRcm -Session $casSession -Lines 12)) { $script:report.Add("  $l") }
    Say "[Primary] last lines:"; foreach ($l in (TailRcm -Session $priSession -Lines 8)) { $script:report.Add("  $l") }

    # ---- ACTION: force-send every global group on the primary ----
    Say ""
    Say "---- FORCING SEND: spDRSSendChangesForGroup over $($globalGroupNames.Count) global group(s) on $PrimaryVM ----" 'Cyan'
    $sent = 0; $failed = 0
    foreach ($grp in $globalGroupNames) {
        $safe = $grp.Replace("'", "''")
        $res = GuestExec -Session $priSession -Db $priDb -Query "EXEC dbo.spDRSSendChangesForGroup @ReplicationGroup = N'$safe'"
        if ($res.Error) { $failed++; Say ("  FAIL  {0}: {1}" -f $grp, $res.Error) 'Red' }
        else { $sent++; $note = ''; if ($res.Messages) { $note = " [$($res.Messages)]" }; Say ("  sent  {0}{1}" -f $grp, $note) }
    }
    Say ("Force-send complete: {0} ok, {1} failed." -f $sent, $failed)

    # ---- MONITOR: poll the CAS copy of the primary's status until 125 or timeout ----
    Say ""
    Say "---- MONITORING the CAS for recovery (up to $MaxWaitMinutes min) ----" 'Cyan'
    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    $recovered = $false
    $tStart = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $cur = GetPrimaryStatusFor -Rows (GetServerData -Session $casSession -Db $casDb) -SiteCode $primarySite
        $elapsed = [int]((Get-Date) - $tStart).TotalSeconds
        Say ("  +{0,4}s  CAS copy of {1} = {2}" -f $elapsed, $primarySite, (StatusText $cur))
        if ($null -ne $cur -and $cur -ge 125) { $recovered = $true; break }
    }

    Say ""
    if ($recovered) {
        $secs = [int]((Get-Date) - $tStart).TotalSeconds
        Say ("RESULT: SUCCESS - CAS now sees {0} as ReplicationActive ~{1}s after the force-send." -f $primarySite, $secs) 'Green'
        Say "This confirms the diagnosis (stale ServerData status row) AND that force-send is a valid fix to wire into Phase 8."
    }
    else {
        Say ("RESULT: NOT recovered within {0} min. The CAS still does not see the primary active." -f $MaxWaitMinutes) 'Red'
        Say "Means the change wasn't built/sent (look at spDRSMsgBuilderActivation / Service Broker), not just a propagation delay."
    }

    # capture rcm tails after action
    Say ""
    Say "---- rcmctrl tail AFTER ----" 'DarkGray'
    Say "[CAS] last lines:"; foreach ($l in (TailRcm -Session $casSession -Lines 14)) { $script:report.Add("  $l") }
    Say "[Primary] last lines:"; foreach ($l in (TailRcm -Session $priSession -Lines 8)) { $script:report.Add("  $l") }
}
finally {
    if ($priSession) { Remove-PSSession $priSession }
    if ($casSession) { Remove-PSSession $casSession }
    SaveReport
    Write-Host ""
    Write-Host "Full report written to: $reportPath" -ForegroundColor Green
    Write-Host "Tell the agent to read it." -ForegroundColor Green
}
