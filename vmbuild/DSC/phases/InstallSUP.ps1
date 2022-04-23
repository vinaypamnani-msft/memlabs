#InstallSUP.ps1
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

$topSite = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq "" }
$thisSiteIsTopSite = $topSite.SiteCode -eq $SiteCode

$SUPs = @()
$ValidSiteCodes = @($SiteCode)
$ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
$ValidSiteCodes += $ReportingSiteCodes

foreach ($sup in $deployConfig.virtualMachines | Where-Object { $_.installSUP -eq $true } ) {
    if ($sup.siteCode -in $ValidSiteCodes) {
        $secondarysite = Get-CMSite -SiteCode $sup.siteCode | Where-Object { $_.Type -eq 1 }
        if ($secondarysite) {
            $supfqdn = $SUP.vmName.Trim() + "." + $DomainFullName
            if ($secondarysite.ServerName -eq $supfqdn) {
                $SUPs += [PSCustomObject]@{
                    ServerName     = $sup.vmName
                    ServerSiteCode = $sup.siteCode
                }
            }
            else {
                Write-DscStatus "Skip SUP role for $($sup.vmName) since it's a remote site system in Secondary site"
            }
        }
        else {
            $SUPs += [PSCustomObject]@{
                ServerName     = $sup.vmName
                ServerSiteCode = $sup.siteCode
            }
        }
    }
}

# Trim nulls/blanks
$SUPNames = $SUPs.ServerName | Where-Object { $_ -and $_.Trim() }
Write-DscStatus "SUP role to be installed on '$($SUPNames -join ',')'"

# Check if a SUP Exists on this site
$configureSUP = $false
$existingSUPs = Get-CMSoftwareUpdatePoint -SiteCode $SiteCode
if ($thisSiteIsTopSite -and -not $existingSUPs -and $SUPs.Count -gt 0) {
    $configureSUP = $true
}

# Install SUP
foreach ($SUP in $SUPs) {

    if ([string]::IsNullOrWhiteSpace($SUP.ServerName)) {
        Write-DscStatus "Found an empty SUP ServerName. Skipping"
        continue
    }

    $SUPFQDN = $SUP.ServerName.Trim() + "." + $DomainFullName
    Install-SUP -ServerFQDN $SUPFQDN -ServerSiteCode $SUP.ServerSiteCode
}

# Configure SUP
$productsToAdd = @("Windows 10, version 1903 and later", "Microsoft Server operating system-21H2")
$classificationsToAdd = @("Critical Updates", "Security Updates", "Updates")
if ($configureSUP) {
    Write-DscStatus "Configuring SUP, and adding Products [$($productsToAdd -join ',')] and Classifications [$($classificationsToAdd -join ',')]"
    $schedule = New-CMSchedule -RecurCount 1 -RecurInterval Days -Start "2022/1/1 00:00:00"
    $attempts = 0
    $configured = $false
    do {
        try {
            if ($topSite) {
                $attempts++
                Write-DscStatus "Running Set-CMSoftwareUpdatePointComponent. Attempt #$attempts"
                Set-CMSoftwareUpdatePointComponent -SiteCode $topSite.SiteCode -AddProduct $productsToAdd -AddUpdateClassification $classificationsToAdd -Schedule $schedule -EnableCallWsusCleanupWizard $true
                $configured = $true
            }
        }
        catch {
            # Run sync to refresh categories, wait for sync, then try again?
            if (-not $syncTimeout) {
                Write-DscStatus "Set-CMSoftwareUpdatePointComponent failed. Running Sync to refresh products."
                Sync-CMSoftwareUpdate
                Start-Sleep -Seconds 120 # Sync waits for 2 mins anyway, so sleep before even checking status
            }
            else {
                Write-DscStatus "Timed out while waiting for sync to finish. Monitoring again..."
            }
            $syncFinished = $syncTimeout = $false
            $i = 0
            do {
                $syncState = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.WSUSSourceServer -like "*Microsoft Update*" }

                if ($syncState.LastSyncState -eq "" -or $null -eq $syncState.LastSyncState) {
                    Write-DscStatus "SUM Sync not detected as running on $($syncState.WSUSServerName). Running Sync to refresh products."
                    Sync-CMSoftwareUpdate
                    Start-Sleep -Seconds 120
                }

                Write-DscStatus "Waiting for SUM Sync on $($syncState.WSUSServerName) to finish. Current State: $($syncState.LastSyncState)"
                if ($syncState.LastSyncState -eq 6702) {
                    $syncFinished = $true
                    Write-DscStatus "SUM Sync finished."
                }

                if (-not $syncFinished) {
                    $i++
                    Start-Sleep -Seconds 60
                }

                if ($i -gt 15) {
                    $syncTimeout = $true
                    Write-DscStatus "SUM Sync timed out. Skipping Set-CMSoftwareUpdatePointComponent"
                }
            } until ($syncFinished -or $syncTimeout)
        }
    } until ($configured -or $attempts -ge 5)

    if ($configured) {
        Write-DscStatus "SUM Component Configuration successful. Invoking another SUM sync."
        Start-Sleep -Seconds 30
        Sync-CMSoftwareUpdate
    }
    else {
        Write-DscStatus "SUM Component Configuration failed."
    }
}
