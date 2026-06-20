<#
.SYNOPSIS
    Detects and (optionally) breaks the CAS<->Primary DRS "Publisher not active" wedge in Phase 8 by
    force-sending the primary's pending GLOBAL replication changes (incl. its ServerData SiteStatus row)
    to the CAS via the supported spDRSSendChangesForGroup sproc. Collects before/after state, monitors
    whether it worked, and writes a full report into logs\drs-investigation\.

    CONFIG-DRIVEN: resolves the CAS, the child Primary, and each site's SQL host (honoring remoteSQLVM)
    from Get-List, and connects with Get-VmSession (PowerShell Direct, credential-managed). Works for any
    lab - no hardcoded VM names or domains. Handles remote-SQL primaries (e.g. CST-PRISITE -> CST-PRISQL).

.DESCRIPTION
    Background (proven via tools\Get-DrsLogs.ps1 capture + ConfigMgr source review): the primary flips its
    own ServerData.SiteStatus to 125 (ReplicationActive) ~10 min after install, but the CAS reads the
    primary's status from its OWN replicated copy of ServerData (ReplicationConfigurationAndMonitoring.cs
    builds SiteData from the LOCAL db). Until DRS delivers that row, the CAS logs "Publisher <PRI> is not
    active" and won't request site data, so the link sits NotStarted ~50 min while both sides idle.
    Force-sending the primary's pending global changes (spDRSSendChangesForGroup over every global
    replication group) flushes the row; the CAS applies it within a Service-Broker drain and unblocks on
    its next 60s RCM cycle.

    DETECTION (only acts when genuinely wedged, never mid-sync):
      - Primary local ServerData.SiteStatus must be 125; if 115/120 it's still applying its snapshot -> abort.
      - CAS copy of the primary's status must be < 125; if already 125 the link recovered -> nothing to do.
      - Defers if a DRS send is currently in-flight on the primary (LastSendStartTime > LastSendEndTime).
      - Re-samples after -StabilizeSeconds and aborts if the CAS copy advanced to 125 on its own.
      - -Force bypasses gates; -DetectOnly reports the decision without sending.

    SAFETY: the only write is the supported spDRSSendChangesForGroup sproc (no-op when no pending changes;
    guarded against concurrent runs via context_info). No service restarts, no re-init, no row edits.

    LIMITATIONS: if the CM site DB is on a SQL Availability Group, this connects to the resolved remoteSQLVM
    node directly; if that node is not the primary replica the sproc will fail (connect to the AG listener
    instead). cstest8-a uses a single remote SQL VM, not an AG, so this is fine there.

.PARAMETER Domain        Domain FQDN to scope to (e.g. cstest8.com). Auto-detected if only one CAS hierarchy exists.
.PARAMETER PrimaryName   Specific child-primary VM name when a CAS has more than one.
.PARAMETER StabilizeSeconds  Re-sample gap to confirm the wedge is stable before acting (default 90).
.PARAMETER MaxWaitMinutes    How long to monitor for recovery after the force-send (default 15).
.PARAMETER PollSeconds       Poll interval while monitoring (default 20).
.PARAMETER Force         Skip detection gates and force-send anyway.
.PARAMETER DetectOnly    Collect + report state and the run/skip decision, but do NOT send.

.EXAMPLE
    cd C:\memlabs\vmbuild\tools ; .\Force-DrsResync.ps1
.EXAMPLE
    .\Force-DrsResync.ps1 -Domain cstest8.com -DetectOnly
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string]$PrimaryName,
    [int]$StabilizeSeconds = 90,
    [int]$MaxWaitMinutes = 15,
    [int]$PollSeconds = 20,
    [switch]$Force,
    [switch]$DetectOnly
)

$ErrorActionPreference = 'Stop'

# ---- locate roots; this script lives in vmbuild\tools, Common.ps1 is in vmbuild ----
$scriptRoot = $PSScriptRoot
$vmbuildRoot = Split-Path -Parent $scriptRoot
Set-Location $vmbuildRoot

# ---- BOM check + dot-source Common.ps1 (host-tool pattern; gives Get-List / Get-VmSession / $Common) ----
$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
$bom = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM (PS5.1 parse hazard). Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Red
    exit 1
}
. $commonPath -InJob

# ---- report setup ----
$destRoot = Join-Path $vmbuildRoot 'logs\drs-investigation'
New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $destRoot "Force-DrsResync-$stamp.txt"
$script:report = New-Object System.Collections.Generic.List[string]
function Say { param([string]$Text, [string]$Color = 'Gray') Write-Host $Text -ForegroundColor $Color; $script:report.Add($Text) }
function SaveReport { Set-Content -Path $reportPath -Value $script:report -Encoding utf8 }

