# ScriptWorkflow.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# dot source functions
. $PSScriptRoot\ScriptFunctions.ps1

# Banner: emit a clearly-delimited start-of-run marker into InstallCMLog.log
# so multiple ScriptWorkflow invocations on the same VM (reruns, retries,
# DSC re-applies) are easy to tell apart when scrolling the log.
try {
    $bannerPid    = $PID
    $bannerHost   = $env:COMPUTERNAME
    $bannerUser   = "$($env:USERDOMAIN)\$($env:USERNAME)"
    $bannerPSVer  = $PSVersionTable.PSVersion.ToString()
    $bannerOS     = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { '<unknown>' }
    # Last boot time + uptime. Logging this in every ScriptWorkflow banner makes
    # a mid-run reboot trivial to spot: if a later banner shows a fresh boot time
    # (low uptime) the box restarted between runs -- a common cause of half-
    # finished work (e.g. an orphaned background download whose join never ran).
    $bannerBoot   = try {
        $lbt = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $up  = (Get-Date) - $lbt
        '{0:yyyy-MM-dd HH:mm:ss} (up {1}d {2}h {3}m)' -f $lbt, $up.Days, $up.Hours, $up.Minutes
    } catch { '<unknown>' }
    $bannerStart  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $bannerCwd    = (Get-Location).Path
    $bannerScript = $MyInvocation.MyCommand.Path
    try {
        $bannerCmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).CommandLine
    } catch { $bannerCmdLine = '<unavailable>' }
    try {
        $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
        $parent    = Get-CimInstance Win32_Process -Filter "ProcessId=$parentPid" -ErrorAction Stop
        $bannerParent = "$($parent.Name) (PID $parentPid)"
    } catch { $bannerParent = '<unavailable>' }

    '' | Write-StatusLogEntry -Component 'ScriptWorkflow' -AllowBlank
    '' | Write-StatusLogEntry -Component 'ScriptWorkflow' -AllowBlank
    ('=' * 100)                                                                | Write-StatusLogEntry -Component 'ScriptWorkflow'
    ' ScriptWorkflow.ps1 - START'                                              | Write-StatusLogEntry -Component 'ScriptWorkflow'
    ('=' * 100)                                                                | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  Started      : $bannerStart"                                            | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  PID          : $bannerPid"                                              | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  Parent       : $bannerParent"                                           | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  Host         : $bannerHost"                                             | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  User         : $bannerUser"                                             | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  OS           : $bannerOS"                                               | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  LastBoot     : $bannerBoot"                                             | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  PowerShell   : $bannerPSVer"                                            | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  Script       : $bannerScript"                                           | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  Cwd          : $bannerCwd"                                              | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  CommandLine  : $bannerCmdLine"                                          | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  ConfigFile   : $ConfigFilePath"                                         | Write-StatusLogEntry -Component 'ScriptWorkflow'
    "  LogPath      : $LogPath"                                                | Write-StatusLogEntry -Component 'ScriptWorkflow'
    ('=' * 100)                                                                | Write-StatusLogEntry -Component 'ScriptWorkflow'
}
catch {
    # Don't let banner failure stop the workflow
    "ScriptWorkflow banner failed: $_" | Write-StatusLogEntry -Component 'ScriptWorkflow' -Type 2
}

Write-DscStatus "ScriptWorkflow.ps1 called with $ConfigFilePath and $LogPath)"

# Read the per-deploy RunId stamped by the orchestrator (Common.ScriptBlocks.ps1)
# right before it began monitoring this phase. We'll echo it back into
# ScriptWorkflow.completed.runid at the very end so the orchestrator can
# detect completion authoritatively (immune to status-string overwrites).
$ExpectedRunIdFile  = 'C:\staging\DSC\ScriptWorkflow.expected.runid'
$CompletedRunIdFile = 'C:\staging\DSC\ScriptWorkflow.completed.runid'
$ScriptWorkflowRunId = $null
if (Test-Path $ExpectedRunIdFile) {
    $ScriptWorkflowRunId = (Get-Content $ExpectedRunIdFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    Write-DscStatus "ScriptWorkflow.ps1 RunId for this deploy: $ScriptWorkflowRunId"
}

# Read required items from config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $deployconfig.Parameters.ThisMachineName }
$CurrentRole = $ThisVM.role

$scenario = "Standalone"
if ($ThisVM.role -eq "CAS" -or $ThisVM.parentSiteCode) { $scenario = "Hierarchy" }

$TopLevelSiteServer = $true
if ($ThisVM.parentSiteCode) {
    $TopLevelSiteServer = $false
}
# contains passive?
$containsPassive = $false
$containsSecondary = $false

if ($CurrentRole -eq "Primary" -and $ThisVM.hidden -and ($ThisVM.domain) -and ($ThisVm.domain -ne $deployConfig.vmOptions.DomainName)) {
    $scenario = "MultiDomain"
    Write-DscStatus "Multi Domain Scenario"
}
else {
    # contains passive?
    $containsPassive = $deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $ThisVM.siteCode }
    $containsSecondary = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" -and $_.parentSiteCode -eq $ThisVM.siteCode }
}


