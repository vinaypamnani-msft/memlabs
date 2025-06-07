# InstallAndUpdateSCCM.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)
Write-DscStatus "Started InstallAndUpdateSCCM.ps1"
# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.parameters.domainName
$CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$CurrentRole = $ThisVM.role
$psvms = $deployConfig.VirtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.ParentSiteCode -eq $thisVM.SiteCode }
$PSVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisVM.thisParams.Primary }

# Read locale settings
$locale = $deployConfig.vmOptions.locale
$cmLanguage = "ENG"
if ($locale -and $locale -ne "en-US") {
    $localeConfigPath = "C:\staging\locale\_localeConfig.json"
    $localeConfig = Get-Content -Path $localeConfigPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $cmLanguage = $localeConfig.$locale.CMLanguage

    # Falling back to ENG if invalid language was set
    if ($cmLanguage.Length -ne 3) {
        $cmLanguage = "ENG"
    }
}

# Set scenario
$scenario = "Standalone"
if ($ThisVM.role -eq "CAS" -or $ThisVM.parentSiteCode) { $scenario = "Hierarchy" }
Write-DscStatus "InstallAndUpdateSCCM.ps1 Scenerio $scenario"
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
    if ($SQLVM.sqlPort) {
        $sqlPort = $SQLVM.sqlPort
    }
    else {
        $sqlPort = 1433
    }
    if ($SQLVM.AlwaysOnListenerName) {
        $installToAO = $true
        $sqlServerName = $SQLVM.AlwaysOnListenerName
        $sqlNode1 = $SQLVM.VMName
        $sqlNode2 = $SQLVM.OtherNode
        $sqlAOGroupName = $SQLVM.AlwaysOnGroupName
        $agBackupShare = $SQLVM.thisParams.SQLAO.BackupShareFQ
        $sqlPort = $SQLVM.thisParams.SQLAO.SQLAOPort
    }
}
else {
    $sqlServerName = $env:COMPUTERNAME
    $sqlInstanceName = $ThisVM.sqlInstanceName
    if ($ThisVM.sqlPort) {
        $sqlPort = $ThisVM.sqlPort
    }
    else {
        $sqlPort = 1433
    }
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
        Write-DscStatus "$CM Does not exist. Failed." -Failure
        return
    }

    Write-DscStatus "Creating $scenario.ini file" # Standalone or Hierarchy
    $CMINIPath = "c:\$CM\$scenario.ini"

    $cmini = @'
[Identification]
Action=%InstallAction%
Preview=0

[Options]
ProductID=%ProductID%
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
%AddServerLanguages%
%AddClientLanguages%

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

