#InstallDPMPClient.ps1
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

# Target the client package as soon as a DP role is registered. In a hierarchy,
# the package is owned by the CAS and cannot start replicating down until this
# durable SMS_DistributionPoint row exists. Waiting until InstallBoundaryGroups
# runs serializes that parent hop behind MP installation and MP-replica setup.
$getSiteSqlDataSource = {
    param($SiteVm)

    return Get-VmSqlConnectionTarget -SiteVm $SiteVm -DeployConfig $deployConfig -DomainFullName $DomainFullName
}

$flushClientPackageTargetingToParent = {
    param([string]$PackageId)

    # PkgServers_G belongs to the global "Configuration Data" replication group.
    # Ask the same stored procedure used by the native DRS message builder to send
    # that group now; otherwise this targeting row can sit at the Primary for ~32m.
    if (-not $ThisVM -or $ThisVM.role -ne 'Primary' -or (-not $ThisVM.parentSiteCode -and -not $ThisVM.thisParams.ParentSiteServer)) { return $true }
    $connection = $null
    $succeeded = $false
    try {
        $dataSource = & $getSiteSqlDataSource $ThisVM
        $database = "CM_$SiteCode"
        $connectionString = "Data Source=$dataSource;Initial Catalog=$database;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'EXEC dbo.spDRSSendChangesForGroup @ReplicationGroup = @rg'
        $command.CommandTimeout = 120
        [void]$command.Parameters.AddWithValue('@rg', 'Configuration Data')
        [void]$command.ExecuteNonQuery()
        $succeeded = $true
        Write-DscStatus "Client package pre-stage: requested immediate DRS Configuration Data send for $PackageId after DP targeting (SQL=$dataSource/$database)."
    }
    catch {
        Write-DscStatus "Client package pre-stage: immediate DRS Configuration Data send for $PackageId failed: $($_.Exception.Message). Normal DRS processing and the later coverage gate remain in place." -Warning
    }
    finally {
        if ($connection) { $connection.Dispose() }
    }
    return $succeeded
}

