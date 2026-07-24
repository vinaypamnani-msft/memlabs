#InstallBoundaryGroups.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.vmOptions.domainName
$NetbiosDomainName = $deployConfig.vmOptions.domainNetBiosName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","
$ClientNames = $thisVM.thisParams.ClientPush
$cm_svc = "$NetbiosDomainName\cm_svc"
# Push is now per-VM (pushClient property). thisParams.ClientPush only contains
# VMs that have opted in, so an empty list means nothing to push.
$pushClients = [bool]$ClientNames
# Per-VM cmOptions wins over the rehydrated global for multi-hierarchy deploys.
$cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
$usePKI = $cmo.UsePKI
if (-not $usePKI) {
    $usePKI = $false
}
# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    Write-DscStatus "Failed to get 'Site Code' from SOFTWARE\Microsoft\SMS\Identification. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return
}

# Provider
$smsProvider = Get-SMSProvider -SiteCode $SiteCode
if (-not $smsProvider.FQDN) {
    Write-DscStatus "Failed to get SMS Provider for site $SiteCode. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return $false
}

# Set CMSite Provider
$worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($smsProvider.FQDN)
if (-not $worked) {
    return
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\"
if ((Get-Location).Drive.Name -ne $SiteCode) {
    Write-DscStatus "Failed to Set-Location to $SiteCode`:"
    return $false
}

# Ensure the client package is Installed (State 0) on EVERY DP that serves a client
# boundary group -- not just "at least one". A client whose boundary group's only DP
# is still validating/pending/failed (e.g. a Secondary DP stuck at ContentValidating)
# can't get client content and loops forever in ccmsetup GetDPLocations (empty
# <LocationRecords/> / 0x87d00215). Defined as a scriptblock so it runs on BOTH the
# fresh-deploy path AND the "BGs already exist" early-return path below -- i.e. a
# Phase 8 re-run self-heals a stuck DP, not just a first deploy. Phase 8 is the right
# home for this (content-distribution context + a generous wait budget).
$ensureClientPkgCoverage = {
    $pkg = Get-CMPackage -Fast -Name 'Configuration Manager Client Package'
    if (-not $pkg) { Write-DscStatus "Client pkg coverage: client package not found."; return }
    $PackageID = $pkg.PackageID
    $ns = "root\SMS\site_$SiteCode"
    $fqdnOf = { param($nal) if ("$nal" -match '\\([^\\"\]]+)') { $Matches[1] } else { $null } }
    $stateName = @{ '0' = 'Installed'; '1' = 'InstallPending'; '2' = 'InstallRetrying'; '3' = 'InstallFailed'; '6' = 'RemovalFailed'; '7' = 'ContentValidating'; '8' = 'ContentValidationFailed' }

    # Version-proof per-DP (re)distribute. The ConfigMgr cmdlet surface for
    # targeting a SINGLE DP is inconsistent across builds and was breaking here:
    #   * Invoke-CMContentRedistribution has NO -PackageId on this build
    #     ("A parameter cannot be found that matches parameter name 'PackageId'").
    #   * Update-CMDistributionPoint has no -DistributionPointName (all-DP only).
    #   * Start-CMContentDistribution throws "No content destination was found ...
    #     already been distributed" when a distribution row already exists.
    # The SMS_DistributionPoint targeting instance is the reliable path: if the
    # package is already targeted at the DP, flip RefreshNow=$true + Put() to force
    # a redistribute (works even for a DP wedged at ContentValidating/Failed); only
    # when there is NO targeting row do we create one with Start-CMContentDistribution.
    # Deciding on the targeting table (not the lagging summarizer) also avoids the
    # "already distributed" throw when the summarizer row hasn't appeared yet.
    $redistOrDistribute = {
        param($dpFqdn)
        $targeting = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$PackageID'" -ErrorAction SilentlyContinue |
                Where-Object { (& $fqdnOf $_.ServerNALPath) -ieq $dpFqdn })
        if ($targeting.Count -gt 0) {
            foreach ($t in $targeting) { $t.RefreshNow = $true; [void]$t.Put() }
            return 'redistributed'
        }
        Start-CMContentDistribution -PackageId $PackageID -DistributionPointName $dpFqdn -ErrorAction Stop
        return 'distributed'
    }

    $bgDpFqdns = @()
    try {
        $bgDpFqdns = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupSiteSystems -ErrorAction Stop |
                ForEach-Object { & $fqdnOf $_.ServerNALPath } | Where-Object { $_ } | Select-Object -Unique)
    }
    catch { Write-DscStatus "Client pkg coverage: could not enumerate boundary-group site systems: $($_.Exception.Message)"; return }
    if ($bgDpFqdns.Count -eq 0) { return }

    # Escalation ladder per DP -- a plain redistribute does NOT clear a Secondary DP
    # wedged at ContentValidating (its distmgr may be idle on a 3600s sleep cycle),
    # so escalate: (0) redistribute -> (1) remove + re-add content (force a clean
    # copy through the wedge) -> (2) restart SMS_EXECUTIVE on the DP to wake its
    # distmgr. The client package is small, so each step should settle in a minute
    # or two when it is going to work.
    $escalation = @{}   # DP-upper -> highest escalation level already applied
    $maxTries = 24
    for ($try = 1; $try -le $maxTries; $try++) {
        $state = @{}
        foreach ($r in @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$PackageID'" -ErrorAction SilentlyContinue)) {
            $f = & $fqdnOf $r.ServerNALPath; if ($f) { $state[$f.ToUpper()] = [int]$r.State }
        }
        $notInstalled = @($bgDpFqdns | Where-Object { -not ($state.ContainsKey($_.ToUpper()) -and $state[$_.ToUpper()] -eq 0) })
        if ($notInstalled.Count -eq 0) {
            Write-DscStatus "Client package is Installed on all $($bgDpFqdns.Count) boundary-group DP(s)."
            break
        }
        foreach ($dp in $notInstalled) {
            $u = $dp.ToUpper()
            $hasRow = $state.ContainsKey($u)
            $st = if ($hasRow) { $state[$u] } else { -1 }
            $stName = if ($stateName.ContainsKey("$st")) { $stateName["$st"] } else { "State$st" }
            # Let actively-progressing distributions (InstallPending=1 / Retrying=2)
            # finish on their own.
            if ($st -in 1, 2) { continue }
            $level = if ($escalation.ContainsKey($u)) { $escalation[$u] } else { -1 }
            try {
                if ($level -lt 0) {
                    # Level 0: gentle (re)distribute via the version-proof WMI path.
                    # $hasRow (summarizer) is unreliable here -- it lags targeting,
                    # so a DP that is already targeted but has no summarizer row yet
                    # would fail Start-CMContentDistribution with "already distributed".
                    # $redistOrDistribute checks the targeting table and picks
                    # RefreshNow (already targeted) vs distribute (not targeted).
                    $action = & $redistOrDistribute $dp
                    if ($action -eq 'distributed') {
                        Write-DscStatus "Client pkg coverage: DP '$dp' had no distribution -> distributed [esc.0, try $try]"
                    }
                    else {
                        Write-DscStatus "Client pkg coverage: DP '$dp' state=$stName -> redistributed (RefreshNow) [esc.0, try $try]"
                    }
                    $escalation[$u] = 0
                }
                elseif ($level -eq 0 -and $try -ge 4) {
                    # Level 1: remove + re-add content (clean copy through the wedge).
                    # The Remove is best-effort (a wedged Secondary DP may reject it),
                    # so re-add via the $redistOrDistribute helper -- if the targeting
                    # row survived the Remove it RefreshNow's it instead of throwing
                    # "already distributed"; if the Remove took, it distributes fresh.
                    try { Remove-CMContentDistribution -PackageId $PackageID -DistributionPointName $dp -Force -ErrorAction Stop } catch {}
                    Start-Sleep -Seconds 10
                    & $redistOrDistribute $dp | Out-Null
                    Write-DscStatus "Client pkg coverage: DP '$dp' still $stName -> removed + re-added content [esc.1, try $try]"
                    $escalation[$u] = 1
                }
                elseif ($level -eq 1 -and $try -ge 8) {
                    # Level 2: wake the DP's distmgr (it may be idle on a 3600s sleep).
                    $dpHost = ("$dp" -split '\.')[0]
                    try {
                        $svc = Get-Service -ComputerName $dpHost -Name 'SMS_EXECUTIVE' -ErrorAction Stop
                        Restart-Service -InputObject $svc -Force -ErrorAction Stop
                        Write-DscStatus "Client pkg coverage: DP '$dp' still $stName -> restarted SMS_EXECUTIVE on '$dpHost' to wake distmgr [esc.2, try $try]"
                    }
                    catch { Write-DscStatus "Client pkg coverage: could not restart SMS_EXECUTIVE on '$dpHost' (WinRM/RPC?): $($_.Exception.Message)" }
                    $escalation[$u] = 2
                }
            }
            catch { Write-DscStatus "Client pkg coverage: remediation on DP '$dp' failed: $($_.Exception.Message)" }
        }
        Write-DscStatus "Client pkg coverage: waiting for client package on: $($notInstalled -join ', ') [$try/$maxTries]"
        Start-Sleep -Seconds 30
    }

    # Final state + rich DP-side diagnostics if anything is still not Installed --
    # so a genuine wedge (content never replicated, distmgr stuck, PFX decrypt,
    # inter-site bundle failure, version skew) is captured in the phase log instead
    # of just failing later in Phase 11.
    #
    # Package's CURRENT source version: a DP pinned at an OLDER version is a
    # content-UPDATE/replication problem, not "never distributed" (observed: the
    # pull DP had v3 while the site server processed v1). Capture it to flag skew.
    $pkgSourceVersion = $null
    try { $pkgSourceVersion = (Get-WmiObject -Namespace $ns -Class SMS_Package -Filter "PackageID='$PackageID'" -ErrorAction SilentlyContinue | Select-Object -First 1).SourceVersion } catch {}

    $state = @{}; $stateVer = @{}
    foreach ($r in @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$PackageID'" -ErrorAction SilentlyContinue)) {
        $f = & $fqdnOf $r.ServerNALPath; if ($f) { $state[$f.ToUpper()] = [int]$r.State; $stateVer[$f.ToUpper()] = "$($r.SourceVersion)" }
    }
    $stillBad = @($bgDpFqdns | Where-Object { -not ($state.ContainsKey($_.ToUpper()) -and $state[$_.ToUpper()] -eq 0) })
    if ($stillBad.Count -gt 0) {
        Write-DscStatus "Client pkg coverage: STILL not Installed after $maxTries tries on: $($stillBad -join ', ') [pkg $PackageID SourceVersion=$pkgSourceVersion]. Capturing DP-side diagnostics..." -Warning
        foreach ($dp in $stillBad) {
            $dpHost = ("$dp" -split '\.')[0]
            $u = $dp.ToUpper()
            $sInfo = if ($state.ContainsKey($u)) { "State=$($stateName["$($state[$u])"]) DPSourceVersion=$($stateVer[$u]) vs pkg=$pkgSourceVersion" } else { "no summarizer row (never targeted, or not yet reported)" }
            try {
                $diag = Invoke-Command -ComputerName $dpHost -ArgumentList $PackageID -ErrorAction Stop -ScriptBlock {
                    param($pkgId)
                    # Tail-bounded, TARGETED CMTrace-log reader: last $n lines that match
                    # $pat (unwrapped), so a busy log yields package-relevant lines instead
                    # of unrelated trailing noise.
                    $grab = {
                        param($p, $n, $pat)
                        if (-not (Test-Path $p)) { return "" }
                        $hits = @(Get-Content $p -Tail 3000 -ErrorAction SilentlyContinue | Where-Object { $_ -match $pat } | Select-Object -Last $n)
                        (@($hits | ForEach-Object { $m = [regex]::Match($_, '<!\[LOG\[(.*?)\]LOG\]!>'); if ($m.Success) { $m.Groups[1].Value } else { $_ } }) -join ' | ')
                    }
                    $o = [ordered]@{ PkgLib = ''; ContentLibDrive = ''; Distmgr = ''; PkgXfer = ''; Despool = ''; Sender = '' }
                    $clRoot = $null
                    foreach ($cl in @('E:\SCCMContentLib', 'D:\SCCMContentLib', 'F:\SCCMContentLib', 'C:\SCCMContentLib')) {
                        $pl = Join-Path $cl 'PkgLib'
                        if (Test-Path $pl) { $clRoot = $cl; $o.PkgLib = (@(Get-ChildItem $pl -Filter "$pkgId*.INI" -ErrorAction SilentlyContinue).Name) -join ','; break }
                    }
                    if ($clRoot) {
                        try { $drv = Get-PSDrive -Name ($clRoot.Substring(0, 1)) -ErrorAction Stop; $o.ContentLibDrive = "$($clRoot.Substring(0, 1)) free=$([math]::Round($drv.Free / 1GB, 1))GB" } catch {}
                    }
                    $smsDir = $null
                    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
                        try { $smsDir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
                        if ($smsDir) { break }
                    }
                    if ($smsDir) {
                        $logs = Join-Path $smsDir 'Logs'
                        # distmgr: package activity + inter-site bundle / cert-decrypt faults.
                        $o.Distmgr = & $grab (Join-Path $logs 'distmgr.log') 6 "$pkgId|creating package bundle|0x800704d3|hasn.t arrived|Failed to decrypt|PFX|No content destination"
                        # PkgXferMgr: pull-DP + inter-site send failures (STATMSG 8211).
                        $o.PkgXfer = & $grab (Join-Path $logs 'PkgXferMgr.log') 4 "$pkgId|8211|Failed|error|abort"
                        # despool: the RECEIVING (child/secondary) side unpacking bundles.
                        $o.Despool = & $grab (Join-Path $logs 'despool.log') 4 "$pkgId|bundle|0x800704d3|decrypt|instruction"
                        # sender: the SENDING side inter-site transfer.
                        $o.Sender = & $grab (Join-Path $logs 'sender.log') 3 "$pkgId|Error|0x8|failed|retry"
                    }
                    return $o
                }
                $pkgLibNote = if ($diag.PkgLib) { "PkgLib HAS [$($diag.PkgLib)]" } else { "PkgLib MISSING $PackageID -> content never arrived on this DP" }
                Write-DscStatus "Client pkg coverage diag [$dp]: summarizer $sInfo ; $pkgLibNote ; $($diag.ContentLibDrive)" -Warning
                if ($diag.Distmgr) { Write-DscStatus "Client pkg coverage diag [$dp] distmgr: $($diag.Distmgr)" -Warning }
                if ($diag.PkgXfer) { Write-DscStatus "Client pkg coverage diag [$dp] PkgXferMgr: $($diag.PkgXfer)" -Warning }
                if ($diag.Despool) { Write-DscStatus "Client pkg coverage diag [$dp] despool: $($diag.Despool)" -Warning }
                if ($diag.Sender) { Write-DscStatus "Client pkg coverage diag [$dp] sender: $($diag.Sender)" -Warning }
            }
            catch { Write-DscStatus "Client pkg coverage diag [$dp]: remote query failed (WinRM?): $($_.Exception.Message)" -Warning }
        }
    }

    Invoke-CMSystemDiscovery
    Invoke-CMDeviceCollectionUpdate -Name "All Systems"
}

