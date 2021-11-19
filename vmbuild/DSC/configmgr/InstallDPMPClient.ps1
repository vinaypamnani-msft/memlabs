param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.parameters.domainName
$DomainName = $DomainFullName.Split(".")[0]
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }

# DPs
$DPNames = @()
$DPNames += ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DPMP" -and $_.siteCode -eq $($ThisVM.siteCode) -and ($_.installDP -eq $true) }).vmName # DP's in current config
# $DPNames += ($deployConfig.existingVMs | Where-Object { $_.role -eq "DPMP" -and $_.siteCode -eq $($ThisVM.siteCode) -and ($_.installDP -eq $true -or $null -eq $_.installDP) }).vmName # Existing DP's from previous deployments with siteCode

# MPs
$MPNames = @()
$MPNames += ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DPMP" -and $_.siteCode -eq $($ThisVM.siteCode) -and ($_.installMP -eq $true) }).vmName # MP's in current config
# $MPNames += ($deployConfig.existingVMs | Where-Object { $_.role -eq "DPMP" -and $_.siteCode -eq $($ThisVM.siteCode) -and ($_.installMP -eq $true -or $null -eq $_.installMP) }).vmName # Existing MP's from previous deployments with siteCode

# Existing DPMP roles without siteCode property (older deployments) but in the same subnet as Primary
# if ($ThisVM.hidden) {
#     $ThisExistingVM = $deployConfig.existingVMs | Where-Object ($_.vmName -eq $ThisVM.vmName)
#     $DPNames += $deployConfig.existingVMs | Where-Object { $_.role -eq "DPMP" -and $null -eq $_.siteCode -and $_.network -eq $ThisExistingVM.network -and ($_.installDP -eq $true -or $null -eq $_.installDP) }
#     $MPNames += $deployConfig.existingVMs | Where-Object { $_.role -eq "DPMP" -and $null -eq $_.siteCode -and $_.network -eq $ThisExistingVM.network -and ($_.installMP -eq $true -or $null -eq $_.installMP) }
# }

# Trim nulls/blanks
$DPNames = $DPNames | Where-Object { $_ -and $_.Trim() }
$MPNames = $MPNames | Where-Object { $_ -and $_.Trim() }

$ClientNames = $deployConfig.parameters.DomainMembers
$cm_svc = "$DomainName\cm_svc"
$pushClients = $deployConfig.cmOptions.pushClientToDomainMembers
$networkSubnet = $deployConfig.vmOptions.network

# Add DPMP on Site Server if none specified
# if (-not $MPNames) {
#     Write-DscStatus "Client Push is true and no MP's found. Forcing MP Role on $($deployConfig.parameters.ThisMachineName) to allow client push to work."
#     $MPNames += $deployConfig.parameters.ThisMachineName
# }

# if (-not $DPNames) {
#     Write-DscStatus "Client Push is true and no DP's found. Forcing DP Role on $($deployConfig.parameters.ThisMachineName) to allow client push to work."
#     $DPNames += $deployConfig.parameters.ThisMachineName
# }

Write-DscStatus "MP role to be installed on '$($MPNames -join ',')'"
Write-DscStatus "DP role to be installed on '$($DPNames -join ',')'"
Write-DscStatus "Client push candidates are '$ClientNames'"

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
if ($ThisVM.hidden) {
    # Only try this once (in case it failed during initial PS setup when we're re-running DSC)
    $attempts = 10
}

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

# Restart services to make sure push account is acknowledged by CCM
Write-DscStatus "Restarting services"
Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue


function Install-DP {
    param (
        [Parameter()]
        [string]
        $ServerFQDN
    )

    $i = 0
    $installFailure = $false
    $DPFQDN = $ServerFQDN

    do {

        $i++

        # Create Site system Server
        #============
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $DPFQDN"
            New-CMSiteSystemServer -SiteSystemServerName $DPFQDN | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN
        }

        # Install DP
        #============
        $dpinstalled = Get-CMDistributionPoint -SiteSystemServerName $DPFQDN
        if (-not $dpinstalled) {
            Write-DscStatus "DP Role not detected on $DPFQDN. Adding Distribution Point role."
            $Date = [DateTime]::Now.AddYears(30)
            Add-CMDistributionPoint -InputObject $SystemServer -CertificateExpirationTimeUtc $Date | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 60
        }
        else {
            Write-DscStatus "DP Role detected on $DPFQDN"
            $dpinstalled = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress after $i tries, Giving up."
            $installFailure = $true
        }

        Start-Sleep -Seconds 10

    } until ($dpinstalled -or $installFailure)
}

function Install-MP {
    param (
        [Parameter()]
        [string]
        $ServerFQDN
    )

    $i = 0
    $installFailure = $false
    $MPFQDN = $ServerFQDN

    do {

        $i++
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $MPFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $MPFQDN"
            New-CMSiteSystemServer -SiteSystemServerName $MPFQDN | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $MPFQDN
        }

        $mpinstalled = Get-CMManagementPoint -SiteSystemServerName $MPFQDN
        if (-not $mpinstalled) {
            Write-DscStatus "MP Role not detected on $MPFQDN. Adding Management Point role."
            Add-CMManagementPoint -InputObject $SystemServer -CommunicationType Http | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 60
        }
        else {
            Write-DscStatus "MP Role detected on $MPFQDN"
            $mpinstalled = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress after $i tries, Giving up."
            $installFailure = $true
        }

        Start-Sleep -Seconds 10

    } until ($mpinstalled -or $installFailure)
}

foreach ($DPName in $DPNames) {

    if ([string]::IsNullOrWhiteSpace($DPName)) {
        continue
    }

    $DPFQDN = $DPName + "." + $DomainFullName
    Install-DP -ServerFQDN $DPFQDN
}

foreach ($MPName in $MPNames) {

    if ([string]::IsNullOrWhiteSpace($MPName)) {
        continue
    }

    $MPFQDN = $MPName + "." + $DomainFullName
    Install-MP -ServerFQDN $MPFQDN
}

# Force install DP/MP on PS Site Server if none present
$dpCount = (Get-CMDistributionPoint -SiteCode $SiteCode | Measure-Object).Count
$mpCount = (Get-CMManagementPoint -SiteCode $SiteCode | Measure-Object).Count

if ($dpCount -eq 0) {
    Install-DP -ServerFQDN ($ThisMachineName + "." + $DomainFullName)
}

if ($mpCount -eq 0) {
    Install-MP -ServerFQDN ($ThisMachineName + "." + $DomainFullName)
}

# exit if rerunning DSC to add passive site
if ($null -ne $deployConfig.parameters.ExistingActiveName) {
    Write-DscStatus "Skip Client Push since we're adding Passive site server"
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

# Push Clients
#==============
if (-not $pushClients) {
    Write-DscStatus "Skipping Client Push. pushClientToDomainMembers options is set to false."
    $Configuration.InstallClient.Status = 'NotRequested'
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

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