$readPkgServerTargetRow = {
    param($SqlConnection, [ValidateSet('PkgServers', 'PkgServers_G')][string]$Table, [string]$PackageId, [string]$Needle)

    $row = [pscustomobject]@{
        Found = $false; Rows = 0; NALPath = $null; LastRefresh = $null
        RefreshTrigger = $null; UpdateMask = $null; Action = $null
    }
    $command = $SqlConnection.CreateCommand()
    if ($Table -eq 'PkgServers_G') {
        $command.CommandText = 'SELECT NALPath, LastRefresh, RefreshTrigger, UpdateMask, Action FROM dbo.PkgServers_G WHERE PkgID = @pkg AND SiteCode = @site'
    }
    else {
        $command.CommandText = 'SELECT NALPath, LastRefresh, RefreshTrigger, UpdateMask, Action FROM dbo.PkgServers WHERE PkgID = @pkg AND SiteCode = @site'
    }
    $command.CommandTimeout = 30
    [void]$command.Parameters.AddWithValue('@pkg', $PackageId)
    [void]$command.Parameters.AddWithValue('@site', $SiteCode)
    $reader = $command.ExecuteReader()
    try {
        while ($reader.Read()) {
            $row.Rows++
            $nalPath = "$($reader['NALPath'])"
            if ($nalPath.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $row.Found = $true
            $row.NALPath = $nalPath
            if ($reader['LastRefresh'] -isnot [System.DBNull]) { $row.LastRefresh = [datetime]$reader['LastRefresh'] }
            if ($reader['RefreshTrigger'] -isnot [System.DBNull]) { $row.RefreshTrigger = [int]$reader['RefreshTrigger'] }
            if ($reader['UpdateMask'] -isnot [System.DBNull]) { $row.UpdateMask = [int]$reader['UpdateMask'] }
            if ($reader['Action'] -isnot [System.DBNull]) { $row.Action = [int]$reader['Action'] }
        }
    }
    finally { $reader.Close() }
    return $row
}

$verifyClientPackageTargetAtParent = {
    param([string]$PackageId, [string]$DistributionPointFqdn, [int]$TimeoutSeconds = 120)

    $result = [pscustomobject]@{
        Verified = $false; Error = $null; DataSource = $null; Database = $null; Rows = 0
        ParentRowPresent = $false; ParentQueried = $false; Mismatch = $null
        NALPath = $null; LastRefresh = $null; RefreshTrigger = $null; UpdateMask = $null; Action = $null
        GlobalNALPath = $null; GlobalLastRefresh = $null; GlobalRefreshTrigger = $null; GlobalUpdateMask = $null; GlobalAction = $null
        LocalLastRefresh = $null; LocalRefreshTrigger = $null; LocalUpdateMask = $null; LocalAction = $null
        NotificationCount = $null; NotificationTime = $null
    }
    if (-not $ThisVM -or $ThisVM.role -ne 'Primary' -or -not $ThisVM.parentSiteCode) {
        $result.Verified = $true
        return $result
    }

    $parentSiteCode = "$($ThisVM.parentSiteCode)"
    $parentVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'CAS' -and $_.siteCode -eq $parentSiteCode } | Select-Object -First 1
    if (-not $parentVm) {
        $result.Error = "parent CAS VM for site $parentSiteCode was not found in deployConfig"
        return $result
    }

    $connection = $null
    $localConnection = $null
    try {
        $result.DataSource = & $getSiteSqlDataSource $parentVm
        $result.Database = "CM_$parentSiteCode"
        $connectionString = "Data Source=$($result.DataSource);Initial Catalog=$($result.Database);Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
        $localDataSource = & $getSiteSqlDataSource $ThisVM
        $localConnectionString = "Data Source=$localDataSource;Initial Catalog=CM_$SiteCode;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"

        $pollSeconds = 10
        # Wall-clock, not a poll count: a refused connect burns its own 15s Connect Timeout,
        # so a fixed number of polls silently overruns the budget the caller was promised.
        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
        $needle = "\\$DistributionPointFqdn\"
        $poll = 0
        while ($true) {
            $poll++
            # Connect INSIDE the loop. A CAS whose SQL is restarting mid-Phase-8 is a
            # transient this budget exists to absorb; opening once outside meant a single
            # refused connect spent the caller's entire attempt without one row being read.
            try {
                if (-not $connection -or $connection.State -ne [System.Data.ConnectionState]::Open) {
                    if ($connection) { $connection.Dispose() }
                    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
                    $connection.Open()
                }
                if (-not $localConnection -or $localConnection.State -ne [System.Data.ConnectionState]::Open) {
                    if ($localConnection) { $localConnection.Dispose() }
                    $localConnection = New-Object System.Data.SqlClient.SqlConnection $localConnectionString
                    $localConnection.Open()
                }
            }
            catch {
                $result.Error = $_.Exception.Message
                $result.Mismatch = "could not reach $($result.DataSource)/$($result.Database) to look (poll $poll)"
                if ((Get-Date).AddSeconds($pollSeconds) -ge $deadline) { break }
                Start-Sleep -Seconds $pollSeconds
                continue
            }
            # Connected: drop the previous poll's connect error so it cannot be reported as a finding.
            $result.Error = $null

            # Compare the parent's PkgServers_G row against OUR OWN PkgServers_G row: that
            # table IS the replicated payload, so equality means the change reached the CAS.
            # Do NOT test LastRefresh against wall-clock. distsrc.cpp writes LastRefresh only
            # when DistMgr PROCESSES the target -- in the same statement that sets
            # RefreshTrigger = 0 -- and DRS copies the column verbatim
            # (tr_PkgServers_G_ins/_upd). While RefreshTrigger is still 1 the row carries
            # whatever LastRefresh it was created with, which on a fresh row is an
            # uninitialised 1970 date. A "LastRefresh >= now" gate can therefore never pass.
            $localRow = & $readPkgServerTargetRow $localConnection 'PkgServers_G' $PackageId $needle
            $parentRow = & $readPkgServerTargetRow $connection 'PkgServers_G' $PackageId $needle
            $result.ParentQueried = $true

            $result.Rows = $parentRow.Rows
            $result.ParentRowPresent = $parentRow.Found
            $result.LocalLastRefresh = $localRow.LastRefresh
            $result.LocalRefreshTrigger = $localRow.RefreshTrigger
            $result.LocalUpdateMask = $localRow.UpdateMask
            $result.LocalAction = $localRow.Action
            if ($parentRow.Found) {
                $result.GlobalNALPath = $parentRow.NALPath
                $result.GlobalLastRefresh = $parentRow.LastRefresh
                $result.GlobalRefreshTrigger = $parentRow.RefreshTrigger
                $result.GlobalUpdateMask = $parentRow.UpdateMask
                $result.GlobalAction = $parentRow.Action
            }

            if (-not $localRow.Found) {
                $result.Mismatch = "the local $SiteCode PkgServers_G row for $DistributionPointFqdn is gone"
            }
            elseif (-not $parentRow.Found) {
                $result.Mismatch = "parent has no PkgServers_G row for $DistributionPointFqdn (site rows=$($parentRow.Rows))"
            }
            else {
                $diffs = @()
                foreach ($field in 'LastRefresh', 'RefreshTrigger', 'UpdateMask', 'Action') {
                    if ("$($parentRow.$field)" -ne "$($localRow.$field)") { $diffs += "$field local='$($localRow.$field)' parent='$($parentRow.$field)'" }
                }
                if ($diffs.Count -eq 0) {
                    $result.Verified = $true
                    $result.Mismatch = $null
                }
                else {
                    $result.Mismatch = "parent copy is behind: $($diffs -join '; ')"
                }
            }

            if ($result.Verified) { break }
            if ((Get-Date).AddSeconds($pollSeconds) -ge $deadline) { break }
            Start-Sleep -Seconds $pollSeconds
        }

        if ($result.ParentQueried) {
            # PkgServers is the local operational projection (_L); DistMgr clears Action and
            # advances LastRefresh there once it processes the target. Diagnostic only.
            $effectiveRow = & $readPkgServerTargetRow $connection 'PkgServers' $PackageId $needle
            if ($effectiveRow.Found) {
                $result.NALPath = $effectiveRow.NALPath
                $result.LastRefresh = $effectiveRow.LastRefresh
                $result.RefreshTrigger = $effectiveRow.RefreshTrigger
                $result.UpdateMask = $effectiveRow.UpdateMask
                $result.Action = $effectiveRow.Action
            }

            $notificationCommand = $connection.CreateCommand()
            $notificationCommand.CommandText = 'SELECT COUNT(*) AS NotificationCount, MAX(TimeKey) AS NotificationTime FROM dbo.PkgNotification WHERE PkgID = @pkg AND Type = 4'
            $notificationCommand.CommandTimeout = 30
            [void]$notificationCommand.Parameters.AddWithValue('@pkg', $PackageId)
            $notificationReader = $notificationCommand.ExecuteReader()
            try {
                if ($notificationReader.Read()) {
                    $result.NotificationCount = [int]$notificationReader['NotificationCount']
                    if ($notificationReader['NotificationTime'] -isnot [System.DBNull]) { $result.NotificationTime = [datetime]$notificationReader['NotificationTime'] }
                }
            }
            finally { $notificationReader.Close() }
        }
    }
    catch { $result.Error = $_.Exception.Message }
    finally {
        if ($connection) { $connection.Dispose() }
        if ($localConnection) { $localConnection.Dispose() }
    }
    return $result
}