# Ensure every CHILD (secondary) boundary group also lists the parent primary's
# DP(s) as fallback content sources, so a child BG never depends on a single --
# possibly slow or wedged -- secondary DP (clients transparently use the parent DP
# when the local one can't serve content, instead of looping in ccmsetup
# GetDPLocations). Runs on BOTH paths (the "BGs already exist" early-return AND the
# fresh client-push path) so a re-run adds them to already-existing child BGs too.
$ensureChildBgFallbackDps = {
    try {
        $parentDps = @((Get-CMDistributionPoint -SiteCode $SiteCode -ErrorAction SilentlyContinue).NetworkOSPath -replace "\\", "" | Where-Object { $_ -and $_.Trim() })
        if ($parentDps.Count -eq 0) { return }
        foreach ($childSite in ($bgs.SiteCode | Select-Object -Unique | Where-Object { $_ -and $_ -ne $SiteCode })) {
            if (-not (Get-CMBoundaryGroup -Name $childSite -ErrorAction SilentlyContinue)) { continue }
            try {
                Set-CMBoundaryGroup -Name $childSite -AddSiteSystemServerName $parentDps -ErrorAction SilentlyContinue
                Write-DscStatus "Ensured parent DP(s) $($parentDps -join ',') are fallback content sources in child Boundary Group '$childSite'"
            }
            catch { Write-DscStatus "Could not add parent DP(s) to child BG '$childSite': $($_.Exception.Message)" }
        }
    }
    catch { Write-DscStatus "Child-BG fallback-DP ensure failed: $($_.Exception.Message)" }
}


