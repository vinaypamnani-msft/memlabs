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
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
$Configuration.InstallSecondary.Status = 'Running'
$Configuration.InstallSecondary.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

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

        # Check if site already exists
        $exists = Get-CMSiteRole -SiteSystemServerName $secondaryFQDN -RoleName "SMS Site Server" -AllSite
        if ($exists) {
            Write-DscStatus "Secondary Site is already installed on $($SecondaryVM.vmName)." -MachineName $SecondaryName
            $installed = $true
            $alreadyExisted = $true
        }

        $SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
        if ($SecondaryVM.cmInstallDir) {
            $SMSInstallDir = $SecondaryVM.cmInstallDir
        }
        # ===========
        # Do install
        # ===========
        if (-not $installed) {
            Write-DscStatus "Adding secondary site server on $secondaryFQDN with Site Code $secondarySiteCode, attached to $parentSiteCode" -MachineName $SecondaryName

            try {
                $Date = [DateTime]::Now.AddYears(30)
                $FileSetting = New-CMInstallationSourceFile -CopyFromParentSiteServer

                if ($SecondaryVM.sqlVersion) {
                    if ($SecondaryVM.sqlInstanceName.ToUpper() -eq "MSSQLSERVER") {
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
        $smsRestartIntervalSec = 30 * 60          # 30 minutes
        $lastSmsRestartTime    = $startTime
        $consecutiveNullStart  = $null            # first null after progress
        do {

            Start-Sleep -Seconds $sleepSeconds

            $i++
            $siteStatus = Get-CMSite -SiteCode $secondarySiteCode

            if ($siteStatus -and $siteStatus.Status -eq 1) {
                $installed = $true
            }

            if ($siteStatus -and $siteStatus.Status -eq 3) {
                Write-DscStatus "Adding secondary site server failed. Review details in ConfigMgr Console." -Failure -MachineName $SecondaryName
                $installFailure = $true
            }

            if ($siteStatus -and $siteStatus.Status -eq 2) {
                # Pull the full history so we can count distinct steps and detect
                # whether anything new has happened since the last poll.
                $allStates = @(Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_SecondarySiteStatus -Filter "SiteCode = '$secondarySiteCode'" | Sort-Object MessageTime)
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
                    # Keep Primary's own row on the simpler "Installing Secondary site on X"
                    # line -- no need to duplicate per-step detail that's already visible
                    # on the Secondary's row.
                    Write-DscStatus "Installing Secondary site on $secondaryFQDN" -RetrySeconds $sleepSeconds -NoLog

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
    if ($installed -and -not $alreadyExisted) {
        $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $secondarySiteCode
        Write-DscStatus "Secondary installation complete. Waiting for replication link to be 'Active'" -MachineName $SecondaryName

        $drsStartTime = Get-Date
        $drsTimeoutSec = 90 * 60  # 90 minutes
        while ($replicationStatus.LinkStatus -ne 2 -or $replicationStatus.Site1ToSite2GlobalState -ne 2 -or $replicationStatus.Site2ToSite1GlobalState -ne 2 ) {
            $drsElapsed = [int]((Get-Date) - $drsStartTime).TotalSeconds
            if ($drsElapsed -ge $drsTimeoutSec) {
                Write-DscStatus "DRS replication wait timed out after $([int]($drsElapsed/60))m. LinkStatus=$($replicationStatus.LinkStatus), S1->S2=$($replicationStatus.Site1ToSite2GlobalState), S2->S1=$($replicationStatus.Site2ToSite1GlobalState). Proceeding anyway." -MachineName $SecondaryName
                break
            }
            Write-DscStatus "Waiting for Data Replication. $SiteCode -> $secondarySiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)% (Link=$($replicationStatus.LinkStatus), S1->S2=$($replicationStatus.Site1ToSite2GlobalState), S2->S1=$($replicationStatus.Site2ToSite1GlobalState))" -RetrySeconds $sleepSeconds -MachineName $SecondaryName
            Start-Sleep -Seconds $sleepSeconds
            $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $secondarySiteCode
        }

        Write-DscStatus "Secondary installation complete. Replication link is 'Active'." -MachineName $SecondaryName
    }
    elseif ($alreadyExisted) {
        Write-DscStatus "Secondary site was already installed. Skipping replication wait." -MachineName $SecondaryName
    }

}

foreach ($SecondaryVM in $SecondaryVMs) {
    $job = Start-Job -ScriptBlock $Install_Secondary -Name $SecondaryVM.vmName -ErrorAction Stop -ErrorVariable Err
    if (-not $job) {
        Write-DscStatus "Failed to create install job for Secondary VM $($SecondaryVM.vmName). $Err" -Failure -MachineName $SecondaryVM.vmName
    }
    else {
        Write-DscStatus "Created an install job for Secondary VM $($SecondaryVM.vmName). $Err" -NoStatus
    }
}

Get-Job | Wait-Job

# Update actions file
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
$Configuration.InstallSecondary.Status = 'Completed'
$Configuration.InstallSecondary.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force