$writeClientPackageTargetingDiagnostics = {
    param([string]$PackageId, [string]$DistributionPointFqdn, $ParentVerification)

    if ($ParentVerification -and -not $ParentVerification.ParentQueried) {
        # rows=0 / present=False are the INITIAL values here, not findings. Printing them
        # when the query never ran states a measurement that was never taken.
        Write-DscStatus "Client package pre-stage diag [parent]: NOT QUERIED -- $($ParentVerification.DataSource)/$($ParentVerification.Database) was never read, so whether it has the $PackageId row is unknown. error='$($ParentVerification.Error)'" -NoStatus
        $probeTarget = "$($ParentVerification.DataSource)"
        $probeHost = $probeTarget
        $probePort = 1433
        if ($probeTarget -match '^(.+?),(\d+)$') { $probeHost = $Matches[1]; $probePort = [int]$Matches[2] }
        elseif ($probeTarget -match '^(.+?)\\') { $probeHost = $Matches[1] }
        $resolved = ''
        try { $resolved = (@([System.Net.Dns]::GetHostAddresses($probeHost) | ForEach-Object { $_.IPAddressToString }) -join ',') } catch { $resolved = "DNS FAILED: $($_.Exception.Message)" }
        $tcp = 'not attempted'
        if ($resolved -and $resolved -notlike 'DNS FAILED*') {
            $client = $null
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $tcp = if ($client.ConnectAsync($probeHost, $probePort).Wait(5000) -and $client.Connected) { "open" } else { "no answer within 5s" }
            }
            catch { $tcp = "refused: $($_.Exception.Message)" }
            finally { if ($client) { $client.Dispose() } }
        }
        Write-DscStatus "Client package pre-stage diag [parent reachability]: host='$probeHost' port=$probePort dns='$resolved' tcp=$tcp" -NoStatus
    }
    elseif ($ParentVerification) {
        Write-DscStatus "Client package pre-stage diag [parent effective]: SQL=$($ParentVerification.DataSource)/$($ParentVerification.Database); rows=$($ParentVerification.Rows); NALPath='$($ParentVerification.NALPath)'; LastRefresh=$($ParentVerification.LastRefresh); RefreshTrigger=$($ParentVerification.RefreshTrigger); UpdateMask=$($ParentVerification.UpdateMask); Action=$($ParentVerification.Action); PkgNotification(type4)=$($ParentVerification.NotificationCount) latest=$($ParentVerification.NotificationTime); error='$($ParentVerification.Error)'" -NoStatus
        Write-DscStatus "Client package pre-stage diag [parent global]: present=$($ParentVerification.ParentRowPresent); NALPath='$($ParentVerification.GlobalNALPath)'; LastRefresh=$($ParentVerification.GlobalLastRefresh); RefreshTrigger=$($ParentVerification.GlobalRefreshTrigger); UpdateMask=$($ParentVerification.GlobalUpdateMask); Action=$($ParentVerification.GlobalAction)" -NoStatus
        Write-DscStatus "Client package pre-stage diag [local global]: LastRefresh=$($ParentVerification.LocalLastRefresh); RefreshTrigger=$($ParentVerification.LocalRefreshTrigger); UpdateMask=$($ParentVerification.LocalUpdateMask); Action=$($ParentVerification.LocalAction); verdict='$($ParentVerification.Mismatch)'" -NoStatus
    }

    $connection = $null
    try {
        $dataSource = & $getSiteSqlDataSource $ThisVM
        $database = "CM_$SiteCode"
        $connectionString = "Data Source=$dataSource;Initial Catalog=$database;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        $connection.Open()

        $targetCommand = $connection.CreateCommand()
        $targetCommand.CommandText = 'SELECT NALPath, LastRefresh, RefreshTrigger, UpdateMask, Action FROM dbo.PkgServers_G WHERE PkgID = @pkg AND SiteCode = @site'
        $targetCommand.CommandTimeout = 30
        [void]$targetCommand.Parameters.AddWithValue('@pkg', $PackageId)
        [void]$targetCommand.Parameters.AddWithValue('@site', $SiteCode)
        $targetReader = $targetCommand.ExecuteReader()
        $localTargetFound = $false
        $needle = "\\$DistributionPointFqdn\"
        try {
            while ($targetReader.Read()) {
                $nalPath = "$($targetReader['NALPath'])"
                if ($nalPath.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                $localTargetFound = $true
                Write-DscStatus "Client package pre-stage diag [local target]: SQL=$dataSource/$database; NALPath='$nalPath'; LastRefresh=$($targetReader['LastRefresh']); RefreshTrigger=$($targetReader['RefreshTrigger']); UpdateMask=$($targetReader['UpdateMask']); Action=$($targetReader['Action'])" -NoStatus
            }
        }
        finally { $targetReader.Close() }
        if (-not $localTargetFound) { Write-DscStatus "Client package pre-stage diag [local target]: no exact $PackageId / $SiteCode / $DistributionPointFqdn row in $dataSource/$database" -NoStatus }

        $drsCommand = $connection.CreateCommand()
        $drsCommand.CommandText = @'
SELECT s.SiteCode, s.LastVersionSent, s.LastSendStartTime, s.LastSendEndTime,
       s.LastSendResult, s.Active, s.LastSyncProcessedTime
FROM dbo.DRS_MessageActivity_Send AS s
INNER JOIN dbo.ReplicationData AS r ON r.ID = s.ReplicationID
WHERE r.ReplicationGroup = @group
'@
        $drsCommand.CommandTimeout = 30
        [void]$drsCommand.Parameters.AddWithValue('@group', 'Configuration Data')
        $drsReader = $drsCommand.ExecuteReader()
        $drsRows = 0
        try {
            while ($drsReader.Read()) {
                $drsRows++
                Write-DscStatus "Client package pre-stage diag [local DRS Configuration Data -> $($drsReader['SiteCode'])]: LastVersionSent=$($drsReader['LastVersionSent']); Start=$($drsReader['LastSendStartTime']); End=$($drsReader['LastSendEndTime']); Result=$($drsReader['LastSendResult']); Active=$($drsReader['Active']); LastProcessed=$($drsReader['LastSyncProcessedTime'])" -NoStatus
            }
        }
        finally { $drsReader.Close() }
        if ($drsRows -eq 0) { Write-DscStatus "Client package pre-stage diag [local DRS]: no Configuration Data send rows in $dataSource/$database" -NoStatus }
    }
    catch { Write-DscStatus "Client package pre-stage diag query failed: $($_.Exception.Message)" -NoStatus }
    finally { if ($connection) { $connection.Dispose() } }
}