$statusName = @{ 100 = 'SiteInstalling'; 105 = 'SiteInstallationComplete'; 110 = 'ReplicationInactive'; 115 = 'ReplicationInitializing'; 120 = 'ReplicationMaintenance'; 125 = 'ReplicationActive' }
function StatusText { param($v) if ($null -eq $v) { return 'unknown' } if ($statusName.ContainsKey([int]$v)) { return ("{0} ({1})" -f [int]$v, $statusName[[int]$v]) } return "$v" }

# ---- in-guest SQL helpers (run against localhost on the resolved SQL VM) ----
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
function GuestSql {
    param($Session, $Db, $Query)
    # PS remoting can return an empty result set as a single deserialized empty-collection object that
    # doesn't unroll (so @() would count it as 1 phantom row). Real rows and the __error row are
    # PSCustomObjects carrying NoteProperty columns; the artifact has none - so keep only note-property rows.
    $res = Invoke-Command -Session $Session -ScriptBlock $sqlQueryBlock -ArgumentList $Db, $Query
    return @($res | Where-Object { ($null -ne $_) -and (@($_.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' }).Count -gt 0) })
}
function GuestExec { param($Session, $Db, $Query) return Invoke-Command -Session $Session -ScriptBlock $sqlExecBlock -ArgumentList $Db, $Query }
function ResolveCmDb {
    param($Session, $SiteCode)
    $guess = "CM_$SiteCode"
    $chk = GuestSql -Session $Session -Db 'master' -Query "SELECT name AS db FROM sys.databases WHERE name = '$guess'"
    foreach ($row in $chk) { if (($row.PSObject.Properties.Name -contains 'db') -and ($row.db -eq $guess)) { return $guess } }
    $any = GuestSql -Session $Session -Db 'master' -Query "SELECT TOP 1 name AS db FROM sys.databases WHERE name LIKE 'CM[_]%' ORDER BY name"
    if ($any.Count -gt 0 -and ($any[0].PSObject.Properties.Name -contains 'db')) { return $any[0].db }
    return $null
}
function StatusForSite {
    param($Session, $Db, $SiteCode)
    $rows = @(GuestSql -Session $Session -Db $Db -Query "SELECT SiteCode, SiteStatus FROM ServerData")
    foreach ($row in $rows) {
        if (($row.PSObject.Properties.Name -contains 'SiteCode') -and ("$($row.SiteCode)".Trim() -eq $SiteCode)) { return [int]$row.SiteStatus }
    }
    return $null
}
function Get-SqlError {
    param($Rows)
    foreach ($row in $Rows) { if ($row.PSObject.Properties.Name -contains '__error') { return $row.__error } }
    return $null
}
function Read-ServerData {
    param($Session, $Db)
    $rows = @(GuestSql -Session $Session -Db $Db -Query "SELECT SiteCode, SiteStatus FROM ServerData")
    $err = Get-SqlError -Rows $rows
    $real = @($rows | Where-Object { $_.PSObject.Properties.Name -notcontains '__error' })
    return [pscustomobject]@{ Rows = $real; Error = $err }
}
function StatusFromRows {
    param($Rows, $SiteCode)
    foreach ($row in $Rows) {
        if (($row.PSObject.Properties.Name -contains 'SiteCode') -and ("$($row.SiteCode)".Trim() -eq $SiteCode)) { return [int]$row.SiteStatus }
    }
    return $null
}
function ConvertTo-DateOrNull {
    param($v)
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { return $v }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$v, [ref]$d)) { return $d }
    return $null
}
function DumpServerRows {
    param($Label, $Rows)
    foreach ($row in $Rows) {
        $sc = if ($row.PSObject.Properties.Name -contains 'SiteCode') { "$($row.SiteCode)".Trim() } else { '?' }
        $ss = if ($row.PSObject.Properties.Name -contains 'SiteStatus') { StatusText $row.SiteStatus } else { '?' }
        Say ("   $Label ServerData row: SiteCode=$sc  SiteStatus=$ss") 'DarkGray'
    }
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

# ---- resolve topology from Get-List (honor remoteSQLVM) ----
function Resolve-SqlVm {
    param($SiteVm, $AllVms)
    if ([string]::IsNullOrWhiteSpace($SiteVm.remoteSQLVM)) { return $SiteVm }
    $r = @($AllVms | Where-Object { $_.domain -eq $SiteVm.domain -and $_.vmName -eq $SiteVm.remoteSQLVM })
    if ($r.Count -eq 0) { $r = @($AllVms | Where-Object { $_.domain -eq $SiteVm.domain -and ($_.vmName -like "*$($SiteVm.remoteSQLVM)") }) }
    if ($r.Count -gt 0) { return $r[0] }
    return $SiteVm
}

Say "================ Force-DrsResync  $stamp ================" 'Cyan'
$allVms = @(Get-List -Type VM -SmartUpdate)
if ($Domain) { $allVms = @($allVms | Where-Object { $_.domain -eq $Domain }) }

$casList = @($allVms | Where-Object { $_.role -eq 'CAS' })
if ($casList.Count -eq 0) { Say "FATAL: no CAS found$(if ($Domain) { " in domain $Domain" }). This tool only applies to a CAS+Primary hierarchy." 'Red'; SaveReport; return }
$casDomains = @($casList | Select-Object -ExpandProperty domain -Unique)
if ($casDomains.Count -gt 1) { Say "FATAL: CAS found in multiple domains ($($casDomains -join ', ')). Re-run with -Domain." 'Red'; SaveReport; return }
$cas = $casList[0]
$dom = $cas.domain

$priList = @($allVms | Where-Object { $_.role -eq 'Primary' -and $_.domain -eq $dom -and $_.parentSiteCode -eq $cas.siteCode })
if ($priList.Count -eq 0) { Say "FATAL: no child Primary found under CAS $($cas.vmName) (site $($cas.siteCode)) in $dom." 'Red'; SaveReport; return }
if ($PrimaryName) { $priList = @($priList | Where-Object { $_.vmName -eq $PrimaryName }) }
if ($priList.Count -eq 0) { Say "FATAL: -PrimaryName '$PrimaryName' did not match a child primary." 'Red'; SaveReport; return }
if ($priList.Count -gt 1) { Say "FATAL: multiple child primaries ($($priList.vmName -join ', ')). Re-run with -PrimaryName <one>." 'Red'; SaveReport; return }
$pri = $priList[0]

$casSqlVm = Resolve-SqlVm -SiteVm $cas -AllVms $allVms
$priSqlVm = Resolve-SqlVm -SiteVm $pri -AllVms $allVms

Say "Domain     : $dom"
Say "CAS        : $($cas.vmName)  (site $($cas.siteCode))   SQL on: $($casSqlVm.vmName)"
Say "Primary    : $($pri.vmName)  (site $($pri.siteCode))   SQL on: $($priSqlVm.vmName)"
Say "StabilizeSeconds=$StabilizeSeconds  MaxWaitMinutes=$MaxWaitMinutes  Force=$Force  DetectOnly=$DetectOnly"
Say ""

# ---- sessions (Get-VmSession is credential-managed + cached; do NOT dispose) ----
$casSql = Get-VmSession -VmName $casSqlVm.vmName -VmDomainName $dom
$priSql = Get-VmSession -VmName $priSqlVm.vmName -VmDomainName $dom
$casLog = if ($cas.vmName -eq $casSqlVm.vmName) { $casSql } else { Get-VmSession -VmName $cas.vmName -VmDomainName $dom }
$priLog = if ($pri.vmName -eq $priSqlVm.vmName) { $priSql } else { Get-VmSession -VmName $pri.vmName -VmDomainName $dom }
if (-not $casSql -or -not $priSql -or -not $casLog -or -not $priLog) { Say "FATAL: could not open a PowerShell Direct session to one of the VMs (is it running?)." 'Red'; SaveReport; return }

$casDb = ResolveCmDb -Session $casSql -SiteCode $cas.siteCode
$priDb = ResolveCmDb -Session $priSql -SiteCode $pri.siteCode
if (-not $casDb -or -not $priDb) { Say "FATAL: could not resolve CM database (casDb=$casDb priDb=$priDb)." 'Red'; SaveReport; return }
Say "CAS DB: $casDb   Primary DB: $priDb"
Say ""

# ---- before-state ----
Say "---- BEFORE: ServerData.SiteStatus ----" 'Cyan'
$priServer = Read-ServerData -Session $priSql -Db $priDb
$casServer = Read-ServerData -Session $casSql -Db $casDb
if ($priServer.Error) { Say ("SQL ERROR reading ServerData on $($priSqlVm.vmName) ($priDb): {0}" -f $priServer.Error) 'Red' }
if ($casServer.Error) { Say ("SQL ERROR reading ServerData on $($casSqlVm.vmName) ($casDb): {0}" -f $casServer.Error) 'Red' }
$priLocal = StatusFromRows -Rows $priServer.Rows -SiteCode $pri.siteCode
$casCopy = StatusFromRows -Rows $casServer.Rows -SiteCode $pri.siteCode
Say ("Primary's own status (on $($priSqlVm.vmName), $priDb): {0}   [ServerData rows: {1}]" -f (StatusText $priLocal), $priServer.Rows.Count)
Say ("CAS's copy of $($pri.siteCode) status (on $($casSqlVm.vmName), $casDb): {0}   [ServerData rows: {1}]" -f (StatusText $casCopy), $casServer.Rows.Count)
DumpServerRows 'PRI' $priServer.Rows
DumpServerRows 'CAS' $casServer.Rows

$gRows = @(GuestSql -Session $priSql -Db $priDb -Query "SELECT ReplicationGroup FROM ReplicationData WHERE ReplicationPattern='global' ORDER BY ReplicationGroup")
$gErr = Get-SqlError -Rows $gRows
if ($gErr) { Say ("SQL ERROR reading ReplicationData on $($priSqlVm.vmName) ($priDb): {0}" -f $gErr) 'Red' }
$globalGroups = @()
foreach ($g in $gRows) { if ($g.PSObject.Properties.Name -contains 'ReplicationGroup') { $globalGroups += "$($g.ReplicationGroup)" } }
Say ("Primary global replication groups: {0}" -f $globalGroups.Count)
$inflight = @(GuestSql -Session $priSql -Db $priDb -Query "SELECT ReplicationGroup, LastSendStartTime, LastSendEndTime FROM DRS_MessageActivity_Send WHERE LastSendStartTime IS NOT NULL AND (LastSendEndTime IS NULL OR LastSendStartTime > LastSendEndTime)")
$ifErr = Get-SqlError -Rows $inflight
if ($ifErr) { Say ("SQL ERROR reading DRS_MessageActivity_Send on $($priSqlVm.vmName) ($priDb): {0}" -f $ifErr) 'Red' }
# Only count a row as genuinely in-flight when the start time is a real date and the end is either
# unset or earlier than the start. A row with empty/NULL timestamps is NOT a live send (was a false defer).
$inflightReal = @($inflight | Where-Object { $_.PSObject.Properties.Name -notcontains '__error' } | ForEach-Object {
        $s = ConvertTo-DateOrNull $_.LastSendStartTime
        $e = ConvertTo-DateOrNull $_.LastSendEndTime
        if (($null -ne $s) -and (($null -eq $e) -or ($s -gt $e))) { $_ }
    })
Say ("Primary sends currently in-flight: {0}" -f $inflightReal.Count)
foreach ($x in $inflightReal) { Say ("   in-flight: {0}  start={1} end={2}" -f $x.ReplicationGroup, $x.LastSendStartTime, $x.LastSendEndTime) }
Say ""

# ---- detection ----
Say "---- DETECTION ----" 'Cyan'
$wedged = $false
$reason = ''
if ($priServer.Error) { $reason = "Could not read the primary's ServerData (SQL error above) on $($priSqlVm.vmName) - cannot safely decide. Fix SQL access / DB state and re-run." }
elseif ($priServer.Rows.Count -eq 0 -and $globalGroups.Count -eq 0) { $reason = "DRS is not initialized on the primary yet: ServerData has 0 rows and there are no global replication groups. This primary is still early in its deploy (hasn't joined the CAS / configured replication). Too early to resync - re-run once the link is forming." }
elseif ($null -eq $priLocal) { $reason = "Primary ServerData has $($priServer.Rows.Count) row(s) but none for site $($pri.siteCode); cannot read its own status yet. Re-run shortly." }
elseif ($priLocal -lt 125) { $reason = "Primary is $($statusName[$priLocal]) (not yet ReplicationActive=125): still applying its global snapshot. Not wedged - a real sync is in progress." }
elseif ($null -ne $casCopy -and $casCopy -ge 125) { $reason = "CAS already sees the primary as ReplicationActive (status $casCopy). The link has recovered. Nothing to do." }
else { $wedged = $true; $reason = "Primary is ReplicationActive (125) but the CAS's copy is $(StatusText $casCopy) (< 125). This is the stale-status wedge." }
Say $reason ($(if ($wedged) { 'Yellow' } else { 'Green' }))

if ($inflightReal.Count -gt 0 -and -not $Force) { $wedged = $false; Say "A DRS send is in-flight on the primary -> deferring (a sync IS happening). Re-run after it settles, or use -Force." 'Yellow' }

if (-not $wedged -and -not $Force) { Say ""; Say "DECISION: not running (not wedged / sync in progress / already recovered). Use -Force to override." 'Green'; SaveReport; Say "`nReport: $reportPath" 'Green'; return }
if ($DetectOnly) { Say ""; Say ("DECISION (DetectOnly): would force-send {0} global group(s) on {1}." -f $globalGroups.Count, $priSqlVm.vmName) 'Yellow'; SaveReport; Say "`nReport: $reportPath" 'Green'; return }

# ---- stabilize ----
if (-not $Force) {
    Say ""
    Say "Confirming the wedge is stable (waiting $StabilizeSeconds s, then re-sampling)..." 'Yellow'
    Start-Sleep -Seconds $StabilizeSeconds
    $casCopy2 = StatusForSite -Session $casSql -Db $casDb -SiteCode $pri.siteCode
    Say ("CAS copy of $($pri.siteCode) after stabilize: {0}" -f (StatusText $casCopy2))
    if ($null -ne $casCopy2 -and $casCopy2 -ge 125) { Say "DECISION: recovered on its own during the stabilize window (normal propagation). Not sending." 'Green'; SaveReport; Say "`nReport: $reportPath" 'Green'; return }
}

# ---- rcm tails before ----
Say ""
Say "---- rcmctrl tail BEFORE force-send ----" 'DarkGray'
Say "[CAS] last lines:"; foreach ($l in (TailRcm -Session $casLog -Lines 12)) { $script:report.Add("  $l") }
Say "[Primary] last lines:"; foreach ($l in (TailRcm -Session $priLog -Lines 8)) { $script:report.Add("  $l") }

# ---- ACTION ----
Say ""
Say "---- FORCING SEND: spDRSSendChangesForGroup over $($globalGroups.Count) global group(s) on $($priSqlVm.vmName) ----" 'Cyan'
$sent = 0; $failed = 0
foreach ($grp in $globalGroups) {
    $safe = $grp.Replace("'", "''")
    $res = GuestExec -Session $priSql -Db $priDb -Query "EXEC dbo.spDRSSendChangesForGroup @ReplicationGroup = N'$safe'"
    if ($res.Error) { $failed++; Say ("  FAIL  {0}: {1}" -f $grp, $res.Error) 'Red' }
    else { $sent++; $note = ''; if ($res.Messages) { $note = " [$($res.Messages)]" }; Say ("  sent  {0}{1}" -f $grp, $note) }
}
Say ("Force-send complete: {0} ok, {1} failed." -f $sent, $failed)

# ---- MONITOR ----
Say ""
Say "---- MONITORING the CAS for recovery (up to $MaxWaitMinutes min) ----" 'Cyan'
$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
$recovered = $false
$tStart = Get-Date
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollSeconds
    $cur = StatusForSite -Session $casSql -Db $casDb -SiteCode $pri.siteCode
    $elapsed = [int]((Get-Date) - $tStart).TotalSeconds
    Say ("  +{0,4}s  CAS copy of $($pri.siteCode) = {1}" -f $elapsed, (StatusText $cur))
    if ($null -ne $cur -and $cur -ge 125) { $recovered = $true; break }
}

Say ""
if ($recovered) {
    $secs = [int]((Get-Date) - $tStart).TotalSeconds
    Say ("RESULT: SUCCESS - CAS now sees $($pri.siteCode) as ReplicationActive ~{0}s after the force-send." -f $secs) 'Green'
    Say "Confirms the diagnosis (stale ServerData status row) AND that force-send is a valid fix to wire into Phase 8."
}
else {
    Say ("RESULT: NOT recovered within {0} min. The CAS still does not see the primary active." -f $MaxWaitMinutes) 'Red'
    Say "Means the change wasn't built/sent (look at spDRSMsgBuilderActivation / Service Broker), not just a propagation delay."
}

Say ""
Say "---- rcmctrl tail AFTER ----" 'DarkGray'
Say "[CAS] last lines:"; foreach ($l in (TailRcm -Session $casLog -Lines 14)) { $script:report.Add("  $l") }
Say "[Primary] last lines:"; foreach ($l in (TailRcm -Session $priLog -Lines 8)) { $script:report.Add("  $l") }

SaveReport
Write-Host ""
Write-Host "Full report written to: $reportPath" -ForegroundColor Green
Write-Host "Tell the agent to read it." -ForegroundColor Green