$ValidSiteCodes = @($SiteCode)
$ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
$ValidSiteCodes += $ReportingSiteCodes


Write-DscStatus "Client push candidates are '$ClientNames'"


# Create Boundary groups
$bgs = $ThisVM.thisParams.sitesAndNetworks | Where-Object { $_.SiteCode -in $ValidSiteCodes }
$bgsCount = $bgs.count

# Quick check: if all boundary groups, boundaries, membership, and discovery are already configured, skip
$allBGsExist = $true
foreach ($bgsitecode in ($bgs.SiteCode | Select-Object -Unique)) {
    if (-not (Get-CMBoundaryGroup -Name $bgsitecode -ErrorAction SilentlyContinue)) {
        $allBGsExist = $false
        break
    }
}
if ($allBGsExist) {
    foreach ($bg in $bgs) {
        $boundary = Get-CMBoundary -BoundaryName $bg.Subnet -ErrorAction SilentlyContinue
        if (-not $boundary) {
            $allBGsExist = $false
            break
        }
        # Verify boundary is actually in its group
        $memberOf = Get-CMBoundary -BoundaryGroupName $bg.SiteCode -ErrorAction SilentlyContinue
        if (-not ($memberOf | Where-Object { $_.DisplayName -eq $bg.Subnet })) {
            $allBGsExist = $false
            break
        }
    }
}
if ($allBGsExist) {
    $adiscovery = (Get-CMDiscoveryMethod | Where-Object { $_.ItemName -eq "SMS_AD_SYSTEM_DISCOVERY_AGENT|SMS Site Server" }).Props | Where-Object { $_.PropertyName -eq "Settings" }
    $adsgdiscovery = (Get-CMDiscoveryMethod | Where-Object { $_.ItemName -eq "SMS_AD_SECURITY_GROUP_DISCOVERY_AGENT|SMS Site Server" }).Props | Where-Object { $_.PropertyName -eq "Settings" }
    if ($adiscovery.Value1.ToLower() -eq "active" -and $adsgdiscovery.Value1.ToLower() -eq "active") {
        Write-DscStatus "All boundary groups, boundaries, and discovery already configured. Skipping."
        # Even when BGs are already configured (re-run / steady state), still ensure
        # the client package is on every client-serving DP. This early-return used to
        # skip the coverage repair further down, so a DP stuck at ContentValidating
        # never self-healed on a Phase 8 re-run.
        if ($pushClients -and -not $ThisVm.thisParams.PassiveNode) {
            & $ensureChildBgFallbackDps
            & $ensureClientPkgCoverage
        }
        # Still handle client push path
        if ($ThisVm.thisParams.PassiveNode -or -not $pushClients) {
            $Configuration.InstallClient.Status = 'NotRequested'
            $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
        }
        return
    }
}

