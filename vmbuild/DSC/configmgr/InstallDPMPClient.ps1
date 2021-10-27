param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.parameters.domainName
$DomainName = $DomainFullName.Split(".")[0]
$DPMPName = $deployConfig.parameters.DPMPName
$ClientNames = $deployConfig.parameters.DomainMembers
$cm_svc = "$DomainName\cm_svc"
$installDPMPRoles = $deployConfig.cmOptions.installDPMPRoles
$pushClients = $deployConfig.cmOptions.pushClientToDomainMembers
$networkSubnet = $deployConfig.vmOptions.network

# exit if rerunning DSC to add passive site
if ($null -ne $deployConfig.parameters.ExistingActiveName) {
    Write-DscStatus "Skip DP/MP/Client install since we're adding Passive site server"
    return
}

# overwrite installDPMPRoles to true if client push is true
if ($pushClients) {
    Write-DscStatus "Client Push is true. Forcing installDPMPRoles to true to allow client push to work."
    $installDPMPRoles = $true
}

# No DPMP specified, install on PS site server
if (-not $DPMPName -and $installDPMPRoles) {
    $DPMPName = $deployConfig.parameters.ThisMachineName
    Write-DscStatus "installDPMPRoles is true but no DPMP specified. Installing roles on $DPMPName."
}

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# Read Site Code from registry
Write-DscStatus "Setting PS Drive for ConfigMgr"
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
New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams

while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    Write-DscStatus "Retry in 10s to Set PS Drive" -NoLog
    Start-Sleep -Seconds 10
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams


$cm_svc_file = "$LogPath\cm_svc.txt"
if (Test-Path $cm_svc_file) {
    # Add cm_svc user as a CM Account
    $secure = Get-Content $cm_svc_file | ConvertTo-SecureString -AsPlainText -Force
    Write-DscStatus "Adding cm_svc domain account as CM account"
    Start-Sleep -Seconds 5
    New-CMAccount -Name $cm_svc -Password $secure -SiteCode $SiteCode | Out-File $global:StatusLog -Append
    Remove-Item -Path $cm_svc_file -Force -Confirm:$false

    # Set client push account
    Write-DscStatus "Setting the Client Push Account"
    Set-CMClientPushInstallation -SiteCode $SiteCode -AddAccount $cm_svc
    Start-Sleep -Seconds 5
}

# Enable EHTTP, some components are still installing and they reset it to Disabled.
# Keep setting it every 30 seconds, 10 times and bail...
$attempts = 0
$enabled = $false
Write-DscStatus "Enabling e-HTTP"
do {
    $attempts++
    Set-CMSite -SiteCode $SiteCode -UseSmsGeneratedCert $true -Verbose | Out-File $global:StatusLog -Append
    Start-Sleep 30
    $prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
    $enabled = ($prop.Value -band 1024) -eq 1024
    Write-DscStatus "IISSSLState Value is $($prop.Value). e-HTTP enabled: $enabled" -RetrySeconds 30
} until ($attempts -ge 10)

if (-not $enabled) {
    Write-DscStatus "e-HTTP not enabled after trying $attempts times, skip."
}
else {
    Write-DscStatus "e-HTTP was enabled."
}