# Script Workflow json file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$firstRun = $true

if (Test-Path -Path $ConfigurationFile) {
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    $firstRun = $false
    # Immediately reset status so WaitForEvent won't find stale "Completed" from a previous run
    if ($Configuration.ScriptWorkflow -and $Configuration.ScriptWorkflow.Status -eq "Completed") {
        $Configuration.ScriptWorkflow.Status = "Running"
        $Configuration.ScriptWorkflow.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }

    # Add-to-existing: the deployConfig may contain new SiteSystem VMs that
    # need DP/MP/SUP installed, but the previous deploy already marked
    # InstallDP/InstallSUP as Completed. Reset those statuses when the
    # current deployConfig has SiteSystem VMs requesting those roles so the
    # installer scripts actually run.
    $newSiteSystemVMs = @($deployConfig.virtualMachines | Where-Object { $_.role -eq 'SiteSystem' })
    if ($newSiteSystemVMs.Count -gt 0) {
        $needsDP  = @($newSiteSystemVMs | Where-Object { $_.installDP }).Count -gt 0
        $needsMP  = @($newSiteSystemVMs | Where-Object { $_.installMP }).Count -gt 0
        $needsSUP = @($newSiteSystemVMs | Where-Object { $_.installSUP -or $_.installRP }).Count -gt 0
        if (($needsDP -or $needsMP) -and $Configuration.InstallDP -and $Configuration.InstallDP.Status -eq 'Completed') {
            Write-DscStatus "Resetting InstallDP status (new SiteSystem VMs with DP/MP found)"
            $Configuration.InstallDP.Status = 'NotStart'
            $Configuration.InstallDP.StartTime = ''
            $Configuration.InstallDP.EndTime = ''
            if ($Configuration.InstallMP) {
                $Configuration.InstallMP.Status = 'NotStart'
                $Configuration.InstallMP.StartTime = ''
                $Configuration.InstallMP.EndTime = ''
            }
        }
        if ($needsSUP -and $Configuration.InstallSUP -and $Configuration.InstallSUP.Status -eq 'Completed') {
            Write-DscStatus "Resetting InstallSUP status (new SiteSystem VMs with SUP found)"
            $Configuration.InstallSUP.Status = 'NotStart'
            $Configuration.InstallSUP.StartTime = ''
            $Configuration.InstallSUP.EndTime = ''
        }
    }
}
if (-not ($configuration.ScriptWorkflow)) {
    $Configuration = $null
}
if (-not $Configuration) {
    if ($scenario -eq "Standalone") {
        [hashtable]$Actions = @{
            InstallSCCM    = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            UpgradeSCCM    = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallDP      = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallMP      = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallClient  = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            ScriptWorkflow = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
        }
    }

    if ($scenario -eq "Hierarchy") {
        if ($CurrentRole -eq "CAS") {
            [hashtable]$Actions = @{
                InstallSCCM    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                UpgradeSCCM    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                ScriptWorkflow = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
            }
            $psvms = $deployConfig.VirtualMachines | Where-Object { $_.Role -eq "Primary" -and ($_.ParentSiteCode -eq $thisVM.SiteCode) }
            foreach ($psvm in $psvms) {
                $PSReadytoUse = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                $propName = propName = "PSReadyToUse" + $psvm.VmName
                $Actions.Add($propName, $PSReadytoUse)
            }
        }
        elseif ($CurrentRole -eq "Primary") {
            [hashtable]$Actions = @{
                WaitingForCASFinishedInstall = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallSCCM                  = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallDP                    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallMP                    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallClient                = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                ScriptWorkflow               = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
            }
        }
    }

    if ($containsPassive) {
        $Actions += @{
            InstallPassive = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
        }
    }

    if ($containsSecondary) {
        $Actions += @{
            InstallSecondary = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
        }
    }

    $Configuration = New-Object -TypeName psobject -Property $Actions
}

