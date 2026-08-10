#perfloading.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

$Tag = "[perfloading]"
$perfloadingTimer = [System.Diagnostics.Stopwatch]::StartNew()

Write-DscStatus "$Tag Starting perfloading"

    if ( -not $ConfigFilePath) {
        $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
    }

    # Read config json
    $deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

    # Resolve per-VM cmOptions: this runs on a specific top-level site server,
    # so prefer its stamped block over the global mirror (multi-hierarchy safe).
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
    $cmo = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }

    if ($cmo.PrePopulateObjects -ne $true) {
        return
    }

    # dot source functions
    . $PSScriptRoot\ScriptFunctions.ps1

    # Get required values from config
    $DomainFullName = $deployConfig.parameters.domainName
    $DN = 'DC=' + $DomainFullName.Replace('.', ',DC=')   
    # $ThisMachineName / $ThisVM / $cmo already resolved above (before PrePopulateObjects gate).
    $CurrentRole = $ThisVM.role
    # Top-level = CAS or standalone Primary (no parent). Child Primaries in a
    # hierarchy cannot run hierarchy-level cmdlets (site features, default
    # client settings, custom client setting creation/deployment).
    $isTopLevel = ($CurrentRole -eq 'CAS') -or (-not $ThisVM.parentSiteCode)
    $CMInstallDir = $ThisVM.CMInstallDir
    # Read Site Code from registry
    #Write-DscStatus "$Tag Setting PS Drive for ConfigMgr" -NoStatus
    $SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
    $ProviderMachineName = $ThisMachineName + "." + $DomainFullName # SMS Provider machine name

    # Get CM module path
    $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
    $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
    $uiInstallPath = $subKey.GetValue("UI Installation Directory")
    $modulePath = $uiInstallPath + "bin\ConfigurationManager.psd1"
    $initParams = @{}

    # Import the ConfigurationManager.psd1 module
    if ($null -eq (Get-Module ConfigurationManager)) {
        Import-Module $modulePath
    }

    # Connect to the site's drive if it is not already present
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
    $psDriveFailcount = 0
    while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        $psDriveFailcount++
        if ($psDriveFailcount -gt 20) {
            Write-DscStatus "$Tag Failed to get the PS Drive for site $SiteCode.  Install may have failed. Check C:\ConfigMgrSetup.log" -NoStatus
            return
        }
        Write-DscStatus "$Tag Retry in 10s to Set PS Drive" -NoStatus
        Start-Sleep -Seconds 10
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
    }

    # Set the current location to be the site code.
    Set-Location "$($SiteCode):\" @initParams

    # Self-healing setup for the Office Install Targets collection. Called both
    # before the Office app deployment is created (so the deployment has a real
    # target on fresh labs) and again later for non-Office paths. Always runs:
    # creates the collection if missing, replaces stale direct-membership rules
    # (legacy) with a name-keyed WQL query rule, and updates the query expression
    # when the VM list has changed. The query auto-evaluates on the collection
    # schedule and survives ResourceID changes, so VMs added/re-discovered after
    # collection creation become members without a rebuild.
    function Set-OfficeInstallTargetsCollection {
        param($OfficeTargetVMs)
        if (-not $OfficeTargetVMs -or $OfficeTargetVMs.Count -eq 0) { return $null }
        $colName = "MEMLABS-Office Install Targets"
        $col = Get-CMDeviceCollection -Name $colName -ErrorAction SilentlyContinue
        if (-not $col) {
            try {
                $col = New-CMDeviceCollection -Name $colName -LimitingCollectionName "All Systems" -Comment "VMs targeted for Microsoft 365 Apps install" -ErrorAction Stop
                Write-DscStatus "$Tag Created collection: $colName"
            }
            catch {
                Write-DscStatus "$Tag WARNING: Failed to create Office Install Targets collection: $($_.Exception.Message)"
                return $null
            }

            # Move the new collection under the MEMLABS folder as a best-effort,
            # cosmetic step. This function is called EARLY (before the Office app
            # deployment is authored) -- ahead of the main collection loop that
            # creates \DeviceCollection\MEMLABS -- so on a fresh lab the folder
            # does not exist yet. Move-CMObject raises a TERMINATING error on a
            # missing target folder, which -ErrorAction SilentlyContinue does NOT
            # suppress; previously that bubbled into the catch above, produced a
            # misleading "Failed to create Office Install Targets collection"
            # warning, returned $null, and skipped adding the query membership
            # rule -- leaving the Office deployment pointed at an empty collection.
            # Ensure the folder exists first and keep the move non-fatal.
            try {
                if (-not (Get-CMFolder -FolderPath "\DeviceCollection\MEMLABS" -ErrorAction SilentlyContinue)) {
                    New-CMFolder -Name "MEMLABS" -ParentFolderPath "\DeviceCollection" -ErrorAction SilentlyContinue | Out-Null
                }
                Move-CMObject -FolderPath "$SiteCode`:\DeviceCollection\MEMLABS" -ObjectId $col.CollectionID -ErrorAction SilentlyContinue
            }
            catch {
                Write-DscStatus "$Tag Note: could not move '$colName' under the MEMLABS folder (cosmetic only): $($_.Exception.Message)"
            }
        }

        $nameList = ($OfficeTargetVMs | ForEach-Object { "'$($_.vmName)'" }) -join ","
        # Gate membership on Client=1 so a VM only joins the collection ONCE its CM
        # client is installed. This eliminates the app-policy projection race: if a
        # device is added while it is still a non-client, policypv snapshots it as
        # non-client and never retroactively projects the Office assignment when it
        # later becomes a client (a plain membership refresh does not re-drive the
        # per-resource app policy -- the MP then answers 'No new assignments'
        # forever). By requiring Client=1, the device becomes a BRAND-NEW member at
        # the moment it becomes a client, and new-member adds are the path policypv
        # projects app-deployment policy for reliably.
        $desiredQuery = "select SMS_R_System.ResourceID from SMS_R_System where SMS_R_System.Client = 1 and SMS_R_System.Name in ($nameList)"
        $ruleName = "Office Install Targets Rule"

        # Remove any stale direct-membership rules left behind by older builds.
        try {
            $directRules = @(Get-CMDeviceCollectionDirectMembershipRule -CollectionId $col.CollectionID -ErrorAction SilentlyContinue)
            foreach ($dr in $directRules) {
                try {
                    Remove-CMDeviceCollectionDirectMembershipRule -CollectionId $col.CollectionID -ResourceId $dr.ResourceID -Force -ErrorAction Stop
                    Write-DscStatus "$Tag Removed legacy direct-membership rule (ResourceID $($dr.ResourceID)) from $colName"
                }
                catch { }
            }
        }
        catch { }

        # Ensure the query rule exists and matches the current VM list. CM
        # normalizes the SELECT clause after the rule is created (expands to
        # ResourceID,ResourceType,Name,...), so compare on the FROM/WHERE tail
        # only to avoid pointlessly delete-and-recreating the rule every run.
        try {
            $existing = @(Get-CMDeviceCollectionQueryMembershipRule -CollectionId $col.CollectionID -ErrorAction SilentlyContinue) |
                Where-Object { $_.RuleName -eq $ruleName }
            $desiredTail = ($desiredQuery -split '(?i)\bfrom\b', 2)[1].Trim()
            $existingTail = if ($existing) { ($existing.QueryExpression -split '(?i)\bfrom\b', 2)[1].Trim() } else { $null }
            if ($existing) {
                if ($existingTail -ne $desiredTail) {
                    Remove-CMDeviceCollectionQueryMembershipRule -CollectionId $col.CollectionID -RuleName $ruleName -Force -ErrorAction SilentlyContinue
                    Add-CMDeviceCollectionQueryMembershipRule -CollectionId $col.CollectionID -QueryExpression $desiredQuery -RuleName $ruleName -ErrorAction Stop
                    Write-DscStatus "$Tag Updated query rule on $colName for: $(($OfficeTargetVMs | ForEach-Object { $_.vmName }) -join ', ')"
                }
            }
            else {
                Add-CMDeviceCollectionQueryMembershipRule -CollectionId $col.CollectionID -QueryExpression $desiredQuery -RuleName $ruleName -ErrorAction Stop
                Write-DscStatus "$Tag Added query membership rule on $colName for: $(($OfficeTargetVMs | ForEach-Object { $_.vmName }) -join ', ')"
            }
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to set Office Install Targets query rule: $($_.Exception.Message)"
        }

        Invoke-CMCollectionUpdate -CollectionId $col.CollectionID -ErrorAction SilentlyContinue

        # Enable incremental (delta) membership updates so a VM is added WITHIN
        # MINUTES of its CM client coming online (Client=1 flipping to match the
        # rule), instead of waiting for the periodic full-eval schedule. Paired
        # with the Client=1 gate above, the device is a fresh member the instant it
        # becomes a client, which is exactly when policypv will project the Office
        # deployment to it.
        try {
            Set-CMCollection -CollectionId $col.CollectionID -RefreshType Both -ErrorAction Stop
            Write-DscStatus "$Tag Enabled incremental membership updates on $colName"
        }
        catch { Write-DscStatus "$Tag WARNING: could not enable incremental updates on ${colName}: $($_.Exception.Message)" }

        # With the Client=1 gate, a target VM only becomes a member once its CM
        # client is installed. During setup some Office targets may not be clients
        # yet (client install still in flight), so 0/partial membership here is
        # EXPECTED, not an error -- incremental updates add each one the moment it
        # becomes a client and policypv projects the deployment to it then (as a
        # new member). Do a short best-effort wait only to catch the common case
        # where the target clients are already up.
        $expected = ($OfficeTargetVMs | Measure-Object).Count
        $deadline = (Get-Date).AddSeconds(60)
        $live = 0
        do {
            Start-Sleep -Seconds 5
            $live = @(Get-CMCollectionMember -CollectionId $col.CollectionID -ErrorAction SilentlyContinue).Count
        } while ($live -lt $expected -and (Get-Date) -lt $deadline)
        if ($live -ge $expected) {
            Write-DscStatus "$Tag Collection '$colName' eval complete: live members=$live/$expected (all Office targets are clients)"
        }
        else {
            Write-DscStatus "$Tag Collection '$colName' has $live/$expected client member(s) so far; remaining Office target(s) will be added + projected automatically once their CM client is installed (Client=1 gate + incremental updates)"
        }
        return $col
    }

    # Force re-authoring of an existing application deployment's policy body.
    # Required when a resource is added to the target collection AFTER the
    # deployment was originally authored: ConfigMgr does not retroactively
    # project pre-existing deployments to late-arriving collection members
    # until the deployment itself is touched. Re-saves the deployment via
    # SMS_ApplicationAssignment.Put() which bumps LastModifiedTime and causes
    # site_comp / policypv to re-project the assignment for all members.
    #
    # Implemented against WMI directly because Set-CMApplicationDeployment's
    # accepted parameters vary by SCCM build -- older SDKs reject both
    # -DeployAction and -DeployPurpose, leaving no portable cmdlet-level way
    # to force a Put(). WMI Put() works on every version.
    function Update-OfficeDeploymentPolicy {
        param([string]$AppName, [string]$CollectionName)
        try {
            $dep = Get-CMApplicationDeployment -Name $AppName -CollectionName $CollectionName -ErrorAction SilentlyContinue
            if (-not $dep) { return }
            $assignmentName = $dep.AssignmentName
            if (-not $assignmentName) { return }

            # Force a fresh collection eval and wait for live membership rows BEFORE
            # the Put(). The toggle-Put() below re-projects the assignment against
            # whatever members the site currently sees in v_FullCollectionMembership;
            # if that table is still empty (cached MemberCount can read correct
            # while the membership rows are not yet materialized), late-arriving
            # members are silently skipped. Field repro: the manual recovery that
            # finally got Office onto MOCHI was a second Invoke-CMCollectionUpdate
            # followed by client policy reset -- nothing more.
            try {
                $tgtCol = Get-CMDeviceCollection -Name $CollectionName -ErrorAction SilentlyContinue
                if ($tgtCol) {
                    Invoke-CMCollectionUpdate -CollectionId $tgtCol.CollectionID -ErrorAction SilentlyContinue
                    $deadline = (Get-Date).AddSeconds(90)
                    $live = 0
                    do {
                        Start-Sleep -Seconds 5
                        $live = @(Get-CMCollectionMember -CollectionId $tgtCol.CollectionID -ErrorAction SilentlyContinue).Count
                    } while ($live -lt 1 -and (Get-Date) -lt $deadline)
                    Write-DscStatus "$Tag Pre-Put '$CollectionName' live membership: $live"
                }
            }
            catch { }

            $escaped = $assignmentName.Replace("'", "''")
            $ass = Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_ApplicationAssignment `
                -Filter "AssignmentName='$escaped'" -ErrorAction Stop
            if (-not $ass) { return }
            # Toggle NotifyUser twice so each Put() registers an actual change
            # (PowerShell's WMI wrapper skips Put() when the assigned value
            # equals the existing value, so `$ass.NotifyUser = $ass.NotifyUser`
            # is a silent no-op). End state is identical to start state, but
            # LastModificationTime is bumped and the assignment is re-projected.
            $ass.NotifyUser = -not $ass.NotifyUser
            [void]$ass.Put()
            Start-Sleep -Seconds 1
            $ass.NotifyUser = -not $ass.NotifyUser
            [void]$ass.Put()
            Write-DscStatus "$Tag Re-authored deployment policy for '$AppName' -> '$CollectionName' (forces projection to late-added members)"
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to re-author Office deployment policy for '$AppName': $($_.Exception.Message)"
        }
    }

    #create all DPs group to distribute the content (its easier to distribute the content to a DP group than enumerating all DPs)
    $DPGroupName = "ALL DPS"
    $existingDPGroups = @(Get-CMDistributionPointGroup | Select-Object -ExpandProperty Name)

    if ($DPGroupName -in $existingDPGroups) {
        Write-DscStatus "$Tag DP group: $DPGroupName already exists"
    }
    else {
        $null = New-CMDistributionPointGroup -Name $DPGroupName -Description "Group containing all Distribution Points" -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag DP group: $DPGroupName created successfully"
    }

    # ALWAYS reconcile group membership against the current DP list -- do NOT
    # gate this on the group being newly created. "ALL DPS" is hierarchy-global
    # data: on a child Primary the group is usually created+replicated by the
    # CAS (which runs this same block first, before the role gate) BEFORE this
    # site's DP exists, so it arrives here already-existing but EMPTY (or missing
    # this site's DP). The old code only populated the group in the freshly-
    # created branch, so on the child Primary the group stayed empty and every
    # Start-CMContentDistribution -DistributionPointGroupName "ALL DPS" failed
    # with "No content destination was found" -- silently skipping boot image,
    # application, and package distribution to this site's DP. (Only the boot-
    # image call surfaced it; the app/package calls use -ErrorAction
    # SilentlyContinue and swallowed the same failure.)
    # Add-CMDistributionPointToGroup is idempotent here: a DP already in the
    # group may return success without changing anything, so resolve current
    # membership first and call it only for missing DPs.
    $serverFromNal = {
        param($NalPath)
        if ("$NalPath" -match '\\([^\\"\]]+)') { return $Matches[1] }
        return $null
    }
    $DistributionPoints = @(Get-CMDistributionPoint -AllSite)
    Write-DscStatus "$Tag Reconciling '$DPGroupName' membership against $($DistributionPoints.Count) distribution point(s)"
    $existingAllDpMemberKeys = @{}
    try {
        $allGrpWmi = Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DistributionPointGroup -Filter "Name='$DPGroupName'" -ErrorAction Stop
        if ($allGrpWmi) {
            foreach ($memberRow in @(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DPGroupMembers -Filter "GroupID='$($allGrpWmi.GroupID)'" -ErrorAction Stop)) {
                $memberHostName = & $serverFromNal $memberRow.DPNALPath
                if (-not $memberHostName) { continue }
                $existingAllDpMemberKeys[$memberHostName.ToUpper()] = $true
                $existingAllDpMemberKeys[(($memberHostName -split '\.')[0]).ToUpper()] = $true
            }
        }
    }
    catch {
        Write-DscStatus "$Tag Could not read existing '$DPGroupName' membership; falling back to idempotent adds: $($_.Exception.Message)"
    }
    foreach ($dp in $DistributionPoints) {
        $DPName = ($dp.NetworkOSPath -replace "^\\\\", "") -split "\\" | Select-Object -First 1
        $dpShortName = ($DPName -split '\.')[0]
        if ($existingAllDpMemberKeys.ContainsKey($DPName.ToUpper()) -or $existingAllDpMemberKeys.ContainsKey($dpShortName.ToUpper())) {
            Write-DscStatus "$Tag Distribution Point '$DPName' is already in '$DPGroupName' -- skipping add"
            continue
        }
        try {
            Add-CMDistributionPointToGroup -DistributionPointGroupName $DPGroupName -DistributionPointName $DPName -ErrorAction Stop
            Write-DscStatus "$Tag Added Distribution Point '$DPName' to group '$DPGroupName'"
        }
        catch {
            # Most common: DP is already a member. Benign -- log and continue.
            Write-DscStatus "$Tag DP '$DPName' not added to '$DPGroupName' (likely already a member): $($_.Exception.Message)"
        }
    }

    # VERIFY the add actually took. A silently-failed add (e.g. wrong name form,
    # like the short-name-vs-FQDN bug that left 'OSD DPS' empty) makes every
    # Start-CMContentDistribution to the group a no-op. Re-query membership from
    # WMI and WARN loudly if the group is empty despite having DPs to add.
    try {
        $allGrpWmi = Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DistributionPointGroup -Filter "Name='$DPGroupName'" -ErrorAction SilentlyContinue
        $allMemberCount = if ($allGrpWmi) { @(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DPGroupMembers -Filter "GroupID='$($allGrpWmi.GroupID)'" -ErrorAction SilentlyContinue).Count } else { 0 }
        if ($DistributionPoints.Count -gt 0 -and $allMemberCount -eq 0) {
            Write-DscStatus "$Tag WARNING: '$DPGroupName' has NO members after reconcile despite $($DistributionPoints.Count) DP(s) -- content distribution to the group will be a no-op"
        }
        else {
            Write-DscStatus "$Tag Verified '$DPGroupName' membership: $allMemberCount DP(s)"
        }
    }
    catch { Write-DscStatus "$Tag Could not verify '$DPGroupName' membership: $($_.Exception.Message)" }


    #Enable Site features (hierarchy-level — top-level site only)
    if ($isTopLevel) {
        Write-DscStatus "$Tag Enabling Site features"
        try {
            Get-CMSiteFeature -Production -Fast | Enable-CMSiteFeature -Force
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to enable site features: $_"
        }
    }

    #Applications and packages — Primary only (content sources are local)
    if ($CurrentRole -ne "CAS") {

    $apps = $deployconfig.Tools | where-object { $_.Appinstall -eq $True }
    $apps | ForEach-Object {

        $appSourceDirectory = "C:\Apps\$($_.Name)"
        $appSourceFile = "C:\tools\$($_.AppMsi)"
        $appLinkPath = Join-Path $appSourceDirectory $_.AppMsi
        if (-not (Test-Path -LiteralPath $appSourceDirectory)) {
            New-Item -ItemType Directory -Path $appSourceDirectory -Force | Out-Null
            Write-DscStatus "$Tag Created application source directory: $appSourceDirectory"
        }

        $appLinkIsCurrent = $false
        if (Test-Path -LiteralPath $appLinkPath) {
            try {
                $appLinkItem = Get-Item -LiteralPath $appLinkPath
                $appLinkIsCurrent = $appLinkItem.LinkType -eq "HardLink" -and
                    (Get-FileHash -LiteralPath $appSourceFile -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $appLinkPath -Algorithm SHA256).Hash
            }
            catch {
                Write-DscStatus "$Tag Could not verify the application source hardlink for $($_.Name); recreating it: $($_.Exception.Message)"
            }
        }
        if ($appLinkIsCurrent) {
            Write-DscStatus "$Tag Application source link is already current for $($_.Name) -- skipping filesystem write"
        }
        else {
            if (Test-Path -LiteralPath $appLinkPath) { Remove-Item -LiteralPath $appLinkPath -Force }
            New-Item -ItemType HardLink -Value $appSourceFile -Path $appLinkPath -Force | Out-Null
            Write-DscStatus "$Tag Created application source hardlink for $($_.Name)"
        }

        #creating an application
        $appname = "MEMLABS-" + "$($_.Name)"

        if (Get-CMApplication -Name "$appname" -Fast -ErrorAction SilentlyContinue) {
            Write-DscStatus "$Tag Application '$appname' already exists, skipping"
        }
        else {
            Write-DscStatus "$Tag Creating an MEMLABS application for $($_.Name) as App model"
            New-CMApplication -Name "$appname" -Description $($_.Description) -Publisher $($_.Publisher) -SoftwareVersion $($_.SoftwareVersion) -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Successfully created an MEMLABS application for $($_.Name) as App model"

            Write-DscStatus "$Tag Creating an MEMLABS application deployment for $($_.Name) as App model"
            Add-CMMSiDeploymentType -ApplicationName "$appname" -DeploymentTypeName $($_.AppMsi) -ContentLocation "\\$ThisMachineName\c$\Apps\$($_.Name)\$($_.AppMsi)" -Comment "$($_.Name) MSI deployment type" -Force -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Successfully an MEMLABS application deployment for $($_.Name) as App model"

            Write-DscStatus "$Tag Distributing MEMLABS application $($_.Name) to all DPs"
            Start-CMContentDistribution -ApplicationName "$appname" -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Successfully distributed MEMLABS application $($_.Name) to all DPs"

            Write-DscStatus "$Tag Deploying MEMLABS application $($_.Name) to all Systems as available deployment"
            New-CMApplicationDeployment -ApplicationName "$appname" -CollectionName "All Systems" -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag successfully deployed MEMLABS application $($_.Name) to all Systems as available deployment"
        }

        $pkgName = "MEMLABS-$($_.Name)"

        if (Get-CMPackage -Name "$pkgName" -Fast -ErrorAction SilentlyContinue) {
            Write-DscStatus "$Tag Package '$pkgName' already exists, skipping"
        }
        else {
            Write-DscStatus "$Tag Creating an MEMLABS application deployment for $($_.Name) as Package model"
            $Package = New-CMPackage -Name "$pkgName" -Path "\\$ThisMachineName\c$\Apps\$($_.Name)" -Description "Package for $($_.Description)"
            Write-DscStatus "$Tag Successfully created a MEMLABS application deployment for $($_.Name) as Package model"

            Write-DscStatus "$Tag Creating an MEMLABS package deployment for $($_.Name) as Package model"
            $CommandLine = "msiexec.exe /i $($_.AppMsi) /qn"
            New-CMProgram -PackageId $Package.PackageID -StandardProgramName $($_.AppMsi) -CommandLine $CommandLine 
            Write-DscStatus "$Tag Successfully created a MEMLABS package deployment for $($_.Name) as Package model"

            Write-DscStatus "$Tag Distributing MEMLABS package $($_.Name) to all DPs"
            Start-CMContentDistribution -PackageId $Package.PackageID -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Successfully distributed MEMLABS package $($_.Name) to all DPs"

            Write-DscStatus "$Tag Deploying MEMLABS package $($_.Name) to all Systems as available deployment"
            New-CMPackageDeployment -StandardProgram -PackageId $Package.PackageID -ProgramName $($_.AppMsi) -CollectionName "All Systems" -DeployPurpose Available
            Write-DscStatus "$Tag successfully deployed MEMLABS package $($_.Name) to all Systems as available deployment"
        }
    }

    #region Microsoft 365 Apps deployment via ODT (background download)
    # Check if any VMs have installOffice configured
    $officeDownloadJob = $null
    $officeVMs = @($deployConfig.virtualMachines | Where-Object { $_.installOffice -and $_.installOffice -ne $false })
    if ($officeVMs.Count -gt 0) {

        $officeAppName = "MEMLABS-Microsoft365Apps"
        $officeSourceRoot = "C:\OfficeSource"
        $officeShareName = "OfficeSource$"
        $odtPath = "C:\tools\odt"

        if (Get-CMApplication -Name $officeAppName -Fast -ErrorAction SilentlyContinue) {
            Write-DscStatus "$Tag Office application '$officeAppName' already exists, skipping Office deployment setup"
        }
        else {
            Write-DscStatus "$Tag Configuring Microsoft 365 Apps deployment for $($officeVMs.Count) VM(s)"

            # Determine unique channels needed
            $channels = @($officeVMs | ForEach-Object { $_.installOffice } | Select-Object -Unique)
            Write-DscStatus "$Tag Office channels requested: $($channels -join ', ')"

            # Channel name to ODT Channel attribute mapping
            $channelMap = @{
                'Current'           = 'Current'
                'MonthlyEnterprise' = 'MonthlyEnterprise'
                'SemiAnnual'        = 'SemiAnnualPreview'
            }

            # Kick off the ODT bootstrapper + Office source download (~2-4 GB per
            # channel) as a background job. This is pure filesystem work with no
            # ConfigMgr dependency, so it overlaps with the boot image / OSD / task
            # sequence / baseline work that follows. The matching join + ConfigMgr
            # application creation happens after the baseline section below.
            $officeDownloadScript = {
                param($jobChannels, $jobChannelMap, $jobSourceRoot, $jobOdtPath)

                $messages = New-Object System.Collections.Generic.List[string]
                $channelResults = @{}
                $odtOk = $false

                try {
                    if (-not (Test-Path "$jobOdtPath\setup.exe")) {
                        $messages.Add("Downloading Office Deployment Tool")
                        New-Item -ItemType Directory -Path $jobOdtPath -Force | Out-Null
                        $odtUrl = "https://officecdn.microsoft.com/pr/wsus/setup.exe"
                        try {
                            Invoke-WebRequest -Uri $odtUrl -OutFile "$jobOdtPath\setup.exe" -UseBasicParsing -ErrorAction Stop
                            $messages.Add("ODT downloaded successfully")
                        }
                        catch {
                            $messages.Add("WARNING: Failed to download ODT: $_. Office deployment will be skipped.")
                        }
                    }

                    if (Test-Path "$jobOdtPath\setup.exe") {
                        $odtOk = $true

                        foreach ($channel in $jobChannels) {
                            $odtChannel = $jobChannelMap[$channel]
                            if (-not $odtChannel) {
                                $messages.Add("WARNING: Unknown Office channel '$channel', defaulting to Current")
                                $odtChannel = 'Current'
                            }

                            $channelSourcePath = Join-Path $jobSourceRoot $channel
                            New-Item -ItemType Directory -Path $channelSourcePath -Force | Out-Null

                            # Generate download configuration.xml
                            $downloadXml = @"
<Configuration>
  <Add SourcePath="$channelSourcePath" OfficeClientEdition="64" Channel="$odtChannel">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
    </Product>
  </Add>
</Configuration>
"@
                            $downloadXmlPath = Join-Path $channelSourcePath "download.xml"
                            $downloadXml | Set-Content -Path $downloadXmlPath -Encoding UTF8 -Force

                            # Generate install configuration.xml
                            $installXml = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$odtChannel">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Updates Enabled="TRUE" />
  <RemoveMSI />
</Configuration>
"@
                            $installXmlPath = Join-Path $channelSourcePath "install.xml"
                            $installXml | Set-Content -Path $installXmlPath -Encoding UTF8 -Force

                            # Generate uninstall configuration.xml
                            $uninstallXml = @"
<Configuration>
  <Remove>
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
    </Product>
  </Remove>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@
                            $uninstallXmlPath = Join-Path $channelSourcePath "uninstall.xml"
                            $uninstallXml | Set-Content -Path $uninstallXmlPath -Encoding UTF8 -Force

                            # Copy ODT setup.exe into the channel source folder
                            Copy-Item "$jobOdtPath\setup.exe" -Destination $channelSourcePath -Force

                            # Download Office source files (this pulls ~2-4 GB from officecdn.microsoft.com)
                            if (-not (Test-Path (Join-Path $channelSourcePath "Office\Data"))) {
                                $messages.Add("Downloading Office source files for channel '$channel' (this may take several minutes)...")
                                $downloadProcess = Start-Process -FilePath "$channelSourcePath\setup.exe" -ArgumentList "/download `"$downloadXmlPath`"" -Wait -PassThru -NoNewWindow
                                if ($downloadProcess.ExitCode -eq 0) {
                                    $messages.Add("Office source download complete for channel '$channel'")
                                    $channelResults[$channel] = $true
                                }
                                else {
                                    $messages.Add("WARNING: ODT download for channel '$channel' exited with code $($downloadProcess.ExitCode)")
                                    $channelResults[$channel] = $false
                                }
                            }
                            else {
                                $messages.Add("Office source files already present for channel '$channel', skipping download")
                                $channelResults[$channel] = $true
                            }
                        }
                    }
                }
                catch {
                    $messages.Add("WARNING: Office download job exception: $_")
                }

                return [PSCustomObject]@{
                    OdtOk          = $odtOk
                    ChannelResults = $channelResults
                    Messages       = $messages
                }
            }

            $officeDownloadJob = Start-Job -Name "OfficeODTDownload" -ScriptBlock $officeDownloadScript -ArgumentList $channels, $channelMap, $officeSourceRoot, $odtPath
            Write-DscStatus "$Tag Started background Office source download job (runs during OSD/TS/baseline setup)"
        }
    }
    #endregion Microsoft 365 Apps deployment via ODT

    } # end Primary-only apps/packages block

    ## Hierarchy auto-approval (TwoKeyApproval) + CM-script library import.
    ## Both are Primary-tier in MEMLABS: New-CMScript on a CAS in a hierarchy
    ## is a no-op (CM Scripts are authored on the Primary; the CAS has no
    ## script library role), so the import block silently fails on every
    ## name and bloats the log. The TwoKeyApproval setting pairs with the
    ## script library and only matters where scripts actually live.
    if ($CurrentRole -ne "CAS") {

    ## Changing the auto-approval setting on Hierarchy settings

    $namespace = "ROOT\SMS\site_$SiteCode"
    $classname = "SMS_SCI_SiteDefinition"

    Write-DscStatus "$Tag Current namespace is: $namespace and class name is: $classname"

    # Fetch the instance of the class
    $instance = Get-CimInstance -ClassName $className -Namespace $namespace -Filter "SiteCode like '$SiteCode'"

    if ($null -ne $instance) {
        Write-DscStatus "$Tag Instance found: modifying existing instance."

        # Get the Props array
        $propsArray = $instance.Props

        # Locate the TwoKeyApproval property
        $propertyFound = $false
        for ($i = 0; $i -lt $propsArray.Length; $i++) {
            if ($propsArray[$i].PropertyName -eq "TwoKeyApproval") {
                $propertyFound = $true
                Write-DscStatus "$Tag Current property name is: $($propsArray[$i].PropertyName) and its value is $($propsArray[$i].Value)"
                if ([int]$propsArray[$i].Value -eq 0) {
                    Write-DscStatus "$Tag TwoKeyApproval is already 0 -- skipping provider write"
                }
                else {
                    Write-DscStatus "$Tag Setting TwoKeyApproval to 0 to allow author self-approval."
                    $propsArray[$i].Value = 0
                    $instance.Props = $propsArray
                    Set-CimInstance -InputObject $instance
                    Write-DscStatus "$Tag TwoKeyApproval value updated successfully."
                }
                break
            }
        }

        if (-not $propertyFound) {
            Write-DscStatus "$Tag Property 'TwoKeyApproval' not found in existing instance. Adding it."
      
            $class = Get-CimClass -ClassName "SMS_EmbeddedProperty" -Namespace $namespace
            $i = New-CimInstance -CimClass $class -Property @{PropertyName = "TwoKeyApproval"; Value = "0"; Value1 = $null; Value2 = $null }
            $propsArray += $i
            $instance.Props = $propsArray
            Set-CimInstance -InputObject $instance
            Write-DscStatus "$Tag TwoKeyApproval property added and value set successfully."

        }
        
    }
    else {
        Write-DscStatus "$Tag Instance not found. Manually approve the scripts"
    }
    Write-DscStatus "$Tag TwoKeyApproval reconciliation complete."


    ## Scripts ( used our scripts from Wiki)

    # Get all PowerShell script files (.ps1) in the folder and its sub folders
    $scriptReconcileTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $ScriptFiles = @(Get-ChildItem -Path C:\tools\Scripts -Recurse -Filter *.ps1)
    $existingScriptNames = @{}
    $scriptInventoryLoaded = $false
    try {
        foreach ($existingScript in @(Get-CMScript -Fast -ErrorAction Stop)) {
            if ($existingScript.ScriptName) { $existingScriptNames["$($existingScript.ScriptName)"] = $true }
        }
        $scriptInventoryLoaded = $true
    }
    catch {
        Write-DscStatus "$Tag WARNING: Could not load the script library in one query; falling back to per-script checks: $($_.Exception.Message)"
    }
    $scriptsImported = 0
    $scriptsSkipped = 0
    $scriptsFailed = 0

    # Loop through each script file and import it into SCCM
    foreach ($ScriptFile in $ScriptFiles) {
        $ScriptName = "MEMLABS-" + [System.IO.Path]::GetFileNameWithoutExtension($ScriptFile.FullName)

        # Create a new script in SCCM using New-CMScript
        try {
            $scriptExists = if ($scriptInventoryLoaded) {
                $existingScriptNames.ContainsKey($ScriptName)
            }
            else {
                $null -ne (Get-CMScript -ScriptName $ScriptName -Fast -ErrorAction Stop)
            }
            if ($scriptExists) {
                $scriptsSkipped++
                continue
            }

            $ScriptContent = Get-Content -Path $ScriptFile.FullName -Raw
            $script = New-CMScript -ScriptName "$ScriptName" -ScriptText $ScriptContent -Fast
            $scriptsImported++
            $existingScriptNames[$ScriptName] = $true
            if ($script -and $script.ScriptGuid) {
                Write-DscStatus "$Tag Successfully imported: $ScriptName"
                # Approve the script by Guid, this is not working as it requires a diff author or the checkmark to be removed (set-cmheirarchysettings doesn't have that feature yet) Tim help needed here
                Approve-CMScript -ScriptGuid $script.ScriptGuid -Comment "MEMLABS auto approved"
            }
            else {
                Write-DscStatus "$Tag Imported $ScriptName but New-CMScript returned no ScriptGuid — skipping auto-approve"
            }
        }
        catch {
            $scriptsFailed++
            Write-DscStatus "$Tag Failed to import: $ScriptName. Error: $_"
        }
    }
    $scriptReconcileTimer.Stop()
    Write-DscStatus "$Tag Script library reconcile: $scriptsImported imported, $scriptsSkipped already present, $scriptsFailed failed in $([math]::Round($scriptReconcileTimer.Elapsed.TotalSeconds, 1))s"

    } # end Primary-only TwoKeyApproval + CM-script library block


    ## Task sequences — Primary only (boot images, OSD content, local shares)
    if ($CurrentRole -ne "CAS") {

    #custom domain name in winPE (default client setting — top-level only)
    if ($isTopLevel) {
        try {
            Set-CMClientSettingComputerAgent -DefaultSetting -BrandingTitle $DomainFullName
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to set branding title: $_"
        }
    }

    # --- OSD content targeting (save DP disk space) ---------------------------
    # The multi-GB OSD content (boot images, OS images, OS upgrade packages, USMT)
    # is only useful on a DP an OSDClient can actually PXE-boot from. PXE is a
    # subnet-local DHCP broadcast, so an OSDClient can only boot from a DP on its
    # OWN subnet (cross-subnet PXE would need an ip-helper/DHCP relay we don't set
    # up). So: distribute OSD content ONLY to DP(s) that share a subnet with an
    # OSDClient, and enable PXE on those DP(s). If the lab has NO OSDClient, OSD
    # content is still created but NOT distributed anywhere (saves ~25GB per DP);
    # add an OSDClient on a DP's subnet and re-run to distribute + enable PXE.
    $OsdDpGroupName = "OSD DPS"
    $osdDefaultNet = $deployConfig.vmOptions.network
    $osdNetOf = { param($vm) if ($vm.network) { "$($vm.network)" } else { "$osdDefaultNet" } }
    $osdSubnets = @($deployConfig.virtualMachines | Where-Object { $_.role -eq 'OSDClient' } | ForEach-Object { & $osdNetOf $_ } | Where-Object { $_ } | Select-Object -Unique)
    $osdDistTarget = $null
    $hasOsdTargets = $false
    if ($osdSubnets.Count -eq 0) {
        Write-DscStatus "$Tag No OSDClient in this lab -- OSD content will be created but NOT distributed (saves DP disk space). Add an OSDClient on a DP's subnet and re-run to distribute + enable PXE."
    }
    else {
        Write-DscStatus "$Tag OSDClient subnet(s): $($osdSubnets -join ', ') -- locating same-subnet DP(s) for OSD content + PXE"
        $osdDps = @()
        foreach ($dp in @(Get-CMDistributionPoint -AllSite -ErrorAction SilentlyContinue)) {
            $dpFqdn = ($dp.NetworkOSPath -replace '^\\\\', '')
            $dpShort = ($dpFqdn -split '\.')[0]
            $dpVm = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $dpShort } | Select-Object -First 1
            if (-not $dpVm) { continue }
            if ($osdSubnets -contains (& $osdNetOf $dpVm)) { $osdDps += [PSCustomObject]@{ Fqdn = $dpFqdn; Short = $dpShort } }
        }
        $osdDps = @($osdDps | Sort-Object Short -Unique)
        if ($osdDps.Count -eq 0) {
            Write-DscStatus "$Tag WARNING: OSDClient exists but NO DP is on its subnet(s) $($osdSubnets -join ', ') -- OSD content NOT distributed and PXE cannot work. Add a DP (SiteSystem) on the OSDClient's subnet."
        }
        else {
            if ("$OsdDpGroupName" -notin @((Get-CMDistributionPointGroup -ErrorAction SilentlyContinue).Name)) {
                $null = New-CMDistributionPointGroup -Name $OsdDpGroupName -Description "DPs on an OSDClient subnet (OSD content + PXE)" -ErrorAction SilentlyContinue
                Write-DscStatus "$Tag Created DP group '$OsdDpGroupName'"
            }
            $osdMemberKeys = @{}
            $osdMembershipRead = $false
            try {
                $osdGrpWmi = Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DistributionPointGroup -Filter "Name='$OsdDpGroupName'" -ErrorAction Stop
                if ($osdGrpWmi) {
                    foreach ($memberRow in @(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DPGroupMembers -Filter "GroupID='$($osdGrpWmi.GroupID)'" -ErrorAction Stop)) {
                        $memberHostName = & $serverFromNal $memberRow.DPNALPath
                        if (-not $memberHostName) { continue }
                        $osdMemberKeys[$memberHostName.ToUpper()] = $true
                        $osdMemberKeys[(($memberHostName -split '\.')[0]).ToUpper()] = $true
                    }
                    $osdMembershipRead = $true
                }
            }
            catch {
                Write-DscStatus "$Tag Could not read existing '$OsdDpGroupName' membership; falling back to idempotent adds: $($_.Exception.Message)"
            }
            foreach ($d in $osdDps) {
                # Add the DP to the group by its FQDN, NOT its short name. Add-CMDistributionPointToGroup
                # resolves -DistributionPointName against the DP's ServerName (FQDN); passing the short
                # name ('PL-PANCETTA') fails to match, the error is swallowed, and the group is left EMPTY
                # -- so every Start-CMContentDistribution to 'OSD DPS' becomes a no-op and OSD content never
                # lands (the Phase 11 'not on any DP' WARN). This mirrors the working 'ALL DPS' block above.
                if ($osdMembershipRead -and ($osdMemberKeys.ContainsKey($d.Fqdn.ToUpper()) -or $osdMemberKeys.ContainsKey($d.Short.ToUpper()))) {
                    Write-DscStatus "$Tag OSD DP '$($d.Fqdn)' is already in '$OsdDpGroupName' -- skipping add"
                }
                else {
                    try { Add-CMDistributionPointToGroup -DistributionPointGroupName $OsdDpGroupName -DistributionPointName $d.Fqdn -ErrorAction Stop; Write-DscStatus "$Tag Added OSD DP '$($d.Fqdn)' to '$OsdDpGroupName'" }
                    catch { Write-DscStatus "$Tag OSD DP '$($d.Fqdn)' not added to '$OsdDpGroupName' (likely already a member): $($_.Exception.Message)" }
                }
                # Enable PXE. Prefer the NonWDS PXE responder (no separate WDS role);
                # fall back to plain EnablePxe if this build lacks -EnableNonWdsPxe.
                try {
                    Set-CMDistributionPoint -SiteSystemServerName $d.Fqdn -EnablePxe $true -AllowPxeResponse $true -EnableNonWdsPxe $true -ErrorAction Stop
                    Write-DscStatus "$Tag Enabled PXE (NonWDS) on OSD DP '$($d.Short)'"
                }
                catch {
                    try {
                        Set-CMDistributionPoint -SiteSystemServerName $d.Fqdn -EnablePxe $true -AllowPxeResponse $true -ErrorAction Stop
                        Write-DscStatus "$Tag Enabled PXE on OSD DP '$($d.Short)'"
                    }
                    catch { Write-DscStatus "$Tag WARNING: Failed to enable PXE on OSD DP '$($d.Short)': $($_.Exception.Message)" }
                }
            }
            # VERIFY each OSD DP is actually a member (a silently-failed add leaves
            # the group EMPTY and makes distribution to it a no-op -- exactly the bug
            # that hid the boot image from the OSDClient-subnet DP). Check per-DP so a
            # partial failure is caught, not just a fully-empty group.
            try {
                $osdGrpWmi = Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DistributionPointGroup -Filter "Name='$OsdDpGroupName'" -ErrorAction SilentlyContinue
                $osdMemberKeys = @{}
                if ($osdGrpWmi) {
                    foreach ($memberRow in @(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DPGroupMembers -Filter "GroupID='$($osdGrpWmi.GroupID)'" -ErrorAction SilentlyContinue)) {
                        $memberHostName = & $serverFromNal $memberRow.DPNALPath
                        if (-not $memberHostName) { continue }
                        $osdMemberKeys[$memberHostName.ToUpper()] = $true
                        $osdMemberKeys[(($memberHostName -split '\.')[0]).ToUpper()] = $true
                    }
                }
                foreach ($d in $osdDps) {
                    if (-not ($osdMemberKeys.ContainsKey($d.Fqdn.ToUpper()) -or $osdMemberKeys.ContainsKey($d.Short.ToUpper()))) {
                        Write-DscStatus "$Tag WARNING: OSD DP '$($d.Fqdn)' is NOT a member of '$OsdDpGroupName' after add -- OSD content distribution to the group will miss it"
                    }
                    else {
                        Write-DscStatus "$Tag Verified OSD DP '$($d.Fqdn)' is a member of '$OsdDpGroupName'"
                    }
                }
            }
            catch { Write-DscStatus "$Tag Could not verify '$OsdDpGroupName' membership: $($_.Exception.Message)" }
            $osdDistTarget = $OsdDpGroupName
            $hasOsdTargets = $true
        }
    }

    # Get all boot images. On a child Primary in a hierarchy, boot images
    # are replicated from the CAS and may not be available immediately.
    $BootImages = @(Get-CMBootImage)
    if ($BootImages.Count -eq 0 -and $ThisVM.parentSiteCode) {
        Write-DscStatus "$Tag No boot images found yet (child Primary — waiting for CAS replication)"
        for ($biWait = 1; $biWait -le 12; $biWait++) {
            Start-Sleep -Seconds 30
            $BootImages = @(Get-CMBootImage)
            if ($BootImages.Count -gt 0) {
                Write-DscStatus "$Tag Boot images appeared after ${biWait} wait(s)"
                break
            }
        }
    }
    if ($BootImages.Count -eq 0) {
        Write-DscStatus "$Tag WARNING: No boot images found — skipping boot image configuration"
    }
    else {
        Write-DscStatus "$Tag Found $($BootImages.Count) boot image(s): $(($BootImages | ForEach-Object { $_.Name }) -join ', ')"
    }

    # Loop through each boot image: enable command support, then distribute
    foreach ($BootImage in $BootImages) {
        $biName = $BootImage.Name
        $packageId = $BootImage.PackageID

        # Enable Command Support (F8 debug shell in WinPE)
        if ([bool]$BootImage.EnableLabShell) {
            Write-DscStatus "$Tag Command support already enabled for boot image: $biName ($packageId) -- skipping provider write"
        }
        else {
            try {
                Set-CMBootImage -Id $packageId -EnableCommandSupport $true
                Write-DscStatus "$Tag Enabled command support for boot image: $biName ($packageId)"
            }
            catch {
                Write-DscStatus "$Tag WARNING: Failed to enable command support for boot image: $biName ($packageId). Error: $_"
            }
        }

        # memlabs OSDClients are all x64 Gen2 VMs -- there is no arm64 PXE target,
        # so don't waste DP space distributing the arm64 boot image (command support
        # was still enabled above so it's usable if an arm64 client is ever added).
        if ($biName -match 'arm64') {
            Write-DscStatus "$Tag Skipping distribution of arm64 boot image '$biName' ($packageId) -- memlabs OSDClients are x64 (no arm64 PXE target)"
            continue
        }

        # Distribute the boot image to the OSD DP group (the DP(s) that share an
        # OSDClient's subnet). Only SKIP when the content is already on EVERY OSD
        # DP -- verified per-DP, not "any row exists". The old pre-check treated
        # ANY SMS_DistributionPoint row for this PackageID as "done", but these
        # boot images are often CAS-owned (e.g. BUN000xx under a child Primary),
        # so that table can carry a hierarchy-replicated / stale assignment for a
        # DIFFERENT (CAS or removed) DP. That false positive made perfloading skip
        # the real distribution, leaving the OSD DP PXE-enabled but with NO boot-
        # image content -- exactly what Phase 11 later flags as "not distributed
        # to any DP". Match the actual OSD DP server(s) so we distribute whenever
        # the content is missing on one of them.
        if (-not $hasOsdTargets) {
            Write-DscStatus "$Tag No OSDClient on a DP subnet -- NOT distributing boot image '$biName' ($packageId) (saves space); it will distribute + PXE-enable when an OSDClient is added on a DP subnet"
        }
        else {
            $osdDpFqdns = @($osdDps | ForEach-Object { "$($_.Fqdn)" } | Where-Object { $_ })
            $distributedFqdns = @()
            try {
                $dpTargets = @(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DistributionPoint -Filter "PackageID='$packageId'" -ErrorAction SilentlyContinue)
                foreach ($t in $dpTargets) {
                    # ServerNALPath looks like: ...["Display=\\PL-PANCETTA.domain\"]...\\PL-PANCETTA.domain\
                    if ("$($t.ServerNALPath)" -match '\\\\([^\\"]+)') { $distributedFqdns += $matches[1] }
                }
            }
            catch { }
            $missingOsdDps = @($osdDpFqdns | Where-Object { $fq = $_; -not ($distributedFqdns | Where-Object { $_ -eq $fq }) })

            if ($osdDpFqdns.Count -gt 0 -and $missingOsdDps.Count -eq 0) {
                Write-DscStatus "$Tag Boot image already on all OSD DP(s) ($($osdDpFqdns -join ', ')): $biName ($packageId) -- skipping"
            }
            else {
                try {
                    Start-CMContentDistribution -BootImageId $packageId -DistributionPointGroupName $osdDistTarget
                    Write-DscStatus "$Tag Successfully started distribution for boot image '$biName' ($packageId) to '$osdDistTarget'$(if ($missingOsdDps.Count) { " (missing on: $($missingOsdDps -join ', '))" })"
                }
                catch {
                    $biDistMsg = "$_"
                    if ($biDistMsg -match 'already been distributed' -or $biDistMsg -match 'No content destination was found') {
                        Write-DscStatus "$Tag Boot image already distributed: $biName ($packageId) -- skipping"
                    }
                    else {
                        Write-DscStatus "$Tag WARNING: Failed to start distribution for boot image: $biName ($packageId). Error: $_"
                    }
                }
            }
        }
    }


    #Tim is copying the iso directly at phase 1
    Write-DscStatus "$Tag ISO files are already copied from phase 1"

    $DriveLetter = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" | Select-Object -ExpandProperty "Installation Directory" | Split-Path -Qualifier

    Write-DscStatus "$Tag SCCM is installed on the drive -  $DriveLetter"

    # Define the folder path and share name
    $folderPath = "$DriveLetter\OSD"
    $shareName = "OSD"

    Write-DscStatus "$Tag sharing the OSD folder as - $folderPath"

    # Create the folder if it doesn't exist
    if (-not (Test-Path -Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath
        Write-DscStatus "$Tag OSD folder does not exist and creating one"
    }

    # Create the share with read access for "Everyone"
    if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $shareName -Path $folderPath -FullAccess @("Administrators", "Everyone")
    }

    Write-DscStatus "$Tag $shareName share successfully shared with Administrators"

    # OSD ISOs are copied to the top-level site server only (Phase 1).
    # On a child Primary under a CAS the OSD folder exists but is empty,
    # so skip OS-package/task-sequence creation when the media isn't there.
    $win11OsdPath = Join-Path $folderPath "Windows 11 24h2"
    $win10OsdPath = Join-Path $folderPath "Windows 10 22h2"
    $hasOsdMedia = (Test-Path "$win11OsdPath\sources\install.wim") -and (Test-Path "$win10OsdPath\sources\install.wim")

    if (-not $hasOsdMedia) {
        Write-DscStatus "$Tag OSD media not found in $folderPath — skipping OS packages and task sequences (ISOs only copied to top-level site)"
    }
    else {

    #get OS upgrade package (guard existence so a re-run doesn't throw
    # "An object with the specified name already exists" -- mirrors the OS
    # image block below. Get-CMOperatingSystemUpgradePackage is the read-side
    # cmdlet for the upgrade packages New-CMOperatingSystemInstaller creates.)
    try {
        $upgradePackageSpecs = @(
            @{ Name = "Windows 11 upgrade"; Path = "\\$ThisMachineName\OSD\Windows 11 24h2"; Version = "10.0.26100" },
            @{ Name = "Windows 10 upgrade"; Path = "\\$ThisMachineName\OSD\Windows 10 22h2"; Version = "10.0.19041" }
        )
        foreach ($upgradePackageSpec in $upgradePackageSpecs) {
            if (Get-CMOperatingSystemUpgradePackage -Name $upgradePackageSpec.Name) {
                Write-DscStatus "$Tag OS upgrade package '$($upgradePackageSpec.Name)' already exists -- skipping creation"
            }
            else {
                New-CMOperatingSystemInstaller -Name $upgradePackageSpec.Name -Path $upgradePackageSpec.Path -Version $upgradePackageSpec.Version
                Write-DscStatus "$Tag Created OS upgrade package '$($upgradePackageSpec.Name)'"
            }
        }
    }
    catch {
        Write-DscStatus "$Tag WARNING: Failed to create OS upgrade packages: $_"
    }

    #get OS package
    try {
        $osImageSpecs = @(
            @{ Name = "Windows 11"; Path = "\\$ThisMachineName\OSD\Windows 11 24h2\sources\install.wim"; Version = "10.0.26100" },
            @{ Name = "Windows 10"; Path = "\\$ThisMachineName\OSD\Windows 10 22h2\sources\install.wim"; Version = "10.0.19041" }
        )
        foreach ($osImageSpec in $osImageSpecs) {
            if (Get-CMOperatingSystemImage -Name $osImageSpec.Name) {
                Write-DscStatus "$Tag OS image '$($osImageSpec.Name)' already exists -- skipping creation"
            }
            else {
                New-CMOperatingSystemImage -Name $osImageSpec.Name -Path $osImageSpec.Path -Version $osImageSpec.Version
                Write-DscStatus "$Tag Created OS image '$($osImageSpec.Name)'"
            }
        }
    }
    catch {
        Write-DscStatus "$Tag WARNING: Failed to create OS image packages: $_"
    }

    # Get all Task Sequences with names starting with the specified prefix.
    # New-CMTaskSequence can hit a transient SQL deadlock (a SMS_PackageContentServerInfo
    # query, error "waiting for query to return" / SQLStatus 1205) mid-block. Because
    # every create shares one try/catch, a single deadlock abandons the WHOLE block and
    # leaves zero MEMLABS task sequences -- Phase 11 then warns "No MEMLABS-* task
    # sequences found". Retry the block on a transient deadlock, removing any partially
    # created MEMLABS TSes first so the retry stays idempotent.
    $tsAttempt = 0
    $tsMaxAttempts = 3
    while ($true) {
    $tsAttempt++
    $taskSequences = Get-CMTaskSequence | Where-Object { $_.Name -like "MEMLABS-*" }

    if (!$taskSequences) {
    try {

        # Define variables for TS
        #$TaskSequenceName = "Windows 11 In-Place Upgrade Task Sequence"
        $win11UpgradePackageID = Get-CMOperatingSystemUpgradePackage -Name "Windows 11 upgrade" | Select-Object -ExpandProperty PackageID
        $win10UpgradePackageID = Get-CMOperatingSystemUpgradePackage -Name "Windows 10 upgrade" | Select-Object -ExpandProperty PackageID
        $BootImagePackageID = Get-CMBootImage | Where-Object { $_.Name -eq "Boot image (x64)" }  | Select-Object -ExpandProperty PackageID
        $win11OSimagepackageID = Get-CMOperatingSystemImage -Name "windows 11" | Select-Object -ExpandProperty PackageID
        $win10OSimagepackageID = Get-CMOperatingSystemImage -Name "windows 10" | Select-Object -ExpandProperty PackageID
        $ClientPackagePackageId = Get-CMPackage -Fast -Name "Configuration Manager Client Package" | Select-Object -ExpandProperty PackageID
        $UserStateMigrationToolPackageId = Get-CMPackage -Fast -Name "User State Migration Tool for Windows" | Select-Object -ExpandProperty PackageID
        $win11UpgradeOperatingSystemWim = "\\$ThisMachineName\osd\Windows 11 24h2\sources\install.wim"
        $win10UpgradeOperatingSystemWim = "\\$ThisMachineName\osd\Windows 10 22h2\sources\install.wim"
        $clientProps = 'CCMDEBUGLOGGING="1" CCMLOGGINGENABLED="TRUE" CCMLOGLEVEL="0" CCMLOGMAXHISTORY="5" CCMLOGMAXSIZE="10000000" SMSCACHESIZE="15000"'
        $cm_svc_file = "C:\Staging\DSC\cm_svc.txt"

        $tstimezone = [System.TimeZoneInfo]::FindSystemTimeZoneById($deployconfig.vmOptions.timeZone)
        if (Test-Path $cm_svc_file) {
            # Add cm_svc user as a CM Account
            $unencrypted = Get-Content $cm_svc_file
        }
        #distribute the OS packages and upgrade packages -- ONLY to OSD-capable DP(s)
        # (same subnet as an OSDClient). No OSDClient -> skip so the multi-GB content
        # doesn't fill every DP; a re-run distributes once an OSDClient is added.
        if ($hasOsdTargets) {
            Start-CMContentDistribution -PackageId $UserStateMigrationToolPackageId -DistributionPointGroupName $osdDistTarget -ErrorAction SilentlyContinue
            Start-CMContentDistribution -OperatingSystemImageIds @($win11OSimagepackageID, $win10OSimagepackageID) -DistributionPointGroupName $osdDistTarget -ErrorAction SilentlyContinue
            Start-CMContentDistribution -OperatingSystemInstallerIds @($win11UpgradePackageID, $win10UpgradePackageID) -DistributionPointGroupName $osdDistTarget -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Distributed OS image + upgrade + USMT content to '$osdDistTarget' (OSDClient subnet DP)"
        }
        else {
            Write-DscStatus "$Tag No OSDClient on a DP subnet -- NOT distributing OS image/upgrade/USMT content (saves space); will distribute when an OSDClient is added"
        }
     

        # Create the in-place upgrade task sequence
        New-CMTaskSequence -UpgradeOperatingSystem -Name "MEMLABS-w11-In-Place Upgrade Task Sequence" -UpgradePackageId $win11UpgradePackageID -SoftwareUpdateStyle All
        Write-DscStatus "$Tag Successfully created windows 11 in-place upgrade TS"
        New-CMTaskSequence -UpgradeOperatingSystem -Name "MEMLABS-w10-In-Place Upgrade Task Sequence" -UpgradePackageId $win10UpgradePackageID -SoftwareUpdateStyle All
        Write-DscStatus "$Tag Successfully created windows 10 in-place upgrade TS"
        $AdminName = $deployConfig.vmOptions.adminName
        ## Build and capture TS

        $buildandcapturewin11 = @{
            BuildOperatingSystemImage          = $true
            Name                               = "MEMLABS-w11-Build and capture"
            Description                        = "MEMLABS auto created"
            BootImagePackageId                 = $BootImagePackageID
            HighPerformance                    = $true
            ApplyAll                           = $false
            OperatingSystemImagePackageId      = $win11OSimagepackageID
            OperatingSystemImageIndex          = 3
            ProductKey                         = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
            GeneratePassword                   = $false
            LocalAdminPassword                 = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
            TimeZone                           = $tstimezone
            JoinDomain                         = "WorkgroupType"
            WorkgroupName                      = "Workgroup"
            ClientPackagePackageId             = $ClientPackagePackageId
            InstallationProperty               = $clientProps
            ApplicationName                    = "Admin Console"
            IgnoreInvalidApplication           = $true
            SoftwareUpdateStyle                = "All"
            OperatingSystemFilePath            = $win11UpgradeOperatingSystemWim
            ImageDescription                   = "MEMLABS autocreated"
            ImageVersion                       = "image version 1"
            CreatedBy                          = "MEMLABS"
            OperatingSystemFileAccount         = "$DomainFullName\$AdminName" 
            OperatingSystemFileAccountPassword = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        }

        New-CMTaskSequence @buildandcapturewin11
        Write-DscStatus "$Tag Successfully created MEMLABS-w11-Build and capture TS"

        $buildandcapturewin10 = @{
            BuildOperatingSystemImage          = $true
            Name                               = "MEMLABS-w10-Build and capture"
            Description                        = "MEMLABS auto created"
            BootImagePackageId                 = $BootImagePackageID
            HighPerformance                    = $true
            ApplyAll                           = $false
            OperatingSystemImagePackageId      = $win10OSimagepackageID
            OperatingSystemImageIndex          = 3
            ProductKey                         = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
            GeneratePassword                   = $false
            LocalAdminPassword                 = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
            TimeZone                           = $tstimezone
            JoinDomain                         = "WorkgroupType"
            WorkgroupName                      = "workgroup"
            ClientPackagePackageId             = $ClientPackagePackageId
            InstallationProperty               = $clientProps
            ApplicationName                    = "Admin Console"
            IgnoreInvalidApplication           = $true
            SoftwareUpdateStyle                = "All"
            OperatingSystemFilePath            = $win10UpgradeOperatingSystemWim
            ImageDescription                   = "MEMLABS autocreated"
            ImageVersion                       = "image version 1"
            CreatedBy                          = "MEMLABS"
            OperatingSystemFileAccount         = "$DomainFullName\$AdminName" 
            OperatingSystemFileAccountPassword = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        }
        New-CMTaskSequence @buildandcapturewin10
        Write-DscStatus "$Tag Successfully created MEMLABS-w10-Build and capture TS"
        ##Create a task sequence to install an OS image

        $installw11OSimage = @{
            InstallOperatingSystemImage     = $true
            Name                            = "MEMLABS-w11-Install OS image"
            Description                     = "MEMLABS auto created"
            BootImagePackageId              = $BootImagePackageID
            HighPerformance                 = $true
            CaptureNetworkSetting           = $true
            CaptureUserSetting              = $true
            SaveLocally                     = $true
            CaptureLocallyUsingLink         = $true
            UserStateMigrationToolPackageId = $UserStateMigrationToolPackageId
            CaptureWindowsSetting           = $true
            ConfigureBitLocker              = $true
            PartitionAndFormatTarget        = $true
            ApplyAll                        = $false
            OperatingSystemImagePackageId   = $win11OSimagepackageID
            OperatingSystemImageIndex       = 3
            ProductKey                      = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
            GeneratePassword                = $false
            LocalAdminPassword              = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
            TimeZone                        = $tstimezone
            JoinDomain                      = "DomainType"
            DomainAccount                   = "$DomainFullName\$AdminName"
            DomainName                      = "$DomainFullName"
            DomainOrganizationUnit          = "LDAP://OU=MEMLABS-OSDComputers,$DN"
            DomainPassword                  = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
            ClientPackagePackageId          = $ClientPackagePackageId
            InstallationProperty            = $clientProps
            SoftwareUpdateStyle             = "All"
        }

        New-CMTaskSequence @installw11OSimage
        Write-DscStatus "$Tag Successfully created MEMLABS-w11-Install OS image TS"

        $installw10OSimage = @{
            InstallOperatingSystemImage     = $true
            Name                            = "MEMLABS-w10-Install OS image"
            Description                     = "MEMLABS auto created"
            BootImagePackageId              = $BootImagePackageID
            HighPerformance                 = $true
            CaptureNetworkSetting           = $true
            CaptureUserSetting              = $true
            SaveLocally                     = $true
            CaptureLocallyUsingLink         = $true
            UserStateMigrationToolPackageId = $UserStateMigrationToolPackageId
            CaptureWindowsSetting           = $true
            ConfigureBitLocker              = $true
            PartitionAndFormatTarget        = $true
            ApplyAll                        = $false
            OperatingSystemImagePackageId   = $win10OSimagepackageID
            OperatingSystemImageIndex       = 3
            ProductKey                      = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
            GeneratePassword                = $false
            LocalAdminPassword              = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
            TimeZone                        = $tstimezone
            JoinDomain                      = "DomainType"
            DomainAccount                   = "$DomainFullName\$AdminName"
            DomainName                      = "$DomainFullName"
            DomainOrganizationUnit          = "LDAP://OU=MEMLABS-OSDComputers,$DN"
            DomainPassword                  = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
            ClientPackagePackageId          = $ClientPackagePackageId
            InstallationProperty            = $clientProps
            SoftwareUpdateStyle             = "All"
        }

        New-CMTaskSequence @installw10OSimage
        Write-DscStatus "$Tag Successfully created MEMLABS-w10-Install OS image TS"

        $customTS = @{
            CustomTaskSequence = $true
            Name               = "MEMLABS-Custom TS Example"
            Description        = "MEMLABS auto created"
            HighPerformance    = $false
            BootImagePackageId = $BootImagePackageID
        }

        New-CMTaskSequence @customTS
        Write-DscStatus "$Tag Successfully created MEMLABS-Custom TS Example"

        # Get all task sequences with names starting with "MEMLABS"
        $taskSequences = Get-CMTaskSequence -Fast | Where-Object { $_.Name -like "MEMLABS*" }

        # Get the "All Unknown Computers" collection
        $unknownCollection = Get-CMDeviceCollection -Name "All Unknown Computers"

        foreach ($ts in $taskSequences) {
            # Check if a deployment already exists for this task sequence to this collection
            $existingDeployment = Get-CMDeployment -CollectionName $unknownCollection.Name | Where-Object { $_.PackageID -eq $ts.PackageID }

            if ($existingDeployment) {
                Write-DscStatus "Skipping $($ts.Name) already deployed to $($unknownCollection.Name)"
            }
            else {
                try {
                    Write-DscStatus "Deploying Task Sequence: $($ts.Name)"

                    New-CMTaskSequenceDeployment `
                        -TaskSequencePackageId $ts.PackageID `
                        -CollectionId $unknownCollection.CollectionID `
                        -DeployPurpose Available `
                        -MakeAvailableTo ClientsMediaAndPxe
                }
                catch {
                    Write-DscStatus "$Tag WARNING: Failed to deploy TS '$($ts.Name)': $_"
                }
            }

        }


    }
    catch {
        $tsErr = "$_"
        $tsTransient = ($tsErr -match 'deadlock') -or ($tsErr -match 'Error waiting for query to return') -or ($tsErr -match '\b1205\b')
        if ($tsTransient -and $tsAttempt -lt $tsMaxAttempts) {
            Write-DscStatus "$Tag WARNING: Transient deadlock creating task sequences (attempt $tsAttempt of $tsMaxAttempts); cleaning up partial TSes and retrying in 30s: $_"
            try { Get-CMTaskSequence -Fast | Where-Object { $_.Name -like 'MEMLABS-*' } | ForEach-Object { Remove-CMTaskSequence -TaskSequencePackageId $_.PackageID -Force -ErrorAction SilentlyContinue } } catch {}
            Start-Sleep -Seconds 30
            continue
        }
        Write-DscStatus "$Tag WARNING: Failed to create task sequences: $_"
        break
    }
    break
    }
    else {

        Write-DscStatus "$Tag Task sequences were already created, skipping the duplicate creation"
        break

    }
    }

    } # end hasOsdMedia

    } # end Primary-only TS/OSD block

    ### CI and baselines 

    #expand archive for importing cab files
    $baselineReconcileTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $baselinesZip = "C:\tools\baselines.zip"
    $baselineFolder = "C:\tools\baselines"
    $baselineArchiveStamp = Join-Path $baselineFolder ".source.sha256"

    # CIs/baselines are client-facing configuration that MEMLABS stages and
    # imports on the Primary ONLY -- baselines.zip is copied solely to the
    # Primary site server (Common.ScriptBlocks.ps1: role -eq 'Primary'). In a
    # hierarchy the CAS holds no client resources, so this block was never meant
    # to run there; because the zip is never present on a CAS it only produced a
    # spurious "baselines.zip not found ... skipping CI/baseline import" WARNING
    # on every run. Skip on CAS, matching the collections/Office CAS gates.
    if ($CurrentRole -eq "CAS") {
        Write-DscStatus "$Tag Skipping CI/baseline import on CAS (client-facing config is imported on the Primary)"
    }
    elseif (Test-Path $baselinesZip) {
        $baselineZipHash = $null
        try { $baselineZipHash = (Get-FileHash -LiteralPath $baselinesZip -Algorithm SHA256 -ErrorAction Stop).Hash }
        catch { Write-DscStatus "$Tag WARNING: Could not hash baselines.zip; it will be expanded again: $($_.Exception.Message)" }
        $expandedBaselineHash = if (Test-Path -LiteralPath $baselineArchiveStamp) { (Get-Content -LiteralPath $baselineArchiveStamp -Raw).Trim() } else { $null }
        $haveBaselineCabs = (Test-Path -LiteralPath $baselineFolder) -and @(Get-ChildItem -LiteralPath $baselineFolder -Filter "*.cab" -File -ErrorAction SilentlyContinue).Count -gt 0
        if ($baselineZipHash -and $haveBaselineCabs -and $expandedBaselineHash -eq $baselineZipHash) {
            Write-DscStatus "$Tag baselines.zip is already expanded at the current hash -- skipping archive write"
        }
        else {
            Expand-Archive -Path $baselinesZip -DestinationPath "C:\tools\" -Force
            if ($baselineZipHash) { $baselineZipHash | Set-Content -LiteralPath $baselineArchiveStamp -Encoding ASCII -Force }
            Write-DscStatus "$Tag Expanded baselines.zip (source changed or extraction was incomplete)"
        }
    }
    else {
        Write-DscStatus "$Tag WARNING: baselines.zip not found at $baselinesZip — skipping CI/baseline import"
    }

    $baselinesImported = 0
    $baselinesSkipped = 0
    $baselinesFailed = 0

    # Get all .cab files in the folder (never on CAS -- see the gate above)
    if ($CurrentRole -ne "CAS" -and (Test-Path $baselineFolder)) {
    $ConfigNames = @(Get-ChildItem -Path $baselineFolder -Filter "*.cab")
    $existingBaselineNames = @{}
    $baselineInventoryLoaded = $false
    try {
        foreach ($existingBaseline in @(Get-CMBaseline -Fast -ErrorAction Stop)) {
            if ($existingBaseline.LocalizedDisplayName) { $existingBaselineNames["$($existingBaseline.LocalizedDisplayName)"] = $true }
        }
        $baselineInventoryLoaded = $true
    }
    catch {
        Write-DscStatus "$Tag WARNING: Could not load baselines in one query; falling back to per-baseline checks: $($_.Exception.Message)"
    }

    ForEach ($ConfigName in $ConfigNames) {

        $baselinename = [System.IO.Path]::GetFileNameWithoutExtension($ConfigName.Name)

        # Whole-iteration try/catch: the Get-CMBaseline guard below issues a WMI
        # ExecQuery against the SMS provider, which can throw a transient
        # ManagementException (e.g. WBEM_E_NOT_FOUND / 0x80041002 when the
        # provider is momentarily busy right after site setup). That call used to
        # sit OUTSIDE the try, so a single hiccup terminated the dot-sourced
        # Perfloading.ps1 mid-run -- skipping everything after it, including the
        # Office app/deployment creation and the end-of-run recovery sweep, which
        # left the Office Install Targets collection with no deployment. Catch it
        # per-baseline and continue so one flaky baseline can't sink the rest of
        # perfloading.
        try {
            $baselineExists = if ($baselineInventoryLoaded) {
                $existingBaselineNames.ContainsKey($baselinename)
            }
            else {
                $null -ne (Get-CMBaseline -Fast -Name $baselinename -ErrorAction Stop)
            }
            if (-not $baselineExists) {
                # Create a configuration item (we are importing the cab files directly here)
                $filename = $baselineFolder + "\" + $ConfigName.Name
                Write-DscStatus "$Tag Importing cab from $filename location"
                Import-CMConfigurationItem -FileName $filename -Force
                Write-DscStatus "$Tag Successfully created Configuration Item for $baselinename"
    
                # Create the configuration baseline
                New-CMBaseline -Name $baselinename -Description "MEMLABS auto imported" 
                Write-DscStatus "$Tag Successfully created Configuration Baseline for $baselinename"

                # Link the configuration item to the configuration baseline (we are using the same name for CI and baseline so using the same name here)
                $ciinfo = Get-CMConfigurationItem -Name $baselinename -Fast
                Set-CMBaseline -Name $baselinename -AddOSConfigurationItem $ciinfo.CI_ID 
                Write-DscStatus "$Tag Successfully linked CI and CB for $baselinename"

                # Deploy the configuration baseline to a collection
                Write-DscStatus "$Tag Deploying baseline $baselinename to All Systems..."
                New-CMBaselineDeployment -Name $baselinename -CollectionName "All Systems" -EnableEnforcement $true
                Write-DscStatus "$Tag Successfully deployed the baseline $baselinename to All systems"
                $existingBaselineNames[$baselinename] = $true
                $baselinesImported++
            }
            else {
                $baselinesSkipped++
            }
        }
        catch {
            $baselinesFailed++
            Write-DscStatus "$Tag WARNING: Failed to import/deploy baseline '$baselinename': $($_.Exception.Message)"
        }
    }
    } # end if baselineFolder exists
    $baselineReconcileTimer.Stop()
    if ($CurrentRole -ne "CAS") {
        Write-DscStatus "$Tag Baseline reconcile: $baselinesImported imported, $baselinesSkipped already present, $baselinesFailed failed in $([math]::Round($baselineReconcileTimer.Elapsed.TotalSeconds, 1))s"
    }

    ### Repro-only policy bulk + purpose-built tattoo CIs
    # Reproduces case 2608010010000636. Two independent knobs, both opt-in via
    # cmOptions; absent or 0 (every normal lab) skips the whole region.
    #
    #   ReproPolicyBulkCount  - contentless packages, purely to PAD the policy set
    #   ReproTattooCICount    - OS script CIs + registry CIs that can actually be
    #                           orphaned and reverted (the mechanism itself)
    #
    # Why this shape, from the real client logs: of 1333 UnintendInstance calls,
    # 1309 were OperatingSystem CIs and 24 were CCM_RegistryValue_Setting_Integer.
    # NOTHING else ever got reverted -- not Applications, not DeploymentTypes, not
    # Baselines. So the tattoo vehicle must be an OS CI (New-CMConfigurationItem
    # -CreationType WindowsOS maps to ConfigurationItemType.OperatingSystem) plus
    # a registry value setting. The rest of the policy set only matters as volume,
    # which is what the packages are for: the orphan window is the time between
    # policy being purged and the projection refilling, so a bigger set = a wider
    # window = a landable repro.
    #
    # The stock baselines.zip CIs are not used as the PRIMARY vehicle, but they are
    # a valid secondary signal. Since the 2026-06 repair (manifest md5 7EB476C8...)
    # all 7 emit their value to stdout and discover correctly; however only 2 of
    # them ("Check windows firewall", "Check Windows update") carry a remediation
    # script, and both remediate by starting a real service -- which leaves no
    # attributable trace and has side effects on the lab. The CIs below instead
    # give a controllable count, a remediation on EVERY CI, and a timestamped
    # audit log, so "the remediation ran because the setting was un-intended" is
    # directly observable rather than inferred.
    $bulkCount = 0
    $tattooCount = 0
    if ($cmo.ReproPolicyBulkCount) { $bulkCount = [int]$cmo.ReproPolicyBulkCount }
    if ($cmo.ReproTattooCICount) { $tattooCount = [int]$cmo.ReproTattooCICount }

    if ($CurrentRole -eq "CAS" -and ($bulkCount -gt 0 -or $tattooCount -gt 0)) {
        Write-DscStatus "$Tag Skipping repro objects on CAS (client policy is projected from the Primary)"
    }
    else {
        # --- 1. Volume: contentless packages -----------------------------------
        # No source path on purpose: no content, no DP distribution, no disk cost,
        # but each deployment still projects real machine policy.
        if ($bulkCount -gt 0) {
            Write-DscStatus "$Tag Repro policy bulk: creating $bulkCount contentless package deployment(s) to pad the machine policy set"
            $bulkMade = 0
            $bulkSkipped = 0
            $bulkFailed = 0

            for ($i = 1; $i -le $bulkCount; $i++) {
                $bulkName = "MEMLABS-PolicyBulk-{0:D4}" -f $i
                try {
                    if (Get-CMPackage -Name $bulkName -Fast -ErrorAction SilentlyContinue) {
                        $bulkSkipped++
                        continue
                    }

                    $bulkPkg = New-CMPackage -Name $bulkName -Description "MEMLABS repro: policy padding only, no content" -ErrorAction Stop
                    New-CMProgram -PackageId $bulkPkg.PackageID -StandardProgramName "NoOp" -CommandLine "cmd.exe /c exit 0" -ErrorAction Stop | Out-Null
                    New-CMPackageDeployment -StandardProgram -PackageId $bulkPkg.PackageID -ProgramName "NoOp" -CollectionName "All Systems" -DeployPurpose Available -ErrorAction Stop | Out-Null
                    $bulkMade++

                    if (($bulkMade % 25) -eq 0) {
                        Write-DscStatus "$Tag Repro policy bulk: $bulkMade created so far (of $bulkCount)"
                    }
                }
                catch {
                    $bulkFailed++
                    # Only surface the first few; a systemic failure repeats N times.
                    if ($bulkFailed -le 3) {
                        Write-DscStatus "$Tag WARNING: Repro policy bulk failed on '$bulkName': $($_.Exception.Message)"
                    }
                }
            }
            Write-DscStatus "$Tag Repro policy bulk complete: $bulkMade created, $bulkSkipped already present, $bulkFailed failed"
        }

        # --- 2. Mechanism: OS script CIs + registry CIs -------------------------
        if ($tattooCount -gt 0) {
            Write-DscStatus "$Tag Repro tattoo CIs: creating $tattooCount script CI(s) + $tattooCount registry CI(s)"

            $reproDir = 'C:\ProgramData\MEMLABS-PolicyChurn'
            $reproKey = 'SOFTWARE\MEMLABS\PolicyChurn'
            $reproBaseline = 'MEMLABS-PolicyChurn-Repro'
            $ciMade = 0
            $ciSkipped = 0
            $ciFailed = 0
            $ciIds = @()

            for ($i = 1; $i -le $tattooCount; $i++) {
                $n = "{0:D3}" -f $i
                $scriptCiName = "MEMLABS-Repro-Script-$n"
                $regCiName = "MEMLABS-Repro-Registry-$n"

                # Discovery MUST emit the value on STDOUT -- ConfigMgr uses stdout as
                # the discovered value and IGNORES the exit code. Returning only an
                # exit code yields DiscoveryFailure and the CI never establishes
                # intent, so it can never be orphaned either.
                $discoveryScript = @"
`$marker = '$reproDir\marker-$n.txt'
if (Test-Path `$marker) { Write-Output `$true } else { Write-Output `$false }
"@

                # Deliberately harmless: creates a marker and appends one audit line.
                # It must NOT reboot or stop ccmexec -- that is the customer's bug, and
                # doing it here would truncate the evaluation pass and hide the very
                # signal we are trying to observe. The audit log is the proof the
                # remediation ran because the setting was UN-INTENDED.
                $remediationScript = @"
`$dir = '$reproDir'
if (-not (Test-Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
Set-Content -Path "`$dir\marker-$n.txt" -Value 'present' -Force
Add-Content -Path "`$dir\remediation-audit.log" -Value ("{0}`tremediation ran`t$scriptCiName" -f (Get-Date -Format 'o'))
Write-Output `$true
"@

                try {
                    # -- script CI (OperatingSystem type: the one that tattoos) --
                    if (Get-CMConfigurationItem -Name $scriptCiName -Fast -ErrorAction SilentlyContinue) {
                        $ciSkipped++
                    }
                    else {
                        $sci = New-CMConfigurationItem -Name $scriptCiName -CreationType WindowsOS -Description "MEMLABS repro: orphan/tattoo observable" -ErrorAction Stop
                        $sci | Add-CMComplianceSettingScript -Name "MarkerPresent-$n" -DataType Boolean `
                            -DiscoveryScriptLanguage PowerShell -DiscoveryScriptText $discoveryScript `
                            -RemediationScriptLanguage PowerShell -RemediationScriptText $remediationScript -Remediate `
                            -ValueRule -ExpectedValue 'True' -ExpressionOperator IsEquals `
                            -RuleName "MarkerPresent-$n" -NoncomplianceSeverity Informational -ErrorAction Stop | Out-Null
                        $ciMade++
                    }
                    $sciObj = Get-CMConfigurationItem -Name $scriptCiName -Fast -ErrorAction SilentlyContinue
                    if ($sciObj) { $ciIds += $sciObj.CI_ID }

                    # -- registry value CI (CCM_RegistryValue_Setting_Integer) --
                    if (Get-CMConfigurationItem -Name $regCiName -Fast -ErrorAction SilentlyContinue) {
                        $ciSkipped++
                    }
                    else {
                        $rci = New-CMConfigurationItem -Name $regCiName -CreationType WindowsOS -Description "MEMLABS repro: registry tattoo observable" -ErrorAction Stop
                        $rci | Add-CMComplianceSettingRegistryKeyValue -Name "ReproValue-$n" -DataType Integer `
                            -Hive LocalMachine -KeyName $reproKey -ValueName "ReproValue$n" `
                            -ValueRule -ExpectedValue '1' -ExpressionOperator IsEquals -Remediate `
                            -RuleName "ReproValue-$n" -NoncomplianceSeverity Informational -ErrorAction Stop | Out-Null
                        $ciMade++
                    }
                    $rciObj = Get-CMConfigurationItem -Name $regCiName -Fast -ErrorAction SilentlyContinue
                    if ($rciObj) { $ciIds += $rciObj.CI_ID }
                }
                catch {
                    $ciFailed++
                    if ($ciFailed -le 3) {
                        Write-DscStatus "$Tag WARNING: Repro tattoo CI failed on '$scriptCiName': $($_.Exception.Message)"
                    }
                }
            }

            # One baseline carrying every repro CI. -AddOSConfigurationItem is the
            # correct linker here because these ARE OS CIs (CreationType WindowsOS).
            try {
                if (-not (Get-CMBaseline -Fast -Name $reproBaseline -ErrorAction SilentlyContinue)) {
                    New-CMBaseline -Name $reproBaseline -Description "MEMLABS repro: policy-churn orphan/tattoo observables" -ErrorAction Stop | Out-Null
                    Write-DscStatus "$Tag Created baseline $reproBaseline"
                }
                foreach ($id in $ciIds) {
                    try { Set-CMBaseline -Name $reproBaseline -AddOSConfigurationItem $id -ErrorAction Stop }
                    catch { }   # already linked on a rerun
                }
                if (-not (Get-CMBaselineDeployment -Name $reproBaseline -ErrorAction SilentlyContinue)) {
                    New-CMBaselineDeployment -Name $reproBaseline -CollectionName "All Systems" -EnableEnforcement $true -ErrorAction Stop | Out-Null
                    Write-DscStatus "$Tag Deployed baseline $reproBaseline to All Systems with enforcement"
                }
            }
            catch {
                Write-DscStatus "$Tag WARNING: Repro baseline setup failed: $($_.Exception.Message)"
            }

            Write-DscStatus "$Tag Repro tattoo CIs complete: $ciMade created, $ciSkipped already present, $ciFailed failed, $($ciIds.Count) linked to $reproBaseline"
            Write-DscStatus "$Tag Watch for remediation on clients: $reproDir\remediation-audit.log"
        }
    }

    #region Microsoft 365 Apps — join background download + create applications
    # The Office source download was started as a background job at the top of the
    # apps/packages section so it could run concurrently with the OSD/TS/baseline
    # work above. Join it now and create the ConfigMgr applications. Guarded to
    # Primary/standalone (non-CAS) — matching where the job was started.
    if ($CurrentRole -ne "CAS" -and $officeDownloadJob) {
        # The job's ODT `setup.exe /download` runs under Start-Process -Wait with
        # no cap of its own, so bound the join: a wedged CDN fetch (or a dead job
        # runspace) must not hang Phase 8 forever. On overrun we fall through with
        # no result and the Office applications are simply skipped this pass.
        $officeDownloadTimeout = 5400
        Write-DscStatus "$Tag Waiting for background Office source download job to complete..."
        $officeDownloadResult = $null
        if (Wait-Job -Job $officeDownloadJob -Timeout $officeDownloadTimeout) {
            $officeDownloadResult = Receive-Job -Job $officeDownloadJob
        }
        else {
            Write-DscStatus "$Tag WARNING: Office source download job did not finish within $officeDownloadTimeout s (state=$($officeDownloadJob.State)); skipping Office application creation this pass."
            Stop-Job -Job $officeDownloadJob -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $officeDownloadJob -Force -ErrorAction SilentlyContinue

        # Replay the job's log messages through Write-DscStatus (the job ran silently)
        if ($officeDownloadResult -and $officeDownloadResult.Messages) {
            foreach ($officeMsg in $officeDownloadResult.Messages) {
                Write-DscStatus "$Tag $officeMsg"
            }
        }

        if ($officeDownloadResult -and $officeDownloadResult.OdtOk) {

            # Create SMB share for Office source
            if (-not (Get-SmbShare -Name $officeShareName -ErrorAction SilentlyContinue)) {
                New-SmbShare -Name $officeShareName -Path $officeSourceRoot -FullAccess @("Administrators", "Everyone") -ErrorAction SilentlyContinue
                Write-DscStatus "$Tag Created SMB share \\$ThisMachineName\$officeShareName"
            }

            # Ensure the Install Targets collection exists with an up-to-date query
            # rule BEFORE creating any deployment. New-CMApplicationDeployment
            # against a non-existent collection silently no-ops with
            # -ErrorAction SilentlyContinue, which previously left fresh labs with
            # an Office app but no deployment (the collection was created later in
            # the script). Running this here also refreshes the rule on existing
            # labs whose collection was built with legacy direct-membership rules.
            Set-OfficeInstallTargetsCollection -OfficeTargetVMs $officeVMs | Out-Null

            # Create one CM Application per channel
            foreach ($channel in $channels) {
                $channelSourcePath = Join-Path $officeSourceRoot $channel

                # Only create the application if the source files actually downloaded
                if (-not (Test-Path (Join-Path $channelSourcePath "Office\Data"))) {
                    Write-DscStatus "$Tag WARNING: Office source files missing for channel '$channel' — skipping application creation"
                    continue
                }

                $channelAppName = if ($channels.Count -eq 1) { $officeAppName } else { "$officeAppName-$channel" }
                $contentUNC = "\\$ThisMachineName\$officeShareName\$channel"

                if (Get-CMApplication -Name $channelAppName -Fast -ErrorAction SilentlyContinue) {
                    Write-DscStatus "$Tag Application '$channelAppName' already exists, skipping"
                    continue
                }

                Write-DscStatus "$Tag Creating application '$channelAppName'"
                New-CMApplication -Name $channelAppName -Description "Microsoft 365 Apps ($channel channel)" -Publisher "Microsoft" -SoftwareVersion "Latest" -ErrorAction SilentlyContinue

                # Script deployment type: ODT install/uninstall with registry detection
                $installCmd = "setup.exe /configure install.xml"
                $uninstallCmd = "setup.exe /configure uninstall.xml"
                $detectScript = @'
$ctr = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
if ($ctr -and $ctr.VersionToReport) { Write-Host $ctr.VersionToReport }
'@
                Add-CMScriptDeploymentType -ApplicationName $channelAppName `
                    -DeploymentTypeName "ODT Install ($channel)" `
                    -ContentLocation $contentUNC `
                    -InstallCommand $installCmd `
                    -UninstallCommand $uninstallCmd `
                    -ScriptLanguage PowerShell `
                    -ScriptText $detectScript `
                    -LogonRequirementType WhetherOrNotUserLoggedOn `
                    -UserInteractionMode Hidden `
                    -InstallationBehaviorType InstallForSystem `
                    -MaximumRuntimeMins 120 `
                    -EstimatedRuntimeMins 30 `
                    -Force `
                    -ErrorAction SilentlyContinue

                Write-DscStatus "$Tag Distributing '$channelAppName' to all DPs"
                Start-CMContentDistribution -ApplicationName $channelAppName -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue

                # Deploy as Required to target VMs
                $officeCollectionName = "MEMLABS-Office Install Targets"
                Write-DscStatus "$Tag Deploying '$channelAppName' as Required to collection '$officeCollectionName'"
                New-CMApplicationDeployment -ApplicationName $channelAppName `
                    -CollectionName $officeCollectionName `
                    -DeployAction Install `
                    -DeployPurpose Required `
                    -UserNotification DisplayAll `
                    -ErrorAction SilentlyContinue

                Write-DscStatus "$Tag Office application '$channelAppName' deployment complete"
            }
        }
        else {
            Write-DscStatus "$Tag WARNING: Office source download did not complete; skipping Office application creation"
        }
    }
    #endregion Microsoft 365 Apps — join background download + create applications

    #we have to make powershell bypass for the baselines to work as expected
    # Custom client settings — top-level site only (replicate to child sites)
    if ($isTopLevel) {
    $customclientsetting = "MEMLABS-powershellbypass"
 
    if (!(Get-CMClientSetting -Name $customclientsetting)) {
        New-CMClientSetting -Name $customclientsetting -Description "Client settings for making powershell execution policy as bypass" -Type Device -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag $customclientsetting client setting created"

        # Enable the PowerShell Execution Policy setting
        Set-CMClientSettingComputerAgent -PowerShellExecutionPolicy Bypass -Name $customclientsetting
        Write-DscStatus "$Tag Powershell policy successfully changed for $customclientsetting client setting "

        New-CMClientSettingDeployment -Name $customclientsetting -CollectionId SMS00001
        Write-DscStatus "$Tag Deployed the client setting to all systems collection"
    }
    } # end top-level client settings

    function Get-WsusDiagnostics {
        # Collect WSUS-native health signals for troubleshooting a stuck sync.
        # Returns an array of human-readable diagnostic lines. Never throws.
        $lines = @()

        # 1. WSUS catalog state — the real "did a sync ever work" signal.
        #    GetStatus().UpdateCount stays 0 until the first full sync completes,
        #    even while CM reports the sync as "running".
        try {
            $wsusSrv = Get-WsusServer -ErrorAction Stop
            $wStatus = $wsusSrv.GetStatus()
            $lines += "WSUS UpdateCount=$($wStatus.UpdateCount), ApprovedUpdates=$($wStatus.ApprovedUpdateCount), Computers=$($wStatus.ComputerTargetCount)"
            try {
                $sub = $wsusSrv.GetSubscription()
                $lastInfo = $sub.GetLastSynchronizationInfo()
                $lines += "WSUS LastSync=$($sub.LastSynchronizationTime), Result=$($lastInfo.Result), Error=$($lastInfo.Error)"
            }
            catch { $lines += "WSUS subscription info unavailable: $($_.Exception.Message)" }
        }
        catch {
            $lines += "WSUS GetStatus failed (server may be unreachable): $($_.Exception.Message)"
        }

        # 2. WsusPool app pool state + configured memory cap + queue length.
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $poolPath = 'IIS:\AppPools\WsusPool'
            if (Test-Path $poolPath) {
                $poolState = (Get-WebAppPoolState -Name WsusPool -ErrorAction SilentlyContinue).Value
                $memCap = (Get-ItemProperty -Path $poolPath -Name recycling.periodicRestart.privateMemory -ErrorAction SilentlyContinue).Value
                $qLen = (Get-ItemProperty -Path $poolPath -Name queueLength -ErrorAction SilentlyContinue).Value
                if ($memCap -eq 0) { $capDesc = 'UNCAPPED' } else { $capDesc = "$([math]::Round($memCap/1024,0)) MB cap" }
                $lines += "WsusPool state=$poolState, privateMemory=$capDesc, queueLength=$qLen"
            }
            else {
                $lines += "WsusPool app pool not found"
            }
        }
        catch {
            $lines += "WsusPool state query failed: $($_.Exception.Message)"
        }

        # 3. Actual w3wp working set for WsusPool (balloon/recycle detection).
        try {
            $w3wp = Get-WmiObject Win32_Process -Filter "Name='w3wp.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -match 'WsusPool' } | Select-Object -First 1
            if ($w3wp) {
                $wsMB = [math]::Round($w3wp.WorkingSetSize / 1MB, 0)
                $lines += "WsusPool worker PID=$($w3wp.ProcessId) WorkingSet=$wsMB MB"
            }
            else {
                $lines += "WsusPool worker process not running (no w3wp for WsusPool)"
            }
        }
        catch {
            $lines += "WsusPool worker query failed: $($_.Exception.Message)"
        }

        # 4. SoftwareDistribution.log tail — surface the real failure reason
        #    (503, ODBC/database connect failures, pool recycles, OOM).
        try {
            $sdLog = 'C:\Program Files\Update Services\LogFiles\SoftwareDistribution.log'
            if (Test-Path $sdLog) {
                $hits = Get-Content $sdLog -Tail 400 -ErrorAction Stop |
                    Where-Object { $_ -match '503|ODBC|unable to connect to its database|recycl|OutOfMemory|System.OutOfMemoryException' } |
                    Select-Object -Last 5
                if ($hits) {
                    $lines += "SoftwareDistribution.log recent issues:"
                    foreach ($h in $hits) { $lines += "  $($h.ToString().Trim())" }
                }
                else {
                    $lines += "SoftwareDistribution.log: no 503/ODBC/recycle errors in last 400 lines"
                }
            }
        }
        catch {
            $lines += "SoftwareDistribution.log read failed: $($_.Exception.Message)"
        }

        return $lines
    }

    function Write-WsusDiagnostics {
        param([string]$Reason = "WSUS diagnostics")
        Write-DscStatus "$Tag --- $Reason ---"
        foreach ($l in (Get-WsusDiagnostics)) {
            Write-DscStatus "$Tag   $l"
        }
        Write-DscStatus "$Tag --- end $Reason ---"
    }

    function Set-WsusPoolHardened {
        # Uncap WsusPool memory + raise the queue so the pool survives a full
        # Microsoft Update sync. Mirrors the install-time hardening in
        # ConfigureWSUS (TemplateHelpDSC.psm1). The reactive repair path MUST
        # reharden BEFORE restarting — otherwise the pool comes back with the
        # default ~1.8 GB cap and the next sync dies the same way.
        try {
            Import-Module WebAdministration -ErrorAction Stop
        }
        catch {
            Write-DscStatus "$Tag WsusPool hardening skipped — WebAdministration unavailable: $_"
            return
        }
        $poolPath = 'IIS:\AppPools\WsusPool'
        if (-not (Test-Path $poolPath)) {
            Write-DscStatus "$Tag WsusPool not found — skipping hardening"
            return
        }
        $settings = @(
            @{ Name = 'recycling.periodicRestart.privateMemory'; Value = 0 }
            @{ Name = 'recycling.periodicRestart.requests'; Value = 0 }
            @{ Name = 'recycling.periodicRestart.time'; Value = [TimeSpan]::Zero }
            @{ Name = 'queueLength'; Value = 25000 }
            @{ Name = 'processModel.idleTimeout'; Value = [TimeSpan]::Zero }
            @{ Name = 'startMode'; Value = 'AlwaysRunning' }
            @{ Name = 'failure.rapidFailProtection'; Value = $false }
        )
        foreach ($s in $settings) {
            try {
                Set-ItemProperty -Path $poolPath -Name $s.Name -Value $s.Value -ErrorAction Stop
            }
            catch {
                Write-DscStatus "$Tag WsusPool: failed to set $($s.Name): $_"
            }
        }
        Write-DscStatus "$Tag WsusPool hardened (privateMemory uncapped, queueLength=25000)"
    }

    function Repair-WsusSync {
        # Remediate a stuck/failed WSUS sync by restarting the IIS app pool
        # and the SMS wsyncmgr component, then triggering a fresh sync.
        # Typical cause: WsusPool hit its default ~1.8 GB private-memory recycle
        # cap during the first full Microsoft Update category sync and recycled
        # mid-sync, returning HTTP 503; wsyncmgr couldn't write the failure to
        # SQL, leaving the sync status frozen at 6704 indefinitely.
        # Capture WSUS-native health BEFORE remediation so the log shows WHY.
        Write-WsusDiagnostics -Reason "WSUS health before repair"
        # Reharden the pool (uncap memory) BEFORE restarting — otherwise it comes
        # back with the default ~1.8 GB cap and the next sync dies the same way.
        Set-WsusPoolHardened
        Write-DscStatus "$Tag Restarting WsusPool app pool..."
        try {
            Import-Module WebAdministration -ErrorAction Stop
            Restart-WebAppPool WsusPool
            Write-DscStatus "$Tag WsusPool restarted"
        }
        catch {
            Write-DscStatus "$Tag Could not restart WsusPool: $_"
        }
        # Give the app pool time to fully initialize before wsyncmgr reconnects
        Start-Sleep -Seconds 15
        # Restart SMS_WSUS_SYNC_MANAGER by cycling SMS_EXECUTIVE. This clears
        # any cached connection state and lets wsyncmgr pick up the fresh app pool.
        Write-DscStatus "$Tag Restarting SMS_EXECUTIVE to cycle wsyncmgr..."
        try {
            Restart-Service SMS_EXECUTIVE -Force -ErrorAction Stop
            Start-Sleep -Seconds 30
            Write-DscStatus "$Tag SMS_EXECUTIVE restarted"
        }
        catch {
            Write-DscStatus "$Tag Could not restart SMS_EXECUTIVE: $_"
        }
        # Now trigger a fresh sync. Force the drop: the pool restart above just
        # aborted any in-flight sync, so CM's lingering 'running' state is stale
        # and the freshness guard must not suppress this re-trigger.
        Invoke-FullSync -Force
    }

    function Invoke-FullSync {
        # Skip if a sync is genuinely running — dropping full.syn during an
        # active sync is harmless but pointless. However, if the "running" state
        # is stale (>15 min unchanged), the sync is dead and we should proceed.
        # -Force bypasses the freshness guard: callers that just restarted the
        # WsusPool (Repair-WsusSync) have already killed any in-flight sync, so
        # CM's lingering 'running' state is stale-by-definition and a fresh
        # trigger MUST be dropped regardless of the reported timestamp.
        param([switch]$Force)
        $currentSync = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $siteCode } | Select-Object -First 1
        if (-not $Force -and $currentSync.LastSyncState -in @(6701, 6704, 6705, 6706)) {
            $syncStateNames = @{ 6701='Started'; 6704='Syncing WSUS'; 6705='Syncing DB'; 6706='Syncing Internet WSUS' }
            $stateName = $syncStateNames[$currentSync.LastSyncState]
            $stateAge = (Get-Date) - $currentSync.LastSyncStateTime
            if ($stateAge.TotalMinutes -le 15) {
                Write-DscStatus "$Tag Sync already in progress ($stateName, $([math]::Round($stateAge.TotalMinutes,1)) min) — skipping full.syn drop"
                return
            }
            Write-DscStatus "$Tag Sync state $stateName is stale ($([math]::Round($stateAge.TotalMinutes,0)) min) — proceeding with full.syn drop"
        }
        $syncFolder = "$CMInstallDir\inboxes\wsyncmgr.box"
        $syncFile = Join-Path $syncFolder "full.syn"
        if (Test-Path $syncFolder) {
            try {
                New-Item -Path $syncFile -ItemType File -Force | Out-Null
                Write-DscStatus "$Tag Triggered full WSUS sync (dropped full.syn)"
            }
            catch {
                Write-DscStatus "$Tag Error creating 'full.syn': $_"
            }
        }
    }

    function Get-WsusSyncLiveness {
        # Probe WSUS-native signals to decide whether a sync that CM reports as
        # "running" is GENUINELY alive, vs a zombie (CM stuck at 6704 while the
        # WSUS engine underneath is dead). Never throws. Returns:
        #   PoolUp         : WsusPool is Started AND a w3wp worker is alive. The
        #                    classic root-cause fault is the pool recycling at its
        #                    memory cap mid-sync, so a down pool is a hard fault.
        #   WsusRunning    : WSUS subscription is actively synchronizing (Running).
        #                    When this is true AND the pool is up, the sync is
        #                    alive and must NEVER be restarted.
        #   Phase          : NotProcessing / Categories / Updates (current phase).
        #   TotalItems /   : sync progress. Per the WSUS source (spSetSubscription-
        #   ProcessedItems   Progress), these ONLY advance during the Updates phase
        #                    -- they are pinned at 0 for the entire Categories phase
        #                    BY DESIGN, so a stalled count is NOT evidence of a hang.
        #   LastResult     : result of the last completed sync
        #                    (Succeeded/Failed/Canceled/NotProcessing).
        #   UpdateCount    : SUSDB update count (informational only; 0 until the
        #                    first full sync completes).
        $r = [PSCustomObject]@{
            PoolUp         = $false
            WsusRunning    = $false
            Phase          = $null
            TotalItems     = -1
            ProcessedItems = -1
            LastResult     = 'Unknown'
            UpdateCount    = -1
        }
        try {
            $srv = Get-WsusServer -ErrorAction Stop
            try { $r.UpdateCount = $srv.GetStatus().UpdateCount } catch { }
            $sub = $srv.GetSubscription()
            try {
                $syncStatus = $sub.GetSynchronizationStatus()
                $r.WsusRunning = ($syncStatus.ToString() -eq 'Running')
            }
            catch { }
            if ($r.WsusRunning) {
                try {
                    $prog = $sub.GetSynchronizationProgress()
                    $r.Phase = $prog.Phase.ToString()
                    $r.TotalItems = [int]$prog.TotalItems
                    $r.ProcessedItems = [int]$prog.ProcessedItems
                }
                catch { }
            }
            try {
                $lastInfo = $sub.GetLastSynchronizationInfo()
                $r.LastResult = $lastInfo.Result.ToString()
            }
            catch { }
        }
        catch { }

        # Pool liveness: Started state AND a live w3wp worker for WsusPool.
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $poolState = (Get-WebAppPoolState -Name WsusPool -ErrorAction SilentlyContinue).Value
            $w3wp = Get-WmiObject Win32_Process -Filter "Name='w3wp.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'WsusPool' } | Select-Object -First 1
            $r.PoolUp = ($poolState -eq 'Started') -and ($null -ne $w3wp)
        }
        catch { }

        return $r
    }

    function Wait-WsusSyncCompletion {
        # Poll sync status up to $MaxAttempts times (30s apart). Returns $true
        # if sync reaches 6702 (completed). On 6703 (failed), retries with
        # Invoke-FullSync and escalates to Repair-WsusSync every 3rd failure.
        #
        # CRITICAL: we NEVER restart a sync that WSUS confirms is actively running
        # (Get-WsusSyncLiveness.WsusRunning), especially during the Categories
        # phase -- WSUS writes no progress and CM's state timestamp sits unchanged
        # for many minutes BY DESIGN, so a stalled counter / stale CM timestamp is
        # NOT evidence of a hang. A running sync is only ever repaired on a genuine
        # HARD fault: the WsusPool worker actually crashed (PoolUp=false), or CM
        # and WSUS are confirmably desynced (WSUS idle + last sync Failed/Canceled
        # while CM still reports running) over several consecutive polls.
        param(
            [string]$Label = "Sync",
            [int]$MaxAttempts = 40,
            [switch]$TriggerFirst   # Drop full.syn before entering the wait loop
        )

        if ($TriggerFirst) {
            Invoke-FullSync
        }

        # Hard-fault streaks. A running sync is NEVER restarted on stalled
        # counters or a stale CM timestamp -- only on these confirmed faults,
        # each requiring several consecutive polls to rule out a transient race:
        #   poolDownStreak : WsusPool worker gone / pool stopped (crashed mid-sync)
        #   desyncStreak   : WSUS idle + last sync Failed/Canceled while CM=running
        $poolDownStreak = 0
        $desyncStreak = 0
        # Track 6702-with-Canceled-LastResult streaks separately: CM transitions to
        # 6702 ("Completed") even when the underlying WSUS sync ended Canceled or
        # Failed (CM treats "stopped" as "done"). A single 6702-Canceled poll could
        # be a stale LastResult from a *previous* sync that hasn't been overwritten
        # yet, so confirm over multiple polls before declaring this 6702 a false
        # positive. Once confirmed, retry / repair like a real failure.
        $falsePositive6702Streak = 0
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            Start-Sleep -Seconds 30
            $status = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $SiteCode } | Select-Object -First 1

            if ($status.LastSyncState -eq 6702) {
                # Cross-check the WSUS-side LastResult before accepting CM's 6702.
                # Canceled/Failed here means CM transitioned to 6702 but the WSUS
                # catalog wasn't actually populated -- accepting this would cause
                # Set-CMSoftwareUpdatePointComponent -AddProduct to silently no-op
                # against an empty catalog later (every -AddProduct name is dropped
                # unless it exists in SMS_UpdateCategoryInstance, which mirrors WSUS).
                $live = Get-WsusSyncLiveness
                if ($live.LastResult -in @('Canceled', 'Failed')) {
                    $falsePositive6702Streak++
                    if ($falsePositive6702Streak -ge 2) {
                        if ($attempt % 3 -eq 0) {
                            Write-DscStatus "$Tag $($Label): CM state 6702 but WSUS LastResult=$($live.LastResult) ($falsePositive6702Streak polls) -- false-positive completion. Repairing WSUS... (attempt $attempt of $MaxAttempts)"
                            Write-WsusDiagnostics -Reason "$Label false-positive 6702 ($($live.LastResult)) at attempt $attempt"
                            Repair-WsusSync
                        }
                        else {
                            Write-DscStatus "$Tag $($Label): CM state 6702 but WSUS LastResult=$($live.LastResult) -- treating as failed, retrying (attempt $attempt of $MaxAttempts)"
                            Invoke-FullSync
                        }
                        $falsePositive6702Streak = 0
                        $poolDownStreak = 0
                        $desyncStreak = 0
                        continue
                    }
                    else {
                        Write-DscStatus "$Tag $($Label): CM state 6702 with WSUS LastResult=$($live.LastResult) (poll $falsePositive6702Streak) -- confirming before retry (attempt $attempt of $MaxAttempts)"
                        continue
                    }
                }
                Write-DscStatus "$Tag $Label completed (attempt $attempt, WSUS LastResult=$($live.LastResult))"
                return $true
            }
            elseif ($status.LastSyncState -eq 6703) {
                if ($attempt % 3 -eq 0) {
                    Write-DscStatus "$Tag $Label failed $attempt times. Repairing WSUS services... (attempt $attempt of $MaxAttempts)"
                    Write-WsusDiagnostics -Reason "$Label failed (6703) at attempt $attempt"
                    Repair-WsusSync
                }
                else {
                    Write-DscStatus "$Tag $Label failed (attempt $attempt of $MaxAttempts). Triggering retry..."
                    Invoke-FullSync
                }
                $poolDownStreak = 0
                $desyncStreak = 0
            }
            elseif ($status.LastSyncState -in @(6701, 6704, 6705, 6706)) {
                $age = (Get-Date) - $status.LastSyncStateTime
                $live = Get-WsusSyncLiveness

                if (-not $live.PoolUp) {
                    # CM reports running but the WsusPool worker is gone / pool
                    # stopped -- the pool crashed mid-sync (the classic memory-cap
                    # recycle). A dead pool with the SUSDB sync phase frozen at
                    # "Running" IS the zombie, so this overrides any stale Running
                    # the DB still reports. Confirm over 2 polls (a deliberate
                    # recycle is brief) then repair.
                    $poolDownStreak++
                    $desyncStreak = 0
                    if ($poolDownStreak -ge 2) {
                        Write-DscStatus "$Tag $($Label): CM reports running but WsusPool is down ($poolDownStreak polls) -- pool crashed mid-sync. Repairing WSUS... (attempt $attempt of $MaxAttempts)"
                        Write-WsusDiagnostics -Reason "$Label WsusPool down at attempt $attempt"
                        Repair-WsusSync
                        $poolDownStreak = 0
                    }
                    else {
                        Write-DscStatus "$Tag $($Label): WsusPool worker not detected (poll $poolDownStreak) -- confirming before repair (attempt $attempt of $MaxAttempts)"
                    }
                }
                elseif ($live.WsusRunning) {
                    # WSUS itself confirms the sync engine is actively running and
                    # the pool is up. NEVER repair/restart a live sync -- during the
                    # Categories phase WSUS legitimately shows no UpdateCount /
                    # ProcessedItems movement and CM's state timestamp sits
                    # unchanged for many minutes BY DESIGN. Just log progress.
                    $poolDownStreak = 0
                    $desyncStreak = 0
                    $prog = ""
                    if ($live.Phase) { $prog = ", phase=$($live.Phase)" }
                    if ($live.ProcessedItems -ge 0) { $prog += ", items=$($live.ProcessedItems)/$($live.TotalItems)" }
                    Write-DscStatus "$Tag $Label running (CM state $($status.LastSyncState)$prog, WSUS UpdateCount=$($live.UpdateCount), attempt $attempt of $MaxAttempts)"
                }
                elseif ($live.LastResult -in @('Failed', 'Canceled')) {
                    # Pool is up but WSUS reports the subscription is NOT processing
                    # and the last sync ended Failed/Canceled, while CM still reports
                    # running. CM and WSUS are desynced -- the sync really stopped.
                    # Confirm over 4 polls (WSUS may have just finished and CM hasn't
                    # caught up) then repair.
                    $desyncStreak++
                    $poolDownStreak = 0
                    if ($desyncStreak -ge 4) {
                        Write-DscStatus "$Tag $($Label): CM reports running but WSUS not processing, last result=$($live.LastResult) ($desyncStreak polls) -- CM/WSUS desync. Repairing WSUS... (attempt $attempt of $MaxAttempts)"
                        Write-WsusDiagnostics -Reason "$Label CM/WSUS desync ($($live.LastResult)) at attempt $attempt"
                        Repair-WsusSync
                        $desyncStreak = 0
                    }
                    else {
                        Write-DscStatus "$Tag $($Label): WSUS not processing (last result=$($live.LastResult), poll $desyncStreak) -- confirming before repair (attempt $attempt of $MaxAttempts)"
                    }
                }
                else {
                    # Pool up, WSUS not processing, last result Succeeded /
                    # NotProcessing -- WSUS is idle: it finished and CM hasn't
                    # transitioned to 6702 yet, or a sync hasn't engaged. WSUS is
                    # NOT running, so a gentle re-trigger is safe once CM has been
                    # stale a long time; otherwise keep waiting.
                    $poolDownStreak = 0
                    $desyncStreak = 0
                    if ($age.TotalMinutes -gt 20) {
                        Write-DscStatus "$Tag $($Label): WSUS idle (last result=$($live.LastResult)) and CM state $($status.LastSyncState) stale $([math]::Round($age.TotalMinutes,0)) min -- re-triggering sync (attempt $attempt of $MaxAttempts)"
                        Invoke-FullSync
                    }
                    else {
                        Write-DscStatus "$Tag $($Label): WSUS idle (last result=$($live.LastResult)), waiting for CM (CM state $($status.LastSyncState), age $([math]::Round($age.TotalMinutes,0)) min, attempt $attempt of $MaxAttempts)"
                    }
                }
            }
            else {
                Write-DscStatus "$Tag $Label unexpected state $($status.LastSyncState) (attempt $attempt of $MaxAttempts)"
            }
        }
        Write-DscStatus "$Tag $Label did not complete after $MaxAttempts attempts."
        Write-WsusDiagnostics -Reason "$Label final timeout diagnostics"
        return $false
    }

    # Resolve a curated product name to the ACTUAL CM/WSUS catalog title.
    # Microsoft spells the same product differently across the WSUS
    # (Get-WsusProduct.Title) and CM (Get-CMSoftwareUpdateCategory's
    # LocalizedCategoryInstanceName) APIs and across releases, so an exact
    # string compare silently drops valid products: Set-CMSoftwareUpdatePoint-
    # Component ignores any -AddProduct name not present VERBATIM in
    # SMS_UpdateCategoryInstance (no error, no warning). Observed live: the
    # curated 'Microsoft SQL Server 2022' / 'Windows 11' never matched the
    # catalog ('SQL Server 2022' / a version-qualified Windows 11 title), so
    # they were reported 'missing from catalog' on every run and never
    # subscribed.
    #
    # Strategy: exact (case-insensitive) match first; otherwise an all-token
    # substring match using a per-product signature, picking the shortest
    # (most generic parent) catalog title. Returns $null only when the product
    # is genuinely absent from the supplied catalog (caller treats that as
    # 'needs a sync' and re-resolves once the catalog is populated).
    function Resolve-CMProductName {
        param(
            [Parameter(Mandatory)][string]$Desired,
            [string[]]$Catalog
        )
        if (-not $Catalog -or @($Catalog).Count -eq 0) { return $null }

        # 1. Exact, case-insensitive.
        $exact = @($Catalog | Where-Object { $_ -ieq $Desired })
        if ($exact.Count -gt 0) { return $exact[0] }

        # 2. Token signature for every curated name this script produces.
        #    All tokens must appear (case-insensitive substring) in the title.
        $tokenMap = @{
            'Windows Server 2016'                        = @('windows server 2016')
            'Windows Server 2019'                        = @('windows server 2019')
            'Microsoft Server operating system-21H2'     = @('server operating system', '21h2')
            'Microsoft Server Operating System-24H2'     = @('server operating system', '24h2')
            'Windows 10, version 1903 and later'         = @('windows 10', '1903')
            'Windows 11'                                 = @('windows 11')
            'Microsoft SQL Server 2016'                  = @('sql server 2016')
            'Microsoft SQL Server 2017'                  = @('sql server 2017')
            'Microsoft SQL Server 2019'                  = @('sql server 2019')
            'Microsoft SQL Server 2022'                  = @('sql server 2022')
            'Microsoft SQL Server 2025'                  = @('sql server 2025')
            'Microsoft 365 Apps/Office 2019/Office LTSC' = @('365 apps')
        }
        $tokens = $tokenMap[$Desired]
        if (-not $tokens) { return $null }

        $cands = @($Catalog | Where-Object {
                $n = $_.ToLowerInvariant()
                $missing = @($tokens | Where-Object { $n -notlike "*$($_.ToLowerInvariant())*" })
                $missing.Count -eq 0
            })
        if ($cands.Count -eq 0) { return $null }
        return ($cands | Sort-Object { $_.Length } | Select-Object -First 1)
    }

    # Kick off WSUS sync early so it runs in background while we create collections
    $Sups = $deployConfig.VirtualMachines | Where-Object { $_.InstallSup -and $_.SiteCode -eq $siteCode }
    $syncNeeded = $false

    if ($cmo.OfflineSUP) {
        $Sups = $false
        Write-DscStatus "$Tag Offline SUP requested, skipping the SUP product check"
    }

    if ($Sups) {
        $productclassifications = Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Where-Object { $_.IsSubscribed } | Select-Object -ExpandProperty LocalizedCategoryInstanceName

        # Only consider VMs that actually receive CM client push -- those are the
        # only machines whose OS/SQL versions need a SUP product subscription.
        # Mirrors the pushable-VM filter used in Common.Phases.ps1 / Common.Config.ps1
        # so a server marked pushClient=false (or a non-pushable role like DC,
        # WSUS, SQLAO, WorkgroupMember, InternetClient, AADClient) is excluded
        # and we don't pull thousands of irrelevant updates into the lab catalog.
        $pushableRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
        $clientVMs = @($deployConfig.virtualMachines | Where-Object {
                $_.role -in $pushableRoles -and ($_.pushClient -ne $false)
            })

        $products = ($clientVMs.operatingSystem | Select-Object -Unique) + ($clientVMs.sqlversion | Select-Object -Unique)

        # Filter out Linux OS names — WSUS has no products for Ubuntu/Linux
        $products = @($products | Where-Object { $_ -and $_ -notmatch '^Ubuntu|^CentOS|^RHEL|^Debian|^Linux' })

        # Rename products to match SUP naming convention.
        # OS names may have date/variant suffixes (e.g. "Server 2019 March 2021")
        # so anchors use .* instead of $ to match variants.
        $products = $products -replace "^Server 2016\b.*$", "Windows Server 2016"
        # Product names below match WSUS canonical titles exactly (the strings
        # found in upd:Title on entries with CategoryType="Product" inside the
        # cab's metadata.txt and in $wsus.GetUpdateCategories()). Microsoft is
        # inconsistent across releases: Server 2022 ("21H2") ships as lowercase
        # "operating system" while Server 2025 ("24H2") ships as Capital O+S
        # "Operating System". SQL is uniformly capital "Server". CM's category
        # lookup is case-insensitive (default SQL collation), so the AddProduct
        # bind worked either way; matching canonical here keeps the perfloading
        # log lines (and the 'Enabling missing products' warning) byte-identical
        # to what shows up in WSUS / the cab.
        $products = $products -replace "^Server 2019\b.*$", "Windows Server 2019"
        $products = $products -replace "^Server 2022\b.*$", "Microsoft Server operating system-21H2"
        $products = $products -replace "^Server 2025\b.*$", "Microsoft Server Operating System-24H2"
        $products = $products -replace "^Windows 10\b.*$", "Windows 10, version 1903 and later"
        $products = $products -replace "^Windows 11\b.*$", "Windows 11"
        $products = $products -replace "^Sql Server 2016\b.*$", "Microsoft SQL Server 2016"
        $products = $products -replace "^Sql Server 2017\b.*$", "Microsoft SQL Server 2017"
        $products = $products -replace "^Sql Server 2019\b.*$", "Microsoft SQL Server 2019"
        $products = $products -replace "^Sql Server 2022\b.*$", "Microsoft SQL Server 2022"
        $products = $products -replace "^Sql Server 2025\b.*$", "Microsoft SQL Server 2025"

        # Only subscribe to Office updates when a pushable client actually installs Office.
        if (@($clientVMs | Where-Object { $_.installOffice -and $_.installOffice -ne $false }).Count -gt 0) {
            $products += "Microsoft 365 Apps/Office 2019/Office LTSC"
        }

        $products = @($products | Where-Object { $_ } | Select-Object -Unique)
        Write-DscStatus "$Tag Dynamic SUP product set ($($products.Count)) from $($clientVMs.Count) pushable VMs: $($products -join ', ')"

        # Map each curated product name to the ACTUAL CM catalog title so every
        # downstream compare (subscribed / missing / in-catalog) and the
        # AddProduct call use the exact string CM expects. Products not yet in
        # the catalog keep their curated name here and are re-resolved after
        # sync 1 at AddProduct time.
        $allCatalogProducts = @(Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Select-Object -ExpandProperty LocalizedCategoryInstanceName)
        $resolvedProducts = @()
        foreach ($p in $products) {
            $actual = Resolve-CMProductName -Desired $p -Catalog $allCatalogProducts
            if ($actual) {
                if ($actual -ine $p) { Write-DscStatus "$Tag Product '$p' resolved to catalog title '$actual'" }
                $resolvedProducts += $actual
            }
            else {
                $resolvedProducts += $p
            }
        }
        $products = @($resolvedProducts | Select-Object -Unique)

        $missingproducts = @($products | Where-Object { $_ -notin $productclassifications })

        # Check if the specific products we need exist as categories in the
        # full catalog (not just subscribed). WSUS ships with built-in
        # categories, so a generic count isn't meaningful. If our target
        # products are present, sync 1 has populated the catalog and we can
        # subscribe without waiting for the current sync. (Names are already
        # resolved to actual catalog titles above.)
        $productsInCatalog = @($products | Where-Object { $_ -in $allCatalogProducts })
        # Gate Sync 1 on the *core* OS/SQL products only. Compound/aliased names
        # (the Office bundle string) may never match a single catalog category,
        # so requiring an exact full-set match means the gate is never satisfied
        # and Sync 1 re-waits every build. Core OS/SQL categories only appear
        # after a real Microsoft Update sync, so they're the reliable
        # "catalog is populated" signal.
        $coreProducts = @($products | Where-Object { $_ -notmatch '/' })
        $coreInCatalog = @($coreProducts | Where-Object { $_ -in $allCatalogProducts })
        $catalogHasOurProducts = ($coreProducts.Count -gt 0) -and ($coreInCatalog.Count -eq $coreProducts.Count)

        if ($missingproducts.Count -gt 0) {
            $syncNeeded = $true
            Write-DscStatus "$Tag SUP products missing ($($missingproducts.Count)): $($missingproducts -join ', ')"
            if ($catalogHasOurProducts) {
                # Our target products exist in the catalog from a previous sync —
                # no need to trigger or wait for sync 1. Skip straight to subscribing.
                Write-DscStatus "$Tag Target products found in catalog ($($productsInCatalog.Count)/$($products.Count)) — skipping sync 1 wait"
            }
            else {
                # First run: catalog doesn't have our products yet, need sync 1.
                $missingFromCatalog = @($products | Where-Object { $_ -notin $allCatalogProducts })
                Write-DscStatus "$Tag Products missing from catalog ($($missingFromCatalog.Count)/$($products.Count)): $($missingFromCatalog -join ', ')"
                # Only trigger early sync if WCM is at SUCCESS — otherwise the sync
                # will fail with 'WSUS server not configured' and block WCM from
                # finishing its subscription setup (deadlock).
                $wcmRegPath = 'HKLM:\SOFTWARE\Microsoft\SMS\COMPONENTS\SMS_WSUS_CONFIGURATION_MANAGER'
                try {
                    $wcmEarlyState = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
                } catch { $wcmEarlyState = -1 }
                if ($wcmEarlyState -eq 2) {
                    Write-DscStatus "$Tag Triggering WSUS sync now (will finish later while we create collections)"
                    Invoke-FullSync
                }
                else {
                    $wcmStateNames = @{ 0='NONE'; 1='PENDING'; 2='SUCCESS'; 3='FAILED'; 4='SUBSCRIPTION_PENDING' }
                    $wcmName = if ($wcmStateNames.ContainsKey($wcmEarlyState)) { $wcmStateNames[$wcmEarlyState] } else { "UNKNOWN($wcmEarlyState)" }
                    Write-DscStatus "$Tag WCM state is $wcmName — skipping early sync to avoid blocking WCM"
                }
            }
        }
        else {
            Write-DscStatus "$Tag SUP products and classifications are already enabled ($($productclassifications.Count) subscribed)."
        }
    }

    # Define additional device collection information
    $Collections += @(
        @{
            Name  = "MEMLABS-Windows 7 Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version LIKE '6.1%'
"@
        },
        @{
            Name  = "MEMLABS-Windows 8.1 Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version LIKE '6.3%'
"@
        },
        @{
            Name  = "MEMLABS-Devices Without Antivirus"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_Installed_Software ON SMS_G_System_Installed_Software.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_Installed_Software.ProductName NOT LIKE '%Antivirus%'
"@
        },
        @{
            Name  = "MEMLABS-Laptops Only"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_SYSTEM_ENCLOSURE ON SMS_G_System_SYSTEM_ENCLOSURE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_SYSTEM_ENCLOSURE.ChassisTypes IN ('8', '9', '10', '14', '18', '21')
"@
        },
        @{
            Name  = "MEMLABS-Desktop Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_SYSTEM_ENCLOSURE ON SMS_G_System_SYSTEM_ENCLOSURE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_SYSTEM_ENCLOSURE.ChassisTypes IN ('3', '4', '6', '7', '15')
"@
        },
        @{
            Name  = "MEMLABS-Virtual Machines"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_SYSTEM_ENCLOSURE ON SMS_G_System_SYSTEM_ENCLOSURE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_SYSTEM_ENCLOSURE.ChassisTypes = '12'
"@
        },
        @{
            Name  = "MEMLABS-Devices Without SCCM Client"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_SYSTEM.Client IS NULL OR SMS_R_SYSTEM.Client = 0
"@
        },
        @{
            Name  = "MEMLABS-Devices With Less Than 4GB RAM"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_PHYSICAL_MEMORY ON SMS_G_System_PHYSICAL_MEMORY.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_PHYSICAL_MEMORY.Capacity < 4294967296
"@
        },
        @{
            Name  = "MEMLABS-All MacOS Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_System.OperatingSystemNameAndVersion LIKE '%MacOS%'
"@
        },
        @{
            Name  = "MEMLABS-All Linux Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_System.OperatingSystemNameAndVersion LIKE '%Linux%'
"@
        },
        @{
            Name  = "MEMLABS-All Devices with Office- Microsoft 365 Apps"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_INSTALLED_SOFTWARE ON SMS_G_System_INSTALLED_SOFTWARE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_INSTALLED_SOFTWARE.ProductName LIKE '%Microsoft 365 Apps%'
"@
        },
        @{
            Name  = "MEMLABS-All Devices with Disk Space < 20GB"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_LOGICAL_DISK ON SMS_G_System_LOGICAL_DISK.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_LOGICAL_DISK.FreeSpace < 20000000000
"@
        },
        @{
            Name  = "MEMLABS-All Devices in Domain XYZ"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_System.ResourceDomainORWorkgroup = 'XYZ'
"@
        },
        @{
            Name  = "MEMLABS-All Devices with BitLocker Disabled"
            Query = @"
select SMS_R_System.Name, SMS_G_System_ENCRYPTABLE_VOLUME.DriveLetter, SMS_G_System_ENCRYPTABLE_VOLUME.ProtectionStatus 
from SMS_R_System inner join SMS_G_System_ENCRYPTABLE_VOLUME on SMS_G_System_ENCRYPTABLE_VOLUME.ResourceId = SMS_R_System.ResourceId
where SMS_G_System_ENCRYPTABLE_VOLUME.DriveLetter = "C:" and SMS_G_System_ENCRYPTABLE_VOLUME.ProtectionStatus = 1 order by SMS_R_System.Name
"@
        },
        @{
            Name  = "MEMLABS-All Devices with Google Chrome Installed"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_INSTALLED_SOFTWARE ON SMS_G_System_INSTALLED_SOFTWARE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_INSTALLED_SOFTWARE.ProductName LIKE '%Google Chrome%'
"@
        },
        @{
            Name  = "MEMLABS-All Devices with Last Logon Older Than 90 Days"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE DATEDIFF(day, SMS_R_SYSTEM.LastLogonTimestamp, GETDATE()) > 90
"@
        },
        @{
            Name  = "MEMLABS-Devices Missing Critical Updates"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_UpdateComplianceStatus ON SMS_UpdateComplianceStatus.MachineID = SMS_R_System.ResourceID
INNER JOIN SMS_SoftwareUpdate ON SMS_SoftwareUpdate.CI_ID = SMS_UpdateComplianceStatus.CI_ID
WHERE SMS_UpdateComplianceStatus.Status = 2 AND SMS_SoftwareUpdate.SeverityName = 'Critical'
"@
        },
        @{
            Name  = "MEMLABS-Devices Online Now"
            Query = @"
select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,
SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.ResourceId in
(select resourceid from SMS_CollectionMemberClientBaselineStatus where SMS_CollectionMemberClientBaselineStatus.CNIsOnline = 1)
"@
        },
        @{
            Name  = "MEMLABS-Devices Offline for Over 30 Days"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE DATEDIFF(day, SMS_R_SYSTEM.LastLogonTimestamp, GETDATE()) > 30
"@
        },
        @{
            Name  = "MEMLABS-High CPU Usage Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_PROCESSOR ON SMS_G_System_PROCESSOR.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_PROCESSOR.LoadPercentage > 90
"@
        },
        @{
            Name  = "MEMLABS-All Workgroup Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_SYSTEM.ResourceDomainORWorkgroup NOT LIKE '%DOMAIN%'
"@
        },
        @{
            Name  = "MEMLABS-Devices Running SQL Server"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_INSTALLED_SOFTWARE ON SMS_G_System_INSTALLED_SOFTWARE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_INSTALLED_SOFTWARE.ProductName LIKE '%SQL Server%'
"@
        },
        @{
            Name  = "MEMLABS-All Domain Controllers"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_SYSTEM.Name LIKE '%DC%'
"@
        },
        @{
            Name  = "MEMLABS-All Devices in Specific OU"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_SYSTEM.DistinguishedName LIKE '%OU=MEMLABS,DC=Domain,DC=com%'
"@
        },
        @{
            Name  = "MEMLABS-All Devices Missing a Default Gateway"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_NETWORK_ADAPTER_CONFIGURATION ON SMS_G_System_NETWORK_ADAPTER_CONFIGURATION.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_NETWORK_ADAPTER_CONFIGURATION.DefaultIPGateway IS NULL
"@
        }

        @{
            Name  = "MEMLABS-Windows 10 Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version LIKE '10.0.1%'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version LIKE '10.0.22%'
"@
        },
        @{
            Name  = "MEMLABS-Windows Server 2016 Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.14393'
"@
        },
        @{
            Name  = "MEMLABS-Windows Server 2019 Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.17763'
"@
        },
        @{
            Name  = "MEMLABS-Windows Server 2022 Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.20348'
"@
        },
        @{
            Name  = "MEMLABS-Windows Server 2025 Devices"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.26100'
"@
        },
        @{
            Name  = "MEMLABS-Windows 10 21H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.19044'
"@
        },
        @{
            Name  = "MEMLABS-Windows 10 22H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.19045'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 23H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.22631'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 24H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.26100'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 21H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.22000'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 22H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.22621'
"@
        },
        @{
            Name  = "MEMLABS-All Non client Devices"
            Query = @"
select Name, SMSAssignedSites, IPAddresses, IPSubnets, OperatingSystemNameandVersion, ResourceDomainORWorkgroup, LastLogonUserDomain, LastLogonUserName, SMSUniqueIdentifier, ResourceId, ResourceType, NetbiosName 
from sms_r_system where Client = 0 or Client is null
"@
        },
        @{
            Name  = "MEMLABS-All Servers"
            Query = @"
select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client 
from SMS_R_System 
where SMS_R_System.OperatingSystemNameandVersion like "%Server%" order by SMS_R_System.Name          
"@
        },
        @{
            Name  = "MEMLABS-All Workstations"
            Query = @"
select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client 
from SMS_R_System 
where SMS_R_System.OperatingSystemNameandVersion like "%Workstation%" order by SMS_R_System.Name      
"@
        }
    )


    # MEMLABS-* device collections + the Office Install Targets collection +
    # the Office deployment recovery sweep are all Primary-tier work. In a
    # hierarchy the CAS holds no client resources (clients report to the
    # Primary's MP) so creating these collections at the CAS scope produces
    # nothing but empty collections + replication noise + colleval load. The
    # apps/packages, OSD/TS and Office-app blocks above are already gated
    # this same way; this block was missed and was running on CAS too.
    if ($CurrentRole -ne "CAS") {

    $collectionReconcileTimer = [System.Diagnostics.Stopwatch]::StartNew()

        # Check if MEMLABS folder exists under Device Collections
    $folder = Get-CMFolder -FolderPath "\DeviceCollection\MEMLABS"

    if (-not $folder) {
        # Create MEMLABS folder if it does not exist
        New-CMFolder -Name "MEMLABS" -ParentFolderPath "\DeviceCollection"
        Write-DscStatus "$Tag MEMLABS folder created under Device Collections."
    }
    else {
        Write-DscStatus "$Tag MEMLABS folder already exists under Device Collections."
    }


    # Loop through each collection and ensure it exists AND carries its query
    # membership rule. Membership reconciliation must NOT be gated on the
    # collection being newly created: on a re-run (or a prior partial run that
    # created the collection but died before Add-CMDeviceCollectionQueryMembership-
    # Rule) the collection exists but has no rule, and the old "if (-not Get-
    # CMDeviceCollection)" guard skipped it -- leaving the collection permanently
    # empty. Checking for existence is not a reason to skip populating members.
    $existingCollectionsByName = @{}
    $collectionInventoryLoaded = $false
    try {
        foreach ($existingCollection in @(Get-CMDeviceCollection -Name "MEMLABS-*" -ErrorAction Stop)) {
            if ($existingCollection.Name) { $existingCollectionsByName["$($existingCollection.Name)"] = $existingCollection }
        }
        $collectionInventoryLoaded = $true
    }
    catch {
        Write-DscStatus "$Tag WARNING: Could not load MEMLABS collections in one query; falling back to per-collection checks: $($_.Exception.Message)"
    }
    $collectionsCreated = 0
    $collectionsSkipped = 0
    $collectionRulesAdded = 0
    $collectionRulesSkipped = 0
    Write-DscStatus "$Tag Reconciling $($Collections.Count) MEMLABS collection definition(s) against $($existingCollectionsByName.Count) existing collection(s)"
    foreach ($Collection in $Collections) {
        $CollectionName = $Collection.Name
        $Query = $Collection.Query
        $ruleName = "$CollectionName Rule"

        try {
            # Ensure the collection exists.
            $col = if ($collectionInventoryLoaded) {
                $existingCollectionsByName[$CollectionName]
            }
            else {
                Get-CMDeviceCollection -Name $CollectionName -ErrorAction Stop
            }
            if (-not $col) {
                $col = New-CMDeviceCollection -Name $CollectionName -LimitingCollectionName "All Systems" -Comment "Collection for $CollectionName"
                $existingCollectionsByName[$CollectionName] = $col
                $collectionsCreated++
                Write-DscStatus "$Tag Created collection: $CollectionName"
                Move-CMObject -FolderPath "$SiteCode`:\Devicecollection\MEMLABS" -ObjectId $col.CollectionID -ErrorAction SilentlyContinue
                Write-DscStatus "$Tag Moved collection '$CollectionName' under the folder MEMLABS"
            }
            else {
                $collectionsSkipped++
            }

            if (-not $col) {
                Write-DscStatus "$Tag WARNING: Could not create or resolve collection '$CollectionName'; skipping rule"
                continue
            }

            # ALWAYS ensure the query membership rule is present -- add it when
            # missing regardless of whether we just created the collection.
            $existingRules = @(Get-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue)
            $haveRule = @($existingRules | Where-Object { $_.RuleName -eq $ruleName }).Count -gt 0
            if (-not $haveRule) {
                Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -QueryExpression $Query -RuleName $ruleName -ErrorAction Stop
                $collectionRulesAdded++
                Write-DscStatus "$Tag Added collection query rule: $ruleName"
                # Force membership evaluation so members appear immediately.
                Invoke-CMCollectionUpdate -CollectionId $col.CollectionID -ErrorAction SilentlyContinue
            }
            else {
                $collectionRulesSkipped++
            }
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to fully configure collection '$CollectionName': $($_.Exception.Message)"
        }
    }
    $collectionReconcileTimer.Stop()
    Write-DscStatus "$Tag Collection reconcile: $collectionsCreated created, $collectionsSkipped already present; $collectionRulesAdded rules added, $collectionRulesSkipped already present in $([math]::Round($collectionReconcileTimer.Elapsed.TotalSeconds, 1))s"

    # Office Install Targets collection: ensure it exists with a current query
    # rule. The collection + deployment + members all belong on the Primary;
    # this is reached only on Primary/standalone now (the outer CAS-skip
    # gate above takes care of the hierarchy CAS path).
    $officeTargetVMs = @($deployConfig.virtualMachines | Where-Object { $_.installOffice -and $_.installOffice -ne $false })
    if ($officeTargetVMs.Count -gt 0) {
        Set-OfficeInstallTargetsCollection -OfficeTargetVMs $officeTargetVMs | Out-Null

        # Self-heal missing Office deployments. The original perfloading flow
        # created the deployment immediately after the app and short-circuits
        # on re-runs ("application already exists, skipping"). If a prior run
        # hit the order bug (deployment created against a not-yet-existing
        # collection) the deployment was lost forever. Re-establish here.
        $officeAppNameBase = "MEMLABS-Microsoft365Apps"
        $officeChannels = @($officeTargetVMs | ForEach-Object { $_.installOffice } | Select-Object -Unique)
        $officeColName = "MEMLABS-Office Install Targets"
        foreach ($ch in $officeChannels) {
            $appName = if ($officeChannels.Count -eq 1) { $officeAppNameBase } else { "$officeAppNameBase-$ch" }
            if (-not (Get-CMApplication -Name $appName -Fast -ErrorAction SilentlyContinue)) { continue }
            $existingDep = Get-CMApplicationDeployment -Name $appName -CollectionName $officeColName -ErrorAction SilentlyContinue
            if (-not $existingDep) {
                try {
                    New-CMApplicationDeployment -ApplicationName $appName `
                        -CollectionName $officeColName `
                        -DeployAction Install `
                        -DeployPurpose Required `
                        -UserNotification DisplayAll `
                        -ErrorAction Stop | Out-Null
                    Write-DscStatus "$Tag Recovered missing Office deployment for '$appName' -> '$officeColName'"
                }
                catch {
                    Write-DscStatus "$Tag WARNING: Failed to (re)create Office deployment for '$appName': $($_.Exception.Message)"
                }
            }
            else {
                # Deployment exists; force a policy re-author so any collection
                # member added after the original deployment author time gets
                # the assignment projected. Symptom this fixes: client's
                # PolicyAgent RequestedConfig has 7-Zip / other assignments
                # but not the Office assignment, even though the collection
                # contains the client and the deployment targets it.
                Update-OfficeDeploymentPolicy -AppName $appName -CollectionName $officeColName
            }
        }
    }

    } # end Primary-only collections + Office Install Targets block

    #install Endpoint protection role in hierarchy to support defender updates
    if (!(Get-CMEndpointProtectionPoint -AllSite)) {
        try {
            # this is needed for defender updates and management
            Add-CMEndpointProtectionPoint -ProtectionService AdvancedMembership -SiteCode $SiteCode -SiteSystemServerName $ProviderMachineName
            Write-DscStatus "$Tag Endpoint protection role to support defender patching is installed"
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to install Endpoint Protection Point: $_"
        }
    }

    # Client settings — top-level site only (replicate to child sites)
    if ($isTopLevel) {
    if (!(Get-CMClientSetting -Name MEMLABS-Defender)) {
        New-CMClientSetting -Name MEMLABS-Defender -Description "Defender execution policy" -Type Device -ErrorAction SilentlyContinue
        Set-CMClientSettingEndpointProtection -Name MEMLABS-Defender -Enable $true -DisableFirstSignatureUpdate $true -ForceRebootHr $true -InstallEndpointProtectionClient $true -OverrideMaintenanceWindow $true -DefenderAgent MdeDownlevel -SuppressReboot $true -PersistInstallation $true 
        New-CMClientSettingDeployment -Name MEMLABS-Defender -CollectionId SMS00001
        Write-DscStatus "$Tag Client setting to support Defender patching is enabled"   
    }
    
    if (!(Get-CMClientSetting -Name MEMLABS-Updates)) {
        New-CMClientSetting -Name MEMLABS-Updates -Description "Updates M365 policy" -Type Device -ErrorAction SilentlyContinue
        Set-CMClientSettingSoftwareUpdate -EnableInstallation $true -Name MEMLABS-Updates -EnableThirdPartyUpdates $true -Office365ManagementType $true -EnableDeltaDownload $true -EnableDynamicUpdate $true -Enable $true
        New-CMClientSettingDeployment -Name MEMLABS-Updates -CollectionId SMS00001
        Write-DscStatus "$Tag Client setting to support O365 patching is enabled"
    }

    # Once the EP agent lands it owns HKLM\SOFTWARE\Policies\...\Windows Defender
    # and sets LocalSettingOverride*=0 + DisableLocalAdminMerge=1, so everything
    # Optimize-Defender.ps1 does locally stops taking effect. Put the same intent
    # in the policy the agent honours. Every parameter below is an absolute set,
    # so re-running perfloading converges instead of accumulating.
    $amDefault = @(Get-CMAntimalwarePolicy -ErrorAction SilentlyContinue) |
        Where-Object { $_.ObjectClass -eq 'SMS_AntimalwareSettingsDefault' -or $_.SmsProviderObjectPath -like 'SMS_AntimalwareSettingsDefault*' } |
        Select-Object -First 1
    if (-not $amDefault) {
        Write-DscStatus "$Tag WARNING: Default antimalware policy not found; Defender stays at CM defaults and will override the local tuning"
    }
    else {
        # One call per parameter set -- Set-CMAntimalwarePolicy will not mix them.
        $amEdits = @(
            @{ Label = 'real-time protection off'; Args = @{ RealTimeProtectionOn = $false } }
            @{ Label = 'scan scope reduced'; Args = @{ ScanArchive = $false; ScanEmail = $false; ScanNetworkDrive = $false; ScanRemovableStorage = $false } }
            @{ Label = 'scheduled scan off'; Args = @{ EnableScheduledScan = $false } }
            @{
                Label = 'exclusions'
                Args  = @{
                    ExcludeFilePath = @(
                        'C:\staging', 'C:\temp', 'C:\tools', 'C:\CMCB', 'C:\inetpub',
                        'C:\Windows\System32\Configuration', 'C:\Windows\System32\inetsrv',
                        'C:\Windows\CCM', 'C:\Windows\ccmcache', 'C:\Windows\ccmsetup',
                        'C:\Windows\SoftwareDistribution\Download'
                    )
                    ExcludeFileType = @('mdf', 'ldf', 'ndf', 'bak', 'trn', 'vhd', 'vhdx')
                    ExcludeProcess  = @(
                        'sqlservr.exe', 'sqlagent.exe', 'sqlwriter.exe', 'sqlceip.exe', 'fdhost.exe', 'fdlauncher.exe',
                        'ReportingServicesService.exe',
                        'smsexec.exe', 'sitecomp.exe', 'cmupdate.exe', 'smsdbmon.exe', 'smswriter.exe', 'smssqlbkup.exe',
                        'smsdpmon.exe', 'CmRcService.exe',
                        'CcmExec.exe', 'ccmsetup.exe', 'CcmRepair.exe', 'PolicyPv.exe',
                        'w3wp.exe', 'WsusService.exe', 'wsusutil.exe'
                    )
                }
            }
        )
        foreach ($amEdit in $amEdits) {
            $amArgs = $amEdit.Args
            try {
                Set-CMAntimalwarePolicy -Name $amDefault.Name @amArgs -ErrorAction Stop
                Write-DscStatus "$Tag Default antimalware policy: $($amEdit.Label)"
            }
            catch {
                Write-DscStatus "$Tag WARNING: Default antimalware policy '$($amEdit.Label)' failed: $($_.Exception.Message)"
            }
        }
    }
    } # end top-level client settings
    
    # Now wait for WSUS sync that was triggered earlier (ran during collection creation)
    if (-not $Sups) {
        Write-DscStatus "$Tag No SUP installed for this site, skipping the SUP product check and sync"
    }

    if ($Sups -and $syncNeeded) {
        # Safety net: InstallRoles owns the cab import (launch +
        # verify+retry). By the time perfloading runs, the state file
        # is normally already removed and this call is a no-op. The
        # call stays so that an InstallRoles pass that didn't reach
        # the wait (early-return, exception before Wait, etc.) still
        # gets caught here before perfloading triggers a CM-side sync
        # on top of an in-flight or partial wsusutil import.
        Wait-WsusBaselineImport -Tag $Tag

        # Two syncs are needed for WSUS to be fully operational:
        #   Sync 1: Pulls in the product catalog so products can be subscribed
        #   Sync 2: After subscribing to products, downloads update metadata
        # InstallRoles already ran sync 1 and waited for it, plus we may have
        # fired an early background sync above. Verify sync 1 completed before
        # adding products — if not, wait for it (up to ~20 min).
        #
        # On re-run: if the product catalog is already populated (from a
        # previous sync 1), skip the wait entirely — we can subscribe
        # products immediately without waiting for any current sync.
        $sync1Done = $false
        if ($ThisVM.hidden) {
            # This Primary is hidden => it's an existing, already-deployed site
            # server pulled into the config only so a *new* VM (e.g. a client added
            # to an existing domain) can get PushClients re-run. There is no actual
            # deployment happening to this site server, so blocking here for up to
            # 40 attempts (~40 min) waiting on a WSUS sync is pure dead time. Kick a
            # background sync off (only when the catalog still needs our products) so
            # the catalog refreshes on its own, and proceed without monitoring it.
            if ($catalogHasOurProducts) {
                Write-DscStatus "$Tag Primary is hidden (re-run for a new VM) and products already in catalog — skipping sync 1 wait"
            }
            else {
                Write-DscStatus "$Tag Primary is hidden (re-run for a new VM) — triggering background sync 1 and NOT waiting"
                Invoke-FullSync
            }
            $sync1Done = $true
        }
        elseif ($catalogHasOurProducts) {
            Write-DscStatus "$Tag Target products already in catalog ($($productsInCatalog.Count)/$($products.Count)) — skipping sync 1 wait, proceeding to subscribe"
            $sync1Done = $true
        }
        else {
            $syncStatus = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $SiteCode } | Select-Object -First 1
            if ($syncStatus.LastSyncState -eq 6702) {
                Write-DscStatus "$Tag Sync 1 already completed (last: $($syncStatus.LastSyncStateTime)) — proceeding to add products"
                $sync1Done = $true
            }
            elseif ($syncStatus.LastSyncState -in @(6701, 6704, 6705, 6706)) {
                # Sync appears to be running — but check if the state is stale.
                $syncAge = (Get-Date) - $syncStatus.LastSyncStateTime
                if ($syncAge.TotalMinutes -gt 15) {
                    Write-DscStatus "$Tag Sync 1 state $($syncStatus.LastSyncState) is stale ($([math]::Round($syncAge.TotalMinutes,0)) min old) — treating as failed. Repairing WSUS..."
                    Repair-WsusSync
                }
                else {
                    Write-DscStatus "$Tag Sync 1 is in progress (state $($syncStatus.LastSyncState), age $([math]::Round($syncAge.TotalMinutes,1)) min) — waiting for completion..."
                }
                $sync1Done = Wait-WsusSyncCompletion -Label "Sync 1"
            }
            else {
                # No sync has run or last sync failed — trigger one and wait
                Write-DscStatus "$Tag No completed sync found (state=$($syncStatus.LastSyncState)). Triggering sync 1..."
                $sync1Done = Wait-WsusSyncCompletion -Label "Sync 1" -TriggerFirst
            }
        }
        if (-not $sync1Done) {
            Write-DscStatus "$Tag WARNING: Sync 1 did not complete after 40 attempts. Adding products anyway — sync 2 may fail if catalog is incomplete."
        }

        # Re-resolve against the now-synced catalog. Products that weren't in the
        # catalog at the early check kept their curated name; sync 1 has since
        # populated the taxonomy, so map them to the real category title now —
        # otherwise the AddProduct loop below would feed CM a name that isn't in
        # SMS_UpdateCategoryInstance and it would be silently dropped.
        $freshCatalog = @(Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Select-Object -ExpandProperty LocalizedCategoryInstanceName)
        $resolvedForAdd = @()
        foreach ($p in $products) {
            $actual = Resolve-CMProductName -Desired $p -Catalog $freshCatalog
            if ($actual) {
                if ($actual -ine $p) { Write-DscStatus "$Tag Product '$p' resolved to catalog title '$actual' (post-sync)" }
                $resolvedForAdd += $actual
            }
            else {
                Write-DscStatus "$Tag WARNING: product '$p' is still not in the catalog after sync — it will be reported rejected below"
                $resolvedForAdd += $p
            }
        }
        $products = @($resolvedForAdd | Select-Object -Unique)

        Write-DscStatus "$Tag Enabling missing products: $($products -join ', ')"
        $supComp = Get-CMSoftwareUpdatePointComponent -SiteCode $SiteCode
        $schedule = New-CMSchedule -RecurCount 1 -RecurInterval Days -Start "2024/1/7 12:00:00"

        # Get the language setting
        $lang = $deployConfig.vmOptions.locale

        # Define language mappings
        switch ($lang) {
            "en-us" { $addLang = "English" }
            "ja-jp" { $addLang = "Japanese" }
            "es-es" { $addLang = "Spanish" }
            "de-de" { $addLang = "German" }
            "fr-fr" { $addLang = "French" }
            default { $addLang = "English" }
        }

        Write-DscStatus "$Tag the locale language is $addLang"

        $parameters = @{
            InputObject                   = $supComp
            SynchronizeAction             = 'SynchronizeFromMicrosoftUpdate'
            AddUpdateClassification       = "Critical Updates", "Security Updates", "Updates"
            Schedule                      = $schedule
            EnableSyncFailureAlert        = $true
            ImmediatelyExpireSupersedence = $false
            AddLanguageUpdateFile         = $addLang
            AddLanguageSummaryDetails     = $addLang
            EnableCallWsusCleanupWizard   = $true
            WaitMonth                     = 3
            EnableThirdPartyUpdates       = $true
            EnableManualCertManagement    = $false
        }

        # Apply base config first (no products yet) so any error in the
        # base parameters is isolated from the per-product additions
        # below. Set-CMSoftwareUpdatePointComponent leaves existing
        # subscribed products untouched when -AddProduct is omitted.
        Set-CMSoftwareUpdatePointComponent @parameters

        #there is an additional windows 10 component under Developer tools which gets enabled by above method, so we are removing the product family to avoid it explicitly
        Set-CMSoftwareUpdatePointComponent -RemoveProductFamily "Developer Tools, Runtimes, and Redistributables"

        # Add products one at a time so a single malformed / catalog-missing
        # name surfaces on its own log line instead of disappearing into a
        # bulk silent-drop. Set-CMSoftwareUpdatePointComponent silently
        # drops any -AddProduct name that doesn't exist in
        # SMS_UpdateCategoryInstance (CM's mirror of WSUS dbo.UpdateCategories)
        # — no error, no warning, just nothing happens. Per-product gives
        # us "Added '<name>'" / "WARNING: '<name>' rejected (not in catalog)"
        # so a typo or canonical-case mismatch (e.g. '24H2' vs the actual
        # 'Microsoft Server Operating System – 24H2') is named explicitly.
        $accepted = @()
        $rejected = @()
        foreach ($product in $products) {
            $beforeSubscribed = @(Get-CMSoftwareUpdateCategory -Fast -TypeName "product" |
                Where-Object { $_.IsSubscribed } |
                Select-Object -ExpandProperty LocalizedCategoryInstanceName)
            try {
                Set-CMSoftwareUpdatePointComponent -InputObject $supComp -AddProduct $product -ErrorAction Stop | Out-Null
            }
            catch {
                $rejected += $product
                Write-DscStatus "$Tag WARNING: Add product '$product' threw: $($_.Exception.Message)"
                continue
            }
            $afterSubscribed = @(Get-CMSoftwareUpdateCategory -Fast -TypeName "product" |
                Where-Object { $_.IsSubscribed } |
                Select-Object -ExpandProperty LocalizedCategoryInstanceName)
            if ($product -in $afterSubscribed) {
                $accepted += $product
                if ($product -in $beforeSubscribed) {
                    Write-DscStatus "$Tag Product '$product' already subscribed (no-op)"
                }
                else {
                    Write-DscStatus "$Tag Added product '$product'"
                }
            }
            else {
                $rejected += $product
                Write-DscStatus "$Tag WARNING: Product '$product' was silently rejected by SUP component (not in WSUS catalog — check exact name match against dbo.UpdateCategories)"
            }
        }
        if ($accepted.Count -eq 0) {
            Write-DscStatus "$Tag WARNING: 0 of $($products.Count) requested products were accepted by Set-CMSoftwareUpdatePointComponent -- the WSUS catalog has none of these names. This means Sync 1 didn't actually populate the catalog (cab import failed/skipped AND the MU categories sync didn't complete). Skipping WCM wait -- there is nothing to push. SUP will be subscribed to the 3 default classifications only ($($parameters.AddUpdateClassification -join ', ')); Phase 11 will WARN on subscription parity until the catalog is repaired. Rejected: $($rejected -join ', ')"
            return
        }
        if ($rejected.Count -gt 0) {
            Write-DscStatus "$Tag WARNING: $($accepted.Count) of $($products.Count) requested products accepted; $($rejected.Count) rejected (not in WSUS catalog): $($rejected -join ', '). Continuing with the $($accepted.Count) that did bind."
        }
        else {
            Write-DscStatus "$Tag All $($accepted.Count) requested products accepted by SUP component"
        }
        Write-DscStatus "$Tag Products enabled. Waiting for WCM to reconfigure WSUS with new products..."

        # Adding products triggers WCM reconfiguration (SUBSCRIPTION_PENDING).
        # We must wait for WCM to reach SUCCESS before triggering a sync,
        # otherwise wsyncmgr sees 'WSUS server not configured' and the sync
        # blocks WCM from setting the subscription (deadlock).
        $wcmRegPath = 'HKLM:\SOFTWARE\Microsoft\SMS\COMPONENTS\SMS_WSUS_CONFIGURATION_MANAGER'
        $wcmStateNames = @{ 0='NONE'; 1='PENDING'; 2='SUCCESS'; 3='FAILED'; 4='SUBSCRIPTION_PENDING' }
        $wcmReady = $false
        for ($wcmWait = 1; $wcmWait -le 20; $wcmWait++) {
            Start-Sleep -Seconds 30
            try {
                $wcmRegVal = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
            } catch { $wcmRegVal = -1 }
            $wcmName = if ($wcmStateNames.ContainsKey($wcmRegVal)) { $wcmStateNames[$wcmRegVal] } else { "UNKNOWN($wcmRegVal)" }
            if ($wcmRegVal -eq 2) {
                Write-DscStatus "$Tag WCM reached SUCCESS after product update (attempt $wcmWait)"
                $wcmReady = $true
                break
            }
            if ($wcmRegVal -eq 3 -and ($wcmWait % 5 -eq 0)) {
                Write-DscStatus "$Tag WCM state is FAILED. Restarting WsusService to trigger reconfiguration (attempt $wcmWait of 20)"
                Restart-Service -Name WsusService -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 30
            }
            else {
                Write-DscStatus "$Tag WCM state: $wcmName (attempt $wcmWait of 20)"
            }
        }
        if ($wcmReady) {
            # Verify products are actually subscribed before triggering sync
            $postProducts = Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Where-Object { $_.IsSubscribed } | Select-Object -ExpandProperty LocalizedCategoryInstanceName
            $stillMissing = @($products | Where-Object { $_ -notin $postProducts })
            if ($stillMissing.Count -gt 0) {
                Write-DscStatus "$Tag WARNING: Products still not subscribed after WCM SUCCESS ($($stillMissing.Count)): $($stillMissing -join ', ')"
                Write-DscStatus "$Tag Subscribed products ($($postProducts.Count)): $($postProducts -join ', ')"
            }
            else {
                Write-DscStatus "$Tag All $($products.Count) products confirmed subscribed"
            }

            Write-DscStatus "$Tag Requesting sync with new products..."
            Invoke-FullSync

            # Verify the sync is running or completed — if not, log diagnostics
            Start-Sleep -Seconds 15
            $postSync = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $SiteCode } | Select-Object -First 1
            $syncRunning = $postSync.LastSyncState -in @(6701, 6704, 6705, 6706)
            $syncDone = $postSync.LastSyncState -eq 6702
            if ($syncRunning) {
                Write-DscStatus "$Tag Sync is running (state $($postSync.LastSyncState)) — continuing, it will finish in background"
            }
            elseif ($syncDone -and $postSync.LastSyncStateTime -and ((Get-Date) - $postSync.LastSyncStateTime).TotalMinutes -lt 5) {
                Write-DscStatus "$Tag Sync already completed (finished $([math]::Round(((Get-Date) - $postSync.LastSyncStateTime).TotalMinutes, 1)) min ago)"
            }
            else {
                # Sync didn't start — log diagnostics
                $diag = @()
                $diag += "SyncState=$($postSync.LastSyncState) ErrorCode=$($postSync.LastSyncErrorCode) LastTime=$($postSync.LastSyncStateTime)"
                $wsusSvc = Get-Service -Name WsusService -ErrorAction SilentlyContinue
                $w3svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
                $diag += "WsusService=$($wsusSvc.Status) W3SVC=$($w3svc.Status)"
                try {
                    $wcmRegVal2 = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
                    $diag += "WCM=$($wcmStateNames[$wcmRegVal2])"
                } catch { $diag += "WCM=unreadable" }
                $synFile = Join-Path $CMInstallDir 'inboxes\wsyncmgr.box\full.syn'
                $diag += "full.syn=$(if (Test-Path $synFile) { 'present (not yet picked up)' } else { 'gone (picked up or never created)' })"
                Write-DscStatus "$Tag WARNING: Sync did not start after full.syn drop. Diag: $($diag -join ' | ')"
                Write-DscStatus "$Tag Dropping full.syn again as remediation..."
                Invoke-FullSync
            }
        }
        else {
            Write-DscStatus "$Tag WCM did not reach SUCCESS after 20 attempts. Skipping sync trigger — wsyncmgr will sync on schedule."
            # Log diagnostics so we can investigate
            $diag = @()
            try {
                $wcmRegVal2 = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
                $diag += "WCM=$($wcmStateNames[$wcmRegVal2])"
            } catch { $diag += "WCM=unreadable" }
            $wsusSvc = Get-Service -Name WsusService -ErrorAction SilentlyContinue
            $diag += "WsusService=$($wsusSvc.Status)"
            $wcmLog = Join-Path $CMInstallDir "Logs\WCM.log"
            if (Test-Path $wcmLog) {
                $wcmTail = @(Get-Content $wcmLog -Tail 3 -ErrorAction SilentlyContinue)
                foreach ($line in $wcmTail) {
                    if ($line -match 'LOG\[(.+?)\]LOG') { $diag += "WCM.log: $($Matches[1].Substring(0, [Math]::Min(120, $Matches[1].Length)))" }
                }
            }
            Write-DscStatus "$Tag WCM timeout diag: $($diag -join ' | ')"
        }
    }
    if ($Sups) {
        # Define ADR Names
        $ADRNames = @{
            "Client"   = "MEMLABS-ADR-Windows-10/11"
            "Server"   = "MEMLABS-ADR-Windows-Servers"
            "Defender" = "MEMLABS-ADR-Windows-defender"
            "office"   = "MEMLABS-ADR-O365patching"
        }

        # Define the folder path and share name — Primary only (local shares)
        if ($CurrentRole -ne "CAS") {
        $folderPath1 = "$DriveLetter\updatePkgs"
        $shareName1 = "updatePkgs"

        Write-DscStatus "$Tag sharing the updatePkgs folder as - $folderPath1"

        # Create the folder if it doesn't exist
        if (-not (Test-Path -Path $folderPath1)) {
            New-Item -ItemType Directory -Path $folderPath1
            New-Item -ItemType Directory -Path (Join-Path $folderPath1 "windows10-11")
            New-Item -ItemType Directory -Path (Join-Path $folderPath1 "Windowsserver")
            New-Item -ItemType Directory -Path (Join-Path $folderPath1 "Windows_defender")
            New-Item -ItemType Directory -Path (Join-Path $folderPath1 "O365") 
            Write-DscStatus "$Tag updatePkgs folder does not exist and creating one"
        }

        # Create the share with read access for "Everyone"
        if (-not (Get-SmbShare -Name $shareName1 -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $shareName1 -Path $folderPath1 -FullAccess @("Administrators", "Everyone")
        }

        Write-DscStatus "$Tag $shareName1 share successfully shared with Administrators"

        # Define Deployment Packages
        $Packages = @(
            @{ Name = "MEMLABS-W10-11-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windows10-11"; Description = "Windows 10 and 11 Security Updates" },
            @{ Name = "MEMLABS-Win-Server-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windowsserver"; Description = "Windows Server Security Updates" },
            @{ Name = "MEMLABS-Defender-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windows_defender"; Description = "Windows Defender Updates" },
            @{ Name = "MEMLABS-ADR-O365patching-pkg"; Path = "\\$ThisMachineName\updatePkgs\O365"; Description = "O365 Updates" }
        )
    
        # Function to Create Software Update Deployment Package
        function New-SCCMUpdatePackage {
            param (
                [string]$PackageName,
                [string]$PackagePath,
                [string]$PackageDescription
            )
    
            if (!(Get-CMSoftwareUpdateDeploymentPackage -Name $PackageName)) {
                Write-DscStatus "$Tag Creating package: $PackageName"
                try {
                    New-CMSoftwareUpdateDeploymentPackage -Name $PackageName -Path $PackagePath -Description $PackageDescription
                    Write-DscStatus "$Tag Successfully created package: $PackageName"
                    Start-CMContentDistribution -DeploymentPackageName $PackageName -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
                    Write-DscStatus "$Tag Successfully distributed MEMLABS $PackageName to all DPs"
                    New-CMSoftwareUpdateGroup -Name $PackageName -Description $PackageDescription
                    Write-DscStatus "$Tag Successfully created SUG $PackageName"
                
                }
                catch {
                    Write-DscStatus "$Tag Failed to create package: $PackageName. Error: $_"
                }
            }
            else {
                Write-DscStatus "$Tag Package already exists: $PackageName"
            }
        }
    
        # Loop through each package and create it if it doesn't exist
        foreach ($pkg in $Packages) {
            New-SCCMUpdatePackage -PackageName $pkg.Name -PackagePath $pkg.Path -PackageDescription $pkg.Description
        }
    
        # Create the ADR schedules
        $patchTueSchedule = New-CMSchedule -Start (Get-Date) -DayOfWeek Tuesday -WeekOrder Second -RecurCount 1 -OffsetDay 2
        $dailySchedule = New-CMSchedule -DurationInterval Days -DurationCount 0 -RecurInterval Days -RecurCount 1
    
        if (!(Get-CMSoftwareUpdateAutoDeploymentRule -Fast | Select-Object Name)) {
    
            $maxAttempts = 3
            $attempt = 0
            $success = $false
        
            while (-not $success -and $attempt -lt $maxAttempts) {
                try {
                    New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Client `
                        -DateReleasedOrRevised Last7Days -Title "cumulative", "security", "malicious" -Superseded $false `
                        -Product "windows 11", "Windows 10, version 1903 and later" -Architecture X64 `
                        -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                        -DeploymentPackageName $Packages[0].Name -Description "MEMLABS autocreated ADR for win 10/11 patching" `
                        -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
                    Write-DscStatus "$Tag ADR created successfully for Windows 10 and 11 Security Updates"
                    $success = $true
                }
                catch {
                    Write-DscStatus "$Tag An error occurred while creating the ADR for Windows 10 and 11 Security Updates: $_"
                    $attempt++
                    Write-DscStatus "$Tag Retrying ADR creation, attempt $attempt of $maxAttempts"
                    Start-Sleep -Seconds 30
                }
            }
        
            if (-not $success) {
                Write-DscStatus "$Tag ADR creation failed after $maxAttempts attempts."
            }
        
            try {
                New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Server `
                    -DateReleasedOrRevised Last7Days -Title "cumulative", "security", "malicious" -Superseded $false -Product "Windows Server 2016", "Windows Server 2019", "Microsoft Server operating system-21H2", "Microsoft Server Operating System-24H2" -Architecture X64 `
                    -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                    -DeploymentPackageName $Packages[1].Name -Description "MEMLABS autocreated ADR for win server patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
    
                Write-DscStatus "$Tag ADR created successfully for Windows server Updates"
            }
            catch {
                Write-DscStatus "$Tag An error occurred while creating the ADR for win server patching"
            }
            try {
                New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Defender `
                    -DateReleasedOrRevised Last7Days -UpdateClassification "Definition updates" -Superseded $false -Product $products -Architecture X64 `
                    -Schedule $dailySchedule -RunType RunTheRuleOnSchedule `
                    -DeploymentPackageName $Packages[2].Name -Description "MEMLABS autocreated ADR for definition updates patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
                Write-DscStatus "$Tag ADR created successfully for Defender Security Updates"
            }
            catch {
                Write-DscStatus "$Tag An error occurred while creating the ADR for Defender Security Updates"
            }

            try {
                New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.office `
                    -DateReleasedOrRevised Last7Days -Titles "-preview", "Microsoft 365 Apps Update" -Superseded $false -Product "Microsoft 365 Apps/Office 2019/Office LTSC" `
                    -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                    -DeploymentPackageName $Packages[3].Name -Description "MEMLABS autocreated ADR for O365 updates patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
                Write-DscStatus "$Tag ADR created successfully for O365 Updates"
            }
            catch {
                Write-DscStatus "$Tag An error occurred while creating the ADR for O365 Updates"
            }
            ##this sync will take a long time as it will almost pull 3k-5k updates down so don't wait for the process to finish
            # Only FORCE a full sync on a TOP-LEVEL SUP (standalone Primary / CAS)
            # that syncs from Microsoft Update directly. On a DOWNSTREAM child
            # Primary the SUP is a replica that pulls its catalog from the upstream
            # CAS, so forcing a sync here -- while the CAS is typically still doing
            # its multi-thousand-item initial MU sync -- just produces a
            # superseded/Canceled cycle (surfaced later as the Phase 11 'WSUS last
            # sync Result=Canceled' warning). The downstream catalog replicates
            # automatically on WCM's schedule once the upstream completes, so on a
            # child Primary we skip the forced trigger.
            if ($isTopLevel) {
                Invoke-FullSync
            }
            else {
                Write-DscStatus "$Tag Downstream SUP (parent=$($ThisVM.parentSiteCode)) - skipping forced full WSUS sync; catalog replicates from the upstream SUP once its sync completes"
            }
        }

        } # end Primary-only update packages/ADR block
    }

    $collection = Get-CMCollection -Name "All Unknown Computers"
    if ($Collection -and $Collection.CollectionID) {
        try { Invoke-CMCollectionUpdate -CollectionId $collection.CollectionID } catch {}
    }    

    $perfloadingTimer.Stop()
    Write-DscStatus "$Tag Completed the perf loading the environment in $($perfloadingTimer.Elapsed.ToString('hh\:mm\:ss'))"
    Write-DscStatus "$Tag ******************************************" -NoStatus
    Write-DscStatus "$Tag ******************************************" -NoStatus