$startClientPackagePrestage = {
    param([string]$DistributionPointFqdn)

    try {
        # This block only runs on a child primary, and Get-CMPackage returns one client
        # package per site, so an unfiltered -First 1 can pre-stage the CAS's package.
        $allClientPackages = @(Get-CMPackage -Fast -Name 'Configuration Manager Client Package')
        $localClientPackages = @($allClientPackages | Where-Object { "$($_.PackageID)" -like "$SiteCode*" })
        $clientPackage = if ($localClientPackages.Count -gt 0) { $localClientPackages[0] } elseif ($allClientPackages.Count -gt 0) { $allClientPackages[0] } else { $null }
        if (-not $clientPackage) {
            Write-DscStatus "Client package pre-stage: package not found; the later coverage gate will retry."
            return $true
        }
        $packageId = "$($clientPackage.PackageID)"
        if ($allClientPackages.Count -gt 1) {
            Write-DscStatus "Client package pre-stage: chose $packageId from $($allClientPackages.Count) same-named packages ($(if ($localClientPackages.Count) { "owned by this site $SiteCode" } else { "no $SiteCode-owned copy; using hierarchy-owned" }))"
        }
        $namespace = "root\SMS\site_$SiteCode"
        $packageState = Get-WmiObject -Namespace $namespace -Class SMS_Package -Filter "PackageID='$packageId'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $packageState) {
            Write-DscStatus "Client package pre-stage: could not read SMS_Package state for $packageId; the later coverage gate will retry."
            return $true
        }
        if ([int]$packageState.StoredPkgVersion -ge 1) {
            # Local content could hit a newly registered DP before smsdpprov has
            # finished creating its virtual directories, causing a 30-minute
            # InstallRetrying backoff. The later coverage gate runs after role setup.
            Write-DscStatus "Client package pre-stage: $packageId content is already local; deferring DP targeting until role setup finishes."
            return $true
        }
        if (-not $ThisVM.parentSiteCode) { return $true }
        $targeting = @(Get-WmiObject -Namespace $namespace -Class SMS_DistributionPoint -Filter "PackageID='$packageId'" -ErrorAction SilentlyContinue |
                Where-Object {
                    $targetFqdn = if ("$($_.ServerNALPath)" -match '\\([^\\"\]]+)') { $Matches[1] } else { '' }
                    $targetFqdn -ieq $DistributionPointFqdn
                })
        if ($targeting.Count -gt 0) {
            # A target inserted before DRS initialization can exist locally without
            # an unsent change for the CAS. Re-arm it to create a fresh PkgServers_G
            # update, then flush that group. Without this, the sproc runs successfully
            # but has no actionable delta; CAS wakes, sees no changed DP, and sends
            # nothing until HMAN refreshes the row much later.
            Write-DscStatus "Client package pre-stage: $packageId is already targeted to $DistributionPointFqdn."
        }
        else {
            # A DP's role registers before its content destination exists. Install-DP used to
            # sleep a flat 60s after adding the role, which incidentally covered that gap; it
            # now returns as soon as the role registers (~5s), so this call can arrive first
            # and fail with "No content destination was found" -- observed on CS2-PS1SITE,
            # 4s after "DP Role detected ... after 5.2s". Wait on the real precondition
            # instead, and exit the moment it takes.
            $distDeadline = (Get-Date).AddMinutes(5)
            $distErr = $null
            while ($true) {
                try {
                    Start-CMContentDistribution -PackageId $packageId -DistributionPointName $DistributionPointFqdn -ErrorAction Stop
                    $distErr = $null
                    break
                }
                catch {
                    $distErr = $_
                    if ((Get-Date) -ge $distDeadline) { break }
                    Start-Sleep -Seconds 10
                }
            }
            if ($distErr) {
                # Not "confirmed broken", just not ready -- same call the coverage gate makes
                # on every iteration when a DP has no targeting row, so let it own the retry.
                Write-DscStatus "Client package pre-stage: $DistributionPointFqdn would not accept the $packageId distribution within 5 min ($($distErr.Exception.Message)). Continuing; the client-package coverage gate re-establishes a missing targeting row on every pass and Phase 11 re-checks." -Warning
                return $true
            }
            $targeting = @(Get-WmiObject -Namespace $namespace -Class SMS_DistributionPoint -Filter "PackageID='$packageId'" -ErrorAction SilentlyContinue |
                    Where-Object {
                        $targetFqdn = if ("$($_.ServerNALPath)" -match '\\([^\\"\]]+)') { $Matches[1] } else { '' }
                        $targetFqdn -ieq $DistributionPointFqdn
                    })
            if ($targeting.Count -eq 0) { throw "Start-CMContentDistribution returned but no targeting row exists for $DistributionPointFqdn" }
            Write-DscStatus "Client package pre-stage: targeted $packageId to $DistributionPointFqdn immediately after DP registration so parent replication overlaps remaining role setup."
        }

        foreach ($target in $targeting) {
            $target.RefreshNow = $true
            [void]$target.Put()
        }
        Write-DscStatus "Client package pre-stage: re-armed $packageId on $DistributionPointFqdn to create a fresh parent-visible targeting change."
        $lastVerification = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if ($attempt -gt 1) {
                $retryTargeting = @(Get-WmiObject -Namespace $namespace -Class SMS_DistributionPoint -Filter "PackageID='$packageId'" -ErrorAction SilentlyContinue |
                        Where-Object {
                            $targetFqdn = if ("$($_.ServerNALPath)" -match '\\([^\\"\]]+)') { $Matches[1] } else { '' }
                            $targetFqdn -ieq $DistributionPointFqdn
                        })
                if ($retryTargeting.Count -eq 0) {
                    Start-CMContentDistribution -PackageId $packageId -DistributionPointName $DistributionPointFqdn -ErrorAction Stop
                    $retryTargeting = @(Get-WmiObject -Namespace $namespace -Class SMS_DistributionPoint -Filter "PackageID='$packageId'" -ErrorAction SilentlyContinue |
                            Where-Object {
                                $targetFqdn = if ("$($_.ServerNALPath)" -match '\\([^\\"\]]+)') { $Matches[1] } else { '' }
                                $targetFqdn -ieq $DistributionPointFqdn
                            })
                    if ($retryTargeting.Count -eq 0) { throw "retry distribution returned but no targeting row exists for $DistributionPointFqdn" }
                }
                foreach ($target in $retryTargeting) {
                    $target.RefreshNow = $true
                    [void]$target.Put()
                }
                if ($lastVerification -and -not $lastVerification.ParentQueried) {
                    Write-DscStatus "Client package pre-stage: the parent could not be read on attempt 1, so its view of $packageId targeting for $DistributionPointFqdn is unknown; re-armed and retrying DRS once."
                }
                else {
                    Write-DscStatus "Client package pre-stage: parent still did not see $packageId targeting for $DistributionPointFqdn; re-armed and retrying DRS once."
                }
            }

            $flushResult = @(& $flushClientPackageTargetingToParent $packageId)
            $flushSucceeded = ($flushResult.Count -gt 0 -and [bool]$flushResult[-1])
            $lastVerification = & $verifyClientPackageTargetAtParent $packageId $DistributionPointFqdn 120
            if ($lastVerification -and $lastVerification.Verified) {
                Write-DscStatus "Client package pre-stage: verified parent site $($ThisVM.parentSiteCode) has the $packageId targeting for $DistributionPointFqdn (RefreshTrigger=$($lastVerification.GlobalRefreshTrigger), UpdateMask=$($lastVerification.GlobalUpdateMask), Action=$($lastVerification.GlobalAction), SQL=$($lastVerification.DataSource)/$($lastVerification.Database), attempt $attempt/2)."
                return $true
            }
            if ($attempt -lt 2) {
                $verifyDetail = if ($lastVerification -and $lastVerification.Error) { $lastVerification.Error } else { "$($lastVerification.Mismatch)" }
                Write-DscStatus "Client package pre-stage: DRS attempt $attempt/2 not verified at parent (flushSucceeded=$flushSucceeded; $verifyDetail)." -Warning
            }
        }

        $finalDetail = if ($lastVerification -and $lastVerification.Error) { $lastVerification.Error } else { "$($lastVerification.Mismatch)" }
        & $writeClientPackageTargetingDiagnostics $packageId $DistributionPointFqdn $lastVerification
        if (-not $lastVerification -or -not $lastVerification.ParentQueried) {
            # The parent database was never read, so "has no row" is not something this run
            # is entitled to say. Failing here converts an outage on the VERIFIER into an
            # 83-minute phase failure while replication itself may be perfectly healthy.
            Write-DscStatus "Client package pre-stage: could not read parent site $($ThisVM.parentSiteCode) at $($lastVerification.DataSource)/$($lastVerification.Database) after 2 DRS attempts, so whether it has the $packageId targeting for $DistributionPointFqdn is UNKNOWN -- not confirmed missing ($finalDetail). Continuing; the client package coverage gate and the Phase 11 [ClientPkg] check both re-verify. See the [parent reachability] diag line above." -Warning
            return $true
        }
        if ($lastVerification.ParentRowPresent) {
            # The parent HAS the DP targeting; only the replicated field values are still
            # catching up. That is a lag, not a broken DRS path, and the coverage gate in
            # InstallBoundaryGroups plus the Phase 11 [ClientPkg] check both re-verify it.
            # Failing here cost a 55-minute Phase 8 that had nothing wrong with it.
            Write-DscStatus "Client package pre-stage: parent site $($ThisVM.parentSiteCode) already has the $packageId targeting for $DistributionPointFqdn but its copy is still catching up ($finalDetail). Continuing; the client package coverage gate re-checks this." -Warning
            return $true
        }
        Write-DscStatus "Client package pre-stage: parent site $($ThisVM.parentSiteCode) has NO $packageId targeting row for $DistributionPointFqdn after 2 DRS attempts ($finalDetail). Stopping before the blind client-package wait; re-run Phase 8 after correcting DRS/SQL access." -Failure
        return $false
    }
    catch {
        if ($packageId) { & $writeClientPackageTargetingDiagnostics $packageId $DistributionPointFqdn $lastVerification }
        Write-DscStatus "Client package pre-stage on $DistributionPointFqdn failed: $($_.Exception.Message). Stopping before the blind client-package wait; re-run Phase 8 after correcting the targeting path." -Failure
        return $false
    }
}


