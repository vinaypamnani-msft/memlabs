#PushClients.ps1
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

$CurrentRole = $ThisVM.role
# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","
$ClientNames = $thisVM.thisParams.ClientPush

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

$cm_svc = "$DomainFullName\cm_svc"
$cm_svc_file = "$LogPath\cm_svc.txt"

# Only set client push account if not CAS
if ($CurrentRole -ne "CAS") {
    if (Test-Path $cm_svc_file -PathType Leaf -and (Get-Content $cm_svc_file | Where-Object { $_.Trim() -ne '' })) {
        #Run this in a loop, until the $cm_svc account is found in the Client Push Installation settings    
        $maxRetries = 10
        $retries = 0
        $found = $false
        do {
            # Add cm_svc domain account as CM account
            $ExistingAccount = $null
            try {
                $ExistingAccount = Get-CMAccount | Where-Object { $_.UserName -eq $cm_svc }
            } catch {
                Write-DscStatus "[ClientPush][Retry $retries] Exception while checking for existing CM account: $_. Exception: $($_.Exception.Message)"
            }
            if (-not $ExistingAccount) {
                try {
                    $secure = Get-Content $cm_svc_file | ConvertTo-SecureString -AsPlainText -Force
                    Write-DscStatus "[ClientPush] Adding cm_svc domain account as CM account"
                    Start-Sleep -Seconds 5
                    New-CMAccount -Name $cm_svc -Password $secure -SiteCode $SiteCode *>&1 | Out-File $global:StatusLog -Append
                } catch {
                    Write-DscStatus "[ClientPush][Retry $retries] Failed to add cm_svc as CM account: $_. Exception: $($_.Exception.Message)"
                }
            }
            $accounts = $null
            try {
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
                    Write-DscStatus "[ClientPush][Retry $retries] Setting the Client Push Account"
                    Set-CMClientPushInstallation -EnableAutomaticClientPushInstallation $True -SiteCode $SiteCode -AddAccount $cm_svc *>&1 | Out-File $global:StatusLog -Append
                    Start-Sleep -Seconds 5
                    Write-DscStatus "[ClientPush][Retry $retries] Restarting services to acknowledge push account"
                    Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                    Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue    
                    Start-Sleep -seconds 30
                } catch {
                    Write-DscStatus "[ClientPush][Retry $retries] Exception while setting Client Push Account or restarting services: $_. Exception: $($_.Exception.Message)"
                }
            }
            if (-not $found) {
                # Query again to see if it was added after the last attempt
                try {
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
        Write-DscStatus "[ClientPush] cm_svc.txt file not found or is empty in $LogPath. Skipping cm_svc account creation." -Failure
    }
} else {
    Write-DscStatus "[ClientPush] Current site is CAS. Skipping client push account configuration."
}

Write-DscStatus "Client push candidates are '$ClientNames'"

# Push Clients
#==============
if (-not $pushClients) {
    Write-DscStatus "Skipping Client Push. pushClientToDomainMembers options is set to false."
    $Configuration.InstallClient.Status = 'NotRequested'
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

# Wait for collection to populate

$ClientNameList = $ClientNames.split(",")
$AnyClientFound = $false
foreach ($clientName in $ClientNameList) {
    $isClient = (Get-CMDevice | Where-Object { $_.Name -eq $clientName -or $_Name -like "$($clientName).*" }).IsClient
    if ($isClient) {
        $ClientNameList = $ClientNameList | Where-Object { $_ -ne $clientName }
        $AnyClientFound = $true
    }    
}

$CollectionName = "All Systems"
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


$machinelist = (get-cmdevice -CollectionName $CollectionName).Name

$PackageID = (Get-CMPackage -Fast -Name 'Configuration Manager Client Package').PackageID
$PackageSuccess = (Get-CMDistributionStatus -Id $PackageID).NumberSuccess
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
        $PackageID = (Get-CMPackage -Fast -Name 'Configuration Manager Client Package').PackageID
        Start-Sleep -Seconds 40
        $PackageSuccess = (Get-CMDistributionStatus -Id $PackageID).NumberSuccess
        $success = $PackageSuccess -ge 1

        if ($failCount -ge 20) {
            $success = $true   
        }
    
    }
    Start-Sleep -Seconds 30
    Invoke-CMSystemDiscovery
    Invoke-CMDeviceCollectionUpdate -Name $CollectionName
}
$machinelist = (get-cmdevice -CollectionName $CollectionName) | Where-Object {$_.IsClient} | Select-Object Name
foreach ($client in $ClientNameList) {

    if ($machinelist -contains $client) {
        continue
    }
    Install-CMClient -DeviceName $client -SiteCode $SiteCode -AlwaysInstallClient $true *>&1 | Out-File $global:StatusLog -Append
}

$installedmachinelist = (get-cmdevice -CollectionName $CollectionName) | Where-Object {$_.IsClient} | Select-Object Name
$machinelist = (get-cmdevice -CollectionName $CollectionName).Name
foreach ($client in $ClientNameList) {

    if ([string]::IsNullOrWhiteSpace($client)) {
        continue
    }
    if ($installedmachinelist -contains $client) {
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