if (-not $Configuration.InstallSUP) {
    $item = [PSCustomObject]@{
        Status    = 'NotStart'
        StartTime = ''
        EndTime   = ''
    }
    $Configuration | Add-Member -MemberType NoteProperty -Name "InstallSUP" -Value $item -force
}

if (-not $Configuration.ConfigureCMProxy) {
    $item = [PSCustomObject]@{
        Status    = 'NotStart'
        StartTime = ''
        EndTime   = ''
    }
    $Configuration | Add-Member -MemberType NoteProperty -Name "ConfigureCMProxy" -Value $item -Force
}

$Configuration.ScriptWorkflow.Status = "Running"
$Configuration.ScriptWorkflow.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Force AD Replication (only on first run)
if ($firstRun) {
    $domainControllers = Get-ADDomainController -Filter * -ErrorAction SilentlyContinue
    if ($domainControllers.Count -gt 1) {
        Write-DscStatus "Forcing AD Replication on $($domainControllers.Name -join ', ')"
        # Run repadmin in a job with a hard timeout. If a DC's NTDS is still
        # initializing (e.g. BDC just promoted), repadmin /syncall can hang
        # indefinitely waiting for RPC. A job + Wait-Job is the only reliable
        # kill switch in PS 5.1.
        $dcNames = @($domainControllers.Name)
        $domainDistinguishedName = (Get-ADDomain).DistinguishedName
        $replJob = Start-Job -ScriptBlock {
            param($dcNames, $dn)
            $dcNames | ForEach-Object { repadmin /syncall $_ $dn /AdeP 2>&1 | Out-Null }
        } -ArgumentList $dcNames, $domainDistinguishedName
        $null = Wait-Job $replJob -Timeout 60
        if ($replJob.State -eq 'Running') {
            Stop-Job $replJob -ErrorAction SilentlyContinue
        }
        Remove-Job $replJob -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

if ($scenario -eq "MultiDomain") {
    Write-DscStatus "$scenario Running InstallMultiDomainPKI.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallMultiDomainPKI.ps1"
    Set-Location $LogPath
    Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    $Configuration.ScriptWorkflow.Status = "Completed"
    $Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    Write-DscStatus "Complete!"
    # Stamp completion RunId for the orchestrator's race-proof completion check
    if ($ScriptWorkflowRunId) {
        try { Set-Content -Path $CompletedRunIdFile -Value $ScriptWorkflowRunId -Force -Encoding ASCII } catch {}
    }
    return
}

if ($scenario -eq "Standalone") {

    #Install CM and Config
    Write-DscStatus "$scenario Running InstallAndUpdateSCCM.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallAndUpdateSCCM.ps1"
    Set-Location $LogPath
    Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

    # Enable HTTPS/eHTTP early so the site component manager has maximum
    # time to republish the updated OperationalXml (SecurityModeMaskEx) to
    # AD before PushClients runs. The flag file prevents double execution
    # if this already ran inside InstallAndUpdateSCCM's update loop.
    $cmoEarly = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
    if (-not $cmoEarly.UsePKI) {
        Write-DscStatus "$scenario Early EnableEHTTP.ps1"
        Invoke-DotSource -Script "$PSScriptRoot\EnableEHTTP.ps1" -Arguments $ConfigFilePath, $LogPath, $firstRun
    }
    else {
        Write-DscStatus "$scenario Early EnableHTTPS.ps1"
        Invoke-DotSource -Script "$PSScriptRoot\EnableHTTPS.ps1" -Arguments $ConfigFilePath, $LogPath, $firstRun
    }

    #Install DP/MP/Client - Run before secondary so MP can be installed on sitesytems
    if ($Configuration.InstallDP.Status -ne "Completed") {
        Write-DscStatus "$scenario Running InstallDPMPClient.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallDPMPClient.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath
    }
    else {
        Write-DscStatus "$scenario Skipping InstallDPMPClient.ps1 (already completed)"
    }

    # Start AD Discovery early so DDRs have maximum processing time before PushClients
    try {
        Set-Location $LogPath
        . $PSScriptRoot\Connect-CMSite.ps1 -Tag "[EarlyDiscovery]"
        $DomainDN = 'DC=' + ($deployConfig.vmOptions.domainName).Replace('.',',DC=')
        Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $SiteCode -Enabled $true -AddActiveDirectoryContainer "LDAP://$DomainDN" -Recursive
        Invoke-CMSystemDiscovery
        Write-DscStatus "AD System Discovery invoked early (pre-staging for client push)"
    }
    catch {
        Write-DscStatus "Early AD Discovery: $($_.Exception.Message)"
    }
    Set-Location $LogPath

    if ($containsSecondary) {
        # Install Secondary Site Server. Run before InstallBoundaryGroups.ps1, so it can create proper BGs
        Write-DscStatus "$scenario Running InstallSecondarySiteServer.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallSecondarySiteServer.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath
    }

    Write-DscStatus "$scenario Running InstallRoles.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
    Set-Location $LogPath
    Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

    # ConfigureCMProxy is cheap and idempotent; always run it so latched
    # Completed state from a deploy that ran before the Proxy was hydrated
    # into deployConfig can self-heal on the next pass. The script itself
    # short-circuits when there's no Proxy or no opted-in clients.
    Write-DscStatus "$scenario Running ConfigureCMProxy.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "ConfigureCMProxy.ps1"
    Set-Location $LogPath
    Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

    #Install BGs -- Must run after InstallRoles so DPs MPs and SUPs can be detected
    Write-DscStatus "$scenario Running InstallBoundaryGroups.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallBoundaryGroups.ps1"
    Set-Location $LogPath
    Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

}

if ($scenario -eq "Hierarchy") {

    if ($CurrentRole -eq "CAS") {

        #Install CM and Config
        Write-DscStatus "$scenario Running InstallAndUpdateSCCM.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallAndUpdateSCCM.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

        # Enable HTTPS/eHTTP early on CAS too (same reasoning as Standalone).
        $cmoEarly = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        if (-not $cmoEarly.UsePKI) {
            Write-DscStatus "$scenario CAS Early EnableEHTTP.ps1"
            Invoke-DotSource -Script "$PSScriptRoot\EnableEHTTP.ps1" -Arguments $ConfigFilePath, $LogPath, $firstRun
        }
        else {
            Write-DscStatus "$scenario CAS Early EnableHTTPS.ps1"
            Invoke-DotSource -Script "$PSScriptRoot\EnableHTTPS.ps1" -Arguments $ConfigFilePath, $LogPath, $firstRun
        }

        Write-DscStatus "$scenario Running InstallRoles.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

        # ConfigureCMProxy is cheap and idempotent; always run.
        Write-DscStatus "$scenario Running ConfigureCMProxy.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "ConfigureCMProxy.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

    }
    elseif ($CurrentRole -eq "Primary") {

        #Install CM and Config
        if (-not [string]::IsNullOrWhiteSpace($($ThisVM.thisParams.ParentSiteServer))) {
            Write-DscStatus "$scenario Running InstallPSForHierarchy.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallPSForHierarchy.ps1"
            Set-Location $LogPath
            Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath
        }

        # Enable HTTPS/eHTTP early on Primary too (same reasoning as Standalone).
        $cmoEarly = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        if (-not $cmoEarly.UsePKI) {
            Write-DscStatus "$scenario Primary Early EnableEHTTP.ps1"
            Invoke-DotSource -Script "$PSScriptRoot\EnableEHTTP.ps1" -Arguments $ConfigFilePath, $LogPath, $firstRun
        }
        else {
            Write-DscStatus "$scenario Primary Early EnableHTTPS.ps1"
            Invoke-DotSource -Script "$PSScriptRoot\EnableHTTPS.ps1" -Arguments $ConfigFilePath, $LogPath, $firstRun
        }

        #Install DP/MP/Client - Run before secondary so MP can be installed on sitesytems
        if ($Configuration.InstallDP.Status -ne "Completed") {
            Write-DscStatus "$scenario Running InstallDPMPClient.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallDPMPClient.ps1"
            Set-Location $LogPath
            Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath
        }
        else {
            Write-DscStatus "$scenario Skipping InstallDPMPClient.ps1 (already completed)"
        }

        # Start AD Discovery early so DDRs have maximum processing time before PushClients
        try {
            Set-Location $LogPath
            . $PSScriptRoot\Connect-CMSite.ps1 -Tag "[EarlyDiscovery]"
            $DomainDN = 'DC=' + ($deployConfig.vmOptions.domainName).Replace('.',',DC=')
            Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $SiteCode -Enabled $true -AddActiveDirectoryContainer "LDAP://$DomainDN" -Recursive
            Invoke-CMSystemDiscovery
            Write-DscStatus "AD System Discovery invoked early (pre-staging for client push)"
        }
        catch {
            Write-DscStatus "Early AD Discovery: $($_.Exception.Message)"
        }
        Set-Location $LogPath
               
        if ($containsSecondary) {
            # Install Secondary Site Server. Run before InstallBoundaryGroups.ps1, so it can create proper BGs
            Write-DscStatus "$scenario Running InstallSecondarySiteServer.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallSecondarySiteServer.ps1"
            Set-Location $LogPath
            Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath
        }

        Write-DscStatus "$scenario Running InstallRoles.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

        # ConfigureCMProxy is cheap and idempotent; always run.
        Write-DscStatus "$scenario Running ConfigureCMProxy.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "ConfigureCMProxy.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

         #Install BGs -- Must run after InstallRoles so DPs MPs and SUPs can be detected
        Write-DscStatus "$scenario Running InstallBoundaryGroups.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallBoundaryGroups.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

    }
}

if ($containsPassive) {
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    $DomainFullName = $deployConfig.vmOptions.domainName
    $passiveFQDN = $containsPassive.vmName + "." + $DomainFullName
    $passiveExists = Get-CMSiteRole -SiteSystemServerName $passiveFQDN -RoleName "SMS Site Server" -ErrorAction SilentlyContinue
    if ($Configuration.InstallPassive.Status -ne "Completed" -or -not $passiveExists) {
        Write-DscStatus "ContainsPassive Running InstallPassiveSiteServer.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallPassiveSiteServer.ps1"
        Set-Location $LogPath
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath

        # Wait for SMS_EXECUTIVE to start on the passive node before proceeding.
        # InstallPassiveSiteServer.ps1 exits at SubStageId 917515, but the
        # SMS_EXECUTIVE service may still be starting on the passive node.
        $passiveSmsSvc = $null
        $maxPassiveWait = 10
        $passiveWaitDelay = 30
        for ($pw = 1; $pw -le $maxPassiveWait; $pw++) {
            try {
                $passiveSmsSvc = Get-Service -ComputerName $containsPassive.vmName -Name 'SMS_EXECUTIVE' -ErrorAction Stop
                if ($passiveSmsSvc.Status -eq 'Running') {
                    Write-DscStatus "SMS_EXECUTIVE is Running on $($containsPassive.vmName) (attempt $pw)"
                    break
                }
                Write-DscStatus "SMS_EXECUTIVE on $($containsPassive.vmName): $($passiveSmsSvc.Status) (attempt $pw/$maxPassiveWait)"
            }
            catch {
                Write-DscStatus "SMS_EXECUTIVE not yet reachable on $($containsPassive.vmName): $($_.Exception.Message) (attempt $pw/$maxPassiveWait)"
            }
            if ($pw -lt $maxPassiveWait) { Start-Sleep -Seconds $passiveWaitDelay }
        }
        if (-not $passiveSmsSvc -or $passiveSmsSvc.Status -ne 'Running') {
            Write-DscStatus "WARNING: SMS_EXECUTIVE not Running on $($containsPassive.vmName) after $maxPassiveWait attempts" -Warning
        }
    }
    else {
        Write-DscStatus "ContainsPassive Skipping InstallPassiveSiteServer.ps1 (passive role verified on $($containsPassive.vmName))"
    }
}

Write-DscStatus "Finished setting up ConfigMgr. Running Additional Tasks"
if ($CurrentRole -eq "CAS") {
    #If we are on the CAS, we can mark this early, to allow the primary to start while we run other tasks.
    # Mark ScriptWorkflow completed for DSC to move on.
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    $Configuration.ScriptWorkflow.Status = "Completed"
    $Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

}


# Per-VM cmOptions (multi-hierarchy safe).
$cmo = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
if (-not $cmo.UsePKI) {
    # Enable E-HTTP. This takes time on new install because SSLState flips, so start the script but don't monitor.
    Write-DscStatus "Not UsePKI Running EnableEHTTP.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableEHTTP.ps1"
    try {
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath, $firstRun
    }
    catch {
        Write-DscStatus "EnableEHTTP.ps1 failed: $_" -Warning
    }
}
else {
    Write-DscStatus "UsePKI Running EnableHTTPS.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableHTTPS.ps1"
    try {
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath, $firstRun
    }
    catch {
        Write-DscStatus "EnableHTTPS.ps1 failed: $_" -Warning
    }
}

# Kick off remote SMS Provider installs (InstallProvider.ps1) as a background
# job BEFORE perfloading so the per-provider setupwpf.exe runs (~5-15 min each)
# overlap the long perfloading work instead of running dead-last/sequentially.
# InstallProvider.ps1 only needs the site installed (roles done by here in both
# the standalone and hierarchy paths) and is idempotent via SMS_ProviderLocation.
# The matching join is below, where the inline call used to be. When perfloading
# doesn't run (CAS, or PrePopulate=false) the job starts then immediately joins,
# so behavior is no worse than today.
$installProviderJob = Start-Job -Name "InstallProvider" -ScriptBlock {
    param($jobConfigFilePath, $jobLogPath, $jobScriptRoot)
    # Dot-source ScriptFunctions.ps1 so InstallProvider.ps1 can call Write-DscStatus.
    . (Join-Path -Path $jobScriptRoot -ChildPath "ScriptFunctions.ps1")
    Set-Location $jobLogPath
    & (Join-Path -Path $jobScriptRoot -ChildPath "InstallProvider.ps1") -ConfigFilePath $jobConfigFilePath -LogPath $jobLogPath
} -ArgumentList $ConfigFilePath, $LogPath, $PSScriptRoot
Write-DscStatus "Started background InstallProvider.ps1 job (overlaps perfloading)"

if (($CurrentRole -eq "Primary" -or $TopLevelSiteServer) -and $cmo.PrePopulateObjects -eq $true) {
    Write-DScStatus "Loading object pre-population for MEMLABS"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "Perfloading.ps1"
    Set-Location $LogPath
    try {
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath
    }
    catch {
        Write-DscStatus "Perfloading.ps1 failed: $_" -Warning
    }

}

  # Install Providers — join the background job started before perfloading.
  Write-DscStatus "Waiting for background InstallProvider.ps1 job to complete"
  try {
      Wait-Job -Job $installProviderJob | Out-Null
      # Write-DscStatus writes status/log to disk from the job runspace, so the
      # pipeline output isn't needed here; discard it. A terminating failure in
      # the job still rethrows on Receive-Job and is caught below.
      Receive-Job -Job $installProviderJob | Out-Null
      Remove-Job -Job $installProviderJob -Force -ErrorAction SilentlyContinue
  }
  catch {
      Write-DscStatus "InstallProvider.ps1 failed: $_" -Warning
  }
  
# CAS already marked JSON Completed above to unblock DSC phases.
# Signal Complete! now so the host advances CAS past Phase 8 while
# PushClients, EnableBLM, etc. continue running in the background.
# Non-CAS: defer Complete! until after all post-install work finishes
# so Phase 11 validates a stable, fully-configured site.
if ($CurrentRole -eq "CAS") {
    Write-DscStatus "Complete!"
}

# PushClients first so auto-push has maximum time to install the agent on
# all targets while EnableBLM configures policies and collections.
if ($ThisVM.role -ne "CAS") {
    # Cross-tier PKI pre-stage handshake. ScriptWorkflow runs inside the guest
    # and cannot PSDirect into the client VMs, but the HOST monitor can. Emit a
    # sentinel status the host watches for, then pause ~60s so the host can
    # pulse + verify the offline-root/sub-CA chain into every push client's
    # LocalMachine cert stores BEFORE auto-push runs ccmsetup. Without the full
    # chain the client fails GetDPLocations (0x87d00454) over HTTPS. Non-PKI
    # deploys skip this so they are not delayed.
    if ($cmo.UsePKI) {
        Write-DscStatus "MEMLABS-PULSE-CERTS: Waiting for host to refresh certificates on clients"
        Start-Sleep -Seconds 60
    }
    Write-DscStatus "Always Running PushClients.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "PushClients.ps1"
    Set-Location $LogPath
    try {
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath
    }
    catch {
        Write-DscStatus "PushClients.ps1 failed: $_" -Warning
    }
}

# EnableBLM only needs AD-discovered devices (not pushed clients) for its
# collection query rules, so it is safe to run after PushClients kicks off
# auto-push. If PushClients fails, EnableBLM still runs.
if ($CurrentRole -eq "Primary") {
    Write-DscStatus "Running EnableBLM.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableBLM.ps1"
    Set-Location $LogPath
    try {
        Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath
    }
    catch {
        Write-DscStatus "EnableBLM.ps1 failed: $_" -Warning
    }
}

# Reset SMS component status counts on site servers. New installs accumulate
# transient warnings/errors from components that started before all their
# dependencies were ready (SMS_DATABASE_NOTIFICATION_MONITOR,
# SMS_DISCOVERY_DATA_MANAGER, etc.). Once the site is fully wired these
# components are healthy but their status counters still show the startup
# noise, which Phase 11 validation flags as WARN. This is equivalent to
# right-clicking each component in the console and choosing "Reset Counts".
if ($CurrentRole -in @("Primary", "CAS", "Secondary")) {
    try {
        $svrSiteCode = $ThisVM.siteCode
        if ($svrSiteCode) {
            Write-DscStatus "Resetting SMS component status counts for site $svrSiteCode"
            $ns = "root\sms\site_$svrSiteCode"
            $sums = @(Get-WmiObject -Namespace $ns -Class SMS_ComponentSummarizer -ErrorAction Stop)
            $resetCount = 0
            foreach ($s in $sums) {
                try { [void]$s.ResetCounts(); $resetCount++ } catch { }
            }
            Write-DscStatus "Reset component counts on $resetCount of $($sums.Count) summarizer entries"
        }
    }
    catch {
        Write-DscStatus "WARNING: Failed to reset SMS component status counts: $($_.Exception.Message)"
    }
}

# Non-CAS: wait for site components to stabilize before signaling completion.
# After E-HTTP/HTTPS, PushClients, EnableBLM, and component resets, many
# SMS_EXECUTIVE components are still starting. Polling here prevents Phase 11
# from failing on "27 components not Started" race conditions.
if ($CurrentRole -ne "CAS" -and $CurrentRole -in @("Primary", "Secondary")) {
    $stabSiteCode = $ThisVM.siteCode
    if ($stabSiteCode) {
        # Same ignore list as Phase 11 (Common.Validation.Functional.ps1)
        # Conditionally ignore WSUS/SRS components only when those roles
        # aren't installed for this site (checked via $deployConfig).
        $hasSUP = $deployConfig.virtualMachines | Where-Object {
            ($_.installSUP -or $_.InstallSUP) -and $_.siteCode -eq $stabSiteCode
        } | Select-Object -First 1
        $hasRP = $deployConfig.virtualMachines | Where-Object {
            $_.InstallRP -and $_.siteCode -eq $stabSiteCode
        } | Select-Object -First 1
        $ignoredComponents = @(
            'SMS_WSUS_CONFIGURATION_MANAGER'         # Until SUP is fully configured
            'SMS_MIGRATION_MANAGER'
            'SMS_SITE_SQL_BACKUP'
            'SMS_SITE_BACKUP'
            'SMS_SITE_VSS_WRITER'
            'SMS_OFFLINE_SERVICING_MANAGER'
            'CONFIGURATION_MANAGER_UPDATE'
            'SMS_MP_DEVICE_MANAGER'
            'SMS_TEM'
            'SMS_PROVIDERS'
            'SMS_AD_SYSTEM_DISCOVERY_AGENT'
            'SMS_AD_SECURITY_GROUP_DISCOVERY_AGENT'
            'SMS_AD_USER_DISCOVERY_AGENT'
            'SMS_AD_FOREST_DISCOVERY_MANAGER'
            'SMS_WINNT_SERVER_DISCOVERY_AGENT'
            'SMS_NETWORK_DISCOVERY'
        )
        if (-not $hasSUP) {
            $ignoredComponents += 'SMS_WSUS_CONTROL_MANAGER'
            $ignoredComponents += 'SMS_WSUS_SYNC_MANAGER'
        }
        if (-not $hasRP) {
            $ignoredComponents += 'SMS_SRS_REPORTING_POINT'
        }
        $stabMaxAttempts = 10
        $stabDelay = 30
        $stabThreshold = 5  # allow up to this many non-Started components
        Write-DscStatus "Waiting for site components to stabilize (up to $([math]::Round($stabMaxAttempts * $stabDelay / 60)) min)"
        for ($stabAttempt = 1; $stabAttempt -le $stabMaxAttempts; $stabAttempt++) {
            try {
                $ns = "root\sms\site_$stabSiteCode"
                $allComps = @(Get-WmiObject -Namespace $ns -Class SMS_ComponentSummarizer `
                    -Filter "TallyInterval='0001128000100008' AND SiteCode='$stabSiteCode'" -ErrorAction Stop)
                if ($allComps.Count -eq 0) {
                    Write-DscStatus "  Component stabilization attempt $stabAttempt/$stabMaxAttempts`: no data yet"
                    if ($stabAttempt -lt $stabMaxAttempts) { Start-Sleep -Seconds $stabDelay }
                    continue
                }
                $checkable = @($allComps | Where-Object { $_.ComponentName -notin $ignoredComponents })
                $notStarted = @($checkable | Where-Object { $_.State -ne 1 })
                if ($notStarted.Count -le $stabThreshold) {
                    Write-DscStatus "Components stabilized: $($checkable.Count - $notStarted.Count)/$($checkable.Count) Started (attempt $stabAttempt)"
                    break
                }
                $names = ($notStarted | Select-Object -First 5 | ForEach-Object { $_.ComponentName }) -join ', '
                Write-DscStatus "  Attempt $stabAttempt/$stabMaxAttempts`: $($notStarted.Count) components not Started ($names...)" -RetrySeconds $stabDelay
            }
            catch {
                Write-DscStatus "  Component stabilization attempt $stabAttempt failed: $($_.Exception.Message)"
            }
            if ($stabAttempt -lt $stabMaxAttempts) { Start-Sleep -Seconds $stabDelay }
        }
    }
}

# Force a FULL collection re-evaluation on every MEMLABS-* device collection
# (plus All Unknown Computers) now that PushClients + auto-push + first-contact
# Heartbeat Discovery have had time to register the agent and flip
# SMS_R_System.Client to 1 for every freshly-pushed VM. Without this,
# SMS_FullCollectionMembership.IsClient is the value colleval snapshotted
# when the resource was FIRST added to the collection -- typically before
# its DDR was processed -- and the stale IsClient=False cache causes CM to
# skip projecting per-resource application deployment policy
# (CCM_ApplicationCIAssignment) to those members. Observed symptom:
# Phase 11 DomainMember check WARNs "Office deployment policy not visible
# after 3 min of polling" on a client that IS in MEMLABS-Office Install
# Targets and IS a healthy registered CM client, purely because the
# membership snapshot was stale. A single RequestRefresh($false) rewrites
# every IsClient cell on the next colleval pass.
if ($CurrentRole -in @("Primary", "Secondary")) {
    $refSiteCode = $ThisVM.siteCode
    if ($refSiteCode) {
        try {
            $ns = "root\sms\site_$refSiteCode"
            # CollectionType=2 is Device. Filter to MEMLABS-* + All Unknown
            # Computers in PowerShell (WQL -Filter doesn't reliably accept
            # SQL LIKE with %). Built-in collections (All Systems, All
            # Users, etc.) are excluded -- CM evals those on its own
            # schedule and we don't deploy MEMLABS apps to them directly.
            $allCols = @(Get-WmiObject -Namespace $ns -Class SMS_Collection -Filter "CollectionType=2" -ErrorAction Stop)
            $targetCols = @($allCols | Where-Object { $_.Name -like 'MEMLABS-*' -or $_.Name -eq 'All Unknown Computers' })
            if ($targetCols.Count -gt 0) {
                Write-DscStatus "Refreshing $($targetCols.Count) collection(s) to update IsClient snapshots after PushClients"
                $refOk = 0
                foreach ($c in $targetCols) {
                    try {
                        [void]([wmi]$c.__PATH).RequestRefresh($false)
                        $refOk++
                    }
                    catch {
                        Write-DscStatus "  WARN: RequestRefresh on '$($c.Name)' ($($c.CollectionID)) failed: $($_.Exception.Message)"
                    }
                }
                Write-DscStatus "  Requested re-eval on $refOk of $($targetCols.Count) collection(s); colleval will process them in the background"
            }
            else {
                Write-DscStatus "No MEMLABS-* device collections found to refresh (perfloading may not have run)"
            }
        }
        catch {
            Write-DscStatus "WARNING: Failed to enumerate collections for refresh sweep: $($_.Exception.Message)"
        }
    }
}

# Non-CAS: mark completion now that PushClients, EnableBLM, component
# resets, and component stabilization are done.
if ($CurrentRole -ne "CAS") {
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    $Configuration.ScriptWorkflow.Status = "Completed"
    $Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    Write-DscStatus "Complete!"
}

# Stamp the completion RunId as the very last action. The orchestrator's
# monitoring loop treats a matching RunId as authoritative completion,
# which is bulletproof against any later status writes from background
# work or future phase additions.
if ($ScriptWorkflowRunId) {
    try {
        Set-Content -Path $CompletedRunIdFile -Value $ScriptWorkflowRunId -Force -Encoding ASCII
        Write-DscStatus "ScriptWorkflow.ps1 stamped completion RunId: $ScriptWorkflowRunId"
    }
    catch {
        Write-DscStatus "ScriptWorkflow.ps1 WARNING: failed to stamp completion RunId: $($_.Exception.Message)"
    }
}


