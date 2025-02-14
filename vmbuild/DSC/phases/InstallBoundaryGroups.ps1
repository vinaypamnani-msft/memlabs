#InstallBoundaryGroups.ps1
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
$cm_svc = "$NetbiosDomainName\cm_svc"
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

$cm_svc_file = "$LogPath\cm_svc.txt"
if (Test-Path $cm_svc_file) {
    # Add cm_svc user as a CM Account
    $ExistingAccount = Get-CMAccount | Where-Object { $_.UserName -eq $cm_svc }
    if (-not $ExistingAccount) {
        $secure = Get-Content $cm_svc_file | ConvertTo-SecureString -AsPlainText -Force
        Write-DscStatus "Adding cm_svc domain account as CM account"
        Start-Sleep -Seconds 5
        New-CMAccount -Name $cm_svc -Password $secure -SiteCode $SiteCode *>&1 | Out-File $global:StatusLog -Append
        # Remove-Item -Path $cm_svc_file -Force -Confirm:$false
    }
    $found = $false
    try {
        $accounts = (get-CMClientPushInstallation -SiteCode $Externaldomainsitecode).EmbeddedPropertyLists.Reserved2.values
        if ($cm_svc -in $accounts) {
            $found = $true
        }
        #$found = (Get-CMClientPushInstallation).PropLists.Values -contains $cm_svc
    }
    catch {}

    if (-not $found) {
        # Set client push account
        Write-DscStatus "Setting the Client Push Account"
        Set-CMClientPushInstallation -EnableAutomaticClientPushInstallation $True -SiteCode $SiteCode -AddAccount $cm_svc
        Start-Sleep -Seconds 5

        # Restart services to make sure push account is acknowledged by CCM
        Write-DscStatus "Restarting services"
        Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
        Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue    
    }
}


$ValidSiteCodes = @($SiteCode)
$ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
$ValidSiteCodes += $ReportingSiteCodes


Write-DscStatus "Client push candidates are '$ClientNames'"