[SABranchOptions]
SAActive=1
CurrentBranch=1
'@

    # Get SQL instance info
    #$inst = (get-itemproperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances[0]
    #$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$inst
    #$sqlinfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$p\$inst"

    # Set ini values
    $installAction = if ($CurrentRole -eq "CAS") { "InstallCAS" } else { "InstallPrimarySite" }
    $productID = "EVAL"

    if ($CM -ne "CMTP") {
        if (-not $($deployConfig.cmOptions.EVALVersion)) {
            if ($($deployConfig.parameters.ProductID)) {
                $productID = $($deployConfig.parameters.ProductID)
            }
        }
    }
    $cmini = $cmini.Replace('%ProductID%', $productID)
    $cmini = $cmini.Replace('%InstallAction%', $installAction)
    $cmini = $cmini.Replace('%InstallDir%', $SMSInstallDir)
    $cmini = $cmini.Replace('%MachineFQDN%', "$env:computername.$DomainFullName")
    $cmini = $cmini.Replace('%SQLMachineFQDN%', "$sqlServerName.$DomainFullName")
    $cmini = $cmini.Replace('%SqlPort%', $sqlPort)
    $cmini = $cmini.Replace('%SiteCode%', $SiteCode)
    # $cmini = $cmini.Replace('%SQLDataFilePath%', $sqlinfo.DefaultData)
    # $cmini = $cmini.Replace('%SQLLogFilePath%', $sqlinfo.DefaultLog)
    $cmini = $cmini.Replace('%CM%', $CM)

    if ($($deployConfig.cmOptions.InstallSCP) -eq $false) {
        $cmini = $cmini.Replace('CloudConnector=1', "CloudConnector=0")
    }

    if ($($deployConfig.cmOptions.OfflineSCP) -eq $true) {
        $cmini = $cmini.Replace('CloudConnector=1', "CloudConnector=0")
    }

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
            if (-not [string]::isnullorwhitespace($ThisVM.siteName)) {
                $cmini = $cmini.Replace('%SiteName%', $ThisVM.siteName)
            }
            else {
                $cmini = $cmini.Replace('%SiteName%', "ConfigMgr CAS")
            }
        }
        else {
            if (-not [string]::isnullorwhitespace($ThisVM.siteName)) {
                $cmini = $cmini.Replace('%SiteName%', $ThisVM.siteName)
            }
            else {
                $cmini = $cmini.Replace('%SiteName%', "ConfigMgr Primary Site")
            }
        }
    }

    if ($sqlInstanceName.ToUpper() -eq "MSSQLSERVER" -or $installToAO) {
        $cmini = $cmini.Replace('%SQLInstance%', "")
    }
    else {
        $tinstance = $sqlInstanceName.ToUpper() + "\"
        $cmini = $cmini.Replace('%SQLInstance%', $tinstance)
    }

    # Set language
    if ($cmLanguage -ne "ENG") {
        $cmini = $cmini.Replace('%AddServerLanguages%', "AddServerLanguages=${cmLanguage}")
        $cmini = $cmini.Replace('%AddClientLanguages%', "AddClientLanguages=${cmLanguage}")
    }
    else {
        $cmini = $cmini.Replace('%AddServerLanguages%', '')
        $cmini = $cmini.Replace('%AddClientLanguages%', '')
    }

    # Write Setup entry, which causes the job on host to overwrite status with entries from ConfigMgrSetup.log
    Write-DscStatusSetup

    #Setup Downloader

    $CMDir = "c:\$CM"
    $CMDirnew = Join-Path $CMDir "cd.retail"
    if (Test-Path $CMDirnew -PathType Container) {
        $CMDir = $CMDirnew
    }
    else {
        $CMDirnew = Join-Path $CMDir "cd.retail.LN"
        if (Test-Path $CMDirnew -PathType Container) {
            $CMDir = $CMDirnew
        }
        else {
            $CMDirnew = Join-Path $CMDir "cd.preview"
            if (Test-Path $CMDirnew -PathType Container) {
                $CMDir = $CMDirnew
            }
        }
    }


    $CMBin = "$CMDir\SMSSETUP\BIN\X64"
    $CMSetupDL = "$CMBin\Setupdl.exe"
    $CMRedist = "C:\$CM\REdist"
    $CMLog = "C:\ConfigMgrSetup.log"
    $success = 0
    $fail = 0

    Write-DscStatus "Starting Pre-Req Download using $CMSetupDL /NOUI $CMRedist"

    $maxTries = 20
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
        else {
            #If we didnt find it, increment fail count, and bail after 10 fails
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            $success = 0
            $fail++
            if ($fail -ge 20) {
                Write-DscStatus "Pre-Req Downloading failed after $maxTries tries. see $CMLog"
                # Set Status to not 'Running' so it can run again.
                $Configuration.InstallSCCM.Status = 'Failed'
                $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
                Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
                return
            }
            Write-DscStatus "Pre-Req downloading Failed. Try $fail out of $maxTries See $CMLog for progress"
            start-sleep -Seconds 30
        }
    }

    #Fix 0 byte files in CMCB

    # Get-ChildItem $CMBIN | ForEach-Object {
    #     if(!$_.PSIsContainer -and $_.length -eq 0) {
    #        write-host (“{0} -> {1} {2}” -f $_.FullName, $_.Name, $_.Length)
    #        $RedistFile = (Join-Path $CMRedist $_.Name)
    #        if ((Test-Path $RedistFile)) {
    #        write-host "found $RedistFile"
    #        Copy-Item $RedistFile $_.FullName -force
    #        }
    #        }
    #     }

    # Create ini
    $cmini > $CMINIPath

    # Install CM
    $CMInstallationFile = "$CMDir\SMSSETUP\BIN\X64\Setup.exe"
    $CMFileVersion = Get-Item -Path $CMInstallationFile -ErrorAction SilentlyContinue

    Write-DscStatus "Starting Install of CM from $CMInstallationFile [$($CMFileVersion.VersionInfo.FileVersion)]"
    start-sleep -seconds 4

    Write-DscStatusSetup

    Start-Process -Filepath ($CMInstallationFile) -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -wait

    Write-DscStatus "Installation finished [$($CMFileVersion.VersionInfo.FileVersion)]."

    # Write action completed
    $Configuration.InstallSCCM.Status = 'Completed'
    $Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
    start-sleep -seconds 60
    $firstRun = $true

}
else {
    Write-DscStatus "ConfigMgr is already installed"
    $firstRun = $false
    Write-DscStatusSetup
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
    Write-DscStatus "Failed to load the ConfigMgr Powershell Components for site $SiteCode, and provider $($smsProvider.FQDN). Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return $false
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\"
if ((Get-Location).Drive.Name -ne $SiteCode) {
    Write-DscStatus "Failed to Set-Location to $SiteCode`:"
    return $false
}

# Add vmbuildadmin as Full Admin

$userName = "vmbuildadmin"
$userDomain = $env:USERDOMAIN
$domainUserName = "$userDomain\$userName"
$exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -like "*$userName*" }

