#InstallRoles.ps1
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
$CSName = $ThisVM.thisParams.ParentSiteServer
# Per-VM cmOptions wins over the rehydrated global for multi-hierarchy deploys.
$cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
$usePKI = $cmo.UsePKI
$offlineSUP = $cmo.OfflineSUP
if (-not $usePKI) {
    $usePKI = $false
}

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

$Configuration.InstallSUP.Status = "Running"
$Configuration.InstallSUP.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Wait for CS
if ($CSName) {
    # Read Actions file on CAS
    $LogFolder = Split-Path $LogPath -Leaf
    $CSFilePath = "\\$CSName\$LogFolder"
    $CSConfigurationFile = Join-Path -Path $CSFilePath -ChildPath "ScriptWorkflow.json"

    # Wait for ScriptWorkflow.json to exist on CAS
    $CSConfiguration = Get-Content -Path $CSConfigurationFile | ConvertFrom-Json
    Write-DscStatus "Waiting for $CSName to finish SUM Configuration. Current Status: $($CSConfiguration.InstallSUP.Status)."
    while ($CSConfiguration.InstallSUP.Status -ne "Completed") {
        Write-DscStatus "Waiting for $CSName to finish SUM Configuration. Current Status: $($CSConfiguration.InstallSUP.Status)" -NoLog -RetrySeconds 30
        Start-Sleep -Seconds 30
        try {
            $CSConfiguration = Get-Content -Path $CSConfigurationFile -ErrorAction Stop | ConvertFrom-Json
        }
        catch {
            Write-DscStatus "Failed to check Status on $CSName from $CSConfigurationFile. $_"
        }
    }
}

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

# Early exit: check if all configured roles (RP + SUP) are already installed.
# InstallRoles.ps1 is called on every ScriptWorkflow pass, so this avoids
# redundant work when everything is already in place.
$allRolesInstalled = $true

$rpVMs = @($deployConfig.virtualMachines | Where-Object { $_.installRP -eq $true -and ($_.SiteCode -eq $thisVM.SiteCode -or $_.vmName -eq $thisVM.RemoteSQLVM) })
foreach ($rp in $rpVMs) {
    $rpFQDN = $rp.vmName + "." + $DomainFullName
    if (-not (Get-CMReportingServicePoint -SiteSystemServerName $rpFQDN)) {
        $allRolesInstalled = $false
        break
    }
}

if ($allRolesInstalled) {
    $ValidSiteCodes = @($SiteCode)
    if ($ThisVM.role -eq "Primary") {
        $ValidSiteCodes += (Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode)
    }
    $supVMs = @($deployConfig.virtualMachines | Where-Object { $_.installSUP -eq $true -and $_.siteCode -in $ValidSiteCodes })
    foreach ($sup in $supVMs) {
        $supFQDN = $sup.vmName.Trim() + "." + $DomainFullName
        if (-not (Get-CMSoftwareUpdatePoint -SiteSystemServerName $supFQDN)) {
            $allRolesInstalled = $false
            break
        }
    }
}