Write-DscStatus "Create $bgsCount Boundary Groups for site $SiteCode"
foreach ($bgsitecode in ($bgs.SiteCode | Select-Object -Unique)) {
    # A child SECONDARY site is installed in PARALLEL with this script (the
    # secondary/passive install runs as a background job and takes ~10+ min),
    # and this Primary is the ONLY place InstallBoundaryGroups runs for the
    # hierarchy: the secondary itself never runs it and the CAS doesn't call it.
    # So gating child boundary-group creation on the child being fully 'Active'
    # (Status -eq 1) ALWAYS skipped it (the secondary never finishes before this
    # loop), and the child BG was never created at all -- the root cause of the
    # Phase 11 'Expected boundary group <child> not found' warning, which never
    # cleared on re-runs either.
    #
    # Fix: wait briefly for the child's SMS_Site ROW to register, then create the
    # BG as soon as the row exists. A boundary group is global metadata and does
    # not require the site to be fully installed to exist; site systems (the
    # secondary's DP) are added best-effort and fill in on a later pass / re-run
    # once the secondary is up.
    $siteStatus = Get-CMSite -SiteCode $bgsitecode -ErrorAction SilentlyContinue
    if (-not $siteStatus -and $bgsitecode -ne $SiteCode) {
        Write-DscStatus "Site '$bgsitecode' not yet registered; waiting up to 3 min for its row before creating its Boundary Group..."
        $rowWaitMax = 36   # 36 x 5s = ~3 min
        for ($rw = 1; $rw -le $rowWaitMax -and -not $siteStatus; $rw++) {
            Start-Sleep -Seconds 5
            $siteStatus = Get-CMSite -SiteCode $bgsitecode -ErrorAction SilentlyContinue
        }
    }
    if (-not $siteStatus) {
        Write-DscStatus "Skip creating Boundary Group '$bgsitecode' - site row never registered after waiting."
        Start-Sleep -Seconds 5
        continue
    }

    # Resolve currently-registered site systems (best-effort; a still-installing
    # secondary's DP/MP/SUP may not be present yet -- that's fine).
    $sitesystems = @()
    $sitesystems += (Get-CMDistributionPoint -SiteCode $bgsitecode -ErrorAction SilentlyContinue).NetworkOSPath -replace "\\", ""
    $sitesystems += (Get-CMManagementPoint -SiteCode $bgsitecode -ErrorAction SilentlyContinue).NetworkOSPath -replace "\\", ""
    $sitesystems += (Get-CMSoftwareUpdatePoint -SiteCode $bgsitecode -ErrorAction SilentlyContinue).NetworkOSPath -replace "\\", ""
    $sitesystems = $sitesystems | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique

    # Site assignment (DefaultSiteCode): a secondary's clients are assigned to the
    # PARENT primary ($SiteCode) and get content from the secondary's DP, so the
    # child BG's default site is the running primary. For the primary's own BG
    # this is identical ($SiteCode -eq $bgsitecode).
    $bgDefaultSite = $SiteCode

    try {
        $exists = Get-CMBoundaryGroup -Name $bgsitecode -ErrorAction SilentlyContinue
        if ($exists) {
            if ($sitesystems) {
                Write-DscStatus "Updating Boundary Group '$bgsitecode' with Site Systems $($sitesystems -join ',') in sitecode $SiteCode"
                Set-CMBoundaryGroup -Name $bgsiteCode -AddSiteSystemServerName $sitesystems
            }
            else {
                Write-DscStatus "Boundary Group '$bgsitecode' already exists; no site systems registered yet to add (site '$bgsitecode' still installing)"
            }
        }
        else {
            if ($sitesystems) {
                Write-DscStatus "Creating Boundary Group '$bgsitecode' with Site Systems $($sitesystems -join ',') in sitecode $SiteCode"
                New-CMBoundaryGroup -Name $bgsitecode -DefaultSiteCode $bgDefaultSite -AddSiteSystemServerName $sitesystems
            }
            else {
                # Site row exists but no site systems registered yet (secondary
                # still installing). Create the group now so it EXISTS + replicates;
                # the DP is added when it comes online (later pass / re-run).
                Write-DscStatus "Creating Boundary Group '$bgsitecode' (site '$bgsitecode' still installing - no site systems yet; DP added on a later pass) in sitecode $SiteCode"
                New-CMBoundaryGroup -Name $bgsitecode -DefaultSiteCode $bgDefaultSite
            }
        }
    }
    catch {
        Write-DscStatus "Failed to create Boundary Group '$bgsitecode' in sitecode $SiteCode. Error: $_"
    }
    Start-Sleep -Seconds 5
}