if (-not $exists) {
    Write-DscStatus "Adding '$userName' account as Full Administrator in ConfigMgr"
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

# Check if we should update
$UpdateRequired = $false
if ($deployConfig.cmOptions.version -notin "current-branch", "tech-preview" -and $deployConfig.cmOptions.version -ne $ThisVM.thisParams.cmDownloadVersion.baselineVersion) {
    $UpdateRequired = $true

    if ($($deployConfig.cmOptions.InstallSCP) -eq $false) {
        $UpdateRequired = $false
    }

    if ($($deployConfig.cmOptions.OfflineSCP) -eq $true) {
        $UpdateRequired = $false        
    }

}

if ($($deployConfig.cmOptions.OfflineSCP) -eq $true) {
    $UpdateRequired = $false
    Write-DscStatus "Installing Offline SCP"
    Add-CMServiceConnectionPoint -SiteSystemServerName "$env:computername.$DomainFullName" -SiteCode $SiteCode -Mode Offline
}


if ($Configuration.UpgradeSCCM.Status -eq 'Completed') {
    $UpdateRequired = $false
}

if ($UpdateRequired) {

    if ($InstalltoAO) {
        try {
            Get-ChildItem "SQLSERVER:\Sql\$sqlServerName\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
            Get-ChildItem "SQLSERVER:\Sql\$sqlNode2\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
            Get-ChildItem "SQLSERVER:\Sql\$sqlNode1\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
        }
        catch {}
    }
    # Update actions file
    $Configuration.UpgradeSCCM.Status = 'Running'
    $Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

    # Check if DMP Downloader is has recently checked for updates

    $registryPath = "HKLM:\Software\Microsoft\SMS\COMPONENTS\SMS_DMP_DOWNLOADER"
    $valueName = "LastSyncedTime"
    
    $lastSyncedTimeHex = (Get-ItemProperty -Path $registryPath -Name $valueName).$valueName
    
    $epoch = [DateTime]::ParseExact("1970-01-01", "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    
    $lastSyncedTime = $epoch.AddSeconds($lastSyncedTimeHex)
    
    $currentTimeUTC = (Get-Date).ToUniversalTime()
    
    $timeDifference = $currentTimeUTC - $lastSyncedTime
    
    # Check if the time difference is less than or equal to 60 minutes
    if ($timeDifference.TotalMinutes -le 60) {
        Write-DscStatus "[DMP Downloader] The LastSyncedTime was updated in the last 60 minutes. Checking for updates."
    }
    else {
        Write-DscStatus "[DMP Downloader] The LastSyncedTime was not updated in the last 60 minutes."
        Set-ItemProperty -Path $registryPath -Name $valueName -Value 0 -Force
        Set-ItemProperty -Path $registryPath -Name "LastSyncRequestTime" -Value 0 -Force
        # Wait for 2 mins before checking DMP Downloader status
        Start-Sleep -Seconds 120
        Write-DscStatus "Checking for updates. Waiting for DMP Downloader."

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

    }




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
    Write-DscStatus "InstallAndUpdateSCCM.ps1 Found Current Build number $originalbuildnumber"
    # Check for updates
    $retrytimes = 0
    $downloadretrycount = 0
    $updatepack = Get-UpdatePack -UpdateVersion $deployConfig.cmOptions.version
    if ($updatepack -ne "") {
        Write-DscStatus "Found '$($updatepack.Name)' update."
    }
    else {
        Write-DscStatus "No updates found."
    }

    $updateCompleted = $false
    # Work on update
    while ($updatepack -ne "") {

        if ($updateCompleted) {
            break
        }

        # Set failure if retry exhausted
        if ($retrytimes -eq 3) {
            $upgradingfailed = $true
            break
        }

        # Get update info
        $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name

        if (-not $updatepack) {
            start-sleep -Seconds 300
            $retrytimes++
            continue
        }
        if ($updatepack.state -eq 199612 ) {
            $updateCompleted = $true
            break
        }

        if (-not $deployConfig.cmOptions.UsePKI) {
            # Enable E-HTTP. This takes time on new install because SSLState flips, so start the script but don't monitor.
            Write-DscStatus "Not UsePKI Running EnableEHTTP.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableEHTTP.ps1"
            . $ScriptFile $ConfigFilePath $LogPath $firstRun
            Write-DscStatus "EnableEHTTP.ps1 done"
        }
        else {
            Write-DscStatus "UsePKI Running EnableHTTPS.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableHTTPS.ps1"
            . $ScriptFile $ConfigFilePath $LogPath $firstRun
            Write-DscStatus "EnableHTTPS.ps1 done"
        }

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
        $count = 0
        while ($updatepack.State -ne 196607 -and $updatepack.State -ne 131074 -and $updatepack.State -ne 131075 -and $updatepack.State -ne 262143 -and $updatepack.State -ne 196612 -and $updatepack.State -ne 196609) {

            $count++
            if ($count -eq 12) {
                Invoke-CMSiteUpdatePrerequisiteCheck -Name $updatepack.Name
            }
            if ($count -ge 30) {
                breaK
            }
            Write-DscStatus "[$($state[$updatepack.State])] Prereq check for '$($updatepack.Name)'."
            Start-Sleep 90
            $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
            
        }

        if ($updatepack.State -eq 196607) {
            Write-DscStatus "Update State: PREREQ_FAILED"
            $retrytimes++
            Start-Sleep 100
            continue
        }

        if ($InstalltoAO) {
            try {
                Get-ChildItem "SQLSERVER:\Sql\$sqlServerName\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
                Get-ChildItem "SQLSERVER:\Sql\$sqlNode2\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
                Get-ChildItem "SQLSERVER:\Sql\$sqlNode1\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
            }
            catch {}
        }
        # trigger setup after the prerequisites check
        Write-DscStatus "Calling Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force"
        
        Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
        while ($updatepack.State -ne 196607 -and $updatepack.State -ne 262143 -and $updatepack.State -ne 196612) {   
            if ($updatepack.Flag -eq 1) {
                Write-DscStatus "Update State: PREREQ_ONLY"
                Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
            }    
            #if ($updatepack.State -eq 131074 -and $updatepack.Flag -eq 1) {
            # PREREQ_SUCCESS and Flag = 1 means the update is in prereq only mode.
            #    Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
            #}

            Write-DscStatus "Updating to '$($updatepack.Name)'. Current State: $($state[$updatepack.State])"
            Start-Sleep -Seconds 60
            try {
                $instance = Get-CimInstance -Class SMS_CM_UpdatePackDetailedMonitoring -Namespace root/SMS/site_$sitecode -Filter "PackageGuid='$($updatepack.PackageGuid)'" | Where-Object { $_.Progress -and $_.Progress -lt 100 }
            }
            catch {}
            if ($instance) {
                Write-DscStatus "$($instance[0].MessageTime.ToShortDateString()) $($instance[0].MessageTime.ToLongTimeString()) $($instance[0].Description)" -NoLog
            }
            start-sleep -seconds 60

            try {
                $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
            }
            catch {}
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
                    Start-Sleep 60
                    $fileversion = (Get-Item ($path + '\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]
                }

                # Wait for copying files finished
                Start-Sleep 600
                $updateCompleted = $true
            }
        }

        if ($updatepack.state -eq 199612 ) {
            $updateCompleted = $true
            break
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
        $Configuration.UpgradeSCCM.Status = 'Error'
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
    $Configuration.UpgradeSCCM.Status = 'Completed'
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

            # Set Delegation for CMPivot
            try {
                if ($SQLVM) {
                    if ($SQLVM.SqlServiceAccount) {
                        if ($SQLVM.SqlServiceAccount -ne "LocalSystem") {
                            $SQLServiceAccountCAS = Get-ADUser -Identity $SQLVM.SqlServiceAccount -Properties PrincipalsAllowedToDelegateToAccount
                        }
                        else {
                            $SQLServiceAccountCAS = Get-ADComputer -Identity $SQLVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                        }
                    }
                    else {
                        $SQLServiceAccountCAS = Get-ADComputer -Identity $SQLVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                    }
                }
                else {
                    $SQLServiceAccountCAS = Get-ADComputer -Identity $ThisVM.vmName -Properties PrincipalsAllowedToDelegateToAccount

                }

                $user = $false
                if ($PSVM.remoteSQLVM) {
                    $PriSQLVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $($PSVM.remoteSQLVM) }
                    if ($PriSQLVM.SqlServiceAccount) {
                        if ($PriSQLVM.SqlServiceAccount -ne "LocalSystem") {
                            $SQLServiceAccountPRI = Get-ADUser -Identity $PriSQLVM.SqlServiceAccount -Properties PrincipalsAllowedToDelegateToAccount
                            $user = $true
                        }
                        else {
                            $SQLServiceAccountPRI = Get-ADComputer -Identity $PriSQLVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                        }
                    }
                    else {
                        $SQLServiceAccountPRI = Get-ADComputer -Identity $PriSQLVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                    }
                }
                else {
                    $SQLServiceAccountPRI = Get-ADComputer -Identity $PSVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                }

                if ($user) {
                    Set-ADUser -Identity $SQLServiceAccountPRI -PrincipalsAllowedToDelegateToAccount $SQLServiceAccountCAS
                }
                else {
                    Set-ADComputer -Identity $SQLServiceAccountPRI -PrincipalsAllowedToDelegateToAccount $SQLServiceAccountCAS
                }
            }
            catch {
                Write-DscStatus "Delegation failed $_"
                start-sleep -seconds 60
            }
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
                Write-DscStatus "Waiting for Primary site to show up via Get-CMSiteSystemServer" -NoLog -RetrySeconds 30
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
                
                if ( $replicationStatus.LinkStatus -ne 2 -or $replicationStatus.Site1ToSite2GlobalState -ne 2 -or $replicationStatus.Site2ToSite1GlobalState -ne 2 -or $replicationStatus.Site2ToSite1SiteState -ne 2 ) {
                    Write-DscStatus "Waiting for Data Replication. $SiteCode -> $PSSiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)" -RetrySeconds 30 -MachineName $PSVM.VmName
                    $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $PSSiteCode
                    Start-Sleep -Seconds 30
                }
                else {
                    Write-DscStatus "Data Replication Complete. $SiteCode -> $PSSiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)" -RetrySeconds 30 -MachineName $PSVM.VmName
                    $waitList = @($waitList | Where-Object { $_ -ne $PSVM.vmName })
                    $propName = "PSReadyToUse" + $PSVM.VmName
                    $Configuration.$propName.Status = 'Completed'
                    $Configuration.$propName.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
                    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
                    Start-Sleep -Seconds 30
                }
            }
        }

        Write-DscStatus "Primary installation complete. Replication link is 'Active'."

    }
}