if ($allRolesInstalled) {
    Write-DscStatus "All roles (RP + SUP) already installed. Nothing to do."
    $Configuration.InstallSUP.Status = 'Completed'
    $Configuration.InstallSUP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

# Reporting Install
Write-DscStatus "Installing Reporting Point"
$rpFailed = $false
foreach ($rp in $deployConfig.virtualMachines | Where-Object { $_.installRP -eq $true } ) {

    $thisSiteCode = $thisVM.SiteCode
    if ($rp.SiteCode -ne $thisSiteCode) {
        #If this is the remote SQL Server for this site code, don't continue
        if ($rp.vmName -ne $thisVM.RemoteSQLVM) {
            continue
        }
    }
    Write-DscStatus "Installing Reporting Point on $($rp.vmName) for site $($thisSiteCode)."
    $netbiosName = $deployConfig.vmOptions.DomainNetBiosName
    $username = $netbiosName + "\cm_svc"
    $databaseName = "CM_" + $thisSiteCode

    #Get the SQL Server. Its either going to be local or remote.
    if ($thisVM.sqlVersion) {
        $sqlServer = $thisVM
    }
    else {
        $sqlServer = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $thisVM.RemoteSQLVM }
    }

    $sqlServerName = $sqlServer.vmName + "." + $DomainFullName

    #Add the SQL Instance if there is one
    #if ($sqlServer.sqlInstance -and $sqlServer.sqlInstance -ne "MSSQLSERVER") {
    #    $sqlServerName += "\" + $sqlServer.SqlInstanceName
    #}

    #Add the SQL Instance, and port
    if ($sqlServer.sqlInstanceName) {
        if ($sqlServer.sqlInstanceName -ne "MSSQLSERVER") {
            $sqlServerName = $sqlServerName + "\" + $sqlServer.sqlInstanceName
        }
    }
    if ($sqlServer.sqlPort) {
        $sqlPort = $sqlServer.sqlPort
    }
    else {
        $sqlPort = 1433
    }
    if ($sqlPort -ne "1433") {
        $sqlServerName = $sqlServerName + "," + $sqlPort
    }

    $PBIRSMachine = $rp.vmName + "." + $DomainFullName

    $cm_svc_file = "$LogPath\cm_svc.txt"
    if (Test-Path $cm_svc_file) {
        # Add cm_svc user as a CM Account
        $unencrypted = Get-Content $cm_svc_file
    }

    Add-ReportingUser -SiteCode $thisSiteCode -UserName $username -Unencrypted $unencrypted
    $rpResult = Install-SRP -ServerSiteCode $thisSiteCode -ServerFQDN $PBIRSMachine -UserName $username -SqlServerName $sqlServerName -DatabaseName $databaseName
    if ($rpResult -eq $false) {
        Write-DscStatus "Reporting Point installation failed for $($rp.vmName). InstallRoles will retry on next ScriptWorkflow pass."
        $rpFailed = $true
    }
}

# End Reporting Install

# SUP Install

$SUPs = @()
$ValidSiteCodes = @($SiteCode)
if ($ThisVM.role -eq "Primary") {
    $ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
    $ValidSiteCodes += $ReportingSiteCodes
}

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
if ($SUPNames) {
    Write-DscStatus "SUP role to be installed on '$($SUPNames -join ',')'"
}

# Kick off the WSUS categories cab import in the background NOW. Done BEFORE
# the $allSUPsInstalled / $SUPs.Count early-returns so a -ResetOnly wipe of
# SUSDB followed by a vmbuild re-run actually exercises the cab path: in that
# scenario CM still has the SUP definition (Get-CMSoftwareUpdatePoint returns
# truthy), $allSUPsInstalled=$true, and the early-return below would skip the
# import. The function is idempotent: 'already-imported' (TaxonomyCats >= 100)
# / 'no-cab' / 'no-wsusutil' all short-circuit cleanly, so it's safe to fire
# on every InstallRoles run regardless of SUP state.
#
# TOP-LEVEL ONLY: only the top-level SUP (syncs from Microsoft Update) may
# import the MU-sourced cab. On a downstream child primary, a local SUP (if any)
# syncs from the CAS upstream; importing would corrupt the sync anchor and break
# it with UssInternalError. Gate on no parentSiteCode. (The function also
# self-guards on the live WSUS upstream config.)
if (-not $ThisVM.parentSiteCode) {
    Start-WsusBaselineImportBackground -Tag "[InstallRoles]" | Out-Null
}
else {
    Write-DscStatus "[InstallRoles] Downstream site (parent=$($ThisVM.parentSiteCode)) - skipping WSUS cab import; categories replicate from the upstream SUP."
}

