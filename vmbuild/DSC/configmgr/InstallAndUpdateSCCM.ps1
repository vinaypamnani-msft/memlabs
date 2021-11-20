param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$scenario = $deployConfig.parameters.Scenario
$CurrentRole = $deployConfig.parameters.ThisMachineRole
$DomainFullName = $deployConfig.parameters.domainName
$CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }
$PSName = $deployConfig.parameters.PSName
$UpdateToLatest = $deployConfig.cmOptions.updateToLatest
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }

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
}
else {
    $sqlServerName = $env:COMPUTERNAME
    $sqlInstanceName = $ThisVM.sqlInstanceName
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
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

if ($Configuration.InstallSCCM.Status -ne "Completed" -and $Configuration.InstallSCCM.Status -ne "Running") {

    # Set Install action as Running
    $Configuration.InstallSCCM.Status = 'Running'
    $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

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
PrerequisiteComp=0
PrerequisitePath=C:\%CM%\REdist
MobileDeviceLanguage=0
AdminConsole=1
JoinCEIP=0

[SQLConfigOptions]
SQLServerName=%SQLMachineFQDN%
DatabaseName=%SQLInstance%CM_%SiteCode%
SQLSSBPort=4022

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
    $cmini = $cmini.Replace('%SiteCode%', $SiteCode)
    # $cmini = $cmini.Replace('%SQLDataFilePath%', $sqlinfo.DefaultData)
    # $cmini = $cmini.Replace('%SQLLogFilePath%', $sqlinfo.DefaultLog)
    $cmini = $cmini.Replace('%CM%', $CM)

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

    if ($sqlInstanceName.ToUpper() -eq "MSSQLSERVER") {
        $cmini = $cmini.Replace('%SQLInstance%', "")
    }
    else {
        $tinstance = $sqlInstanceName.ToUpper() + "\"
        $cmini = $cmini.Replace('%SQLInstance%', $tinstance)
    }

    # Create ini
    $cmini > $CMINIPath

    # Install CM
    $CMInstallationFile = "c:\$CM\SMSSETUP\BIN\X64\Setup.exe"

    # Write Setup entry, which causes the job on host to overwrite status with entries from ConfigMgrSetup.log
    Write-DscStatusSetup

    Start-Process -Filepath ($CMInstallationFile) -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -wait

    Write-DscStatus "Installation finished."

    # Write action completed
    $Configuration.InstallSCCM.Status = 'Completed'
    $Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

}
else {
    Write-DscStatus "ConfigMgr is already installed."
}

# get the available update
function getupdate() {

    Write-DscStatus "Get CM Update..." -NoStatus

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
    $CMPSSuppressFastNotUsedCheck = $true

    $updatepacklist = Get-CMSiteUpdate -Fast | Where-Object { $_.State -ne 196612 }
    $getupdateretrycount = 0
    while ($updatepacklist.Count -eq 0) {

        if ($getupdateretrycount -eq 3) {
            break
        }

        Write-DscStatus "No update found. Running Invoke-CMSiteUpdateCheck and waiting for 2 mins..." -NoStatus
        $getupdateretrycount++

        Invoke-CMSiteUpdateCheck -ErrorAction Ignore
        Start-Sleep 120

        $updatepacklist = Get-CMSiteUpdate | Where-Object { $_.State -ne 196612 }
    }

    $updatepack = ""

    if ($updatepacklist.Count -eq 0) {
        # No updates
    }
    elseif ($updatepacklist.Count -eq 1) {
        # Single update
        $updatepack = $updatepacklist
    }
    else {
        # Multiple updates
        $updatepack = ($updatepacklist | Sort-Object -Property fullversion)[-1]
    }

    return $updatepack
}

# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
$ProviderMachineName = $env:COMPUTERNAME + "." + $DomainFullName # SMS Provider machine name

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
Write-DscStatus "Setting PS Drive"
New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams

while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    Write-DscStatus "Retry in 10s to Set PS Drive for site $SiteCode on $ProviderMachineName"
    Start-Sleep -Seconds 10
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams

# Check if we should update to the  latest version
if ($UpdateToLatest) {

    # Update actions file
    $Configuration.UpgradeSCCM.Status = 'Running'
    $Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force



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
    $updatepack = getupdate
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
                Write-DscStatus "Download in progress. Waiting for '$($updatepack.Name)' download to complete" -RetrySeconds 60
                Start-Sleep 60
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
            $updatepack = getupdate
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
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
}

if ($installAction -eq "InstallPrimarySite") {

    # We're done, Update Actions file
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

}
else {

    # Write action completed, PS can start when UpgradeSCCM.EndTime is not empty
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

    # Waiting for PS ready to use
    $Configuration.PSReadyToUse.Status = 'Running'
    $Configuration.PSReadyToUse.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

    $PSVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $PSName }

    if ($PSVM) {
        $PSSiteCode = $PSVM.siteCode
        $PSSystemServer = Get-CMSiteSystemServer -SiteCode $PSSiteCode
        Write-DscStatus "Waiting for Primary site installation to finish"
        while (!$PSSystemServer) {
            Write-DscStatus "Waiting for Primary site installation to finish" -NoLog -RetrySeconds 60
            Start-Sleep -Seconds 60
            $PSSystemServer = Get-CMSiteSystemServer -SiteCode $PSSiteCode
        }

        # Wait for replication ready
        $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $PSSiteCode
        Write-DscStatus "Primary installation complete. Waiting for replication link to be 'Active'"
        Start-Sleep -Seconds 30
        while ($replicationStatus.LinkStatus -ne 2 -or $replicationStatus.Site1ToSite2GlobalState -ne 2 -or $replicationStatus.Site2ToSite1GlobalState -ne 2 -or $replicationStatus.Site2ToSite1SiteState -ne 2 ) {
            Write-DscStatus "Waiting for Data Replication. $SiteCode -> $PSSiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)%'" -RetrySeconds 60
            Start-Sleep -Seconds 60
            $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $PSSiteCode
        }

        Write-DscStatus "Primary installation complete. Replication link is 'Active'."
    }

    # Update Actions file
    $Configuration.PSReadyToUse.Status = 'Completed'
    $Configuration.PSReadyToUse.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
}