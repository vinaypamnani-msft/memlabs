Param($ConfigFilePath, $ProvisionToolPath)

$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$Config = $deployConfig.parameters.Scenario
$CurrentRole = $deployConfig.parameters.ThisMachineRole
$DomainFullName = $deployConfig.parameters.domainName
$DName = $DomainFullName.Split(".")[0]
$CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }
$CMUser = "$DName\admin"
$DPMPName = $deployConfig.parameters.DPMPName
$ClientName = $deployConfig.parameters.DomainMembers
$CSName = $deployConfig.parameters.CSName
$PSName = $deployConfig.parameters.PSName

$UpdateToLatest = $deployConfig.cmOptions.updateToLatest

$SMSInstallDir="C:\Program Files\Microsoft Configuration Manager"

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }

if ($ThisVM.cmInstallDir) {
    $SMSInstallDir = $ThisVM.cmInstallDir
}

if ($ThisVM.siteCode) {
    $SiteCode = $ThisVM.siteCode
}

$logpath = $ProvisionToolPath+"\InstallSCCMlog.txt"
$ConfigurationFile = Join-Path -Path $ProvisionToolPath -ChildPath "$SiteCode.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

$Configuration.InstallSCCM.Status = 'Running'
$Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Write Setup entry, which causes the job on host to overwrite this with the entries from ConfigMgrSetup.log
Write-DscStatusSetup

$cmpath = "c:\temp\$CM.exe"
$cmsourcepath = "c:\$CM"
if(!(Test-Path $cmpath))
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Copying SCCM installation source..." | Out-File -Append $logpath
    $cmurl = "https://go.microsoft.com/fwlink/?linkid=2093192"
    Start-BitsTransfer -Source $cmurl -Destination $cmpath -Priority Foreground -ErrorAction Stop
    if(!(Test-Path $cmsourcepath))
    {
        Start-Process -Filepath ($cmpath) -ArgumentList ('/Auto "' + $cmsourcepath + '"') -wait
    }
}
$CMINIPath = "c:\$CM\Standalone.ini"
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Check ini file." | Out-File -Append $logpath

$cmini = @'
[Identification]
Action=InstallPrimarySite

[Options]
ProductID=EVAL
SiteCode=%Role%
SiteName=%Role%
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
DatabaseName=%SQLInstance%CM_%Role%
SQLSSBPort=4022
SQLDataFilePath=%SQLDataFilePath%
SQLLogFilePath=%SQLLogFilePath%

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
$inst = (get-itemproperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances[0]
$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$inst

$sqlinfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$p\$inst"

"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ini file exist." | Out-File -Append $logpath
$cmini = $cmini.Replace('%InstallDir%',$SMSInstallDir)
$cmini = $cmini.Replace('%MachineFQDN%',"$env:computername.$DomainFullName")
$cmini = $cmini.Replace('%SQLMachineFQDN%',"$env:computername.$DomainFullName")
$cmini = $cmini.Replace('%Role%',$SiteCode)
$cmini = $cmini.Replace('%SQLDataFilePath%',$sqlinfo.DefaultData)
$cmini = $cmini.Replace('%SQLLogFilePath%',$sqlinfo.DefaultLog)
$cmini = $cmini.Replace('%CM%',$CM)

if(!(Test-Path C:\$CM\Redist))
{
    New-Item C:\$CM\Redist -ItemType directory | Out-Null
}

if($inst.ToUpper() -eq "MSSQLSERVER")
{
    $cmini = $cmini.Replace('%SQLInstance%',"")
}
else
{
    $tinstance = $inst.ToUpper() + "\"
    $cmini = $cmini.Replace('%SQLInstance%',$tinstance)
}
$CMInstallationFile = "c:\$CM\SMSSETUP\BIN\X64\Setup.exe"
$cmini > $CMINIPath
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Installing.." | Out-File -Append $logpath
Start-Process -Filepath ($CMInstallationFile) -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -wait

"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Finished installing CM." | Out-File -Append $logpath
Write-DscStatus "Installation finished."

Remove-Item $CMINIPath

$Configuration.InstallSCCM.Status = 'Completed'
$Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force


$SiteCode =  Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'

$ProviderMachineName = $env:COMPUTERNAME+"."+$DomainFullName # SMS Provider machine name

# Customizations
$key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
$subKey =  $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
$uiInstallPath = $subKey.GetValue("UI Installation Directory")
$modulePath = $uiInstallPath+"bin\ConfigurationManager.psd1"
# Import the ConfigurationManager.psd1 module
if((Get-Module ConfigurationManager) -eq $null) {
    Import-Module $modulePath
}
$initParams = @{}

# Connect to the site's drive if it is not already present
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Setting PS Drive..." | Out-File -Append $logpath
New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams

while($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue))
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Retry in 10s to set PS Drive. Please wait." | Out-File -Append $logpath
    Start-Sleep -Seconds 10
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams

#Add domain user as CM administrative user
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Setting $CMUser as CM administrative user." | Out-File -Append $logpath
New-CMAdministrativeUser -Name $CMUser -RoleName "Full Administrator" -SecurityScopeName "All","All Systems","All Users and User Groups"
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Done" | Out-File -Append $logpath

#Add cm_svc user as a CM Account
if (Test-Path "C:\staging\DSC\cm_svc.txt") {
    $cm_svc = $DomainFullName.Split(".")[0] + "\cm_svc"
    $secure = Get-Content "C:\staging\DSC\cm_svc.txt" | ConvertTo-SecureString -AsPlainText -Force
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Setting cm_svc domain account as CM account." | Out-File -Append $logpath
    New-CMAccount -Name $cm_svc -Password $secure -SiteCode $SiteCode -Confirm:$false
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Done" | Out-File -Append $logpath
    Remove-Item -Path "C:\staging\DSC\cm_svc.txt" -Force -Confirm:$false
}

# Upgrade to latest
if (-not $UpdateToLatest) {
    Write-DscStatus "Installation finished."
    return
}

$upgradingfailed = $false
$originalbuildnumber = ""

#Upgrade SCCM
$Configuration.UpgradeSCCM.Status = 'Running'
$Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

Start-Sleep -Seconds 120
$logpath = $ProvisionToolPath+"\UpgradeCMlog.txt"

#Wait for SMS_DMP_DOWNLOADER running
Write-DscStatus "Checking for updates. Waiting for DMP Downloader."
$counter = 0
$key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$subKey =  $key.OpenSubKey("SOFTWARE\Microsoft\SMS\Components\SMS_Executive\Threads\SMS_DMP_DOWNLOADER")
$DMPState = $subKey.GetValue("Current State")
while($DMPState -ne "Running")
{
    $counter += 1
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Current SMS_DMP_DOWNLOADER state is : $DMPState , will try again 30 seconds later..." | Out-File -Append $logpath
    Start-Sleep -Seconds 30
    $DMPState = $subKey.GetValue("Current State")

    if (0 -eq $counter % 10) {
        Restart-Service -DisplayName "SMS_Site_Component_Manager"
        Start-Sleep 120
    }
}

Write-DscStatus "Checking for updates."
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Current SMS_DMP_DOWNLOADER state is : $DMPState " | Out-File -Append $logpath

#get the available update
function getupdate()
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Get CM update..." | Out-File -Append $logpath
    $CMPSSuppressFastNotUsedCheck = $true
    $updatepacklist= Get-CMSiteUpdate -Fast | Where-Object {$_.State -ne 196612}
    $getupdateretrycount = 0
    while($updatepacklist.Count -eq 0)
    {
        if($getupdateretrycount -eq 3)
        {
            break
        }
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Not found any updates, retry to invoke update check." | Out-File -Append $logpath
        $getupdateretrycount++
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Invoke CM Site update check..." | Out-File -Append $logpath
        Invoke-CMSiteUpdateCheck -ErrorAction Ignore
        Start-Sleep 120

        $updatepacklist= Get-CMSiteUpdate | Where-Object {$_.State -ne 196612}
    }

    $updatepack=""

    if($updatepacklist.Count -eq 0)
    {
    }
    elseif($updatepacklist.Count -eq 1)
    {
        $updatepack= $updatepacklist
    }
    else
    {
        $updatepack= ($updatepacklist | Sort-Object -Property fullversion)[-1]
    }
    return $updatepack
}

