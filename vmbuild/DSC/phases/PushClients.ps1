#PushClients.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.vmOptions.domainName
$NetbiosDomainName = $deployConfig.vmOptions.domainNetBiosName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

$CurrentRole = $ThisVM.role
# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","
$ClientNames = $thisVM.thisParams.ClientPush

# Push is now per-VM (pushClient property). thisParams.ClientPush only contains
# VMs that have opted in, so an empty list means nothing to push.
$pushClients = [bool]$ClientNames
# Per-VM cmOptions wins over the rehydrated global so multi-hierarchy deploys
# (CAS hierarchy alongside a separate standalone Primary with differing PKI)
# pick this VM's own UsePKI setting.
$cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
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

# Provider — retry connection since the provider may still be initializing
# (InstallProvider.ps1 may have just finished installing a remote provider).
# Reusable provider connection function — called for initial connect and
# retry after transient WMI/provider failures during push.
function Connect-CMProvider {
    param([string]$SiteCode, [int]$MaxRetries = 6, [int]$DelaySec = 30, [string]$Tag = "[PushClients]")
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $prov = Get-SMSProvider -SiteCode $SiteCode
            if (-not $prov.FQDN) {
                Write-DscStatus "$Tag Attempt $attempt/$MaxRetries`: Get-SMSProvider returned no FQDN"
                if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $DelaySec }
                continue
            }
            $worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($prov.FQDN)
            if (-not $worked) {
                Write-DscStatus "$Tag Attempt $attempt/$MaxRetries`: Set-CMSiteProvider returned false"
                if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $DelaySec }
                continue
            }
            Set-Location "$($SiteCode):\"
            if ((Get-Location).Drive.Name -ne $SiteCode) {
                Write-DscStatus "$Tag Attempt $attempt/$MaxRetries`: Set-Location to $SiteCode`: failed"
                if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $DelaySec }
                continue
            }
            return $true
        }
        catch {
            Write-DscStatus "$Tag Attempt $attempt/$MaxRetries`: Provider connection failed: $_"
            if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $DelaySec }
        }
    }
    return $false
}

$providerConnected = Connect-CMProvider -SiteCode $SiteCode

if (-not $providerConnected) {
    Write-DscStatus "[PushClients] Failed to connect to CM provider. Skipping client push." -Warning
    return
}

$cm_svc = "$DomainFullName\cm_svc"
$cm_svc_file = "$LogPath\cm_svc.txt"

