# InstallPassiveSiteServer.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath,
    # When set (parallel-Phase8 mode, launched as a background job by
    # Start-ParallelPassiveJob), this script does NOT touch ScriptWorkflow.json --
    # the main ScriptWorkflow thread owns the InstallPassive status before/after
    # the job, so there is never a second concurrent writer to the file.
    [switch]$SkipStatusFileUpdate
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.vmOptions.domainName
#$DomainName = $DomainFullName.Split(".")[0]
$DomainName = $deployConfig.vmOptions.domainNetBiosName

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
# Atomic, mutex-guarded so when this script runs as a background job in parallel
# with the main ScriptWorkflow thread (secondary install / roles / boundary
# groups) neither side clobbers the other's whole-file rewrite. In parallel mode
# (-SkipStatusFileUpdate) the main thread owns this status, so skip the write.
if (-not $SkipStatusFileUpdate) {
    $null = Set-ScriptWorkflowStep -ConfigurationFile $ConfigurationFile -Step 'InstallPassive' -Status 'Running' -StampStartTime
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

# Get info for Passive Site Server
$ThisMachineName = $deployconfig.Parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $deployconfig.Parameters.ThisMachineName }
$SSVM = $deployConfig.virtualMachines | Where-Object { $_.siteCode -eq $ThisVM.siteCode -and $_.role -eq "PassiveSite" }
$shareName = $SiteCode
$sharePath = "E:\$shareName"
$remoteLibVMName = $SSVM.remoteContentLibVM
$passiveFQDN = $SSVM.vmName + "." + $DomainFullName
if ($remoteLibVMName -is [string]) { $remoteLibVMName = $remoteLibVMName.Trim() }
$computersToAdd = @("$($SSVM.vmName)$", "$($ThisMachineName)$")
$contentLibShare = "\\$remoteLibVMName\$shareName\ContentLib"