#----------------------------------------------------
$state=@{
    0 = 'UNKNOWN'
    2 = 'ENABLED'
    #DMP DOWNLOAD
    262145 = 'DOWNLOAD_IN_PROGRESS'
    262146 = 'DOWNLOAD_SUCCESS'
    327679 = 'DOWNLOAD_FAILED'
    #APPLICABILITY
    327681 = 'APPLICABILITY_CHECKING'
    327682 = 'APPLICABILITY_SUCCESS'
    393213 ='APPLICABILITY_HIDE'
    393214 = 'APPLICABILITY_NA'
    393215 = 'APPLICABILITY_FAILED'
    #CONTENT
    65537 = 'CONTENT_REPLICATING'
    65538 = 'CONTENT_REPLICATION_SUCCESS'
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
$starttime= Get-Date
$sites= Get-CMSite
if($originalbuildnumber -eq "")
{
    if($sites.count -eq 1)
    {
        $originalbuildnumber = $sites.BuildNumber
    }
    else
    {
        $originalbuildnumber = $sites[0].BuildNumber
    }
}

#----------------------------------------------------
$retrytimes = 0
$downloadretrycount = 0
$updatepack = getupdate
if($updatepack -ne "")
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Update package is " + $updatepack.Name | Out-File -Append $logpath
    Write-DscStatus "Found $($updatepack.Name) update."
}
else
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] No update package be found." | Out-File -Append $logpath
}
while($updatepack -ne "")
{
    if($retrytimes -eq 3)
    {
        $upgradingfailed = $true
        break
    }
    $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
    while($updatepack.State -eq 327682 -or $updatepack.State -eq 262145 -or $updatepack.State -eq 327679)
    {
        #package not downloaded
        if($updatepack.State -eq 327682)
        {
            Invoke-CMSiteUpdateDownload -Name $updatepack.Name -Force -WarningAction SilentlyContinue
            Start-Sleep 120
            $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
            $downloadstarttime = get-date
            while($updatepack.State -eq 327682)
            {
                Write-DscStatus "Starting $($updatepack.Name) download"
                "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Waiting SCCM Upgrade package start to download, sleep 2 min..." | Out-File -Append $logpath
                Start-Sleep 120
                $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
                $downloadspan = New-TimeSpan -Start $downloadstarttime -End (Get-Date)
                if($downloadspan.Hours -ge 1)
                {
                    Restart-Service -DisplayName "SMS_Executive"
                    $downloadretrycount++
                    Start-Sleep 120
                    $downloadstarttime = get-date
                }
                if($downloadretrycount -ge 2)
                {
                    Write-DscStatus "$($updatepack.Name) download failed to start."
                    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Update package " + $updatepack.Name + " failed to start downloading in 2 hours."| Out-File -Append $logpath
                    break
                }
            }
        }

        if($downloadretrycount -ge 2)
        {
            break
        }

        #waiting package downloaded
        $downloadstarttime = get-date
        while($updatepack.State -eq 262145)
        {
            Write-DscStatus "Downloading $($updatepack.Name)."
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Waiting SCCM Upgrade package download, sleep 2 min..." | Out-File -Append $logpath
            Start-Sleep 120
            $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
            $downloadspan = New-TimeSpan -Start $downloadstarttime -End (Get-Date)
            if($downloadspan.Hours -ge 1)
            {
                Restart-Service -DisplayName "SMS_Executive"
                Start-Sleep 120
                $downloadstarttime = get-date
            }
        }

        #downloading failed
        if($updatepack.State -eq 327679)
        {
            $retrytimes++
            Start-Sleep 300
            continue
        }
    }

    if($downloadretrycount -ge 2)
    {
        break
    }

    #trigger prerequisites check after the package downloaded
    Invoke-CMSiteUpdatePrerequisiteCheck -Name $updatepack.Name
    while($updatepack.State -ne 196607 -and $updatepack.State -ne 131074 -and $updatepack.State -ne 131075)
    {

        Write-DscStatus "Updating to $($updatepack.Name). Current State: $($state[$updatepack.State])"
        ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Waiting checking prerequisites complete, current pack " + $updatepack.Name + " state is " + ($state.($updatepack.State)) + ", sleep 2 min...") | Out-File -Append $logpath
        Start-Sleep 120
        $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
    }
    if($updatepack.State -eq 196607)
    {
        $retrytimes++
        Start-Sleep 300
        continue
    }
    #trigger setup after the prerequisites check
    Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
    while($updatepack.State -ne 196607 -and $updatepack.State -ne 262143 -and $updatepack.State -ne 196612)
    {
        Write-DscStatus "Updating to $($updatepack.Name). Current State: $($state[$updatepack.State])"
        ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Waiting SCCM Upgrade Complete, current pack " + $updatepack.Name + " state is " + ($state.($updatepack.State)) + ", sleep 2 min...") | Out-File -Append $logpath
        Start-Sleep 120
        $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
    }
    if($updatepack.State -eq 196612)
    {
        Write-DscStatus "Updating to $($updatepack.Name). Current State: $($state[$updatepack.State])"
        ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] SCCM Upgrade Complete, current pack " + $updatepack.Name + " state is " + ($state.($updatepack.State)) ) | Out-File -Append $logpath
        #we need waiting the copying files finished if there is only one site
        $toplevelsite =  Get-CMSite | Where-Object {$_.ReportingSiteCode -eq ""}
        if((Get-CMSite).count -eq 1)
        {
            $path= Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory'

            $fileversion=(Get-Item ($path+'\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]
            while($fileversion -ne $toplevelsite.BuildNumber)
            {
                Start-Sleep 120
                $fileversion=(Get-Item ($path+'\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]
            }
            #Wait for copying files finished
            Start-Sleep 600
        }
        #Get if there are any other updates need to be installed
        $updatepack = getupdate
        if($updatepack -ne "")
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Found another update package : " + $updatepack.Name | Out-File -Append $logpath
        }
    }
    if($updatepack.State -eq 196607 -or $updatepack.State -eq 262143 )
    {
        if($retrytimes -le 3)
        {
            $retrytimes++
            Start-Sleep 300
            continue
        }
    }
}

if($upgradingfailed -eq $true)
{
    Write-DscStatus "Upgrade to $($updatepack.Name) failed."
    ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Upgrade " + $updatepack.Name + " failed") | Out-File -Append $logpath
    if($($updatepack.Name).ToLower().Contains("hotfix"))
    {
        ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] This is a hotfix, skip it and continue...") | Out-File -Append $logpath
        $Configuration.UpgradeSCCM.Status = 'CompletedWithHotfixInstallFailed'
    }
    else
    {
        $Configuration.UpgradeSCCM.Status = 'Error'
        $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
        throw
    }
}
else
{
    Write-DscStatus "Updating to $($updatepack.Name). Current State: $($state[$updatepack.State])"
    $Configuration.UpgradeSCCM.Status = 'Completed'
}

if($downloadretrycount -ge 2)
{
    Write-DscStatus "Failed to download $($updatepack.Name)"
    ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Upgrade " + $updatepack.Name + " failed to start downloading") | Out-File -Append $logpath
    $Configuration.UpgradeSCCM.Status = 'CompletedWithDownloadFailed'
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    throw
}

$Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force