# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.

# ThreadJob (PS7+) exposes its data streams directly on the job object and
# has an empty ChildJobs collection, whereas Start-Job wraps the work in a
# child PSRemotingChildJob whose streams hold the data. Return whichever
# object actually carries Output/Error/Progress for a given job.
function Get-JobStreamSource {
    param($Job)
    if (-not $Job) { return $null }
    if ($Job.ChildJobs -and $Job.ChildJobs.Count -gt 0) { return $Job.ChildJobs[0] }
    return $Job
}

# Diagnostic (gated by $global:ProgressDiag): log the volume and last record of a
# running job's Progress stream, throttled to ~2s per job. Tags each record
# MANAGED (Activity carries the VM-name prefix) vs RAW (child's own ActivityId-0
# record that PS7 may auto-render as an orphan). Used to confirm the Phase 2
# flood vs Phase 3 trickle and pinpoint which records cause the bottom orphan.
function Write-JobProgressDiag {
    param($Job)
    if (-not $global:ProgressDiag) { return }
    try {
        if (-not $global:ProgressDiagJobVolume) { $global:ProgressDiagJobVolume = @{} }
        $streamSource = Get-JobStreamSource -Job $Job
        if (-not $streamSource -or -not $streamSource.Progress) { return }
        $now = [DateTime]::UtcNow
        $key = $Job.Id
        $entry = $global:ProgressDiagJobVolume[$key]
        if ($entry -and (($now - $entry.Time).TotalSeconds -lt 2)) { return }
        $count = $streamSource.Progress.Count
        if ($entry) { $prevCount = $entry.Count } else { $prevCount = 0 }
        $delta = $count - $prevCount
        $global:ProgressDiagJobVolume[$key] = @{ Time = $now; Count = $count }
        if ($count -gt 0) {
            $last = $streamSource.Progress[$count - 1]
            $vmPrefix = ($Job.Name -split " ")[0]
            $tag = "RAW"
            if ($last.Activity -and $last.Activity.TrimStart().StartsWith($vmPrefix)) { $tag = "MANAGED" }
            Write-ProgressDiagLog ("[Vol] job={0} count={1} (+{2}) lastId={3} {4} act='{5}' status='{6}'" -f $Job.Name.Trim(), $count, $delta, $last.ActivityId, $tag, $last.Activity, $last.StatusDescription)
        }
    }
    catch {}
}

function Write-JobProgress {
    param($Job, $AdditionalData)

    try {
        if (-not $global:JobProgressHistory) {
            $global:JobProgressHistory = @{}
        }
        $latestActivity = $null
        $latestStatus = $null
        # ThreadJob has no ChildJobs -- streams live directly on the job.
        $streamSource = Get-JobStreamSource -Job $Job
        if ($null -ne $job -and $null -ne $streamSource -and $null -ne $streamSource.Progress) {
            #Extracts the latest progress of the job and writes the progress
            $latestPercentComplete = 0
            # Notes: "Preparing modules for first use" is translated when other than en-US
            # Index directly instead of piping through Where-Object | Select-Object -Last 1
            # to avoid enumerating the full PSDataCollection, which can cause PS7 to
            # auto-render the child job's raw progress records as orphan bars (no VM name prefix).
            $lastProgress = $null
            $progressCount = $streamSource.Progress.Count
            for ($pi = $progressCount - 1; $pi -ge 0; $pi--) {
                $candidate = $streamSource.Progress[$pi]
                if ($candidate.Activity -ne "Preparing modules for first use." -and
                    $candidate.Activity -ne "Compress-Archive" -and
                    $candidate.ActivityId -eq 0) {
                    $lastProgress = $candidate
                    break
                }
            }
            if ($lastProgress) {
                $latestPercentComplete = $lastProgress | Select-Object -expand PercentComplete;
                $latestActivity = $lastProgress | Select-Object -expand Activity;
                $latestStatus = $lastProgress | Select-Object -expand StatusDescription;
                $secondsRemaining = $lastProgress | Select-Object -expand SecondsRemaining;
                $jobName = $job.Name
                if ($latestActivity) {
                    $latestActivity = $latestActivity.Replace("$jobName`: ", "").Trim()
                }
                if (-not $latestStatus) {
                    $latestStatus = ""
                }
            }

            if ($latestActivity -and $latestStatus.Trim().Length) {
                #When adding multiple progress bars, a unique ID must be provided. Here I am providing the JobID as this
                if ($latestPercentComplete -gt 0 -and $latestPercentComplete -lt 101) {

                }
                else {
                    $latestPercentComplete = 0
                }
                try {
                    $padding = 0
                    $jobName2 = "[Unknown]"
                    if ($jobName) {
                        $jobName2 = "  $($jobName.PadRight($padding," "))"
                    }
                    else {
                        $jobName = "[Unknown VM] [Unknown Role]"
                    }

                    if ($Common.PS7) {
                        if ($AdditionalData) {
                            $padding1 = $AdditionalData.MaxVmNameLength
                            $padding2 = $AdditionalData.MaxRoleNameLength
                            $vmName = ($jobName -split " ")[0]
                            $roleName = ($jobName -split " ")[1]
                            $jobName2 = "  $($vmName.PadRight($padding1," ")) $($roleName.PadRight($padding2," "))"
                        }
                    }
                    $CurrentActivity = "$jobName2`: $latestActivity"
                    $HistoryLine = $Job.Id.ToString() + $CurrentActivity + $latestStatus + $latestPercentComplete
                    $jobKey = $Job.Id
                    $now = [DateTime]::UtcNow
                    $lastEntry = $global:JobProgressHistory[$jobKey]
                    $changed = (-not $lastEntry) -or ($lastEntry.Line -ne $HistoryLine)
                    $stale = $lastEntry -and (($now - $lastEntry.Time).TotalSeconds -ge 10)
                    if ($changed -or $stale) {
                        $global:JobProgressHistory[$jobKey] = @{ Line = $HistoryLine; Time = $now }
                        if ($secondsRemaining -gt 0) {
                            $latestStatus += " (Remaining: $($secondsRemaining)s)"
                        }
                        Write-Progress2 -Activity $CurrentActivity -Id $Job.Id -Status $latestStatus -PercentComplete $latestPercentComplete -force
                        write-host -NoNewline "$hideCursor"

                        # Dismiss any orphan progress bar that PS7 may auto-render from
                        # the child job's original progress record. Child jobs write with
                        # the default ActivityId (0), but the managed bar above uses
                        # $Job.Id. If PS7 surfaces the child's record at its original Id,
                        # an extra bar appears without the VM name prefix.
                        $childActivityId = $lastProgress.ActivityId
                        if ($childActivityId -ne $Job.Id) {
                            if ($global:ProgressDiag) {
                                if (-not $global:OrphanDismissHits) { $global:OrphanDismissHits = 0 }
                                $global:OrphanDismissHits++
                                Write-ProgressDiagLog ("[OrphanDismiss] job={0} childActId={1} act='{2}'" -f $Job.Name.Trim(), $childActivityId, $lastProgress.Activity)
                            }
                            Write-Progress2 -Activity $lastProgress.Activity -Id $childActivityId -Status "Completed" -Completed -force
                        }
                    }
                }
                catch {
                    Write-Log "[$jobName] Exception during job progress reporting. $vmName; $roleName; $AdditionalData. $_" -failure
                }
            }
        }
    }
    catch {
        Write-Log "[$jobName] Exception during job progress reporting. $vmName; $roleName; $AdditionalData. $_" -failure
    }
    finally {
    }
}

# Returns the host path to the SQL ISO for a given VM (resolved from the Azure
# file list by sqlVersion), or $null if it can't be resolved.
function Get-SqlIsoPathForVm {
    param([object]$VirtualMachine)

    if (-not $VirtualMachine.sqlVersion) { return $null }
    $azureFileList = if ($Common) { $Common.AzureFileList } else { $null }
    if (-not $azureFileList) { return $null }

    $sqlFiles = $azureFileList.ISO | Where-Object { $_.id -eq $VirtualMachine.sqlVersion }
    $sqlIso = $sqlFiles.filename | Where-Object { $_.ToLowerInvariant().EndsWith(".iso") }
    if (-not $sqlIso) { return $null }

    return (Join-Path $Common.AzureFilesPath $sqlIso)
}

# Mounts the SQL ISO to the DVD drive of every SQL VM in the config, just before
# Phase 4 installs SQL directly from it. Idempotent: if the correct ISO is
# already mounted (e.g. a -StartPhase 4 retry after a failed run left it
# attached), the VM is skipped. The single DVD drive is free by Phase 4 because
# the create-time CM/OSD copies (Common.ScriptBlocks.ps1) eject when done.
function Mount-SqlIsoForPhase {
    param([object]$deployConfig)

    $sqlVMs = $deployConfig.virtualMachines | Where-Object { $_.sqlVersion -and -not $_.hidden }
    foreach ($vm in $sqlVMs) {
        $sqlIsoPath = Get-SqlIsoPathForVm -VirtualMachine $vm
        if (-not $sqlIsoPath) {
            Write-Log "[Phase 4]: $($vm.vmName): Could not resolve SQL ISO path for '$($vm.sqlVersion)'; skipping mount." -Warning
            continue
        }

        # Already mounted with the correct ISO -> no-op (idempotent re-run).
        $existing = Get-VMDvdDrive -VMName $vm.vmName -ErrorAction SilentlyContinue
        if ($existing -and $existing.Path -eq $sqlIsoPath) {
            Write-Log "[Phase 4]: $($vm.vmName): SQL ISO already mounted ($sqlIsoPath)."
            continue
        }

        Write-Log "[Phase 4]: $($vm.vmName): Mounting SQL ISO $sqlIsoPath as a DVD drive"
        $dvd = Set-VMDvdDrive -VMName $vm.vmName -Path $sqlIsoPath -Passthru
        if (-not $dvd) {
            Write-Log "[Phase 4]: $($vm.vmName): Failed mounting SQL ISO. Retrying after eject."
            Get-VMDvdDrive -VMName $vm.vmName | Set-VMDvdDrive -Path $null
            Start-Sleep -Seconds 20
            $dvd = Set-VMDvdDrive -VMName $vm.vmName -Path $sqlIsoPath -Passthru
        }
        if (-not $dvd) {
            Write-Log "[Phase 4]: $($vm.vmName): Failed mounting SQL ISO $sqlIsoPath as a DVD drive" -Failure -OutputStream
        }
    }
}

# Ejects the SQL ISO from every SQL VM in the config. Called after a SUCCESSFUL
# Phase 4 so nothing is mounted at rest (avoids baking a host ISO path into
# checkpoints / .memlabs exports). On a failed Phase 4 the ISO is deliberately
# left mounted for debugging.
function Dismount-SqlIsoForPhase {
    param([object]$deployConfig)

    $sqlVMs = $deployConfig.virtualMachines | Where-Object { $_.sqlVersion -and -not $_.hidden }
    foreach ($vm in $sqlVMs) {
        $dvd = Get-VMDvdDrive -VMName $vm.vmName -ErrorAction SilentlyContinue
        if ($dvd -and $dvd.Path) {
            Write-Log "[Phase 4]: $($vm.vmName): Ejecting SQL ISO from DVD drive"
            $dvd | Set-VMDvdDrive -Path $null
        }
    }
}