# Only set client push account if not CAS
if ($CurrentRole -ne "CAS") {
    Write-DscStatus "[ClientPush] Starting client push account configuration."
    if ((Test-Path $cm_svc_file -PathType Leaf) -and ((Get-Content $cm_svc_file | Where-Object { $_.Trim() -ne '' }))) {
        Write-DscStatus "[ClientPush] Found non-empty cm_svc.txt at $cm_svc_file. Proceeding with account configuration."
        #Run this in a loop, until the $cm_svc account is found in the Client Push Installation settings    
        $maxRetries = 10
        $retries = 0
        $found = $false
        do {
            # Add cm_svc domain account as CM account.
            # SCOPE TO THIS SITE: Configuration Manager accounts are per-site
            # (SMS_SCI_Reserved in the site control file). In a CAS+child-primary
            # hierarchy the account *object* replicates down via DRS so a bare
            # Get-CMAccount returns cm_svc on the child even though the encrypted
            # password secret was only seeded at the site where New-CMAccount
            # actually ran (the CAS / a sibling primary). The secret does NOT
            # replicate, so the child has no usable credential -- and the later
            # Set-CMClientPushInstallation -AddAccount fails with "User account
            # ... was not found at site '<child>'", leaving the site with an
            # EMPTY client-push account and falling back to the site-server
            # machine account (which isn't a local admin on workstation clients),
            # so ccmsetup never reaches them (no ccmsetup.log on the client).
            # Get-CMAccount -SiteCode <thisSite> returns only accounts seeded at
            # THIS site, so a child that hasn't run New-CMAccount yet correctly
            # falls into the creation branch below and seeds its own local secret.
            $ExistingAccount = $null
            try {
                Write-DscStatus "[ClientPush][Retry $retries] Running: Get-CMAccount -SiteCode $SiteCode -UserName $cm_svc"
                $ExistingAccount = Get-CMAccount -SiteCode $SiteCode -UserName $cm_svc | Where-Object { $_.UserName -eq $cm_svc }
            } catch {
                Write-DscStatus "[ClientPush][Retry $retries] Exception while checking for existing CM account: $_. Exception: $($_.Exception.Message)"
            }
            if (-not $ExistingAccount) {
                try {
                    $secure = Get-Content $cm_svc_file | ConvertTo-SecureString -AsPlainText -Force
                    Write-DscStatus "[ClientPush][Retry $retries] Running: New-CMAccount -Name $cm_svc -Password <secure> -SiteCode $SiteCode"
                    Write-DscStatus "[ClientPush] Adding cm_svc domain account as CM account"
                    Start-Sleep -Seconds 5
                    New-CMAccount -Name $cm_svc -Password $secure -SiteCode $SiteCode *>&1 | Write-StatusLogEntry
                } catch {
                    Write-DscStatus "[ClientPush][Retry $retries] Failed to add cm_svc as CM account: $_. Exception: $($_.Exception.Message)"
                }
            }
            $accounts = $null
            try {
                Write-DscStatus "[ClientPush][Retry $retries] Running: get-CMClientPushInstallation -SiteCode $SiteCode"
                $accounts = (get-CMClientPushInstallation -SiteCode $SiteCode).EmbeddedPropertyLists.Reserved2.values
                if ($cm_svc -in $accounts) {
                    $found = $true
                } else {
                    Write-DscStatus "[ClientPush][Retry $retries] $cm_svc not found in $accounts for Sitecode $SiteCode. Will retry."
                }
            } catch {
                Write-DscStatus "[ClientPush][Retry $retries] Exception while checking Client Push Installation accounts: $_. Exception: $($_.Exception.Message)"
            }
            if (-not $found) {
                try {
                    Write-DscStatus "[ClientPush][Retry $retries] Running: Set-CMClientPushInstallation -EnableAutomaticClientPushInstallation $True -SiteCode $SiteCode -AddAccount $cm_svc"
                    Write-DscStatus "[ClientPush][Retry $retries] Setting the Client Push Account"
                    Set-CMClientPushInstallation -EnableAutomaticClientPushInstallation $True -SiteCode $SiteCode -AddAccount $cm_svc *>&1 | Write-StatusLogEntry
                    Start-Sleep -Seconds 5
                    if ($retries -gt 5) {
                        Write-DscStatus "[ClientPush][Retry $retries] Running: Restart-Service -DisplayName 'SMS_Executive'"
                        Write-DscStatus "[ClientPush][Retry $retries] Restarting services to acknowledge push account"
                        Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                        Write-DscStatus "[ClientPush][Retry $retries] Running: Restart-Service -DisplayName 'SMS_Site_Component_Manager'"
                        Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue    
                        Start-Sleep -seconds 30
                    }
                } catch {
                    Write-DscStatus "[ClientPush][Retry $retries] Exception while setting Client Push Account or restarting services: $_. Exception: $($_.Exception.Message)"
                }
            }
            if (-not $found) {
                # Query again to see if it was added after the last attempt
                try {
                    Write-DscStatus "[ClientPush][Retry $retries] Running: get-CMClientPushInstallation -SiteCode $SiteCode (post-add re-check)"
                    $accounts = (get-CMClientPushInstallation -SiteCode $SiteCode).EmbeddedPropertyLists.Reserved2.values
                    if ($cm_svc -in $accounts) {
                        $found = $true
                        Write-DscStatus "[ClientPush][Retry $retries] cm_svc found in Client Push Installation settings after re-check."
                    }
                    else {
                        Write-DscStatus "[ClientPush][Retry $retries] cm_svc still not found in Client Push Installation settings. Retrying..."
                    }
                } catch {
                    Write-DscStatus "[ClientPush][Retry $retries] Exception during post-add re-check: $_. Exception: $($_.Exception.Message)"
                }
            }
            $retries++
        } until ($found -or $retries -ge $maxRetries)
        if (-not $found) {
            Write-DscStatus "[ClientPush] Failed to add cm_svc to Client Push Installation settings after $maxRetries retries."
        }
    }
    else {
        if (-not (Test-Path $cm_svc_file -PathType Leaf)) {
            Write-DscStatus "[ClientPush] cm_svc.txt file was not found at $cm_svc_file. Skipping cm_svc account creation."
        } elseif (-not (Get-Content $cm_svc_file | Where-Object { $_.Trim() -ne '' })) {
            Write-DscStatus "[ClientPush] cm_svc.txt file at $cm_svc_file is empty. Skipping cm_svc account creation."
        } else {
            Write-DscStatus "[ClientPush] Unknown reason for skipping cm_svc account creation. Check $cm_svc_file."
        }
    }
} else {
    Write-DscStatus "[ClientPush] Skipping client push account configuration because current site is CAS."
}