# Check if Passive already exists
$exists = Get-CMSiteRole -SiteSystemServerName $passiveFQDN -RoleName "SMS Site Server"
if ($exists) {
    # The role existing is necessary but NOT sufficient. A stress build can leave
    # the passive with ServerState in a FAILED category (0x0001FFFF
    # SiteServerInstallationFailed / 0x0002FFFF PREREQ_ERROR): CM can briefly report
    # a Ready-category ServerState (so the first install loop exits "complete") and
    # then regress after the async Stage 14/15 work (install SMS_FAILOVER_MANAGER,
    # validate access to remote site systems) fails -- e.g. sitecomp on the passive
    # couldn't read the install.map from the active during an SMB / content-library
    # blip. CM does NOT self-heal this, and the active failover manager sits idle.
    # So on a RE-RUN, before exiting, read the authoritative ServerState and, when
    # failed, drive the exact console recovery (SMS_SCI_SysResUse.RetryInstallation)
    # until it reaches a Ready category. A healthy passive just exits as before.
    $exPassiveNode = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_SCI_SysResUse `
        -Filter "RoleName = 'SMS Site Server' AND SiteCode = '$SiteCode' AND SiteSystemStatus = 0" -ErrorAction SilentlyContinue | Select-Object -First 1
    $exState = if ($exPassiveNode -and $null -ne $exPassiveNode.ServerState) { [int]$exPassiveNode.ServerState } else { 0 }
    $exStateHex = '0x{0:X8}' -f $exState
    $exFailed = ($exState -gt 0 -and ('{0:X4}' -f ($exState % 65536)).Substring(0, 1) -eq 'F')

    if (-not $exFailed) {
        Write-DscStatus "Passive Site Server is already installed on $($SSVM.vmName) (ServerState=$exStateHex). Exiting."
        if (-not $SkipStatusFileUpdate) { $null = Set-ScriptWorkflowStep -ConfigurationFile $ConfigurationFile -Step 'InstallPassive' -Status 'Completed' -StampEndTime }
        Start-Sleep -Seconds 5 # Force sleep for status to update on host.
        return
    }

    Write-DscStatus "Passive Site Server on $($SSVM.vmName) is present but ConfigMgr reports a FAILED state (ServerState=$exStateHex); driving RetryInstallation (console-equivalent) to finish the stalled HA install."
    $exRetryMax = 2
    $exRetry = 0
    $exDone = $false
    $exLastHex = $exStateHex
    while ($exRetry -lt $exRetryMax -and -not $exDone) {
        try {
            $exServerName = ([string]$exPassiveNode.NetworkOSPath).Replace('\\', '')
            $exClass = [wmiclass]"\\$($smsProvider.FQDN)\$($smsProvider.NamespacePath):SMS_SCI_SysResUse"
            $exMp = $exClass.GetMethodParameters('RetryInstallation')
            $exMp.SiteCode = [string]$exPassiveNode.SiteCode
            $exMp.ServerName = $exServerName
            $null = $exClass.InvokeMethod('RetryInstallation', $exMp, $null)
            $exRetry++
            Write-DscStatus "RetryInstallation invoked for $exServerName (attempt $exRetry/$exRetryMax); waiting up to ~30 min for it to reach Ready." -RetrySeconds 60
        }
        catch {
            Write-DscStatus "Failed to invoke RetryInstallation on $passiveFQDN. Error: $($_.Exception.Message)" -Failure
            return
        }

        # Poll the authoritative ServerState for this retry to reach an OK category.
        for ($w = 1; $w -le 30; $w++) {
            Start-Sleep -Seconds 60
            $exNode2 = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_SCI_SysResUse `
                -Filter "RoleName = 'SMS Site Server' AND SiteCode = '$SiteCode' AND SiteSystemStatus = 0" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $exNode2 -or $null -eq $exNode2.ServerState) { continue }
            $exState2 = [int]$exNode2.ServerState
            $exLastHex = '0x{0:X8}' -f $exState2
            if (($exState2 -band 0xFFFF0000) -eq 0x00030000) {
                Write-DscStatus "Passive site server on $passiveFQDN recovered via RetryInstallation (ServerState=$exLastHex); add complete."
                $exDone = $true
                break
            }
            Write-DscStatus "Waiting for passive $passiveFQDN to recover (ServerState=$exLastHex, attempt $w/30)" -RetrySeconds 60
        }
    }

    if (-not $exDone) {
        Write-DscStatus "Passive site server on $($SSVM.vmName) still not healthy after $exRetry RetryInstallation attempt(s) (last ServerState=$exLastHex). Check failovermgr.log + ConfigMgrSetup.log on $passiveFQDN." -Failure
    }
    elseif (-not $SkipStatusFileUpdate) {
        $null = Set-ScriptWorkflowStep -ConfigurationFile $ConfigurationFile -Step 'InstallPassive' -Status 'Completed' -StampEndTime
    }
    Start-Sleep -Seconds 5 # Force sleep for status to update on host.
    return
}

