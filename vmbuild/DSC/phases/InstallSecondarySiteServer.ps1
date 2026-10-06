# InstallSecondarySiteServer.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.parameters.domainName

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
# Atomic, mutex-guarded so a concurrent background step (e.g. the passive-site
# install running in parallel) can't clobber this update on the shared file.
$Configuration = Set-ScriptWorkflowStep -ConfigurationFile $ConfigurationFile -Step 'InstallSecondary' -Status 'Running' -StampStartTime

# Get info for Secondary Site Servers
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisMachineFQDN = $ThisMachineName + "." + $DomainFullName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
# Resolve per-VM cmOptions (multi-hierarchy safe).
$cmo = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
$usePKI = $cmo.UsePKI
if (-not $usePKI) {
    $usePKI = $false
}
$SecondaryVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" -and $_.parentSiteCode -eq $ThisVM.siteCode }
# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    Write-DscStatus "Failed to get 'Site Code' from SOFTWARE\Microsoft\SMS\Identification. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return
}

[int]$failCount = 0
$success = $false
while ($success -eq $false) {


    if ($failCount -ge 20) {
        Write-DscStatus "Failed to get SMS Provider for site $SiteCode after 20 retries. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
        return $false
    }
    if ($failCount -ne 0) {
        Start-Sleep -Seconds 30
    }

    $failCount++
    # Provider
    $smsProvider = Get-SMSProvider -SiteCode $SiteCode
    if (-not $smsProvider.FQDN) {
        continue
    }

    # Set CMSite Provider
    $worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($smsProvider.FQDN)
    if (-not $worked) {
        continue
    }

    # Set the current location to be the site code.
    Set-Location "$($SiteCode):\"
    if ((Get-Location).Drive.Name -ne $SiteCode) {
        Write-DscStatus "Try $($failcount)/20: Failed to Set-Location to $SiteCode`:"
        continue
    }
    else {
        $success = $true
    }

}
$mpCount = (Get-CMManagementPoint -SiteCode $SiteCode | Measure-Object).Count
if ($mpCount -eq 0) {
    Write-DscStatus "No MP's were found in site '$SiteCode'. Forcing MP install on Site Server $ThisMachineName"
    Install-MP -ServerFQDN $ThisMachineFQDN -ServerSiteCode $SiteCode
}

Write-DscStatus "Installing Secondary Site on [$($SecondaryVMs.vmName -join ',')]"