$DPs = @()
$MPs = @()
$PullDPs = @()
$BareSiteSystems = @()
$ValidSiteCodes = @($SiteCode)
$ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
$ValidSiteCodes += $ReportingSiteCodes

foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -eq "SiteSystem" } ) {
    if ($vm.siteCode -in $ValidSiteCodes) {
        $hasAnyRole = $vm.installDP -or $vm.installMP -or $vm.installSUP -or $vm.installRP -or $vm.installSMSProv
        if ($vm.installDP) {
            if ($vm.enablePullDP) {
                $PullDPs += [PSCustomObject]@{
                    ServerName     = $vm.vmName
                    ServerSiteCode = $vm.siteCode
                    SourceDP       = $vm.pullDPSourceDP
                }
            }
            else {
                $DPs += [PSCustomObject]@{
                    ServerName     = $vm.vmName
                    ServerSiteCode = $vm.siteCode
                }
            }
        }
        if ($vm.installMP) {
            if ($vm.siteCode -notin $ReportingSiteCodes) {
                $MPs += [PSCustomObject]@{
                    ServerName     = $vm.vmName
                    ServerSiteCode = $vm.siteCode
                }
            }
            else {
                Write-DscStatus "Skip MP role for $($vm.vmName) since it's a remote site system in Secondary site"
            }
        }
        # Register VMs with no automated roles so they appear in the console
        # and roles (e.g. Reporting Services Point) can be added manually.
        if (-not $hasAnyRole) {
            $BareSiteSystems += [PSCustomObject]@{
                ServerName     = $vm.vmName
                ServerSiteCode = $vm.siteCode
            }
        }
    }
}

