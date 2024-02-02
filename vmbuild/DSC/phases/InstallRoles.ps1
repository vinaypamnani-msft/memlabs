#InstallRoles.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.vmOptions.domainName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$CSName = $ThisVM.thisParams.ParentSiteServer

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

$Configuration.InstallSUP.Status = "Running"
$Configuration.InstallSUP.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Wait for CS
if ($CSName) {
    # Read Actions file on CAS
    $LogFolder = Split-Path $LogPath -Leaf
    $CSFilePath = "\\$CSName\$LogFolder"
    $CSConfigurationFile = Join-Path -Path $CSFilePath -ChildPath "ScriptWorkflow.json"

    # Wait for ScriptWorkflow.json to exist on CAS
    $CSConfiguration = Get-Content -Path $CSConfigurationFile | ConvertFrom-Json
    Write-DscStatus "Waiting for $CSName to finish SUM Configuration. Current Status: $($CSConfiguration.InstallSUP.Status)."
    while ($CSConfiguration.InstallSUP.Status -ne "Completed") {
        Write-DscStatus "Waiting for $CSName to finish SUM Configuration. Current Status: $($CSConfiguration.InstallSUP.Status)" -NoLog -RetrySeconds 30
        Start-Sleep -Seconds 30
        try {
            $CSConfiguration = Get-Content -Path $CSConfigurationFile -ErrorAction Stop | ConvertFrom-Json
        }
        catch {
            Write-DscStatus "Failed to check Status on $CSName from $CSConfigurationFile. $_"
        }
    }
}

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

$topSite = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq "" }
$thisSiteIsTopSite = $topSite.SiteCode -eq $SiteCode

# Reporting Install

foreach ($rp in $deployConfig.virtualMachines | Where-Object { $_.installRP -eq $true } ) {

    $thisSiteCode = $thisVM.SiteCode
    if ($rp.SiteCode -ne $thisSiteCode) {
        #If this is the remote SQL Server for this site code, dont continue
        if ($rp.vmName -ne $thisVM.RemoteSQLVM) {
            continue
        }
    }

    $netbiosName = $deployConfig.vmOptions.DomainNetBiosName
    $username = $netbiosName + "\cm_svc"
    $databaseName = "CM_" + $thisSiteCode

    #Get the SQL Server. Its either going to be local or remote.
    if ($thisVM.sqlVersion) {
        $sqlServer = $thisVM
    }
    else {
        $sqlServer = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $thisVM.RemoteSQLVM }
    }

    $sqlServerName = $sqlServer.vmName + "." + $DomainFullName

    #Add the SQL Instance if there is one
    #if ($sqlServer.sqlInstance -and $sqlServer.sqlInstance -ne "MSSQLSERVER") {
    #    $sqlServerName += "\" + $sqlServer.SqlInstanceName
    #}

    #Add the SQL Instance, and port
    if ($sqlServer.sqlInstanceName) {
        if ($sqlServer.sqlInstanceName -ne "MSSQLSERVER") {
        $sqlServerName = $sqlServerName + "\" + $sqlServer.sqlInstanceName
        }
    }
    if ($sqlServer.sqlPort) {
        $sqlPort = $sqlServer.sqlPort
    }
    else {
        $sqlPort = 1433
    }
    if ($sqlPort -ne "1433") {
        $sqlServerName = $sqlServerName + "," + $sqlPort
    }

    $PBIRSMachine = $rp.vmName + "." + $DomainFullName

    $cm_svc_file = "$LogPath\cm_svc.txt"
    if (Test-Path $cm_svc_file) {
        # Add cm_svc user as a CM Account
        $unencrypted = Get-Content $cm_svc_file
    }

    Add-ReportingUser -SiteCode $thisSiteCode -UserName $username -Unencrypted $unencrypted
    Install-SRP -ServerSiteCode $thisSiteCode -ServerFQDN $PBIRSMachine -UserName $username -SqlServerName $sqlServerName -DatabaseName $databaseName
}

# End Reporting Install

# SUP Install

$SUPs = @()
$ValidSiteCodes = @($SiteCode)
if ($ThisVM.role -eq "Primary") {
    $ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
    $ValidSiteCodes += $ReportingSiteCodes
}

foreach ($sup in $deployConfig.virtualMachines | Where-Object { $_.installSUP -eq $true } ) {
    if ($sup.siteCode -in $ValidSiteCodes) {
        $secondarysite = Get-CMSite -SiteCode $sup.siteCode | Where-Object { $_.Type -eq 1 }
        if ($secondarysite) {
            $supfqdn = $SUP.vmName.Trim() + "." + $DomainFullName
            if ($secondarysite.ServerName -eq $supfqdn) {
                $SUPs += [PSCustomObject]@{
                    ServerName     = $sup.vmName
                    ServerSiteCode = $sup.siteCode
                }
            }
            else {
                Write-DscStatus "Skip SUP role for $($sup.vmName) since it's a remote site system in Secondary site"
            }
        }
        else {
            $SUPs += [PSCustomObject]@{
                ServerName     = $sup.vmName
                ServerSiteCode = $sup.siteCode
            }
        }
    }
}