function Start-Phase {

    param(
        [int]$Phase,
        [object]$deployConfig,
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "[WhatIf] Will Start Phase $Phase"
        return $true
    }

    # Remove DNS records for VM's in this config, if existing DC
    if ($deployConfig.parameters.ExistingDCName -and $Phase -eq 1) {
        $existingDC = $deployConfig.parameters.ExistingDCName
        # When Phase 1 was forced only for AADClient cleanup, scope DNS
        # removal to just the deleted VMs instead of nuking all records.
        if ($global:ForcePhase1VmNames -and $global:ForcePhase1VmNames.Count -gt 0) {
            $dnsTargets = $deployConfig.virtualMachines | Where-Object { $_.vmName -in $global:ForcePhase1VmNames }
            Write-Log "[Phase $Phase] Removing DNS records for re-created VM(s): $($global:ForcePhase1VmNames -join ', ')"
        }
        else {
            $dnsTargets = $deployConfig.virtualMachines | Where-Object { -not ($_.hidden) }
            Write-Log "[Phase $Phase] Attempting to remove existing DNS Records"
        }
        foreach ($item in $dnsTargets) {
            Remove-DnsRecord -DCName $existingDC -Domain $deployConfig.vmOptions.domainName -RecordToDelete $item.vmName
        }
    }

    # Pre-allocate DHCP IPs for every VM before Phase 1 jobs start.
    # This runs serially so there are no race conditions, and every VM's
    # config gets an AssignedIP that New-VirtualMachine uses to create
    # the reservation immediately after creating the NIC.
    if ($Phase -eq 1) {

        # Memory pre-flight. Phase 1 starts every new VM concurrently for file
        # injection, so the host has to hold ALL their startup memory at once
        # on top of the OS/Hyper-V baseline and the ~N concurrent VM_Create job
        # processes that mount and inject VHDs. The static validation check uses
        # only an 8GB buffer against total physical RAM, which is thinner than a
        # loaded host's real baseline, so a config that "fits" (sum < total) can
        # still OOM mid-phase and force a full rollback (seen on
        # wacky.sandwich.lab: ZZ-TURNIP, the 25th VM, failed to start with
        # 0x8007000E at ~93GB committed on a 128GB host). Re-check here against
        # REAL available memory and let the user bail before any VM is created.
        # Default is "continue" so unattended runs are never blocked.
        try {
            $existingVmNames = (Get-List -Type VM -SmartUpdate).vmName
            $newVMs = @($deployConfig.virtualMachines | Where-Object { -not $_.hidden -and $_.vmName -notin $existingVmNames })
            if ($newVMs.Count -gt 0) {
                $newStartupGB = [Math]::Round((($newVMs.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum).Sum) / 1GB, 1)
                $availMB = $null
                try { $availMB = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue } catch {}
                if ($availMB) {
                    $availGB = [Math]::Round($availMB / 1024, 1)
                    # Reserve headroom for Hyper-V root-partition per-VM overhead
                    # and the concurrent Phase 1 job processes injecting VHDs.
                    $hostReserveGB = 8
                    $needGB = [Math]::Round($newStartupGB + $hostReserveGB, 1)
                    if ($needGB -gt $availGB) {
                        Write-OrangePoint "[Phase 1] Memory pre-flight: creating $($newVMs.Count) VM(s) needs ~$($newStartupGB)GB startup + $($hostReserveGB)GB host reserve = $($needGB)GB, but only $($availGB)GB is currently available. The build may run out of memory mid-phase and roll back." -WriteLog
                        $memResp = Read-YesOrNoWithTimeout -timeout 30 -prompt "Continue Phase 1 anyway? (Y/n)" -Default "y"
                        if ($memResp -and $memResp.ToString().ToLower() -eq "n") {
                            Write-RedX "[Phase 1] Aborted by user: insufficient available memory (~$($needGB)GB needed, $($availGB)GB available)." -WriteLog
                            return $false
                        }
                    }
                    else {
                        Write-Log "[Phase 1] Memory pre-flight OK: ~$($newStartupGB)GB startup + $($hostReserveGB)GB reserve = $($needGB)GB <= $($availGB)GB available." -LogOnly
                    }
                }
            }
        }
        catch {
            Write-Log "[Phase 1] Memory pre-flight check skipped (non-fatal): $_" -LogOnly
        }

        Set-DeployConfigIPAddresses -DeployConfig $deployConfig
    }

    # Linux Proxy Squid install is dispatched as a per-VM job through
    # Start-PhaseJobs in Phase 2 (see $global:Proxy_Install), so it shows
    # up in the same Wait-Phase progress block as the DC/client jobs and
    # benefits from the same lifetime/error handling.

    # Pre-build tools zips on the host so Phase 2 jobs skip Compress-Archive.
    if ($Phase -eq 2) {
        Build-ToolZipsForPhase2 -deployConfig $deployConfig
    }

    # Mount the SQL ISO to each SQL VM just before Phase 4 installs SQL from it.
    # The single DVD drive is free here because the create-time CM/OSD copies
    # already ejected. Idempotent on -StartPhase 4 reruns.
    if ($Phase -eq 4) {
        Mount-SqlIsoForPhase -deployConfig $deployConfig
    }

    # Start Phase
    $start = Start-PhaseJobs -Phase $Phase -deployConfig $deployConfig
    # Hard-fail when a phase's preflight (e.g. the Phase 8 SQL-admin self-heal)
    # couldn't remediate. Returning $false here breaks the New-Lab phase loop
    # immediately so other VMs don't sit waiting through CM Setup's own multi-
    # hour internal timeouts on dependencies that we already know are broken.
    if ($start -and $start.PreflightFailed) {
        Write-RedX "[Phase $Phase] Preflight checks failed; aborting before any per-VM jobs are dispatched. See log for details." -WriteLog
        return $false
    }
    if (-not $start.Applicable) {
        Write-OrangePoint "[Phase $Phase] No VMs need this step. Skipping." -ForegroundColor Yellow -WriteLog
        $global:PhaseSkipped = $true
        return $true
    }
    $global:PhaseSkipped = $false
    $result = Wait-Phase -Phase $Phase -Jobs $start.Jobs -AdditionalData $start.AdditionalData -DeployConfig $deployConfig

    # Phase 2 builds tool zips keyed by fingerprint. Clean up any stale
    # zips from previous runs that are no longer referenced.
    if ($Phase -eq 2) {
        Clean-StaleToolZips
    }

    # Eject the SQL ISO after a SUCCESSFUL Phase 4. On failure leave it mounted
    # so the VM can be inspected; a -StartPhase 4 retry re-mounts idempotently.
    if ($Phase -eq 4 -and $result.Failed -eq 0) {
        Dismount-SqlIsoForPhase -deployConfig $deployConfig
    }

    Write-Log "[Phase $Phase] Jobs completed; $($result.Success) success, $($result.Warning) warnings, $($result.Failed) failures. Time: $($result.Elapsed)"

    # Record per-phase stats
    if ($global:BuildStats) {
        $vmCount = ($start.Success + $start.Failed)
        $global:BuildStats.Phases[$Phase] = @{
            Elapsed = $result.Elapsed
            Success = $result.Success
            Warning = $result.Warning
            Failed  = $result.Failed
            VMCount = $vmCount
        }
    }

    if ($result.Failed -gt 0) {
        return $false
    }

    # After Phase 2 (domain-join + initial member config) succeeds, push proxy
    # client settings to any VM with useProxy=true. Done from the host over
    # PSDirect so we don't have to thread proxy config through DSC. No-op if
    # no Proxy VM or no opted-in clients are present.
    if ($Phase -eq 2) {
        $postPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()

        # Flip Linux VMs (incl. the Proxy itself) from bootstrap public DNS
        # to the DC's DNS first, so the Proxy can resolve internal names
        # and clients pointed at it land on a fully-configured upstream.
        $hasLinux = @($deployConfig.virtualMachines | Where-Object { (Test-VmIsLinux -Vm $_) -and -not $_.hidden }).Count -gt 0
        if ($hasLinux) {
            $null = Set-LinuxVmsDcDns -DeployConfig $deployConfig
        }

        # NOTE: Set-WindowsClientProxyForConfig used to run here as a serial
        # foreach over Windows clients. Per-VM proxy client config now lives in
        # $global:VM_Config (Phase 2 post-DSC block) so it parallelizes with
        # every other per-VM Phase 2 job. The function remains callable for
        # Fix-* scripts and manual reruns.

        # Per-deploy enforcement covers brand-new VMs whose useProxy lives only
        # in deployConfig (VM Notes not yet written on first-run cases).
        Set-VmProxyEnforcementForConfig -deployConfig $deployConfig | Out-Null
        # NOTE: Cross-lab reconciliation (Set-VmProxyEnforcementForAllLabs)
        # runs from New-Lab.ps1 after Phase 11 succeeds, to clear stale ACLs
        # from VMs whose useProxy was flipped off. The ACL set itself is
        # fixed (RFC 1918 allow + deny public ports), so no subnet-union
        # timing concerns exist.

        # Clean up stale tool zips from previous runs that are no longer
        # referenced. Keeps current-fingerprint zips so reruns skip rebuild.
        Clean-StaleToolZips

        $postPhaseTimer.Stop()
        Write-Log "[Phase 2] Post-processing (Linux DNS, Proxy config) completed. Time: $($postPhaseTimer.Elapsed.ToString("hh\:mm\:ss"))"
        if ($global:BuildStats -and $global:BuildStats.Phases.ContainsKey(2)) {
            $global:BuildStats.Phases[2].Elapsed += $postPhaseTimer.Elapsed
        }
    }

    return $true
}

function Start-NormalJobs {
    param (
        [object]$machines,
        [object]$scriptBlock,
        [object]$phase,
        [Object]$argument1,
        [Object]$argument2,
        [Object]$argument3,
        # When set and Start-ThreadJob is available (PS7+ with ThreadJob
        # module), spawn ThreadJobs instead of Start-Job. ThreadJobs share
        # the parent process and its already-loaded modules/assemblies, so
        # each worker skips powershell.exe startup (~1s) and Hyper-V /
        # DhcpServer module imports (~2-3s). Falls back to Start-Job when
        # ThreadJob isn't available. Throttle limit is set generously since
        # ThreadJobs are cheap; caller-controlled via -ThreadJobThrottle.
        [switch]$PreferThreadJob,
        [int]$ThreadJobThrottle = 16
    )

    $useThreadJob = $PreferThreadJob.IsPresent -and (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)
    if ($PreferThreadJob.IsPresent -and -not $useThreadJob) {
        Write-Log "Start-NormalJobs: ThreadJob requested but not available; using Start-Job." -LogOnly
    }

    [System.Collections.ArrayList]$jobs = @()
    $job_created_yes = 0
    $job_created_no = 0
    $maxVmNameLength = 0
    $maxRoleNameLength = 0

    if (-not $phase) {
        $phase = "NormalJob"
    }
    # Define $deployConfigCopy in local scope so $using:deployConfigCopy in
    # script blocks (e.g. Phase10Job) binds successfully even when this caller
    # (e.g. Start-Maintenance) has no deployConfig. The script blocks guard
    # against null before using it.
    $deployConfigCopy = $null

    # ThreadJob's $using: parser only supports bare variable expressions --
    # member access like $using:Common.DevBranch throws "Cannot get the value
    # of the Using expression". Pre-extract the few $Common properties used
    # by ThreadJob-eligible scriptblocks (Phase10Job, DeleteVMs) into locals
    # so they can be referenced as $using:devBranchValue / etc. Harmless when
    # ThreadJob isn't in play -- Start-Job also resolves these names fine.
    $devBranchValue = if ($Common) { $Common.DevBranch } else { $false }
    $azureFileList = if ($Common) { $Common.AzureFileList } else { $null }
    $localAdmin = if ($Common) { $Common.LocalAdmin } else { $null }
    foreach ($currentItem in $machines) {
        $jobName = "$($currentItem.vmName) [$($currentItem.role)] "
        if ($currentItem.vmName.Length -gt $maxVmNameLength) {
            $maxVmNameLength = $currentItem.vmName.Length
        }
        if ($currentItem.role.Length -gt $maxRoleNameLength) {
            $maxRoleNameLength = $currentItem.role.Length
        }

        Write-Log -verbose "Starting Job for $jobName $argument2, $argument3"
        if ($useThreadJob) {
            if ($argument1) {
                $job = Start-ThreadJob -ScriptBlock $scriptBlock -Name $jobName -ThrottleLimit $ThreadJobThrottle -ErrorAction Stop -ErrorVariable Err -ArgumentList $currentItem, (, $argument1), $argument2, $argument3, $PSScriptRoot
            }
            else {
                $job = Start-ThreadJob -ScriptBlock $scriptBlock -Name $jobName -ThrottleLimit $ThreadJobThrottle -ErrorAction Stop -ErrorVariable Err
            }
        }
        elseif ($argument1) {
            $job = Start-Job -ScriptBlock $scriptBlock -Name $jobName -ErrorAction Stop -ErrorVariable Err -ArgumentList $currentItem, (, $argument1), $argument2, $argument3, $PSScriptRoot
        }
        else {
            $job = Start-Job -ScriptBlock $scriptBlock -Name $jobName -ErrorAction Stop -ErrorVariable Err
        }
        if (-not $job) {
            Write-Log "[Phase $Phase] Failed to create job for VM $($currentItem.vmName). $Err" -Failure
            $job_created_no++
        }
        if ($Err.Count -ne 0) {
            Write-Log "[Phase $Phase] Failed to start job for VM $($currentItem.vmName). $Err" -Failure
            $job_created_no++
        }
        else {
            Write-Log "[Phase $Phase] Created job $($job.Id) for VM $($currentItem.vmName)" -LogOnly
            $jobs += $job
            $job_created_yes++
        }
    }

    $additionalData = [PSCustomObject]@{
        MaxVmNameLength   = $maxVmNameLength
        MaxRoleNameLength = $maxRoleNameLength + 2
    }

    # Create return object
    $return = [PSCustomObject]@{
        Failed         = $job_created_no
        Success        = $job_created_yes
        Jobs           = $jobs
        Applicable     = $true
        AdditionalData = $additionalData
    }
    return $return
}


