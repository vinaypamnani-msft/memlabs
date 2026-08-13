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

$boundaryNamespace = "root\SMS\site_$SiteCode"
$getMissingBoundaryGroupSiteSystems = {
    param($BoundaryGroup, [string[]]$DesiredSiteSystems)

    if (-not $BoundaryGroup -or -not $DesiredSiteSystems -or $DesiredSiteSystems.Count -eq 0) { return @() }
    try {
        $currentSiteSystems = @{}
        foreach ($siteSystemLink in @(Get-WmiObject -Namespace $boundaryNamespace -Class SMS_BoundaryGroupSiteSystems -Filter "GroupID='$($BoundaryGroup.GroupID)'" -ErrorAction Stop)) {
            if ("$($siteSystemLink.ServerNALPath)" -match '\\([^\\"\]]+)') {
                $currentSiteSystems[$Matches[1].ToUpper()] = $true
            }
        }
        return @($DesiredSiteSystems | Where-Object { -not $currentSiteSystems.ContainsKey("$_".ToUpper()) })
    }
    catch {
        Write-DscStatus "Could not read current site-system membership for Boundary Group '$($BoundaryGroup.Name)'; falling back to idempotent adds: $($_.Exception.Message)" -Warning
        return @($DesiredSiteSystems)
    }
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
    $bgLinks = @()
    $expectedBgObjects = @()
    try {
        $expectedBgNames = @($bgs.SiteCode | Where-Object { $_ } | Select-Object -Unique)
        $expectedBgObjects = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroup -ErrorAction Stop |
            Where-Object { $expectedBgNames -contains $_.Name })
        $expectedBgIds = @($expectedBgObjects | ForEach-Object { $_.GroupID })
        $bgLinks = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupSiteSystems -ErrorAction Stop |
            Where-Object { $expectedBgIds -contains $_.GroupID })
        $bgDpFqdns = @($bgLinks |
                ForEach-Object { & $fqdnOf $_.ServerNALPath } | Where-Object { $_ } | Select-Object -Unique)
    }
    catch { Write-DscStatus "Client pkg coverage: could not enumerate boundary-group site systems: $($_.Exception.Message)"; return }

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
    $nonDp = @($bgDpFqdns | Where-Object { -not $dpFqdnSet.ContainsKey($_.ToUpper()) })
    if ($nonDp.Count -gt 0) {
        Write-DscStatus "Client pkg coverage: excluding $($nonDp.Count) boundary-group site system(s) that are MP/SUP-only, not DPs (no client-package content lands there): $($nonDp -join ', ')"
    }
    $bgDpFqdns = @($bgDpFqdns | Where-Object { $dpFqdnSet.ContainsKey($_.ToUpper()) })

    $existingExpectedBgNames = @($expectedBgObjects | ForEach-Object { $_.Name })
    $groupsWithoutDps = @($expectedBgNames | Where-Object { $existingExpectedBgNames -notcontains $_ })
    foreach ($expectedBg in $expectedBgObjects) {
        $linkedDps = @($bgLinks | Where-Object { $_.GroupID -eq $expectedBg.GroupID } |
                ForEach-Object { & $fqdnOf $_.ServerNALPath } |
                Where-Object { $_ -and $dpFqdnSet.ContainsKey($_.ToUpper()) } |
                Select-Object -Unique)
        if ($linkedDps.Count -eq 0) { $groupsWithoutDps += $expectedBg.Name }
    }
    if ($groupsWithoutDps.Count -gt 0) {
        Write-DscStatus "Client pkg coverage: boundary group(s) have NO registered Distribution Point after membership reconciliation: $($groupsWithoutDps -join ', '). Clients in these groups cannot locate the client package." -Failure
        return
    }
    if ($bgDpFqdns.Count -eq 0) { Write-DscStatus "Client pkg coverage: no DP site systems in expected boundary groups to cover." -Failure; return }

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
    $secKeptDps = @()
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
        if ($assigned.Count -gt 0) { $keptDpFqdns += $dp; $secKeptDps += "$dp" }             # clients depend on it -> wait
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
    # $secLinkSites drives only the LINK wait, so it needs a resolvable site code. The
    # retry BUDGET must not: PT1-SS1SITE/PT1-SS2SITE were covered as secondary DPs but
    # contributed no site code here, so the budget stayed at 24 tries (720s) and the gate
    # gave up twice at exactly 742/743/744s. Track the covered secondary DPs themselves.
    $secLinkSites = @{}   # secondary siteCode -> $true (for kept secondary DPs)
    foreach ($dp in $secKeptDps) {
        $dpVm = $vmByHost[(("$dp" -split '\.')[0].ToUpper())]
        if ($dpVm -and $dpVm.siteCode) { $secLinkSites["$($dpVm.siteCode)"] = $true }
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

    # Remediation per DP is deliberately NON-destructive: keep the SMS_DistributionPoint
    # (PkgServers) targeting row alive and flip RefreshNow on it so distmgr re-processes
    # the package now instead of waiting out its 3600s sleep / 30-min retry backoff.
    $lastArm = @{}   # DP-upper -> when RefreshNow was last flipped for that DP
    $maxTries = 24
    # A CAS/parent-owned package (e.g. the client package under a child primary) has NO
    # local content yet (StoredPkgVersion=0); its content must first replicate DOWN from
    # the parent before it can land on a local DP. That inter-site transfer is slow, so
    # give it a much larger budget and (below) never tear down the targeting meanwhile.
    $maxTriesContentPending = 90
    # A secondary-site DP needs that same budget even when THIS site already holds the
    # content, because it is one MORE inter-site hop (parent distmgr -> secondary
    # despool -> secondary distmgr -> secondary DP) and the StoredPkgVersion escalation
    # below only sees a missing LOCAL copy. Measured on fabrikam: replication link went
    # Active at 23:20:30, the secondary stored the package at 23:31:11 and finished
    # adding it to its own DP at 23:31:55 -- the 24-try (~12 min) budget ran out at
    # 23:32:25, so this warned about a DP that had just gone healthy. The loop still
    # breaks the moment every DP reports Installed, so the larger budget only costs
    # wall-clock when the content genuinely has not landed.
    if ($secKeptDps.Count -gt 0) {
        $maxTries = $maxTriesContentPending
        $secWhere = if ($secLinkSites.Count -gt 0) { @($secLinkSites.Keys) -join ', ' } else { $secKeptDps -join ', ' }
        Write-DscStatus "Client pkg coverage: covering secondary-site DP(s) $secWhere -- content needs an extra parent->secondary hop, so allowing up to $maxTries tries."
    }

    # The parent already HAS our targeting change: tr_PkgServers_G_ins/upd insert a
    # PkgNotification row (Type 4) the moment DRS applies the replicated PkgServers_G row.
    # What the parent never gets is a WAKE-UP. distmgr's main loop waits on a directory
    # change in <install>\inboxes\distmgr.box or a <=3600s timeout (distmgr.cpp:
    # FindFirstChangeNotification(sDistMgrInbox, ...) + m_dwWaitSecs = 3600), and a row
    # written by SQL replication touches no file. So it sleeps out the hour and only then
    # logs "No action specified for the package ... however there may be package server
    # changes" and sends. That is the whole delay: measured mean 1,718s against the 1,800s
    # a uniform arrival into a 1-hour cycle predicts.
    # SMS_Package.AddChangeNotification() is a no-argument provider method whose entire
    # body is AddNotification(pkgid, priority, PKG_NOTIF_TYPE_PKG) (SspPackage.cpp) -- it
    # changes no package property, bumps no SourceVersion, and re-snapshots no content
    # (unlike RefreshPkgSource, which would re-send the whole 673MB package). Best-effort:
    # on failure the parent's own timer still owns the outcome, exactly as before.
    $parentFqdn = if ($ThisVM.thisParams) { "$($ThisVM.thisParams.ParentSiteServer)" } else { '' }
    $parentSite = "$($ThisVM.parentSiteCode)"
    $lastParentPoke = $null
    $lastParentFilePoke = $null
    $pokeParentDistmgr = {
        if (-not $parentFqdn -or -not $parentSite) { return $false }
        try {
            $pPkg = @(Get-WmiObject -ComputerName $parentFqdn -Namespace "root\SMS\site_$parentSite" -Class SMS_Package -Filter "PackageID='$PackageID'" -ErrorAction Stop) | Select-Object -First 1
            if (-not $pPkg) {
                Write-DscStatus "Client pkg coverage: parent site $parentSite ($parentFqdn) has no SMS_Package row for $PackageID; cannot re-notify its distmgr."
                return $false
            }
            $rc = $pPkg.AddChangeNotification()
            Write-DscStatus "Client pkg coverage: [wake-ROW] asked parent site $parentSite ($parentFqdn) to re-notify its distmgr for $PackageID (AddChangeNotification returned $($rc.ReturnValue))."
            return $true
        }
        catch {
            Write-DscStatus "Client pkg coverage: [wake-ROW] could not re-notify parent site $parentSite ($parentFqdn) distmgr for $PackageID -- $($_.Exception.Message). The parent's own timer still governs the send."
            return $false
        }
    }

    # Second, INDEPENDENT wake path, run on a deliberately DIFFERENT cadence (8 min vs the
    # row's 5) so the next build can attribute which one actually moved the parent: compare
    # these [wake-ROW]/[wake-FILE] stamps against the wake times in the pulled
    # <CAS>-Phase8-*-ClientPkgPrestage-ParentCAS-distmgr.log. They coincide only every 40 min.
    #
    # distmgr's wake handle is FindFirstChangeNotification(sDistMgrInbox, FALSE, FILE_NOTIFY_
    # CHANGE_FILE_NAME | ...), so ANY file created in distmgr.box wakes it -- but only the top
    # directory (bWatchSubtree = FALSE). Choosing an extension no enumerator matches is what
    # makes this safe: distmgr.box itself is only ever enumerated for *.STS, *.MNT, *.PXY,
    # *.TRN, *.NOT, *.CF?, *.CLM, *.DP?, *.CER*, *.DPU and *.DSU. The "*.*" sweep that deletes
    # unrecognised files ('Unknown package replication file ... delete it') runs against
    # SMS_INBOX_DISTMGR_INCOMING = distmgr.box\incoming, a SUBdirectory we must not touch.
    # .MEMLABS matches none of those, so nothing parses or deletes it -- we clean it up here.
    $pokeParentDistmgrFile = {
        if (-not $parentFqdn -or -not $parentSite) { return $false }
        # SMS_<sitecode> is the site server's own install-dir share (the CAS reads package
        # sources over it: '...from source \\<cas>\SMS_CS1\Client').
        $wakeFile = "\\$parentFqdn\SMS_$parentSite\inboxes\distmgr.box\memlabs-wake-$([guid]::NewGuid().ToString('N')).MEMLABS"
        try {
            Set-Content -LiteralPath $wakeFile -Value 'memlabs distmgr wake' -ErrorAction Stop
            Write-DscStatus "Client pkg coverage: [wake-FILE] created a distmgr.box change on parent site $parentSite ($parentFqdn) to wake its distmgr for $PackageID."
            return $true
        }
        catch {
            Write-DscStatus "Client pkg coverage: [wake-FILE] could not write to $parentFqdn distmgr.box -- $($_.Exception.Message). The parent's own timer still governs the send."
            return $false
        }
        finally {
            # Leaving it would be litter no ConfigMgr component ever collects.
            try { Remove-Item -LiteralPath $wakeFile -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
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
        # Only the parent can start this send, and only after something wakes its distmgr.
        if ($contentPendingFromParent -and (-not $lastParentPoke -or ((Get-Date) - $lastParentPoke).TotalMinutes -ge 5)) {
            $null = & $pokeParentDistmgr
            $lastParentPoke = Get-Date
        }
        if ($contentPendingFromParent -and (-not $lastParentFilePoke -or ((Get-Date) - $lastParentFilePoke).TotalMinutes -ge 8)) {
            $null = & $pokeParentDistmgrFile
            $lastParentFilePoke = Get-Date
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
            # The SMS_DistributionPoint (PkgServers) row is the one thing that matters: it
            # tells distmgr to send the content AND it is what distmgr checks before it will
            # accept the DP's status file back. With no row the copy still runs to completion
            # but the result is discarded -- "Will reject STA for DP ... as it does not exist
            # in the PkgServers table" (STATMSG 2354) -- leaving the content physically on the
            # DP and permanently un-Installed in the site DB. Restore a missing row on EVERY
            # iteration; the summarizer is not consulted because it lags the targeting table.
            $hasTgt = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$PackageID'" -ErrorAction SilentlyContinue |
                    Where-Object { (& $fqdnOf $_.ServerNALPath) -ieq $dp }).Count -gt 0
            if (-not $hasTgt) {
                try {
                    Start-CMContentDistribution -PackageId $PackageID -DistributionPointName $dp -ErrorAction Stop
                    $lastArm[$u] = Get-Date
                    Write-DscStatus "Client pkg coverage: DP '$dp' had NO targeting row (PkgServers) -> distributed to re-establish it [try $try]"
                }
                catch { Write-DscStatus "Client pkg coverage: re-establishing the targeting row for DP '$dp' failed: $($_.Exception.Message)" }
                continue
            }
            # InstallPending (1) is a distribution actually in flight -- leave it alone.
            if ($st -eq 1) { continue }
            # Re-arm at most every 5 minutes. RefreshNow is the ONLY remediation, by design.
            #
            # This runs while content is still pending from the parent too. RefreshNow does
            # not poke the LOCAL distmgr into producing content it does not have -- it writes
            # PkgServers, which replicates to the parent's PkgServers_G and is the one signal
            # that wakes the PARENT's distmgr to send the package down. Arming once is not
            # enough: cstest2 armed at 20:50, the CAS provably had the delta by 20:51
            # (RefreshTrigger=1/UpdateMask=4/Action=2) and still sent nothing for the next 50
            # minutes, while a fresh target refresh in the 08-09 run had the CAS scheduling
            # the send immediately. Space those out further, because unlike the local case
            # this can land on an inter-site transfer that is already running.
            # Remove-CMContentDistribution (the old "clean copy through the wedge" step)
            # deletes the PkgServers row and stranded the package every time it fired --
            # most recently 7s after the CAS content finally landed, killing a distribution
            # that had already reached the DP. Restarting SMS_EXECUTIVE is equally
            # destructive (it aborts content import / status publication). ConfigMgr's own
            # retry backoff (STATMSG 2326: 30 min, 100 retries) outlives this whole gate, so
            # flipping RefreshNow is what makes distmgr re-process the package now.
            $armMinutes = if ($contentPendingFromParent) { 10 } else { 5 }
            $armedAt = if ($lastArm.ContainsKey($u)) { $lastArm[$u] } else { $null }
            if ($armedAt -and ((Get-Date) - $armedAt).TotalMinutes -lt $armMinutes) { continue }
            try {
                & $redistOrDistribute $dp | Out-Null
                $lastArm[$u] = Get-Date
                if ($contentPendingFromParent) { Write-DscStatus "Client pkg coverage: DP '$dp' is $stName and site $SiteCode still has no content -> re-armed the targeting with RefreshNow so the parent sees a fresh change and sends the package [try $try]" }
                elseif ($armedAt) { Write-DscStatus "Client pkg coverage: DP '$dp' still $stName -> re-armed with RefreshNow so distmgr retries now instead of waiting out its backoff [try $try]" }
                else { Write-DscStatus "Client pkg coverage: DP '$dp' state=$stName -> redistributed (RefreshNow) [try $try]" }
            }
            catch { Write-DscStatus "Client pkg coverage: remediation on DP '$dp' failed: $($_.Exception.Message)" }
        }
        $waitDesc = @($notInstalled | ForEach-Object {
                $uw = $_.ToUpper()
                $sw = if (-not $state.ContainsKey($uw)) { 'no-row' } elseif ($stateName.ContainsKey("$($state[$uw])")) { $stateName["$($state[$uw])"] } else { "State$($state[$uw])" }
                "$_ ($sw)"
            })
        $siteContentState = if ($contentPendingFromParent) { 'PENDING FROM PARENT' } else { 'LOCAL' }
        Write-DscStatus "Client pkg coverage: waiting for client package on: $($waitDesc -join ', '); site $SiteCode content=$siteContentState (StoredPkgVersion=$storedVer) [$try/$maxTries]"
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
            $sInfo = if ($state.ContainsKey($u)) { "State=$($stateName["$($state[$u])"]) DPSourceVersion=$($stateVer[$u]) vs pkg=$pkgSourceVersion" } else { "no summarizer row" }
            if (-not $state.ContainsKey($u)) {
                # "never targeted, or not yet reported" was a coin toss, and the two halves
                # need opposite fixes. The TARGETING table (SMS_DistributionPoint) answers it
                # outright: a row means distribution WAS requested and only the summarizer is
                # missing/lagging (with PkgLib holding the .INI that means the content landed
                # but the site DB never recorded it -- so the MP hands clients no DP location
                # and ccmsetup wedges in GetDPLocations, which is exactly what CS4 did). No row
                # means the (re)distribute never took and the repair ladder is the problem.
                try {
                    $tgt = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$PackageID'" -ErrorAction SilentlyContinue |
                            Where-Object { (& $fqdnOf $_.ServerNALPath) -ieq $dp }) | Select-Object -First 1
                    if ($tgt) {
                        $sInfo = "no summarizer row BUT targeting row EXISTS (SMS_DistributionPoint: SiteCode=$($tgt.SiteCode) StoredPkgVersion=$($tgt.StoredPkgVersion) SourceVersion=$($tgt.SourceVersion) LastRefresh=$($tgt.LastRefreshTime)) -> distribution WAS requested; the site DB just never got an Installed status back"
                    }
                    else {
                        $sInfo = 'no summarizer row AND no targeting row (SMS_DistributionPoint) -> the (re)distribute never created a distribution for this DP'
                    }
                }
                catch { $sInfo = "no summarizer row; targeting-row query failed: $($_.Exception.Message)" }
            }
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
                    $o = [ordered]@{ PkgLib = ''; ContentLib = ''; Distmgr = ''; PkgXfer = ''; Despool = ''; Sender = ''; Exec = ''; DpProv = '' }
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
                    # smsdpprov.log -- the DP's OWN content-import + status-publication log,
                    # and the ONLY one of these that exists on a remote DP (no SMS install dir
                    # -> every grab above returns empty, which is why CS4-DPMP1's diagnostics
                    # were blank). This is where "content is in PkgLib but the site never saw
                    # an Installed row" is explained.
                    try {
                        $dpProvLog = $null
                        foreach ($d in @('E:', 'D:', 'F:', 'C:')) {
                            $cand = "$d\SMS_DP`$\sms\logs\smsdpprov.log"
                            if (Test-Path $cand) { $dpProvLog = $cand; break }
                        }
                        if ($dpProvLog) {
                            $o.DpProv = "$dpProvLog :: " + (& $grab $dpProvLog 10 "$pkgId|Failed|error|0x8|ContentLibrary|AddFile|CreateContent|signature|Import")
                        }
                        else {
                            $o.DpProv = 'smsdpprov.log not found (SMS_DP$ share/log missing -> the DP role may not be fully installed on this server)'
                        }
                    }
                    catch { $o.DpProv = "smsdpprov.log read threw: $($_.Exception.Message)" }
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
                if ($diag.DpProv) { Write-DscStatus "Client pkg coverage diag [$dp] smsdpprov: $($diag.DpProv)" -Warning }
                if ($diag.PkgXfer) { Write-DscStatus "Client pkg coverage diag [$dp] PkgXferMgr: $($diag.PkgXfer)" -Warning }
                if ($diag.Despool) { Write-DscStatus "Client pkg coverage diag [$dp] despool: $($diag.Despool)" -Warning }
                if ($diag.Sender) { Write-DscStatus "Client pkg coverage diag [$dp] sender: $($diag.Sender)" -Warning }
            }
            catch { Write-DscStatus "Client pkg coverage diag [$dp]: remote query failed (WinRM?): $($_.Exception.Message)" -Warning }
        }
    }

    if ($pushClients) {
        Invoke-CMSystemDiscovery
        Invoke-CMDeviceCollectionUpdate -Name "All Systems"
    }
    else {
        Write-DscStatus "Client pkg coverage: skipping post-coverage discovery refresh because there are no client-push targets."
    }
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
            $childBoundaryGroup = Get-CMBoundaryGroup -Name $childSite -ErrorAction SilentlyContinue
            if (-not $childBoundaryGroup) { continue }
            try {
                $missingParentDps = @(& $getMissingBoundaryGroupSiteSystems $childBoundaryGroup $parentDps)
                if ($missingParentDps.Count -gt 0) {
                    Set-CMBoundaryGroup -Name $childSite -AddSiteSystemServerName $missingParentDps -ErrorAction Stop
                    Write-DscStatus "Added parent DP fallback(s) $($missingParentDps -join ',') to child Boundary Group '$childSite'"
                }
                else {
                    Write-DscStatus "Child Boundary Group '$childSite' already contains all parent DP fallback(s) -- skipping provider write"
                }
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
        $IPBits = [int[]]$bg.Subnet.Split('.')
        $MaskBits = [int[]]'255.255.255.0'.Split('.')
        $NetworkIDBits = 0..3 | ForEach-Object { $IPBits[$_] -band $MaskBits[$_] }
        $BroadcastBits = 0..3 | ForEach-Object { $NetworkIDBits[$_] + ($MaskBits[$_] -bxor 255) }
        $NetworkID = $NetworkIDBits -join '.'
        $NetworkIDBits[3] = 1
        $BroadcastBits[3] = 254
        $rangeValue = "$(($NetworkIDBits -join '.'))-$(($BroadcastBits -join '.'))"
        $boundaryName = "$DomainFullName/$($bg.SiteCode)/$NetworkID/24"
        $boundary = Get-CMBoundary -BoundaryName $boundaryName -ErrorAction SilentlyContinue
        if (-not $boundary) { $boundary = Get-CMBoundary -BoundaryName $bg.Subnet -ErrorAction SilentlyContinue }
        if (-not $boundary) { $boundary = Get-CMBoundary | Where-Object { $_.BoundaryType -eq 3 -and $_.Value -eq $rangeValue } }
        if (-not $boundary) {
            $allBGsExist = $false
            break
        }
        # Verify boundary is actually in its group
        $memberOf = @(Get-CMBoundary -BoundaryGroupName $bg.SiteCode -ErrorAction SilentlyContinue)
        if (-not ($memberOf | Where-Object { $_.BoundaryID -eq $boundary.BoundaryID -or $_.DisplayName -eq $boundary.DisplayName })) {
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
        # A DP/MP/SUP can be added after its boundary group already exists (for
        # example, an add-on SiteSystem deployment). The old early-return path
        # never reconciled site-system membership, so the new DP remained outside
        # the BG and the client-package coverage gate could neither see nor target
        # it. Add every currently registered site system before checking content.
        foreach ($bgsitecode in ($bgs.SiteCode | Select-Object -Unique)) {
            $boundaryGroup = Get-CMBoundaryGroup -Name $bgsitecode -ErrorAction SilentlyContinue
            if (-not $boundaryGroup) { continue }
            $sitesystems = @()
            $sitesystems += (Get-CMDistributionPoint -SiteCode $bgsitecode -ErrorAction SilentlyContinue).NetworkOSPath -replace "\\", ""
            $sitesystems += (Get-CMManagementPoint -SiteCode $bgsitecode -ErrorAction SilentlyContinue).NetworkOSPath -replace "\\", ""
            $sitesystems += (Get-CMSoftwareUpdatePoint -SiteCode $bgsitecode -ErrorAction SilentlyContinue).NetworkOSPath -replace "\\", ""
            $sitesystems = @($sitesystems | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
            if ($sitesystems.Count -eq 0) { continue }
            try {
                $missingSiteSystems = @(& $getMissingBoundaryGroupSiteSystems $boundaryGroup $sitesystems)
                if ($missingSiteSystems.Count -gt 0) {
                    Set-CMBoundaryGroup -Name $bgsitecode -AddSiteSystemServerName $missingSiteSystems -ErrorAction Stop
                    Write-DscStatus "Added missing Site Systems to Boundary Group '$bgsitecode': $($missingSiteSystems -join ',')"
                }
                else {
                    Write-DscStatus "Boundary Group '$bgsitecode' already contains all registered Site Systems -- skipping provider write"
                }
            }
            catch {
                Write-DscStatus "Could not reconcile Site Systems in Boundary Group '$bgsitecode': $($_.Exception.Message)" -Warning
            }
        }
        # Even when BGs are already configured (re-run / steady state), still ensure
        # the client package is on every client-serving DP. This early-return used to
        # skip the coverage repair further down, so a DP stuck at ContentValidating
        # never self-healed on a Phase 8 re-run.
        # Coverage is NOT gated on client PUSH: Phase 11's ClientPkg check hard-fails
        # whenever a boundary-group DP lacks the client package, and clients installed
        # by ANY method (push, SCP/GPO, manual) pull ccmsetup content from that DP. A
        # no-push lab (pushClient=false) must still get the client package onto its DP.
        & $ensureChildBgFallbackDps
        & $ensureClientPkgCoverage
        # Still handle client push path
        if (-not $pushClients) {
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
    $boundaryGroupChanged = $false

    try {
        $exists = Get-CMBoundaryGroup -Name $bgsitecode -ErrorAction SilentlyContinue
        if ($exists) {
            if ($sitesystems) {
                $missingSiteSystems = @(& $getMissingBoundaryGroupSiteSystems $exists $sitesystems)
                if ($missingSiteSystems.Count -gt 0) {
                    Write-DscStatus "Adding missing Site Systems to Boundary Group '$bgsitecode': $($missingSiteSystems -join ',')"
                    Set-CMBoundaryGroup -Name $bgsiteCode -AddSiteSystemServerName $missingSiteSystems -ErrorAction Stop
                    $boundaryGroupChanged = $true
                }
                else {
                    Write-DscStatus "Boundary Group '$bgsitecode' already contains all registered Site Systems -- skipping provider write"
                }
            }
            else {
                Write-DscStatus "Boundary Group '$bgsitecode' already exists; no site systems registered yet to add (site '$bgsitecode' still installing)"
            }
        }
        else {
            if ($sitesystems) {
                Write-DscStatus "Creating Boundary Group '$bgsitecode' with Site Systems $($sitesystems -join ',') in sitecode $SiteCode"
                New-CMBoundaryGroup -Name $bgsitecode -DefaultSiteCode $bgDefaultSite -AddSiteSystemServerName $sitesystems -ErrorAction Stop
                $boundaryGroupChanged = $true
            }
            else {
                # Site row exists but no site systems registered yet (secondary
                # still installing). Create the group now so it EXISTS + replicates;
                # the DP is added when it comes online (later pass / re-run).
                Write-DscStatus "Creating Boundary Group '$bgsitecode' (site '$bgsitecode' still installing - no site systems yet; DP added on a later pass) in sitecode $SiteCode"
                New-CMBoundaryGroup -Name $bgsitecode -DefaultSiteCode $bgDefaultSite -ErrorAction Stop
                $boundaryGroupChanged = $true
            }
        }
    }
    catch {
        Write-DscStatus "Failed to create Boundary Group '$bgsitecode' in sitecode $SiteCode. Error: $_"
    }
    if ($boundaryGroupChanged) { Start-Sleep -Seconds 5 }
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
    $boundaryChanged = $false
    if ($exists) {
        $boundaryGroupMembers = @(Get-CMBoundary -BoundaryGroupName $bg.SiteCode -ErrorAction SilentlyContinue)
        $alreadyMember = @($boundaryGroupMembers | Where-Object { $_.BoundaryID -eq $exists.BoundaryID -or $_.DisplayName -eq $exists.DisplayName }).Count -gt 0
        if ($alreadyMember) {
            Write-DscStatus "Boundary '$($exists.DisplayName)' is already in Boundary Group $($bg.SiteCode) -- skipping provider write"
        }
        else {
            try {
                Write-DscStatus "Adding Boundary '$($exists.DisplayName)' ($rangeValue) to Boundary Group $($bg.SiteCode)"
                Add-CMBoundaryToGroup -BoundaryName $exists.DisplayName -BoundaryGroupName $bg.SiteCode -ErrorAction Stop
                $boundaryChanged = $true
            }
            catch {
                Write-DscStatus "Failed to add boundary '$($exists.DisplayName)' to Boundary Group '$($bg.SiteCode)'. Error: $_"
            }
        }
    }
    else {
        try {
            Write-DscStatus "Creating Boundary '$boundaryName' with range $rangeValue"
            New-CMBoundary -Type IPRange -Name $boundaryName -Value $rangeValue -ErrorAction Stop
            $boundaryChanged = $true
            try {
                Add-CMBoundaryToGroup -BoundaryName $boundaryName -BoundaryGroupName $bg.SiteCode -ErrorAction Stop
            }
            catch {
                Write-DscStatus "Failed to add boundary '$boundaryName' to Boundary Group '$($bg.SiteCode)'. Error: $_"
            }
        }
        catch {
            Write-DscStatus "Failed to create boundary '$boundaryName'. Error: $_"
        }
    }

    if ($boundaryChanged) { Start-Sleep -Seconds 5 }
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
if ($pushClients) {
    Start-Sleep -Seconds 5
}
else {
    Write-DscStatus "No client-push targets -- skipping the 5s discovery grace period"
}

# Ensure the client package is present on every client-serving boundary-group DP
# BEFORE the no-push short-circuit below. Phase 11's ClientPkg check hard-fails if a
# boundary-group DP lacks the client package, and clients installed by ANY method
# (push, SCP/GPO, manual) pull ccmsetup content from that DP -- so coverage must NOT
# be gated on client PUSH. Previously this ran only on the push path, so a no-push
# lab (pushClient=false) returned here without ever distributing the client package
# to the new DP, failing Phase 11 with the DP stuck at ContentValidating.
& $ensureChildBgFallbackDps
& $ensureClientPkgCoverage

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