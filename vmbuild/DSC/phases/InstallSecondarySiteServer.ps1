param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.parameters.domainName

# Read Actions file
# $ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
# $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
# $Configuration.InstallSecondary.Status = 'Running'
# $Configuration.InstallSecondary.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
# $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Get info for Secondary Site Servers
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisMachineFQDN = $ThisMachineName + "." + $DomainFullName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$SecondaryVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" -and $_.parentSiteCode -eq $ThisVM.siteCode }
# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    Write-DscStatus "Failed to get 'Site Code' from SOFTWARE\Microsoft\SMS\Identification. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return
}

$failCount = 0
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

        # Check if site already exists
        $exists = Get-CMSiteRole -SiteSystemServerName $secondaryFQDN -RoleName "SMS Site Server" -AllSite
        if ($exists) {
            Write-DscStatus "Secondary Site is already installed on $($SecondaryVM.vmName)." -MachineName $SecondaryName
            #sleep will occur in DRS Monitoring phase
            #Start-Sleep -Seconds 10 # Force sleep for status to update on host.
            $installed = $true
            #continue
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
                $SQLSetting = New-CMSqlServerSetting -CopySqlServerExpressOnSecondarySite -SqlServerServiceBrokerPort 4022 -SqlServerServicePort 1433
                if ($SecondaryVM.sqlVersion) {
                    if ($SecondaryVM.sqlInstanceName.ToUpper() -eq "MSSQLSERVER") {
                        $SQLSetting = New-CMSqlServerSetting -SiteDatabaseName "CM_$secondarySiteCode" -UseExistingSqlServerInstance -SqlServerServiceBrokerPort 4022
                    }
                    else {
                        $SQLSetting = New-CMSqlServerSetting -SiteDatabaseName "CM_$secondarySiteCode" -UseExistingSqlServerInstance -InstanceName $SecondaryVM.sqlInstanceName -SqlServerServiceBrokerPort 4022
                    }
                }

                New-CMSecondarySite -CertificateExpirationTimeUtc $Date -Http -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
                    -PrimarySiteCode $parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
                    -SiteName "Secondary Site" -SqlServerSetting $SQLSetting -CreateSelfSignedCertificate | Out-File $global:StatusLog -Append
                Start-Sleep -Seconds 15
            }
            catch {
                try {
                    $_ | Out-File $global:StatusLog -Append
                    Write-DscStatus "Failed to add secondary site on $secondaryFQDN. Error: $_. Retrying once." -MachineName $SecondaryName
                    Start-Sleep -Seconds 300
                    New-CMSecondarySite -CertificateExpirationTimeUtc $Date -Http -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
                        -PrimarySiteCode $parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
                        -SiteName "Secondary Site" -SqlServerSetting $SQLSetting -CreateSelfSignedCertificate | Out-File $global:StatusLog -Append
                }
                catch {
                    $_ | Out-File $global:StatusLog -Append
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
        $i = 0
        $sleepSeconds = 30
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
                $state = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_SecondarySiteStatus -Filter "SiteCode = '$secondarySiteCode'" | Sort-Object MessageTime | Select-Object -Last 1

                if ($state) {
                    Write-DscStatus "Installing Secondary site on $secondaryFQDN`: $($state.Status)" -RetrySeconds $sleepSeconds -MachineName $SecondaryName
                }

                if (-not $state) {
                    if (0 -eq $i % 20) {
                        Write-DscStatus "No Progress reported after $($i * $sleepSeconds) seconds, restarting SMS_Executive" -MachineName $SecondaryName
                        Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds ($sleepSeconds * 2)
                    }

                    if ($i -gt 61) {
                        Write-DscStatus "No Progress for adding secondary site reported after $($i * $sleepSeconds) seconds, giving up." -Failure -MachineName $SecondaryName
                        $installFailure = $true
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
        $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $secondarySiteCode
        Write-DscStatus "Secondary installation complete. Waiting for replication link to be 'Active'" -MachineName $SecondaryName

        while ($replicationStatus.LinkStatus -ne 2 -or $replicationStatus.Site1ToSite2GlobalState -ne 2 -or $replicationStatus.Site2ToSite1GlobalState -ne 2 ) {
            Write-DscStatus "Waiting for Data Replication. $SiteCode -> $secondarySiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)" -RetrySeconds $sleepSeconds -MachineName $SecondaryName
            Start-Sleep -Seconds $sleepSeconds
            $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $secondarySiteCode
        }

        Write-DscStatus "Secondary installation complete. Replication link is 'Active'." -MachineName $SecondaryName
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
# $Configuration.InstallSecondary.Status = 'Completed'
# $Configuration.InstallSecondary.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
# $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force