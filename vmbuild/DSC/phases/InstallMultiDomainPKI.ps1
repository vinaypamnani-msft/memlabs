#InstallMultiDomainPKI.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.vmOptions.domainName


$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

$DC = $deployConfig.virtualMachines | where-object { $_.Role -eq "DC" }

$Externaldomainsitecode = $DC.externalDomainJoinSiteCode


$cm_svc = "$DomainFullName\cm_svc"

# Resolve per-VM cmOptions (multi-hierarchy safe).
$cmo = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
$usePKI = $cmo.UsePKI
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
    Write-DscStatus "ExternalDomainSiteCode is not set. Skipping PKI configuration"
    return
}
else {
    Write-DscStatus "ExternalDomainSiteCode is $Externaldomainsitecode."
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
    Write-DscStatus "Adding $cm_svc domain account as CM account for sitecode $Externaldomainsitecode"
    Start-Sleep -Seconds 5
    New-CMAccount -Name $cm_svc -Password $secure -SiteCode $Externaldomainsitecode *>&1 | Write-StatusLogEntry
    #Remove-Item -Path $cm_svc_file -Force -Confirm:$false

    # Set client push account
    #Write-DscStatus "Setting the Client Push Account"
    #Set-CMClientPushInstallation -SiteCode $SiteCode -AddAccount $cm_svc *>&1 | Write-StatusLogEntry
    #Start-Sleep -Seconds 5

    $ForestDiscoveryAccount = "$DomainFullName\$($deployConfig.vmOptions.adminName)"

    Write-DscStatus "Adding $ForestDiscoveryAccount domain account as CM account for sitecode $SiteCode"
    Start-Sleep -Seconds 5
    New-CMAccount -Name $ForestDiscoveryAccount -Password $secure -SiteCode $Externaldomainsitecode *>&1 | Write-StatusLogEntry

    Write-DscStatus "Creating New-CMActiveDirectoryForest for domain $DomainFullName"
    try {
        New-CMActiveDirectoryForest -Description "Multi Forest $DomainFullName" -EnableDiscovery $true -UserName $ForestDiscoveryAccount -Password $secure -ForestFqdn $DomainFullName *>&1 | Write-StatusLogEntry
    }
    catch {
        Write-DscStatus "Failed to create New-CMActiveDirectoryForest for domain $DomainFullName $_"
    }
    Write-DscStatus "Get-CMSiteDefinition -SiteCode $Externaldomainsitecode"
    $sitedef = Get-CMSiteDefinition -SiteCode $Externaldomainsitecode

    if (-not $sitedef) {
        Write-DscStatus "Failed to get CMSiteDefinition for sitecode $Externaldomainsitecode"
        return
    }   
    
    Write-DscStatus "Enable Discovery Set-CMActiveDirectoryForest"
    "Set-CMActiveDirectoryForest -EnableDiscovery $true -ForestFQDN $DomainFullName -AddPublishingSite $sitedef" | Write-StatusLogEntry
    Set-CMActiveDirectoryForest -EnableDiscovery $true -ForestFQDN $DomainFullName -AddPublishingSite $sitedef *>&1 | Write-StatusLogEntry

    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery for sitecode $sitecode"
    "Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery -SiteCode $sitecode -Enabled $true -Verbose" | Write-StatusLogEntry
    Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery -SiteCode $sitecode -Enabled $true -Verbose | Write-StatusLogEntry

    $Domain = $DomainFullName
    $DN = 'DC=' + $Domain.Replace('.',',DC=')   
    $LDAPPath = "LDAP://$DN"
    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery $LDAPPath"
    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $sitecode -Enabled $true -addActiveDirectoryContainer @($LDAPPath) -UserName $ForestDiscoveryAccount -Verbose -EnableIncludeGroup $$true -EnableRecursive $$true"
    Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $sitecode -Enabled $true -addActiveDirectoryContainer @($LDAPPath) -UserName $ForestDiscoveryAccount -EnableIncludeGroup $true -EnableRecursive $true -Verbose *>&1 | Write-StatusLogEntry

    Write-DscStatus "Set-CMDiscoveryMethod -ActiveDirectoryUserDiscovery $LDAPPath"
    Set-CMDiscoveryMethod -ActiveDirectoryUserDiscovery -SiteCode $sitecode -Enabled $true -AddActiveDirectoryContainer @($LDAPPath) -UserName $ForestDiscoveryAccount -EnableIncludeGroup $true -EnableRecursive $true -Verbose *>&1 | Write-StatusLogEntry

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
        # Compute usable host range (.1 to .254), matching CM's Forest Discovery convention.
        $IP = $network
        $mask = '255.255.255.0'
        $IPBits = [int[]]$IP.Split('.')
        $MaskBits = [int[]]$Mask.Split('.')
        $NetworkIDBits = 0..3 | Foreach-Object { $IPBits[$_] -band $MaskBits[$_] }
        $BroadcastBits = 0..3 | Foreach-Object { $NetworkIDBits[$_] + ($MaskBits[$_] -bxor 255) }
        $NetworkID = $NetworkIDBits -join '.'
        $NetworkIDBits[3] = 1          # first usable host
        $BroadcastBits[3] = 254        # last usable host
        $FirstHost = $NetworkIDBits -join '.'
        $LastHost = $BroadcastBits -join '.'
        $rangeValue = "$FirstHost-$LastHost"
        # Match AD Forest Discovery naming: domain/SiteCode/NetworkID/prefix
        $boundaryName = "$DomainFullName/$Externaldomainsitecode/$NetworkID/24"
        Write-DscStatus "New Boundary '$boundaryName' ($rangeValue)"

        $sitesystems = @()
        $sitesystems += (Get-CMDistributionPoint -SiteCode $Externaldomainsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems += (Get-CMManagementPoint -SiteCode $Externaldomainsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems += (Get-CMSoftwareUpdatePoint -SiteCode $Externaldomainsitecode).NetworkOSPath -replace "\\", ""
        $sitesystems = $sitesystems | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique

        # Check by name first, then by old name, then by value
        $existingBoundary = Get-CMBoundary -BoundaryName $boundaryName -ErrorAction SilentlyContinue
        if (-not $existingBoundary) {
            $existingBoundary = Get-CMBoundary -BoundaryName "$DomainFullName - $network" -ErrorAction SilentlyContinue
        }
        if (-not $existingBoundary) {
            $existingBoundary = Get-CMBoundary | Where-Object { $_.BoundaryType -eq 3 -and $_.Value -eq $rangeValue }
        }
        if (-not $existingBoundary) {
            try {
                "New-CMBoundary -Type IPRange -Name `"$boundaryName`" -Value `"$rangeValue`"" | Write-StatusLogEntry
                New-CMBoundary -Type IPRange -Name $boundaryName -Value $rangeValue *>&1 | Write-StatusLogEntry
            }
            catch {
                Write-DscStatus "Failed to create New-CMBoundary for $boundaryName - $sitecode $_"
            }
        }
        else {
            $boundaryName = $existingBoundary.DisplayName
            Write-DscStatus "Boundary '$boundaryName' ($rangeValue) already exists, reusing"
        }

        try {
            "New-CMBoundaryGroup -Name `"$boundaryName`" -DefaultSiteCode $Externaldomainsitecode -AddSiteSystemServerName $sitesystems" | Write-StatusLogEntry
            New-CMBoundaryGroup -Name $boundaryName -DefaultSiteCode $Externaldomainsitecode -AddSiteSystemServerName $sitesystems *>&1 | Write-StatusLogEntry
        }
        catch {
            Write-DscStatus "Failed to create New-CMBoundaryGroup for $boundaryName - $Externaldomainsitecode $_"
        }

        Add-CMBoundaryToGroup -BoundaryName $boundaryName -BoundaryGroupName $boundaryName *>&1 | Write-StatusLogEntry
        "Add-CMBoundaryToGroup -BoundaryName `"$boundaryName`" -BoundaryGroupName `"$boundaryName`"" | Write-StatusLogEntry
    }

    # ---- Force the external site's MP(s) to honor the freshly-created boundary
    # group(s) NOW. The MP caches the boundary-group list in its w3wp worker and
    # does NOT pick up a brand-new boundary group for ~10-20 min. So the first
    # cross-forest client push hits MP GetDPLocations during that window, gets an
    # EMPTY ContentLocationReply, and ccmsetup fails 0x87d00454 (HTTP 200, no
    # content location). The deploy self-heals on the client's next ccmsetup
    # retry, but the new domain's Phase 11 first pass WARNs on every client.
    # Recycling IIS (WAS + its dependent W3SVC) on each MP drops the cached
    # boundary list, so the very next GetDPLocations re-reads it from the site DB
    # (where New-CMBoundary just committed) and returns the DP. RPC remote restart
    # matches the site-system remoting ScriptWorkFlow already uses for MP bounces;
    # the CM site-server context is admin on its own MPs. The ~15-min discovery
    # wait below gives IIS ample time to come back before the explicit push.
    if ($networks.Count -gt 0) {
        $externalMPs = @()
        try {
            $externalMPs = @((Get-CMManagementPoint -SiteCode $Externaldomainsitecode).NetworkOSPath -replace "\\", "" |
                Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
        }
        catch {
            Write-DscStatus "MP boundary refresh: failed to enumerate MPs for site $Externaldomainsitecode ($_); skipping (ccmsetup retry will recover)" -Warning
            $externalMPs = @()
        }
        foreach ($mpServer in $externalMPs) {
            Write-DscStatus "MP boundary refresh: recycling IIS on $mpServer so it honors the new cross-forest boundary group(s)"
            "Restart-Service -ComputerName $mpServer -Name WAS -Force (IIS recycle to drop MP boundary cache)" | Write-StatusLogEntry
            try {
                Restart-Service -ComputerName $mpServer -Name 'WAS' -Force -ErrorAction Stop
            }
            catch {
                Write-DscStatus "MP boundary refresh: IIS recycle on $mpServer failed ($($_.Exception.Message)); auto-push/ccmsetup retry will recover" -Warning
            }
        }
    }

    Write-DscStatus "Set-CMClientPushInstallation $cm_svc"
    $accounts = (get-CMClientPushInstallation -SiteCode $Externaldomainsitecode).EmbeddedPropertyLists.Reserved2.values

    if ($cm_svc -in $accounts) {
        Write-DscStatus "Skip Set-CMClientPushInstallation since $cm_svc already exists"
    }
    else {
        Set-CMClientPushInstallation -SiteCode $Externaldomainsitecode -EnableAutomaticClientPushInstallation $True -AddAccount $cm_svc *>&1 | Write-StatusLogEntry
    }

    # Restart services to make sure push account is acknowledged by CCM
    Write-DscStatus "Restarting services"
    Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
    Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 30

    # ---- Explicitly discover + push the external domain's clients NOW ----
    # Set-CMClientPushInstallation above only ENABLES automatic client push, which
    # then relies on the slow AD Forest Discovery -> device record -> auto-push
    # cycle (typically 15-60+ min on the first pass). On its own that means the
    # cross-forest clients are NOT installed by the time the new domain's Phase 11
    # validates them (observed: discovery/push enabled at deploy time, Phase 11
    # ran <3 min later -> every client "CcmExec not installed"). To install the
    # agent DURING the deploy, force a discovery pass and then explicitly
    # Install-CMClient each external-domain DomainMember, mirroring PushClients.ps1.
    $externalClients = @($deployConfig.virtualMachines | Where-Object {
            $_.Role -eq "DomainMember" -and ($_.pushClient -ne $false) -and
            ($_.ThisParams.vmNetwork -in $networks)
        } | Select-Object -ExpandProperty vmName | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)

    if ($externalClients.Count -gt 0) {
        Write-DscStatus "External client push: $($externalClients.Count) target(s) [$($externalClients -join ', ')] for site $Externaldomainsitecode"
        $CollectionName = "All Systems"

        # Force a forest + system discovery pass so the cross-forest machines
        # become device records we can push to.
        try { Invoke-CMForestDiscovery -SiteCode $Externaldomainsitecode *>&1 | Write-StatusLogEntry } catch { Write-DscStatus "External client push: Invoke-CMForestDiscovery failed (auto-push still runs): $_" }
        try { Invoke-CMSystemDiscovery *>&1 | Write-StatusLogEntry } catch { Write-DscStatus "External client push: Invoke-CMSystemDiscovery failed: $_" }

        # Bounded wait shared across ALL targets (forest discovery populates them
        # in one batch, so wait once rather than per-client) -- caps the total
        # stall at 15 min regardless of client count.
        $maxWaitSec = 900
        $waited = 0
        $machinelist = @()
        $listMeasured = $false
        while ($waited -lt $maxWaitSec) {
            # A swallowed failure here used to leave $machinelist holding the PREVIOUS poll,
            # so the count below was reported as current from a query that never ran.
            $listMeasured = $false
            try {
                $machinelist = @((Get-CMDevice -CollectionName $CollectionName -ErrorAction Stop).Name)
                $listMeasured = $true
            }
            catch {
                Write-DscStatus "External client push: Get-CMDevice on '$CollectionName' failed; discovery was NOT measured this pass: $_"
            }
            if ($listMeasured) {
                $present = @($externalClients | Where-Object { $machinelist -contains $_ })
                if ($present.Count -ge $externalClients.Count) {
                    Write-DscStatus "External client push: all $($externalClients.Count) target(s) discovered"
                    break
                }
                Write-DscStatus "External client push: discovered $($present.Count)/$($externalClients.Count) target(s); waiting for forest discovery (${waited}s/${maxWaitSec}s)"
            }
            # Re-kick discovery roughly every 3 min.
            if (($waited % 180) -eq 0) {
                try { Invoke-CMForestDiscovery -SiteCode $Externaldomainsitecode *>&1 | Out-Null } catch {}
                try { Invoke-CMSystemDiscovery *>&1 | Out-Null } catch {}
                try { Invoke-CMDeviceCollectionUpdate -Name $CollectionName *>&1 | Out-Null } catch {}
            }
            Start-Sleep -Seconds 30
            $waited += 30
        }
        $listMeasured = $false
        try {
            $machinelist = @((Get-CMDevice -CollectionName $CollectionName -ErrorAction Stop).Name)
            $listMeasured = $true
        }
        catch {
            Write-DscStatus "External client push: final Get-CMDevice on '$CollectionName' failed: $_"
        }

        foreach ($client in $externalClients) {
            if (-not $listMeasured) {
                Write-DscStatus "External client push: device list unavailable, so whether $client was discovered is UNKNOWN, not 'no'; leaving it to automatic client push"
                continue
            }
            if ($machinelist -notcontains $client) {
                Write-DscStatus "External client push: $client not discovered within ${maxWaitSec}s; automatic client push will install it on the next discovery cycle"
                continue
            }
            # Auto-push may have already installed it -- a second push races with
            # the first and can throw E_ABORT (0x80004004).
            $device = $null
            try { $device = Get-CMDevice -Name $client -ErrorAction SilentlyContinue } catch {}
            if ($device -and $device.IsClient) {
                Write-DscStatus "External client push: $client already has the CM client (auto-push won); skipping explicit push"
                continue
            }
            Write-DscStatus "External client push: Install-CMClient -DeviceName $client -SiteCode $Externaldomainsitecode"
            try {
                Install-CMClient -DeviceName $client -SiteCode $Externaldomainsitecode -AlwaysInstallClient $true *>&1 | Write-StatusLogEntry
                Start-Sleep -Seconds 5
            }
            catch {
                Write-DscStatus "External client push: Install-CMClient for $client failed: $_ ; automatic push will retry"
            }
        }
        Write-DscStatus "External client push: explicit push pass complete (clients install asynchronously via ccmsetup)"
    }
    else {
        Write-DscStatus "External client push: no external-domain DomainMember clients to push"
    }
}

# Update actions file
$Configuration.InstallClient.Status = 'Completed'
$Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