# When PKI/HTTPS is enabled, ccmsetup must be told to use the PKI cert to reach the HTTPS-only MP
if ($usePKI -and $CurrentRole -ne "CAS") {
    Write-DscStatus "[ClientPush] PKI is enabled. Setting /UsePKICert installation property for client push."
    try {
        Set-CMClientPushInstallation -SiteCode $SiteCode -InstallationProperty "SMSSITECODE=$SiteCode /UsePKICert" *>&1 | Write-StatusLogEntry
    }
    catch {
        Write-DscStatus "[ClientPush] WARNING: Failed to set /UsePKICert property: $_"
    }

    # After EnableHTTPS sets IISSSLState=63, the site component manager must
    # republish the OperationalXml to AD. ccmsetup reads SecurityModeMaskEx
    # from the MP's AD object during bootstrap and needs CCM_SSL_ENABLED (bit 0)
    # to be set. If we push before AD is updated, ccmsetup fails with
    # CCM_E_NO_CLIENT_PKI_CERT. Check ALL DCs to guard against replication lag.
    Write-DscStatus "[ClientPush] Verifying AD has HTTPS-mode OperationalXml on all DCs before pushing..."
    $searchBase = "CN=System Management,CN=System," + ([ADSI]"LDAP://RootDSE").defaultNamingContext
    $allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty HostName)
    if ($allDCs.Count -eq 0) { $allDCs = @($env:LOGONSERVER -replace '\\\\','') }

    $maxWaitMinutes = 10
    $pollSeconds = 15
    $deadline = (Get-Date).AddMinutes($maxWaitMinutes)
    $allGood = $false

    while (-not $allGood -and (Get-Date) -lt $deadline) {
        $staleDCs = @()
        foreach ($dc in $allDCs) {
            try {
                $mpObj = Get-ADObject -Server $dc -Filter "objectClass -eq 'mSSMSManagementPoint' -and mSSMSSiteCode -eq '$SiteCode'" `
                    -SearchBase $searchBase -Properties mSSMSCapabilities -ErrorAction Stop | Select-Object -First 1
                if ($mpObj -and $mpObj.mSSMSCapabilities) {
                    $maskMatch = [regex]::Match($mpObj.mSSMSCapabilities, '<SecurityModeMaskEx>(\d+)</SecurityModeMaskEx>')
                    if ($maskMatch.Success) {
                        $adMaskEx = [int]$maskMatch.Groups[1].Value
                        if (-not ($adMaskEx -band 1)) {
                            $staleDCs += "$dc (SecurityModeMaskEx=$adMaskEx, bit 0x1 missing)"
                        }
                    }
                    else {
                        $staleDCs += "$dc (SecurityModeMaskEx not found in OperationalXml)"
                    }
                }
                else {
                    $staleDCs += "$dc (MP AD object not found)"
                }
            }
            catch {
                $staleDCs += "$dc (query failed: $($_.Exception.Message))"
            }
        }

        if ($staleDCs.Count -eq 0) {
            $allGood = $true
            Write-DscStatus "[ClientPush] AD OperationalXml verified on $($allDCs.Count) DC(s) -- SecurityModeMaskEx has CCM_SSL_ENABLED."
        }
        else {
            $elapsed = [math]::Round(((Get-Date) - $deadline.AddMinutes($maxWaitMinutes)).TotalSeconds)
            Write-DscStatus "[ClientPush] Waiting for AD replication ($($staleDCs.Count)/$($allDCs.Count) DC(s) stale, ${elapsed}s elapsed): $($staleDCs -join '; ')" -RetrySeconds $pollSeconds
            Start-Sleep -Seconds $pollSeconds
        }
    }

    if (-not $allGood) {
        Write-DscStatus "[ClientPush] WARNING: AD OperationalXml still stale on some DCs after ${maxWaitMinutes}m. Client push may fail with CCM_E_NO_CLIENT_PKI_CERT if clients query a stale DC."
    }
}

Write-DscStatus "Client push candidates are '$ClientNames'"

# Push Clients
#==============
if (-not $pushClients) {
    Write-DscStatus "Skipping Client Push. No VMs have pushClient=true in this deployment."
    $Configuration.InstallClient.Status = 'NotRequested'
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

# Wait for collection to populate — single query instead of per-client unfiltered
# Get-CMDevice calls which can exhaust provider connections.
$ClientNameList = $ClientNames.split(",")
$AnyClientFound = $false
$CollectionName = "All Systems"
$pushMaxAttempts = 2

# Redeploy-aware staleness test. When a same-named VM is removed from the domain
# and rebuilt, CM keeps the OLD device record (IsClient=1) while the freshly
# built machine has no agent. The IsClient pre-check below would then wrongly
# trim the VM and never push. Compare the AD machine account's join/rotation
# time (pwdLastSet, fallback whenCreated) against CM's last-active time: if the
# machine (re)joined the domain AFTER CM last heard from the client, the CM
# record belongs to the previous incarnation and must be cleared so ccmsetup
# re-runs on the new machine. RSAT-free (ADSISearcher) so it works on any site
# server. PS5.1-safe.
function Test-RemoteCMClientInstalled {
    <#
    .SYNOPSIS
    Returns $true when the target machine already has a ConfigMgr client on
    disk. Asked of the MACHINE itself over SMB (admin$ = %windir%), not of this
    site's CM database.

    Why: in a hierarchy a client owned by ANOTHER site may never show up in this
    site's 'All Systems', so the CM-side pre-check below can't trim it and the
    discovery wait then burns its full budget on it -- on EVERY rerun, forever.
    The machine's own filesystem is the one source of truth that can't be stale
    or site-scoped. RSAT-free, remoting-free, PS5.1-safe.
    #>
    param([string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $false }

    $probePaths = @(
        "\\$ComputerName\admin`$\CCM\CcmExec.exe",
        "\\$ComputerName\c`$\Windows\CCM\CcmExec.exe"
    )
    foreach ($p in $probePaths) {
        try {
            if (Test-Path -Path $p -PathType Leaf -ErrorAction SilentlyContinue) { return $true }
        }
        catch {}
    }
    return $false
}

function Test-CMClientRecordStale {
    param([string]$ShortName, [string]$SiteCode)

    $result = New-Object psobject -Property @{ Stale = $false; Reason = '' }

    # --- AD machine epoch ---
    $adEpoch = $null
    try {
        $searcher = [ADSISearcher]"(&(objectClass=computer)(cn=$ShortName))"
        $null = $searcher.PropertiesToLoad.AddRange(@('pwdlastset', 'whencreated'))
        $adRes = $searcher.FindOne()
        if ($adRes) {
            $pwd = $adRes.Properties['pwdlastset']
            if ($pwd -and $pwd.Count -gt 0 -and [int64]$pwd[0] -gt 0) {
                $adEpoch = [datetime]::FromFileTimeUtc([int64]$pwd[0])
            }
            if (-not $adEpoch) {
                $wc = $adRes.Properties['whencreated']
                if ($wc -and $wc.Count -gt 0) { $adEpoch = ([datetime]$wc[0]).ToUniversalTime() }
            }
        }
    }
    catch {
        # Can't read AD -> don't second-guess CM; treat as not-stale.
        $result.Reason = "AD lookup failed: $($_.Exception.Message)"
        return $result
    }
    if (-not $adEpoch) {
        $result.Reason = "no AD machine account found for $ShortName"
        return $result
    }

    # --- CM last-active epoch (SMS_CombinedDeviceResources backs the Devices node) ---
    $cmLastActive = $null
    $clientActiveStatus = $null
    try {
        $combined = Get-WmiObject -Namespace "root\sms\site_$SiteCode" -Class SMS_CombinedDeviceResources -Filter "Name='$ShortName'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($combined) {
            $clientActiveStatus = $combined.ClientActiveStatus
            if ($combined.LastActiveTime) {
                $cmLastActive = ([Management.ManagementDateTimeConverter]::ToDateTime($combined.LastActiveTime)).ToUniversalTime()
            }
        }
    }
    catch {}

    # 60-min margin absorbs DateTimeKind/timezone skew; a real redeploy gap is
    # days-to-months so the margin never masks one, while a healthy client
    # (LastActiveTime updates on every ~60-min policy cycle) is never flagged
    # even right after a 30-day machine-password rotation.
    if ($cmLastActive) {
        if ($adEpoch -gt $cmLastActive.AddMinutes(60)) {
            $result.Stale = $true
            $result.Reason = "AD machine epoch $($adEpoch.ToString('u')) is newer than CM LastActiveTime $($cmLastActive.ToString('u')) (ClientActiveStatus=$clientActiveStatus)"
        }
    }
    else {
        # CM marks it a client but has never recorded activity, and the machine
        # account (re)joined within the last day -> almost certainly a redeploy
        # whose old record predates activity tracking.
        if ($adEpoch -gt (Get-Date).ToUniversalTime().AddDays(-1)) {
            $result.Stale = $true
            $result.Reason = "CM has no LastActiveTime and AD machine epoch $($adEpoch.ToString('u')) is within 24h (ClientActiveStatus=$clientActiveStatus)"
        }
    }
    return $result
}

