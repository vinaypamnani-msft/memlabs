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

# --- One-time recovery for a WEDGED distmgr (stuck cancel/shutdown flag) ----------
# A distmgr whose internal cancel flag (m_bShutdownRequest) is stuck TRUE stays
# RUNNING but aborts EVERY content operation with 0x800704d3 (CopyFileExW cancelled /
# TakeContentSnapshot aborted), silently blocking ALL content distribution for the
# site (nothing snapshots -> nothing replicates to child sites or DPs). CM source
# (distmgr.cpp): that flag is cleared ONLY by the CDistributionManager constructor --
# never in Initialize() or at thread (re)start -- so only a FRESH PROCESS clears it; a
# component/thread-only restart does not. A full SMS_EXECUTIVE restart is the proven
# cure (confirmed on pushlab HA/remote content library: content flowed within seconds).
# The SMS Provider is hosted by WMI (smsprov), NOT SMS_EXECUTIVE, so this recycles
# distmgr without dropping the provider connected below. Fire ONCE, and only on the
# confirmed wedge signature (many 0x800704d3 aborts, ZERO successes, executive up a
# while so it isn't a fresh/normal start -- which also prevents a restart loop).
try {
    $imDir = $null
    foreach ($ik in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $imDir = (Get-ItemProperty -Path $ik -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
        if ($imDir) { break }
    }
    $dmLog = if ($imDir) { Join-Path $imDir 'Logs\distmgr.log' } else { $null }
    if ($dmLog -and (Test-Path $dmLog)) {
        $dmTail = @(Get-Content $dmLog -Tail 800 -ErrorAction SilentlyContinue)
        $dmAborts = @($dmTail | Where-Object { $_ -match '0x800704d3' -and $_ -match 'CopyFileExW|CreatePackageBundle|TakeContentSnapshot|AddContentToBundle|SnapshotPackage|BundleLegacyContentFiles' }).Count
        $dmSucc = @($dmTail | Where-Object { $_ -match 'Created minijob to send compressed copy|Removing retry key for package' }).Count
        $exeUpMin = 999
        try {
            $exeSvc = Get-CimInstance Win32_Service -Filter "Name='SMS_EXECUTIVE'" -ErrorAction Stop
            if ($exeSvc.ProcessId -gt 0) { $exeProc = Get-Process -Id $exeSvc.ProcessId -ErrorAction SilentlyContinue; if ($exeProc) { $exeUpMin = ((Get-Date) - $exeProc.StartTime).TotalMinutes } }
        }
        catch {}
        if ($dmAborts -ge 5 -and $dmSucc -eq 0 -and $exeUpMin -gt 20) {
            Write-DscStatus "distmgr WEDGED: $dmAborts x 0x800704d3 content aborts and 0 successes in the recent log, SMS_EXECUTIVE up $([int]$exeUpMin)m -- a stuck distmgr cancel state is blocking ALL content distribution for this site. Restarting SMS_EXECUTIVE ONCE to clear it (the cancel flag is only reset by a fresh process)." -Warning
            try {
                Restart-Service -Name SMS_EXECUTIVE -Force -ErrorAction Stop
                Write-DscStatus "Restarted SMS_EXECUTIVE to clear the wedged distmgr; waiting 90s for components to resume."
                Start-Sleep -Seconds 90
            }
            catch { Write-DscStatus "Could not restart SMS_EXECUTIVE to clear the wedged distmgr: $($_.Exception.Message)" -Warning }
        }
    }
}
catch {}

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

    # SMS_BoundaryGroupSiteSystems lists ALL site systems in a boundary group --
    # DPs, MPs AND SUPs (memlabs adds all three: Get-CMDistributionPoint +
    # Get-CMManagementPoint + Get-CMSoftwareUpdatePoint). The client PACKAGE is
    # DP content and only ever reports Installed on a DISTRIBUTION POINT, so an
    # MP/SUP-only site system (e.g. an HA Primary like the site server itself,
    # whose content library is remote and which has NO DP role) can never satisfy
    # this check -- it would spin all $maxTries and warn. Intersect with the real
    # DP list (SMS_DistributionPointInfo) so coverage only waits on actual DPs.
    $dpFqdnSet = @{}
    foreach ($d in @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPointInfo -ErrorAction SilentlyContinue)) {
        $df = & $fqdnOf $d.NALPath
        if (-not $df -and $d.ServerName) { $df = "$($d.ServerName)" }
        if ($df) { $dpFqdnSet[$df.ToUpper()] = $true }
    }
    if ($dpFqdnSet.Count -gt 0) {
        $nonDp = @($bgDpFqdns | Where-Object { -not $dpFqdnSet.ContainsKey($_.ToUpper()) })
        if ($nonDp.Count -gt 0) {
            Write-DscStatus "Client pkg coverage: excluding $($nonDp.Count) boundary-group site system(s) that are MP/SUP-only, not DPs (no client-package content lands there): $($nonDp -join ', ')"
        }
        $bgDpFqdns = @($bgDpFqdns | Where-Object { $dpFqdnSet.ContainsKey($_.ToUpper()) })
    }
    if ($bgDpFqdns.Count -eq 0) { Write-DscStatus "Client pkg coverage: no DP site systems in boundary groups to cover."; return }

    # A SECONDARY-site DP only receives the client package via slow inter-site
    # content replication (parent Primary -> secondary despool -> secondary distmgr),
    # and only AFTER the secondary is fully installed + its replication link is Active
    # -- which frequently isn't true yet when this Phase 8 gate runs, so waiting on it
    # burns the whole budget and warns. That wait is only worth taking when a client
    # actually DEPENDS on that secondary's DP. So: if any push client is assigned to
    # the secondary (its resolved pushClient site code == the secondary's site code,
    # or a legacy pushClient=$true client sits on the secondary's own subnet), WAIT
    # for it as before; if NONE are, SKIP it (the parent-Primary DPs still cover every
    # boundary, and the content will arrive on its own via normal inter-site
    # replication -- Phase 11 re-checks). Non-secondary DPs are always waited on.
    $vmByHost = @{}
    foreach ($v in @($deployConfig.virtualMachines)) { if ($v.vmName) { $vmByHost["$($v.vmName)".ToUpper()] = $v } }
    $secSkipped = @()
    $keptDpFqdns = @()
    foreach ($dp in $bgDpFqdns) {
        $dpHost = ("$dp" -split '\.')[0].ToUpper()
        $dpVm = $vmByHost[$dpHost]
        if (-not $dpVm -or $dpVm.role -ne 'Secondary') { $keptDpFqdns += $dp; continue }   # not a secondary -> always cover
        $secSite = "$($dpVm.siteCode)"
        $secNet = "$($dpVm.network)"
        $assigned = @($deployConfig.virtualMachines | Where-Object {
                ($_.pushClient -ne $false) -and (
                    ("$($_.pushClient)" -eq $secSite) -or
                    (($_.pushClient -eq $true) -and $secNet -and ("$($_.network)" -eq $secNet))
                )
            })
        if ($assigned.Count -gt 0) { $keptDpFqdns += $dp }                                  # clients depend on it -> wait
        else { $secSkipped += "$dp" }                                                       # no clients -> skip
    }
    $bgDpFqdns = @($keptDpFqdns)
    if ($secSkipped.Count -gt 0) {
        Write-DscStatus "Client pkg coverage: skipping $($secSkipped.Count) secondary-site DP(s) with NO push clients assigned (parent-Primary DPs still serve those boundaries; client package will arrive via normal inter-site replication): $($secSkipped -join ', ')"
    }
    if ($bgDpFqdns.Count -eq 0) { Write-DscStatus "Client pkg coverage: no DP site systems require client-package coverage."; return }

    # We ARE covering one or more secondary-site DPs (clients depend on them).
    # Content can't land on a secondary DP until that secondary's replication link
    # to this parent is Active -- until then the parent's distmgr logs "...is not an
    # active site, ignore it" and sends nothing, so spinning the content escalations
    # is pointless. Gate the content wait on link activation, 30 min max (a secondary
    # that just finished installing still needs DRS init + link Active). If the link
    # is still not Active after 30 min, warn and fall through: the parent-Primary DPs
    # still serve every boundary, and Phase 11 re-checks + collects link diagnostics.
    $secLinkSites = @{}   # secondary siteCode -> $true (for kept secondary DPs)
    foreach ($dp in $bgDpFqdns) {
        $dpVm = $vmByHost[(("$dp" -split '\.')[0].ToUpper())]
        if ($dpVm -and $dpVm.role -eq 'Secondary' -and $dpVm.siteCode) { $secLinkSites["$($dpVm.siteCode)"] = $true }
    }
    if ($secLinkSites.Count -gt 0) {
        $linkDeadline = (Get-Date).AddMinutes(30)
        $pendingLink = @($secLinkSites.Keys)
        while ($pendingLink.Count -gt 0 -and (Get-Date) -lt $linkDeadline) {
            $stillPending = @()
            foreach ($sc in $pendingLink) {
                $isActive = $false
                try {
                    $rs = Get-CMDatabaseReplicationStatus -Site2 $sc -ErrorAction SilentlyContinue
                    # LinkStatus/GlobalState enum: 2 = Active (both directions must be Active).
                    if ($rs -and [int]$rs.LinkStatus -eq 2 -and [int]$rs.Site1ToSite2GlobalState -eq 2 -and [int]$rs.Site2ToSite1GlobalState -eq 2) { $isActive = $true }
                }
                catch {}
                if ($isActive) { Write-DscStatus "Client pkg coverage: secondary '$sc' replication link is Active -- client-package content can now flow." }
                else { $stillPending += $sc }
            }
            $pendingLink = @($stillPending)
            if ($pendingLink.Count -gt 0) {
                $remainMin = [int]((($linkDeadline) - (Get-Date)).TotalMinutes)
                if ($remainMin -lt 0) { $remainMin = 0 }
                Write-DscStatus "Client pkg coverage: waiting for secondary replication link(s) to be Active before the client-package wait: $($pendingLink -join ', ') [~${remainMin}m left of 30m]"
                Start-Sleep -Seconds 30
            }
        }
        if ($pendingLink.Count -gt 0) {
            Write-DscStatus "Client pkg coverage: secondary replication link(s) still NOT Active after 30 min: $($pendingLink -join ', '). Proceeding with the client-package wait anyway (content can't arrive until the link activates; Phase 11 re-checks and collects link diagnostics)." -Warning
        }
    }

    # Site servers (CAS/Primary/Secondary) run SMS_EXECUTIVE + distmgr. Restarting a
    # site server's executive sets distmgr's thread-exit flag (m_bShutdownRequest) and
    # ABORTS any in-flight inter-site content bundle with ERROR_REQUEST_ABORTED
    # (0x800704d3) -- source-confirmed in distmgr.cpp CreatePackageBundle. So the
    # level-2 "wake distmgr" restart must NEVER target one (esp. the primary that is
    # sending content down to a secondary -- that IS the failure we're clearing).
    $siteServerHosts = @($deployConfig.virtualMachines | Where-Object { $_.role -in 'CAS', 'Primary', 'Secondary' } | ForEach-Object { "$($_.vmName)".ToUpper() })

    # Escalation ladder per DP -- a plain redistribute does NOT clear a Secondary DP
    # wedged at ContentValidating (its distmgr may be idle on a 3600s sleep cycle),
    # so escalate: (0) redistribute -> (1) remove + re-add content (force a clean
    # copy through the wedge) -> (2) restart SMS_EXECUTIVE on the DP to wake its
    # distmgr. The client package is small, so each step should settle in a minute
    # or two when it is going to work.
    $escalation = @{}   # DP-upper -> highest escalation level already applied
    $maxTries = 24
    # A CAS/parent-owned package (e.g. the client package under a child primary) has NO
    # local content yet (StoredPkgVersion=0); its content must first replicate DOWN from
    # the parent before it can land on a local DP. That inter-site transfer is slow, so
    # give it a much larger budget and (below) never tear down the targeting meanwhile.
    $maxTriesContentPending = 90
    for ($try = 1; $try -le $maxTries; $try++) {
        # Is the client package content present at THIS site yet? StoredPkgVersion=0
        # means it is still replicating down from a parent/CAS site.
        $storedVer = 0
        try { $sp = Get-WmiObject -Namespace $ns -Class SMS_Package -Filter "PackageID='$PackageID'" -ErrorAction SilentlyContinue | Select-Object -First 1; if ($sp) { $storedVer = [int]$sp.StoredPkgVersion } } catch {}
        $contentPendingFromParent = ($storedVer -lt 1)
        if ($contentPendingFromParent -and $maxTries -lt $maxTriesContentPending) {
            $maxTries = $maxTriesContentPending
            Write-DscStatus "Client pkg coverage: client package content has not replicated down to site $SiteCode yet (StoredPkgVersion=0; source is a parent/CAS site). Waiting for the parent to send content (up to ~45 min) and NOT tearing down the DP targeting that signals it."
        }
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
                elseif ($contentPendingFromParent) {
                    # Content isn't at this site yet -> the DP CANNOT receive it until the
                    # parent/CAS sends it down. Removing/re-adding or restarting only tears
                    # down the SMS_DistributionPoint row that signals the parent (observed:
                    # it stranded the client package at 'no-row' while a sibling CAS package
                    # that kept its targeting flowed down fine). Only re-establish a vanished
                    # targeting row; otherwise just wait for the content to replicate down.
                    $hasTgt = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$PackageID'" -ErrorAction SilentlyContinue |
                            Where-Object { (& $fqdnOf $_.ServerNALPath) -ieq $dp }).Count -gt 0
                    if (-not $hasTgt) {
                        Start-CMContentDistribution -PackageId $PackageID -DistributionPointName $dp -ErrorAction Stop
                        Write-DscStatus "Client pkg coverage: DP '$dp' targeting row was missing -> re-distributed to re-signal the parent; waiting for content to replicate down (StoredPkgVersion=0) [content-pending, try $try]"
                    }
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
                    # Level 2: last resort. Historically restarted SMS_EXECUTIVE on the DP
                    # to "wake" an idle secondary distmgr -- but per distmgr source
                    # (CreatePackageBundle -> SetCancelFlag(&m_bShutdownRequest); the
                    # content library returns ERROR_REQUEST_ABORTED only when that flag is
                    # set; m_bShutdownRequest is set only when the distmgr thread exits),
                    # restarting a SITE SERVER's executive ABORTS its in-flight inter-site
                    # content bundle with 0x800704d3 -- the very failure this remediation is
                    # meant to clear (self-inflicted on the primary PL-MELT sending to the
                    # secondary). NEVER restart a site server's executive; let distmgr retry.
                    $dpHost = ("$dp" -split '\.')[0]
                    if ($siteServerHosts -contains $dpHost.ToUpper()) {
                        Write-DscStatus "Client pkg coverage: DP '$dp' is a SITE SERVER -> NOT restarting SMS_EXECUTIVE (that aborts in-flight inter-site content bundles: distmgr 0x800704d3). Leaving distmgr to retry uninterrupted. [esc.2, try $try]" -Warning
                    }
                    else {
                        try {
                            $svc = Get-Service -ComputerName $dpHost -Name 'SMS_EXECUTIVE' -ErrorAction Stop
                            Restart-Service -InputObject $svc -Force -ErrorAction Stop
                            Write-DscStatus "Client pkg coverage: DP '$dp' still $stName -> restarted SMS_EXECUTIVE on '$dpHost' to wake distmgr [esc.2, try $try]"
                        }
                        catch { Write-DscStatus "Client pkg coverage: could not restart SMS_EXECUTIVE on '$dpHost' (WinRM/RPC?): $($_.Exception.Message)" }
                    }
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
                    $o = [ordered]@{ PkgLib = ''; ContentLib = ''; Distmgr = ''; PkgXfer = ''; Despool = ''; Sender = ''; Exec = '' }
                    # Resolve the ACTUAL content library root from the DP registry. For an
                    # HA site the library is RELOCATED to a remote share (\\<FileServer>\...
                    # via remoteContentLibVM), so the old hard-coded E:/D:/F:/C:\SCCMContentLib
                    # probe gave a FALSE "PkgLib MISSING -> content never arrived" plus no
                    # drive info. ContentLibraryPath is a UNC path on an HA site.
                    $clRoot = $null; $clRemote = $false
                    try {
                        $clp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\DP' -Name ContentLibraryPath -ErrorAction Stop).ContentLibraryPath
                        if ($clp) { $clRoot = "$clp"; $clRemote = ($clRoot -like '\\*') }
                    } catch {}
                    if (-not $clRoot) {
                        foreach ($cl in @('E:\SCCMContentLib', 'D:\SCCMContentLib', 'F:\SCCMContentLib', 'C:\SCCMContentLib')) {
                            if (Test-Path (Join-Path $cl 'PkgLib')) { $clRoot = $cl; break }
                        }
                    }
                    if ($clRoot) {
                        $pl = Join-Path $clRoot 'PkgLib'
                        $reach = Test-Path $pl
                        if ($reach) { $o.PkgLib = (@(Get-ChildItem $pl -Filter "$pkgId*.INI" -ErrorAction SilentlyContinue).Name) -join ',' }
                        if ($clRemote) {
                            $clHostName = ($clRoot -replace '^\\\\', '' -split '\\')[0]
                            $o.ContentLib = "REMOTE content library '$clRoot' (HA remoteContentLibVM) host=$clHostName reachable=$reach"
                        }
                        else {
                            try { $drv = Get-PSDrive -Name ($clRoot.Substring(0, 1)) -ErrorAction Stop; $o.ContentLib = "LOCAL content library '$clRoot' drive free=$([math]::Round($drv.Free / 1GB, 1))GB" } catch { $o.ContentLib = "LOCAL content library '$clRoot'" }
                        }
                    }
                    $smsDir = $null
                    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
                        try { $smsDir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
                        if ($smsDir) { break }
                    }
                    if ($smsDir) {
                        $logs = Join-Path $smsDir 'Logs'
                        # distmgr: package activity + inter-site bundle / cert-decrypt /
                        # content-library-write (HA remote content lib) faults.
                        $o.Distmgr = & $grab (Join-Path $logs 'distmgr.log') 8 "$pkgId|creating package bundle|0x800704d3|hasn.t arrived|Failed to decrypt|PFX|No content destination|CopyFileExW|Failed to add the file|TakeContentSnapshot"
                        # PkgXferMgr: pull-DP + inter-site send failures (STATMSG 8211).
                        $o.PkgXfer = & $grab (Join-Path $logs 'PkgXferMgr.log') 4 "$pkgId|8211|Failed|error|abort"
                        # despool: the RECEIVING (child/secondary) side unpacking bundles.
                        $o.Despool = & $grab (Join-Path $logs 'despool.log') 4 "$pkgId|bundle|0x800704d3|decrypt|instruction"
                        # sender: the SENDING side inter-site transfer.
                        $o.Sender = & $grab (Join-Path $logs 'sender.log') 3 "$pkgId|Error|0x8|failed|retry"
                    }
                    # SMS_EXECUTIVE forensics: a 0x800704d3 bundle abort means this site's
                    # executive/distmgr was STOPPED mid-build. Show when it last started and
                    # how many SCM start/stop (event 7036) entries it logged in the last 2h --
                    # a high count = a restart LOOP = the real root cause of the inter-site
                    # abort (find + stop whatever keeps bouncing the service).
                    try {
                        $exe = Get-CimInstance Win32_Service -Filter "Name='SMS_EXECUTIVE'" -ErrorAction Stop
                        $startedNote = ''
                        if ($exe.ProcessId -gt 0) { $pp = Get-Process -Id $exe.ProcessId -ErrorAction SilentlyContinue; if ($pp) { $startedNote = " up since $($pp.StartTime.ToString('MM-dd HH:mm:ss'))" } }
                        $recent = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7036; StartTime = (Get-Date).AddHours(-2) } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'SMS_EXECUTIVE' })
                        $o.Exec = "State=$($exe.State)$startedNote; $($recent.Count) SCM start/stop (7036) events in last 2h"
                    }
                    catch {}
                    # distmgr COMPONENT state (SMS_ComponentSummarizer): the service-level
                    # 7036 check above CANNOT see a component that is RUNNING but WEDGED
                    # (thread alive, but Status=Critical because every op is aborting).
                    # Status: 0=OK, 1=Warning, 2=Critical.
                    try {
                        $scNs = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
                        $dmc = Get-CimInstance -Namespace "root\SMS\site_$scNs" -ClassName SMS_ComponentSummarizer -Filter "ComponentName='SMS_DISTRIBUTION_MANAGER'" -ErrorAction Stop | Select-Object -First 1
                        if ($dmc) { $o.Exec += "; distmgr component State=$($dmc.State) Status=$($dmc.Status)(0=OK/1=Warn/2=Critical)" }
                    }
                    catch {}
                    return $o
                }
                $pkgLibNote = if ($diag.PkgLib) { "PkgLib HAS [$($diag.PkgLib)]" } elseif ($diag.ContentLib -match 'REMOTE') { "$PackageID not yet listed in the content library" } else { "PkgLib MISSING $PackageID -> content never arrived on this DP" }
                Write-DscStatus "Client pkg coverage diag [$dp]: summarizer $sInfo ; $pkgLibNote ; $($diag.ContentLib)" -Warning
                if ($diag.Distmgr) { Write-DscStatus "Client pkg coverage diag [$dp] distmgr: $($diag.Distmgr)" -Warning }
                # Source-confirmed (distmgr.cpp CreatePackageBundle ->
                # SetCancelFlag(&m_bShutdownRequest); the content library returns
                # ERROR_REQUEST_ABORTED ONLY when that flag is set; m_bShutdownRequest is
                # set ONLY when the distmgr thread is exiting): a 0x800704d3 on an inter-
                # site bundle means the SENDING site's SMS_EXECUTIVE/distmgr was STOPPED or
                # RESTARTED mid-build. This is NOT benign -- if it keeps happening,
                # something keeps bouncing the sending site's executive; that restarter is
                # the ROOT CAUSE to hunt (see the executive forensics line below).
                if ($diag.Distmgr -match 'creating package bundle' -and $diag.Distmgr -match '0x800704d3') {
                    Write-DscStatus "Client pkg coverage diag [$dp]: 0x800704d3 = ERROR_REQUEST_ABORTED -- the inter-site content bundle was aborted because the SENDING site's SMS_EXECUTIVE/distmgr was STOPPED/RESTARTED mid-build (source: distmgr's bundle cancel flag is the thread-exit m_bShutdownRequest). NOT benign if persistent: find + stop whatever keeps restarting SMS_EXECUTIVE on the sending site (see executive forensics)." -Warning
                }
                # A 0x800704d3 on a CopyFileExW / TakeContentSnapshot / AddFile to the
                # content library = the WRITE to the content library was aborted. On an HA
                # site the library is REMOTE (\\<FileServer>); if the site server can't
                # populate it, NO package snapshots -> NOTHING distributes anywhere (every
                # package fails, not just the client package). This is the site-wide root
                # cause and outranks the per-DP symptoms above.
                if ($diag.Distmgr -match 'CopyFileExW|TakeContentSnapshot|Failed to add the file' -and $diag.Distmgr -match '0x800704d3') {
                    Write-DscStatus "Client pkg coverage diag [$dp]: 0x800704d3 writing to the content library ($($diag.ContentLib)) -- content snapshot ABORTED. If the library is REMOTE (HA remoteContentLibVM), verify the FileServer host is UP and the site server's machine account can WRITE the ContentLib share; a broken remote content library blocks ALL content distribution for the whole site." -Warning
                }
                if ($diag.Exec) { Write-DscStatus "Client pkg coverage diag [$dp] SMS_EXECUTIVE: $($diag.Exec)" -Warning }
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
        # Coverage is NOT gated on client PUSH: Phase 11's ClientPkg check hard-fails
        # whenever a boundary-group DP lacks the client package, and clients installed
        # by ANY method (push, SCP/GPO, manual) pull ccmsetup content from that DP. A
        # no-push lab (pushClient=false) must still get the client package onto its DP.
        if (-not $ThisVm.thisParams.PassiveNode) {
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

# Ensure the client package is present on every client-serving boundary-group DP
# BEFORE the no-push short-circuit below. Phase 11's ClientPkg check hard-fails if a
# boundary-group DP lacks the client package, and clients installed by ANY method
# (push, SCP/GPO, manual) pull ccmsetup content from that DP -- so coverage must NOT
# be gated on client PUSH. Previously this ran only on the push path, so a no-push
# lab (pushClient=false) returned here without ever distributing the client package
# to the new DP, failing Phase 11 with the DP stuck at ContentValidating.
if (-not $ThisVm.thisParams.PassiveNode) {
    & $ensureChildBgFallbackDps
    & $ensureClientPkgCoverage
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
    # Client-package coverage already ensured above (runs regardless of push).
    $null = $ClientNames
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