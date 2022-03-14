param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$scenario = $deployConfig.parameters.Scenario
$DomainFullName = $deployConfig.parameters.domainName
$CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }
$UpdateToLatest = $deployConfig.cmOptions.updateToLatest
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$CurrentRole = $ThisVM.role
$psvms = $deployConfig.VirtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.ParentSiteCode -eq $thisVM.SiteCode }
$PSVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisVM.thisParams.Primary }

# Set Install Dir
$SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
if ($ThisVM.cmInstallDir) {
    $SMSInstallDir = $ThisVM.cmInstallDir
}

# SQL FQDN

if ($ThisVM.remoteSQLVM) {
    $sqlServerName = $ThisVM.remoteSQLVM
    $SQLVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $sqlServerName }
    $sqlInstanceName = $SQLVM.sqlInstanceName
    $sqlPort = $SQLVM.thisParams.sqlPort
    if ($SQLVM.AlwaysOnName) {
        $installToAO = $true
        $sqlServerName = $SQLVM.AlwaysOnName
        $agBackupShare = $SQLVM.thisParams.SQLAO.BackupShareFQ
        $sqlPort = $SQLVM.thisParams.SQLAO.SQLAOPort
    }
}
else {
    $sqlServerName = $env:COMPUTERNAME
    $sqlInstanceName = $ThisVM.sqlInstanceName
    $sqlPort = $ThisVM.thisParams.sqlPort
}

# Set Site Code
if ($ThisVM.siteCode) {
    $SiteCode = $ThisVM.siteCode
}

# Create $CM and redist dir before we create the INI
if (!(Test-Path C:\$CM\Redist)) {
    New-Item C:\$CM\Redist -ItemType directory | Out-Null
}

# Read Actions file

$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# Reset upgrade action (in case called again in add to existing scenario)
$Configuration.UpgradeSCCM.Status = 'NotStart'
$Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