# Wait for the remote content-library file server to be READY before touching it.
# On an ADD-passive deploy (active site already installed) the active site's
# Phase 8 ScriptWorkflow runs while the brand-new file server is still completing
# its own Phase 2/3 setup. Standing up the content-library share / running
# Move-CMContentLibrary / Add-CMPassiveSite against a not-yet-ready file server
# aborts the passive install (often via a swallowed New-PSSession error in the
# site-system loop below) and leaves the passive node completely empty -- the
# active site then stamps Phase 8 complete and Phase 11 fails on a missing
# SMS_EXECUTIVE. Gate on WinRM reachability + the content-library volume (E:)
# being present and writable first. Bounded; on timeout we leave InstallPassive
# NOT Completed so a later Phase 8 pass retries (this script is idempotent).
if ($remoteLibVMName) {
    Write-DscStatus "Waiting for content-library file server $remoteLibVMName to be ready (WinRM + E: volume)"
    $libReady = $false
    for ($rl = 1; $rl -le 60; $rl++) {
        # up to ~30 min (60 x 30s)
        try {
            $libSession = New-PSSession -ComputerName $remoteLibVMName -ErrorAction Stop
            try {
                $probe = Invoke-Command -Session $libSession -ErrorAction Stop -ScriptBlock {
                    $vol = Get-Volume -DriveLetter 'E' -ErrorAction SilentlyContinue
                    [pscustomobject]@{ HasE = [bool]$vol; Writable = (Test-Path 'E:\') }
                }
            }
            finally { Remove-PSSession $libSession -ErrorAction SilentlyContinue }
            if ($probe -and $probe.HasE -and $probe.Writable) { $libReady = $true; break }
            Write-DscStatus "Content-library file server $remoteLibVMName reachable but E: not ready yet (attempt $rl/60)" -RetrySeconds 30
        }
        catch {
            Write-DscStatus "Content-library file server $remoteLibVMName not reachable yet (attempt $rl/60): $($_.Exception.Message)" -RetrySeconds 30
        }
        Start-Sleep -Seconds 30
    }
    if (-not $libReady) {
        Write-DscStatus "Content-library file server $remoteLibVMName not ready after ~30 min; aborting passive install (InstallPassive left not-Completed for retry)." -Failure
        return
    }
    Write-DscStatus "Content-library file server $remoteLibVMName is ready."
}

# Create share on remote FS to host Content Library
$create_Share = {

    $shareName = $using:shareName
    $sharePath = $using:sharePath
    $computersToAdd = $using:computersToAdd

    $exists = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if ($exists) {
        Grant-SmbShareAccess -Name $shareName -AccountName $computersToAdd -AccessRight Full -Force -ErrorAction Stop
    }
    else {
        New-Item -Path $sharePath -type directory -Force -ErrorAction Stop
        New-Item -Path (Join-Path $sharePath "ContentLib") -type directory -Force -ErrorAction Stop
        New-SMBShare -Name $shareName -Path $sharePath -FullAccess $computersToAdd -ReadAccess Everyone -ErrorAction Stop
    }

    # Configure the access object values - READ-ONLY
    $access = [System.Security.AccessControl.AccessControlType]::Allow
    $rights = [System.Security.AccessControl.FileSystemRights]"FullControl"
    $inherit = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    $propagate = [System.Security.AccessControl.PropagationFlags]::None

    foreach ($item in $computersToAdd) {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule($item, $rights, $inherit, $propagate, $access)

        # Retrieve the directory ACL and add a new ACL rule
        $acl = Get-Acl $sharePath -ErrorAction Stop
        $acl.AddAccessRule($ace)
        $acl.SetAccessRuleProtection($false, $false)

        # Set-Acl $directory $acl
        Set-ACL -aclobject $acl $sharePath -ErrorAction Stop
    }

}

Write-DscStatus "Creating a share on $remoteLibVMName to host the content library"
$shareCreated = $false
for ($attempt = 1; $attempt -le 5; $attempt++) {
    Invoke-Command -Session (New-PSSession -ComputerName $remoteLibVMName) -ScriptBlock $create_Share -ErrorVariable Err2
    if ($Err2.Count -eq 0) {
        $shareCreated = $true
        break
    }
    if ($attempt -lt 5) {
        Write-DscStatus "Share creation attempt $attempt failed (likely AD replication lag). Retrying in 30s. Error: $Err2"
        Start-Sleep -Seconds 30
    }
}
if (-not $shareCreated) {
    Write-DscStatus "Failed to create share $contentLibShare on $remoteLibVMName after 5 attempts. Error: $Err2" -Failure
    return
}

$add_local_admin = {
    param($computersToAdd, $domainName)
    $maxRetries = 5
    $retrySleep = 30
    foreach ($computer in $computersToAdd) {
        if ($computer -eq "$($env:COMPUTERNAME)$") { continue }
        $memberToCheck = "$domainName\$computer"
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                # Use ADSI to check membership; Get-LocalGroupMember -Member can fail
                # if the group contains unresolvable SIDs (orphaned accounts).
                $group = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators"
                $isMember = $group.Invoke('Members') | ForEach-Object {
                    $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null)
                } | Where-Object { $_ -eq $computer.TrimEnd('$') -or $_ -eq $computer }
                if (-not $isMember) {
                    Add-LocalGroupMember -Group "Administrators" -Member $computer -ErrorAction Stop
                }
                break
            }
            catch {
                if ($_.Exception.Message -match 'already a member') {
                    break
                }
                if ($attempt -eq $maxRetries) {
                    throw "Failed to add $memberToCheck to Administrators after $maxRetries attempts. Last error: $_"
                }
                Start-Sleep -Seconds $retrySleep
            }
        }
    }
}