for ($pushAttempt = 1; $pushAttempt -le $pushMaxAttempts; $pushAttempt++) {

Write-DscStatus "[ClientPush] Pre-check: querying '$CollectionName' for existing clients... (attempt $pushAttempt/$pushMaxAttempts)"
try {
    $allDevices = @(Get-CMDevice -CollectionName $CollectionName -ErrorAction Stop)
    Write-DscStatus "[ClientPush] Pre-check: '$CollectionName' returned $($allDevices.Count) device(s)"
} catch {
    Write-DscStatus "[ClientPush] Pre-check: Get-CMDevice failed: $($_.Exception.Message). Proceeding with empty list."
    $allDevices = @()
}

foreach ($clientName in $ClientNameList) {
    $cmIsClient = ($allDevices | Where-Object { ($_.Name -eq $clientName -or $_.Name -like "$($clientName).*") -and $_.IsClient }).Count -gt 0
    if (-not $cmIsClient) {
        # No client record in THIS site's collection. In a hierarchy that only
        # means it isn't our client -- the machine may already be a fully
        # installed client of a sibling site, in which case it will never appear
        # here and the discovery wait below is guaranteed dead time. Ask the
        # machine itself before committing to that wait.
        if (Test-RemoteCMClientInstalled -ComputerName $clientName) {
            Write-DscStatus "[ClientPush] Pre-check: $clientName already has the CM client on disk (owned by another site; not in this site's '$CollectionName'). Skipping."
            $ClientNameList = @($ClientNameList | Where-Object { $_ -ne $clientName })
        }
        continue
    }

    # CM reports this name as an installed client. Verify the record actually
    # belongs to the CURRENT machine before trusting it -- on a redeploy the
    # record is stale (old incarnation) and the new machine truly has no agent.
    $shortName = ($clientName -split '\.')[0]
    $staleInfo = Test-CMClientRecordStale -ShortName $shortName -SiteCode $SiteCode

    if ($staleInfo.Stale) {
        Write-DscStatus "[ClientPush] Pre-check: $clientName CM record looks stale (redeploy) -- $($staleInfo.Reason). Removing stale CM record and re-pushing."
        try {
            $staleDevs = @(Get-CMDevice -Name $shortName -ErrorAction SilentlyContinue | Where-Object { $_.IsClient })
            foreach ($sd in $staleDevs) {
                Remove-CMDevice -InputObject $sd -Force -ErrorAction Stop
                Write-DscStatus "[ClientPush] Removed stale CM device record for $shortName (ResourceID $($sd.ResourceID))."
            }
        }
        catch {
            Write-DscStatus "[ClientPush] WARNING: failed to remove stale CM record for $shortName ($($_.Exception.Message)). Will still attempt push."
        }
        # Leave $clientName in the push list so the loop below re-discovers and
        # re-pushes it (the IsClient re-guards downstream now see no record).
        continue
    }

    # Genuinely an active client -> trim from the push list.
    Write-DscStatus "[ClientPush] Pre-check: $clientName already has CM client installed (active)"
    $ClientNameList = $ClientNameList | Where-Object { $_ -ne $clientName }
    $AnyClientFound = $true
}

# If all clients already have the agent installed, skip the rest
if ($ClientNameList.Count -eq 0) {
    Write-DscStatus "[ClientPush] All clients already have the agent installed. Skipping."
    $Configuration.InstallClient.Status = 'Completed'
    $Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

if ($ClientNames) {
    Write-DscStatus "Waiting for $($ClientNameList -join ',') to appear in '$CollectionName'"
}
else {
    Write-DscStatus "Skipping Client Push. No Clients to push."
    $Configuration.InstallClient.Status = 'Completed'
    $Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

try {
Write-DscStatus "[ClientPush] Querying '$CollectionName' collection..."
$machinelist = (get-cmdevice -CollectionName $CollectionName -ErrorAction Stop).Name
Write-DscStatus "[ClientPush] '$CollectionName' has $($machinelist.Count) device(s): $($machinelist -join ',')"

# In a hierarchy Get-CMPackage returns packages from every site; filter to
# this site so $PackageID is a single string (not an array) and
# Get-CMDistributionStatus works correctly.
Write-DscStatus "[ClientPush] Checking client package distribution (SiteCode=$SiteCode)..."
$PackageID = (Get-CMPackage -Fast -Name 'Configuration Manager Client Package' | Where-Object { $_.PackageID -like "$SiteCode*" } | Select-Object -First 1).PackageID
if (-not $PackageID) {
    # Fallback: pick any package if site-code filter missed
    $PackageID = (Get-CMPackage -Fast -Name 'Configuration Manager Client Package' | Select-Object -First 1).PackageID
}
Write-DscStatus "[ClientPush] Client Package ID: $PackageID"
$PackageSuccess = if ($PackageID) { (Get-CMDistributionStatus -Id $PackageID -ErrorAction SilentlyContinue).NumberSuccess } else { $null }
Write-DscStatus "[ClientPush] Package distribution success count: $PackageSuccess"
if ($PackageSuccess -eq 0) {
    Start-Sleep -Seconds 5
    if (-not $AnyClientFound) {
        Update-CMDistributionPoint -PackageName "Configuration Manager Client Package"
    }
    $failCount = 0
    $success = $false
    while (-not $success) {
   
        $failCount++
        if ($failCount -eq 2 -and $AnyClientFound) {
            Update-CMDistributionPoint -PackageName "Configuration Manager Client Package"
        }
        Write-DscStatus "Waiting for Client Package to appear on any DP. $failcount / 20"
        $PackageID = (Get-CMPackage -Fast -Name 'Configuration Manager Client Package' | Where-Object { $_.PackageID -like "$SiteCode*" } | Select-Object -First 1).PackageID
        if (-not $PackageID) { $PackageID = (Get-CMPackage -Fast -Name 'Configuration Manager Client Package' | Select-Object -First 1).PackageID }
        Start-Sleep -Seconds 40
        $PackageSuccess = if ($PackageID) { (Get-CMDistributionStatus -Id $PackageID -ErrorAction SilentlyContinue).NumberSuccess } else { 0 }
        $success = $PackageSuccess -ge 1

        if ($failCount -ge 20) {
            $success = $true   
        }
    
    }
    Start-Sleep -Seconds 30
    Invoke-CMSystemDiscovery
    Invoke-CMDeviceCollectionUpdate -Name $CollectionName
}
$installedmachinelist = @(get-cmdevice -CollectionName $CollectionName -ErrorAction Stop | Where-Object {$_.IsClient} | Select-Object -ExpandProperty Name)
$machinelist = @(get-cmdevice -CollectionName $CollectionName -ErrorAction Stop).Name
Write-DscStatus "[ClientPush] Already installed: $($installedmachinelist -join ','). Discovered: $($machinelist -join ',')"

# Shared discovery budget for the WHOLE push run. Previously each client got its
# own 2 x 600s wait loop, so N never-discoverable clients cost N x ~21 minutes of
# pure sleeping (measured: 5 clients = ~105 min per config, on reruns that
# changed nothing). System discovery is site-wide -- one Invoke-CMSystemDiscovery
# covers every pending client -- so the budget is shared, not per-client.
$discoveryBudgetMinutes = 20
$discoveryDeadline = (Get-Date).AddMinutes($discoveryBudgetMinutes)
$lastDiscoveryRun = [datetime]::MinValue

$clientIndex = 0
foreach ($client in $ClientNameList) {
    $clientIndex++

    if ([string]::IsNullOrWhiteSpace($client)) {
        continue
    }
    if ($installedmachinelist -contains $client) {
        Write-DscStatus "[ClientPush] ($clientIndex/$($ClientNameList.Count)) $client already installed, skipping"
        continue
    }

    Write-DscStatus "[ClientPush] ($clientIndex/$($ClientNameList.Count)) Testing SMB to $client..."
    if (-not (Test-TcpPortFast -ComputerName $client -Port 445)) {
        # Don't wait for client to appear in collection if it's not online
        Write-DscStatus "Could not test SMB connection to $client. Skipping."
        continue
    }

    # Machine-sourced short-circuit. The CM-side pre-check above can only see
    # devices in THIS site's 'All Systems'; a client owned by a sibling site in
    # the hierarchy is invisible here and would otherwise consume the entire
    # discovery budget waiting for a record that is never coming.
    if (Test-RemoteCMClientInstalled -ComputerName $client) {
        Write-DscStatus "[ClientPush] ($clientIndex/$($ClientNameList.Count)) $client already has the CM client installed on disk. Skipping push."
        continue
    }

    $success = $true
    while ($machinelist -notcontains $client) {
        if ((Get-Date) -ge $discoveryDeadline) {
            Write-DscStatus "[ClientPush] Shared ${discoveryBudgetMinutes}m discovery budget exhausted; $client never appeared in '$CollectionName'. Skipping." -Warning
            $success = $false
            break
        }

        # Discovery is site-wide, so re-triggering it per client is wasted work.
        # Kick it at most once every 10 minutes for the whole run.
        if (((Get-Date) - $lastDiscoveryRun).TotalMinutes -ge 10) {
            Invoke-CMSystemDiscovery
            Invoke-CMDeviceCollectionUpdate -Name $CollectionName
            $lastDiscoveryRun = Get-Date
        }

        Write-DscStatus "Waiting for $client to appear in '$CollectionName'" -RetrySeconds 30
        Start-Sleep -Seconds 30
        $machinelist = @((get-cmdevice -CollectionName $CollectionName).Name)
        if ($machinelist -contains $client) {
            Write-DscStatus "$client is in '$CollectionName'"
        }
    }
    if ($success) {
        # Re-check if client is already installed or ccmsetup is already running
        # (automatic push may have beaten us). A second push races with the first
        # and can cause E_ABORT (0x80004004).
        $device = Get-CMDevice -Name $client -ErrorAction SilentlyContinue
        if ($device.IsClient) {
            Write-DscStatus "[ClientPush] $client already has the CM client (auto-push succeeded). Skipping manual push."
        }
        else {
            $ccmRunning = $false
            try {
                $ccmRunning = [bool](Invoke-Command -ComputerName $client -ScriptBlock {
                    Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue
                } -ErrorAction SilentlyContinue)
            } catch {}
            if ($ccmRunning) {
                Write-DscStatus "[ClientPush] ccmsetup.exe already running on $client (auto-push in progress). Skipping manual push."
            }
            else {
                Write-DscStatus "Pushing client to $client."
                Install-CMClient -DeviceName $client -SiteCode $SiteCode -AlwaysInstallClient $true *>&1 | Write-StatusLogEntry
                Start-Sleep -Seconds 5
            }
        }
    }
}
} # end try
catch {
    Write-DscStatus "[ClientPush] Client push failed (attempt $pushAttempt/$pushMaxAttempts): $_" -Warning
    if ($pushAttempt -lt $pushMaxAttempts) {
        Write-DscStatus "[ClientPush] Reconnecting to CM provider and retrying..."
        Set-Location $env:SystemDrive
        Start-Sleep -Seconds 30
        $reconnected = Connect-CMProvider -SiteCode $SiteCode -MaxRetries 4 -DelaySec 30 -Tag "[ClientPush-Reconnect]"
        if (-not $reconnected) {
            Write-DscStatus "[ClientPush] Provider reconnect failed. Giving up." -Warning
            break
        }
        Write-DscStatus "[ClientPush] Provider reconnected. Retrying push operation..."
        continue
    }
}

# If we get here without catching, the push succeeded — break out of the retry loop
break

} # end pushAttempt loop


# Update actions file
$Configuration.InstallClient.Status = 'Completed'
$Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