# The site server (this Primary) can host its OWN DP/MP in ADDITION to any
# dedicated SiteSystem DPs, when installDP / installMP are set on the Primary role.
# Previously the site server only became a DP via the "no DP in this site" fallback
# at the very bottom; an explicit installDP makes it a real, declared DP (which also
# lets it serve as a valid Pull DP source). ThisVM is the box running this script.
if ($ThisVM -and $ThisVM.role -eq "Primary") {
    if ($ThisVM.installDP -and -not ($DPs.ServerName -contains $ThisVM.vmName) -and -not ($PullDPs.ServerName -contains $ThisVM.vmName)) {
        Write-DscStatus "Primary site server '$($ThisVM.vmName)' has installDP -- adding its own DP in site $SiteCode"
        $DPs += [PSCustomObject]@{
            ServerName     = $ThisVM.vmName
            ServerSiteCode = $SiteCode
        }
    }
    if ($ThisVM.installMP -and -not ($MPs.ServerName -contains $ThisVM.vmName)) {
        Write-DscStatus "Primary site server '$($ThisVM.vmName)' has installMP -- adding its own MP in site $SiteCode"
        $MPs += [PSCustomObject]@{
            ServerName     = $ThisVM.vmName
            ServerSiteCode = $SiteCode
        }
    }
}

# Trim nulls/blanks
$DPNames = $DPs.ServerName | Where-Object { $_ -and $_.Trim() }
$PullDPNames = $PullDPs.ServerName | Where-Object { $_ -and $_.Trim() }
$MPNames = $MPs.ServerName | Where-Object { $_ -and $_.Trim() }

# Quick check: verify all expected DPs and MPs are already installed
$allInstalled = $true
foreach ($DP in $DPs) {
    if ([string]::IsNullOrWhiteSpace($DP.ServerName)) { continue }
    $DPFQDN = $DP.ServerName.Trim() + "." + $DomainFullName
    if (-not (Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $DP.ServerSiteCode)) {
        $allInstalled = $false
        break
    }
}
$dpInstallFailed = $false
if ($allInstalled) {
    foreach ($PDP in $PullDPs) {
        if ([string]::IsNullOrWhiteSpace($PDP.ServerName)) { continue }
        $DPFQDN = $PDP.ServerName.Trim() + "." + $DomainFullName
        if (-not (Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $PDP.ServerSiteCode)) {
            $allInstalled = $false
            break
        }
    }
}
if ($allInstalled) {
    foreach ($MP in $MPs) {
        if ([string]::IsNullOrWhiteSpace($MP.ServerName)) { continue }
        $MPFQDN = $MP.ServerName.Trim() + "." + $DomainFullName
        if (-not (Get-CMManagementPoint -SiteSystemServerName $MPFQDN)) {
            $allInstalled = $false
            break
        }
    }
}
# Also verify at least 1 DP and 1 MP exist in the site
if ($allInstalled) {
    $dpCount = (Get-CMDistributionPoint -SiteCode $SiteCode | Measure-Object).Count
    $mpCount = (Get-CMManagementPoint -SiteCode $SiteCode | Measure-Object).Count
    if ($dpCount -eq 0 -or $mpCount -eq 0) {
        $allInstalled = $false
    }
}
# Check bare site systems are registered
if ($allInstalled) {
    foreach ($BSS in $BareSiteSystems) {
        if ([string]::IsNullOrWhiteSpace($BSS.ServerName)) { continue }
        $BSSFQDN = $BSS.ServerName.Trim() + "." + $DomainFullName
        if (-not (Get-CMSiteSystemServer -SiteSystemServerName $BSSFQDN -SiteCode $BSS.ServerSiteCode)) {
            $allInstalled = $false
            break
        }
    }
}