Write-DscStatus "Verifying/adding Active and Passive computer accounts on all site system servers"

# Build a clean, de-duplicated list of site-system computer names. NetworkOSPath
# is normally "\\server.domain.dom", but it can occasionally come back null/blank
# or with stray separators. An unsanitized value handed to New-PSSession throws a
# TERMINATING "One or more computer names are not valid ... pass a URI" error that
# the per-iteration -ErrorVariable cannot trap, so it aborts the WHOLE passive
# install before Move-CMContentLibrary / Add-CMPassiveSite ever run (observed
# deterministically on CSTest1-C: the loop died on the first bad entry, the throw
# was swallowed by Invoke-DotSource, and the passive node stayed empty).
$rawSiteSystems = @()
$rawSiteSystems += @(Get-CMSiteSystemServer -SiteCode $SiteCode | Select-Object -ExpandProperty NetworkOSPath -ErrorAction SilentlyContinue)
$rawSiteSystems += "\\$remoteLibVMName"

$siteSystemNames = New-Object System.Collections.Generic.List[string]
foreach ($raw in $rawSiteSystems) {
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    # Strip the leading \\ (NetworkOSPath / the appended \\FS form) and any whitespace.
    $name = ([string]$raw).Trim().TrimStart('\').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    # A valid computer / DNS name contains no path or URI separators; skipping one
    # malformed entry no longer kills the whole install.
    if ($name -match '[\\/:]') {
        Write-DscStatus "Skipping malformed site-system name '$raw' (not a valid computer name)"
        continue
    }
    $dup = $false
    foreach ($existing in $siteSystemNames) { if ($existing -eq $name) { $dup = $true; break } }
    if (-not $dup) { $siteSystemNames.Add($name) }
}

$localSiteServer = "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
$displayName = $computersToAdd -join ","
$adminAddFailures = New-Object System.Collections.Generic.List[string]
foreach ($serverName in $siteSystemNames) {
    $isLocal = ($serverName -eq $localSiteServer) -or ($serverName -eq $env:COMPUTERNAME)
    $session = $null
    try {
        if ($isLocal) {
            Invoke-Command -ScriptBlock $add_local_admin -ArgumentList $computersToAdd, $DomainName -ErrorAction Stop
        }
        else {
            $session = New-PSSession -ComputerName $serverName -ErrorAction Stop
            Invoke-Command -Session $session -ScriptBlock $add_local_admin -ArgumentList $computersToAdd, $DomainName -ErrorAction Stop
        }
        Write-DscStatus "Verified/added [$displayName] as members of local Administrators group on $serverName."
    }
    catch {
        $adminAddFailures.Add($serverName)
        Write-DscStatus "WARNING: could not add [$displayName] to local Administrators on $serverName`: $($_.Exception.Message)"
    }
    finally {
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
}

# The content-library file server MUST have the accounts (the site server writes
# the moved content library there), so a failure there is fatal -- leave
# InstallPassive not-Completed for a retry. The local site server is added via the
# local path above. Every other site system is best-effort: a single flaky or
# renamed one no longer aborts HA setup.
$libName = ([string]$remoteLibVMName).Trim().TrimStart('\').Trim()
$libFailed = $false
foreach ($f in $adminAddFailures) { if ($f -eq $libName) { $libFailed = $true; break } }
if ($libFailed) {
    Write-DscStatus "Failed to grant [$displayName] local admin on the content-library file server $libName; cannot proceed with passive install." -Failure
    return
}
if ($adminAddFailures.Count -gt 0) {
    Write-DscStatus "Proceeding with passive install; the (best-effort) local-admin add was skipped/failed on: $($adminAddFailures -join ', ')"
}

# Remove SCP?
# Remove-CMServiceConnectionPoint -SiteSystemServerName SCCM-CAS.contosomd.com -Force
# Add NOSMS on all drives but H for fileserver
# Add CAS to admin group on machine
# New-CMSiteSystemServer -SiteCode CAS -SiteSystemServerName SCCM-FileServer.contosomd.com
# Add-CMServiceConnectionPoint -Mode Online -SiteCode CAS -SiteSystemServerName SCCM-FileServer.contosomd.com
# New-CMSiteSystemServer -SiteCode CAS -SiteSystemServerName SCCM-CAS2.contosomd.com

if ((Get-CMDistributionPoint -SiteSystemServerName $localSiteServer).count -eq 1) {
    Write-DscStatus "Removing DP Role from $localSiteServer before moving Content Library."
    Remove-CMDistributionPoint -SiteSystemServerName $localSiteServer -Force *>&1 | Write-StatusLogEntry
}


Write-DscStatus "Moving Content Library to $contentLibShare for site $SiteCode"
Move-CMContentLibrary -NewLocation $contentLibShare -SiteCode $SiteCode *>&1 | Write-StatusLogEntry

$i = 0
$lastMoveProgress = 0
do {
    $moveStatus = Get-CMSite -SiteCode $SiteCode
    $moveProgress = $moveStatus.ContentLibraryMoveProgress

    if ($lastMoveProgress -eq $moveProgress) {
        $i++
    }
    else {
        $i = 0
    }

    if ($i -gt 120) {
        # Bail after progress hasn't change for 60 minutes (30 seconds * 120)
        $bailOut = $true
        break
    }

    Start-Sleep -Seconds 30
    Write-DscStatus "Moving Content Library to $contentLibShare, Current Progress: $moveProgress%" -RetrySeconds 30

    if ($moveStatus.ContentLibraryStatus -eq 3) {
        Write-DscStatus "Content Library Location empty after move. Retrying Content Library Move"
        Move-CMContentLibrary -NewLocation $contentLibShare -SiteCode $SiteCode *>&1 | Write-StatusLogEntry
    }

    $lastMoveProgress = $moveStatus.ContentLibraryMoveProgress

} until ($moveProgress -eq 100 -and (-not [string]::IsNullOrWhitespace($moveStatus.ContentLibraryLocation)))
if ($bailOut) {
    Write-DscStatus "Gave up after 1 hour on Content Library move after move progress stalled at $moveProgress%. Exiting." -Failure
    return
}
else {
    Write-DscStatus "Content Library moved to $($moveStatus.ContentLibraryLocation)"
    start-sleep -Seconds 60
}

# Add Passive site
$SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
if ($SSVM.cmInstallDir) {
    $SMSInstallDir = $SSVM.cmInstallDir
}
while ($true) { 
    Write-DscStatus "Adding passive site server on $passiveFQDN"
    try {
        New-CMSiteSystemServer -SiteCode $SiteCode -SiteSystemServerName $passiveFQDN *>&1 | Write-StatusLogEntry
        Add-CMPassiveSite -InstallDirectory $SMSInstallDir -SiteCode $SiteCode -SiteSystemServerName $passiveFQDN -SourceFilePathOption CopySourceFileFromActiveSite *>&1 | Write-StatusLogEntry
        break
    }
    catch {
        if ($_ -like "*Content library move is in progress, please try again after the move is completed*") {
            Write-DscStatus "Content Library move is in progress, retrying in 5 minutes"
            Start-Sleep -Seconds 300
            continue
        }

        Write-DscStatus "Failed to add passive site on $passiveFQDN. Error: $_" -Failure
        return
    }
}

$i = 0
$failureCount = 0

# --- CM-accurate failure detection + retry (mirrors the admin console) -------
# The console / Set-CMSite read ONE authoritative value for a passive site
# server: SMS_SCI_SysResUse.ServerState (root\SMS\Site_<code>), filtered to the
# passive row (RoleName='SMS Site Server', SiteSystemStatus=0). Verified against
# ConfigMgr source (Constants.cs, Utils.cs ShowStatus/Retry gate, and
# SetSite.cs::RunRetryInstallationForPassiveSite):
#   131071 0x0001FFFF SiteServerInstallationFailed  -> console "Installation failed"
#   196607 0x0002FFFF PREREQ_ERROR                  -> prereq failed
#   generic failure  : (ServerState % 65536) as 4-hex starts with 'F'
#   196608 0x00030000 OK category (Active/Passive/Ready) -> healthy/complete
#   SiteSystemStatus : 0 = Passive, 1 = Active
# The substage tables (SMS_HA_SiteServerDetailedMonitoring.IsComplete=4) do NOT
# reliably flag failure -- that is why the old IsComplete=4 query found nothing
# while the console showed "Installation failed" and the monitor hung. ServerState
# is the real signal, so it now drives both completion and failure here.
# The "Retry installation" console action / Set-CMSite both do exactly one thing
# on failure: call the SMS_SCI_SysResUse.RetryInstallation(SiteCode, ServerName)
# WMI method. We reproduce that here (bounded) instead of hanging or giving up.
$SiteServerInstallationFailed = 131071   # 0x0001FFFF
$PrereqError = 196607                    # 0x0002FFFF
$OkCategoryMask = 0x00030000             # high word -> ready for failover

function Test-CMServerStateFailed {
    param([int]$ServerState)
    if ($ServerState -le 0) { return $false }
    $sub = $ServerState % 65536
    return (('{0:X4}' -f $sub).Substring(0, 1) -eq 'F')
}

function Get-CMPassiveNode {
    param($ProviderFqdn, $Namespace, $Site)
    try {
        Get-WmiObject -ComputerName $ProviderFqdn -Namespace $Namespace -Class SMS_SCI_SysResUse `
            -Filter "RoleName = 'SMS Site Server' AND SiteCode = '$Site' AND SiteSystemStatus = 0" -ErrorAction Stop |
        Select-Object -First 1
    }
    catch { $null }
}

function Get-PassiveSetupFailureDetail {
    param($PassiveVmName)
    try {
        $lines = Invoke-Command -ComputerName $PassiveVmName -ErrorAction Stop -ScriptBlock {
            $log = 'C:\ConfigMgrSetup.log'
            if (Test-Path $log) {
                Get-Content -Path $log -Tail 4000 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match 'error|fail|fatal' } |
                Select-Object -Last 12
            }
        }
        if ($lines) { return ($lines -join " | ") }
    }
    catch { return "Could not read C:\ConfigMgrSetup.log on $PassiveVmName ($($_.Exception.Message))" }
    return $null
}

function Invoke-CMPassiveRetry {
    param($ProviderFqdn, $Namespace, $Node)
    $serverName = ([string]$Node.NetworkOSPath).Replace('\\', '')
    $cmClass = [wmiclass]"\\$ProviderFqdn\${Namespace}:SMS_SCI_SysResUse"
    $mp = $cmClass.GetMethodParameters('RetryInstallation')
    $mp.SiteCode = [string]$Node.SiteCode
    $mp.ServerName = $serverName
    $null = $cmClass.InvokeMethod('RetryInstallation', $mp, $null)
}

# --- Completion / stall watchdog state --------------------------------------
$passiveComplete = $false
$lastProgressSig = $null
$lastProgressChange = Get-Date
$stallHardMinutes = 75   # no forward progress AND CM not-failed/not-ready -> give up
$maxCMRetries = 2        # automatic equivalents of the console "Retry installation" click
$cmRetryCount = 0
do {

    $i++
    $prereqFailure = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_HA_SiteServerDetailedPrereqMonitoring  -Filter "IsComplete = 4 AND Applicable = 1 AND Progress = 100 AND SiteCode = '$SiteCode'" | Sort-Object MessageTime | Select-Object -Last 1
    if ($prereqFailure) {
        Write-DscStatus "Failed to add passive site server on $passiveFQDN due to prereq failure. Reason: $($prereqFailure.SubStageName)" -Failure
    }

    # Informational only: substage rows do not reliably mark failure (see note).
    $installFailure = $false
    $installFailureRow = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_HA_SiteServerDetailedMonitoring -Filter "IsComplete = 4 AND Applicable = 1 AND SiteCode = '$SiteCode'" | Sort-Object MessageTime | Select-Object -Last 1

    $state = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_HA_SiteServerDetailedMonitoring -Filter "IsComplete = 2 AND Applicable = 1 AND SiteCode = '$SiteCode'" | Sort-Object MessageTime | Select-Object -Last 1

    if ($state) {
        Write-DscStatus "Adding passive site server on $passiveFQDN`: $($state.SubStageName)" -RetrySeconds 30

        # No-forward-progress stall detection. A genuinely advancing install
        # changes its SubStageId / MessageTime / Progress; a wedged one keeps
        # reporting the same in-progress row.
        $progressSig = "$($state.SubStageId)|$($state.MessageTime)|$($state.Progress)"
        if ($progressSig -ne $lastProgressSig) {
            $lastProgressSig = $progressSig
            $lastProgressChange = Get-Date
        }
    }

    # --- Authoritative CM state (the value the console reads) -----------------
    $cmNode = Get-CMPassiveNode -ProviderFqdn $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Site $SiteCode
    if ($cmNode -and ($null -ne $cmNode.ServerState)) {
        $serverState = [int]$cmNode.ServerState
        $serverStateHex = '0x{0:X8}' -f $serverState
        $cmReady = (($serverState -band 0xFFFF0000) -eq $OkCategoryMask)
        $cmFailed = Test-CMServerStateFailed -ServerState $serverState

        if ($cmReady) {
            Write-DscStatus "ConfigMgr reports passive site server on $passiveFQDN ready (ServerState=$serverStateHex); add complete."
            $passiveComplete = $true
        }
        elseif ($cmFailed) {
            # CM has declared failure -- exactly what the console surfaces as
            # "Installation failed" (and what gates its Retry installation button:
            # ServerState == SiteServerInstallationFailed or PREREQ_ERROR).
            $failKind = if ($serverState -eq $PrereqError) { "prereq check failed" } elseif ($serverState -eq $SiteServerInstallationFailed) { "installation failed" } else { "failed" }
            $detail = Get-PassiveSetupFailureDetail -PassiveVmName $SSVM.vmName
            if ($detail) {
                Write-DscStatus "ConfigMgr reports passive site server on $passiveFQDN $failKind (ServerState=$serverStateHex). Setup log: $detail"
            }
            else {
                Write-DscStatus "ConfigMgr reports passive site server on $passiveFQDN $failKind (ServerState=$serverStateHex)."
            }

            if ($cmRetryCount -lt $maxCMRetries) {
                $cmRetryCount++
                try {
                    Write-DscStatus "Retrying passive install the same way the console does (SMS_SCI_SysResUse.RetryInstallation), attempt $cmRetryCount/$maxCMRetries."
                    Invoke-CMPassiveRetry -ProviderFqdn $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Node $cmNode
                    # Retry re-enters the install pipeline; reset the stall clock
                    # so the watchdog measures the fresh attempt, not the wait.
                    $lastProgressChange = Get-Date
                    $lastProgressSig = $null
                    Start-Sleep -Seconds 60
                }
                catch {
                    Write-DscStatus "Failed to invoke RetryInstallation on $passiveFQDN. Error: $($_.Exception.Message)" -Failure
                    $installFailure = $true
                }
            }
            else {
                Write-DscStatus "Passive site server on $passiveFQDN still $failKind after $maxCMRetries retries (ServerState=$serverStateHex); giving up. Check ConfigMgrSetup.log on $passiveFQDN." -Failure
                $installFailure = $true
            }
        }
    }
    elseif ($installFailureRow) {
        # Fall back to the substage failure row only when CM exposes no ServerState
        # (older provider). Give recoverable transients ~10 min before failing.
        $failureCount++
        if ($failureCount -gt 10) {
            Write-DscStatus "Failed to add passive site server on $passiveFQDN. Failure State: $($installFailureRow.SubStageName): $($installFailureRow.Description)" -Failure
            $installFailure = $true
        }
    }
    else {
        $failureCount = 0
    }

    if (-not $state -and -not $passiveComplete) {
        if ($i -gt 61) {
            Write-DscStatus "No Progress for adding passive site server reported after $($i * 30) seconds, giving up." -Failure
            $installFailure = $true
        }
    }

    # Ground-truth completion fallback (only when CM did not already report ready
    # or failed). Role-present + SMS_EXECUTIVE Running is necessary but, on its
    # own, NOT sufficient (CM can still report "Installation failed" while the
    # service is up), so it is gated on CM NOT being in a failed state.
    if (-not $passiveComplete -and -not $installFailure -and -not $prereqFailure -and (0 -eq $i % 5)) {
        $roleNow = Get-CMSiteRole -SiteSystemServerName $passiveFQDN -RoleName "SMS Site Server" -ErrorAction SilentlyContinue
        if ($roleNow) {
            $execRunning = $false
            try {
                $execSvc = Get-Service -ComputerName $SSVM.vmName -Name 'SMS_EXECUTIVE' -ErrorAction Stop
                $execRunning = ($execSvc.Status -eq 'Running')
            }
            catch { $execRunning = $false }
            if ($execRunning) {
                Write-DscStatus "Passive site server ground-truth complete on $($SSVM.vmName): SMS Site Server role present and SMS_EXECUTIVE Running, and ConfigMgr is not reporting a failed state."
                $passiveComplete = $true
            }
        }
    }

    # Stall watchdog backstop: a wedged in-progress row that CM has neither marked
    # ready nor failed for a long window -> give up so the phase can't hang forever.
    if ($state -and -not $passiveComplete -and -not $installFailure) {
        $stalledMinutes = ((Get-Date) - $lastProgressChange).TotalMinutes
        if ($stalledMinutes -ge $stallHardMinutes) {
            Write-DscStatus "Passive install stuck at '$($state.SubStageName)' for $([int]$stalledMinutes) min with no forward progress and ConfigMgr reporting neither ready nor failed on $passiveFQDN; giving up. Check ConfigMgrSetup.log on $passiveFQDN." -Failure
            $installFailure = $true
        }
    }

    Start-Sleep -Seconds 60

} until ($state.SubStageId -eq 917515 -or $passiveComplete -or $prereqFailure -or $installFailure)

# Update actions file (mutex-guarded; safe under parallel execution). In parallel
# mode the main ScriptWorkflow thread stamps Completed after joining the job
# (gated on the passive role actually being present), so skip the write here.
if (-not $SkipStatusFileUpdate) {
    $null = Set-ScriptWorkflowStep -ConfigurationFile $ConfigurationFile -Step 'InstallPassive' -Status 'Completed' -StampEndTime
}