#InstallMultiDomainPKI.ps1
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

$DC = $deployConfig.virtualMachines | where-object { $_.Role -eq "DC" }

$Externaldomainsitecode = $DC.externalDomainJoinSiteCode


$cm_svc = "$DomainFullName\cm_svc"

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

if (-not $Externaldomainsitecode) {
    Write-DscStatus "ExternalDomainSiteCode is not set. Skipping PKI configuration" -Log
    return
}
else {
    Write-DscStatus "ExternalDomainSiteCode is $Externaldomainsitecode." -Log
}

if ($SiteCode -ne $Externaldomainsitecode) {

    $childSites = (Get-CMSiteDefinition | Where-Object { $_.ParentSiteCode -eq $SiteCode }).Sitecode
    if ($childSites) {
        Write-DscStatus "SiteCode $SiteCode has child sites $childSites. Configuring for ChildSite"        
    }
    else {
        Write-DscStatus "SiteCode $SiteCode is not the external domain site code $Externaldomainsitecode. Skipping PKI configuration"
        return
    }
}


$cm_svc_file = "C:\Windows\Temp\ProvisionScript\certauth.txt"
if (Test-Path $cm_svc_file) {
    # Add cm_svc user as a CM Account
    $secure = Get-Content $cm_svc_file | ConvertTo-SecureString -AsPlainText -Force
    Write-DscStatus "Adding $cm_svc domain account as CM account for sitecode $Externaldomainsitecode" -Log
    Start-Sleep -Seconds 5
    New-CMAccount -Name $cm_svc -Password $secure -SiteCode $Externaldomainsitecode *>&1 | Out-File $global:StatusLog -Append
    #Remove-Item -Path $cm_svc_file -Force -Confirm:$false

    # Set client push account
    #Write-DscStatus "Setting the Client Push Account"
    #Set-CMClientPushInstallation -SiteCode $SiteCode -AddAccount $cm_svc *>&1 | Out-File $global:StatusLog -Append
    #Start-Sleep -Seconds 5

    $ForestDiscoveryAccount = "$DomainFullName\$($deployConfig.vmOptions.adminName)"

    Write-DscStatus "Adding $ForestDiscoveryAccount domain account as CM account for sitecode $SiteCode" -Log
    Start-Sleep -Seconds 5
    New-CMAccount -Name $ForestDiscoveryAccount -Password $secure -SiteCode $Externaldomainsitecode *>&1 | Out-File $global:StatusLog -Append

    Write-DscStatus "Creating New-CMActiveDirectoryForest for domain $DomainFullName" -Log
    try {
        New-CMActiveDirectoryForest -Description "Multi Forest $DomainFullName" -EnableDiscovery $true -UserName $ForestDiscoveryAccount -Password $secure -ForestFqdn $DomainFullName *>&1 | Out-File $global:StatusLog -Append
    }
    catch {
        Write-DscStatus "Failed to create New-CMActiveDirectoryForest for domain $DomainFullName $_" -Log     
    }
    Write-DscStatus "Get-CMSiteDefinition -SiteCode $Externaldomainsitecode" -Log   
    $sitedef = Get-CMSiteDefinition -SiteCode $Externaldomainsitecode

    if (-not $sitedef) {
        Write-DscStatus "Failed to get CMSiteDefinition for sitecode $Externaldomainsitecode" -Log
        return
    }   
    
    Write-DscStatus "Enable Discovery Set-CMActiveDirectoryForest" -Log
    "Set-CMActiveDirectoryForest -EnableDiscovery $true -ForestFQDN $DomainFullName -AddPublishingSite $sitedef" | Out-File $global:StatusLog -Append
    Set-CMActiveDirectoryForest -EnableDiscovery $true -ForestFQDN $DomainFullName -AddPublishingSite $sitedef *>&1 | Out-File $global:StatusLog -Append

    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery for sitecode $sitecode"
    "Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery -SiteCode $sitecode -Enabled $true -Verbose" | Out-File $global:StatusLog -Append
    Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery -SiteCode $sitecode -Enabled $true -Verbose | Out-File $global:StatusLog -Append

    $Domain = $DomainFullName
    $DN = 'DC=' + $Domain.Replace('.',',DC=')   
    $LDAPPath = "LDAP://$DN"
    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery $LDAPPath"
    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $sitecode -Enabled $true -addActiveDirectoryContainer @($LDAPPath) -UserName $ForestDiscoveryAccount -Verbose -EnableIncludeGroup $$true -EnableRecursive $$true"
    Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $sitecode -Enabled $true -addActiveDirectoryContainer @($LDAPPath) -UserName $ForestDiscoveryAccount -EnableIncludeGroup $true -EnableRecursive $true -Verbose *>&1 | Out-File $global:StatusLog -Append

    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectoryUserDiscovery $LDAPPath"
    Set-CMDiscoveryMethod -ActiveDirectoryUserDiscovery -SiteCode $sitecode -Enabled $true -AddActiveDirectoryContainer @($LDAPPath) -UserName $ForestDiscoveryAccount -EnableIncludeGroup $true -EnableRecursive $true -Verbose *>&1 | Out-File $global:StatusLog -Append

    $clients = @($deployConfig.virtualMachines | Where-Object { $_.Role -eq "DomainMember" })
    $networks = @()
    foreach ($client in $clients) {

        $siteServersNetworks = @(($deployConfig.virtualMachines | Where-Object { $_.role -in "Primary", "Secondary" -and -not $_.hidden }).ThisParams.vmNetwork)

        Write-DscStatus "Checking $($client.ThisParams.vmNetwork)"
        if ($($client.ThisParams.vmNetwork) -in $siteServersNetworks) {
            Write-DscStatus "Skipping $($client.vmName) because $($client.ThisParams.vmNetwork) belongs to a local site server"
            continue
        }
        if (-not ($networks.Contains($($client.ThisParams.vmNetwork)))) {
            $networks += $client.ThisParams.vmNetwork
        }
    }

    foreach ($network in $networks) {
        Write-DscStatus "New Boundary $DomainFullName - $network - $Externaldomainsitecode"
        #New-CMBoundary -DisplayName "$DomainFullName - $network" -BoundaryType IPSubNet -Value "$network/24" *>&1 | Out-File $global:StatusLog -Append
        $IP = $network
        $mask = '255.255.255.0'
        $IPBits = [int[]]$IP.Split('.')
        $MaskBits = [int[]]$Mask.Split('.')
        $NetworkIDBits = 0..3 | Foreach-Object { $IPBits[$_] -band $MaskBits[$_] }
        $BroadcastBits = 0..3 | Foreach-Object { $NetworkIDBits[$_] + ($MaskBits[$_] -bxor 255) }
        $NetworkID = $NetworkIDBits -join '.'
        $Broadcast = $BroadcastBits -join '.'

        $sitesystems = @()
        $sitesystems += (Get-CMDistributionPoint -SiteCode $Externaldomainsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems += (Get-CMManagementPoint -SiteCode $Externaldomainsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems += (Get-CMSoftwareUpdatePoint -SiteCode $Externaldomainsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems = $sitesystems | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique

        try {
            "New-CMBoundary -Type IPRange -Name `"$DomainFullName - $network`" -Value `"$($NetworkID)-$($Broadcast)`"" | Out-File $global:StatusLog -Append
            New-CMBoundary -Type IPRange -Name "$DomainFullName - $network" -Value "$($NetworkID)-$($Broadcast)" *>&1 | Out-File $global:StatusLog -Append
        
        }
        catch {
            Write-DscStatus "Failed to create New-CMBoundary for $DomainFullName - $network - $sitecode $_" -Log
        }
        try {
            "New-CMBoundaryGroup -Name `"$DomainFullName - $network`" -DefaultSiteCode $Externaldomainsitecode -AddSiteSystemServerName $sitesystems" | Out-File $global:StatusLog -Append
            New-CMBoundaryGroup -Name "$DomainFullName - $network" -DefaultSiteCode $Externaldomainsitecode -AddSiteSystemServerName $sitesystems *>&1 | Out-File $global:StatusLog -Append
        }
        catch {
            Write-DscStatus "Failed to create New-CMBoundaryGroup for $DomainFullName - $network - $Externaldomainsitecode $_" -Log
        }

        Add-CMBoundaryToGroup -BoundaryName "$DomainFullName - $network" -BoundaryGroupName "$DomainFullName - $network" *>&1 | Out-File $global:StatusLog -Append
        "Add-CMBoundaryToGroup -BoundaryName `"$DomainFullName - $network`" -BoundaryGroupName `"$DomainFullName - $network`"" | Out-File $global:StatusLog -Append
    }
    Write-DscStatus "Set-CMClientPushInstallation $cm_svc"
    $accounts = (get-CMClientPushInstallation -SiteCode $Externaldomainsitecode).EmbeddedPropertyLists.Reserved2.values

    if ($cm_svc -in $accounts) {
        Write-DscStatus "Skip Set-CMClientPushInstallation since $cm_svc already exists"
    }
    else {
        Set-CMClientPushInstallation -SiteCode $Externaldomainsitecode -EnableAutomaticClientPushInstallation $True -AddAccount $cm_svc *>&1 | Out-File $global:StatusLog -Append
    }

    # Restart services to make sure push account is acknowledged by CCM
    Write-DscStatus "Restarting services"
    Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
    Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue
}

# Update actions file
$Configuration.InstallClient.Status = 'Completed'
$Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