$Install_Secondary = {

    # Dot source functions
    $scriptRoot = $using:PSScriptRoot
    . $scriptRoot\ScriptFunctions.ps1

    # usings
    $SiteCode = $using:SiteCode
    $smsProvider = $using:smsProvider
    $SecondaryVM = $using:SecondaryVM
    $DomainFullName = $using:DomainFullName
    $usePKI = $using:UsePKI
    $ParentVM = $using:ThisVM
    $DeployConfig = $using:deployConfig
    $secondaryInstallSucceeded = $false

    $mtx = $null
    try {
        $mtx = New-Object System.Threading.Mutex($false, "NewSecondarySite-$SiteCode")
        [void]$mtx.WaitOne()
        # Set CMSite Provider
        $worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($smsProvider.FQDN)
        if (-not $worked) {
            return
        }

        # Set the current location to be the site code.
        Set-Location "$($SiteCode):\"
        if ((Get-Location).Drive.Name -ne $SiteCode) {
            Write-DscStatus "Failed to Set-Location to $SiteCode`:"
            return
        }

        # Secondary props
        $SecondaryName = $SecondaryVM.vmName
        $secondaryFQDN = $SecondaryVM.vmName + "." + $DomainFullName
        $secondarySiteCode = $SecondaryVM.siteCode
        $parentSiteCode = $SecondaryVM.parentSiteCode
        $installed = $false
        $alreadyExisted = $false
        $recoveryRequested = $false
        $recoveryObservedInProgress = $false
        $recoveryRequestedAt = $null
        $lastRecoveryWaitLog = $null

        # Check if site already exists
        $exists = Get-CMSiteRole -SiteSystemServerName $secondaryFQDN -RoleName "SMS Site Server" -AllSite
        if ($exists) {
            Write-DscStatus "Secondary Site is already installed on $($SecondaryVM.vmName)." -MachineName $SecondaryName

            # Verify the SQL instance and CM database actually exist on the secondary.
            # If a previous install timed out mid-setup, the site record may exist in the
            # parent's DB but the SQL Express instance was never created on the secondary.
            $sqlInstance = if ($SecondaryVM.sqlVersion) {
                if ($SecondaryVM.sqlInstanceName) { $SecondaryVM.sqlInstanceName } else { 'MSSQLSERVER' }
            } else { 'CONFIGMGRSEC' }
            $sqlSvcName = if ($sqlInstance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$sqlInstance" }
            $dbName = "CM_$secondarySiteCode"

            Write-DscStatus "Verifying SQL instance '$sqlInstance' and database '$dbName' exist on $SecondaryName..." -MachineName $SecondaryName
            $dbExists = $false
            try {
                $dbCheck = Invoke-Command -ComputerName $secondaryFQDN -ScriptBlock {
                    param($svcName, $instName, $db)
                    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                    if (-not $svc) {
                        return @{ ServiceOk = $false; ServiceStatus = 'NotFound'; DbOk = $false }
                    }
                    if ($svc.Status -ne 'Running') {
                        # Service exists but is stopped — try to start it before giving up
                        try {
                            Start-Service -Name $svcName -ErrorAction Stop
                            # Wait up to 60s for it to reach Running
                            $waited = 0
                            while ($waited -lt 60) {
                                Start-Sleep -Seconds 5
                                $waited += 5
                                $svc = Get-Service -Name $svcName
                                if ($svc.Status -eq 'Running') { break }
                            }
                        }
                        catch { }
                        $svc = Get-Service -Name $svcName
                        if ($svc.Status -ne 'Running') {
                            return @{ ServiceOk = $false; ServiceStatus = $svc.Status; ServiceStartAttempted = $true; DbOk = $false }
                        }
                    }
                    # SQL service is running — check the database
                    try {
                        Import-Module SqlServer -ErrorAction SilentlyContinue
                        if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                            Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
                        }
                        # -TrustServerCertificate not available on older SQLPS (SQL Express)
                        $sqlParams = @{}
                        if ((Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('TrustServerCertificate')) {
                            $sqlParams['TrustServerCertificate'] = $true
                        }
                        $connStr = if ($instName -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instName" }
                        $result = Invoke-Sqlcmd -ServerInstance $connStr -Query "SELECT state_desc FROM sys.databases WHERE name = '$db'" -QueryTimeout 30 @sqlParams -ErrorAction Stop
                        return @{ ServiceOk = $true; ServiceStatus = 'Running'; DbOk = ($null -ne $result -and $result.state_desc -eq 'ONLINE'); DbState = $result.state_desc }
                    }
                    catch {
                        return @{ ServiceOk = $true; ServiceStatus = 'Running'; DbOk = $false; Error = $_.Exception.Message }
                    }
                } -ArgumentList $sqlSvcName, $sqlInstance, $dbName -ErrorAction Stop

                if ($dbCheck.ServiceOk -and $dbCheck.DbOk) {
                    Write-DscStatus "Verified: SQL service '$sqlSvcName' is Running and database '$dbName' is ONLINE on $SecondaryName." -MachineName $SecondaryName
                    $dbExists = $true
                }
                elseif (-not $dbCheck.ServiceOk) {
                    $startNote = if ($dbCheck.ServiceStartAttempted) { ' (attempted start)' } else { '' }
                    Write-DscStatus "SQL service '$sqlSvcName' is $($dbCheck.ServiceStatus)$startNote on $SecondaryName. The secondary site installation did not complete." -MachineName $SecondaryName
                }
                else {
                    $errMsg = if ($dbCheck.Error) { " Error: $($dbCheck.Error)" } else { "" }
                    Write-DscStatus "Database '$dbName' not found or not ONLINE on $SecondaryName (State: $($dbCheck.DbState)).$errMsg" -MachineName $SecondaryName
                }
            }
            catch {
                Write-DscStatus "Could not verify SQL on $SecondaryName`: $($_.Exception.Message)" -MachineName $SecondaryName
            }

            if ($dbExists) {
                $installed = $true
                $alreadyExisted = $true
            }
            else {
                # The site record exists but the secondary isn't actually functional.
                # Never remove+reinstall — use CM's "Recover Secondary Site" which
                # reinstalls CM, reinstalls/repairs SQL Express, and syncs a new DB
                # from the parent primary.  This avoids:
                #   - "site system role already installed" errors on reinstall
                #   - AD prereq failures (System Management container permissions)
                #
                # The console triggers recovery by updating SMS_SCI_SiteDefinition:
                #   "Requested Status" Value1=2 (Pending), Value2=1011 (recover from primary)
                # Note: the console also sets "PreReq Check" Value=1, but we skip that
                # because the AD prereq check fails in lab environments (System Management
                # container permissions) and would block the recovery.
                Write-DscStatus "Secondary site record exists but SQL/$dbName is missing. Triggering recovery for '$secondarySiteCode' on $SecondaryName..." -MachineName $SecondaryName
                try {
                    $siteDef = Get-WmiObject -Namespace $smsProvider.NamespacePath -ComputerName $smsProvider.FQDN -Query "SELECT * FROM SMS_SCI_SiteDefinition WHERE FileType=2 AND SiteCode='$secondarySiteCode'" -ErrorAction Stop
                    if (-not $siteDef) {
                        Write-DscStatus "Could not find SMS_SCI_SiteDefinition for site '$secondarySiteCode'. Cannot trigger recovery." -Failure -MachineName $SecondaryName
                        continue
                    }

                    # Update embedded properties — only set Requested Status
                    $props = $siteDef.Props
                    $foundRequestedStatus = $false
                    for ($p = 0; $p -lt $props.Count; $p++) {
                        if ($props[$p].PropertyName -eq 'Requested Status') {
                            $props[$p].Value1 = '2'     # Pending
                            $props[$p].Value2 = '1011'  # Recover from primary
                            $foundRequestedStatus = $true
                        }
                    }

                    if (-not $foundRequestedStatus) {
                        $newProp = ([wmiclass]"\\$($smsProvider.FQDN)\$($smsProvider.NamespacePath):SMS_EmbeddedProperty").CreateInstance()
                        $newProp.PropertyName = 'Requested Status'
                        $newProp.Value1 = '2'     # Pending
                        $newProp.Value2 = '1011'  # Recover from primary
                        $props += $newProp
                    }

                    $siteDef.Props = $props
                    $siteDef.Put() | Out-Null
                    Write-DscStatus "Recovery initiated for secondary site '$secondarySiteCode'. CM will reinstall the site, SQL, and sync a new DB from parent." -MachineName $SecondaryName
                    $installed = $false
                    $recoveryRequested = $true
                    $recoveryRequestedAt = Get-Date
                }
                catch {
                    Write-DscStatus "Failed to trigger recovery for secondary site '$secondarySiteCode': $_" -Failure -MachineName $SecondaryName
                    continue
                }
            }
        }

        $SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
        if ($SecondaryVM.cmInstallDir) {
            $SMSInstallDir = $SecondaryVM.cmInstallDir
        }
        # ===========
        # Do install
        # ===========
        if (-not $installed -and -not $recoveryRequested) {
            Write-DscStatus "Adding secondary site server on $secondaryFQDN with Site Code $secondarySiteCode, attached to $parentSiteCode" -MachineName $SecondaryName

            try {
                $Date = [DateTime]::Now.AddYears(30)
                $FileSetting = New-CMInstallationSourceFile -CopyFromParentSiteServer

                if ($SecondaryVM.sqlVersion) {
                    if ($SecondaryVM.sqlInstanceName -ieq "MSSQLSERVER") {
                        # New-CMSqlServerSetting does not allow you to specify a port # when using full SQL
                        #$SQLSetting = New-CMSqlServerSetting -SiteDatabaseName "CM_$secondarySiteCode" -UseExistingSqlServerInstance -SqlServerServiceBrokerPort 4022 -SqlServerServicePort $SecondaryVM.thisParams.sqlPort
                        $SQLSetting = New-CMSqlServerSetting -SiteDatabaseName "CM_$secondarySiteCode" -UseExistingSqlServerInstance -SqlServerServiceBrokerPort 4022
                    }
                    else {
                        #$SQLSetting = New-CMSqlServerSetting -SiteDatabaseName "CM_$secondarySiteCode" -UseExistingSqlServerInstance -InstanceName $SecondaryVM.sqlInstanceName -SqlServerServiceBrokerPort 4022 -SqlServerServicePort $SecondaryVM.thisParams.sqlPort
                        $SQLSetting = New-CMSqlServerSetting -SiteDatabaseName "CM_$secondarySiteCode" -UseExistingSqlServerInstance -InstanceName $SecondaryVM.sqlInstanceName -SqlServerServiceBrokerPort 4022
                    }
                }
                else {
                    $SQLSetting = New-CMSqlServerSetting -CopySqlServerExpressOnSecondarySite -SqlServerServiceBrokerPort 4022 -SqlServerServicePort 1433
                }


                $siteName = "Secondary Site"

                if (-not [string]::IsNullOrWhiteSpace($ThisVM.siteName)) {
                    $siteName = $ThisVM.siteName
                }

                # Seed Primary's own status row so it shows what it's working on
                # before the first 30s monitor poll updates it.
                Write-DscStatus "Installing Secondary site on $secondaryFQDN (initializing)" -NoLog
                if ($usePki) {
                    Write-DscStatus "Adding secondary site server on $secondaryFQDN With PKI" -NoStatus
                    $CertPath = "C:\temp\ConfigMgrClientDistributionPointCertificate.pfx"
                    if (Test-Path $CertPath) {
                        $CertAuth = "$env:windir\temp\ProvisionScript\certauth.txt"
                        if (Test-Path $CertAuth) {
                            $certPass = Get-Content $CertAuth | ConvertTo-SecureString -AsPlainText -Force
                            New-CMSecondarySite -Https -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
                                -PrimarySiteCode $parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
                                -SiteName $siteName -SqlServerSetting $SQLSetting -ImportCertificate -CertificatePath $CertPath -CertificatePassword $certPass -ForceWhenDuplicateCertificate:$true *>&1 | Write-StatusLogEntry
                        }
                    }
                }
                else {
                    Write-DscStatus "Adding secondary site server on $secondaryFQDN Without PKI" -NoStatus
                    New-CMSecondarySite -CertificateExpirationTimeUtc $Date -Http -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
                        -PrimarySiteCode $parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
                        -SiteName $siteName -SqlServerSetting $SQLSetting -CreateSelfSignedCertificate *>&1 | Write-StatusLogEntry
                }
                Start-Sleep -Seconds 15
            }
            catch {
                try {
                    $_ | Write-StatusLogEntry
                    Write-DscStatus "Failed to add secondary site on $secondaryFQDN. Error: $_. Retrying once." -MachineName $SecondaryName
                    Start-Sleep -Seconds 300
                    if ($usePki) {
                        $CertPath = "C:\temp\ConfigMgrClientDistributionPointCertificate.pfx"
                        if (Test-Path $CertPath) {
                            $CertAuth = "$env:windir\temp\ProvisionScript\certauth.txt"
                            if (Test-Path $CertAuth) {
                                $certPass = Get-Content $CertAuth | ConvertTo-SecureString -AsPlainText -Force
                                New-CMSecondarySite -Https -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
                                    -PrimarySiteCode $parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
                                    -SiteName $siteName -SqlServerSetting $SQLSetting -ImportCertificate -CertificatePath $CertPath -CertificatePassword $certPass -ForceWhenDuplicateCertificate:$true *>&1 | Write-StatusLogEntry
                            }
                        }
                    }
                    else {
                        New-CMSecondarySite -CertificateExpirationTimeUtc $Date -Http -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
                            -PrimarySiteCode $parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
                            -SiteName $siteName -SqlServerSetting $SQLSetting -CreateSelfSignedCertificate *>&1 | Write-StatusLogEntry
                    }
                }
                catch {
                    $_ | Write-StatusLogEntry
                    Write-DscStatus "Failed to add secondary site on $secondaryFQDN. Error: $_" -Failure -MachineName $SecondaryName
                    $installFailure = $true
                    continue
                }
            }
            finally {
            }
        }
        # ================
        # Monitor install
        # ================
        # Three timeout scenarios:
        #   "Not started" — CM accepted the request (Status=2) but
        #     SMS_SecondarySiteStatus has no entries yet.  The primary's
        #     engine may still be busy (DP/MP installs, content-library
        #     move, etc.) so the secondary install is queued.  Allow up
        #     to 3 hours before giving up; restart SMS_Executive every
        #     30 min as a recovery nudge.
        #   "Stalled" — progress entries exist but nothing has changed
        #     for 45 min.  Something is genuinely stuck.
        #   "WMI blip" — progress was seen before but WMI returns null
        #     on this iteration (transient).  Retry for 15 min of
        #     consecutive nulls before treating it as a real failure.
        $i = 0
        $sleepSeconds = 15
        $startTime = Get-Date
        $lastStatusText = $null
        $lastProgressTime = $startTime
        $lastSeenMessageTime = [datetime]::MinValue
        $stepNumber = 0
        $everSeenProgress = $false
        $notStartedTimeoutSec  = 3 * 3600        # 3 hours
        $stalledTimeoutSec     = 45 * 60          # 45 minutes
        $wmiBlipTimeoutSec     = 15 * 60          # 15 min of consecutive nulls
        $providerReadTimeoutSec = 45 * 60         # provider recycle / reconnect budget
        $smsRestartIntervalSec = 30 * 60          # 30 minutes
        $lastSmsRestartTime    = $startTime
        $consecutiveNullStart  = $null            # first null after progress
        $providerReadFailureStart = $null
        $lastProviderReadFailureLog = $null
        $lastProviderReconnect = $null
        $unexpectedSiteStatusStart = $null
        $lastUnexpectedSiteStatusLog = $null
        do {

            Start-Sleep -Seconds $sleepSeconds

            $i++
            $monitorSnapshot = $null
            $providerReadError = $null
            try {
                $monitorSnapshot = Get-SecondarySiteInstallMonitorSnapshot -SecondarySiteCode $secondarySiteCode `
                    -ProviderFqdn $smsProvider.FQDN -ProviderNamespacePath $smsProvider.NamespacePath
            }
            catch {
                $providerReadError = $_.Exception.Message
            }

            if ($providerReadError) {
                $now = Get-Date
                if (-not $providerReadFailureStart) { $providerReadFailureStart = $now }
                $providerReadFailureSec = [int](($now - $providerReadFailureStart).TotalSeconds)
                if (-not $lastProviderReconnect -or
                    ($now - $lastProviderReconnect).TotalMinutes -ge 2) {
                    $lastProviderReconnect = $now
                    $reconnect = Reset-CMSiteProviderConnection -SiteCode $SiteCode -ProviderFqdn $smsProvider.FQDN
                    if ($reconnect.Succeeded) {
                        Write-DscStatus "Secondary site monitor rebuilt the $SiteCode`: provider drive after a read failure; retrying the site query." -MachineName $SecondaryName
                    }
                    else {
                        Write-DscStatus "Secondary site monitor could not rebuild the $SiteCode`: provider drive: $($reconnect.Error). The bounded read retry continues." -MachineName $SecondaryName
                    }
                }
                if (-not $lastProviderReadFailureLog -or
                    ($now - $lastProviderReadFailureLog).TotalMinutes -ge 5) {
                    $lastProviderReadFailureLog = $now
                    Write-DscStatus "Secondary site monitor could not read provider state for $secondaryFQDN ($providerReadError). Retrying for up to $([int]($providerReadTimeoutSec / 60)) minutes." -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                    Write-DscStatus "Installing Secondary site on $secondaryFQDN (step $stepNumber): SMS Provider read retry" -RetrySeconds $sleepSeconds -NoLog
                }
                if ($providerReadFailureSec -ge $providerReadTimeoutSec) {
                    Write-DscStatus "Secondary site monitor could not read provider state for $([int]($providerReadFailureSec / 60)) consecutive minutes. Last error: $providerReadError" -Failure -MachineName $SecondaryName
                    $installFailure = $true
                }
                continue
            }
            if ($providerReadFailureStart) {
                $providerReadFailureSec = [int]((Get-Date) - $providerReadFailureStart).TotalSeconds
                Write-DscStatus "Secondary site monitor provider reads recovered after $providerReadFailureSec seconds; resuming installation monitoring." -MachineName $SecondaryName
                $providerReadFailureStart = $null
                $lastProviderReadFailureLog = $null
                $lastProviderReconnect = $null
            }

            $siteStatus = $monitorSnapshot.SiteStatus
            $allStates = @($monitorSnapshot.StatusHistory)
            $siteStatusValue = [int]$siteStatus.Status

            if ($siteStatusValue -notin @(1, 2, 3)) {
                $now = Get-Date
                if (-not $unexpectedSiteStatusStart) { $unexpectedSiteStatusStart = $now }
                $unexpectedStatusSec = [int](($now - $unexpectedSiteStatusStart).TotalSeconds)
                if (-not $lastUnexpectedSiteStatusLog -or
                    ($now - $lastUnexpectedSiteStatusLog).TotalMinutes -ge 5) {
                    $lastUnexpectedSiteStatusLog = $now
                    Write-DscStatus "Secondary site '$secondarySiteCode' returned unexpected Status=$siteStatusValue; waiting for a terminal install state for up to $([int]($providerReadTimeoutSec / 60)) minutes." -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                }
                if ($unexpectedStatusSec -ge $providerReadTimeoutSec) {
                    Write-DscStatus "Secondary site '$secondarySiteCode' remained in unexpected Status=$siteStatusValue for $([int]($unexpectedStatusSec / 60)) minutes." -Failure -MachineName $SecondaryName
                    $installFailure = $true
                }
                continue
            }
            $unexpectedSiteStatusStart = $null
            $lastUnexpectedSiteStatusLog = $null

            if ($siteStatusValue -eq 1) {
                if (-not $recoveryRequested -or $recoveryObservedInProgress) {
                    $installed = $true
                }
                else {
                    $recoveryWaitSec = [int](((Get-Date) - $recoveryRequestedAt).TotalSeconds)
                    if (-not $lastRecoveryWaitLog -or
                        ((Get-Date) - $lastRecoveryWaitLog).TotalMinutes -ge 5) {
                        $lastRecoveryWaitLog = Get-Date
                        Write-DscStatus "Secondary recovery was requested for '$secondarySiteCode', but the site still reports its pre-recovery Active state. Waiting for recovery to enter an in-progress state before accepting Active." -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                    }
                    if ($recoveryWaitSec -ge $providerReadTimeoutSec) {
                        Write-DscStatus "Secondary recovery for '$secondarySiteCode' never entered an in-progress state within $([int]($providerReadTimeoutSec / 60)) minutes." -Failure -MachineName $SecondaryName
                        $installFailure = $true
                    }
                    continue
                }
            }

            if ($siteStatusValue -eq 3) {
                Write-DscStatus "Adding secondary site server failed. Review details in ConfigMgr Console." -Failure -MachineName $SecondaryName
                $installFailure = $true
            }

            if ($siteStatusValue -eq 2) {
                if ($recoveryRequested) { $recoveryObservedInProgress = $true }
                # Pull the full history so we can count distinct steps and detect
                # whether anything new has happened since the last poll.
                $state = $allStates | Select-Object -Last 1

                if ($state) {
                    $everSeenProgress = $true
                    $consecutiveNullStart = $null   # reset blip tracker

                    # MessageTime comes back as a CIM/WMI datetime string; convert
                    # for comparison. Fall back to "now" if the conversion fails so
                    # we don't blow up the monitor loop.
                    $msgTime = $null
                    try { $msgTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($state.MessageTime) } catch { $msgTime = Get-Date }

                    # Count a new "step" whenever the status text changes OR a
                    # newer state message arrives (handles repeated-text cases like
                    # "Creating compressed package" that fires multiple times).
                    if ($state.Status -ne $lastStatusText -or $msgTime -gt $lastSeenMessageTime) {
                        $stepNumber = $allStates.Count
                        $lastStatusText = $state.Status
                        $lastSeenMessageTime = $msgTime
                        $lastProgressTime = Get-Date
                    }

                    $elapsedMin = [int]((Get-Date) - $startTime).TotalMinutes
                    $sinceProgressSec = [int]((Get-Date) - $lastProgressTime).TotalSeconds
                    $progressTag = "step $stepNumber, $($elapsedMin)m elapsed"
                    if ($sinceProgressSec -ge 60) {
                        $progressTag += ", $([int]($sinceProgressSec/60))m on this step"
                    }

                    $msg = "Installing Secondary site on $secondaryFQDN ($progressTag): $($state.Status)"
                    Write-DscStatus $msg -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                    # Keep elapsed time out of the Primary's row so host liveness resets only
                    # when WMI reports real progress, not merely because another minute passed.
                    Write-DscStatus "Installing Secondary site on $secondaryFQDN (step $stepNumber): $($state.Status)" -RetrySeconds $sleepSeconds -NoLog

                    # Stalled: progress was seen before but nothing changed for $stalledTimeoutSec.
                    if ($sinceProgressSec -ge $stalledTimeoutSec) {
                        Write-DscStatus "Secondary site install stalled on step $stepNumber for $([int]($sinceProgressSec/60)) minutes, giving up. Last status: $($state.Status)" -Failure -MachineName $SecondaryName
                        $installFailure = $true
                    }
                }

                if (-not $state) {
                    if ($everSeenProgress) {
                        # WMI returned null after we previously had progress entries.
                        # This is usually a transient WMI/provider blip.  Retry for
                        # $wmiBlipTimeoutSec before treating it as a real failure.
                        if (-not $consecutiveNullStart) {
                            $consecutiveNullStart = Get-Date
                        }
                        $nullSec = [int]((Get-Date) - $consecutiveNullStart).TotalSeconds
                        $nullMin = [int]($nullSec / 60)
                        $elapsedMin = [int]((Get-Date) - $startTime).TotalMinutes

                        Write-DscStatus "Installing Secondary site on $secondaryFQDN ($($elapsedMin)m elapsed, WMI returned no status for $($nullMin)m, last step $stepNumber): $lastStatusText" -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                        Write-DscStatus "Installing Secondary site on $secondaryFQDN" -RetrySeconds $sleepSeconds -NoLog

                        if ($nullSec -ge $wmiBlipTimeoutSec) {
                            Write-DscStatus "WMI has returned no status entries for $($nullMin) minutes after reaching step $stepNumber. Last status: $lastStatusText. Giving up." -Failure -MachineName $SecondaryName
                            $installFailure = $true
                        }
                    }
                    else {
                        # Install hasn't started yet — primary's engine is likely
                        # still busy.  Wait up to $notStartedTimeoutSec.
                        $waitingSec = [int]((Get-Date) - $startTime).TotalSeconds
                        $waitingMin = [int]($waitingSec / 60)

                        Write-DscStatus "Waiting for secondary site installation to begin on $secondaryFQDN ($($waitingMin)m elapsed)" -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                        Write-DscStatus "Waiting for secondary site installation to begin on $secondaryFQDN" -RetrySeconds $sleepSeconds -NoLog

                        # Restart SMS_Executive periodically as a recovery nudge.
                        if (((Get-Date) - $lastSmsRestartTime).TotalSeconds -ge $smsRestartIntervalSec) {
                            Write-DscStatus "No progress after $($waitingMin)m, restarting SMS_Executive as recovery nudge" -MachineName $SecondaryName
                            Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds ($sleepSeconds * 2)
                            $lastSmsRestartTime = Get-Date
                        }

                        if ($waitingSec -ge $notStartedTimeoutSec) {
                            Write-DscStatus "No progress for adding secondary site reported after $($waitingMin) minutes, giving up." -Failure -MachineName $SecondaryName
                            $installFailure = $true
                        }
                    }
                }
            }

        } until ($installed -or $installFailure)
    }
    finally {
        if ($mtx) {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
        }
    }
    $sleepSeconds = 30
    if ($installed) {
        # --- Verify SQL is running on both parent and secondary before DRS check ---
        # If a service was stopped, start it, wait 60s, and confirm it stays running
        # (crash-loop detection). DRS cannot establish without SQL on both endpoints.
        $verifySqlService = {
            param($svcName)
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{ Status = 'NotFound'; Started = $false }
            }
            if ($svc.Status -eq 'Running') {
                return @{ Status = 'Running'; Started = $false }
            }
            # Service exists but is not running — attempt to start it
            try {
                Start-Service -Name $svcName -ErrorAction Stop
                $waited = 0
                while ($waited -lt 30) {
                    Start-Sleep -Seconds 5
                    $waited += 5
                    $svc = Get-Service -Name $svcName
                    if ($svc.Status -eq 'Running') { break }
                }
            }
            catch {
                return @{ Status = (Get-Service -Name $svcName -EA SilentlyContinue).Status; Started = $false; Failed = $true; Error = $_.Exception.Message }
            }
            $svc = Get-Service -Name $svcName
            if ($svc.Status -ne 'Running') {
                return @{ Status = $svc.Status; Started = $false; Failed = $true }
            }
            # Service started — wait 60s and verify it hasn't crashed again
            Start-Sleep -Seconds 60
            $svc = Get-Service -Name $svcName
            if ($svc.Status -ne 'Running') {
                return @{ Status = $svc.Status; Started = $true; CrashLoop = $true }
            }
            return @{ Status = 'Running'; Started = $true }
        }

        # Secondary SQL instance
        $secSqlInstance = if ($SecondaryVM.sqlVersion) {
            if ($SecondaryVM.sqlInstanceName) { $SecondaryVM.sqlInstanceName } else { 'MSSQLSERVER' }
        } else { 'CONFIGMGRSEC' }
        $secSqlSvcName = if ($secSqlInstance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$secSqlInstance" }

        Write-DscStatus "Verifying SQL service '$secSqlSvcName' on $SecondaryName before DRS check..." -MachineName $SecondaryName
        $secResult = Invoke-Command -ComputerName $secondaryFQDN -ScriptBlock $verifySqlService -ArgumentList $secSqlSvcName -ErrorAction SilentlyContinue
        if ($secResult.CrashLoop) {
            Write-DscStatus "SQL service '$secSqlSvcName' on $SecondaryName is crash-looping (started then stopped within 60s). Cannot verify DRS." -Failure -MachineName $SecondaryName
            return
        }
        elseif ($secResult.Failed) {
            Write-DscStatus "SQL service '$secSqlSvcName' on $SecondaryName could not be started (Status=$($secResult.Status)). Cannot verify DRS." -Failure -MachineName $SecondaryName
            return
        }
        elseif ($secResult.Started) {
            Write-DscStatus "SQL service '$secSqlSvcName' on $SecondaryName was stopped. Started successfully and stable after 60s." -MachineName $SecondaryName
        }

        # Parent SQL instance (local or remote)
        $parentSqlInstance = if ($ParentVM.sqlInstanceName) { $ParentVM.sqlInstanceName } else { 'MSSQLSERVER' }
        $parentSqlSvcName = if ($parentSqlInstance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$parentSqlInstance" }
        $parentSqlHost = if ($ParentVM.remoteSQLVM) { "$($ParentVM.remoteSQLVM).$DomainFullName" } else { $null }
        $parentSqlLabel = if ($parentSqlHost) { $parentSqlHost } else { $env:COMPUTERNAME }

        Write-DscStatus "Verifying SQL service '$parentSqlSvcName' on $parentSqlLabel before DRS check..." -MachineName $SecondaryName
        if ($parentSqlHost) {
            $parentResult = Invoke-Command -ComputerName $parentSqlHost -ScriptBlock $verifySqlService -ArgumentList $parentSqlSvcName -ErrorAction SilentlyContinue
        }
        else {
            $parentResult = Invoke-Command -ScriptBlock $verifySqlService -ArgumentList $parentSqlSvcName
        }
        if ($parentResult.CrashLoop) {
            Write-DscStatus "SQL service '$parentSqlSvcName' on $parentSqlLabel is crash-looping (started then stopped within 60s). Cannot verify DRS." -Failure -MachineName $SecondaryName
            return
        }
        elseif ($parentResult.Failed) {
            Write-DscStatus "SQL service '$parentSqlSvcName' on $parentSqlLabel could not be started (Status=$($parentResult.Status)). Cannot verify DRS." -Failure -MachineName $SecondaryName
            return
        }
        elseif ($parentResult.Started) {
            Write-DscStatus "SQL service '$parentSqlSvcName' on $parentSqlLabel was stopped. Started successfully and stable after 60s." -MachineName $SecondaryName
        }

        # --- DRS replication link verification ---
        $drsSqlDataSource = $null
        try {
            $drsSqlDataSource = Get-VmSqlConnectionTarget -SiteVm $ParentVM -DeployConfig $DeployConfig -DomainFullName $DomainFullName
        }
        catch {
            Write-DscStatus "Could not resolve parent SQL data source for DRS ground-truth checks: $($_.Exception.Message). The normal provider summary remains authoritative for this run." -MachineName $SecondaryName
        }
        if (-not $alreadyExisted) {
            Write-DscStatus "Secondary installation complete. Waiting for replication link to be 'Active'" -MachineName $SecondaryName
        }
        else {
            Write-DscStatus "Secondary site already installed. Verifying replication link is 'Active'" -MachineName $SecondaryName
        }

        # ReplicationLinkStatus enum: Active=2, Initializing=4, NotStarted=5, Error=6, Unknown=7, Degraded=8, Failed=9
        $failedStates = @(6, 8, 9)  # Error, Degraded, Failed
        $failedSinceTime = $null
        $reinitAttempted = $false
        $reinitCooldownMin = 10

        $drsStartTime = Get-Date
        $drsTimeoutSec = 120 * 60  # match the hierarchy-link budget
        $replicationStatus = $null
        $drsActive = $false
        $lastDrsReadErrorLog = $null
        $lastDrsMissingRowLog = $null
        while (-not $drsActive) {
            $drsElapsed = [int]((Get-Date) - $drsStartTime).TotalSeconds
            if ($drsElapsed -ge $drsTimeoutSec) {
                $sqlDrsHealth = $null
                if ($drsSqlDataSource) {
                    $sqlDrsHealth = Test-DrsLinkHealthyViaSql -SqlDataSource $drsSqlDataSource `
                        -DatabaseName "CM_$SiteCode" -ParentSiteCode $SiteCode -ChildSiteCode $secondarySiteCode
                }
                if ($sqlDrsHealth -and $sqlDrsHealth.Healthy) {
                    Write-DscStatus "DRS summary did not report Active after $([int]($drsElapsed/60))m, but SQL ground truth is healthy (parent SiteStatus=$($sqlDrsHealth.ParentStatus), child SiteStatus=$($sqlDrsHealth.ChildStatus), negative sends=$($sqlDrsHealth.NegativeSends)). Treating the link as Active and continuing to the DP readiness gate." -MachineName $SecondaryName
                    $drsActive = $true
                }
                else {
                    $sqlDetail = if ($sqlDrsHealth) {
                        " SQL ground truth: parent SiteStatus=$($sqlDrsHealth.ParentStatus), child SiteStatus=$($sqlDrsHealth.ChildStatus), negative sends=$($sqlDrsHealth.NegativeSends), error='$($sqlDrsHealth.Error)'."
                    }
                    else {
                        ' SQL ground truth was unavailable because the parent SQL data source could not be resolved.'
                    }
                    Write-DscStatus "DRS replication wait timed out after $([int]($drsElapsed/60))m. LinkStatus=$($replicationStatus.LinkStatus), S1->S2=$($replicationStatus.Site1ToSite2GlobalState), S2->S1=$($replicationStatus.Site2ToSite1GlobalState).$sqlDetail The secondary is not ready for downstream DP/content work." -Failure -MachineName $SecondaryName
                }
                break
            }

            $drsReadError = $null
            try {
                $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $secondarySiteCode -ErrorAction Stop
            }
            catch {
                $drsReadError = $_.Exception.Message
            }
            if ($drsReadError) {
                if (-not $lastDrsReadErrorLog -or
                    ((Get-Date) - $lastDrsReadErrorLog).TotalMinutes -ge 5) {
                    $lastDrsReadErrorLog = Get-Date
                    Write-DscStatus "Could not read DRS status for $SiteCode -> $secondarySiteCode ($drsReadError); rebuilding the provider drive and retrying." -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                    $reconnect = Reset-CMSiteProviderConnection -SiteCode $SiteCode -ProviderFqdn $smsProvider.FQDN
                    if (-not $reconnect.Succeeded) {
                        Write-DscStatus "DRS monitor could not rebuild the $SiteCode`: provider drive: $($reconnect.Error)."
                    }
                }
                Start-Sleep -Seconds $sleepSeconds
                continue
            }
            $lastDrsReadErrorLog = $null
            if (-not $replicationStatus) {
                if (-not $lastDrsMissingRowLog -or
                    ((Get-Date) - $lastDrsMissingRowLog).TotalMinutes -ge 5) {
                    $lastDrsMissingRowLog = Get-Date
                    Write-DscStatus "DRS status row for $SiteCode -> $secondarySiteCode is not visible yet; waiting without recycling the healthy provider connection." -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                }
                Start-Sleep -Seconds $sleepSeconds
                continue
            }
            $lastDrsMissingRowLog = $null

            $drsActive = Test-SecondarySiteReplicationActive -ReplicationStatus $replicationStatus
            if ($drsActive) { break }

            # Detect failed/error/degraded link and attempt reinit after 10 minutes
            $linkInFailedState = $replicationStatus.LinkStatus -in $failedStates -or $replicationStatus.Site1ToSite2GlobalState -in $failedStates -or $replicationStatus.Site2ToSite1GlobalState -in $failedStates
            if ($linkInFailedState) {
                if (-not $failedSinceTime) {
                    $failedSinceTime = Get-Date
                    Write-DscStatus "DRS link is in a failed state (Link=$($replicationStatus.LinkStatus), S1->S2=$($replicationStatus.Site1ToSite2GlobalState), S2->S1=$($replicationStatus.Site2ToSite1GlobalState)). Will attempt reinit after $reinitCooldownMin minutes." -MachineName $SecondaryName
                }
                $failedMin = [int]((Get-Date) - $failedSinceTime).TotalMinutes
                if ($failedMin -ge $reinitCooldownMin -and -not $reinitAttempted) {
                    $reinitAttempted = $true
                    Write-DscStatus "DRS link has been failed for $failedMin minutes. Attempting reinitialization via SMS_ReplicationGroup.InitializeData..." -MachineName $SecondaryName
                    try {
                        $failedGroups = Get-WmiObject -Namespace "root\sms\site_$SiteCode" -Class SMS_ReplicationGroup -Filter "SiteCode1 = '$SiteCode' AND SiteCode2 = '$secondarySiteCode' AND Status != 2"
                        if ($failedGroups) {
                            foreach ($group in $failedGroups) {
                                Write-DscStatus "Reinitializing replication group '$($group.ReplicationGroup)' (ID=$($group.ID))..." -MachineName $SecondaryName
                                $result = ([wmiclass]"\\.\root\sms\site_$($SiteCode):SMS_ReplicationGroup").InitializeData($group.ID, $SiteCode, $secondarySiteCode)
                                Write-DscStatus "InitializeData result for group '$($group.ReplicationGroup)': ReturnValue=$($result.ReturnValue)" -MachineName $SecondaryName
                            }
                        }
                        else {
                            Write-DscStatus "No failed replication groups found via WMI. Link may recover on its own." -MachineName $SecondaryName
                        }
                    }
                    catch {
                        Write-DscStatus "Failed to reinitialize DRS link: $_. Will continue waiting." -MachineName $SecondaryName
                    }
                }
            }
            else {
                # Link is no longer in a failed state (e.g. moved to Initializing); reset tracking
                if ($failedSinceTime) {
                    Write-DscStatus "DRS link is no longer in a failed state (Link=$($replicationStatus.LinkStatus)). Continuing to wait for Active." -MachineName $SecondaryName
                    $failedSinceTime = $null
                    $reinitAttempted = $false
                }
            }

            Write-DscStatus "Waiting for Data Replication. $SiteCode -> $secondarySiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)% (Link=$($replicationStatus.LinkStatus), S1->S2=$($replicationStatus.Site1ToSite2GlobalState), S2->S1=$($replicationStatus.Site2ToSite1GlobalState))" -RetrySeconds $sleepSeconds -MachineName $SecondaryName
            Start-Sleep -Seconds $sleepSeconds
        }

        if ($drsActive) {
            Write-DscStatus "Secondary site replication link is 'Active'." -MachineName $SecondaryName
            $secondaryHttpsReady = -not $usePKI
            if ($usePKI) {
                $existingMpApp = $null
                try {
                    $existingMpApp = Invoke-Command -ComputerName $secondaryFQDN -ScriptBlock {
                        Import-Module WebAdministration -ErrorAction Stop
                        Get-WebApplication -Site 'Default Web Site' -Name 'SMS_MP' -ErrorAction SilentlyContinue
                    } -ErrorAction Stop
                }
                catch { }
                $mpBindingRepaired = Confirm-MPHttpsBinding -MPFQDN $secondaryFQDN
                $secondaryHttpsReady = Test-MPHttpsBinding -MPFQDN $secondaryFQDN
                if (-not $existingMpApp -or $mpBindingRepaired) {
                    try {
                        Invoke-Command -ComputerName $secondaryFQDN -ScriptBlock {
                            Restart-Service -Name SMS_SITE_COMPONENT_MANAGER -Force -ErrorAction Stop
                        } -ErrorAction Stop
                        Write-DscStatus "Restarted SMS_SITE_COMPONENT_MANAGER on $secondaryFQDN to retry implicit HTTPS MP provisioning." -MachineName $SecondaryName
                    }
                    catch {
                        Write-DscStatus "Could not restart SMS_SITE_COMPONENT_MANAGER on $secondaryFQDN`: $($_.Exception.Message). The bounded MP readiness wait continues." -Warning -MachineName $SecondaryName
                    }
                }
            }
            $secondaryDp = Wait-CMRoleRegistered -RoleName 'Secondary DP' -ServerFQDN $secondaryFQDN `
                -TimeoutSeconds 900 -PollSeconds 15 `
                -Probe {
                    Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_DistributionPointInfo `
                        -Filter "ServerName='$secondaryFQDN'" -ErrorAction Stop
                }
            $secondaryMp = Wait-CMRoleRegistered -RoleName 'Secondary MP' -ServerFQDN $secondaryFQDN `
                -TimeoutSeconds 900 -PollSeconds 15 `
                -Probe {
                    Get-CMManagementPoint -SiteCode $secondarySiteCode -ErrorAction Stop | Where-Object {
                        $networkPath = "$($_.NetworkOSPath)" -replace '^\\\\', ''
                        $networkPath -ieq $secondaryFQDN -or $networkPath -ieq $SecondaryName
                    }
                }
            $secondaryMpIis = Wait-CMRoleRegistered -RoleName 'Secondary MP IIS' -ServerFQDN $secondaryFQDN `
                -TimeoutSeconds 900 -PollSeconds 15 `
                -Probe {
                    Invoke-Command -ComputerName $secondaryFQDN -ScriptBlock {
                        Import-Module WebAdministration -ErrorAction Stop
                        Get-WebApplication -Site 'Default Web Site' -Name 'SMS_MP' -ErrorAction SilentlyContinue
                    } -ErrorAction Stop
                }
            if ($secondaryDp -and $secondaryMp -and $secondaryMpIis -and $secondaryHttpsReady) {
                Write-DscStatus "Secondary DP and MP on $secondaryFQDN are provider-visible, and the SMS_MP IIS application is ready." -MachineName $SecondaryName
                $secondaryInstallSucceeded = $true
            }
            else {
                $missingRoles = @()
                if (-not $secondaryDp) { $missingRoles += 'DP provider role' }
                if (-not $secondaryMp) { $missingRoles += 'MP provider role' }
                elseif (-not $secondaryMpIis) { $missingRoles += 'SMS_MP IIS application' }
                if (-not $secondaryHttpsReady) { $missingRoles += 'healthy IIS HTTPS binding' }
                Write-DscStatus "Secondary site '$secondarySiteCode' is Active, but implicit role readiness failed after bounded waits: $($missingRoles -join ', ')." -Failure -MachineName $SecondaryName
            }
        }
    }

    [pscustomobject]@{
        MemLabsSecondaryInstallResult = $true
        MachineName                   = $SecondaryName
        SiteCode                      = $secondarySiteCode
        Succeeded                     = [bool]$secondaryInstallSucceeded
        LastStep                      = $stepNumber
        LastStatus                    = $lastStatusText
    }
}

$secondaryJobs = @()
foreach ($SecondaryVM in $SecondaryVMs) {
    $job = Start-Job -ScriptBlock $Install_Secondary -Name $SecondaryVM.vmName -ErrorAction Stop -ErrorVariable Err
    if (-not $job) {
        Write-DscStatus "Failed to create install job for Secondary VM $($SecondaryVM.vmName). $Err" -Failure -MachineName $SecondaryVM.vmName
    }
    else {
        $secondaryJobs += $job
        Write-DscStatus "Created an install job for Secondary VM $($SecondaryVM.vmName). $Err" -NoStatus
    }
}

# Wait for and drain only this script's own jobs. Completion requires the child
# to return its explicit success marker; a provider recycle that terminates the
# child must not be mistaken for a completed secondary installation.
$secondaryJobsSucceeded = $secondaryJobs.Count -eq @($SecondaryVMs).Count
foreach ($secondaryJob in $secondaryJobs) {
    try {
        $jobResult = Receive-SecondarySiteInstallJobResult -Job $secondaryJob
        if (-not $jobResult.Succeeded) {
            $secondaryJobsSucceeded = $false
            Write-DscStatus "Secondary install job '$($secondaryJob.Name)' did not complete successfully: $($jobResult.Reason)" -Failure -MachineName $secondaryJob.Name
        }
    }
    catch {
        $secondaryJobsSucceeded = $false
        Write-DscStatus "Secondary install job '$($secondaryJob.Name)' could not be joined or read: $($_.Exception.Message)" -Failure -MachineName $secondaryJob.Name
    }
    finally {
        Remove-Job -Job $secondaryJob -Force -ErrorAction SilentlyContinue
    }
}

if ($secondaryJobsSucceeded) {
    # Update actions file (mutex-guarded so a parallel passive-site install can't
    # clobber this whole-file rewrite).
    $Configuration = Set-ScriptWorkflowStep -ConfigurationFile $ConfigurationFile -Step 'InstallSecondary' -Status 'Completed' -StampEndTime
}
else {
    $Configuration = Set-ScriptWorkflowStep -ConfigurationFile $ConfigurationFile -Step 'InstallSecondary' -Status 'NotStart' -ClearEndTime
    if ($secondaryJobs.Count -ne @($SecondaryVMs).Count) {
        Write-DscStatus "Only $($secondaryJobs.Count) of $(@($SecondaryVMs).Count) secondary install job(s) started; InstallSecondary remains retryable." -Warning
    }
}