# Create Boundaries for each subnet and add to BG
Write-DscStatus "Create Boundaries for each subnet and add to BG"
foreach ($bg in $bgs) {
    # Compute usable host range (.1 to .254), matching the convention CM uses
    # when auto-creating boundaries from AD subnets via Forest Discovery.
    # Using .0-.255 (network/broadcast) would create a duplicate boundary
    # alongside the Forest Discovery auto-created .1-.254 range.
    $IP = $bg.Subnet
    $mask = '255.255.255.0'
    $IPBits = [int[]]$IP.Split('.')
    $MaskBits = [int[]]$Mask.Split('.')
    $NetworkIDBits = 0..3 | Foreach-Object { $IPBits[$_] -band $MaskBits[$_] }
    $BroadcastBits = 0..3 | Foreach-Object { $NetworkIDBits[$_] + ($MaskBits[$_] -bxor 255) }
    $NetworkID = $NetworkIDBits -join '.'
    $NetworkIDBits[3] = 1          # first usable host
    $BroadcastBits[3] = 254        # last usable host
    $FirstHost = $NetworkIDBits -join '.'
    $LastHost = $BroadcastBits -join '.'
    $rangeValue = "$FirstHost-$LastHost"
    # Match AD Forest Discovery naming: domain/SiteCode/NetworkID/prefix
    $boundaryName = "$DomainFullName/$($bg.SiteCode)/$NetworkID/24"

    # Check by name first, then by value to catch Forest Discovery auto-created boundaries
    $exists = Get-CMBoundary -BoundaryName $boundaryName -ErrorAction SilentlyContinue
    if (-not $exists) {
        # Also check the old naming convention (just the subnet IP)
        $exists = Get-CMBoundary -BoundaryName $bg.Subnet -ErrorAction SilentlyContinue
    }
    if (-not $exists) {
        $exists = Get-CMBoundary | Where-Object { $_.BoundaryType -eq 3 -and $_.Value -eq $rangeValue }
    }
    if ($exists) {
        try {
            Write-DscStatus "Adding Boundary '$($exists.DisplayName)' ($rangeValue) to Boundary Group $($bg.SiteCode)"
            Add-CMBoundaryToGroup -BoundaryName $exists.DisplayName -BoundaryGroupName $bg.SiteCode
        }
        catch {
            Write-DscStatus "Failed to add boundary '$($exists.DisplayName)' to Boundary Group '$($bg.SiteCode)'. Error: $_"
        }
    }
    else {
        try {
            Write-DscStatus "Creating Boundary '$boundaryName' with range $rangeValue"
            New-CMBoundary -Type IPRange -Name $boundaryName -Value $rangeValue
            try {
                Add-CMBoundaryToGroup -BoundaryName $boundaryName -BoundaryGroupName $bg.SiteCode
            }
            catch {
                Write-DscStatus "Failed to add boundary '$boundaryName' to Boundary Group '$($bg.SiteCode)'. Error: $_"
            }
        }
        catch {
            Write-DscStatus "Failed to create boundary '$boundaryName'. Error: $_"
        }
    }

    Start-Sleep -Seconds 5
}