if ($Configuration.InstallSCCM.Status -ne "Completed" -and $Configuration.InstallSCCM.Status -ne "Running") {

    # Set Install action as Running
    $Configuration.InstallSCCM.Status = 'Running'
    $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

    # Ensure CM files were downloaded
    $cmsourcepath = "c:\$CM"
    if (!(Test-Path $cmsourcepath)) {
        Write-DscStatus "Downloading $CM installation source..."
        if ($CM -eq "CMTP") {
            $cmurl = "https://go.microsoft.com/fwlink/?linkid=2077212&clcid=0x409"
        }
        else {
            $cmurl = "https://go.microsoft.com/fwlink/?linkid=2093192"
        }

        Start-BitsTransfer -Source $cmurl -Destination $cmpath -Priority Foreground -ErrorAction Stop

        if (!(Test-Path $cmsourcepath)) {
            Start-Process -Filepath ($cmpath) -ArgumentList ('/Auto "' + $cmsourcepath + '"') -wait
        }
    }

    Write-DscStatus "Creating $scenario.ini file" # Standalone or Hierarchy
    $CMINIPath = "c:\$CM\$scenario.ini"

    $cmini = @'
[Identification]
Action=%InstallAction%
Preview=0

[Options]
ProductID=EVAL
SiteCode=%SiteCode%
SiteName=%SiteName%
SMSInstallDir=%InstallDir%
SDKServer=%MachineFQDN%
RoleCommunicationProtocol=HTTPorHTTPS
ClientsUsePKICertificate=0
PrerequisiteComp=1
PrerequisitePath=C:\%CM%\REdist
MobileDeviceLanguage=0
AdminConsole=1
JoinCEIP=0

[SQLConfigOptions]
SQLServerName=%SQLMachineFQDN%
DatabaseName=%SQLInstance%CM_%SiteCode%
SQLServerPort=%SqlPort%
SQLSSBPort=4022

AGBackupShare=

[CloudConnectorOptions]
CloudConnector=1
CloudConnectorServer=%MachineFQDN%
UseProxy=0
ProxyName=
ProxyPort=

[SystemCenterOptions]
SysCenterId=

[HierarchyExpansionOption]
'@

    # Get SQL instance info
    #$inst = (get-itemproperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances[0]
    #$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$inst
    #$sqlinfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$p\$inst"

    # Set ini values
    $installAction = if ($CurrentRole -eq "CAS") { "InstallCAS" } else { "InstallPrimarySite" }
    $cmini = $cmini.Replace('%InstallAction%', $installAction)
    $cmini = $cmini.Replace('%InstallDir%', $SMSInstallDir)
    $cmini = $cmini.Replace('%MachineFQDN%', "$env:computername.$DomainFullName")
    $cmini = $cmini.Replace('%SQLMachineFQDN%', "$sqlServerName.$DomainFullName")
    $cmini = $cmini.Replace('%SqlPort%', $sqlPort)
    $cmini = $cmini.Replace('%SiteCode%', $SiteCode)
    # $cmini = $cmini.Replace('%SQLDataFilePath%', $sqlinfo.DefaultData)
    # $cmini = $cmini.Replace('%SQLLogFilePath%', $sqlinfo.DefaultLog)
    $cmini = $cmini.Replace('%CM%', $CM)

    if ($installToAO) {
        $cmini = $cmini.Replace('AGBackupShare=', "AGBackupShare=$agBackupShare")
    }

    if ($deployConfig.parameters.SysCenterId) {
        $cmini = $cmini.Replace('SysCenterId=', "SysCenterId=$($deployConfig.parameters.SysCenterId)")
    }

    # Remove items not needed on CAS
    if ($installAction -eq "InstallCAS") {
        $cmini = $cmini.Replace('RoleCommunicationProtocol=HTTPorHTTPS', "")
        $cmini = $cmini.Replace('ClientsUsePKICertificate=0', "")
    }

    # Set site name
    if ($CM -eq "CMTP") {
        $cmini = $cmini.Replace('%SiteName%', "ConfigMgr Tech Preview")
        $cmini = $cmini.Replace('Preview=0', "Preview=1")
    }
    else {
        $cmini = $cmini.Replace('Preview=0', "")
        if ($installAction -eq "InstallCAS") {
            $cmini = $cmini.Replace('%SiteName%', "ConfigMgr CAS")
        }
        else {
            $cmini = $cmini.Replace('%SiteName%', "ConfigMgr Primary Site")
        }
    }

    if ($sqlInstanceName.ToUpper() -eq "MSSQLSERVER" -or $installToAO) {
        $cmini = $cmini.Replace('%SQLInstance%', "")
    }
    else {
        $tinstance = $sqlInstanceName.ToUpper() + "\"
        $cmini = $cmini.Replace('%SQLInstance%', $tinstance)
    }

    # Write Setup entry, which causes the job on host to overwrite status with entries from ConfigMgrSetup.log
    Write-DscStatusSetup

    #Setup Downloader
    $CMSetupDL = "c:\$CM\SMSSETUP\BIN\X64\Setupdl.exe"
    $CMRedist = "C:\$CM\REdist"
    $CMLog = "C:\ConfigMgrSetup.log"
    $success = 0
    $fail = 0

    Write-DscStatus "Starting Pre-Req Download using $CMSetupDL /NOUI $CMRedist"

    # We require 2 success entries in a row
    while ($success -le 1) {

        #Start Setupdl.exe, and wait for it to exit
        Start-Process -Filepath ($CMSetupDL) -ArgumentList ('/NOUI ' + $CMRedist ) -wait

        #Just to make sure the log is flushed.
        start-sleep -seconds 5

        #Get the last line of the log.  Assumption: No other components are writing to the log at this time.
        $LogLine = Get-Content -Path $CMLog -Tail 1

        #Check for success indicator.
        if ($LogLine -and $LogLine.Contains("INFO: Setup downloader") -and $LogLine.Contains("FINISHED")) {
            $success++
            Write-DscStatus "Pre-Req downloading complete Success Count $success out of 2."
        }
        else { #If we didnt find it, increment fail count, and bail after 10 fails
            $success = 0
            $fail++
            if ($fail -ge 10) {
                Write-DscStatus "Pre-Req Downloading failed after 10 tries. see $CMLog"
                # Set Status to not 'Running' so it can run again.
                $Configuration.InstallSCCM.Status = 'Failed'
                $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
                Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
                return
            }
            Write-DscStatus "Pre-Req downloading Failed. Try $fail out of 10 See $CMLog for progress"
        }
    }
    # Create ini
    $cmini > $CMINIPath

    # Install CM
    $CMInstallationFile = "c:\$CM\SMSSETUP\BIN\X64\Setup.exe"


    Write-DscStatus "Starting Install of CM from $CMInstallationFile"
    start-sleep -seconds 4

    Write-DscStatusSetup

    Start-Process -Filepath ($CMInstallationFile) -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -wait

    Write-DscStatus "Installation finished."

    # Write action completed
    $Configuration.InstallSCCM.Status = 'Completed'
    $Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

}
else {
    Write-DscStatus "ConfigMgr is already installed."
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

# Add vmbuildadmin as Full Admin
Write-DscStatus "Adding 'vmbuildadmin' account as Full Administrator in ConfigMgr"
$userName = "vmbuildadmin"
$userDomain = $env:USERDOMAIN
$domainUserName = "$userDomain\$userName"
$exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -like "*$userName*" }

