<#
.SYNOPSIS
    Test harness for the ConfigMgr-accurate passive site-server failure detection +
    retry that InstallPassiveSiteServer.ps1's monitor now uses. Reads the SAME value
    the admin console reads to show "Installation failed", and (with -Retry) invokes
    the SAME WMI method the console's "Retry installation" / Set-CMSite uses.

.DESCRIPTION
    Run this ON THE ACTIVE site server / SMS Provider host (e.g. CS2-CS1SITE).
    Verified against the ConfigMgr source (Constants.cs, SiteSystems\Utils.cs
    retry-enable gate, and PowerShell\...\HS\SetSite.cs::RunRetryInstallationForPassiveSite):

      Failure detection -- the console reads ServerState on the passive site server's
      SMS_SCI_SysResUse row (RoleName='SMS Site Server', SiteSystemStatus=0):
        131071 0x0001FFFF SiteServerInstallationFailed -> "Installation failed"
        196607 0x0002FFFF PREREQ_ERROR                 -> prereq failed
        generic failure  : (ServerState % 65536) as 4-hex starts with 'F'
        0x0003xxxx        OK category (Active/Passive/Ready) -> healthy/complete
      (The SMS_HA_SiteServerDetailedMonitoring substage rows do NOT reliably mark
      failure -- ServerState is the authoritative signal.)

      Retry -- the console action and Set-CMSite both call the WMI method
        SMS_SCI_SysResUse.RetryInstallation(SiteCode, ServerName)
      where ServerName is NetworkOSPath with the leading \\ stripped.

    The script: (1) reads + classifies ServerState, (2) on failure tails the passive
    node's C:\ConfigMgrSetup.log for the underlying error, (3) with -Retry invokes
    RetryInstallation (up to -MaxRetries) and polls ServerState until it leaves the
    failed state / reaches ready, (4) prints a verdict. Without -Retry it only detects
    and reports (dry run).

.PARAMETER SiteCode
    3-char site code. Auto-detected from the local SMS registry if omitted.

.PARAMETER Retry
    Actually invoke RetryInstallation when CM reports a failed state. Omit for a
    detect-only dry run.

.PARAMETER MaxRetries
    Max RetryInstallation invocations (mirrors the monitor's auto-retry budget). Default 2.

.PARAMETER TimeoutMinutes
    How long to poll ServerState after each retry. Default 30.

.PARAMETER PollSeconds
    Poll cadence. Default 30.

.EXAMPLE
    .\Repair-PassiveSiteCompletion.ps1                 # detect-only dry run
.EXAMPLE
    .\Repair-PassiveSiteCompletion.ps1 -SiteCode CS1 -Retry
#>
[CmdletBinding()]
param(
    [string]$SiteCode,
    [int]$TimeoutMinutes = 30,
    [int]$PollSeconds = 30,
    [int]$MaxRetries = 2,
    [switch]$Retry
)

$ErrorActionPreference = 'Stop'

function Write-Section { param([string]$Text) Write-Host ""; Write-Host ("===== {0} =====" -f $Text) -ForegroundColor Cyan }

# --- Resolve site code -------------------------------------------------------
if (-not $SiteCode) {
    try {
        $SiteCode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
    }
    catch {
        throw "Could not auto-detect Site Code from HKLM:\SOFTWARE\Microsoft\SMS\Identification. Pass -SiteCode."
    }
}
$ns = "root\SMS\site_$SiteCode"
Write-Host "Site code: $SiteCode   Namespace: $ns"

# --- Resolve install dir / log path ------------------------------------------
$logDir = $null
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Setup', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\SMS\Setup')) {
    try {
        $dir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory'
        if ($dir -and (Test-Path (Join-Path $dir 'Logs'))) { $logDir = Join-Path $dir 'Logs'; break }
    }
    catch { }
}
if (-not $logDir) {
    foreach ($cand in @('E:\ConfigMgr\Logs', 'D:\ConfigMgr\Logs', 'C:\Program Files\Microsoft Configuration Manager\Logs')) {
        if (Test-Path $cand) { $logDir = $cand; break }
    }
}
Write-Host "Log dir:   $logDir"