# exit if nothing to do
if (-not $installDPMPRoles -and -not $pushClients) {
    Write-DscStatus "Skipping DPMP and Client setup. installDPMPRoles and pushClientToDomainMembers options are set to false."
    $Configuration.InstallClient.Status = 'NotRequested'
    $Configuration.InstallDP.Status = 'NotRequested'
    $Configuration.InstallMP.Status = 'NotRequested'
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

# Restart services to make sure push account is acknowledged by CCM
Write-DscStatus "Restarting services"
Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue

# Create Site system Server
#============
$DPMPFQDN = $DPMPName + "." + $DomainFullName
$SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPMPFQDN
if (!$SystemServer) {
    Write-DscStatus "Creating new CM Site System server on $DPMPFQDN"
    New-CMSiteSystemServer -SiteSystemServerName $DPMPFQDN -AccountName $cm_svc | Out-File $global:StatusLog -Append
    Start-Sleep -Seconds 5
    $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPMPFQDN
}

# Install DP
#============
$Configuration.InstallDP.Status = 'Running'
$Configuration.InstallDP.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

if ((Get-CMDistributionPoint -SiteSystemServerName $DPMPFQDN).count -ne 1) {
    Write-DscStatus "Adding Distribution Point role on $DPMPFQDN"
    $Date = [DateTime]::Now.AddYears(30)
    Add-CMDistributionPoint -InputObject $SystemServer -CertificateExpirationTimeUtc $Date | Out-File $global:StatusLog -Append
    Start-Sleep -Seconds 5

    if ((Get-CMDistributionPoint -SiteSystemServerName $DPMPFQDN).count -eq 1) {
        Write-DscStatus "DP Role added on $DPMPFQDN"
        $Configuration.InstallDP.Status = 'Completed'
        $Configuration.InstallDP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }
    else {
        Write-DscStatus "Failed to add DP Role on $DPMPFQDN"
        $Configuration.InstallDP.Status = 'Failed'
        $Configuration.InstallDP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }
}
else {
    Write-DscStatus "DP Role already installed on $DPMPFQDN"
}

# Install MP
#============
$Configuration.InstallMP.Status = 'Running'
$Configuration.InstallMP.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

if ((Get-CMManagementPoint -SiteSystemServerName $DPMPFQDN).count -ne 1) {

    Write-DscStatus "Adding Management Point role on $DPMPFQDN"
    Add-CMManagementPoint -InputObject $SystemServer -CommunicationType Http | Out-File $global:StatusLog -Append
    Start-Sleep -Seconds 5

    if ((Get-CMManagementPoint -SiteSystemServerName $DPMPFQDN).count -eq 1) {
        Write-DscStatus "MP Role added on $DPMPFQDN"
        $Configuration.InstallMP.Status = 'Completed'
        $Configuration.InstallMP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }
    else {
        Write-DscStatus "Failed to add MP Role on $DPMPFQDN"
        $Configuration.InstallMP.Status = 'Failed'
        $Configuration.InstallMP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }
}
else {
    Write-DscStatus "MP Role already installed on $DPMPFQDN"
}

# Push Clients
#==============
if (-not $pushClients) {
    Write-DscStatus "Skipping Client Push. pushClientToDomainMembers options is set to false."
    $Configuration.InstallClient.Status = 'NotRequested'
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

# Create Boundry Group
Write-DscStatus "Creating Boundary and Boundary Group"
New-CMBoundaryGroup -Name $SiteCode -DefaultSiteCode $SiteCode -AddSiteSystemServerName $DPMPFQDN
New-CMBoundary -Type IPSubnet -Name $networkSubnet -Value "$networkSubnet/24"
Add-CMBoundaryToGroup -BoundaryName $networkSubnet -BoundaryGroupName $SiteCode
Start-Sleep -Seconds 5

# Setup System Discovery
Write-DscStatus "Enabling AD system discovery"
$lastdomainname = $DomainFullName.Split(".")[-1]
do {
    $adiscovery = (Get-CMDiscoveryMethod | Where-Object { $_.ItemName -eq "SMS_AD_SYSTEM_DISCOVERY_AGENT|SMS Site Server" }).Props | Where-Object { $_.PropertyName -eq "Settings" }
    Write-DscStatus "AD System Discovery state is: $($adiscovery.Value1)" -RetrySeconds 30
    Start-Sleep -Seconds 30
    if ($adiscovery.Value1.ToLower() -ne "active") {
        Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $SiteCode -Enabled $true -AddActiveDirectoryContainer "LDAP://DC=$DomainName,DC=$lastdomainname" -Recursive
    }
} until ($adiscovery.Value1.ToLower() -eq "active")

# Run discovery
Write-DscStatus "Invoking AD system discovery"
Start-Sleep -Seconds 5
Invoke-CMSystemDiscovery
Start-Sleep -Seconds 5

# Wait for collection to populate
$CollectionName = "All Systems"
Write-DscStatus "Waiting for clients to appear in '$CollectionName'"
$ClientNameList = $ClientNames.split(",")
$machinelist = (get-cmdevice -CollectionName $CollectionName).Name
Start-Sleep -Seconds 5

foreach ($client in $ClientNameList) {

    if ([string]::IsNullOrWhiteSpace($client)) {
        continue
    }

    $testClient = Test-NetConnection -ComputerName $client -CommonTCPPort SMB -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    if (-not $testClient.TcpTestSucceeded) {
        # Don't wait for client to appear in collection if it's not online
        Write-DscStatus "Could not test SMB connection to $client. Skipping."
        continue
    }

    while ($machinelist -notcontains $client) {
        Invoke-CMSystemDiscovery
        Invoke-CMDeviceCollectionUpdate -Name $CollectionName

        Write-DscStatus "Waiting for $client to appear in '$CollectionName'" -RetrySeconds 60
        Start-Sleep -Seconds 60
        $machinelist = (get-cmdevice -CollectionName $CollectionName).Name
    }

    Write-DscStatus "Pushing client to $client."
    Install-CMClient -DeviceName $client -SiteCode $SiteCode -AlwaysInstallClient $true | Out-File $global:StatusLog -Append
    Start-Sleep -Seconds 5
}

# Update actions file
$Configuration.InstallClient.Status = 'Completed'
$Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
