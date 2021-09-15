param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$DomainFullName = $deployConfig.parameters.domainName
$CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
$UpdateToLatest = $deployConfig.cmOptions.updateToLatest
$CSName = $deployConfig.parameters.CSName
$CSVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $CSName }
$CSSiteCode = $CSVM.siteCode

# Set Install Dir
$SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
if ($ThisVM.cmInstallDir) {
    $SMSInstallDir = $ThisVM.cmInstallDir
}

# Set Site Code
if ($ThisVM.siteCode) {
    $SiteCode = $ThisVM.siteCode
}

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# Set Install action as Running
$Configuration.WaitingForCASFinsihedInstall.Status = 'Running'
$Configuration.WaitingForCASFinsihedInstall.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Read Actions file on CS
$LogFolder = Split-Path $LogPath -Leaf
$CSFilePath = "\\$CSName\$LogFolder"
$CSConfigurationFile = Join-Path -Path $CSFilePath -ChildPath "ScriptWorkflow.json"

# Wait for ScriptWorkflow.json to exist on CS
Write-DscStatus "Waiting for $CSName to begin installation"
while(!(Test-Path $CSConfigurationFile))
{
    Write-DscStatus "Waiting for $CSName to begin installation" -NoLog -RetrySeconds 60
    Start-Sleep -Seconds 60
}

# Read CS actions file, wait for install to finish
Write-DscStatus "Waiting for $CSName to finish installing ConfigMgr"
$CSConfiguration = Get-Content -Path $CSConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
while($CSConfiguration.$("InstallSCCM").Status -ne "Completed")
{
    Write-DscStatus "Waiting for $CSName to finish installing ConfigMgr" -NoLog -RetrySeconds 60
    Start-Sleep -Seconds 60
    $CSConfiguration = Get-Content -Path $CSConfigurationFile | ConvertFrom-Json
}

if ($UpdateToLatest) {
    # Read CS actions file, wait for upgrade to finish
    Write-DscStatus "Waiting for $CSName to finish upgrading ConfigMgr"
    $CSConfiguration = Get-Content -Path $CSConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
    while($CSConfiguration.$("UpgradeSCCM").Status -ne "Completed")
    {
        Write-DscStatus "Waiting for $CSName to finish upgrading ConfigMgr" -NoLog -RetrySeconds 60
        Start-Sleep -Seconds 60
        $CSConfiguration = Get-Content -Path $CSConfigurationFile | ConvertFrom-Json
    }
}

# Write actions file, wait finished
$Configuration.WaitingForCASFinsihedInstall.Status = 'Completed'
$Configuration.WaitingForCASFinsihedInstall.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Create $CM dir, before creating the ini
if(!(Test-Path C:\$CM))
{
    New-Item C:\$CM -ItemType directory | Out-Null
}

# Set cource path
Write-DscStatus "Creating HierarchyPS.ini file"

$CMINIPath = "c:\$CM\HierarchyPS.ini"

$cmini = @'
[Identification]
Action=InstallPrimarySite
CDLatest=1

[Options]
ProductID=EVAL
SiteCode=%Role%
SiteName=%Role%
SMSInstallDir=%InstallDir%
SDKServer=%MachineFQDN%
RoleCommunicationProtocol=HTTPorHTTPS
ClientsUsePKICertificate=0
PrerequisiteComp=1
PrerequisitePath=%REdistPath%
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
CloudConnector=0
CloudConnectorServer=
UseProxy=0
ProxyName=
ProxyPort=

[SystemCenterOptions]
SysCenterId=

[HierarchyExpansionOption]
CCARSiteServer=%CASMachineFQDN%

'@

# Get SQL instance info
$inst = (get-itemproperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances[0]
$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$inst
$sqlinfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$p\$inst"

# Set CM Source Path
$cmsourcepath = "\\$CSName\SMS_$CSSiteCode\cd.latest"

# Set ini values
$cmini = $cmini.Replace('%InstallDir%',$SMSInstallDir)
$cmini = $cmini.Replace('%MachineFQDN%',"$env:computername.$DomainFullName")
$cmini = $cmini.Replace('%SQLMachineFQDN%',"$env:computername.$DomainFullName")
$cmini = $cmini.Replace('%Role%',$SiteCode)
$cmini = $cmini.Replace('%SQLDataFilePath%',$sqlinfo.DefaultData)
$cmini = $cmini.Replace('%SQLLogFilePath%',$sqlinfo.DefaultLog)
$cmini = $cmini.Replace('%CASMachineFQDN%',"$CSName.$DomainFullName")
$cmini = $cmini.Replace('%REdistPath%',"$cmsourcepath\REdist")

if($inst.ToUpper() -eq "MSSQLSERVER")
{
    $cmini = $cmini.Replace('%SQLInstance%',"")
}
else
{
    $tinstance = $inst.ToUpper() + "\"
    $cmini = $cmini.Replace('%SQLInstance%',$tinstance)
}

# Create ini
$cmini > $CMINIPath

# Set env var to disable open file security warning, otherwise PS hangs in background
$env:SEE_MASK_NOZONECHECKS = 1

# Install CM
$CMInstallationFile = "$cmsourcepath\SMSSETUP\BIN\X64\Setup.exe"

# Write Setup entry, which causes the job on host to overwrite status with entries from ConfigMgrSetup.log
Write-DscStatusSetup

Start-Process -Filepath ($CMInstallationFile) -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -wait

Write-DscStatus "Installation finished."
Start-Sleep -Seconds 5

# Delete ini file?
# Remove-Item $CMINIPath

# Wait for Site ready
$CSConfiguration = Get-Content -Path $CSConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
Write-DscStatus "Waiting for $CSName to indicate PS is ready to use"
while($CSConfiguration.$("PSReadytoUse").Status -ne "Completed")
{
    Write-DscStatus "Waiting for $CSName to indicate PS is ready to use" -NoLog -RetrySeconds 60
    Start-Sleep -Seconds 60
    $CSConfiguration = Get-Content -Path $CSConfigurationFile | ConvertFrom-Json
}

$Configuration.InstallSCCM.Status = 'Completed'
$Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
