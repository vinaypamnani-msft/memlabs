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

.EXAMPLE
    cd C:\memlabs\vmbuild\tools ; .\Get-DrsLogs.ps1
.EXAMPLE
    .\Get-DrsLogs.ps1 -Domain cstest8.com
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string]$PrimaryName,
    [int]$TailLines = 30
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
$sqlSnapBlock = {
    param($siteCode)
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
    function Q {
        param($q, $title)
        $out.Add("---- $title ----")
        try {
            $cs = "Server=$server;Initial Catalog=$db;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
            $cn = New-Object System.Data.SqlClient.SqlConnection $cs
            $cn.Open()
            $cmd = $cn.CreateCommand(); $cmd.CommandText = $q; $cmd.CommandTimeout = 60
            $r = $cmd.ExecuteReader()
            while ($r.Read()) {
                $line = @()
                for ($i = 0; $i -lt $r.FieldCount; $i++) { $line += ("{0}={1}" -f $r.GetName($i), $r.GetValue($i)) }
                $out.Add('  ' + ($line -join '  '))
            }
            $r.Close(); $cn.Close()
        }
        catch { $out.Add('  ERROR: ' + $_.Exception.Message) }
    }
    $out.Add("CM database: $db  (server $server)")
    Q "SELECT SiteCode, SiteStatus FROM ServerData ORDER BY SiteCode" "ServerData (SiteStatus per site)"
    Q "SELECT ReplicationGroup, ReplicationPattern FROM ReplicationData ORDER BY ReplicationPattern, ReplicationGroup" "ReplicationData (groups)"
    Q "SELECT TOP 60 rd.ReplicationGroup, rd.ReplicationPattern, s.SiteCode, s.Active, s.LastSendResult, s.LastVersionSent, s.LastSendStartTime, s.LastSendEndTime FROM DRS_MessageActivity_Send s INNER JOIN ReplicationData rd ON rd.ID = s.ReplicationID ORDER BY s.LastSendStartTime DESC" "DRS_MessageActivity_Send (per-group send status; LastSendResult<0 = error)"
    Q "SELECT rd.ReplicationGroup, rd.ReplicationPattern, s.SiteCode, s.Active, s.LastSendResult FROM DRS_MessageActivity_Send s INNER JOIN ReplicationData rd ON rd.ID = s.ReplicationID WHERE s.LastSendResult < 0 ORDER BY rd.ReplicationGroup" "Send groups with an ERROR result (LastSendResult<0)"
    # Per-group link status both directions. spGetLinkOverAllStatus takes MAX(Status) across
    # groups, so one lagging group is what turns the whole link Degraded (7816) / Failed (7822).
    Q "SELECT rd.ReplicationGroup, rd.ReplicationPattern, s.SiteSending, s.SiteReceiving, s.Status FROM RCM_ReplicationLinkStatus s INNER JOIN ReplicationData rd ON rd.ID = s.ReplicationID ORDER BY s.Status DESC, s.SiteSending, rd.ReplicationGroup" "RCM_ReplicationLinkStatus (per-group, both directions)"
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