function Start-PhaseJobs {
    param (
        [int]$Phase,
        [object]$deployConfig
    )

    # Detect if DSC source files changed since last copy; if so, force re-copy
    $dscSourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) "DSC"
    $newestFile = Get-ChildItem -Path "$dscSourcePath\phases" -Filter "*.ps1" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newestFile -and $global:DSC_CopiedTime -and $newestFile.LastWriteTime -gt $global:DSC_CopiedTime) {
        Write-Log "[Phase $Phase] DSC source files modified since last copy; forcing re-copy" -LogOnly
        $global:DSC_Copied = @()
    }
    if (-not $global:DSC_CopiedTime) {
        $global:DSC_CopiedTime = Get-Date
    }

    $global:preparePhasePercent = 5
    Write-Progress2 "Preparing Phase $Phase" -Status "Getting configuration data" -PercentComplete $global:preparePhasePercent

    [System.Collections.ArrayList]$jobs = @()
    $job_created_yes = 0
    $job_created_no = 0

    # Phase10Job/Phase11Job (and any other scriptblock dispatched from here
    # that uses the bare-name form) reference $using:devBranchValue. The
    # Start-Job/Start-ThreadJob parent must have it in scope or the job-
    # creation call throws "The value of the using variable
    # '$using:devBranchValue' cannot be retrieved because it has not been
    # set in the local session." Mirror the same shim Start-NormalJobs uses
    # so both call sites agree.
    $devBranchValue = if ($Common) { $Common.DevBranch } else { $false }

    # Phase 10 (Maintenance) and Phase 11 (Functional Validation) per-VM
    # work is short (~3-10s of PSDirect probes), so the ~10s of fresh
    # powershell.exe startup + module imports under Start-Job dominates.
    # When ThreadJob is available, both phases share the parent's already-
    # loaded Hyper-V module + assemblies and skip that init entirely.
    # Other phases (VM_Create, VM_Config) stay on Start-Job for now --
    # their per-VM payload is larger so the relative win is smaller, and
    # they touch $global:DSC_Copied which would need review for ThreadJob.
    $usePhaseThreadJob = (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue) -ne $null
    $phaseThreadJobThrottle = 16

    # Determine single vs. multi-DSC
    $multiNodeDsc = $true
    $ConfigurationData = $null
    if ($Phase -gt 1 -and $Phase -lt 10) {
        $ConfigurationData = Get-ConfigurationData -Phase $Phase -deployConfig $deployConfig
        if (-not $ConfigurationData) {
            # Nothing applicable for this phase
            return [PSCustomObject]@{
                Failed         = 0
                Success        = 0
                Jobs           = 0
                Applicable     = $false
                AdditionalData = $null
            }
        }

        if ($ConfigurationData.AllNodes.NodeName -contains "LOCALHOST") {
            $multiNodeDsc = $false
        }
    }
    else {
        $multiNodeDsc = $false
    }

    # Phase 8 preflight: ensure each CAS/Primary's machine account is in local
    # Administrators on every SQL host it will use. ConfigMgr Setup walks the
    # AG replica nodes via remote WMI to read the SQL config; if the site
    # server's machine account isn't admin on a replica, the prereq emits
    # "Computer account doesn't have admininstrative rights to the SQL Server"
    # and Setup fails before doing any real work. Phase 3 normally adds this
    # via AddUserToLocalAdminGroup, but `-StartPhase 8` skips Phase 3 and a
    # restored snapshot may predate the membership (config drift, prior
    # topology without this site server, secure-channel reset, etc.). Self-
    # heal here so a -Restore + -StartPhase 8 run is robust against drift.
    #
    # Fail-fast contract: actively try to remediate (start the SQL host if it
    # isn't Running, retry the self-heal up to 3 times). If we still can't
    # confirm membership, ABORT Phase 8 immediately by returning
    # PreflightFailed=$true. Without this, a single broken SQL host would let
    # CM Setup launch and wait through its multi-hour internal timeouts, and
    # every dependent node (Primary waiting on CAS replication, secondary
    # waiting on Primary) would block on the same wall-clock, turning a
    # 30-second misconfig into a 9-hour stuck deploy.
    if ($Phase -eq 8) {
        $netbios = $deployConfig.vmOptions.domainNetBiosName
        $domain = $deployConfig.vmOptions.domainName
        $siteServers = @($deployConfig.virtualMachines | Where-Object {
            ($_.role -eq 'CAS' -or $_.role -eq 'Primary') -and $_.remoteSQLVM
        })
        $preflightFailures = New-Object System.Collections.Generic.List[string]

        foreach ($ss in $siteServers) {
            # Resolve SQL host set: the remoteSQLVM itself plus its OtherNode
            # when it's a SQLAO pair. CM Setup probes every replica, so all
            # nodes must have the site server's machine account in local
            # Administrators -- missing it on the secondary trips the same
            # prereq error whenever the AG happens to be mounted there.
            $sqlVm = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ss.remoteSQLVM } | Select-Object -First 1
            $sqlHosts = @($ss.remoteSQLVM)
            if ($sqlVm -and $sqlVm.OtherNode) { $sqlHosts += $sqlVm.OtherNode }
            $sqlHosts = @($sqlHosts | Where-Object { $_ } | Select-Object -Unique)
            $account = "$netbios\$($ss.vmName)" + '$'

            foreach ($sqlHost in $sqlHosts) {
                # Step 1: make sure the SQL host VM is Running and reachable
                # via PSDirect. If it's not, start it and wait briefly --
                # without a running, reachable VM there's no point trying
                # the ADSI add and Phase 8 will definitely fail.
                $hvm = Get-VM2 -Name $sqlHost -ErrorAction SilentlyContinue
                if (-not $hvm) {
                    $msg = "[$($ss.vmName) -> $sqlHost] SQL host VM not found on this Hyper-V host."
                    Write-Log "[Phase 8] $msg" -Failure
                    $preflightFailures.Add($msg) | Out-Null
                    continue
                }
                if ($hvm.State -ne 'Running') {
                    Write-Log "[Phase 8] $sqlHost is $($hvm.State); starting it for site-server $($ss.vmName) preflight." -Activity
                    try { Start-VM2 -Name $sqlHost -ErrorAction Stop } catch {
                        Write-Log "[Phase 8] $sqlHost`: Start-VM2 threw: $($_.Exception.Message)" -Warning
                    }
                    $ready = Wait-ForVm -VmName $sqlHost -PathToVerify 'C:\Users' -VmDomainName $domain -TimeoutMinutes 3 -SkipDiskTest -Quiet
                    if (-not $ready) {
                        $postState = (Get-VM2 -Name $sqlHost -ErrorAction SilentlyContinue).State
                        $msg = "[$($ss.vmName) -> $sqlHost] SQL host did not become reachable within 3 minutes (state=$postState)."
                        Write-Log "[Phase 8] $msg" -Failure
                        $preflightFailures.Add($msg) | Out-Null
                        continue
                    }
                }

                # Step 2: idempotently add the site-server machine account to
                # local Administrators on this SQL host. Retry transient
                # Invoke-VmCommand / ADSI failures (PSDirect session not yet
                # warm right after Start-VM2, brief WinRM contention, etc.).
                # ADSI WinNT://NETBIOS/USER lookups need a working secure
                # channel (the principal resolve walks NetLogon to a DC);
                # if the snapshot we just restored predates an AD machine-
                # password rotation, the channel is broken and the add
                # throws "The trust relationship between this workstation
                # and the primary domain failed". The scriptblock below
                # detects that and runs Test-ComputerSecureChannel -Repair
                # first (PSDirect authenticated us as the domain admin,
                # which has rights to reset the machine password in AD).
                $attempts = 0
                $maxAttempts = 3
                $success = $false
                $lastError = $null
                while (-not $success -and $attempts -lt $maxAttempts) {
                    $attempts++
                    $result = Invoke-VmCommand -VmName $sqlHost -VmDomainName $domain -DisplayName "Ensure $account in local Administrators" -ArgumentList @($account) -SuppressLog -ScriptBlock {
                        param($acct)
                        $scNote = ''
                        # Repair secure channel first if needed -- without it,
                        # ADSI WinNT://DOMAIN/USER below will throw "trust
                        # relationship failed" because the principal resolve
                        # walks NetLogon to a DC.
                        try {
                            $sc = Test-ComputerSecureChannel -ErrorAction Stop
                            if (-not $sc) {
                                try {
                                    $sc = Test-ComputerSecureChannel -Repair -ErrorAction Stop
                                    $scNote = if ($sc) { ' (secure channel repaired)' } else { ' (secure channel repair returned False)' }
                                }
                                catch { $scNote = " (secure channel repair threw: $($_.Exception.Message))" }
                            }
                        }
                        catch {
                            # Test-ComputerSecureChannel can itself throw
                            # "trust relationship failed" -- treat as broken
                            # and try -Repair to recover.
                            try {
                                $sc = Test-ComputerSecureChannel -Repair -ErrorAction Stop
                                $scNote = if ($sc) { ' (secure channel repaired after Test threw)' } else { ' (secure channel repair returned False)' }
                            }
                            catch { $scNote = " (secure channel repair threw: $($_.Exception.Message))" }
                        }
                        try {
                            $grpName = (Get-CimInstance -ClassName Win32_Group -Filter 'LocalAccount = True AND SID = "S-1-5-32-544"' -ErrorAction Stop).Name
                            $g = [ADSI]"WinNT://$env:COMPUTERNAME/$grpName,group"
                            $parts = $acct.Split('\')
                            $path = "WinNT://$($parts[0])/$($parts[1])"
                            if ($g.IsMember($path)) { return "already-member$scNote" }
                            $g.Add($path)
                            # Verify post-add so a silent ADSI no-op surfaces.
                            if ($g.IsMember($path)) { return "added$scNote" }
                            return "error: Add returned success but IsMember still false$scNote"
                        }
                        catch {
                            return "error: $($_.Exception.Message)$scNote"
                        }
                    }
                    if ($result -and -not $result.ScriptBlockFailed) {
                        $out = "$($result.ScriptBlockOutput)".Trim()
                        if ($out -like 'added*') {
                            $note = if ($attempts -gt 1) { " (attempt $attempts)" } else { '' }
                            Write-Log "[Phase 8] $sqlHost`: added $account to local Administrators (was missing) -- self-heal for site server $($ss.vmName)$note. $out" -Activity
                            $success = $true
                        }
                        elseif ($out -like 'already-member*') {
                            Write-Log "[Phase 8] $sqlHost`: $account already in local Administrators. $out" -LogOnly
                            $success = $true
                        }
                        else {
                            $lastError = $out
                            Write-Log "[Phase 8] $sqlHost`: self-heal attempt $attempts returned '$out'." -Warning
                        }
                    }
                    else {
                        $lastError = if ($result -and $result.ErrorDetails) { $result.ErrorDetails } else { 'Invoke-VmCommand returned no result' }
                        Write-Log "[Phase 8] $sqlHost`: self-heal attempt $attempts failed ($lastError)." -Warning
                    }
                    if (-not $success -and $attempts -lt $maxAttempts) { Start-Sleep -Seconds 10 }
                }

                if (-not $success) {
                    $msg = "[$($ss.vmName) -> $sqlHost] Could not verify/add $account in local Administrators after $maxAttempts attempts. Last error: $lastError"
                    Write-Log "[Phase 8] $msg" -Failure
                    $preflightFailures.Add($msg) | Out-Null
                }
            }
        }

        if ($preflightFailures.Count -gt 0) {
            Write-Log "[Phase 8] Preflight FAILED: $($preflightFailures.Count) site-server/SQL-host pair(s) could not be remediated. Aborting Phase 8 BEFORE dispatching CM Setup jobs -- otherwise dependent nodes (Primary waiting on CAS, secondary waiting on Primary) would block on multi-hour internal timeouts." -Failure
            foreach ($f in $preflightFailures) {
                Write-Log "[Phase 8]   $f" -Failure
            }
            Write-Log "[Phase 8] Remediation: ensure each listed SQL host is Running and reachable via PowerShell Direct, then re-run with -StartPhase 8. If the SQL host is up but the self-heal still fails, log in and inspect 'net localgroup Administrators' on it." -Failure
            return [PSCustomObject]@{
                Failed          = $siteServers.Count
                Success         = 0
                Jobs            = 0
                Applicable      = $true
                AdditionalData  = $null
                PreflightFailed = $true
            }
        }
    }

    # Per-run readiness token for the multi-node DSC handshake. Every VM_Config
    # job dispatched below captures this same GUID via $using:phaseRunGuid.
    # Members write it to C:\staging\DSC\RunGuid.txt as the LAST step of
    # DSC_ClearStatus (only after DSC is confirmed stopped and DSC_Status.txt
    # is cleared); the DC's node-ready loop treats a node as ready only when
    # RunGuid.txt equals THIS guid. A positive, per-run token can't be
    # satisfied by stale prior-run state or by self-recovery re-creating
    # DSC_Status.txt -- both of which defeated the old "DSC_Status.txt absent"
    # readiness signal and dead-waited the loop.
    $phaseRunGuid = [guid]::NewGuid().ToString()

    $global:preparePhasePercent = 50
    Write-Progress2 "Preparing Phase $Phase" -Status "Updating VM List" -PercentComplete $global:preparePhasePercent

    $global:vm_remove_list = @()
    $maxVmNameLength = 0
    $maxRoleNameLength = 0
    $existingVMs = Get-List -Type VM

    # Phase 10/11: start all required VMs in parallel before the per-VM job
    # dispatch loop.  Phases 2-9 use Invoke-SmartStartVMs via ConfigurationData,
    # but Phase 10/11 skip that path.  Doing it here in bulk avoids sequential
    # Get-VM2/Start-VM2 calls inside the loop (which took ~1-2s per VM).
    if ($Phase -ge 10) {
        $excludedRoles = @("OSDClient", "AADClient", "StandaloneRootCA")
        $vmsToStart = @()

        # Include all non-hidden VMs from deployConfig
        foreach ($vm in $deployConfig.virtualMachines) {
            if ($vm.Role -notin $excludedRoles -and -not $vm.hidden) {
                $vmsToStart += $vm.vmName
            }
        }

        # Include BDCs (and any other DCs) from the domain that may not be in deployConfig
        $allDomainVMs = Get-List -Type VM -DomainName $deployConfig.vmOptions.domainName -SmartUpdate
        foreach ($domVm in $allDomainVMs) {
            if ($domVm.Role -in @("DC", "BDC") -and $domVm.vmName -notin $vmsToStart) {
                $vmsToStart += $domVm.vmName
            }
        }

        # Boot ordering: start domain controllers FIRST and wait for AD DS / DNS /
        # Netlogon to be serving before starting the dependent VMs. On a cold start
        # every VM otherwise boots simultaneously, so SQLAO cluster nodes, domain
        # members, secure channels and SMS providers come up before the DC can
        # answer them -- producing a cascade of transient Phase 11 failures (broken
        # secure channel, dcdiag Replications, cluster not formed, provider not
        # loaded). Starting DCs first lets AD converge before its dependents arrive.
        # This is a no-op when the DCs are already Running (e.g. a full end-to-end
        # deploy where Phase 11 follows Phase 10 without a reboot).
        $dcRoleSet = @("DC", "BDC")
        $dcNames = @()
        foreach ($vmName in $vmsToStart) {
            $vmRole = ($existingVMs | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1).Role
            if (-not $vmRole) {
                $vmRole = ($allDomainVMs | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1).Role
            }
            if ($vmRole -in $dcRoleSet) { $dcNames += $vmName }
        }
        $otherNames = @($vmsToStart | Where-Object { $_ -notin $dcNames })

        $startedCount = 0

        # Start DCs first
        $startedDcs = @()
        foreach ($vmName in $dcNames) {
            $vmObj = $existingVMs | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
            if ($vmObj -and $vmObj.State -ne 'Running') {
                Write-Progress2 "Preparing Phase $Phase" -Status "Starting domain controller $vmName ($($vmObj.State))" -PercentComplete $global:preparePhasePercent
                Start-VM2 -Name $vmName -ErrorAction SilentlyContinue
                $startedCount++
                $startedDcs += $vmName
            }
        }

        # Only wait if we actually started a DC from a non-running state. Poll each
        # for AD DS / DNS / Netlogon up (bounded) before releasing dependent VMs.
        if ($startedDcs.Count -gt 0) {
            $dcWaitTimeoutSec = 300
            foreach ($dcName in $startedDcs) {
                Write-Progress2 "Preparing Phase $Phase" -Status "Waiting for domain controller $dcName (AD DS / DNS / Netlogon)" -PercentComplete $global:preparePhasePercent
                $dcReady = $false
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while ($sw.Elapsed.TotalSeconds -lt $dcWaitTimeoutSec) {
                    $probe = Invoke-VmCommand -VmName $dcName -VmDomainName $deployConfig.vmOptions.domainName `
                        -ScriptBlock {
                        $nl = (Get-Service -Name Netlogon -ErrorAction SilentlyContinue).Status
                        $dns = (Get-Service -Name DNS -ErrorAction SilentlyContinue).Status
                        $ntds = (Get-Service -Name NTDS -ErrorAction SilentlyContinue).Status
                            ($nl -eq 'Running') -and ($dns -eq 'Running') -and ($ntds -eq 'Running')
                    } -DisplayName "Phase$Phase-DCReady-$dcName" -SuppressLog -CommandReturnsBool -SessionMaxRetries 2
                    if ($probe -and -not $probe.ScriptBlockFailed -and $probe.ScriptBlockOutput -eq $true) {
                        $dcReady = $true
                        break
                    }
                    Start-Sleep -Seconds 10
                }
                if ($dcReady) {
                    Write-Log "[Phase $Phase] Domain controller $dcName is serving AD DS / DNS / Netlogon ($([int]$sw.Elapsed.TotalSeconds)s)." -LogOnly
                }
                else {
                    Write-Log "[Phase $Phase] Domain controller $dcName not confirmed ready after ${dcWaitTimeoutSec}s; starting remaining VMs anyway." -Warning
                }
            }
        }

        # Start the remaining (non-DC) VMs.
        foreach ($vmName in $otherNames) {
            $vmObj = $existingVMs | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
            if ($vmObj -and $vmObj.State -ne 'Running') {
                Write-Progress2 "Preparing Phase $Phase" -Status "Starting VM $vmName ($($vmObj.State))" -PercentComplete $global:preparePhasePercent
                Start-VM2 -Name $vmName -ErrorAction SilentlyContinue
                $startedCount++
            }
        }

        if ($startedCount -gt 0) {
            Write-Log "[Phase $Phase] Started $startedCount VMs." -LogOnly
        }
    }

    # Phase 10 pre-filter: bulk-read VM notes and skip VMs where every
    # applicable fix (AppliesToExisting=$true) is already recorded at the
    # current FixVersion. Phase 10's job is to bring the VM to 100%
    # up-to-date, so the eligibility set must match Start-VMMaintenance's
    # AppliesToExisting filter -- not a subset of NeededOnFreshDeploy, which
    # used to silently skip VMs missing existing-only hotfixes (e.g.
    # Fix-SQLAOBackupJobs). Skipping here just avoids spawning a job for
    # VMs that genuinely have nothing to do.
    #
    # Also skip VMs whose role is intentionally kept Off after the initial
    # deploy (StandaloneRootCA = offline root CA). Waking those just to
    # apply cosmetic Phase 10 fixes defeats the whole point of an offline
    # CA; they'll catch up the next time the user turns them on manually
    # for cert work.
    $phase10SkipSet = @{}
    $offByDesignRoles = @('StandaloneRootCA')
    if ($Phase -eq 10) {
        $allFixDefs = Get-VMFixes -ReturnDummyList
        $relevantFixes = @($allFixDefs | Where-Object { $_.AppliesToExisting -eq $true })
        $vmNoteCache = @{}
        $vmStateCache = @{}
        try {
            foreach ($hvm in (Get-VM -ErrorAction SilentlyContinue)) {
                $vmStateCache[$hvm.Name] = $hvm.State
                if ($hvm.Notes -like "*appliedFixes*") {
                    try { $vmNoteCache[$hvm.Name] = $hvm.Notes | ConvertFrom-Json } catch {}
                }
            }
        } catch {}
        foreach ($vm in $deployConfig.virtualMachines) {
            if ($vm.hidden) { continue }

            # Off-by-design + currently Off -> skip without spawning a job.
            if ($vm.role -in $offByDesignRoles -and $vmStateCache[$vm.vmName] -eq 'Off') {
                $phase10SkipSet[$vm.vmName] = "$($vm.role) is Off (kept off post-deploy), skipping."
                continue
            }

            $note = $vmNoteCache[$vm.vmName]
            if ($note -and $note.appliedFixes) {
                $allApplied = $true
                foreach ($fix in $relevantFixes) {
                    # Per-VM role gating: skip fixes that don't apply to this VM's role.
                    $roleOk = $true
                    if ($fix.AppliesToRoles -and $fix.AppliesToRoles.Count -gt 0) {
                        $roleOk = ($note.role -in $fix.AppliesToRoles) -or
                                  (($fix.AppliesToRoles -contains 'CASorStandalonePrimary') -and
                                   ($note.role -eq 'CAS' -or ($note.role -eq 'Primary' -and -not $note.parentSiteCode)))
                    }
                    if ($fix.NotAppliesToRoles -and ($note.role -in $fix.NotAppliesToRoles)) { $roleOk = $false }
                    if (-not $roleOk) { continue }
                    if (-not (Test-VMFixApplied -VMNote $note -FixName $fix.FixName -FixVersion $fix.FixVersion)) {
                        $allApplied = $false
                        break
                    }
                }
                if ($allApplied) {
                    $phase10SkipSet[$vm.vmName] = "All fixes already applied, skipping."
                }
            }
        }
        if ($phase10SkipSet.Count -gt 0) {
            Write-Log "[Phase 10] $($phase10SkipSet.Count) VM(s) will skip maintenance (already up-to-date or kept Off by design)." -LogOnly
        }
    }

    foreach ($currentItem in $deployConfig.virtualMachines) {

        $global:preparePhasePercent++
        Write-Progress2 "Preparing Phase $Phase" -Status "Evaluating virtual machine $($currentItem.vmName)" -PercentComplete $global:preparePhasePercent

        # Don't touch non-hidden VM's in Phase 0
        if ($Phase -eq 0 -and -not $currentItem.hidden) {
            continue
        }

        # Don't touch hidden VM's in Phase 1, 10, or 11
        if ($currentItem.hidden -and $Phase -in @(1, 10, 11)) {
            continue
        }

        #Special Case for Cross Domain workflows
        $valid = $false
        Write-Log "Checking $($currentItem.vmname) $($currentItem.Role) in Phase $Phase, Domain $($currentItem.domain) Hidden: $($currentItem.hidden)" -LogOnly

        if ($Phase -ge 2 -and $currentItem.hidden -and ($currentItem.domain -and ($currentItem.domain -ne $deployConfig.vmOptions.domainName))) {
            if ($Phase -eq 2 -and ($currentItem.role -in ("OtherDC"))) {
                $valid = $true
            }

            if ($Phase -eq 9 -and ($currentItem.role -in ("Primary"))) {
                $valid = $true
            }           

            if ($valid -eq $false) {
                continue
            }
        }


        # Skip Phase 1 for machines that exist - should never hit this
        if ($Phase -eq 1 -and $currentItem.vmName -in $existingVMs.vmName) {
            continue
        }

        # Skip everything for OSDClient, nothing for us to do
        if ($Phase -gt 1 -and $currentItem.role -eq "OSDClient") {
            stop-vm2 -Name $currentItem.vmName -TurnOff
            continue
        }

        # Linux VMs have no Windows DSC config. Phase 2 has a dedicated
        # dispatch branch ($global:Proxy_Install, Proxy role only) and
        # Phase 3 has another ($global:Linux_Configure, all Linux). Skip
        # every other Linux case so we don't queue a $global:VM_Config job
        # that would hang on "Waiting for VM to respond" (Invoke-VmCommand
        # is Windows-only). That means: Phase 4+ for any Linux, AND Phase 2
        # for non-Proxy Linux roles (LinuxClient, LinuxServer).
        if ((Test-VmIsLinux -Vm $currentItem) -and
            ($Phase -gt 3 -or ($Phase -eq 2 -and $currentItem.role -ne 'Proxy'))) {
            Write-Log "[Phase $Phase] Skipping Linux VM $($currentItem.vmName) (no Windows DSC)" -LogOnly
            continue
        }

        # Skip multi-node DSC (& monitoring) for all machines except those in the ConfigurationData.AllNodes
        # Exception: Linux Proxy in Phase 2 — handled below by $global:Proxy_Install.
        # Exception: any Linux VM in Phase 3 — handled below by $global:Linux_Configure.
        $vmNamefull = "$($currentItem.vmName).$($currentItem.domain)"
        if ($multiNodeDsc -and ($currentItem.vmName -notin $ConfigurationData.AllNodes.NodeName) -and ($vmNamefull -notin $ConfigurationData.AllNodes.NodeName) -and -not ($Phase -eq 2 -and $currentItem.role -eq 'Proxy') -and -not ($Phase -eq 3 -and (Test-VmIsLinux -Vm $currentItem))) {
            Write-Log -Verbose "Skipping $($currentItem.vmName) because it does not exist in ConfigData"
            continue
        }

        $deployConfigCopy = $deployConfig | ConvertTo-Json -depth 5 | ConvertFrom-Json
        $deployConfigCopy.parameters.ThisMachineName = $currentItem.vmName

        if ($WhatIf) {
            Write-Log "[Phase $Phase] Will start a job for VM $($currentItem.vmName)"
            continue
        }

        $jobName = "$($currentItem.vmName) [$($currentItem.role)] "
        if ($currentItem.vmName.Length -gt $maxVmNameLength) {
            $maxVmNameLength = $currentItem.vmName.Length
        }
        if ($currentItem.role.Length -gt $maxRoleNameLength) {
            $maxRoleNameLength = $currentItem.role.Length
        }

        # Linux Proxy (Phase 2): dispatch a per-VM job that runs the Squid
        # install. This gives the Proxy VM the same Wait-Phase progress row
        # as the Windows DSC jobs, and bypasses the multi-node DSC skip
        # below (the Proxy has no DSC config so it isn't in
        # $ConfigurationData.AllNodes). The install bash short-circuits
        # quickly when squid is already healthy, so dispatching
        # unconditionally is cheap and keeps the progress UI consistent.
        if ($Phase -eq 2 -and $currentItem.role -eq 'Proxy') {
            $job = Start-Job -ScriptBlock $global:Proxy_Install -Name $jobName -ErrorAction Stop -ErrorVariable Err
            if (-not $job) {
                Write-Log "[Phase $Phase] Failed to create Proxy_Install job for VM $($currentItem.vmName). $Err" -Failure
                $job_created_no++
            }
            else {
                Write-Log "[Phase $Phase] Created job $($job.Id) for VM $($currentItem.vmName) (Proxy_Install)" -LogOnly
                $jobs += $job
                $job_created_yes++
            }
            continue
        }

        # Linux Phase 3: dispatch a per-VM job that applies role-driven
        # post-boot config (xrdp/xfce4/Firefox for enableRDP, realm-join for
        # joinDomain). Mirrors the Phase 2 Proxy_Install branch so Linux VMs
        # get the same Wait-Phase progress treatment and run in parallel with
        # the Windows DSC jobs instead of bloating cloud-init first boot.
        # No-op success (returns true) when the VM has no applicable flags.
        if ($Phase -eq 3 -and (Test-VmIsLinux -Vm $currentItem)) {
            $job = Start-Job -ScriptBlock $global:Linux_Configure -Name $jobName -ErrorAction Stop -ErrorVariable Err
            if (-not $job) {
                Write-Log "[Phase $Phase] Failed to create Linux_Configure job for VM $($currentItem.vmName). $Err" -Failure
                $job_created_no++
            }
            else {
                Write-Log "[Phase $Phase] Created job $($job.Id) for VM $($currentItem.vmName) (Linux_Configure)" -LogOnly
                $jobs += $job
                $job_created_yes++
            }
            continue
        }

        if ($Phase -eq 0 -or $Phase -eq 1 -or $Phase -eq 10 -or $Phase -eq 11) {

            if ($Phase -eq 11) {
                # Phase 11 = functional validation. Skip only roles that have no
                # PSDirect-reachable validation surface (OSDClient is the boot
                # task-sequence image, AADClient isn't in the domain so
                # Invoke-VmCommand's domain-cred path can't reach them reliably).
                # Client roles (DomainMember/WorkgroupMember/InternetClient) DO
                # run -- see Test-DomainMemberFunctionality et al.
                if ($currentItem.Role -in @("OSDClient", "AADClient")) {
                    continue
                }
                if ($usePhaseThreadJob) {
                    $job = Start-ThreadJob -ScriptBlock $global:Phase11Job -Name $jobName -ThrottleLimit $phaseThreadJobThrottle -ArgumentList $currentItem, (, @()), $true, $false, $PSScriptRoot -ErrorAction Stop -ErrorVariable Err
                }
                else {
                    $job = Start-Job -ScriptBlock $global:Phase11Job -Name $jobName -ArgumentList $currentItem, (, @()), $true, $false, $PSScriptRoot -ErrorAction Stop -ErrorVariable Err
                }
                if (-not $job) {
                    Write-Log "[Phase $Phase] Failed to create job for VM $($currentItem.vmName). $Err" -Failure
                    $job_created_no++
                }
            }
            elseif ($Phase -eq 10) {         
                if ($currentItem.Role -in @("OSDClient", "AADClient")) {
                    continue
                }
                if ($phase10SkipSet.ContainsKey($currentItem.vmName)) {
                    Write-Log "[Phase 10] $($currentItem.vmName): $($phase10SkipSet[$currentItem.vmName])" -LogOnly
                    continue
                }
                # -ArgumentList $currentItem, (, $argument1), $argument2, $argument3, $PSScriptRoot
                # 3rd arg ($FreshDeployOnly in Phase10Job) is $false. Phase 10
                # brings the VM to 100% up-to-date, so route through the
                # AppliesToExisting filter (which is a superset of
                # NeededOnFreshDeploy). Per-fix version check inside
                # Start-VMFixes still no-ops fixes already at version, so this
                # stays cheap on a fresh deploy.
                if ($usePhaseThreadJob) {
                    $job = Start-ThreadJob -ScriptBlock $global:Phase10Job -Name $jobName -ThrottleLimit $phaseThreadJobThrottle -ArgumentList $currentItem, (, @()), $false, $false, $PSScriptRoot -ErrorAction Stop -ErrorVariable Err
                }
                else {
                    $job = Start-Job -ScriptBlock $global:Phase10Job -Name $jobName -ArgumentList $currentItem, (, @()), $false, $false, $PSScriptRoot -ErrorAction Stop -ErrorVariable Err
                }
                if (-not $job) {
                    Write-Log "[Phase $Phase] Failed to create job for VM $($currentItem.vmName). $Err" -Failure
                    $job_created_no++
                }
            }
            else {
                # Create/Prepare VM
                $job = Start-Job -ScriptBlock $global:VM_Create -Name $jobName -ErrorAction Stop -ErrorVariable Err
                if (-not $job) {
                    Write-Log "[Phase $Phase] Failed to create job for VM $($currentItem.vmName). $Err" -Failure
                    $job_created_no++
                }
                else {
                    if ($Phase -eq 1) {
                        # Add VM's that started jobs in phase 1 (VM Creation) to global remove list.
                        #if (-not $Migrate) {
                        $global:vm_remove_list += ($jobName -split " ")[0]
                        #}
                    }
                }
            }
        }
        else {
            $reservation = $null
            #Phase 5 is for SQL Always on.. So if we are in this phase, it is a SQLAO node
            $alreadyCopiedDSC = $false
            if (-not $global:DSC_Copied) {
                $global:DSC_Copied = @()
            }
            if ($currentitem.VmName -in $global:DSC_Copied) {
                write-log "[alreadyCopiedDSC] $($currentItem.VmName) was in $($global:DSC_Copied -join ','))" -verbose -logonly
                $alreadyCopiedDSC = $true
            }
            else {
                $global:DSC_Copied += $currentItem.VmName
                $global:DSC_CopiedTime = Get-Date
            }
            Write-Log -verbose "[Phase $Phase] $($currentItem.vmName) alreadyCopiedDSC = $alreadyCopiedDSC"
            $job = Start-Job -ScriptBlock $global:VM_Config -Name $jobName -ErrorAction Stop -ErrorVariable Err
            if (-not $job) {
                Write-Log "[Phase $Phase] Failed to create job for VM $($currentItem.vmName). $Err" -Failure
                $job_created_no++
            }
        }

        if ($Err.Count -ne 0) {
            Write-Log "[Phase $Phase] Failed to start job for VM $($currentItem.vmName). $Err" -Failure
            $job_created_no++
        }
        else {
            Write-Log "[Phase $Phase] Created job $($job.Id) for VM $($currentItem.vmName)" -LogOnly
            $jobs += $job
            $job_created_yes++
        }
    }

    $additionalData = [PSCustomObject]@{
        MaxVmNameLength   = $maxVmNameLength
        MaxRoleNameLength = $maxRoleNameLength + 2
    }

    # Create return object
    $return = [PSCustomObject]@{
        Failed         = $job_created_no
        Success        = $job_created_yes
        Jobs           = $jobs
        Applicable     = $true
        AdditionalData = $additionalData
    }

    Write-Progress2 "Preparing Phase $Phase" -Status "Created $job_created_yes jobs." -PercentComplete 100 -Completed

    if ($job_created_no -eq 0) {
        Write-Log "[Phase $Phase] Created $job_created_yes jobs. Waiting for jobs."
    }
    else {
        Write-Log "[Phase $Phase] Created $job_created_yes jobs. Failed to create $job_created_no jobs."
    }

    return $return

}

function Wait-Phase {

    param(
        [object]$Phase,
        $Jobs,
        $AdditionalData,
        [object]$DeployConfig
    )
    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'SilentlyContinue'

    $esc = [char]27
    $hideCursor = "$esc[?25l"
    $showCursor = "$esc[?25h"

    $StartTime = $(get-date)

    try {

        Set-PS7ProgressWidth # Refresh progress bar width in case the terminal was resized
        Write-Host -NoNewline "$hideCursor" # Reduce flickering in Progress bars

        # Diagnostic (gated by $global:ProgressDiag): one-time environment snapshot.
        # Progress auto-render behavior differs by PSStyle.Progress.View (Minimal vs
        # Classic), so capture it along with host/version and the active prefs/switches.
        if ($global:ProgressDiag) {
            $pv = "n/a"; $pw = "n/a"
            try { $pv = $PSStyle.Progress.View } catch {}
            try { $pw = $PSStyle.Progress.MaxWidth } catch {}
            Write-ProgressDiagLog ("[Env] Phase={0} Host={1} HostVer={2} ProgressView={3} ProgressMaxWidth={4} GlobalPref={5} PS7={6} UseLocalPref={7}" -f $Phase, $Host.Name, $Host.Version, $pv, $pw, $Global:ProgressPreference, $Common.PS7, ($global:ProgressForceUseLocalPref -ne $false))
            $global:ProgressDiagJobVolume = @{}
        }

        # Create return object
        $return = [PSCustomObject]@{
            Failed  = 0
            Success = 0
            Warning = 0
            Elapsed = $null
        }

        $global:JobProgressHistory = @{}

        # Track how many output objects we've already displayed per job so
        # warnings/errors from running jobs appear in real-time instead of
        # being deferred until the job completes.
        $outputDisplayed = @{}

        # DSC log diagnostics: after a job runs 30+ min, peek at the
        # guest's ConfigurationStatus folder for exceptions/failures and
        # log them. Purely informational -- never fails the phase.
        $dscDiagLastCheck = @{}   # VMName -> [datetime] last check
        $dscDiagInitialMinutes = 30
        $dscDiagIntervalMinutes = 15
        $dscDiagSkipRoles = @('Proxy', 'LinuxServer', 'LinuxClient', 'OSDClient', 'AADClient', 'InternetClient')

        $FailRetry = 0
        do {
            # Begin synchronized output so Windows Terminal buffers all progress
            # bar redraws and paints them as a single frame (eliminates flicker).
            [Console]::Write("$esc[?2026h")

            $runningJobs = $jobs | Where-Object { $_.State -ne "Completed" -and $_.State -ne "Failed" } | Sort-Object -Property Id

            foreach ($job in $runningJobs) {
                Write-JobProgress -Job $job -AdditionalData $AdditionalData

                # Diagnostic: record progress-stream volume/last-record for this job.
                Write-JobProgressDiag -Job $job

                # Surface warning/error output objects from running jobs immediately.
                $streamSource = Get-JobStreamSource -Job $job
                if ($streamSource -and $streamSource.Output) {
                    $shown = if ($outputDisplayed.ContainsKey($job.Id)) { $outputDisplayed[$job.Id] } else { 0 }
                    $total = $streamSource.Output.Count
                    for ($oi = $shown; $oi -lt $total; $oi++) {
                        $obj = $streamSource.Output[$oi]
                        if ($obj -and $obj.LogLevel -ge 2 -and $obj.Text) {
                            $line = $obj.Text.ToString().Trim()
                            if ($obj.LogLevel -eq 3) {
                                Write-RedX $line -ForegroundColor $obj.ForegroundColor
                            }
                            else {
                                Write-OrangePoint $line -ForegroundColor $obj.ForegroundColor
                            }
                        }
                    }
                    $outputDisplayed[$job.Id] = $total
                }
            }

            # Blanket-dismiss ActivityId 0 after each poll cycle. CIM cmdlets
            # (DHCP, Hyper-V) write progress at Id 0 in child processes. Even
            # with $Global:ProgressPreference = 'SilentlyContinue', PS7 can
            # auto-render these from the PSDataCollection before our poll picks
            # them up, producing blank/stray lines. Writing -Completed for Id 0
            # every 500ms ensures any such orphan is immediately cleared.
            Write-Progress2 -Activity "." -Id 0 -Status "Completed" -Completed -force

            $failedJobs = $jobs | Where-Object { $_.State -eq "Failed" } | Sort-Object -Property Id
            foreach ($job in $failedJobs) {
                $FailRetry = $FailRetry + 1
                if ($FailRetry -gt 30) {
                    try {
                        # ThreadJob has no ChildJobs -- read state/error from the job itself.
                        $streamSource = Get-JobStreamSource -Job $job
                        if ($job.Name) {
                            $jobOutput = $job.Name
                            $jobOutput += " "
                        }
                        else {
                            $jobOutput = ""
                        }
                        $joberror = $streamSource | Select-Object -ExpandProperty Error
                        if ($joberror -is [string]) {
                            $jobOutput += $joberror
                            $jobOutput += " "
                        }
                   
                        if ($streamSource.JobStateInfo.Reason.ErrorRecord.Exception) {
                            if ($streamSource.JobStateInfo.Reason.ErrorRecord.Exception.Message) {
                                $jobOutput += $streamSource.JobStateInfo.Reason.ErrorRecord.Exception.Message
                                $jobOutput += " "
                            }
                            else {
                                $jobOutput += $streamSource.JobStateInfo.Reason.ErrorRecord.Exception
                                $jobOutput += " "
                            }
                        }
                        if ($streamSource.JobStateInfo.Message) {
                            $jobOutput += $streamSource.JobStateInfo.Message
                            $jobOutput += " "
                        }
                    }
                    catch {
                        Write-Log "Job failed Error Gathering Job Output: : $_" -LogOnly
                        $jobOutput = "Error Gathering Job Output: " + $jobOutput
                    }
                                   
                    $jobJson = $job | convertTo-Json -depth 5 -WarningAction SilentlyContinue
                    Write-Log "[Phase $Phase] Job failed: $jobJson" -LogOnly
                    Write-RedX "[Phase $Phase] Job failed: $jobOutput" -ForegroundColor Red
                    Write-Progress2 -Id $job.Id -Activity $job.Name -Completed -force

                    # Capture per-VM timing for failed jobs too
                    if ($global:BuildStats -and $job.Name -match '^(.+?)\s+\[(.+?)\]') {
                        $fvmName = $Matches[1]
                        $fRole = $Matches[2]
                        $fStart = if ($job.PSBeginTime) { $job.PSBeginTime } else { $StartTime }
                        $fEnd = if ($job.PSEndTime) { $job.PSEndTime } else { Get-Date }
                        if (-not $global:BuildStats.VMs.ContainsKey($fvmName)) {
                            $global:BuildStats.VMs[$fvmName] = @{ Role = $fRole; Phases = @{} }
                        }
                        $global:BuildStats.VMs[$fvmName].Phases[$Phase] = @{
                            Elapsed = ($fEnd - $fStart)
                            Start   = $fStart
                            End     = $fEnd
                            Failed  = $true
                        }
                    }

                    $jobs.Remove($job)
                    $return.Failed++
                }
            }
            $completedJobs = $jobs | Where-Object { $_.State -eq "Completed" } | Sort-Object -Property Id
            foreach ($job in $completedJobs) {
                # Diagnostic: log unique progress activities to identify CIM cmdlet leaks
                $streamSource2 = Get-JobStreamSource -Job $job
                if ($streamSource2 -and $streamSource2.Progress -and $streamSource2.Progress.Count -gt 0) {
                    $acts = @{}
                    foreach ($pr in $streamSource2.Progress) {
                        $k = "$($pr.ActivityId)|$($pr.Activity)"
                        if (-not $acts.ContainsKey($k)) { $acts[$k] = 0 }
                        $acts[$k]++
                    }
                    $diagLines = $acts.GetEnumerator() | ForEach-Object { "$($_.Key) x$($_.Value)" }
                    Write-Log "[Diag] $($job.Name) progress: $($diagLines -join '; ')" -LogOnly
                }

                Write-Progress2 -Id $job.Id -Activity $job.Name -Completed -force
                #Write-JobProgress -Job $job -AdditionalData $AdditionalData
                $jobName = $job | Select-Object -ExpandProperty Name

                # Capture per-VM timing into $global:BuildStats
                if ($global:BuildStats) {
                    $parsedVmName = $null
                    $parsedRole = $null
                    if ($jobName -match '^(.+?)\s+\[(.+?)\]') {
                        $parsedVmName = $Matches[1]
                        $parsedRole = $Matches[2]
                    }
                    if ($parsedVmName) {
                        # Use PSBeginTime/PSEndTime when available (Start-Job); fall back to phase start/now (ThreadJob)
                        $jobStart = if ($job.PSBeginTime) { $job.PSBeginTime } else { $StartTime }
                        $jobEnd = if ($job.PSEndTime) { $job.PSEndTime } else { Get-Date }
                        $jobElapsed = $jobEnd - $jobStart

                        if (-not $global:BuildStats.VMs.ContainsKey($parsedVmName)) {
                            $global:BuildStats.VMs[$parsedVmName] = @{
                                Role   = $parsedRole
                                Phases = @{}
                            }
                        }
                        $global:BuildStats.VMs[$parsedVmName].Phases[$Phase] = @{
                            Elapsed = $jobElapsed
                            Start   = $jobStart
                            End     = $jobEnd
                        }
                    }
                }

                # ThreadJob has no ChildJobs -- streams live directly on the job.
                $streamSource = Get-JobStreamSource -Job $job
                $jobOutput = $streamSource | Select-Object -ExpandProperty Output
                if (-not $jobOutput) {
                    $jobError = $streamSource | Select-Object -ExpandProperty Error

                    if ($jobError) {
                        Write-RedX "[Phase $Phase] Job $jobName completed with error: $jobError" -ForegroundColor Red
                    }
                    else {
                        Write-RedX "[Phase $Phase] Job $jobName completed with no output" -ForegroundColor Red
                    }
                    $jobJson = $job | ConvertTo-Json -Depth 5 -WarningAction SilentlyContinue
                    write-log -LogOnly $jobJson
                    $return.Failed++
                }
                #$logLevel = 1    # 0 = Verbose, 1 = Info, 2 = Warning, 3 = Error
                $worstLogLevel = 0
                # Items with LogLevel >= 2 that were already surfaced while the
                # job was running should not be printed again.
                $alreadyShown = if ($outputDisplayed.ContainsKey($job.Id)) { $outputDisplayed[$job.Id] } else { 0 }
                $outputIndex = 0
                foreach ($OutputObject in $jobOutput) {
                    $outputIndex++
                    $line = $OutputObject.text
                    if (-not $line) {
                        continue
                    }
                    $line = $line.ToString().Trim()
                    if ($OutputObject.LogLevel -gt $worstLogLevel) { $worstLogLevel = $OutputObject.LogLevel }

                    # Skip warning/error items already displayed while the job was running
                    if ($outputIndex -le $alreadyShown -and $OutputObject.LogLevel -ge 2) {
                        # DC/CAS failure still needs to stop the phase even if already displayed.
                        # Exception: Phase 11 is validation -- continue so we collect every problem.
                        if ($OutputObject.LogLevel -eq 3 -and $phase -ge 2 -and $phase -ne 11 -and ($jobName.Contains("[DC]") -or $jobName.Contains("[CAS]"))) {
                            $critRole = if ($jobName.Contains("[DC]")) { "DC" } else { "CAS" }
                            Write-RedX "$critRole failed. Stopping Phase." -ForegroundColor $OutputObject.ForegroundColor
                            try { $jobs | Stop-Job } catch {}
                            $return.Failed++
                            return $return
                        }
                        continue
                    }

                    if ($OutputObject.LogLevel -eq 3) {
                        Write-RedX $line -ForegroundColor $OutputObject.ForegroundColor
                        if ($phase -ge 2 -and $phase -ne 11 -and ($jobName.Contains("[DC]") -or $jobName.Contains("[CAS]"))) {
                            $critRole = if ($jobName.Contains("[DC]")) { "DC" } else { "CAS" }
                            Write-RedX "$critRole failed. Stopping Phase." -ForegroundColor $OutputObject.ForegroundColor
                            try {
                                $jobs | Stop-Job
                            }
                            catch {}
                            $return.Failed++
                            return $return
                        }
                    }
                    elseif ($OutputObject.LogLevel -eq 2) {
                        Write-OrangePoint $line -ForegroundColor $OutputObject.ForegroundColor
                    }
                    else {
                        Write-GreenCheck $line -ForegroundColor $OutputObject.ForegroundColor
                    }
                }

                # Count once per job based on worst severity seen
                if ($worstLogLevel -ge 3) { $return.Failed++ }
                elseif ($worstLogLevel -ge 2) { $return.Warning++ }
                elseif ($jobOutput) { $return.Success++ }

                #Write-Progress2 -Id $job.Id -Activity $job.Name -Completed
                $jobs.Remove($job)
            }

            # End synchronized output — terminal renders all progress updates as one frame.
            [Console]::Write("$esc[?2026l")

            # DSC log diagnostics for long-running jobs (phases 2-9 only).
            # Check one VM per loop iteration to keep progress display responsive.
            if ($Phase -ge 2 -and $Phase -le 9 -and $DeployConfig -and $runningJobs.Count -gt 0) {
                $phaseElapsedMin = ((Get-Date) - $StartTime).TotalMinutes
                if ($phaseElapsedMin -ge $dscDiagInitialMinutes) {
                    :dscDiag foreach ($dscJob in $runningJobs) {
                        if ($dscJob.Name -match '^(.+?)\s+\[(.+?)\]') {
                            $dscVmName = $Matches[1]
                            $dscVmRole = $Matches[2]
                            if ($dscVmRole -in $dscDiagSkipRoles) { continue }
                            # Skip VMs that have moved past DSC into ConfigMgr setup
                            $dscJobStream = Get-JobStreamSource -Job $dscJob
                            if ($dscJobStream -and $dscJobStream.Progress -and $dscJobStream.Progress.Count -gt 0) {
                                $dscLastProgress = $dscJobStream.Progress[$dscJobStream.Progress.Count - 1]
                                if ($dscLastProgress.StatusDescription -match 'ConfigMgrSetup\.log|Setting up ConfigMgr') {
                                    continue
                                }
                            }
                            $dscNow = Get-Date
                            $dscLast = $dscDiagLastCheck[$dscVmName]
                            if ($dscLast -and ($dscNow - $dscLast).TotalMinutes -lt $dscDiagIntervalMinutes) { continue }
                            $dscDiagLastCheck[$dscVmName] = $dscNow
                            try {
                                $dscDiagResult = Invoke-VmCommand -VmName $dscVmName `
                                    -VmDomainName $DeployConfig.vmOptions.domainName `
                                    -SuppressLog -TimeoutSeconds 30 -SessionMaxRetries 1 -ScriptBlock {
                                    $statusPath = "$env:SystemRoot\System32\Configuration\ConfigurationStatus"
                                    if (-not (Test-Path $statusPath)) { return $null }
                                    $files = Get-ChildItem -Path $statusPath -Filter "*.json" -ErrorAction SilentlyContinue |
                                        Sort-Object LastWriteTime -Descending | Select-Object -First 3
                                    $diag = @()
                                    foreach ($f in $files) {
                                        try {
                                            $tail = Get-Content -Path $f.FullName -Tail 10 -ErrorAction Stop
                                            $hits = @($tail | Where-Object {
                                                $_ -match 'exception|"Status"\s*:\s*"Failure"|"Error"\s*:\s*".+"' })
                                            if ($hits.Count -gt 0) {
                                                $snippet = ($hits | ForEach-Object { $_.Trim() }) -join ' | '
                                                if ($snippet.Length -gt 500) { $snippet = $snippet.Substring(0, 500) + '...' }
                                                $diag += "$($f.Name): $snippet"
                                            }
                                        }
                                        catch { <# file locked #> }
                                    }
                                    if ($diag.Count -gt 0) { return $diag }
                                    return $null
                                }
                                if ($dscDiagResult.ScriptBlockOutput) {
                                    $elapsed = [math]::Round($phaseElapsedMin, 0)
                                    Write-Log "[Phase $Phase] DSC diagnostics for ${dscVmName} (${elapsed}m elapsed):" -LogOnly
                                    foreach ($dscLine in $dscDiagResult.ScriptBlockOutput) {
                                        Write-Log "[Phase $Phase]   $dscVmName - $dscLine" -LogOnly
                                    }
                                }
                            }
                            catch {
                                Write-Log "[Phase $Phase] DSC diagnostics: failed to query $dscVmName - $_" -LogOnly -Verbose
                            }
                            break :dscDiag  # one VM per iteration
                        }
                    }
                }
            }

            # Sleep
            Start-Sleep -Milliseconds 500

        } until (($runningJobs.Count -eq 0) -and ($failedJobs.Count -eq 0))

        $return.Elapsed = $(get-date) - $StartTime
        return $return
    }
    catch {
        Write-Exception -ExceptionInfo $_
    }
    finally {
        $Global:ProgressPreference = $OriginalProgressPreference
        Write-Host -NoNewline "$showCursor" # Show cursor again
    }
}

function Get-ConfigurationData {
    param (
        [int]$Phase,
        [object]$deployConfig
    )

    #$netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
    $netbiosName = $deployConfig.vmOptions.domainNetBiosName
    if (-not $netbiosName) {
        write-Log -Failure "[Phase $Phase] Could not get Netbios name from 'deployConfig.vmOptions.domainName' "
        return
    }

    switch ($Phase) {
        "2" { $cd = Get-Phase2ConfigurationData -deployConfig $deployConfig }
        "3" { $cd = Get-Phase3ConfigurationData -deployConfig $deployConfig }
        "4" { $cd = Get-Phase4ConfigurationData -deployConfig $deployConfig }
        "5" { $cd = Get-Phase5ConfigurationData -deployConfig $deployConfig }
        "6" { $cd = Get-Phase6ConfigurationData -deployConfig $deployConfig }
        "7" { $cd = Get-Phase7ConfigurationData -deployConfig $deployConfig }
        "8" {
            $cd = Get-Phase8ConfigurationData -deployConfig $deployConfig
            if ($cd -and -not $global:NoSnapshot) {
                $autoSnapshotName = "MemLabs Phase 8 AutoSnapshot " + $Global:ConfigurationShort
                $snapshot = $null
                $dc = get-list2 -deployConfig $deployConfig | Where-Object { $_.role -eq "DC" }
                if ($dc) {
                    $snapshot = Get-VMCheckpoint2 -VMName $dc.vmName -ErrorAction SilentlyContinue | where-object { $_.Name -like "*$autoSnapshotName*" } | Sort-Object CreationTime | Select-Object -ExpandProperty Name
                }

                # Snapshot decision is based ONLY on CAS/Primary site servers in
                # the Phase 8 set. They are the ones actually running CM setup;
                # other Phase 8 VMs (DPMP, PassiveSite, Secondary, etc.) are
                # secondary work whose failure is recoverable. Other roles
                # (AAD-joined clients, etc.) don't even run in Phase 8.
                #
                # Snapshot only when there's a CAS/Primary in the set that has
                # NOT yet finished Phase 8 -- i.e. the risky first CM install is
                # about to happen. If the CAS/Primary in scope has already done
                # Phase 8 once (re-run, validation pass, adding a secondary),
                # the install already succeeded and a new rollback point is
                # unnecessary. If there's no CAS/Primary in the Phase 8 set at
                # all, no CM site install is happening -- also skip.
                # lastPhaseComplete is now monotonic (see Set-VMNote in Common.ps1),
                # so '< 8' reliably means "this CAS/Primary has never finished
                # Phase 8" -- the only state where a pre-install rollback point
                # is useful. This correctly covers both the happy first-deploy
                # path AND a resume after an earlier phase (e.g. Phase 4) failed,
                # while skipping no-op re-runs on a lab that already reached 8+.
                $phase8SiteServers = $cd.AllNodes | Where-Object {
                    $_.NodeName -ne "*" -and ($_.Role -eq 'CAS' -or $_.Role -eq 'Primary')
                }
                $needsSnapshot = $false
                $pendingSiteServer = $null
                foreach ($node in $phase8SiteServers) {
                    $vmNote = Get-VMNote -VMName $node.NodeName
                    if (-not $vmNote -or -not $vmNote.lastPhaseComplete -or $vmNote.lastPhaseComplete -lt 8) {
                        $needsSnapshot = $true
                        $pendingSiteServer = $node.NodeName
                        break
                    }
                }

                if (-not $needsSnapshot) {
                    if (-not $phase8SiteServers) {
                        Write-Log "[Phase 8] Skipping auto-snapshot: no CAS/Primary in Phase 8 set" -LogOnly
                    }
                    else {
                        Write-Log "[Phase 8] Skipping auto-snapshot: CAS/Primary already completed Phase 8 (re-run)" -LogOnly
                    }
                }
                elseif (-not $snapshot) {
                    $response = Read-YesOrNoWithTimeout -timeout 30 -prompt "Automatically take snapshot of domain? (Y/n)" -HideHelp -Default "y"
                    if (-not ($response -eq "n")) {
                        Invoke-AutoSnapShotDomain -domain $deployConfig.vmOptions.DomainName -comment $autoSnapshotName
                        write-log -HostOnly ""
                        write-log "Auto Snapshot $autoSnapshotName completed."
                    }
                }

            }

        }
        "9" { $cd = Get-Phase9ConfigurationData -deployConfig $deployConfig }
        Default { return }
    }
    if ($global:Common.VerboseEnabled) {
        $cd | ConvertTo-Json | out-host
    }

    if ($cd) {

        $global:preparePhasePercent++
        Start-Sleep -Milliseconds 251
        Write-Progress2 "Preparing Phase $Phase" -Status "Verifying all required VMs are running" -PercentComplete $global:preparePhasePercent

        $nodes = $cd.AllNodes.NodeName | Where-Object { $_ -ne "*" -and ($_ -ne "LOCALHOST") }
        if ($nodes) {
            $critlist = Get-CriticalVMs -domain $deployConfig.vmOptions.domainName -vmNames $nodes
        }

        # Start BDCs alongside the primary DC in every phase.  BDCs aren't in
        # ConfigurationData for phases 4-9 (no DSC work for them), but they
        # must be running for AD replication and DNS availability.
        # Use Get-List to discover all BDCs in the domain, since deployConfig
        # only contains VMs explicitly added to the current configuration.
        $allDomainVMs = Get-List -Type VM -DomainName $deployConfig.vmOptions.domainName -SmartUpdate
        $bdcVMs = @($allDomainVMs | Where-Object { $_.Role -eq "BDC" })
        foreach ($bdc in $bdcVMs) {
            if ($bdc.State -ne 'Running') {
                Write-Log "[Phase $Phase] BDC [$($bdc.vmName)] is $($bdc.State). Starting..." -LogOnly
                Start-VM2 -Name $bdc.vmName -ErrorAction SilentlyContinue
            }
        }

        $global:preparePhasePercent++
        Start-Sleep -Milliseconds 251
        Write-Progress2 "Preparing Phase $Phase" -Status "Starting required VMs (if needed)" -PercentComplete $global:preparePhasePercent -log

        if ($critlist) {
            $failures = Invoke-SmartStartVMs -CritList $critlist
            if ($failures -ne 0) {
                write-log "$failures VM(s) could not be started" -Failure
            }
        }

        $dc = $cd.AllNodes | Where-Object { $_.Role -eq "DC" }
        if ($dc -and -not $global:StartPhase) {

            $global:preparePhasePercent++
            Start-Sleep -Milliseconds 251
            Write-Progress2 "Preparing Phase $Phase" -Status "Testing net connection to 3389 on $($dc.NodeName)" -PercentComplete $global:preparePhasePercent -Log

            $OriginalProgressPreference = $Global:ProgressPreference
            try {
                $Global:ProgressPreference = 'SilentlyContinue'
    
                # Test if VM is responsive with multiple checks
                $isResponsive = Test-VmResponsive -VmName $dc.NodeName -TimeoutSeconds 15
    
                if (-not $isResponsive) {
                    Write-Log "[Phase $Phase]: $($dc.NodeName): VM is not responsive. Performing hard restart." -Warning
        
                    # Hard cycle the VM
                    $restarted = Restart-UnresponsiveVm -VmName $dc.NodeName -WaitTimeSeconds 90
        
                    if (-not $restarted) {
                        Write-Log "[Phase $Phase]: $($dc.NodeName): VM failed to become responsive after restart" -Error
                        # You might want to throw an exception here or handle the failure
                    }
                    else {
                        Write-Log "[Phase $Phase]: $($dc.NodeName): VM successfully restarted and is responsive"
                    }
                }
                else {
                    Write-Log "[Phase $Phase]: $($dc.NodeName): VM is responsive" -LogOnly
        
                    # RDP port probe with hard timeout + retry (Test-NetConnection can hang)
                    $testNet = Test-TcpPort -ComputerName $dc.NodeName -Port 3389 -TimeoutMs 3000 -Retries 3 -RetryDelayMs 1000
        
                    if (-not $testNet) {
                        Write-Log "[Phase $Phase]: $($dc.NodeName): RDP port not accessible after retries. Attempting soft restart." -Warning
                        Invoke-VmCommand -VmName $dc.NodeName -VmDomainName $deployConfig.vmOptions.domainName -ScriptBlock { Restart-Computer -Force } | Out-Null
                        Wait-ForHeartbeat -VmName $dc.NodeName | Out-Null
                    }
                }
            }
            catch {
                Write-Log "[Phase $Phase]: $($dc.NodeName): Error during VM connectivity test: $_" -Error
            }
            finally {
                Write-Progress2 "Preparing Phase $Phase" -Status "Done Testing net connection on $($dc.NodeName)" -PercentComplete $global:preparePhasePercent -Log
                $Global:ProgressPreference = $OriginalProgressPreference
            }
        }

    }

    return $cd
}

function Get-Phase2ConfigurationData {
    param (
        [object]$deployConfig
    )

    $cd = @{
        AllNodes = @(
            @{
                NodeName                    = 'LOCALHOST'
                PSDscAllowDomainUser        = $true
                PSDscAllowPlainTextPassword = $true
            }
        )
    }

    foreach ($vm in $deployConfig.virtualMachines) {

        $global:preparePhasePercent++

        # Filter out machines with an unconnectable OS, except AADClient, which has a special case to skip the DSC
        if ($vm.role -ne "OSDClient") {
            if (-not $vm.Hidden) {
                $cd
                #Write-Host "xxxReturning $cd for $($vm.vmName)"
                return $cd
            }
        }
    }
    return $null
}

function Get-Phase3ConfigurationData {
    param (
        [object]$deployConfig
    )

    $cd = @{
        AllNodes = @(
            @{
                NodeName                    = '*'
                PSDscAllowDomainUser        = $true
                PSDscAllowPlainTextPassword = $true
            }
        )
    }

    $NumberOfNodesAdded = 0
    foreach ($vm in $deployConfig.virtualMachines) {

        $global:preparePhasePercent++

        # Filter out workgroup machines and Linux (Proxy/LinuxServer/LinuxClient) -- no DSC for Linux.
        if ($vm.role -in "WorkgroupMember", "InternetClient", "OSDClient", "OtherDC", "AADClient", "StandaloneRootCA", "Proxy", "LinuxServer", "LinuxClient") {
            continue
        }

        if ($vm.hidden -and $vm.domain -and ($vm.domain -ne $deployConfig.vmoptions.domainName) ) {
            continue
        }
        $newItem = @{
            NodeName = $vm.vmName
            Role     = $vm.Role
        }
        $cd.AllNodes += $newItem
        if ($vm.Role -ne "DC") {
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
        }
    }


    if ($NumberOfNodesAdded -eq 0) {
        return
    }

    return $cd
}

function Get-Phase4ConfigurationData {
    param (
        [object]$deployConfig
    )

    $cd = @{
        AllNodes = @(
            @{
                NodeName                    = '*'
                PSDscAllowDomainUser        = $true
                PSDscAllowPlainTextPassword = $true
            }
        )
    }

    $NumberOfNodesAdded = 0
    #foreach ($vm in $deployConfig.virtualMachines | Where-Object { ($_.SqlVersion -and -not ($_.Hidden)) -or $_.Role -eq "DC" }) {
    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.SqlVersion -or $_.Role -eq "DC" }) {

        $global:preparePhasePercent++

        # Filter out workgroup machines and Linux (Proxy/LinuxServer/LinuxClient) -- no DSC for Linux.
        if ($vm.role -in "WorkgroupMember", "AADClient", "InternetClient", "OSDClient" , "OtherDC", "StandaloneRootCA", "Proxy", "LinuxServer", "LinuxClient") {
            continue
        }

        if ($vm.hidden -and $vm.domain -and ($vm.domain -ne $deployConfig.vmoptions.domainName) ) {
            continue
        }

        $newItem = @{
            NodeName = $vm.vmName
            Role     = $vm.Role
        }
        $cd.AllNodes += $newItem
        if ($vm.Role -ne "DC") {
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
        }
    }

    if ($NumberOfNodesAdded -eq 0) {
        return
    }

    return $cd
}

function Get-Phase5ConfigurationData {
    param (
        [object]$deployConfig
    )

    $primaryNodes = $deployConfig.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode -and -not ($_.hidden) }
    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }


    $NumberOfNodesAdded = 0
    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    $fileServersAdded = @()
    if ($primaryNodes) {

        foreach ($primaryNode in $primaryNodes) {


            if ($vm.hidden -and $vm.domain -and ($vm.domain -ne $deployConfig.vmoptions.domainName) ) {
                continue
            }

            $global:preparePhasePercent++

            $primary = @{
                # Replace with the name of the actual target node.
                NodeName = $primaryNode.vmName
                # This is used in the configuration to know which resource to compile.
                Role     = 'ClusterNode1'
            }

            $cd.AllNodes += $primary
            $secondary = @{
                # Replace with the name of the actual target node.
                NodeName = $primaryNode.OtherNode
                # This is used in the configuration to know which resource to compile.
                Role     = 'ClusterNode2'
            }
            $cd.AllNodes += $secondary
            #added Primary And Secondary

            if ($fileServersAdded -notcontains ( $primaryNode.fileServerVM)) {
                $fileServer = @{
                    # Replace with the name of the actual target node.
                    NodeName = $primaryNode.fileServerVM
                    # This is used in the configuration to know which resource to compile.
                    Role     = 'FileServer'
                }
                $cd.AllNodes += $fileServer
                $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                $fileServersAdded += $primaryNode.fileServerVM
            }
            $NumberOfNodesAdded = $NumberOfNodesAdded + 2
        }

        $all = @{
            NodeName                    = "*"
            PSDscAllowDomainUser        = $true
            PSDscAllowPlainTextPassword = $true
        }
        $cd.AllNodes += $all

    }

    if ($NumberOfNodesAdded -eq 0) {
        return
    }
    return $cd
}

function Get-Phase6ConfigurationData {
    param (
        [object]$deployConfig
    )

    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }

    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    $NumberOfNodesAdded = 0
    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.Role -eq "WSUS" -or $_.installSUP -eq $true }) {

        $global:preparePhasePercent++

        # Filter out workgroup machines and Linux (Proxy/LinuxServer/LinuxClient) -- no DSC for Linux.
        if ($vm.role -in "WorkgroupMember", "AADClient", "InternetClient", "OSDClient" , "OtherDC", "StandaloneRootCA", "Proxy", "LinuxServer", "LinuxClient") {
            continue
        }
        if ($vm.hidden -and $vm.domain -and ($vm.domain -ne $deployConfig.vmoptions.domainName) ) {
            continue
        }
        $newItem = @{
            NodeName = $vm.vmName
            Role     = "WSUS"
        }
        $cd.AllNodes += $newItem
        if ($vm.Role -ne "DC") {
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
        }
    }

    $all = @{
        NodeName                    = "*"
        PSDscAllowDomainUser        = $true
        PSDscAllowPlainTextPassword = $true
    }
    $cd.AllNodes += $all

    if ($NumberOfNodesAdded -eq 0) {
        return
    }

    return $cd
}

function Get-Phase7ConfigurationData {
    param (
        [object]$deployConfig
    )
    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }

    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    $NumberOfNodesAdded = 0
    # Pull in any VM that needs either PBIRS install OR a WSUS early sync.
    # WSUS sync was previously fired at end of Phase 6, but on a dual-role VM
    # (installSUP + installRP), the Phase 7 PBIRS install can trigger a reboot
    # that kills the in-flight sync. Running the sync at the end of Phase 7
    # (after PBIRS install completes) puts all install reboots before the sync.
    foreach ($vm in $deployConfig.virtualMachines | Where-Object {
            $_.installRP -eq $true -or $_.installSUP -eq $true -or $_.role -eq 'WSUS'
        }) {

        $global:preparePhasePercent++

        # Filter out workgroup machines and Linux (Proxy/LinuxServer/LinuxClient) -- no DSC for Linux.
        if ($vm.role -in "WorkgroupMember", "AADClient", "InternetClient", "OSDClient" , "OtherDC", "StandaloneRootCA", "Proxy", "LinuxServer", "LinuxClient") {
            continue
        }

        if ($vm.hidden -and $vm.domain -and ($vm.domain -ne $deployConfig.vmoptions.domainName) ) {
            continue
        }

        # PBIRS takes precedence -- if the VM also has WSUS, the PBIRS node
        # block adds the WSUSSync resource after InstallPBIRS completes.
        $synthRole = if ($vm.installRP -eq $true) { "PBIRS" } else { "WSUS" }
        $newItem = @{
            NodeName = $vm.vmName
            Role     = $synthRole
        }
        $cd.AllNodes += $newItem
        if ($vm.Role -ne "DC") {
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
        }
    }

    $all = @{
        NodeName                    = "*"
        PSDscAllowDomainUser        = $true
        PSDscAllowPlainTextPassword = $true
    }
    $cd.AllNodes += $all

    if ($NumberOfNodesAdded -eq 0) {
        return
    }

    return $cd
}
function Get-Phase8ConfigurationData {
    param (
        [object]$deployConfig
    )

    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }
    $NumberOfNodesAdded = 0
    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    if ($deployConfig.cmOptions.Install -ne $false) {

        $fsVMsAdded = @()
        foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in ("Primary", "CAS", "PassiveSite", "Secondary", "SiteSystem", "WSUS") }) {

            $global:preparePhasePercent++

            if ($vm.Role -eq "WSUS" -and -not $vm.InstallSUP) {
                continue
            }

            $MultiDomain = $false
            if ($vm.hidden -and $vm.domain -and ($vm.domain -ne $deployConfig.vmoptions.domainName) ) {
                continue
            }

            $newItem = @{
                NodeName = $vm.vmName
                Role     = $vm.Role
            }

            $cd.AllNodes += $newItem
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1

            if (-not $MultiDomain) {
                if ($vm.PassiveSite) {
                    if ($fsVMsAdded -notcontains $vm.remoteContentLibVM) {
                        $newItem = @{
                            NodeName = $vm.remoteContentLibVM
                            Role     = "FileServer"
                        }
                        $fsVMsAdded += $vm.remoteContentLibVM
                        $cd.AllNodes += $newItem
                        $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                    }
                }

                #if ($vm.PatchMyPCFileServer) {
                #    if ($fsVMsAdded -notcontains $vm.PatchMyPCFileServer) {
                #        $newItem = @{
                #            NodeName = $vm.PatchMyPCFileServer
                #            Role     = "FileServer"
                #        }
                #        $fsVMsAdded += $vm.PatchMyPCFileServer
                #        $cd.AllNodes += $newItem
                #        $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                #    }
                #}

                if ($vm.RemoteSQLVM) {
                    $remoteSQL = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $vm.RemoteSQLVM }
                    $newItem = @{
                        NodeName = $remoteSQL.vmName
                        Role     = "SqlServer"
                    }
                    if ($cd.AllNodes.NodeName -notcontains $($newItem.NodeName)) {
                        $cd.AllNodes += $newItem
                        $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                    }
                    if ($remoteSQL.OtherNode) {

                        if ($fsVMsAdded -notcontains $remoteSQL.fileServerVM) {
                            $newItem = @{
                                NodeName = $remoteSQL.fileServerVM
                                Role     = "FileServer"
                            }
                            $fsVMsAdded += $remoteSQL.fileServerVM
                            $cd.AllNodes += $newItem
                            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                        }

                        $newItem = @{
                            NodeName = $remoteSQL.OtherNode
                            Role     = "SqlServer"
                        }
                        if ($cd.AllNodes.NodeName -notcontains $($newItem.NodeName)) {
                            $cd.AllNodes += $newItem
                            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                        }
                    }
                }
            }
        }

        $all = @{
            NodeName                    = "*"
            PSDscAllowDomainUser        = $true
            PSDscAllowPlainTextPassword = $true
        }
        $cd.AllNodes += $all

    }

    # Even when cmOptions.Install is false (existing CM), include the hidden Primary
    # if there are new VMs with BitLocker=true that need BLM collection membership,
    # or new VMs that need client push. This allows ScriptWorkFlow re-run on the Primary
    # to handle EnableBLM and PushClients for newly added VMs.
    if ($NumberOfNodesAdded -eq 0) {
        $newBLMVMs = @($deployConfig.virtualMachines | Where-Object { $_.BitLocker -eq $true -and -not $_.hidden })
        # Per-VM pushClient opt-in (null/absent treated as $true for back-compat)
        $pushableRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
        $newPushVMs = @($deployConfig.virtualMachines | Where-Object {
                $_.role -in $pushableRoles -and -not $_.hidden -and ($_.pushClient -ne $false)
            })
        if ($newBLMVMs.Count -gt 0 -or $newPushVMs.Count -gt 0) {
            $hiddenPrimary = $deployConfig.virtualMachines | Where-Object {
                $_.role -eq "Primary" -and $_.hidden -and
                (-not $_.domain -or $_.domain -eq $deployConfig.vmOptions.domainName)
            } | Select-Object -First 1
            if ($hiddenPrimary) {
                $cd.AllNodes += @{ NodeName = $hiddenPrimary.vmName; Role = $hiddenPrimary.Role }
                $cd.AllNodes += @{ NodeName = "*"; PSDscAllowDomainUser = $true; PSDscAllowPlainTextPassword = $true }
                $NumberOfNodesAdded = 1
            }
        }
    }

    if ($NumberOfNodesAdded -eq 0) {
        return
    }
    return $cd
}

function Get-Phase9ConfigurationData {
    param (
        [object]$deployConfig
    )

    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }
    $NumberOfNodesAdded = 0
    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    $MultiDomain = $false
    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in ("Primary") -and $_.hidden }) {
        if ($vm.hidden -and $vm.domain -and ($vm.domain -ne $deployConfig.vmoptions.domainName) ) {
            if ($vm.role -ne "Primary") {
                continue
            }
            $MultiDomain = $true
        }
        if ($MultiDomain) {
            $role = $vm.role
            
            if ($role -eq "DomainMember") {
                if ($vm.sqlVersion) {
                    $role = "SqlServer"
                }
            }
            $newItem = @{
                NodeName = "$($vm.vmName).$($vm.domain)"
                #NodeName = "$($vm.vmName)"
                Role     = $role
            }
        }
        #else {
        #    $newItem = @{
        #        NodeName = $vm.vmName
        #        Role     = $vm.Role
        #    }
        #}
        $cd.AllNodes += $newItem
        $NumberOfNodesAdded = $NumberOfNodesAdded + 1

    }

    if (-not $MultiDomain) {
        return
    }
    $all = @{
        NodeName                    = "*"
        PSDscAllowDomainUser        = $true
        PSDscAllowPlainTextPassword = $true
    }
    $cd.AllNodes += $all


    if ($NumberOfNodesAdded -eq 0) {
        return
    }
    return $cd

}

function Get-GuestTimingStats {
    param (
        [object]$deployConfig
    )

    if (-not $global:BuildStats) { return }

    foreach ($vm in $deployConfig.virtualMachines) {
        if ($vm.hidden) { continue }
        if (Test-VmIsLinux -Vm $vm) { continue }
        if ($vm.role -in @('OSDClient', 'AADClient')) { continue }

        # Skip VMs that aren't running (avoids session errors on partial-phase runs)
        $vmObj = Get-VM2 -Name $vm.vmName -ErrorAction SilentlyContinue
        if (-not $vmObj -or $vmObj.State -ne 'Running') { continue }

        try {
            $json = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $deployConfig.vmOptions.domainName -SuppressLog -TimeoutSeconds 30 -ScriptBlock {
                $path = "C:\staging\DSC\ScriptWorkflow.json"
                if (Test-Path $path) { Get-Content $path -Raw } else { $null }
            }

            if (-not $json -or -not $json.ScriptBlockOutput) { continue }
            $raw = $json.ScriptBlockOutput
            $wf = $raw | ConvertFrom-Json

            $components = @{}
            foreach ($prop in $wf.PSObject.Properties) {
                $comp = $prop.Value
                if (-not $comp.StartTime -or -not $comp.EndTime -or $comp.StartTime -eq '' -or $comp.EndTime -eq '') { continue }
                try {
                    $cStart = [datetime]::ParseExact($comp.StartTime, "yyyy-MM-dd HH:mm:ss", $null)
                    $cEnd = [datetime]::ParseExact($comp.EndTime, "yyyy-MM-dd HH:mm:ss", $null)
                    $components[$prop.Name] = @{
                        Elapsed = ($cEnd - $cStart)
                        Status  = $comp.Status
                    }
                }
                catch {
                    # Skip components with unparseable timestamps
                }
            }

            if ($components.Count -gt 0) {
                if (-not $global:BuildStats.ContainsKey('Components')) {
                    $global:BuildStats['Components'] = @{}
                }
                $global:BuildStats.Components[$vm.vmName] = $components
            }
        }
        catch {
            Write-Log "[BuildStats] Could not retrieve timing from $($vm.vmName): $_" -LogOnly
        }
    }
}

function Write-BuildSummary {

    if (-not $global:BuildStats) { return }

    $stats = $global:BuildStats
    $hasPhases = $stats.Phases.Count -gt 0
    $hasVMs = $stats.VMs.Count -gt 0
    $hasComponents = $stats.ContainsKey('Components') -and $stats.Components.Count -gt 0

    if (-not $hasPhases -and -not $hasVMs) { return }

    Write-Host
    Write-Log "============================== Build Summary ==============================" -Activity

    # --- Phase Summary ---
    if ($hasPhases -and $hasVMs) {
        Write-Log ""
        foreach ($phaseNum in $stats.Phases.Keys | Sort-Object) {
            $p = $stats.Phases[$phaseNum]
            $elapsed = if ($p.Elapsed) { $p.Elapsed.ToString("hh\:mm\:ss") } else { "N/A" }

            # Find the slowest VM in this phase
            $slowestName = $null
            $slowestTicks = [long]0
            foreach ($vmName in $stats.VMs.Keys) {
                $vmData = $stats.VMs[$vmName]
                if ($vmData.Phases.ContainsKey($phaseNum)) {
                    $pe = $vmData.Phases[$phaseNum]
                    $t = if ($pe.Elapsed) { $pe.Elapsed.Ticks } else { 0 }
                    if ($t -gt $slowestTicks) {
                        $slowestTicks = $t
                        $slowestName = $vmName
                        $slowestRole = $vmData.Role
                        $slowestElapsed = $pe.Elapsed
                    }
                }
            }

            $line = "  Phase $phaseNum`: $elapsed ($($p.VMCount) VMs)"
            if ($p.Failed -gt 0) { $line += ", $($p.Failed) failed" }
            if ($p.Warning -gt 0) { $line += ", $($p.Warning) warnings" }
            if ($slowestName -and $p.VMCount -gt 1) {
                $line += " - slowest: $slowestName [$slowestRole] $($slowestElapsed.ToString("hh\:mm\:ss"))"
            }
            Write-Log $line
        }
    }

    # --- Overall Slowest VM ---
    if ($hasVMs) {
        # Calculate total time per VM across all phases
        $vmTotals = @()
        foreach ($vmName in $stats.VMs.Keys) {
            $vmData = $stats.VMs[$vmName]
            $totalTicks = [long]0
            foreach ($phaseNum in $vmData.Phases.Keys) {
                $phaseEntry = $vmData.Phases[$phaseNum]
                if ($phaseEntry.Elapsed) { $totalTicks += $phaseEntry.Elapsed.Ticks }
            }
            $vmTotals += [PSCustomObject]@{
                Name       = $vmName
                Role       = $vmData.Role
                TotalTicks = $totalTicks
                Total      = [TimeSpan]::FromTicks($totalTicks)
            }
        }
        $vmTotals = $vmTotals | Sort-Object -Property TotalTicks -Descending

        if ($vmTotals.Count -gt 1) {
            $slowest = $vmTotals[0]
            Write-Log ""
            Write-Log "  Slowest VM overall: $($slowest.Name) [$($slowest.Role)] - $($slowest.Total.ToString("hh\:mm\:ss"))"
        }
    }

    # --- Slowest Component ---
    if ($hasComponents) {
        $globalSlowest = $null
        $globalSlowestTicks = [long]0
        foreach ($vmName in $stats.Components.Keys) {
            foreach ($entry in $stats.Components[$vmName].GetEnumerator()) {
                if ($entry.Value.Elapsed -and $entry.Value.Elapsed.Ticks -gt $globalSlowestTicks) {
                    $globalSlowestTicks = $entry.Value.Elapsed.Ticks
                    $globalSlowest = @{ VM = $vmName; Component = $entry.Key; Elapsed = $entry.Value.Elapsed }
                }
            }
        }
        if ($globalSlowest) {
            Write-Log "  Slowest component:  $($globalSlowest.Component) on $($globalSlowest.VM) - $($globalSlowest.Elapsed.ToString("hh\:mm\:ss"))"
        }
    }

    Write-Log ""
    Write-Log "===========================================================================" -Activity
    Write-Host
}

function Save-BuildStats {
    param (
        [string]$Configuration,
        [TimeSpan]$TotalElapsed,
        [bool]$Success
    )

    if (-not $global:BuildStats) { return }
    if (-not $Configuration) { return }

    $stats = $global:BuildStats

    try {
        # Build the stats directory under logs\stats
        $logsPath = Split-Path $Common.LogPath -Parent
        $statsDir = Join-Path $logsPath "stats"
        if (-not (Test-Path $statsDir)) {
            $null = New-Item -ItemType Directory -Path $statsDir -Force
        }

        # Gather metadata
        $configShort = Split-Path $Configuration -LeafBase
        $branch = try { Get-BranchName } catch { "unknown" }
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

        # Convert phase timing to serializable form
        $phasesOut = @{}
        foreach ($phaseNum in $stats.Phases.Keys) {
            $p = $stats.Phases[$phaseNum]
            $phasesOut["$phaseNum"] = @{
                ElapsedSeconds = if ($p.Elapsed) { [Math]::Round($p.Elapsed.TotalSeconds, 1) } else { $null }
                VMCount        = $p.VMCount
                Success        = $p.Success
                Warning        = $p.Warning
                Failed         = $p.Failed
            }
        }

        # Convert VM timing to serializable form
        $vmsOut = @{}
        foreach ($vmName in $stats.VMs.Keys) {
            $vmData = $stats.VMs[$vmName]
            $vmPhases = @{}
            $totalSeconds = [double]0
            foreach ($pNum in $vmData.Phases.Keys) {
                $pe = $vmData.Phases[$pNum]
                $elSec = if ($pe.Elapsed) { [Math]::Round($pe.Elapsed.TotalSeconds, 1) } else { 0 }
                $totalSeconds += $elSec
                $vmPhases["$pNum"] = @{
                    ElapsedSeconds = $elSec
                    Failed         = [bool]$pe.Failed
                }
            }
            $vmsOut[$vmName] = @{
                Role           = $vmData.Role
                TotalSeconds   = [Math]::Round($totalSeconds, 1)
                Phases         = $vmPhases
            }
        }

        # Convert component timing to serializable form
        $compsOut = @{}
        if ($stats.ContainsKey('Components') -and $stats.Components.Count -gt 0) {
            foreach ($vmName in $stats.Components.Keys) {
                $comps = $stats.Components[$vmName]
                $vmComps = @{}
                foreach ($compName in $comps.Keys) {
                    $c = $comps[$compName]
                    $vmComps[$compName] = @{
                        ElapsedSeconds = if ($c.Elapsed) { [Math]::Round($c.Elapsed.TotalSeconds, 1) } else { $null }
                        Status         = $c.Status
                    }
                }
                $compsOut[$vmName] = $vmComps
            }
        }

        $statsObj = [ordered]@{
            Timestamp       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Configuration   = $configShort
            MemLabsVersion  = $Common.MemLabsVersion
            Branch          = $branch
            Success         = $Success
            TotalElapsed    = if ($TotalElapsed) { $TotalElapsed.ToString("hh\:mm\:ss") } else { $null }
            TotalSeconds    = if ($TotalElapsed) { [Math]::Round($TotalElapsed.TotalSeconds, 1) } else { $null }
            HostName        = $env:COMPUTERNAME
            Phases          = $phasesOut
            VMs             = $vmsOut
            Components      = $compsOut
        }

        $fileName = "${configShort}_${timestamp}.json"
        $filePath = Join-Path $statsDir $fileName
        $statsObj | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding utf8 -Force
        Write-Log "Build stats saved to: $filePath" -LogOnly
    }
    catch {
        Write-Log "[BuildStats] Failed to save stats: $_" -LogOnly
    }
}