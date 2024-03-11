#InstallMultiDomainPKI.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.vmOptions.domainName
$DomainName = $DomainFullName.Split(".")[0]
$NetbiosDomainName = $deployConfig.vmOptions.domainNetBiosName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","
$ClientNames = $thisVM.thisParams.ClientPush
$cm_svc = "$DomainFullName\cm_svc"
$pushClients = $deployConfig.cmOptions.pushClientToDomainMembers
$usePKI = $deployConfig.cmOptions.UsePKI
if (-not $usePKI) {
    $usePKI = $false
}
# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

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

$cm_svc_file = "C:\Windows\Temp\ProvisionScript\certauth.txt"
if (Test-Path $cm_svc_file) {
    # Add cm_svc user as a CM Account
    $secure = Get-Content $cm_svc_file | ConvertTo-SecureString -AsPlainText -Force
    Write-DscStatus "Adding $cm_svc domain account as CM account"
    Start-Sleep -Seconds 5
    New-CMAccount -Name $cm_svc -Password $secure -SiteCode $SiteCode *>&1 | Out-File $global:StatusLog -Append
    #Remove-Item -Path $cm_svc_file -Force -Confirm:$false

    # Set client push account
    Write-DscStatus "Setting the Client Push Account"
    Set-CMClientPushInstallation -SiteCode $SiteCode -AddAccount $cm_svc *>&1 | Out-File $global:StatusLog -Append
    Start-Sleep -Seconds 5

    $ForestDiscoveryAccount = "$DomainFullName\admin"

    Write-DscStatus "Creating New-CMActiveDirectoryForest"
    New-CMActiveDirectoryForest -Description "Multi Forest $DomainFullName" -EnableDiscovery $true -UserName $ForestDiscoveryAccount -Password $secure -ForestFqdn $DomainFullName *>&1 | Out-File $global:StatusLog -Append


    $sitedef = Get-CMSiteDefinition -SiteCode $SiteCode

    Write-DscStatus "Enable Discovery Set-CMActiveDirectoryForest"
    Set-CMActiveDirectoryForest -EnableDiscovery $true -Id 2 -AddPublishingSite $sitedef *>&1 | Out-File $global:StatusLog -Append

    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery"
    Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery -SiteCode $SiteCode -Enabled $true -Verbose | Out-File $global:StatusLog -Append

    $DomainA = $DomainFullName.Split(".")[0]
    $DomainB = $DomainFullName.Split(".")[1]
    $LDAPPath = "LDAP://DC=$DomainA,DC=$DomainB"
    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery $LDAPPath"
    Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $sitecode -Enabled $true -addActiveDirectoryContainer @($LDAPPath) -UserName $ForestDiscoveryAccount *>&1 | Out-File $global:StatusLog -Append

    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectoryUserDiscovery $LDAPPath"
    Set-CMDiscoveryMethod -ActiveDirectoryUserDiscovery -SiteCode $sitecode -Enabled $true -AddActiveDirectoryContainer @($LDAPPath) -UserName  $ForestDiscoveryAccount -EnableIncludeGroup $true -EnableRecursive $true -Verbose *>&1 | Out-File $global:StatusLog -Append

    $clients = @($deployConfig.virtualMachines | Where-Object { $_.Role -eq "DomainMember" })
    $networks = @()
    foreach ($client in $clients) {
        Write-DscStatus "Checking $($client.ThisParams.vmNetwork)"
        if (-not ($networks.Contains($($client.ThisParams.vmNetwork)))) {
            $networks += $client.ThisParams.vmNetwork
        }
    }

    foreach ($network in $networks) {
        Write-DscStatus "New Boundary $DomainFullName - $network"
        New-CMBoundary -DisplayName "$DomainFullName - $network" -BoundaryType IPSubNet -Value "$network/24" *>&1 | Out-File $global:StatusLog -Append
        New-CMBoundaryGroup -Name '192.168.2.0' -DefaultSiteCode $sitecode *>&1 | Out-File $global:StatusLog -Append
        Add-CMBoundaryToGroup -BoundaryName "$DomainFullName - $network" -BoundaryGroupName $network *>&1 | Out-File $global:StatusLog -Append
    }
    Write-DscStatus "Set-CMClientPushInstallation $cm_svc"
    Set-CMClientPushInstallation -SiteCode $SiteCode -EnableAutomaticClientPushInstallation $True -AddAccount $cm_svc *>&1 | Out-File $global:StatusLog -Append

    # Restart services to make sure push account is acknowledged by CCM
    Write-DscStatus "Restarting services"
    Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
    Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue
}

# Update actions file
$Configuration.InstallClient.Status = 'Completed'
$Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