# Setup System Discovery
Write-DscStatus "Enabling AD system discovery"

$Domain = $DomainFullName
$DN = 'DC=' + $Domain.Replace('.',',DC=')    
do {
    $adiscovery = (Get-CMDiscoveryMethod | Where-Object { $_.ItemName -eq "SMS_AD_SYSTEM_DISCOVERY_AGENT|SMS Site Server" }).Props | Where-Object { $_.PropertyName -eq "Settings" }

    if ($adiscovery.Value1.ToLower() -ne "active") {
        Write-DscStatus "AD System Discovery state is: $($adiscovery.Value1)" -RetrySeconds 30
        Start-Sleep -Seconds 30
        Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $SiteCode -Enabled $true -AddActiveDirectoryContainer "LDAP://$DN" -Recursive
    }
    else {
        Write-DscStatus "AD System Discovery state is: $($adiscovery.Value1)"
    }
} until ($adiscovery.Value1.ToLower() -eq "active")

# Setup SG Discovery
Write-DscStatus "Enabling AD Group discovery"
do {
    $adsgdiscovery = (Get-CMDiscoveryMethod | Where-Object { $_.ItemName -eq "SMS_AD_SECURITY_GROUP_DISCOVERY_AGENT|SMS Site Server" }).Props | Where-Object { $_.PropertyName -eq "Settings" }

    if ($adsgdiscovery.Value1.ToLower() -ne "active") {

        Write-DscStatus "AD Group Discovery state is: $($adiscovery.Value1)" -RetrySeconds 30
        Start-Sleep -Seconds 30
        $sgscope = New-CMADGroupDiscoveryScope -name Allscope -SiteCode $SiteCode -LdapLocation "LDAP://$DN" -RecursiveSearch $true -Verbose
        Set-CMDiscoveryMethod -ActiveDirectoryGroupDiscovery -AddGroupDiscoveryScope $sgscope -Enabled $true -Verbose
    }
    else {
        Write-DscStatus "AD System Discovery state is: $($adsgdiscovery.Value1)"
    }
} until ($adsgdiscovery.Value1.ToLower() -eq "active")