if (-not $exists) {
    $i = 0
    do {
        $i++
        New-CMAdministrativeUser -Name $domainUserName -RoleName "Full Administrator" `
            -SecurityScopeName "All", "All Systems", "All Users and User Groups"
        Start-Sleep -Seconds 30
        $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -eq $domainUserName }
    }
    until ($exists -or $i -gt 10)
}

if (-not $exists) {
    Write-DscStatus "Failed to add 'vmbuildadmin' account as Full Administrator in ConfigMgr"
}

# Check if we should update to the  latest version
if ($UpdateToLatest) {

    # Update actions file
    $Configuration.UpgradeSCCM.Status = 'Running'
    $Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

    # Wait for 2 mins before checking DMP Downloader status
    Write-DscStatus "Checking for updates. Waiting for DMP Downloader."
    Start-Sleep -Seconds 120

    # Set var
    $upgradingfailed = $false
    $originalbuildnumber = ""

    # Wait for SMS_DMP_DOWNLOADER running
    $counter = 0
    $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\SMS\Components\SMS_Executive\Threads\SMS_DMP_DOWNLOADER")
    $DMPState = $subKey.GetValue("Current State")

    if ($DMPState -ne "Running") {
        Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue
    }

    while ($DMPState -ne "Running") {
        $counter += 1
        Write-DscStatus "SMS_DMP_DOWNLOADER state is: $DMPState" -RetrySeconds 30
        Start-Sleep -Seconds 30
        $DMPState = $subKey.GetValue("Current State")

        if (0 -eq $counter % 10) {
            Write-DscStatus "SMS_DMP_DOWNLOADER state is still $DMPState. Restarting SiteComp service."
            Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue
            Start-Sleep 30
        }
    }


    Write-DscStatus "SMS_DMP_DOWNLOADER state is: $DMPState. Checking for updates."

    #----------------------------------------------------
    $state = @{
        0      = 'UNKNOWN'
        2      = 'ENABLED'
        #DMP DOWNLOAD
        262145 = 'DOWNLOAD_IN_PROGRESS'
        262146 = 'DOWNLOAD_SUCCESS'
        327679 = 'DOWNLOAD_FAILED'
        #APPLICABILITY
        327681 = 'APPLICABILITY_CHECKING'
        327682 = 'APPLICABILITY_SUCCESS'
        393213 = 'APPLICABILITY_HIDE'
        393214 = 'APPLICABILITY_NA'
        393215 = 'APPLICABILITY_FAILED'
        #CONTENT
        65537  = 'CONTENT_REPLICATING'
        65538  = 'CONTENT_REPLICATION_SUCCESS'
        131071 = 'CONTENT_REPLICATION_FAILED'
        #PREREQ
        131073 = 'PREREQ_IN_PROGRESS'
        131074 = 'PREREQ_SUCCESS'
        131075 = 'PREREQ_WARNING'
        196607 = 'PREREQ_ERROR'
        #Apply changes
        196609 = 'INSTALL_IN_PROGRESS'
        196610 = 'INSTALL_WAITING_SERVICE_WINDOW'
        196611 = 'INSTALL_WAITING_PARENT'
        196612 = 'INSTALL_SUCCESS'
        196613 = 'INSTALL_PENDING_REBOOT'
        262143 = 'INSTALL_FAILED'
        #CMU SERVICE UPDATEI
        196614 = 'INSTALL_CMU_VALIDATING'
        196615 = 'INSTALL_CMU_STOPPED'
        196616 = 'INSTALL_CMU_INSTALLFILES'
        196617 = 'INSTALL_CMU_STARTED'
        196618 = 'INSTALL_CMU_SUCCESS'
        196619 = 'INSTALL_WAITING_CMU'
        262142 = 'INSTALL_CMU_FAILED'
        #DETAILED INSTALL STATUS
        196620 = 'INSTALL_INSTALLFILES'
        196621 = 'INSTALL_UPGRADESITECTRLIMAGE'
        196622 = 'INSTALL_CONFIGURESERVICEBROKER'
        196623 = 'INSTALL_INSTALLSYSTEM'
        196624 = 'INSTALL_CONSOLE'
        196625 = 'INSTALL_INSTALLBASESERVICES'
        196626 = 'INSTALL_UPDATE_SITES'
        196627 = 'INSTALL_SSB_ACTIVATION_ON'
        196628 = 'INSTALL_UPGRADEDATABASE'
        196629 = 'INSTALL_UPDATEADMINCONSOLE'
    }
    #----------------------------------------------------

    # Get build number of current install
    $sites = Get-CMSite
    if ($originalbuildnumber -eq "") {
        if ($sites.count -eq 1) {
            $originalbuildnumber = $sites.BuildNumber
        }
        else {
            $originalbuildnumber = $sites[0].BuildNumber
        }
    }

    # Check for updates
    $retrytimes = 0
    $downloadretrycount = 0
    $updatepack = Get-UpdatePack
    if ($updatepack -ne "") {
        Write-DscStatus "Found '$($updatepack.Name)' update."
    }
    else {
        Write-DscStatus "No updates found."
    }

    # Work on update
    while ($updatepack -ne "") {

        # Set failure if retry exhausted
        if ($retrytimes -eq 3) {
            $upgradingfailed = $true
            break
        }

        # Get update info
        $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name

        # Invoke update download
        while ($updatepack.State -eq 327682 -or $updatepack.State -eq 262145 -or $updatepack.State -eq 327679) {

            # Package not downloaded
            if ($updatepack.State -eq 327682) {

                # Invoke download
                Write-DscStatus "Invoking download for '$($updatepack.Name)', waiting for download to begin."
                Invoke-CMSiteUpdateDownload -Name $updatepack.Name -Force -WarningAction SilentlyContinue
                Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                Start-Sleep 120

                # Check state
                $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
                $downloadstarttime = get-date
                while ($updatepack.State -eq 327682) {

                    # Get update state
                    Write-DscStatus "Waiting for '$($updatepack.Name)' download to begin" -RetrySeconds 60
                    Start-Sleep 60

                    # Check state again
                    $downloadspan = New-TimeSpan -Start $downloadstarttime -End (Get-Date)
                    $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast

                    # Trigger restart every 5 mins
                    if (0 -eq $downloadspan.Minutes % 5) {
                        Write-DscStatus "Still waiting for '$($updatepack.Name)' download to begin, Restarting SmsExec."
                        Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                    }

                    # Been an hour, incrememt retry counter
                    if ($downloadspan.Hours -ge 1) {
                        Write-DscStatus "Still waiting for '$($updatepack.Name)' download to begin, Restarting SmsExec and incrementing retry counter."
                        Restart-Service -DisplayName "SMS_Executive"
                        $downloadretrycount++
                        Start-Sleep 120
                        $downloadstarttime = get-date
                    }

                    # Give up and fail after 2 hours
                    if ($downloadretrycount -ge 2) {
                        Write-DscStatus "Timed out waiting for '$($updatepack.Name)' download to start."
                        break
                    }
                }
            }

            # Give up and fail
            if ($downloadretrycount -ge 2) {
                break
            }

            #waiting package downloaded
            $downloadstarttime = get-date
            while ($updatepack.State -eq 262145) {
                Write-DscStatus "Download in progress. Waiting for '$($updatepack.Name)' download to complete" -RetrySeconds 30
                Start-Sleep 30
                $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
                $downloadspan = New-TimeSpan -Start $downloadstarttime -End (Get-Date)
                if ($downloadspan.Minutes -ge 30) {
                    Write-DscStatus "Still waiting for '$($updatepack.Name)' download to complete'. Restarting SmsExec."
                    Restart-Service -DisplayName "SMS_Executive"
                    Start-Sleep 120
                    $downloadstarttime = get-date
                }
            }

            #downloading failed
            if ($updatepack.State -eq 327679) {
                $retrytimes++
                Start-Sleep 300
                continue
            }
        }

        if ($downloadretrycount -ge 2) {
            Write-DscStatus "Timed out waiting for '$($updatepack.Name)' download to complete."
            break
        }

        # trigger prerequisites check after the package downloaded
        Invoke-CMSiteUpdatePrerequisiteCheck -Name $updatepack.Name
        while ($updatepack.State -ne 196607 -and $updatepack.State -ne 131074 -and $updatepack.State -ne 131075) {

            Write-DscStatus "Running prerequisites check for '$($updatepack.Name)'. Current State: $($state[$updatepack.State])"
            Start-Sleep 120
            $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
        }

        if ($updatepack.State -eq 196607) {
            $retrytimes++
            Start-Sleep 300
            continue
        }

        # trigger setup after the prerequisites check
        Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
        while ($updatepack.State -ne 196607 -and $updatepack.State -ne 262143 -and $updatepack.State -ne 196612) {
            Write-DscStatus "Updating to '$($updatepack.Name)'. Current State: $($state[$updatepack.State])"
            Start-Sleep 120
            $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
        }

        if ($updatepack.State -eq 196612) {
            Write-DscStatus "'$($updatepack.Name)' update completed. Current State: $($state[$updatepack.State])"

            # we need waiting the copying files finished if there is only one site
            $toplevelsite = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq "" }
            if ((Get-CMSite).count -eq 1) {

                Write-DscStatus "'$($updatepack.Name)' update completed. Current State: $($state[$updatepack.State]). Waiting for file copy to finish."

                $path = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory'
                $fileversion = (Get-Item ($path + '\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]

                while ($fileversion -ne $toplevelsite.BuildNumber) {
                    Start-Sleep 120
                    $fileversion = (Get-Item ($path + '\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]
                }

                # Wait for copying files finished
                Start-Sleep 600
            }

            #Get if there are any other updates need to be installed
            Write-DscStatus "Checking if another update is available..."
            $updatepack = Get-UpdatePack
            if ($updatepack -ne "") {
                Write-DscStatus "Found another update: '$($updatepack.Name)'."
            }
        }

        if ($updatepack.State -eq 196607 -or $updatepack.State -eq 262143 ) {
            if ($retrytimes -le 3) {
                $retrytimes++
                Start-Sleep 300
                continue
            }
        }
    }

    # Update Action file
    if ($downloadretrycount -ge 2) {
        Write-DscStatus "Failed to download '$($updatepack.Name)'"
        $Configuration.UpgradeSCCM.Status = 'Completed'
    }

    # Update Action file
    if ($upgradingfailed -eq $true) {
        Write-DscStatus "Upgrade to '$($updatepack.Name)' failed."

        if ($($updatepack.Name).ToLower().Contains("hotfix")) {
            Write-DscStatus "'$($updatepack.Name)' is a hotfix, skip it and continue...."
            $Configuration.UpgradeSCCM.Status = 'Completed'
        }
        else {
            $Configuration.UpgradeSCCM.Status = 'Error'
        }
    }
    else {
        $Configuration.UpgradeSCCM.Status = 'Completed'
    }
}
else {

    # Write action completed, PS can start when UpgradeSCCM.EndTime is not empty
    $Configuration.UpgradeSCCM.Status = 'NotRequested'
    $Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
}

if ($installAction -eq "InstallPrimarySite") {

    # We're done, Update Actions file
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

}
else {

    # Write action completed, PS can start when UpgradeSCCM.EndTime is not empty
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

    if ($PSVMs) {

        #Set each Primary to Started
        foreach ($PSVM in $PSVMs) {

            $propName = "PSReadyToUse" + $PSVM.VmName
            if (-not $Configuration.$propName) {
                $PSReadytoUse = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                $Configuration | Add-Member -MemberType NoteProperty -Name  $propName  -Value  $PSReadytoUse -Force

            }
            # Waiting for PS ready to use
            $Configuration.$propName.Status = 'Running'
            $Configuration.$propName.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
            Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
        }
        #Wait for all Primaries to get added
        foreach ($PSVM in $PSVMs) {

            $PSSiteCode = $PSVM.siteCode
            $PSSystemServer = Get-CMSiteSystemServer -SiteCode $PSSiteCode
            Write-DscStatus "Waiting for Primary site installation to finish"
            while (!$PSSystemServer) {
                Write-DscStatus "Waiting for Primary site installation to finish" -NoLog -RetrySeconds 30
                Start-Sleep -Seconds 30
                $PSSystemServer = Get-CMSiteSystemServer -SiteCode $PSSiteCode
            }
        }

        Write-DscStatus "Primary is installed. Waiting for replication link to be 'Active'"


        $waitList = @($PSVMs.vmName)

        while ( $true) {
            if ($waitlist.Count -eq 0) {
                break
            }
            foreach ($PSVM in $PSVMs) {
                if ($waitList -notcontains $PSVM.VmName) {
                    continue
                }
                $PSSiteCode = $PSVM.siteCode
                # Wait for replication ready
                $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $PSSiteCode
                Start-Sleep -Seconds 30
                if ( $replicationStatus.LinkStatus -ne 2 -or $replicationStatus.Site1ToSite2GlobalState -ne 2 -or $replicationStatus.Site2ToSite1GlobalState -ne 2 -or $replicationStatus.Site2ToSite1SiteState -ne 2 ) {
                    Write-DscStatus "Waiting for Data Replication. $SiteCode -> $PSSiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)" -RetrySeconds 30 -MachineName $PSVM.VmName
                    $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $PSSiteCode
                }
                else {
                    Write-DscStatus "Data Replication Complete. $SiteCode -> $PSSiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)" -RetrySeconds 30 -MachineName $PSVM.VmName
                    $waitList = @($waitList | Where-Object { $_ -ne $PSVM.vmName })
                    $propName = "PSReadyToUse" + $PSVM.VmName
                    $Configuration.$propName.Status = 'Completed'
                    $Configuration.$propName.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
                    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
                }
            }
        }

        Write-DscStatus "Primary installation complete. Replication link is 'Active'."

    }
}