# Trim nulls/blanks
$SUPNames = $SUPs.ServerName | Where-Object { $_ -and $_.Trim() }
if ($SUPNames) {
    Write-DscStatus "SUP role to be installed on '$($SUPNames -join ',')'"
}

# Check if a SUP Exists on this site
$configureSUP = $false
$existingSUPs = Get-CMSoftwareUpdatePoint -SiteCode $SiteCode
if ($thisSiteIsTopSite -and -not $existingSUPs -and $SUPs.Count -gt 0) {
    $configureSUP = $true
}

# Install SUP
foreach ($SUP in $SUPs) {

    if ([string]::IsNullOrWhiteSpace($SUP.ServerName)) {
        Write-DscStatus "Found an empty SUP ServerName. Skipping"
        continue
    }

    $SUPFQDN = $SUP.ServerName.Trim() + "." + $DomainFullName
    Install-SUP -ServerFQDN $SUPFQDN -ServerSiteCode $SUP.ServerSiteCode
}

# Configure SUP
#$productsToAdd = @("Windows 10, version 1903 and later", "Microsoft Server operating system-21H2")
$productsToAdd = @("PowerShell - x64")
#$classificationsToAdd = @("Critical Updates", "Security Updates", "Updates")
$classificationsToAdd = @("Tools")
if ($configureSUP) {
    Write-DscStatus "Configuring SUP, and adding Products [$($productsToAdd -join ',')] and Classifications [$($classificationsToAdd -join ',')]"
    $schedule = New-CMSchedule -RecurCount 1 -RecurInterval Days -Start "2022/1/1 00:00:00"
    $attempts = 0
    $configured = $false
    do {
        try {
            if ($topSite) {
                $attempts++
                Write-DscStatus "Running Set-CMSoftwareUpdatePointComponent. Attempt #$attempts"
                Set-CMSoftwareUpdatePointComponent -SiteCode $topSite.SiteCode -AddProduct $productsToAdd -AddUpdateClassification $classificationsToAdd -Schedule $schedule -EnableCallWsusCleanupWizard $true
                $configured = $true
                Write-DscStatus "Set-CMSoftwareUpdatePointComponent successful. Waiting 2 mins for WCM to configure WSUS."
                Start-Sleep -Seconds 120  # Sleep for 2 mins to let WCM config WSUS
            }
        }
        catch {
            # Run sync to refresh categories, wait for sync, then try again?
            if (-not $syncTimeout) {
                Write-DscStatus "Set-CMSoftwareUpdatePointComponent failed. Running Sync to refresh products. Attempt #$attempts $_"
                Sync-CMSoftwareUpdate
                Start-Sleep -Seconds 120 # Sync waits for 2 mins anyway, so sleep before even checking status
            }
            else {
                Write-DscStatus "Timed out while waiting for sync to finish. Monitoring again..."
            }
            $syncFinished = $syncTimeout = $false
            $i = 0
            do {
                $syncState = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.WSUSSourceServer -like "*Microsoft Update*" -and $_.SiteCode -eq $SiteCode }

                if (-not $syncState.LastSyncState ) {
                    Write-DscStatus "SUM Sync not detected as running on $($syncState.WSUSServerName). Running Sync to refresh products."
                    Sync-CMSoftwareUpdate
                    Start-Sleep -Seconds 120
                }
                else {
                    $syncStateString = "Unknown"
                    switch ($($syncState.LastSyncState)) {
                        "6700" { $syncStateString = "WSUS Sync Manager Error" }
                        "6701" { $syncStateString = "WSUS Synchronization Started" }
                        "6702" { $syncStateString = "WSUS Synchronization Done" }
                        "6703" { $syncStateString = "WSUS Synchronization Failed" }
                        "6704" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing WSUS Server" }
                        "6705" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing SMS Database" }
                        "6706" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing Internet facing WSUS Server" }
                        "6707" { $syncStateString = "Content of WSUS Server is out of sync with upstream server" }
                        "6709" { $syncStateString = "SMS Legacy Update Synchronization started" }
                        "6710" { $syncStateString = "SMS Legacy Update Synchronization done" }
                        "6711" { $syncStateString = "SMS Legacy Update Synchronization failed" }
                    }

                    Write-DscStatus "Waiting for SUM Sync on $($syncState.WSUSServerName) to finish. Current State: $($syncState.LastSyncState) $syncStateString"
                    if ($syncState.LastSyncState -eq 6702) {
                        $syncFinished = $true
                        Write-DscStatus "SUM Sync finished."
                    }
                }

                if (-not $syncFinished) {
                    $i++
                    Start-Sleep -Seconds 60
                }

                if ($i -gt 20) {
                    $syncTimeout = $true
                    Write-DscStatus "SUM Sync timed out. Skipping Set-CMSoftwareUpdatePointComponent"
                }
            } until ($syncFinished -or $syncTimeout)
        }
    } until ($configured -or $attempts -ge 5)

    if ($configured) {
        Write-DscStatus "SUM Component Configuration successful. Invoking another SUM sync and exiting."
        Start-Sleep -Seconds 15
        Sync-CMSoftwareUpdate
    }
    else {
        Write-DscStatus "SUM Component Configuration failed."
    }
}

$Configuration.InstallSUP.Status = 'Completed'
$Configuration.InstallSUP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force