if ($allInstalled) {
    # Even when every DP/MP role is already registered (so the installs below are
    # skipped), an HTTPS (PKI) MP still needs its IIS "Default Web Site" 443 SSL
    # binding present with a valid WebServer cert. If it is missing, the server-side
    # MP Control Manager MSI fails with "Error 25055 ... not correctly configured
    # for SSL" and the SMS_MP IIS app is never created (Phase 11 then fails with
    # "IIS application 'SMS_MP' not found"). Install-MP normally ensures this via
    # Confirm-MPHttpsBinding, but it does NOT run on this skip path -- so a lab that
    # was first registered as eHTTP (UsePKI=false) and later corrected to PKI would
    # stay broken. Ensure the binding here for every HTTPS MP. Idempotent no-op when
    # the binding is already correct.
    if ($usePKI) {
        $mpBindingRepaired = $false
        foreach ($MP in $MPs) {
            if ([string]::IsNullOrWhiteSpace($MP.ServerName)) { continue }
            $MPFQDN = $MP.ServerName.Trim() + "." + $DomainFullName
            if (Confirm-MPHttpsBinding -MPFQDN $MPFQDN) { $mpBindingRepaired = $true }
        }
        # If we just created/repaired an MP's 443 binding, the server-side MP install
        # had previously failed (error 25055) and Site Component Manager is now in a
        # long retry backoff. Restart it on this site server to force an immediate
        # retry so the SMS_MP IIS app is created without waiting for the next cycle.
        if ($mpBindingRepaired) {
            try {
                Restart-Service -Name SMS_SITE_COMPONENT_MANAGER -Force -ErrorAction Stop
                Write-DscStatus "Restarted SMS_SITE_COMPONENT_MANAGER to force MP install retry after repairing the IIS 443 binding."
            }
            catch {
                Write-DscStatus "WARNING: Could not restart SMS_SITE_COMPONENT_MANAGER (MP install will retry on its own backoff cycle): $($_.Exception.Message)"
            }
        }
    }
    foreach ($DP in @($DPs) + @($PullDPs)) {
        if ([string]::IsNullOrWhiteSpace($DP.ServerName)) { continue }
        $DPFQDN = $DP.ServerName.Trim() + "." + $DomainFullName
        $prestageResult = @(& $startClientPackagePrestage $DPFQDN)
        if ($prestageResult.Count -eq 0 -or -not [bool]$prestageResult[-1]) { $dpInstallFailed = $true; break }
    }
    if ($dpInstallFailed) {
        $Configuration.InstallDP.Status = 'NotStart'
        $Configuration.InstallDP.EndTime = ''
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
        return
    }
    Write-DscStatus "All DP/MP roles already installed. Skipping InstallDPMPClient."
    $Configuration.InstallDP.Status = 'Completed'
    $Configuration.InstallDP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration.InstallMP.Status = 'Completed'
    $Configuration.InstallMP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

Write-DscStatus "MP role to be installed on '$($MPNames -join ',')'"
Write-DscStatus "DP role to be installed on '$($DPNames -join ',')'"
Write-DscStatus "Pull DP role to be installed on '$($PullDPNames -join ',')'"

# Register bare site systems (no DP/MP/SUP/RP) in the console so roles can
# be added manually after deployment (e.g. Reporting Services Point).
foreach ($BSS in $BareSiteSystems) {
    if ([string]::IsNullOrWhiteSpace($BSS.ServerName)) { continue }
    $BSSFQDN = $BSS.ServerName.Trim() + "." + $DomainFullName
    $existing = Get-CMSiteSystemServer -SiteSystemServerName $BSSFQDN -SiteCode $BSS.ServerSiteCode
    if (-not $existing) {
        Write-DscStatus "Registering bare site system $BSSFQDN in site $($BSS.ServerSiteCode)"
        New-CMSiteSystemServer -SiteSystemServerName $BSSFQDN -SiteCode $BSS.ServerSiteCode *>&1 | Write-StatusLogEntry
    }
    else {
        Write-DscStatus "Site system $BSSFQDN already registered in site $($BSS.ServerSiteCode)"
    }
}

foreach ($DP in $DPs) {

    if ([string]::IsNullOrWhiteSpace($DP.ServerName)) {
        Write-DscStatus "Found an empty DP ServerName. Skipping"
        continue
    }

    $DPFQDN = $DP.ServerName.Trim() + "." + $DomainFullName
    $dpInstallResult = @(Install-DP -ServerFQDN $DPFQDN -ServerSiteCode $DP.ServerSiteCode -usePKI:$usePKI)
    if ($dpInstallResult.Count -eq 0 -or -not [bool]$dpInstallResult[-1]) {
        $dpInstallFailed = $true
    }
    else {
        $prestageResult = @(& $startClientPackagePrestage $DPFQDN)
        if ($prestageResult.Count -eq 0 -or -not [bool]$prestageResult[-1]) { $dpInstallFailed = $true }
    }
}

foreach ($MP in $MPs) {

    if ([string]::IsNullOrWhiteSpace($MP.ServerName)) {
        Write-DscStatus "Found an empty MP ServerName. Skipping"
        continue
    }

    $MPFQDN = $MP.ServerName.Trim() + "." + $DomainFullName
    Install-MP -ServerFQDN $MPFQDN -ServerSiteCode $MP.ServerSiteCode -usePKI:$usePKI
}

# A Pull DP requires its Source DP to already be an INSTALLED standard DP.
# Add-CMDistributionPoint -EnablePullDP -SourceDistributionPoint throws
# "No object corresponds to the specified parameters" (a terminating error that
# aborts this whole script) when the source isn't a DP yet. The source is
# frequently the site server itself (e.g. the Primary), which is NOT in $DPs and
# only gets a DP from the "force install DP on Site Server" fallback further
# below -- code that never runs once the pull-DP add throws. That leaves the site
# with no DP and the pull DP permanently uninstalled. Install every unique pull-DP
# source as a standard DP FIRST so the source object exists before we add pull DPs.
$EnsuredSourceDPs = @{}
foreach ($PDP in $PullDPs) {
    if ([string]::IsNullOrWhiteSpace($PDP.ServerName)) { continue }
    if ([string]::IsNullOrWhiteSpace($PDP.SourceDP)) { continue }
    $SourceDPFQDN = $PDP.SourceDP.Trim() + "." + $DomainFullName
    if ($EnsuredSourceDPs.ContainsKey($SourceDPFQDN)) { continue }
    $EnsuredSourceDPs[$SourceDPFQDN] = $true
    if (-not (Get-CMDistributionPoint -SiteSystemServerName $SourceDPFQDN -SiteCode $PDP.ServerSiteCode)) {
        Write-DscStatus "Pull DP source '$SourceDPFQDN' is not a Distribution Point yet. Installing standard DP on the source first (required before adding pull DPs)."
        $dpInstallResult = @(Install-DP -ServerFQDN $SourceDPFQDN -ServerSiteCode $PDP.ServerSiteCode -usePKI:$usePKI)
        if ($dpInstallResult.Count -eq 0 -or -not [bool]$dpInstallResult[-1]) {
            $dpInstallFailed = $true
        }
        else {
            $prestageResult = @(& $startClientPackagePrestage $SourceDPFQDN)
            if ($prestageResult.Count -eq 0 -or -not [bool]$prestageResult[-1]) { $dpInstallFailed = $true }
        }
    }
}

foreach ($PDP in $PullDPs) {

    if ([string]::IsNullOrWhiteSpace($PDP.ServerName)) {
        Write-DscStatus "Found an empty Pull DP ServerName. Skipping"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($PDP.SourceDP)) {
        Write-DscStatus "Found Pull DP $($PDP.ServerName) with empty SourceDP. Skipping"
        continue
    }

    $DPFQDN = $PDP.ServerName.Trim() + "." + $DomainFullName
    $SourceDPFQDN = $PDP.SourceDP.Trim() + "." + $DomainFullName
    $dpInstallResult = @(Install-PullDP -ServerFQDN $DPFQDN -ServerSiteCode $PDP.ServerSiteCode -SourceDPFQDN $SourceDPFQDN -usePKI:$usePKI)
    if ($dpInstallResult.Count -eq 0 -or -not [bool]$dpInstallResult[-1]) {
        $dpInstallFailed = $true
    }
    else {
        $prestageResult = @(& $startClientPackagePrestage $DPFQDN)
        if ($prestageResult.Count -eq 0 -or -not [bool]$prestageResult[-1]) { $dpInstallFailed = $true }
    }
}

# Force install DP/MP on PS Site Server ONLY when the site has no dedicated DP/MP.
# The whole point of a standalone DPMP is to keep those roles OFF the Primary, so
# we must NOT fall back onto the site server whenever a dedicated DP/MP is
# configured for this site -- even if it hasn't registered in CM yet at this
# instant (avoids a race where the site server grabs the role the DPMP is meant to
# own). The fallback only fires for a genuinely DP/MP-less site (e.g. a minimal
# Primary-only config with no SiteSystem DPMP).
$dpCount = (Get-CMDistributionPoint -SiteCode $SiteCode | Measure-Object).Count
$mpCount = (Get-CMManagementPoint -SiteCode $SiteCode | Measure-Object).Count

$configuredDPsThisSite = @($DPs | Where-Object { $_.ServerSiteCode -eq $SiteCode }).Count `
    + @($PullDPs | Where-Object { $_.ServerSiteCode -eq $SiteCode }).Count
$configuredMPsThisSite = @($MPs | Where-Object { $_.ServerSiteCode -eq $SiteCode }).Count

if ($dpCount -eq 0) {
    if ($configuredDPsThisSite -eq 0) {
        Write-DscStatus "No DP's found or configured in site $SiteCode. Forcing DP install on Site Server $ThisMachineName"
        $dpInstallResult = @(Install-DP -ServerFQDN ($ThisMachineName + "." + $DomainFullName) -ServerSiteCode $SiteCode -usePKI:$usePKI)
        if ($dpInstallResult.Count -eq 0 -or -not [bool]$dpInstallResult[-1]) {
            $dpInstallFailed = $true
        }
        else {
            $prestageResult = @(& $startClientPackagePrestage ($ThisMachineName + "." + $DomainFullName))
            if ($prestageResult.Count -eq 0 -or -not [bool]$prestageResult[-1]) { $dpInstallFailed = $true }
        }
    }
    else {
        Write-DscStatus "No DP registered in site $SiteCode yet, but $configuredDPsThisSite dedicated DP(s) are configured -- NOT forcing a DP onto site server $ThisMachineName (the standalone DP owns this role)."
    }
}

if ($mpCount -eq 0) {
    if ($configuredMPsThisSite -eq 0) {
        Write-DscStatus "No MP's found or configured in site $SiteCode. Forcing MP install on Site Server $ThisMachineName"
        Install-MP -ServerFQDN ($ThisMachineName + "." + $DomainFullName) -ServerSiteCode $SiteCode -usePKI:$usePKI
    }
    else {
        Write-DscStatus "No MP registered in site $SiteCode yet, but $configuredMPsThisSite dedicated MP(s) are configured -- NOT forcing an MP onto site server $ThisMachineName (the standalone MP owns this role)."
    }
}

if ($dpInstallFailed) {
    Write-DscStatus "One or more Distribution Point roles or client-package targeting checks failed. Leaving InstallDP incomplete so Phase 8 retries before boundary-group and client-package validation." -Failure
    $Configuration.InstallDP.Status = 'NotStart'
    $Configuration.InstallDP.EndTime = ''
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

# Mark completed
$Configuration.InstallDP.Status = 'Completed'
$Configuration.InstallDP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration.InstallMP.Status = 'Completed'
$Configuration.InstallMP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