# Create Boundary groups
$bgs = $ThisVM.thisParams.sitesAndNetworks | Where-Object { $_.SiteCode -in $ValidSiteCodes }
$bgsCount = $bgs.count
Write-DscStatus "Create $bgsCount Boundary Groups for site $SiteCode"
foreach ($bgsitecode in ($bgs.SiteCode | Select-Object -Unique)) {
    $siteStatus = Get-CMSite -SiteCode $bgsitecode
    if ($siteStatus.Status -eq 1) {
        $sitesystems = @()
        $sitesystems += (Get-CMDistributionPoint -SiteCode $bgsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems += (Get-CMManagementPoint -SiteCode $bgsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems += (Get-CMSoftwareUpdatePoint -SiteCode $bgsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems = $sitesystems | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
        try {
            $exists = Get-CMBoundaryGroup -Name $bgsitecode
            if ($exists) {
                Write-DscStatus "Updating Boundary Group '$bgsitecode' with Site Systems $($sitesystems -join ',') in sitecode $SiteCode"
                Set-CMBoundaryGroup -Name $bgsiteCode -AddSiteSystemServerName $sitesystems
            }
            else {
                Write-DscStatus "Creating Boundary Group '$bgsitecode' with Site Systems $($sitesystems -join ',') in sitecode $SiteCode"
                #New-CMBoundaryGroup -Name $bgsitecode -DefaultSiteCode $SiteCode -AddSiteSystemServerName $sitesystems
                New-CMBoundaryGroup -Name $bgsitecode -DefaultSiteCode $bgsitecode -AddSiteSystemServerName $sitesystems
            }
        }
        catch {
            Write-DscStatus "Failed to create Boundary Group '$bgsitecode' in sitecode $siteCode. Error: $_"
        }
    }
    else {
        Write-DscStatus "Skip creating Boundary groups for site $bgsitecode because Site Status for sitecode $siteCode is not 'Active'."
    }
    Start-Sleep -Seconds 5
}

# Create Boundaries for each subnet and add to BG
Write-DscStatus "Create Boundaries for each subnet and add to BG"
foreach ($bg in $bgs) {
    $exists = Get-CMBoundary -BoundaryName $bg.Subnet
    if ($exists) {
        try {
            Write-DscStatus "Adding Boundary $($bg.SiteCode) with subnet $($bg.Subnet) to Boundary Group $($bg.SiteCode)"
            Add-CMBoundaryToGroup -BoundaryName $bg.Subnet -BoundaryGroupName $bg.SiteCode
        }
        catch {
            Write-DscStatus "Failed to add boundary '$($bg.Subnet)' to Boundary Group '$($bg.SiteCode)'. Error: $_"
        }
    }
    else {
        try {
            Write-DscStatus "Creating Boundary $($bg.SiteCode) with subnet $($bg.Subnet)"
            #New-CMBoundary -Type IPSubnet -Name $bg.Subnet -Value "$($bg.Subnet)/24"
            $IP = $bg.Subnet
            $mask = '255.255.255.0'
            $IPBits = [int[]]$IP.Split('.')
            $MaskBits = [int[]]$Mask.Split('.')
            $NetworkIDBits = 0..3 | Foreach-Object { $IPBits[$_] -band $MaskBits[$_] }
            $BroadcastBits = 0..3 | Foreach-Object { $NetworkIDBits[$_] + ($MaskBits[$_] -bxor 255) }
            $NetworkID = $NetworkIDBits -join '.'
            $Broadcast = $BroadcastBits -join '.'
            New-CMBoundary -Type IPRange -Name $bg.Subnet -Value "$($NetworkID)-$($Broadcast)"
            try {
                Write-DscStatus "Adding Boundary $($bg.SiteCode) with subnet $($bg.Subnet) to Boundary Group $($bg.SiteCode)"
                Add-CMBoundaryToGroup -BoundaryName $bg.Subnet -BoundaryGroupName $bg.SiteCode
            }
            catch {
                Write-DscStatus "Failed to add boundary '$($bg.Subnet)' to Boundary Group '$($bg.SiteCode)'. Error: $_"
            }
        }
        catch {
            Write-DscStatus "Failed to create boundary '$($bg.Subnet)'. Error: $_"
        }
    }

    Start-Sleep -Seconds 5
}

# Setup System Discovery
Write-DscStatus "Enabling AD system discovery"
$lastdomainname = $DomainFullName.Split(".")[-1]
do {
    $adiscovery = (Get-CMDiscoveryMethod | Where-Object { $_.ItemName -eq "SMS_AD_SYSTEM_DISCOVERY_AGENT|SMS Site Server" }).Props | Where-Object { $_.PropertyName -eq "Settings" }

    if ($adiscovery.Value1.ToLower() -ne "active") {
        Write-DscStatus "AD System Discovery state is: $($adiscovery.Value1)" -RetrySeconds 30
        Start-Sleep -Seconds 30
        Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $SiteCode -Enabled $true -AddActiveDirectoryContainer "LDAP://DC=$DomainName,DC=$lastdomainname" -Recursive
    }
    else {
        Write-DscStatus "AD System Discovery state is: $($adiscovery.Value1)"
    }
} until ($adiscovery.Value1.ToLower() -eq "active")

# Setup SG Discovery
Write-DscStatus "Enabling AD Group discovery"
do {
    $adsgdiscovery = (Get-CMDiscoveryMethod | Where-Object { $_.ItemName -eq "SMS_AD_SECURITY_GROUP_DISCOVERY_AGENT|SMS Site Server" }).Props | Where-Object { $_.PropertyName -eq "Settings" }

    if ($adsgdiscovery.Value1.ToLower() -ne "active") {

        Write-DscStatus "AD Group Discovery state is: $($adiscovery.Value1)" -RetrySeconds 30
        Start-Sleep -Seconds 30
        $sgscope = New-CMADGroupDiscoveryScope -name Allscope -SiteCode $SiteCode -LdapLocation "LDAP://DC=$DomainName,DC=$lastdomainname" -RecursiveSearch $true -Verbose
        Set-CMDiscoveryMethod -ActiveDirectoryGroupDiscovery -AddGroupDiscoveryScope $sgscope -Enabled $true -Verbose
    }
    else {
        Write-DscStatus "AD System Discovery state is: $($adsgdiscovery.Value1)"
    }
} until ($adsgdiscovery.Value1.ToLower() -eq "active")

# Run discovery
Write-DscStatus "Invoking AD system discovery"
Invoke-CMSystemDiscovery
Start-Sleep -Seconds 5

if ($ThisVm.thisParams.PassiveNode) {
    Write-DscStatus "Skip Client Push since we're adding Passive site server"
    $pushClients = $false
    #return
}

# Push Clients
#==============
if (-not $pushClients) {
    Write-DscStatus "Skipping Client Push. pushClientToDomainMembers options is set to false."
    $Configuration.InstallClient.Status = 'NotRequested'
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}




# Wait for collection to populate

if ($ClientNames) {

    $PackageID = (Get-CMPackage -Fast -Name 'Configuration Manager Client Package').PackageID
    $PackageSuccess = (Get-CMDistributionStatus -Id $PackageID).NumberSuccess
    if ($PackageSuccess -eq 0) {
        $CollectionName = "All Systems"
        Update-CMDistributionPoint -PackageName "Configuration Manager Client Package"
        Invoke-CMSystemDiscovery
        Invoke-CMDeviceCollectionUpdate -Name $CollectionName


        if ($false) {
            #Let PushClients.ps1 handle this later.
            $failCount = 0
            $success = $false
            while (-not $success) {
   
                $failCount++
                Write-DscStatus "Waiting for Client Package to appear on any DP. $failcount / 15"
                $PackageID = (Get-CMPackage -Fast -Name 'Configuration Manager Client Package').PackageID
                Start-Sleep -Seconds 30
                $PackageSuccess = (Get-CMDistributionStatus -Id $PackageID).NumberSuccess
                $success = $PackageSuccess -ge 1

                if ($failCount -ge 15) {
                    $success = $true   
                }
    
            }
            Write-DscStatus "Waiting for $ClientNames to appear in '$CollectionName'"
        }
    }
}
else {
    Write-DscStatus "Skipping Client Push. No Clients to push."
    $Configuration.InstallClient.Status = 'Completed'
    $Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

if ($false) {
    #Let PushClients.ps1 handle this later.
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

        $failCount = 0
        $success = $true
        while ($machinelist -notcontains $client) {
       
            if ($failCount -ge 2) {
                $success = $false
                break
            }
            Invoke-CMSystemDiscovery
            Invoke-CMDeviceCollectionUpdate -Name $CollectionName


            $seconds = 600
            while ($seconds -ge 0) {
                Write-DscStatus "Waiting for $client to appear in '$CollectionName'" -RetrySeconds 30
                Start-Sleep -Seconds 30
                $seconds -= 30
                $machinelist = (get-cmdevice -CollectionName $CollectionName).Name
                if ($machinelist -contains $client) {
                    Write-DscStatus "$client is in'$CollectionName'"
                    break
                }
            }

            $machinelist = (get-cmdevice -CollectionName $CollectionName).Name
            $failCount++
        }
        if ($success) {
            Write-DscStatus "Pushing client to $client."
            Install-CMClient -DeviceName $client -SiteCode $SiteCode -AlwaysInstallClient $true *>&1 | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 5
        }
    }



    # Update actions file
    $Configuration.InstallClient.Status = 'Completed'
    $Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
}