# Quick check: if all SUPs are already installed, skip the entire install+sync
$allSUPsInstalled = $true
foreach ($SUP in $SUPs) {
    if ([string]::IsNullOrWhiteSpace($SUP.ServerName)) { continue }
    $SUPFQDN = $SUP.ServerName.Trim() + "." + $DomainFullName
    if (-not (Get-CMSoftwareUpdatePoint -SiteSystemServerName $SUPFQDN)) {
        $allSUPsInstalled = $false
        break
    }
}
if ($allSUPsInstalled -and $SUPs.Count -gt 0) {
    Write-DscStatus "All SUP roles already installed. Skipping SUP install and configuration."
    # Wait for any in-flight cab import we just kicked off above before
    # returning, so the caller's Phase 11 taxonomy assertion sees a populated
    # SUSDB. No-op when the import short-circuited (no state file).
    try { Wait-WsusBaselineImport -Tag "[InstallRoles]" } catch { Write-DscStatus "WARNING: Wait-WsusBaselineImport (allSUPsInstalled path) threw: $($_.Exception.Message)" }
    if (-not $rpFailed) {
        $Configuration.InstallSUP.Status = 'Completed'
        $Configuration.InstallSUP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    } else {
        Write-DscStatus "Not marking InstallSUP as Completed because Reporting Point failed."
    }
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}
if ($SUPs.Count -eq 0) {
    Write-DscStatus "No SUPs configured. Skipping SUP install."
    if (-not $rpFailed) {
        $Configuration.InstallSUP.Status = 'Completed'
        $Configuration.InstallSUP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    } else {
        Write-DscStatus "Not marking InstallSUP as Completed because Reporting Point failed."
    }
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

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
    # Grant the SUP server's MACHINE account CM Full Administrator so the Patch My
    # PC publishing service (runs as SYSTEM on the SUP) can author/deploy third-
    # party update CIs. A computer's down-level logon name is DOMAIN\NAME$ -- without
    # the trailing '$' New-CMAdministrativeUser's AD validation fails every run with
    # "Validation of input parameters failed. Cannot continue." (the account never
    # resolves), so the intended grant silently never happened.
    $domainUserName = "$($DomainFullName)\$($SUP.ServerName.Trim())" + '$'
    Write-DscStatus "Installing SUP on $SUPFQDN"
    $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -like "*$domainUserName*" } -ErrorAction SilentlyContinue

    if (-not $exists) {
        try {
            New-CMAdministrativeUser -Name $domainUserName -RoleName "Full Administrator" `
                -SecurityScopeName "All", "All Systems", "All Users and User Groups" -ErrorAction Stop | out-null
        } catch {
            if ($_.Exception.Message -notmatch 'already assigned') { Write-DscStatus "WARNING: New-CMAdministrativeUser failed: $($_.Exception.Message)" }
        }
    }
    Install-SUP -ServerFQDN $SUPFQDN -ServerSiteCode $SUP.ServerSiteCode -usePKI:$usePKI
}

# Configure SUP
#$productsToAdd = @("Windows 10, version 1903 and later", "Microsoft Server operating system-21H2")
#$productsToAdd = @("SQL Server 2005")
#$productsToAdd = @("PowerShell - x64")
#$classificationsToAdd = @("Critical Updates","Definition updates","Security Updates","Upgrades","updates")
$classificationsToAdd = @("Updates")
if ($configureSUP) {

    if ($offlineSUP) {
        Write-DscStatus "Configuring Offline SUP" 
        Set-CMSoftwareUpdatePointComponent -SiteCode $topSite.SiteCode -SynchronizeAction DoNotSynchronizeFromMicrosoftUpdateOrUpstreamDataSource -Schedule $NULL
    }
    else {
        $syncFinished = $syncTimeout = $false
        Write-DscStatus "Configuring SUP, and adding Products [$($productsToAdd -join ',')] and Classifications [$($classificationsToAdd -join ',')]"
        $schedule = New-CMSchedule -RecurCount 1 -RecurInterval Days -Start "2022/1/1 00:00:00"

        try {
            if ($topSite) {
                                            
                $productclassifications = Get-CMSoftwareUpdateCategory -Fast | Where-Object { $_.IsSubscribed } | Select-Object -Expand LocalizedCategoryInstanceName
                $match = $($productclassifications -contains $classificationsToAdd)
                if (-not $match) {
                    Write-DscStatus "Running Set-CMSoftwareUpdatePointComponent."
                    #Set-CMSoftwareUpdatePointComponent -SiteCode $topSite.SiteCode -AddProduct $productsToAdd -AddUpdateClassification $classificationsToAdd -Schedule $schedule -EnableCallWsusCleanupWizard $true -EnableThirdPartyUpdates $true -EnableManualCertManagement $false
                    Set-CMSoftwareUpdatePointComponent -SiteCode $topSite.SiteCode -AddUpdateClassification $classificationsToAdd -Schedule $schedule -EnableCallWsusCleanupWizard $true -EnableThirdPartyUpdates $true -EnableManualCertManagement $false
                    Write-DscStatus "Set-CMSoftwareUpdatePointComponent successful. Waiting for WCM to configure WSUS..."

                    # Poll WCM registry state instead of blind sleep. WCM stores its
                    # configuration result at this key (0=NONE,1=PENDING,2=SUCCESS,3=FAILED,4=SUBSCRIPTION_PENDING).
                    $wcmRegPath = 'HKLM:\SOFTWARE\Microsoft\SMS\COMPONENTS\SMS_WSUS_CONFIGURATION_MANAGER'
                    $wcmStateNames = @{ 0='NONE'; 1='PENDING'; 2='SUCCESS'; 3='FAILED'; 4='SUBSCRIPTION_PENDING' }
                    $wcmReady = $false
                    for ($wcmWait = 1; $wcmWait -le 30; $wcmWait++) {
                        Start-Sleep -Seconds 30
                        try {
                            $wcmRegVal = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
                        } catch { $wcmRegVal = -1 }
                        $wcmName = if ($wcmStateNames.ContainsKey($wcmRegVal)) { $wcmStateNames[$wcmRegVal] } else { "UNKNOWN($wcmRegVal)" }
                        if ($wcmRegVal -eq 2) {
                            Write-DscStatus "WCM reached SUCCESS state (attempt $wcmWait)"
                            $wcmReady = $true
                            break
                        }
                        if ($wcmRegVal -eq 3) {
                            Write-DscStatus "WCM state is FAILED (attempt $wcmWait). Restarting WsusService to trigger reconfiguration."
                            Restart-Service -Name WsusService -Force -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 30
                        }
                        else {
                            Write-DscStatus "WCM state: $wcmName (attempt $wcmWait of 30)"
                        }
                    }
                    if (-not $wcmReady) {
                        Write-DscStatus "WARNING: WCM did not reach SUCCESS after 30 attempts. Proceeding anyway."
                    }
                }
 
                # Wait for the cab import launched at the top of this script
                # (Start-WsusBaselineImportBackground) to finish AND verify
                # the taxonomy actually landed (log marker + count threshold,
                # with a single synchronous retry on partial). wsyncmgr ->
                # WSUS.StartSynchronization() on top of an in-flight or
                # partial cab import races on SUSDB writes and triggers the
                # 'invalid update identity in XML' SqlException. No-op when
                # the cab path wasn't used (no state file).
                Wait-WsusBaselineImport -Tag "[InstallRoles]"

                # Guard against re-runs: if a sync (especially a long Categories
                # sync) is already in progress from a prior build attempt, don't
                # restart it - triggering a new sync cancels the running one and
                # forces a full restart. Only kick off a sync when none is running.
                $preSyncState = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $SiteCode } | Select-Object -First 1
                if ($preSyncState -and $preSyncState.LastSyncState -in @(6701, 6704, 6705, 6706)) {
                    Write-DscStatus "SUM sync already in progress (state $($preSyncState.LastSyncState)) on re-run - not restarting. Waiting for it to complete."
                }
                else {
                    Sync-CMSoftwareUpdate
                    Write-DscStatus "SUM Component Sync started."
                }


                $i = 0
                do {                    
                    $syncState = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.WSUSSourceServer -like "*Microsoft Update*" -and $_.SiteCode -eq $SiteCode } | Select-Object -First 1

                    if (-not $syncState.LastSyncState -or $syncState.LastSyncState -eq 6703) {
                        $i++
                        Write-DscStatus "SUM Sync not detected as running on $($syncState.WSUSServerName). Running Sync to refresh products. (attempt $i of 30)"
                        Sync-CMSoftwareUpdate
                        if ($i -ge 30) {
                            $syncTimeout = $true
                            Write-DscStatus "SUM Sync: gave up after $i attempts. Skipping Set-CMSoftwareUpdatePointComponent"
                        }
                        else {
                            Start-Sleep -Seconds 120
                        }
                    } 
                    else {
                        $syncStateString = "Unknown"
                        switch ($($syncState.LastSyncState)) {
                            "6700" { $syncStateString = "WSUS Sync Manager Error" }
                            "6701" { $syncStateString = "WSUS Synchronization Started" }
                            "6702" { $syncStateString = "WSUS Synchronization Done" }
                            "6703" { $syncStateString = "WSUS Synchronization Failed" }
                            "6704" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing WSUS Server" }
                            "6705" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing SMS Database" }
                            "6706" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing Internet facing WSUS Server" }
                            "6707" { $syncStateString = "Content of WSUS Server is out of sync with upstream server" }
                            "6709" { $syncStateString = "SMS Legacy Update Synchronization started" }
                            "6710" { $syncStateString = "SMS Legacy Update Synchronization done" }
                            "6711" { $syncStateString = "SMS Legacy Update Synchronization failed" }
                        }
                        Write-DscStatus "SUM Sync: Current State: $($syncState.LastSyncState) $syncStateString [$($syncState.WSUSServerName)]"
                        if ($syncState.LastSyncState -eq 6702) {
                            $syncFinished = $true
                            Write-DscStatus "SUM Sync finished."
                        }

                        if (-not $syncFinished) {
                            $i++
                            Start-Sleep -Seconds 60
                        }

                        if ($i -gt 30) {
                            $syncTimeout = $true
                            Write-DscStatus "SUM Sync timed out. Skipping Set-CMSoftwareUpdatePointComponent"
                        }
                    }
                }  until ($syncFinished -or $syncTimeout)
            }
            #Start a 2nd Sync, or an initial sync if not top-level
            start-sleep -seconds 30
            # Same re-run guard: never restart a sync that WSUS/CM still reports
            # as running (a Categories sync can legitimately sit for many minutes).
            $secondSyncState = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $SiteCode } | Select-Object -First 1
            if ($secondSyncState -and $secondSyncState.LastSyncState -in @(6701, 6704, 6705, 6706)) {
                Write-DscStatus "Sync already in progress (state $($secondSyncState.LastSyncState)) - skipping 2nd sync trigger."
            }
            else {
                Sync-CMSoftwareUpdate
            }
        }
        catch { 
            Write-DscStatus "SUM Component Sync failed $_"
            Sync-CMSoftwareUpdate
        }                         
    }
}

if (-not $rpFailed) {
    $Configuration.InstallSUP.Status = 'Completed'
    $Configuration.InstallSUP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
} else {
    Write-DscStatus "Not marking InstallSUP as Completed because Reporting Point failed."
}
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# CM site-role proxy is now applied by phases/ConfigureCMProxy.ps1, invoked
# directly from ScriptWorkflow.ps1 so it runs even when this script returns
# early (e.g. no SUP configured).