# --- ConfigMgr-authoritative state constants (from ConfigMgr Constants.cs) ----
$SiteServerInstallationFailed = 131071   # 0x0001FFFF
$PrereqError = 196607                    # 0x0002FFFF
$OkCategoryMask = 0x00030000             # high word -> ready for failover

function Test-CMServerStateFailed {
    param([int]$ServerState)
    if ($ServerState -le 0) { return $false }
    return ((('{0:X4}' -f ($ServerState % 65536)).Substring(0, 1)) -eq 'F')
}

function Get-CMPassiveNode {
    param([string]$Namespace, [string]$Site)
    Get-WmiObject -Namespace $Namespace -Class SMS_SCI_SysResUse `
        -Filter "RoleName = 'SMS Site Server' AND SiteCode = '$Site' AND SiteSystemStatus = 0" -ErrorAction SilentlyContinue |
    Select-Object -First 1
}

function Get-CMServerStateInfo {
    param($Node)
    if (-not $Node -or ($null -eq $Node.ServerState)) {
        return [pscustomobject]@{ Found = $false; ServerState = $null; Hex = ''; ServerName = ''; IsFailed = $false; IsReady = $false; Kind = 'unknown (no passive SMS_SCI_SysResUse row / no ServerState)' }
    }
    $ss = [int]$Node.ServerState
    $isFailed = Test-CMServerStateFailed -ServerState $ss
    $isReady = (($ss -band 0xFFFF0000) -eq $OkCategoryMask)
    $kind = if ($isReady) { 'ready/healthy (OK category)' }
    elseif ($ss -eq $PrereqError) { 'prereq check failed' }
    elseif ($ss -eq $SiteServerInstallationFailed) { 'installation failed' }
    elseif ($isFailed) { 'failed' }
    else { 'in progress' }
    [pscustomobject]@{
        Found       = $true
        ServerState = $ss
        Hex         = '0x{0:X8}' -f $ss
        ServerName  = ([string]$Node.NetworkOSPath).Replace('\\', '')
        IsFailed    = $isFailed
        IsReady     = $isReady
        Kind        = $kind
    }
}

function Get-PassiveSetupFailureDetail {
    param([string]$PassiveServer)
    if (-not $PassiveServer) { return $null }
    try {
        $lines = Invoke-Command -ComputerName $PassiveServer -ErrorAction Stop -ScriptBlock {
            $log = 'C:\ConfigMgrSetup.log'
            if (Test-Path $log) {
                Get-Content -Path $log -Tail 4000 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match 'error|fail|fatal' } |
                Select-Object -Last 12
            }
        }
        if ($lines) { return $lines }
    }
    catch { return @("Could not read C:\ConfigMgrSetup.log on $PassiveServer ($($_.Exception.Message))") }
    return $null
}

function Invoke-CMPassiveRetry {
    param([string]$Namespace, $Node)
    # Exactly what the console action / Set-CMSite do: call the static WMI method
    # SMS_SCI_SysResUse.RetryInstallation(SiteCode, ServerName).
    $serverName = ([string]$Node.NetworkOSPath).Replace('\\', '')
    $cmClass = [wmiclass]"${Namespace}:SMS_SCI_SysResUse"
    $mp = $cmClass.GetMethodParameters('RetryInstallation')
    $mp.SiteCode = [string]$Node.SiteCode
    $mp.ServerName = $serverName
    $null = $cmClass.InvokeMethod('RetryInstallation', $mp, $null)
}

function Show-LogTail {
    param([string]$Path, [int]$Tail = 30)
    if (-not $Path -or -not (Test-Path $Path)) { Write-Host "  (log not found: $Path)"; return }
    $lines = Get-Content -Path $Path -Tail $Tail -ErrorAction SilentlyContinue
    foreach ($l in $lines) {
        if ($l -match 'FAILOVER|passive|HA |HSMonitoring|SMS_FAILOVER_MANAGER|site server job|Send data to passive|SiteToSiteConnection|compressed installation') {
            Write-Host "  $l"
        }
    }
}

# --- BEFORE: read + classify the value the console reads ----------------------
Write-Section "BEFORE (ConfigMgr-authoritative passive node state)"
$node = Get-CMPassiveNode -Namespace $ns -Site $SiteCode
$before = Get-CMServerStateInfo -Node $node
if (-not $before.Found) {
    Write-Host "No PASSIVE (SiteSystemStatus=0) SMS Site Server SCI row found for site $SiteCode." -ForegroundColor Yellow

    # Disambiguate: dump EVERY 'SMS Site Server' SCI row (active + passive) so we can
    # see whether the passive was reclassified, completed, or removed/rolled back.
    $allRows = @(Get-WmiObject -Namespace $ns -Class SMS_SCI_SysResUse `
            -Filter "RoleName = 'SMS Site Server' AND SiteCode = '$SiteCode'" -ErrorAction SilentlyContinue)
    if ($allRows.Count -eq 0) {
        Write-Host "No SMS Site Server SCI rows AT ALL for site $SiteCode (provider/site code mismatch, or the site server resource is gone)." -ForegroundColor Red
    }
    else {
        Write-Host "All SMS Site Server SCI rows for $SiteCode (SiteSystemStatus: 0=Passive, 1=Active):" -ForegroundColor Cyan
        foreach ($r in $allRows) {
            $rsHex = if ($null -ne $r.ServerState) { '0x{0:X8}' -f [int]$r.ServerState } else { '<none>' }
            $rsKind = if ($null -ne $r.ServerState) { (Get-CMServerStateInfo -Node $r).Kind } else { 'unknown' }
            Write-Host ("  {0,-32} SiteSystemStatus={1} ServerState={2} ({3})" -f `
                (([string]$r.NetworkOSPath).Replace('\\', '')), $r.SiteSystemStatus, $rsHex, $rsKind)
        }
        Write-Host "=> A passive row (SiteSystemStatus=0) reaching ServerState 0x0003xxxx is the completed state; its ABSENCE means the passive add was removed/rolled back (re-add it), while only an active (SiteSystemStatus=1) row remaining confirms there is no passive configured anymore." -ForegroundColor Yellow
    }

    # Ground-truth the passive node directly (role + SMS_EXECUTIVE), independent of SCI.
    $passiveGuess = ($allRows | Where-Object { $_.SiteSystemStatus -eq 0 } | Select-Object -First 1)
    if (-not $passiveGuess) { $passiveGuess = ($allRows | Where-Object { ([string]$_.NetworkOSPath) -match '-P\.' } | Select-Object -First 1) }
    if ($passiveGuess) {
        $pName = ([string]$passiveGuess.NetworkOSPath).Replace('\\', '')
        try {
            $svc = Get-Service -ComputerName $pName -Name 'SMS_EXECUTIVE' -ErrorAction Stop
            Write-Host ("Passive node {0}: SMS_EXECUTIVE = {1}" -f $pName, $svc.Status) -ForegroundColor Cyan
        }
        catch { Write-Host ("Passive node {0}: SMS_EXECUTIVE not queryable ({1})" -f $pName, $_.Exception.Message) -ForegroundColor Yellow }
    }
    return
}
Write-Host ("Passive server: {0} | ServerState={1} ({2}) => {3}" -f $before.ServerName, $before.Hex, $before.ServerState, $before.Kind) -ForegroundColor Cyan

if ($before.IsReady) {
    Write-Host "ConfigMgr reports the passive site server READY. Nothing to retry -- the add is complete." -ForegroundColor Green
    return
}
if (-not $before.IsFailed) {
    Write-Host "ConfigMgr reports the passive add still IN PROGRESS (not failed). The console would NOT offer 'Retry installation' yet; this is a detect-only observation." -ForegroundColor Yellow
}
else {
    Write-Host "ConfigMgr reports the passive site server '$($before.Kind)' -- exactly the state the console surfaces as 'Installation failed' and gates 'Retry installation' on." -ForegroundColor Red
    Write-Section "Passive ConfigMgrSetup.log (recent error/fail lines on $($before.ServerName))"
    $detail = Get-PassiveSetupFailureDetail -PassiveServer $before.ServerName
    if ($detail) { $detail | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no error lines / log unavailable)" }
}

# --- RETRY (opt-in): the same call the console's 'Retry installation' makes ----
$attempts = 0
if ($Retry -and $before.IsFailed) {
    while ($attempts -lt $MaxRetries) {
        $cur = Get-CMServerStateInfo -Node (Get-CMPassiveNode -Namespace $ns -Site $SiteCode)
        if (-not $cur.Found -or $cur.IsReady -or -not $cur.IsFailed) { break }
        $attempts++
        Write-Section "RETRY $attempts/$MaxRetries -- SMS_SCI_SysResUse.RetryInstallation (console/Set-CMSite equivalent)"
        try {
            Invoke-CMPassiveRetry -Namespace $ns -Node $node
            Write-Host "RetryInstallation invoked for $($before.ServerName)." -ForegroundColor Green
        }
        catch {
            Write-Host "RetryInstallation FAILED: $($_.Exception.Message)" -ForegroundColor Red
            break
        }

        # Poll ServerState through 'in progress' until it CONVERGES: ready (done) or
        # back to failed AFTER it re-entered the install pipeline (this retry failed
        # again -> spend the next retry). The retry re-runs the full passive setup,
        # so converging to ready can take several minutes -- hence the per-attempt
        # $TimeoutMinutes budget. (A bare 'left failed' is NOT convergence: the state
        # flips failed -> Installing within seconds of the call.)
        Write-Section "POLL after retry $attempts (up to $TimeoutMinutes min, every $PollSeconds s)"
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $sawProgress = $false
        $ready = $false
        $reFailed = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $PollSeconds
            $now = Get-CMServerStateInfo -Node (Get-CMPassiveNode -Namespace $ns -Site $SiteCode)
            Write-Host ("[poll {0}] ServerState={1} => {2}" -f (Get-Date).ToString('HH:mm:ss'), $now.Hex, $now.Kind)
            if ($now.IsReady) { $ready = $true; break }
            if (-not $now.IsFailed) { $sawProgress = $true; continue }   # re-entered install; keep watching
            if ($sawProgress) { $reFailed = $true; break }               # failed again after progressing
            # else: still reporting the prior failed state right after the call -- keep waiting for it to flip
        }
        if ($ready) { break }
        if ($reFailed) {
            Write-Host "Re-entered the install pipeline but FAILED again; retrying once more if attempts remain." -ForegroundColor Yellow
            continue
        }
        Write-Host "Poll window ($TimeoutMinutes min) elapsed while still in progress (not yet ready). Re-run the script to keep watching it converge." -ForegroundColor Yellow
        break
    }
}
elseif ($before.IsFailed) {
    Write-Host "`n-Retry not specified: detected the failure but did NOT invoke RetryInstallation. Re-run with -Retry to trigger the console-equivalent retry." -ForegroundColor Yellow
}

# --- AFTER snapshot + active-side logs ---------------------------------------
Write-Section "AFTER"
$after = Get-CMServerStateInfo -Node (Get-CMPassiveNode -Namespace $ns -Site $SiteCode)
if ($after.Found) {
    Write-Host ("ServerState={0} ({1}) => {2}" -f $after.Hex, $after.ServerState, $after.Kind) -ForegroundColor Cyan
}

if ($logDir) {
    Write-Section "hman.log (failover/passive lines)"
    Show-LogTail -Path (Join-Path $logDir 'hman.log') -Tail 60
    Write-Section "sitecomp.log (failover/passive lines)"
    Show-LogTail -Path (Join-Path $logDir 'sitecomp.log') -Tail 60
}

# --- VERDICT -----------------------------------------------------------------
Write-Section "VERDICT"
if ($after.IsReady) {
    Write-Host "SUCCESS: ConfigMgr now reports the passive site server READY ($($after.Hex))." -ForegroundColor Green
    if ($attempts -gt 0) { Write-Host "=> RetryInstallation recovered the passive add in $attempts attempt(s); the monitor's auto-retry does the same." -ForegroundColor Green }
}
elseif ($after.IsFailed) {
    Write-Host "STILL FAILED: ConfigMgr still reports '$($after.Kind)' ($($after.Hex)) after $attempts retry attempt(s)." -ForegroundColor Red
    Write-Host "=> Check ConfigMgrSetup.log on $($after.ServerName); the underlying failure is not retry-recoverable." -ForegroundColor Red
}
elseif ($after.Found) {
    Write-Host "IN PROGRESS: ConfigMgr reports '$($after.Kind)' ($($after.Hex)). The retry re-entered the install pipeline; re-run to watch it converge to ready." -ForegroundColor Yellow
}
