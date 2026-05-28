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
    . $ScriptFile $ConfigFilePath $LogPath

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
    . $ScriptFile $ConfigFilePath $LogPath

    #Install DP/MP/Client - Run before secondary so MP can be installed on sitesytems
    if ($Configuration.InstallDP.Status -ne "Completed") {
        Write-DscStatus "$scenario Running InstallDPMPClient.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallDPMPClient.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath
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
        . $ScriptFile $ConfigFilePath $LogPath
    }

    if ($Configuration.InstallSUP.Status -ne "Completed") {
        Write-DscStatus "$scenario Running InstallRoles.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath
    }
    else {
        Write-DscStatus "$scenario Skipping InstallRoles.ps1 (already completed)"
    }

    # ConfigureCMProxy is cheap and idempotent; always run it so latched
    # Completed state from a deploy that ran before the Proxy was hydrated
    # into deployConfig can self-heal on the next pass. The script itself
    # short-circuits when there's no Proxy or no opted-in clients.
    Write-DscStatus "$scenario Running ConfigureCMProxy.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "ConfigureCMProxy.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath

    #Install BGs -- Must run after InstallRoles so DPs MPs and SUPs can be detected
    Write-DscStatus "$scenario Running InstallBoundaryGroups.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallBoundaryGroups.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath

}

if ($scenario -eq "Hierarchy") {

    if ($CurrentRole -eq "CAS") {

        #Install CM and Config
        Write-DscStatus "$scenario Running InstallAndUpdateSCCM.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallAndUpdateSCCM.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath

        if ($Configuration.InstallSUP.Status -ne "Completed") {
            Write-DscStatus "$scenario Running InstallRoles.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
            Set-Location $LogPath
            . $ScriptFile $ConfigFilePath $LogPath
        }
        else {
            Write-DscStatus "$scenario Skipping InstallRoles.ps1 (already completed)"
        }

        # ConfigureCMProxy is cheap and idempotent; always run.
        Write-DscStatus "$scenario Running ConfigureCMProxy.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "ConfigureCMProxy.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath

    }
    elseif ($CurrentRole -eq "Primary") {

        #Install CM and Config
        if (-not [string]::IsNullOrWhiteSpace($($ThisVM.thisParams.ParentSiteServer))) {
            Write-DscStatus "$scenario Running InstallPSForHierarchy.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallPSForHierarchy.ps1"
            Set-Location $LogPath
            . $ScriptFile $ConfigFilePath $LogPath
        }

        #Install DP/MP/Client - Run before secondary so MP can be installed on sitesytems
        if ($Configuration.InstallDP.Status -ne "Completed") {
            Write-DscStatus "$scenario Running InstallDPMPClient.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallDPMPClient.ps1"
            Set-Location $LogPath
            . $ScriptFile $ConfigFilePath $LogPath
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
            . $ScriptFile $ConfigFilePath $LogPath
        }

        if ($Configuration.InstallSUP.Status -ne "Completed") {
            Write-DscStatus "$scenario Running InstallRoles.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
            Set-Location $LogPath
            . $ScriptFile $ConfigFilePath $LogPath
        }
        else {
            Write-DscStatus "$scenario Skipping InstallRoles.ps1 (already completed)"
        }

        # ConfigureCMProxy is cheap and idempotent; always run.
        Write-DscStatus "$scenario Running ConfigureCMProxy.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "ConfigureCMProxy.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath

         #Install BGs -- Must run after InstallRoles so DPs MPs and SUPs can be detected
        Write-DscStatus "$scenario Running InstallBoundaryGroups.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallBoundaryGroups.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath

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
        . $ScriptFile $ConfigFilePath $LogPath
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
    . $ScriptFile $ConfigFilePath $LogPath $firstRun
}
else {
    Write-DscStatus "UsePKI Running EnableHTTPS.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableHTTPS.ps1"
    . $ScriptFile $ConfigFilePath $LogPath $firstRun
}

if ($TopLevelSiteServer) {
    Write-DScStatus "Loading object pre-population for MEMLABS"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "Perfloading.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath

}

  # Install Providers
  Write-DscStatus "Running InstallProvider.ps1"
  $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallProvider.ps1"
  Set-Location $LogPath
  . $ScriptFile $ConfigFilePath $LogPath
  
# Mark ScriptWorkflow completed for DSC to move on.
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
$Configuration.ScriptWorkflow.Status = "Completed"
$Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
Write-DscStatus "Complete!"

if ($ThisVM.role -ne "CAS") {
    Write-DscStatus "Always Running PushClients.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "PushClients.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath
    Write-DscStatus "Complete!"
}

# Run EnableBLM AFTER PushClients so newly pushed clients are discoverable
if ($CurrentRole -eq "Primary") {
    Write-DscStatus "Running EnableBLM.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableBLM.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath
    # MUST re-assert Complete! -- EnableBLM's final status ("BitLocker Management
    # configuration complete") overwrites the earlier Complete! marker written
    # after PushClients. The orchestrator in Common.ScriptBlocks.ps1 polls for
    # exact match "Complete!" / "Setting up ConfigMgr. Status: Complete!" and
    # will otherwise hang on Phase 8 long after the work is done.
    Write-DscStatus "Complete!"
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