# Run discovery
Write-DscStatus "Invoking AD system discovery"
Invoke-CMSystemDiscovery
Start-Sleep -Seconds 5

if ($ThisVm.thisParams.PassiveNode) {
    Write-DscStatus "Passive site server detected — client push will proceed for other VMs"
}

# Push Clients
#==============
if (-not $pushClients) {
    Write-DscStatus "Skipping Client Push. No VMs have pushClient=true in this deployment."
    $Configuration.InstallClient.Status = 'NotRequested'
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}




# Wait for collection to populate

if ($ClientNames) {
    # Ensure the client package is present on every client-serving DP (see the
    # $ensureClientPkgCoverage definition near the top). Runs on the fresh-deploy
    # path; the "BGs already exist" early-return above calls the same scriptblock.
    & $ensureChildBgFallbackDps
    & $ensureClientPkgCoverage
}
else {
    Write-DscStatus "Skipping Client Push. No Clients to push."
    $Configuration.InstallClient.Status = 'Completed'
    $Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

if ($false) {
    #Let PushClients.ps1 handle this later.
    $ClientNameList = $ClientNames.split(",")
    $machinelist = (get-cmdevice -CollectionName $CollectionName).Name
    Start-Sleep -Seconds 5

    foreach ($client in $ClientNameList) {

        if ([string]::IsNullOrWhiteSpace($client)) {
            continue
        }

        $testClient = Test-NetConnection -ComputerName $client -CommonTCPPort SMB -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        if (-not $testClient.TcpTestSucceeded) {
            # Don't wait for client to appear in collection if it's not online
            Write-DscStatus "Could not test SMB connection to $client. Skipping."
            continue
        }

        $failCount = 0
        $success = $true
        while ($machinelist -notcontains $client) {
       
            if ($failCount -ge 2) {
                $success = $false
                break
            }
            Invoke-CMSystemDiscovery
            Invoke-CMDeviceCollectionUpdate -Name $CollectionName


            $seconds = 600
            while ($seconds -ge 0) {
                Write-DscStatus "Waiting for $client to appear in '$CollectionName'" -RetrySeconds 30
                Start-Sleep -Seconds 30
                $seconds -= 30
                $machinelist = (get-cmdevice -CollectionName $CollectionName).Name
                if ($machinelist -contains $client) {
                    Write-DscStatus "$client is in'$CollectionName'"
                    break
                }
            }

            $machinelist = (get-cmdevice -CollectionName $CollectionName).Name
            $failCount++
        }
        if ($success) {
            Write-DscStatus "Pushing client to $client."
            Install-CMClient -DeviceName $client -SiteCode $SiteCode -AlwaysInstallClient $true *>&1 | Write-StatusLogEntry
            Start-Sleep -Seconds 5
        }
    }



    # Update actions file
    $Configuration.InstallClient.Status = 'Completed'
    $Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
}