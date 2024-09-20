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
$CollectionName = "All Systems"
if ($ClientNames) {
    Write-DscStatus "Waiting for $ClientNames to appear in '$CollectionName'"
}
else {
    Write-DscStatus "Skipping Client Push. No Clients to push."
    $Configuration.InstallClient.Status = 'Completed'
    $Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}
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
        if ($failCount -gt 30) {
            $success = $false
            break
        }
        Invoke-CMSystemDiscovery
        Invoke-CMDeviceCollectionUpdate -Name $CollectionName

        Write-DscStatus "Waiting for $client to appear in '$CollectionName'" -RetrySeconds 30
        Start-Sleep -Seconds 30
        $machinelist = (get-cmdevice -CollectionName $CollectionName).Name
        $failCount++
    }
    if ($success) {
        Write-DscStatus "Pushing client to $client."
        Install-CMClient -DeviceName $client -SiteCode $SiteCode -AlwaysInstallClient $true *>&1 | Out-File $global:StatusLog -Append
        Start-Sleep -Seconds 5
    }

}

while ($failcount -le 30) {
    $failCount++
    foreach ($client in $ClientNameList) {
        $device = Get-CMDevice -Name $client
        $status = $device.ClientActiveStatus
        if ($status -eq 1) {
            continue
        }
        Write-DscStatus "Pushing client to $client."
        Install-CMClient -DeviceName $client -SiteCode $SiteCode -AlwaysInstallClient $true *>&1 | Out-File $global:StatusLog -Append

        $device = Get-CMDevice -Name $client
        $status = $device.ClientActiveStatus

        if ($status -eq 1) {
            Write-DscStatus "$client Successfully installed"
        }
    }
    Start-Sleep -Seconds 60
}

# Update actions file
$Configuration.InstallClient.Status = 'Completed'
$Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
