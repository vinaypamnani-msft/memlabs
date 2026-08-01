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

# A Start-Job whose scriptblock RAN TO COMPLETION (emitting its terminal
# "VM Creation completed successfully" / "...Preparation completed successfully"
# line) can still end up State=Failed when the runspace/transport Close that
# happens AFTER the scriptblock returns times out. The usual trigger: an
# Invoke-VmCommand -AsJob step inside the scriptblock timed out under
# concurrent-boot load and was abandoned via StopJobAsync (Common.ps1) -- the
# abandoned PSDirect pipeline never acknowledges cancellation, so closing the
# parent runspace hits its 60s CancelTimeout and surfaces a
# PSRemotingTransportException (ErrorCode 2106: "The client did not receive a
# response for a Close operation in the specified time interval. This can happen
# when a command is not responding to a Stop message in a timely manner.").
# The VM was actually created fine -- only the teardown failed. Detect that exact
# shape so Wait-Phase scores the job by its own output instead of as a spurious
# phase failure. Conservative by design: requires BOTH the transport-close reason
# AND a terminal success sentinel AND the absence of any failure-level (LogLevel 3)
# output, so a genuine scriptblock failure is never misclassified.
function Test-JobTransportCloseFalseFailure {
    param($Job)
    if (-not $Job -or $Job.State -ne "Failed") { return $false }
    $streamSource = Get-JobStreamSource -Job $Job
    if (-not $streamSource) { return $false }

    # 1. The terminating reason must be the remoting transport teardown, not a
    #    genuine scriptblock error.
    $reason = $null
    try { $reason = $streamSource.JobStateInfo.Reason } catch {}
    if (-not $reason) { try { $reason = $Job.JobStateInfo.Reason } catch {} }
    if (-not $reason) { return $false }
    $reasonText = "$($reason.Message)"
    try { $reasonText += " $($reason.GetType().FullName)" } catch {}
    try { if ($reason.ErrorRecord -and $reason.ErrorRecord.Exception) { $reasonText += " $($reason.ErrorRecord.Exception.Message)" } } catch {}
    try { if ($reason.FullyQualifiedErrorId) { $reasonText += " $($reason.FullyQualifiedErrorId)" } } catch {}
    $isTransportClose = $reasonText -match 'Close operation in the specified time interval|not responding to a Stop message|PSRemotingTransportException|PSRemotingDataStructureException'
    if (-not $isTransportClose) { return $false }

    # 2. No failure-level output, AND a terminal VM-create success line present.
    $jobOutput = @($streamSource | Select-Object -ExpandProperty Output -ErrorAction SilentlyContinue)
    if ($jobOutput | Where-Object { $_.LogLevel -eq 3 }) { return $false }
    $hasSuccessSentinel = $jobOutput | Where-Object { $_.LogLevel -eq 1 -and $_.Text -match 'VM Creation completed successfully|Preparation completed successfully' }
    return [bool]$hasSuccessSentinel
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

# Returns the set (case-insensitive) of SQL VM names that must have the SQL
# 'Replication' feature for an MP database replica: every replica SQL host, plus
# the site DB SQL (publisher/distributor) of any site that has a replica MP. Used
# to also mount the SQL ISO on EXISTING (hidden) SQL VMs so Phase 4 can add the
# feature (transactional replication requires it; see Phase4.ps1 EnsureSqlReplication).
function Get-SqlVMNamesNeedingReplication {
    param([object]$deployConfig)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $replicaMPs = @($deployConfig.virtualMachines | Where-Object { $_.role -eq 'SiteSystem' -and $_.installMP -and $_.useDatabaseReplica })
    foreach ($mp in $replicaMPs) {
        if ($mp.replicaSqlServerVM) { [void]$set.Add([string]$mp.replicaSqlServerVM) }
        # Publisher = the site DB SQL for the MP's site (the site server's own SQL, or its remote SQL VM).
        $ss = $deployConfig.virtualMachines | Where-Object { $_.role -in @('Primary', 'CAS') -and $_.siteCode -eq $mp.siteCode } | Select-Object -First 1
        if ($ss) {
            if ($ss.sqlVersion) { [void]$set.Add([string]$ss.vmName) }
            elseif ($ss.remoteSQLVM) { [void]$set.Add([string]$ss.remoteSQLVM) }
        }
    }
    # Return with the unary comma so PowerShell does NOT unroll the HashSet into
    # the pipeline. Plain 'return $set' enumerates it: an empty set yields $null
    # and a single-element set yields a bare string, so callers' $replNeeded.Contains()
    # then threw "You cannot call a method on a null-valued expression."
    return , $set
}

function Mount-SqlIsoForPhase {
    param([object]$deployConfig)

    # New SQL installs (non-hidden) always need the media. ALSO mount for existing
    # (hidden) SQL VMs that must gain the 'Replication' feature for an MP replica.
    $replNeeded = Get-SqlVMNamesNeedingReplication -deployConfig $deployConfig
    $sqlVMs = $deployConfig.virtualMachines | Where-Object { $_.sqlVersion -and (-not $_.hidden -or $replNeeded.Contains([string]$_.vmName)) }
    foreach ($vm in $sqlVMs) {
        $sqlIsoPath = Get-SqlIsoPathForVm -VirtualMachine $vm
        if (-not $sqlIsoPath) {
            Write-Log "[Phase 4]: $($vm.vmName): Could not resolve SQL ISO path for '$($vm.sqlVersion)'; skipping mount." -Warning
            continue
        }
        # Idempotent, per-drive, multi-drive-safe (see Mount-IsoOnVm): a re-run is a
        # no-op, and it never evicts another disc that may be co-mounted. The guest
        # picks the SQL disc by content (Phase4 AssignSqlIsoDriveLetter -> S:).
        # -RepresentIfAttached: if a prior (killed) run left the SQL ISO inserted
        # across the guest's reboot, re-present it so the guest raises a fresh
        # media-arrival event and the Phase 4 DSC can see the disc.
        if (-not (Mount-IsoOnVm -VmName $vm.vmName -IsoPath $sqlIsoPath -Context "SQL" -Phase 4 -RepresentIfAttached)) {
            Write-Log "[Phase 4]: $($vm.vmName): Failed mounting SQL ISO $sqlIsoPath as a DVD drive" -Failure -OutputStream
            continue
        }

        # POSTCONDITION: confirm the GUEST actually enumerates the SQL disc, on a
        # fresh PSDirect session (Mount-IsoOnVm already evicted the stale one). This
        # front-loads visibility to the host -- where we hold the fresh-session lever
        # -- so the disc is proven present BEFORE Phase 4 DSC runs, instead of relying
        # solely on the in-guest AssignSqlIsoDriveLetter to re-find it. On a miss, one
        # clean DVD reset un-wedges a two-disc Gen2 enumeration; a persistent miss is
        # left to the in-guest helper (which polls + re-enumerates for 2 min). Never
        # fatal here -- a false host-side miss must not fail the mount.
        $sqlDomainName = if ($vm.Domain) { $vm.Domain } else { $deployConfig.vmOptions.domainName }
        if (-not (Confirm-IsoVisibleInGuest -VmName $vm.vmName -VmDomainName $sqlDomainName -MarkerRelativePath 'setup.exe' -Context 'SQL' -Phase 4 -TimeoutSeconds 90)) {
            Write-Log "[Phase 4]: $($vm.vmName): SQL media not yet visible in guest after mount; clean DVD reset + recheck." -Warning
            $null = Reset-AllDvdDrivesOnVm -VmName $vm.vmName -RequiredIsoPath $sqlIsoPath -Context "SQL" -Phase 4
            $null = Confirm-IsoVisibleInGuest -VmName $vm.vmName -VmDomainName $sqlDomainName -MarkerRelativePath 'setup.exe' -Context 'SQL' -Phase 4 -TimeoutSeconds 60
        }
    }
}

# Ejects the SQL ISO from every SQL VM in the config. Called after a SUCCESSFUL
# Phase 4 so nothing is mounted at rest (avoids baking a host ISO path into
# checkpoints / .memlabs exports). On a failed Phase 4 the ISO is deliberately
# left mounted for debugging. Per-ISO eject (Dismount-IsoFromVm) so a co-mounted
# cache / CM disc is left untouched.
function Dismount-SqlIsoForPhase {
    param([object]$deployConfig)

    $replNeeded = Get-SqlVMNamesNeedingReplication -deployConfig $deployConfig
    $sqlVMs = $deployConfig.virtualMachines | Where-Object { $_.sqlVersion -and (-not $_.hidden -or $replNeeded.Contains([string]$_.vmName)) }
    foreach ($vm in $sqlVMs) {
        $sqlIsoPath = Get-SqlIsoPathForVm -VirtualMachine $vm
        if ($sqlIsoPath) {
            Dismount-IsoFromVm -VmName $vm.vmName -IsoPath $sqlIsoPath -Context "SQL" -Phase 4
        }
    }
}

# ---------------------------------------------------------------------------
# ConfigMgr media (ISO) mount-on-demand.
#
# When the selected CM version is an ISO (cmDownloadVersion.filename ends .iso),
# we no longer copy ~800MB of media to C:\CMCB at VM-create time. Instead we
# mount the CM ISO on the site server's DVD drive on-demand right before the
# phase that needs it (Phase 8 install; Phase 9 secondary/passive add; Phase 2
# cross-forest schema extension), install directly from the DVD, and eject
# after the phase succeeds.
#
# All mounts/ejects go through Mount-IsoOnVm / Dismount-IsoFromVm, which are
# idempotent, drive-specific (keyed by ISO path), and multi-drive-safe: the CM
# ISO gets its own DVD drive and can coexist with a SQL / cache disc on the same
# VM. The guest reads the CM disc by content (SMSSETUP\BIN\X64\Setup.exe), never
# by "the CD-ROM", so co-mounted discs don't confuse it.
#
# The CMCB SMB share (read by the schema-extension resources over SMB as
# \\<server>\CMCB\SMSSETUP\BIN\X64\extadsch.exe) is pointed at the CM DVD drive.
# REdist stays a LOCAL writable folder C:\<CM>\REdist (setupdl writes there);
# the share NAME "CMCB" and the local folder path are independent objects.
#
# URL-download CM versions (cmDownloadVersion.downloadUrl) are unaffected: they
# keep the old method (DownloadSCCM extracts to C:\CMCB, DSC FileReadAccessShare
# shares C:\CMCB). Get-CmIsoPathForVersion returns $null for those, so nothing
# below mounts anything and every function no-ops.
# ---------------------------------------------------------------------------

# Host path to the CM ISO for a CM version, or $null when the version is a
# URL-download (no ISO in the file list).
function Get-CmIsoPathForVersion {
    param([string]$CmVersion)
    if (-not $CmVersion) { return $null }
    $azureFileList = if ($Common) { $Common.AzureFileList } else { $null }
    if (-not $azureFileList) { return $null }
    $cmFiles = @($azureFileList.CMVersions | Where-Object { $_.versions -contains $CmVersion })
    $cmIso = $cmFiles.filename | Where-Object { $_ -and $_.ToLowerInvariant().EndsWith(".iso") } | Select-Object -First 1
    if (-not $cmIso) { return $null }
    return (Join-Path $Common.AzureFilesPath $cmIso)
}

# CM share name: CMTP for tech-preview, CMCB otherwise (matches Phase8/9 $CM).
function Get-CmShareName {
    param([object]$Vm, [object]$deployConfig)
    $cmVer = if ($Vm.cmOptions -and $Vm.cmOptions.version) { $Vm.cmOptions.version } else { $deployConfig.cmOptions.version }
    if ($cmVer -eq "tech-preview") { return "CMTP" }
    return "CMCB"
}

# Top-level site servers (CAS / standalone or top-level Primary; no
# ParentSiteServer) that install CM from LOCAL media and expose the CMCB share.
# Child Primaries / Secondaries install from the parent's CM-owned
# SMS_<sitecode>\cd.latest share, so they are excluded. Returns objects carrying
# the VM, resolved ISO path, and share name; ISO-only (URL versions skipped).
function Get-CmMediaSiteServers {
    param([object]$deployConfig, [switch]$IncludeHidden)
    $list = @()
    foreach ($vm in $deployConfig.virtualMachines) {
        if ($vm.role -notin @('CAS', 'Primary')) { continue }
        if ($vm.thisParams -and $vm.thisParams.ParentSiteServer) { continue }
        if ($vm.hidden -and -not $IncludeHidden) { continue }
        $cmVer = if ($vm.cmOptions -and $vm.cmOptions.version) { $vm.cmOptions.version } else { $deployConfig.cmOptions.version }
        $isoPath = Get-CmIsoPathForVersion -CmVersion $cmVer
        if (-not $isoPath) { continue }
        $list += [pscustomobject]@{ Vm = $vm; IsoPath = $isoPath; ShareName = (Get-CmShareName -Vm $vm -deployConfig $deployConfig) }
    }
    return $list
}

# External top-level site servers referenced by cross-forest joiners
# (thisParams.ExternalTopLevelSiteServer). A different domain's DC reads their
# CMCB share during its Phase 2 schema extension, so their media must be mounted
# before Phase 2. Resolvable from the (multi-domain / add-run) deployConfig.
function Get-CmExternalSchemaServers {
    param([object]$deployConfig)
    $list = @()
    $seen = @{}
    foreach ($vm in $deployConfig.virtualMachines) {
        $ext = if ($vm.thisParams) { $vm.thisParams.ExternalTopLevelSiteServer } else { $null }
        if (-not $ext) { continue }
        $extName = ($ext -split '\.')[0]
        if ($seen.ContainsKey($extName)) { continue }
        $seen[$extName] = $true
        $extVm = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $extName } | Select-Object -First 1
        if ($extVm) {
            $cmVer = if ($extVm.cmOptions -and $extVm.cmOptions.version) { $extVm.cmOptions.version } else { $deployConfig.cmOptions.version }
            $isoPath = Get-CmIsoPathForVersion -CmVersion $cmVer
            if (-not $isoPath) { continue }
            $list += [pscustomobject]@{ Vm = $extVm; IsoPath = $isoPath; ShareName = (Get-CmShareName -Vm $extVm -deployConfig $deployConfig) }
            continue
        }

        # Not in this deployConfig: the cross-forest joiner (e.g. cstest8b) was
        # deployed as a SEPARATE lab from the external CAS (e.g. cstest8's
        # CST-CASSITE). An ISO-based CM ejects its media after its OWN Phase 8, so
        # that CAS's CMCB share now points at an empty ejected DVD -- the joiner's
        # Phase 2 schema-extend then waits forever for extadsch.exe. Resolve the
        # external CAS host-wide from persisted VM notes and re-mount its CM ISO +
        # CMCB share for the duration of this Phase 2.
        $hostVm = $null
        try { $hostVm = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $extName } | Select-Object -First 1 }
        catch { $hostVm = $null }
        if (-not $hostVm) {
            Write-Log "[Phase 2]: External schema server '$extName' (referenced by cross-forest joiner) not found on this host; its CMCB share must already exist for schema extension to succeed." -Warning
            continue
        }
        $cmVer = if ($hostVm.cmOptions -and $hostVm.cmOptions.version) { $hostVm.cmOptions.version } else { $null }
        $isoPath = Get-CmIsoPathForVersion -CmVersion $cmVer
        if (-not $isoPath) {
            # URL-download CM -> persistent C:\CMCB share on the CAS; nothing to re-mount.
            Write-Log "[Phase 2]: External schema server '$extName' uses URL-download CM (persistent CMCB share); no ISO re-mount needed." -LogOnly
            continue
        }
        $shareName = if ($cmVer -eq "tech-preview") { "CMTP" } else { "CMCB" }
        Write-Log "[Phase 2]: External schema server '$extName' resolved host-wide (domain '$($hostVm.domain)', CM '$cmVer'); will re-mount CM ISO + '$shareName' share." -LogOnly
        $list += [pscustomobject]@{ Vm = $hostVm; IsoPath = $isoPath; ShareName = $shareName }
    }
    return $list
}

# Mount the CM ISO on one site server's single DVD (idempotent) and (re)create
# the CMCB SMB share pointing at that DVD + ensure the writable REdist folder.
function Set-CmMediaMountAndShare {
    param([object]$Target, [object]$deployConfig, [int]$Phase)
    $vm = $Target.Vm
    $vmName = $vm.vmName
    $isoPath = $Target.IsoPath
    $shareName = $Target.ShareName
    $domain = if ($vm.Domain) { $vm.Domain } else { $deployConfig.vmOptions.domainName }

    # ---- Guest probe: locate the CM media DVD, returning structured diagnostics.
    # This is the "signal back to the host": a short, self-contained in-guest check
    # that (a) assigns a drive letter to any letterless optical volume, (b) nudges
    # a device rescan, (c) looks for a CD-ROM carrying the CM media, and (d) ALWAYS
    # returns the guest's optical inventory so the host can diagnose a miss and
    # decide whether to repair (re-present the disc) and retry.
    $probeScript = {
        param($ProbeSeconds)
        $diag = [System.Collections.Generic.List[string]]::new()
        $deadline = (Get-Date).AddSeconds([int]$ProbeSeconds)
        $cd = $null
        while (-not $cd -and (Get-Date) -lt $deadline) {
            # Give any letterless CD-ROM volume a drive letter so the content probe
            # can see it (diskpart/pnputil rescans never letter optical media).
            try {
                $letterless = @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue | Where-Object { -not $_.DriveLetter })
                if ($letterless.Count -gt 0) {
                    $free = @()
                    foreach ($n in 70..90) { $l = [char]$n; if (-not (Test-Path "${l}:\")) { $free += $l } }
                    $i = 0
                    foreach ($vol in $letterless) {
                        if ($i -ge $free.Count) { break }
                        Set-CimInstance -InputObject $vol -Property @{ DriveLetter = "$($free[$i]):" } -ErrorAction SilentlyContinue
                        $i++
                    }
                }
            }
            catch { }
            # STRONGEST signal first: if CM Setup / Setupdl is already executing
            # from the media, its open image handle proves the disc is present and
            # names the drive. This survives the Gen2 optical-enumeration flakiness
            # that hides a busy disc from Get-Volume / Win32_CDROMDrive / a bare
            # drive-letter Test-Path scan (observed: setup was running from F:\ for
            # 26s while Win32_CDROMDrive enumerated only the idle cache disc D:).
            # A running process's ExecutablePath cannot be an enumeration phantom.
            $cd = $null
            try {
                $sp = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='setupdl.exe' OR Name='setup.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.ExecutablePath -match '(?i)^[A-Za-z]:\\SMSSETUP\\BIN\\X64\\setup(dl)?\.exe$' }) |
                    Select-Object -First 1
                if ($sp -and $sp.ExecutablePath) {
                    $cd = $sp.ExecutablePath.Substring(0, 2)  # e.g. 'F:'
                    $diag.Add("CM Setup already running from ${cd} ($($sp.Name)); media present (process handle).")
                }
            }
            catch { }
            # Fallback: scan EVERY drive letter (C..Z) for the setup binary, NOT by
            # filtering Get-Volume on DriveType -eq 'CD-ROM'. The DriveType filter
            # proved unreliable: when the disc is busy (the site's own setup reads
            # it concurrently) or enumerated in a different session, Get-Volume can
            # omit the very CD-ROM the guest is actively using. A direct Test-Path
            # on each letter finds the media wherever it landed, regardless of
            # volume-type classification.
            if (-not $cd) {
                foreach ($n in 67..90) {
                    $dl = [char]$n
                    if (Test-Path ("${dl}:\SMSSETUP\BIN\X64\Setup.exe")) { $cd = "${dl}:"; break }
                }
            }
            if (-not $cd) {
                try { & pnputil.exe /scan-devices *>$null } catch { }
                try { "rescan" | & diskpart.exe *>$null } catch { }
                Start-Sleep -Seconds 5
            }
        }
        # Always snapshot the guest's optical + drive-scan state for the host log.
        try {
            # PID identifies the wsmprovhost backing THIS PSDirect session. When the
            # host evicts the cached session before each probe, a fresh session ->
            # a new PID here; a stale reused runspace keeps the same PID. So a
            # changing PID across attempts confirms the probe is genuinely running
            # on a fresh session (the fix), and a device count that jumps when the
            # PID changes is the smoking gun for a cached-session stale device view.
            $diag.Add("probe session PID=$PID")
            $cdVols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'CD-ROM' })
            if ($cdVols.Count -eq 0) { $diag.Add("guest sees NO CD-ROM volumes") }
            foreach ($v in $cdVols) {
                $lbl = if ($v.DriveLetter) { "$($v.DriveLetter):" } else { "(no letter)" }
                $hasCm = $false
                if ($v.DriveLetter) { $hasCm = Test-Path ("$($v.DriveLetter):\SMSSETUP\BIN\X64\Setup.exe") }
                $diag.Add("CD-ROM $lbl size=$([math]::Round(($v.Size / 1MB)))MB cmMedia=$hasCm")
            }
            # Also report which lettered drives (any type) carry the CM setup, since
            # the media can surface on a letter Get-Volume doesn't call 'CD-ROM'.
            $cmLetters = @()
            foreach ($n in 67..90) { $dl = [char]$n; if (Test-Path ("${dl}:\SMSSETUP\BIN\X64\Setup.exe")) { $cmLetters += "${dl}:" } }
            $diag.Add("Drives with CM setup (any type): $(if ($cmLetters.Count) { $cmLetters -join ', ' } else { '<none>' })")
            $drv = @(Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction SilentlyContinue)
            $diag.Add("Win32_CDROMDrive=$($drv.Count): " + (($drv | ForEach-Object { "$($_.Drive)|MediaLoaded=$($_.MediaLoaded)" }) -join '; '))
            # Cross-check the CIM count with the legacy WMI provider and .NET
            # DriveInfo. All three read the SAME global device layer, so if they
            # disagree the session's view is split/stale rather than the media
            # being absent -- the decisive signal that separates a detection bug
            # from a genuine "no disc" case.
            try {
                $wmi = @(Get-WmiObject -Class Win32_CDROMDrive -ErrorAction SilentlyContinue)
                $diag.Add("Win32_CDROMDrive(WMI)=$($wmi.Count): " + (($wmi | ForEach-Object { "$($_.Drive)|MediaLoaded=$($_.MediaLoaded)|Vol='$($_.VolumeName)'" }) -join '; '))
            }
            catch { $diag.Add("Win32_CDROMDrive(WMI) query failed: $($_.Exception.Message)") }
            try {
                $di = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'CDRom' })
                $diag.Add("DriveInfo CDRom=$($di.Count): " + (($di | ForEach-Object { "$($_.Name)|Ready=$($_.IsReady)|Label='$(if ($_.IsReady) { $_.VolumeLabel } else { '' })'" }) -join '; '))
            }
            catch { $diag.Add("DriveInfo query failed: $($_.Exception.Message)") }
            # Report any running CM Setup and where it's reading from -- the
            # authoritative 'media is present' signal when enumeration is flaky.
            $spAll = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='setupdl.exe' OR Name='setup.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath })
            $diag.Add("CM Setup processes: $(if ($spAll.Count) { ($spAll | ForEach-Object { "$($_.Name)@$($_.ExecutablePath)" }) -join '; ' } else { '<none>' })")
        }
        catch { $diag.Add("diag error: $($_.Exception.Message)") }
        return @{ Found = [bool]$cd; Root = $(if ($cd) { "$cd\" } else { $null }); Diag = $diag }
    }

    # Lightweight, churn-free check: is CM Setup already reading the media? A
    # running setupdl.exe/setup.exe whose image lives on \SMSSETUP\BIN\X64 proves
    # the disc is present and names its drive -- an open image handle can't be an
    # enumeration phantom. Used to AVOID yanking the DVD out from under a live
    # install (a reset/reboot mid-setup would corrupt it).
    $setupRunningScript = {
        $sp = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='setupdl.exe' OR Name='setup.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ExecutablePath -match '(?i)^[A-Za-z]:\\SMSSETUP\\BIN\\X64\\setup(dl)?\.exe$' }) |
            Select-Object -First 1
        if ($sp -and $sp.ExecutablePath) { return @{ Running = $true; Root = $sp.ExecutablePath.Substring(0, 3) } }
        return @{ Running = $false; Root = $null }
    }

    # ---- Host-driven diagnose -> repair loop, BUDGETED to the DC's tolerance.
    # The DC's WaitForExtendSchemaFile polls the CMCB share for extadsch.exe for up
    # to 30 minutes before it throws, so giving up after a few quick tries here just
    # deadlocks the DC waiting on a share we stopped trying to create. Instead we
    # keep re-presenting/probing for nearly that whole window as long as there is
    # ANY chance the disc is present (the host ISO still exists), and only declare
    # failure when that budget is exhausted.
    #
    # Escalation stays gentle, spaced out, and NEVER churns the DVD while CM Setup
    # is reading it (a reset/reboot mid-install would corrupt setup):
    #   - every loop: a cheap, churn-free guest probe. It also detects a running
    #     Setup (proof-positive the media is present, and it names the drive).
    #   - a clean DVD reset (remove all + re-add discs fresh at low locations --
    #     de-churns, un-wedges Gen2 optical enumeration) at most ~every 4 min.
    #   - a reboot from the clean topology (a disc present at boot is always
    #     enumerated) at most ~every 10 min, capped at 2, and only when Setup is
    #     NOT running -- re-checked immediately before the reboot.
    $mediaRoot = $null
    $loopStart = Get-Date
    $mediaDeadline = $loopStart.AddMinutes(28)
    $attempt = 0
    $lastResetAt = [DateTime]::MinValue
    $lastRebootAt = [DateTime]::MinValue
    $rebootCount = 0
    while (-not $mediaRoot -and (Get-Date) -lt $mediaDeadline) {
        $attempt++
        $minsLeft = [int]((($mediaDeadline) - (Get-Date)).TotalMinutes)

        # There's no chance to present anything if the host ISO itself is gone.
        # Treat as a transient host blip and re-check rather than failing outright.
        if (-not (Test-Path $isoPath)) {
            Write-Log "[Phase $Phase]: $($vmName): CM ISO path missing on host: $isoPath [attempt $attempt, ~$minsLeft min left]; re-checking." -Warning
            Start-Sleep -Seconds 15
            continue
        }

        # Idempotently ensure the ISO is attached at the hypervisor (no churn).
        $attached = $false
        try { $attached = [bool](@(Get-VMDvdDrive -VMName $vmName -ErrorAction SilentlyContinue) | Where-Object { $_.Path -eq $isoPath }) } catch { }
        if (-not $attached) {
            $null = Mount-IsoOnVm -VmName $vmName -IsoPath $isoPath -Context "CM" -Phase $Phase
            try { $attached = [bool](@(Get-VMDvdDrive -VMName $vmName -ErrorAction SilentlyContinue) | Where-Object { $_.Path -eq $isoPath }) } catch { $attached = $false }
        }

        # DETECTION FIX + DIAG: run the media probe on a FRESH PSDirect session.
        # Get-VmSession hands Invoke-VmCommand a LONG-LIVED cached session (one per
        # VM, reused for the whole build). A cached runspace created BEFORE the CM
        # disc was attached can hold a STALE optical / DOS-device view: the disc
        # that arrived after the session started is invisible to it, even though
        # every FRESH session sees it at D: -- the guest's own CM Setup, an
        # interactive logon, and a standalone Invoke-Command all read the media
        # fine while only this reused probe session reported "CD-ROM D: 700MB
        # cmMedia=False, Win32_CDROMDrive=1" (the cache disc) for 28 min straight.
        # This is the same cached-vs-fresh split as the PKI Step 2 token race.
        # Evicting the cached session forces the next Invoke-VmCommand to build a
        # fresh, validated session that sees current media. It's cheap (~1-2s
        # rebuild vs the loop's 15s+ cadence) and turns a 28-min churn-and-fail
        # into an instant hit when the media is genuinely present. The probe is
        # synchronous with no in-flight job bound to the session, so disposing it
        # here is safe.
        Remove-VmSessionFromCache -VmName $vmName

        # Churn-free guest probe: detects a running CM Setup (proof of media) or the
        # setup binary on any drive letter, and returns the guest's optical diag.
        $probe = Invoke-VmCommand -VmName $vmName -VmDomainName $domain -ScriptBlock $probeScript -ArgumentList @(60) -SuppressLog -DisplayName "Locate CM media ($attempt)"
        $out = $probe.ScriptBlockOutput
        if ($out -is [hashtable] -and $out.Found) {
            $mediaRoot = [string]$out.Root
            Write-Log "[Phase $Phase]: $($vmName): CM media visible at $mediaRoot [attempt $attempt]." -LogOnly
            break
        }
        # Signal back to host: log the guest's optical inventory so a miss is diagnosable.
        if ($out -is [hashtable] -and $out.Diag) {
            foreach ($d in $out.Diag) { Write-Log "[Phase $Phase]: $($vmName): [CM media diag] $d" -LogOnly }
        }
        elseif ($probe.ScriptBlockFailed) {
            Write-Log "[Phase $Phase]: $($vmName): CM media probe errored [attempt $attempt]: $($probe.ScriptBlockOutput)" -Warning
        }

        # FINAL guard before any disruptive repair: re-confirm Setup did not start
        # during the probe. If it did, the media is present -- use it and never
        # churn the disc out from under the running install.
        $sr = Invoke-VmCommand -VmName $vmName -VmDomainName $domain -ScriptBlock $setupRunningScript -SuppressLog -DisplayName "Recheck CM setup ($attempt)"
        if ($sr.ScriptBlockOutput -is [hashtable] -and $sr.ScriptBlockOutput.Running) {
            $mediaRoot = [string]$sr.ScriptBlockOutput.Root
            Write-Log "[Phase $Phase]: $($vmName): CM Setup now running from $mediaRoot; using it as the media root (no DVD churn)." -LogOnly
            break
        }

        # Not visible yet, and Setup isn't reading it -> safe to escalate. Space the
        # disruptive repairs out so we don't churn the optical stack every loop.
        $now = Get-Date
        $elapsedMin = ($now - $loopStart).TotalMinutes
        if ($elapsedMin -ge 8 -and ($now - $lastRebootAt).TotalMinutes -ge 10 -and $rebootCount -lt 2) {
            Write-Log "[Phase $Phase]: $($vmName): CM media still not visible after clean resets; rebooting from the clean topology so the attached disc enumerates at boot [reboot $($rebootCount + 1)/2, ~$minsLeft min left]." -Warning
            $null = Reset-AllDvdDrivesOnVm -VmName $vmName -RequiredIsoPath $isoPath -Context "CM" -Phase $Phase
            try {
                Restart-VM -Name $vmName -Force -ErrorAction Stop
            }
            catch {
                Write-Log "[Phase $Phase]: $($vmName): graceful Restart-VM failed ($($_.Exception.Message)); hard power-cycling." -Warning
                try { Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue } catch { }
                Start-Sleep -Seconds 5
                try { Start-VM -Name $vmName -ErrorAction SilentlyContinue } catch { }
            }
            # Wait for the guest to come back before probing (a path that always
            # exists once Windows is up).
            $null = Wait-ForVm -VmName $vmName -VmDomainName $domain -PathToVerify "C:\Windows\System32\cmd.exe" -TimeoutMinutes 10 -Quiet
            $lastRebootAt = Get-Date
            $rebootCount++
        }
        elseif (($now - $lastResetAt).TotalMinutes -ge 4) {
            Write-Log "[Phase $Phase]: $($vmName): CM media not visible [attempt $attempt, ~$minsLeft min left]; clean DVD reset to un-wedge guest enumeration." -Warning
            $null = Reset-AllDvdDrivesOnVm -VmName $vmName -RequiredIsoPath $isoPath -Context "CM" -Phase $Phase
            $lastResetAt = $now
        }
        else {
            Start-Sleep -Seconds 15
        }
    }

    if (-not $mediaRoot) {
        $waited = [int](((Get-Date) - $loopStart).TotalMinutes)
        Write-RedX "[Phase $Phase]: $($vmName): CM media DVD never became visible in the guest after $attempt attempts over ~$waited min (clean DVD resets and guest reboots); the CMCB share (DC schema extension depends on it) cannot be created." -WriteLog -ForegroundColor Red
        return
    }

    # ---- Create the CMCB share off the resolved media root. Preferred: share the
    # CM DVD directly (zero-copy) so the schema extension reads
    # \\<server>\CMCB\SMSSETUP\BIN\X64\extadsch.exe off the media. If a host won't
    # share a read-only optical volume, fall back to staging just extadsch.exe (a
    # few MB) into a local folder and sharing that. Setup.exe installs directly
    # from the DVD either way; setupdl writes REdist locally to C:\<CM>\REdist.
    $shareScript = {
        param($ShareName, $Root)
        New-Item -Path "C:\$ShareName\REdist" -ItemType Directory -Force | Out-Null
        try {
            $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
            if ($share -and $share.Path -ne $Root) {
                Remove-SmbShare -Name $ShareName -Force -ErrorAction SilentlyContinue
                $share = $null
            }
            if (-not $share) {
                New-SmbShare -Name $ShareName -Path $Root -ReadAccess "Everyone" -ErrorAction Stop | Out-Null
            }
            return "OK: $ShareName -> $Root"
        }
        catch {
            $localRoot = "C:\$ShareName"
            $localBin = Join-Path $localRoot "SMSSETUP\BIN\X64"
            New-Item -Path $localBin -ItemType Directory -Force | Out-Null
            Copy-Item -Path (Join-Path $Root "SMSSETUP\BIN\X64\extadsch.exe") -Destination $localBin -Force -ErrorAction SilentlyContinue
            $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
            if ($share -and $share.Path -ne $localRoot) {
                Remove-SmbShare -Name $ShareName -Force -ErrorAction SilentlyContinue
                $share = $null
            }
            if (-not $share) {
                New-SmbShare -Name $ShareName -Path $localRoot -ReadAccess "Everyone" -ErrorAction Stop | Out-Null
            }
            return "OK(local extadsch fallback): $ShareName -> $localRoot"
        }
    }
    $res = Invoke-VmCommand -VmName $vmName -VmDomainName $domain -ScriptBlock $shareScript -ArgumentList @($shareName, $mediaRoot) -DisplayName "Share CM media ($shareName)"
    if ($res.ScriptBlockFailed) {
        Write-RedX "[Phase $Phase]: $($vmName): Failed to create CM media share '$shareName' (DC schema extension depends on it). $($res.ScriptBlockOutput)" -WriteLog -ForegroundColor Red
    }
    else {
        Write-Log "[Phase $Phase]: $($vmName): CM media share ready ($($res.ScriptBlockOutput))" -LogOnly
    }
}

# Remove the CMCB share on one site server and eject the CM ISO (leaves any
# SQL / cache / OS ISO on the drive untouched by matching the exact ISO path).
function Clear-CmMediaMount {
    param([object]$Target, [object]$deployConfig, [int]$Phase)
    $vm = $Target.Vm
    $vmName = $vm.vmName
    $isoPath = $Target.IsoPath
    $shareName = $Target.ShareName
    $domain = if ($vm.Domain) { $vm.Domain } else { $deployConfig.vmOptions.domainName }

    $unshare = { param($ShareName) Remove-SmbShare -Name $ShareName -Force -ErrorAction SilentlyContinue; "ok" }
    $null = Invoke-VmCommand -VmName $vmName -VmDomainName $domain -ScriptBlock $unshare -ArgumentList @($shareName) -SuppressLog -DisplayName "Remove CM media share ($shareName)"

    # Per-ISO eject (leaves any co-mounted SQL / cache disc untouched).
    Dismount-IsoFromVm -VmName $vmName -IsoPath $isoPath -Context "CM" -Phase $Phase
}

# Mount CM media for the top-level site servers this phase needs. Hidden top-level
# site servers are INCLUDED: in an add scenario (e.g. AddPS2) the existing CAS/Primary
# is hidden, but a Phase 8 DC still schema-extends against its \\<server>\CMCB share
# (WaitForExtendSchemaFile) and the guest installs off its CM DVD -- excluding it left
# the media unmounted, so the DC hung waiting for extadsch.exe on a share never created.
function Mount-CmIsoForPhase {
    param([object]$deployConfig, [int]$Phase)
    $targets = Get-CmMediaSiteServers -deployConfig $deployConfig -IncludeHidden
    foreach ($t in $targets) { Set-CmMediaMountAndShare -Target $t -deployConfig $deployConfig -Phase $Phase }
}

# Eject CM media from the top-level site servers after a successful phase. Mirrors
# Mount-CmIsoForPhase's target set (IncludeHidden) so a hidden site server's ISO/share
# isn't left mounted and baked into checkpoints / .memlabs exports.
function Dismount-CmIsoForPhase {
    param([object]$deployConfig, [int]$Phase)
    $targets = Get-CmMediaSiteServers -deployConfig $deployConfig -IncludeHidden
    foreach ($t in $targets) { Clear-CmMediaMount -Target $t -deployConfig $deployConfig -Phase $Phase }
}

# Mount CM media on the external top-level site servers referenced by
# cross-forest joiners, so their CMCB share serves extadsch to the joining
# domain's DC during Phase 2. No-op unless a cross-forest join is configured.
function Mount-CmIsoForExternalSchema {
    param([object]$deployConfig)
    foreach ($t in (Get-CmExternalSchemaServers -deployConfig $deployConfig)) {
        Set-CmMediaMountAndShare -Target $t -deployConfig $deployConfig -Phase 2
    }
}

function Dismount-CmIsoForExternalSchema {
    param([object]$deployConfig)
    foreach ($t in (Get-CmExternalSchemaServers -deployConfig $deployConfig)) {
        Clear-CmMediaMount -Target $t -deployConfig $deployConfig -Phase 2
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
        # Scope DNS removal to ONLY the VMs Phase 1 will actually (re)create.
        if ($global:ForcePhase1VmNames -and $global:ForcePhase1VmNames.Count -gt 0) {
            # Phase 1 was forced for specific VMs only (e.g. AADClient cleanup).
            $dnsTargets = @($deployConfig.virtualMachines | Where-Object { $_.vmName -in $global:ForcePhase1VmNames })
            Write-Log "[Phase $Phase] Removing DNS records for re-created VM(s): $($global:ForcePhase1VmNames -join ', ')"
        }
        else {
            # Only VMs that DON'T already exist as Hyper-V VMs get created this
            # run -- Phase 1's job loop skips existing ones via the same
            # $existingVMs check. Removing DNS for VMs we aren't touching
            # de-registers healthy, running machines and forces a needless
            # domain-wide DNS re-registration cycle on every partial re-run.
            $existingVmNameSet = @((Get-List -Type VM -SmartUpdate -DomainName $deployConfig.vmOptions.domainName).vmName)
            $dnsTargets = @($deployConfig.virtualMachines | Where-Object { -not ($_.hidden) -and ($_.vmName -notin $existingVmNameSet) })
            if ($dnsTargets.Count -gt 0) {
                Write-Log "[Phase $Phase] Removing DNS records for VM(s) to be created: $(($dnsTargets.vmName) -join ', ')"
            }
            else {
                Write-Log "[Phase $Phase] No new VMs to create; skipping DNS record removal."
            }
        }
        foreach ($item in $dnsTargets) {
            Remove-DnsRecord -DCName $existingDC -Domain $deployConfig.vmOptions.domainName -RecordToDelete $item.vmName

            # SQLAO: when a node is recreated, also clear the cluster's virtual
            # DNS records -- the Cluster Name A record and the AG listener A
            # record. WSFC and the AG listener register these against the
            # node/listener IPs; left stale from the prior incarnation they
            # resolve the cluster/listener name to a dead address until the
            # rebuilt cluster re-registers (and a stale cluster-name record on
            # the old subnet is exactly the kind of thing that breaks a rebuilt
            # cluster). Only the primary node config carries ClusterName /
            # AlwaysOnListenerName. Remove-DnsRecord no-ops quietly when the
            # record is already gone.
            if ($item.role -eq 'SQLAO') {
                if ($item.ClusterName) {
                    Remove-DnsRecord -DCName $existingDC -Domain $deployConfig.vmOptions.domainName -RecordToDelete $item.ClusterName
                }
                if ($item.AlwaysOnListenerName) {
                    Remove-DnsRecord -DCName $existingDC -Domain $deployConfig.vmOptions.domainName -RecordToDelete $item.AlwaysOnListenerName
                }
            }
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
        # processes that mount and inject VHDs. Re-check immediately before
        # creation because available memory can change after validation; a
        # config that fit earlier can still OOM mid-phase and force a full
        # rollback (seen on
        # wacky.sandwich.lab: ZZ-TURNIP, the 25th VM, failed to start with
        # 0x8007000E at ~93GB committed on a 128GB host). Re-check here against
        # REAL available memory and let the user bail before any VM is created.
        # Default to abort so unattended runs do not proceed into a predictable
        # OOM failure and full Phase 1 rollback.
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
                        $memResp = Read-YesOrNoWithTimeout -timeout 30 -prompt "Continue Phase 1 anyway? (y/N)" -Default "n"
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

    # Cross-forest: mount the CM ISO on the EXTERNAL top-level site servers before
    # Phase 2 so a joining domain's DC can read their CMCB share for schema
    # extension. No-op for URL-download CM versions / non-cross-forest configs.
    # (Local site-server CM mounts happen in the Phase 8/9 block below, before
    # Start-PhaseJobs.)
    if ($Phase -eq 2) {
        Mount-CmIsoForExternalSchema -deployConfig $deployConfig
    }

    # Allocate the SQLAO cluster heartbeat IPs (10.250.251.x) once, serially, here
    # -- before the parallel Phase 5 jobs fan out -- so every node gets a unique IP
    # with no mutex and no cross-job race. Only Phase 5 needs these.
    if ($Phase -eq 5) {
        Set-SQLAOHeartbeatIPs -DeployConfig $deployConfig
    }

    # Phase 8/9 CM media: take the pre-install rollback snapshot and mount the CM
    # media BEFORE Start-PhaseJobs dispatches the DSC workers -- mirroring the
    # Phase 4 SQL ISO mount above. The ordering here is deliberate and load-bearing:
    #   1. Snapshot FIRST, while NO CM ISO is attached anywhere, so the rollback
    #      checkpoint never captures the host ISO path (this is the reason the mount
    #      used to be deferred until after Start-PhaseJobs).
    #   2. Mount the CM media SECOND and let drive letters settle, so the media is
    #      present and lettered before any guest CM setup runs.
    # Because the discs are locked in up front and never churned mid-phase, the old
    # host-side probe / DVD-reset race (cache disc grabbing D: while the CM disc
    # came up letterless -> false "media not visible" -> CMCB share never created
    # -> DC extadsch deadlock) can no longer happen. No-op for URL-download CM
    # versions; idempotent on -StartPhase reruns.
    if ($Phase -eq 8) {
        Invoke-Phase8PreInstallSnapshot -deployConfig $deployConfig
    }
    if ($Phase -eq 8 -or $Phase -eq 9) {
        # Only mount CM media when this phase actually has DSC work. Phase 9
        # (multi-forest secondary/passive add) is a NO-OP unless there is a hidden
        # cross-domain Primary, and Phase 8 is a no-op on a -StartPhase run whose
        # site servers are already installed. Without this gate, Mount-CmIsoForPhase
        # still mounts + probes + DVD-resets the CM media on every top-level site
        # server for a phase that then reports "No VMs need this step. Skipping." --
        # wasteful churn that can even wedge the guest optical stack (observed:
        # Phase 9 "CM media not visible ... clean DVD reset" immediately before
        # "No VMs need this step"). Gate on the SAME pure config-data builder
        # Start-PhaseJobs uses to decide applicability (Get-PhaseNConfigurationData
        # returns null when no Windows DSC node needs the phase). Call the builder
        # directly -- NOT Get-ConfigurationData -- to avoid its critical-VM
        # verification side effect running twice.
        $cmPhaseHasWork = if ($Phase -eq 9) {
            [bool](Get-Phase9ConfigurationData -deployConfig $deployConfig)
        }
        else {
            [bool](Get-Phase8ConfigurationData -deployConfig $deployConfig)
        }
        if ($cmPhaseHasWork) {
            Mount-CmIsoForPhase -deployConfig $deployConfig -Phase $Phase
        }
        else {
            Write-Log "[Phase $Phase] No DSC nodes need this phase; skipping CM media mount (avoids churning the optical stack for a no-op phase)." -LogOnly
        }
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

    # Eject the CM ISO + drop the CMCB share after a SUCCESSFUL CM phase, so the
    # host ISO path isn't baked into checkpoints / .memlabs exports. On failure
    # leave it mounted for inspection; a -StartPhase retry re-mounts idempotently.
    if ($Phase -eq 2 -and $result.Failed -eq 0) {
        Dismount-CmIsoForExternalSchema -deployConfig $deployConfig
    }
    if (($Phase -eq 8 -or $Phase -eq 9) -and $result.Failed -eq 0) {
        Dismount-CmIsoForPhase -deployConfig $deployConfig -Phase $Phase
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
        $postPhaseScope = [System.Collections.Generic.List[string]]::new()

        # Flip Linux VMs (incl. the Proxy itself) from bootstrap public DNS
        # to the DC's DNS first, so the Proxy can resolve internal names
        # and clients pointed at it land on a fully-configured upstream.
        $hasLinux = @($deployConfig.virtualMachines | Where-Object { (Test-VmIsLinux -Vm $_) -and -not $_.hidden }).Count -gt 0
        if ($hasLinux) {
            $null = Set-LinuxVmsDcDns -DeployConfig $deployConfig
            $postPhaseScope.Add("Linux DNS")
        }

        # NOTE: Set-WindowsClientProxyForConfig used to run here as a serial
        # foreach over Windows clients. Per-VM proxy client config now lives in
        # $global:VM_Config (Phase 2 post-DSC block) so it parallelizes with
        # every other per-VM Phase 2 job. The function remains callable for
        # Fix-* scripts and manual reruns.

        # Per-deploy enforcement covers brand-new VMs whose useProxy lives only
        # in deployConfig (VM Notes not yet written on first-run cases). Only
        # run/label when a VM actually opts into the proxy -- with no useProxy
        # VM the call is a pure no-op, so there's nothing to log.
        $hasProxy = @($deployConfig.virtualMachines | Where-Object { $_.useProxy -eq $true -and -not $_.hidden }).Count -gt 0
        if ($hasProxy) {
            Set-VmProxyEnforcementForConfig -deployConfig $deployConfig | Out-Null
            $postPhaseScope.Add("Proxy config")
        }
        # NOTE: Cross-lab reconciliation (Set-VmProxyEnforcementForAllLabs)
        # runs from New-Lab.ps1 after Phase 11 succeeds, to clear stale ACLs
        # from VMs whose useProxy was flipped off. The ACL set itself is
        # fixed (RFC 1918 allow + deny public ports), so no subnet-union
        # timing concerns exist.

        # Clean up stale tool zips from previous runs that are no longer
        # referenced. Keeps current-fingerprint zips so reruns skip rebuild.
        Clean-StaleToolZips

        $postPhaseTimer.Stop()
        if ($postPhaseScope.Count -gt 0) {
            Write-Log "[Phase 2] Post-processing ($($postPhaseScope -join ', ')) completed. Time: $($postPhaseTimer.Elapsed.ToString("hh\:mm\:ss"))"
        }
        if ($global:BuildStats -and $global:BuildStats.Phases.ContainsKey(2)) {
            $global:BuildStats.Phases[2].Elapsed += $postPhaseTimer.Elapsed
        }
    }

    return $true
}

function Start-NormalJobs {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
        Justification = 'deployConfigCopy/devBranchValue/azureFileList/localAdmin are consumed via $using: inside Start-Job/Start-ThreadJob scriptblocks, which PSScriptAnalyzer cannot trace.')]
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

function Get-MissingDscDispatchNodes {
    param (
        [object]$ConfigurationData,
        [object]$deployConfig
    )

    $dispatchNodeNames = @()
    foreach ($vm in $deployConfig.virtualMachines) {
        $dispatchNodeNames += $vm.vmName
        if ($vm.vmName -and $vm.domain) {
            $dispatchNodeNames += "$($vm.vmName).$($vm.domain)"
        }
    }

    foreach ($node in $ConfigurationData.AllNodes) {
        if ([string]::IsNullOrWhiteSpace([string]$node.NodeName)) {
            '<empty NodeName>'
        }
        elseif ($node.NodeName -notin @('*', 'LOCALHOST') -and $node.NodeName -notin $dispatchNodeNames) {
            $node.NodeName
        }
    }
}


function Start-PhaseJobs {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
        Justification = 'devBranchValue and phaseRunGuid are consumed via $using: inside Start-Job/Start-ThreadJob scriptblocks, which PSScriptAnalyzer cannot trace.')]
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
    $usePhaseThreadJob = $null -ne (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)
    $phaseThreadJobThrottle = 16

    # Determine single vs. multi-DSC
    $multiNodeDsc = $true
    $ConfigurationData = $null
    $linuxDispatchOnly = $false
    if ($Phase -gt 1 -and $Phase -lt 10) {
        $ConfigurationData = Get-ConfigurationData -Phase $Phase -deployConfig $deployConfig
        if (-not $ConfigurationData) {
            # No Windows DSC nodes need this phase. Normally that means the phase
            # is a no-op -- EXCEPT when the only work is a non-DSC Linux dispatch
            # handled later in the per-VM loop:
            #   Phase 2 -> $global:Proxy_Install   (Proxy role: Squid install)
            #   Phase 3 -> $global:Linux_Configure (all Linux: realm-join, xrdp, etc.)
            # Get-PhaseNConfigurationData filters ALL Linux roles out and counts
            # only Windows nodes, so adding ONLY a Linux VM to an existing domain
            # (every Windows member already deployed/hidden) yields null here.
            # Without this guard we early-return Applicable=$false and never
            # dispatch the Linux job -- so a LinuxServer/LinuxClient with
            # joinDomain=true gets created but is never actually realm-joined.
            # Fall through with no DSC nodes so the loop reaches the Linux/Proxy
            # dispatch branches.
            $hasLinuxPhaseWork = $false
            if ($Phase -eq 3) {
                $hasLinuxPhaseWork = @($deployConfig.virtualMachines | Where-Object { (Test-VmIsLinux -Vm $_) -and -not $_.hidden }).Count -gt 0
            }
            elseif ($Phase -eq 2) {
                $hasLinuxPhaseWork = @($deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' -and -not $_.hidden }).Count -gt 0
            }

            if (-not $hasLinuxPhaseWork) {
                # Nothing applicable for this phase
                return [PSCustomObject]@{
                    Failed         = 0
                    Success        = 0
                    Jobs           = 0
                    Applicable     = $false
                    AdditionalData = $null
                }
            }

            Write-Log "[Phase $Phase] No Windows DSC nodes, but Linux VM(s) require this phase; proceeding to per-VM Linux dispatch." -LogOnly
            $multiNodeDsc = $false
            # Linux-only fall-through: there is NO Windows DSC work this phase, so
            # the loop must dispatch ONLY the Linux/Proxy per-VM jobs and skip every
            # Windows VM (including the DC). Without this the DC would fall through
            # to a single-node Windows DSC dispatch and fail on a missing
            # Phase3DC.ps1 (the DC has no standalone Phase-3 config).
            $linuxDispatchOnly = $true
        }
        elseif ($ConfigurationData.AllNodes.NodeName -contains "LOCALHOST") {
            $multiNodeDsc = $false
        }
    }
    else {
        $multiNodeDsc = $false
    }

    if ($multiNodeDsc) {
        $missingDispatchNodes = @(Get-MissingDscDispatchNodes -ConfigurationData $ConfigurationData -deployConfig $deployConfig | Select-Object -Unique)
        if ($missingDispatchNodes.Count -gt 0) {
            Write-Log "[Phase $Phase] ConfigurationData contains DSC node(s) with no dispatchable VM worker: $($missingDispatchNodes -join ', '). Aborting before the DC readiness handshake." -Failure
            return [PSCustomObject]@{
                Failed         = $missingDispatchNodes.Count
                Success        = 0
                Jobs           = 0
                Applicable     = $true
                AdditionalData = $null
            }
        }
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
                else {
                    # The VM reports 'Running', but that only means the Hyper-V
                    # worker process is up -- the guest OS / PSDirect VMBus can
                    # still be unreachable (mid-boot, hung integration services,
                    # or a passive SQLAO node that came up slowly). Probe PSDirect
                    # liveness with a BOUNDED, LOGGED check before the Step 2
                    # admin-add so an unreachable guest doesn't silently burn
                    # ~5 min/attempt in Get-VmSession credential-retry timeouts.
                    #
                    # Do NOT use Wait-ForVm here: its TimeoutMinutes is only
                    # re-checked between iterations, and a single in-flight
                    # Get-VmSession call burns ~5-6 min (4 creds x 30s x 3
                    # retries) with -Quiet producing zero feedback -- so a
                    # "3 minute" wait actually runs ~6 min silently (the
                    # regression that made this look hung). Probe via
                    # Invoke-VmCommand with -SkipDomainFallback (LocalOnly: only
                    # the primary domain cred + the VMNAME\local fallback, no
                    # domain-lookup/Administrator creds) + -SessionMaxRetries 1
                    # + -AsJob, so each probe is bounded to ~60s worst case and
                    # emits its own log line. A reachable guest answers in <5s.
                    $probe = {
                        param($vm, $dom, $label)
                        $r = Invoke-VmCommand -VmName $vm -VmDomainName $dom -DisplayName $label -SuppressLog -SkipDomainFallback -SessionMaxRetries 1 -AsJob -TimeoutSeconds 30 -ScriptBlock { $env:COMPUTERNAME }
                        return [bool]($r -and -not $r.ScriptBlockFailed -and "$($r.ScriptBlockOutput)".Trim())
                    }

                    $reachable = $false
                    for ($p = 1; $p -le 2 -and -not $reachable; $p++) {
                        Write-Progress2 "Preparing Phase $Phase" -Status "$sqlHost`: probing PowerShell Direct (attempt $p/2)" -PercentComplete $global:preparePhasePercent
                        Write-Log "[Phase 8] $sqlHost`: probing PowerShell Direct reachability (attempt $p/2) before admin-add for site server $($ss.vmName)." -LogOnly
                        $reachable = & $probe $sqlHost $domain "PSDirect liveness probe"
                        if (-not $reachable -and $p -lt 2) { Start-Sleep -Seconds 10 }
                    }

                    if (-not $reachable) {
                        Write-Log "[Phase 8] $sqlHost is Running but did not answer PowerShell Direct within ~2 min; restarting it once for site-server $($ss.vmName) preflight." -Warning
                        try { Stop-VM2 -Name $sqlHost -TurnOff } catch {
                            Write-Log "[Phase 8] $sqlHost`: Stop-VM2 threw: $($_.Exception.Message)" -Warning
                        }
                        try { Start-VM2 -Name $sqlHost -ErrorAction Stop } catch {
                            Write-Log "[Phase 8] $sqlHost`: Start-VM2 threw: $($_.Exception.Message)" -Warning
                        }
                        # Bounded wait for the guest to answer after the restart.
                        # Up to 8 probes (~60s each worst case) + 20s gaps = ~10
                        # min ceiling. Heartbeat goes to the in-place "Preparing
                        # Phase" progress bar (not a per-attempt banner) so the
                        # screen stays clean while still showing it's not frozen.
                        for ($p = 1; $p -le 8 -and -not $reachable; $p++) {
                            Write-Progress2 "Preparing Phase $Phase" -Status "$sqlHost`: waiting for PowerShell Direct after restart (attempt $p/8)" -PercentComplete $global:preparePhasePercent
                            Write-Log "[Phase 8] $sqlHost`: waiting for PowerShell Direct after restart (attempt $p/8)." -LogOnly
                            $reachable = & $probe $sqlHost $domain "PSDirect liveness probe (post-restart)"
                            if (-not $reachable -and $p -lt 8) { Start-Sleep -Seconds 20 }
                        }

                        if (-not $reachable) {
                            $postState = (Get-VM2 -Name $sqlHost -ErrorAction SilentlyContinue).State
                            $msg = "[$($ss.vmName) -> $sqlHost] SQL host is Running but never answered PowerShell Direct, even after a restart (state=$postState). The in-guest self-heal scriptblock cannot be delivered."
                            Write-Log "[Phase 8] $msg" -Failure
                            $preflightFailures.Add($msg) | Out-Null
                            continue
                        }
                        Write-Log "[Phase 8] $sqlHost`: PowerShell Direct recovered after restart."
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
                        # ChannelBroken means Get-VmSession could never open a
                        # PSDirect session (every credential attempt timed out --
                        # the guest is Running but its VMBus/PSDirect host is hung),
                        # so the in-guest secure-channel/admin-add scriptblock never
                        # ran. Surface that explicitly instead of the opaque
                        # "returned no result" -- it points the operator at a hung
                        # guest rather than at a membership/ADSI problem.
                        if ($result -and $result.ChannelBroken) {
                            $lastError = "PowerShell Direct channel to $sqlHost is hung (VM is Running but the guest is not responding); the in-guest secure-channel/admin-add scriptblock could not be delivered"
                        }
                        elseif ($result -and $result.ErrorDetails) {
                            $lastError = $result.ErrorDetails
                        }
                        else {
                            $lastError = 'Invoke-VmCommand returned no result'
                        }
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

        # MP database-replica SQL hosts: the replicaSqlServerVM of each SiteSystem MP
        # that uses a database replica is (typically) a HIDDEN VM, so it is NOT a Phase 8
        # DSC node -- Invoke-SmartStartVMs never starts it, and the loop above only covers
        # site servers' remoteSQLVM. ConfigureMPReplica.ps1 runs on the site server and
        # connects to these hosts over SQL + WinRM, so bring them Running + reachable first
        # (otherwise every replica setup fails with "server was not found" / "WinRM cannot
        # complete the operation"). Best-effort: a host that never comes up is left to
        # ConfigureMPReplica's own readiness gate (it waits, then skips + reports), so this
        # does NOT add to $preflightFailures / abort Phase 8.
        $replicaSqlVMs = @($deployConfig.virtualMachines | Where-Object {
                $_.role -eq 'SiteSystem' -and $_.installMP -and $_.useDatabaseReplica -and $_.replicaSqlServerVM
            } | ForEach-Object { $_.replicaSqlServerVM } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($replicaSqlVM in $replicaSqlVMs) {
            $rvm = Get-VM2 -Name $replicaSqlVM -ErrorAction SilentlyContinue
            if (-not $rvm) {
                Write-Log "[Phase 8] MP replica SQL host $replicaSqlVM not found on this Hyper-V host; ConfigureMPReplica will skip its replica(s)." -Warning
                continue
            }
            if ($rvm.State -ne 'Running') {
                Write-Log "[Phase 8] MP replica SQL host $replicaSqlVM is $($rvm.State); starting it for the MP database-replica setup." -Activity
                try { Start-VM2 -Name $replicaSqlVM -ErrorAction Stop } catch {
                    Write-Log "[Phase 8] $replicaSqlVM`: Start-VM2 threw: $($_.Exception.Message)" -Warning
                }
                $ready = Wait-ForVm -VmName $replicaSqlVM -PathToVerify 'C:\Users' -VmDomainName $domain -TimeoutMinutes 3 -SkipDiskTest -Quiet
                if (-not $ready) {
                    $postState = (Get-VM2 -Name $replicaSqlVM -ErrorAction SilentlyContinue).State
                    Write-Log "[Phase 8] MP replica SQL host $replicaSqlVM did not become reachable within 3 minutes (state=$postState); ConfigureMPReplica will wait for it and may skip it." -Warning
                }
                else {
                    Write-Log "[Phase 8] MP replica SQL host $replicaSqlVM is Running and reachable." -LogOnly
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
        # This is nearly a no-op when the DCs are already Running and healthy (a
        # single readiness probe per DC), and additionally self-heals an
        # already-running DC whose PowerShell Direct channel is wedged (see the
        # readiness/recovery loop below) before the per-VM jobs fan out.
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
        foreach ($vmName in $dcNames) {
            $vmObj = $existingVMs | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
            if ($vmObj -and $vmObj.State -ne 'Running') {
                Write-Progress2 "Preparing Phase $Phase" -Status "Starting domain controller $vmName ($($vmObj.State))" -PercentComplete $global:preparePhasePercent
                Start-VM2 -Name $vmName -ErrorAction SilentlyContinue
                $startedCount++
            }
        }

        # Confirm EVERY domain controller is actually serving AD DS / DNS / Netlogon
        # over PowerShell Direct before releasing the dependent VMs and dispatching
        # the per-VM maintenance/validation jobs. This runs for ALL DCs -- not just
        # the ones we started above -- because an ALREADY-running DC can have a
        # wedged PSDirect/VMBus channel: the guest is up with a healthy heartbeat,
        # but New-PSSession -VMId times out. When that DC is the (only) DC, its
        # Phase 10/11 job fails with "Start-VMMaintenance returned no data" and,
        # being the DC, stops the entire phase. A healthy already-running DC passes
        # the first probe instantly, so the normal end-to-end case (Phase 11 right
        # after Phase 10, no reboot) adds negligible delay.
        if ($dcNames.Count -gt 0) {
            $dcWaitTimeoutSec = 300
            foreach ($dcName in $dcNames) {
                Write-Progress2 "Preparing Phase $Phase" -Status "Waiting for domain controller $dcName (AD DS / DNS / Netlogon)" -PercentComplete $global:preparePhasePercent
                $dcReady = $false
                $dcChannelBrokenCount = 0
                $dcChannelRebootDone = $false
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

                    # Probe did not succeed. If the DC is Running with a healthy
                    # heartbeat but PowerShell Direct is wedged (ChannelBroken),
                    # recover the VMBus with a single reboot -- the same recovery
                    # Wait-ForVm performs. One-shot per DC, and only after a few
                    # consecutive channel-broken probes so a transient timeout
                    # during boot doesn't trigger a needless reboot.
                    $vmCheck = Get-VM2 -Name $dcName -ErrorAction SilentlyContinue
                    $vmStateNow = if ($vmCheck) { "$($vmCheck.State)" } else { "NotFound" }
                    $hbNow = if ($vmCheck) { "$($vmCheck.Heartbeat)" } else { "N/A" }
                    $channelBroken = ($probe -and $probe.ChannelBroken)
                    $heartbeatAlive = ($hbNow -ne 'NoContact' -and $hbNow -ne 'N/A')
                    if ($vmStateNow -eq 'Running' -and $channelBroken -and $heartbeatAlive) {
                        $dcChannelBrokenCount++
                        if (-not $dcChannelRebootDone -and $dcChannelBrokenCount -ge 3 -and $sw.Elapsed.TotalSeconds -ge 45) {
                            $dcChannelRebootDone = $true
                            Write-Log "[Phase $Phase] Domain controller $dcName is Running with a healthy heartbeat ($hbNow) but its PowerShell Direct channel is wedged after $dcChannelBrokenCount probes. Rebooting to recover VMBus before dispatching jobs." -Warning
                            Write-Progress2 "Preparing Phase $Phase" -Status "Rebooting domain controller $dcName to recover PowerShell Direct channel" -PercentComplete $global:preparePhasePercent
                            Stop-VM2 -Name $dcName -TurnOff | Out-Null
                            Start-Sleep -Seconds 10
                            Start-VM2 -Name $dcName -ErrorAction SilentlyContinue | Out-Null
                            $dcChannelBrokenCount = 0
                        }
                    }
                    else {
                        $dcChannelBrokenCount = 0
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

    # ---------------------------------------------------------------------
    # Phase 2 DC head start
    #
    # On a FRESH deploy every VM's Phase 2 (single-node) DSC job is dispatched
    # back-to-back, so the DC's promotion (Phase2DC) competes with every domain
    # member's config for host CPU/disk while the members sit idle in
    # WaitForDomainReady polling a DC that isn't up yet. Give the DC a head
    # start proportional to the number of members that will wait on it: dispatch
    # the DC (and the non-domain-joined VMs, which don't wait on it) first, then
    # hold the domain-joined members' dispatch for ~10s per fresh member (capped)
    # so the DC can get ahead in its promotion before the herd arrives.
    #
    # Gating: ONLY engages when the DC itself has never completed Phase 2. If the
    # DC has already completed Phase 2 (a re-run / -StartPhase 2 on an already-
    # promoted DC), $phase2HeadStartSeconds stays 0 and NO VM is delayed -- the
    # dispatch list and loop behave exactly as before. Members that already
    # completed Phase 2 don't count toward the 10s/member multiplier either.
    # ---------------------------------------------------------------------
    $phase2HeadStartSeconds = 0
    $phase2HeadStartDone = $false
    $phase2HeadStartCapSeconds = 180
    $phase2NonDomainJoinedRoles = @('DC', 'OtherDC', 'WorkgroupMember', 'AADClient', 'InternetClient', 'StandaloneRootCA', 'OSDClient')
    if ($Phase -eq 2 -and -not $WhatIf) {
        $dcVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'DC' -and -not $_.hidden } | Select-Object -First 1
        $dcFresh = $false
        if ($dcVm) {
            $dcNote = Get-VMNote -VMName $dcVm.vmName
            $dcFresh = (-not $dcNote -or -not $dcNote.lastPhaseComplete -or [int]$dcNote.lastPhaseComplete -lt 2)
        }
        if ($dcVm -and $dcFresh) {
            $freshMemberCount = 0
            foreach ($mv in $deployConfig.virtualMachines) {
                if ($mv.hidden) { continue }
                if ($mv.role -in $phase2NonDomainJoinedRoles) { continue }
                if (Test-VmIsLinux -Vm $mv) { continue }
                $mNote = Get-VMNote -VMName $mv.vmName
                if (-not $mNote -or -not $mNote.lastPhaseComplete -or [int]$mNote.lastPhaseComplete -lt 2) {
                    $freshMemberCount++
                }
            }
            $phase2HeadStartSeconds = [Math]::Min($freshMemberCount * 10, $phase2HeadStartCapSeconds)
            if ($phase2HeadStartSeconds -gt 0) {
                Write-Log "[Phase 2] DC head start: $($dcVm.vmName) is fresh; $freshMemberCount fresh domain-joined member(s) -> holding member dispatch ${phase2HeadStartSeconds}s after the DC starts (10s/member, capped ${phase2HeadStartCapSeconds}s)." -LogOnly
            }
        }
        else {
            Write-Log "[Phase 2] DC head start: skipped (DC already completed Phase 2 or not found); no VMs delayed." -LogOnly
        }
    }

    # Phase 2 head start active: dispatch the DC first, then the non-domain-joined
    # VMs, then the domain-joined members last (the head-start sleep is injected at
    # the first member's dispatch site below). Stable secondary sort on original
    # index preserves config order within each priority group. Every other phase
    # (and Phase 2 when the head start is inactive) iterates the unmodified list.
    $vmDispatchList = $deployConfig.virtualMachines
    if ($Phase -eq 2 -and $phase2HeadStartSeconds -gt 0) {
        $phase2Idx = 0
        $phase2Tagged = foreach ($v in $deployConfig.virtualMachines) {
            $pri = if ($v.role -eq 'DC') { 0 }
                   elseif (($v.role -in $phase2NonDomainJoinedRoles) -or (Test-VmIsLinux -Vm $v)) { 1 }
                   else { 2 }
            [PSCustomObject]@{ Vm = $v; Pri = $pri; Idx = $phase2Idx }
            $phase2Idx++
        }
        $vmDispatchList = @($phase2Tagged | Sort-Object Pri, Idx | ForEach-Object { $_.Vm })
    }

    foreach ($currentItem in $vmDispatchList) {

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
        # is Windows-only). That means: Phase 4-10 for any Linux, AND Phase 2
        # for non-Proxy Linux roles (LinuxClient, LinuxServer).
        # EXCEPT Phase 11 (functional validation): Test-VmFunctionality has
        # dedicated Linux branches ($vmIsLinux -> ping/SSH/SMB health, proxy,
        # and the joinDomain AD-DNS/realm checks over SSH), so Linux VMs MUST
        # reach the Phase 11 dispatch. Skipping them here left every Linux VM
        # unvalidated (Phase 11 logged "No VMs need this step" on a Linux-only
        # add-to-existing).
        if ((Test-VmIsLinux -Vm $currentItem) -and
            (($Phase -gt 3 -and $Phase -ne 11) -or ($Phase -eq 2 -and $currentItem.role -ne 'Proxy'))) {
            Write-Log "[Phase $Phase] Skipping Linux VM $($currentItem.vmName) (no Windows DSC)" -LogOnly
            continue
        }

        # Linux-only fall-through: ConfigurationData was null (no Windows DSC
        # nodes this phase) but a Linux/Proxy VM still needs it. Dispatch ONLY
        # the Linux/Proxy targets and skip every other VM -- especially the DC,
        # which would otherwise fall through to a single-node Windows DSC job
        # and fail on a missing Phase3DC.ps1.
        if ($linuxDispatchOnly) {
            $isLinuxTarget = ($Phase -eq 3 -and (Test-VmIsLinux -Vm $currentItem))
            $isProxyTarget = ($Phase -eq 2 -and $currentItem.role -eq 'Proxy')
            if (-not ($isLinuxTarget -or $isProxyTarget)) {
                Write-Log "[Phase $Phase] Skipping $($currentItem.vmName) [$($currentItem.role)] (Linux-only dispatch: no Windows DSC work this phase)" -LogOnly
                continue
            }
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
            # NOTE: consumed inside $global:VM_Config via $using:reservation.
            # Static analysis can't see the cross-scriptblock $using: read, so
            # do NOT remove this as a "dead local" -- doing so re-breaks the
            # 418f5d9d "Fix using:reservation crash" (the first VM_Config job of
            # every Phase 2 deploy throws "the using variable '$using:reservation'
            # ... has not been set in the local session").
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Read in $global:VM_Config via $using:reservation')]
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

            # Quiet Windows Update once per run per VM (mirrors $global:DSC_Copied above).
            # The create-time WU service stop+disable only runs at VM-create (Phase 1).
            # A -StartPhase re-run skips Phase 1, and the PRIOR deploy's Phase 11 revert
            # re-enabled wuauserv/UsoSvc (by design, so the SUP can deploy updates after
            # the build) -- so a re-run would otherwise service Windows Updates mid-build,
            # holding the CBS/TrustedInstaller lock (slow Install-WindowsFeature) and
            # injecting reboots. Re-assert the stop+disable the FIRST time we touch each
            # VM in this run, for build phases only ($Phase -lt 11). Phase 11 validation
            # re-enables both services unconditionally at the end, exactly as today, so
            # this is self-cleaning and the post-build SUP behavior is unchanged.
            $quietWUThisRun = $false
            if (-not $global:WU_Quieted) {
                $global:WU_Quieted = @()
            }
            if ($Phase -lt 11 -and $currentItem.VmName -notin $global:WU_Quieted) {
                $quietWUThisRun = $true
                $global:WU_Quieted += $currentItem.VmName
            }
            Write-Log -verbose "[Phase $Phase] $($currentItem.vmName) quietWUThisRun = $quietWUThisRun"

            # Phase 2 DC head start: the dispatch list above puts the DC (and the
            # non-domain-joined VMs) first, so by the time we reach the FIRST
            # domain-joined member the DC's VM_Config job is already running. Hold
            # the member herd for the computed head-start window so the DC can get
            # ahead in its promotion before the members start competing for host
            # CPU/disk and polling it in WaitForDomainReady. One-shot per phase
            # run; never fires when the head start is inactive (DC already did
            # Phase 2), so no VM is delayed in that case.
            if ($Phase -eq 2 -and $phase2HeadStartSeconds -gt 0 -and -not $phase2HeadStartDone -and
                ($currentItem.role -notin $phase2NonDomainJoinedRoles) -and -not (Test-VmIsLinux -Vm $currentItem)) {
                $phase2HeadStartDone = $true
                Write-Log "[Phase 2] DC head start: holding domain-joined member dispatch for ${phase2HeadStartSeconds}s so the DC can get ahead (first member: $($currentItem.vmName))." -Activity
                Write-Progress2 "Preparing Phase $Phase" -Status "DC head start: letting the domain controller get ahead (${phase2HeadStartSeconds}s) before joining $($currentItem.vmName) and the other members" -PercentComplete $global:preparePhasePercent
                Start-Sleep -Seconds $phase2HeadStartSeconds
            }
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

    # If no jobs were dispatched and none failed to dispatch, nothing in this
    # phase applied to any VM (e.g. Phase 10 where every VM is already up to
    # date / kept Off by design). Report Applicable=$false so the caller emits
    # the same "[Phase N] No VMs need this step. Skipping." line that the
    # earlier-phase Get-ConfigurationData short-circuit produces, instead of a
    # misleading "Created 0 jobs. Waiting for jobs."
    $applicable = -not ($job_created_yes -eq 0 -and $job_created_no -eq 0)

    # Create return object
    $return = [PSCustomObject]@{
        Failed         = $job_created_no
        Success        = $job_created_yes
        Jobs           = $jobs
        Applicable     = $applicable
        AdditionalData = $additionalData
    }

    Write-Progress2 "Preparing Phase $Phase" -Status "Created $job_created_yes jobs." -PercentComplete 100 -Completed

    if (-not $applicable) {
        Write-Log "[Phase $Phase] No VMs need this step." -LogOnly
    }
    elseif ($job_created_no -eq 0) {
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

    # A DC/CAS job failure aborts the ENTIRE phase (Stop-Job on every in-flight
    # job) ONLY for the foundational deployment phases (2-9), where dependent VMs
    # genuinely cannot proceed without the DC/CAS. The per-VM fan-out passes --
    # phase 10 (deploy-time maintenance), the standalone "Maintenance" startup
    # pass, and phase 11 (validation) -- only apply idempotent per-VM fixes / run
    # checks, so a single VM's failure (e.g. one fix erroring on the CAS) must NOT
    # cut off every other VM. In those passes each VM stands on its own and is
    # marked failed individually.
    $phaseStr = "$Phase"
    $phaseStopsOnCritFailure = $false
    if ($phaseStr -ne "Maintenance" -and $phaseStr -ne "10" -and $phaseStr -ne "11") {
        $phaseNum = 0
        if ([int]::TryParse($phaseStr, [ref]$phaseNum) -and $phaseNum -ge 2) {
            $phaseStopsOnCritFailure = $true
        }
    }

    # Phase 1 (VM creation) aborts the ENTIRE phase on ANY VM-creation failure --
    # not just the DC/CAS. Every VM in the config is required for the deployment to
    # complete, so once one base-image copy / OOBE attempt fails there is nothing to
    # gain by finishing the other 20+ creates: it only burns time and leaves the
    # operator more half-built VMs to clean up (the corrupt-base-image case). Stop
    # as soon as the first VM job reports a failure and let the operator re-run.
    $phase1StopsOnAnyFailure = ($phaseStr -eq "1")

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
                # The job's State is Failed, but if its scriptblock actually ran to
                # completion (emitted its terminal "...completed successfully" line) and
                # only the post-scriptblock runspace Close timed out
                # (PSRemotingTransportException 2106), this is a FALSE failure -- the VM
                # was created. Score it by the scriptblock's own output the same way a
                # Completed job is scored, instead of failing the whole phase.
                if (Test-JobTransportCloseFalseFailure -Job $job) {
                    $streamSource = Get-JobStreamSource -Job $job
                    $jobName = $job | Select-Object -ExpandProperty Name
                    Write-Log "[Phase $Phase] Job $jobName ended State=Failed, but its scriptblock completed successfully; only the runspace Close/transport teardown timed out after the work finished (PSRemotingTransportException). Scoring by job output, not as a failure." -LogOnly
                    $jobOutput = @($streamSource | Select-Object -ExpandProperty Output)
                    $worstLogLevel = 0
                    $alreadyShown = if ($outputDisplayed.ContainsKey($job.Id)) { $outputDisplayed[$job.Id] } else { 0 }
                    $outputIndex = 0
                    foreach ($OutputObject in $jobOutput) {
                        $outputIndex++
                        $line = $OutputObject.text
                        if (-not $line) { continue }
                        $line = $line.ToString().Trim()
                        if ($OutputObject.LogLevel -gt $worstLogLevel) { $worstLogLevel = $OutputObject.LogLevel }
                        # Skip warning items already surfaced while the job was running.
                        if ($outputIndex -le $alreadyShown -and $OutputObject.LogLevel -ge 2) { continue }
                        if ($OutputObject.LogLevel -eq 2) {
                            Write-OrangePoint $line -ForegroundColor $OutputObject.ForegroundColor
                        }
                        else {
                            Write-GreenCheck $line -ForegroundColor $OutputObject.ForegroundColor
                        }
                    }
                    if ($worstLogLevel -ge 2) { $return.Warning++ } else { $return.Success++ }

                    # Per-VM timing: record as a successful (not failed) phase.
                    if ($global:BuildStats -and $job.Name -match '^(.+?)\s+\[(.+?)\]') {
                        $svmName = $Matches[1]
                        $sRole = $Matches[2]
                        $sStart = if ($job.PSBeginTime) { $job.PSBeginTime } else { $StartTime }
                        $sEnd = if ($job.PSEndTime) { $job.PSEndTime } else { Get-Date }
                        if (-not $global:BuildStats.VMs.ContainsKey($svmName)) {
                            $global:BuildStats.VMs[$svmName] = @{ Role = $sRole; Phases = @{} }
                        }
                        $global:BuildStats.VMs[$svmName].Phases[$Phase] = @{
                            Elapsed = ($sEnd - $sStart)
                            Start   = $sStart
                            End     = $sEnd
                        }
                    }

                    Write-Progress2 -Id $job.Id -Activity $job.Name -Completed -force
                    $jobs.Remove($job)
                    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
                    continue
                }

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
                    # Reap the failed job from the PS session job table. $jobs.Remove only
                    # drops it from this local tracking list; without Remove-Job the dead job
                    # lingers in the session until New-Lab's end-of-run sweep, so jobs from
                    # every phase pile up (e.g. 19+18+6+6 = 49 at "Removing N job(s)").
                    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
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

                # Per-resource DSC timing diagnostic (LogOnly). After a DSC phase job
                # completes, pull the guest's last ConfigurationStatus record and log the
                # slowest resources, so a re-run that still spends minutes in a phase shows
                # exactly WHICH DSC resource consumed the time (SQL setup, cluster
                # formation, a download, etc.) AND how much of the wall-clock was actually
                # outside DSC resources (host push/copy + LCM warmup). Only for DSC phases,
                # only for roles that apply DSC, and only when the job ran a while -- so the
                # extra guest round-trip never touches fast/no-op phases (90s threshold).
                if ($Phase -ge 2 -and $Phase -le 9 -and $DeployConfig -and $jobName -match '^(.+?)\s+\[(.+?)\]') {
                    $dtVmName = $Matches[1]
                    $dtRole = $Matches[2]
                    $dtStart = if ($job.PSBeginTime) { $job.PSBeginTime } else { $StartTime }
                    $dtEnd = if ($job.PSEndTime) { $job.PSEndTime } else { Get-Date }
                    $dtElapsedSec = [int]($dtEnd - $dtStart).TotalSeconds
                    if ($dtRole -notin $dscDiagSkipRoles -and $dtElapsedSec -ge 90) {
                        try {
                            $dtResult = Invoke-VmCommand -VmName $dtVmName -VmDomainName $DeployConfig.vmOptions.domainName `
                                -SuppressLog -TimeoutSeconds 45 -SessionMaxRetries 1 -ScriptBlock {
                                param($topN)
                                # Canonical source first: Get-DscConfigurationStatus returns the LCM's
                                # last run with per-resource DurationInSeconds. It refuses while the LCM
                                # is mid-apply -- which it isn't, the job just finished -- but on the off
                                # chance it throws, fall back to parsing the newest ConfigurationStatus
                                # .json directly (same record the LCM persists).
                                $resAll = @()
                                $meta = @{ Source = 'Get-DscConfigurationStatus'; Reboot = $null; Start = $null }
                                $st = $null
                                try { $st = Get-DscConfigurationStatus -ErrorAction Stop | Select-Object -First 1 } catch { $st = $null }
                                if ($st) {
                                    $meta.Reboot = $st.RebootRequested
                                    $meta.Start = $st.StartDate
                                    foreach ($r in (@($st.ResourcesInDesiredState) + @($st.ResourcesNotInDesiredState))) {
                                        if ($null -eq $r) { continue }
                                        $resAll += [pscustomobject]@{ Id = $r.ResourceId; Dur = [double]$r.DurationInSeconds; Ok = $r.InDesiredState }
                                    }
                                }
                                if ($resAll.Count -eq 0) {
                                    $statusPath = "$env:SystemRoot\System32\Configuration\ConfigurationStatus"
                                    if (-not (Test-Path $statusPath)) { return $null }
                                    $f = Get-ChildItem -Path $statusPath -Filter '*.json' -ErrorAction SilentlyContinue |
                                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                                    if (-not $f) { return $null }
                                    try {
                                        $obj = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
                                    }
                                    catch { return @{ ErrorLine = "json parse failed: $($_.Exception.Message)"; File = $f.Name } }
                                    $meta.Source = $f.Name
                                    $meta.Reboot = $obj.RebootRequested
                                    $meta.Start = $obj.StartDate
                                    foreach ($r in (@($obj.ResourcesInDesiredState) + @($obj.ResourcesNotInDesiredState))) {
                                        if ($null -eq $r) { continue }
                                        $resAll += [pscustomobject]@{ Id = $r.ResourceId; Dur = [double]$r.DurationInSeconds; Ok = $r.InDesiredState }
                                    }
                                }
                                if ($resAll.Count -eq 0) { return $null }
                                $top = $resAll | Sort-Object Dur -Descending | Select-Object -First $topN
                                $total = ($resAll | Measure-Object Dur -Sum).Sum
                                return @{
                                    Source          = $meta.Source
                                    Reboot          = $meta.Reboot
                                    ResourceCount   = $resAll.Count
                                    TotalSec        = [math]::Round([double]$total, 1)
                                    Top             = @($top | ForEach-Object { '{0,7:N1}s  {1}  [InDesiredState={2}]' -f $_.Dur, $_.Id, $_.Ok })
                                }
                            } -ArgumentList 8
                            $dt = $dtResult.ScriptBlockOutput
                            if ($dt -and $dt.Top) {
                                $dtOutsideSec = [int]($dtElapsedSec - $dt.TotalSec)
                                if ($dtOutsideSec -lt 0) { $dtOutsideSec = 0 }
                                Write-Log "[DscTiming] $dtVmName [$dtRole] Phase $Phase job=${dtElapsedSec}s; record '$($dt.Source)': $($dt.ResourceCount) resources, applied-sum $($dt.TotalSec)s, ~${dtOutsideSec}s outside resources (host push/copy + LCM warmup), reboot=$($dt.Reboot). Slowest resources:" -LogOnly
                                foreach ($tl in $dt.Top) {
                                    Write-Log "[DscTiming]   $dtVmName - $tl" -LogOnly
                                }
                            }
                            elseif ($dt -and $dt.ErrorLine) {
                                Write-Log "[DscTiming] $dtVmName [$dtRole] Phase ${Phase}: $($dt.ErrorLine)" -LogOnly
                            }
                        }
                        catch {
                            Write-Log "[DscTiming] ${dtVmName}: failed to read DSC timing - $_" -LogOnly -Verbose
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
                        # Only for foundational deploy phases (2-9); maintenance (10 /
                        # "Maintenance") and validation (11) never abort their siblings.
                        if ($OutputObject.LogLevel -eq 3 -and (($phaseStopsOnCritFailure -and ($jobName.Contains("[DC]") -or $jobName.Contains("[CAS]"))) -or $phase1StopsOnAnyFailure)) {
                            $critRole = if ($jobName.Contains("[DC]")) { "DC" } elseif ($jobName.Contains("[CAS]")) { "CAS" } else { "VM creation" }
                            Write-RedX "$critRole failed. Stopping Phase." -ForegroundColor $OutputObject.ForegroundColor
                            try { $jobs | Stop-Job } catch {}
                            $return.Failed++
                            return $return
                        }
                        continue
                    }

                    if ($OutputObject.LogLevel -eq 3) {
                        Write-RedX $line -ForegroundColor $OutputObject.ForegroundColor
                        if (($phaseStopsOnCritFailure -and ($jobName.Contains("[DC]") -or $jobName.Contains("[CAS]"))) -or $phase1StopsOnAnyFailure) {
                            $critRole = if ($jobName.Contains("[DC]")) { "DC" } elseif ($jobName.Contains("[CAS]")) { "CAS" } else { "VM creation" }
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
                # Reap the completed job from the PS session job table. Its output/streams
                # were already drained above; $jobs.Remove only updates this local list, so
                # without Remove-Job the finished job survives in the session and accumulates
                # across phases until the end-of-run cleanup sweep.
                try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
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

        # ── PSDirect leak diagnostic (LogOnly) ────────────────────────────
        # Phase boundary: every worker job for this phase has finished. Count
        # the PSRemoting jobs + PSSessions still alive in THIS (parent/host)
        # process to learn whether abandoned timed-out Invoke-VmCommand jobs and
        # their leaked sessions actually escape the worker that created them.
        #   - ThreadJob workers run in child runspaces with their OWN job
        #     repositories, and Start-Job workers run in child PROCESSES, so the
        #     leaked Invoke-Command -AsJob jobs likely DON'T appear here -- a
        #     count of ~0 phase-over-phase means the leak is reaped at worker
        #     teardown and no cross-phase reaper is needed (the -LeakSession
        #     crash fix in Invoke-VmCommand is sufficient).
        #   - If the PSRemotingJob / PSSession counts CLIMB across phases, the
        #     leak is escaping to the parent and a reaper (hung off the next
        #     phase's Wait-ForVm, per the design discussion) is warranted.
        # PSJobTypeName disambiguates: 'RemoteJob' = the leaked PSDirect jobs;
        # 'BackgroundJob'/'ThreadJob' = the phase workers themselves.
        try {
            $allJobs = @(Get-Job -ErrorAction SilentlyContinue)
            $remoteJobs = @($allJobs | Where-Object { $_ -is [System.Management.Automation.PSRemotingJob] })
            $byState = (@($remoteJobs | Group-Object State | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
            $byType = (@($allJobs | Group-Object PSJobTypeName | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
            $sessions = @(Get-PSSession -ErrorAction SilentlyContinue)
            $sessByAvail = (@($sessions | Group-Object Availability | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
            $cacheCount = if ($global:ps_cache) { $global:ps_cache.Count } else { 0 }
            $threadJobMode = [bool](Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)
            Write-Log "[Phase $Phase] PSDirect leak diag (pid $PID, ThreadJobMode=$threadJobMode): PSRemotingJobs=$($remoteJobs.Count) [$byState]; AllJobsByType [$byType]; PSSessions=$($sessions.Count) [$sessByAvail]; ps_cache=$cacheCount" -LogOnly
        }
        catch { Write-Log "[Phase $Phase] PSDirect leak diag failed: $_" -LogOnly -Verbose }

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

# Take the Phase 8 pre-install rollback snapshot of the domain. Extracted from
# Get-ConfigurationData so the phase orchestrator can take it EARLY -- before the
# CM media is mounted and before Start-PhaseJobs dispatches the DSC workers --
# guaranteeing the checkpoint is ISO-free and the media can then be locked in and
# left untouched for the whole phase. Gating is unchanged from the old inline
# block: only snapshot when a CAS/Primary in the Phase 8 set has never finished
# Phase 8 (the risky first CM install), honoring $global:NoSnapshot and an
# existing snapshot of the same name.
function Invoke-Phase8PreInstallSnapshot {
    param([object]$deployConfig)

    if ($global:NoSnapshot) { return }
    $cd = Get-Phase8ConfigurationData -deployConfig $deployConfig
    if (-not $cd) { return }

    $autoSnapshotName = "MemLabs Phase 8 AutoSnapshot " + $Global:ConfigurationShort
    $snapshot = $null
    $dc = get-list2 -deployConfig $deployConfig | Where-Object { $_.role -eq "DC" }
    if ($dc) {
        $snapshot = Get-VMCheckpoint2 -VMName $dc.vmName -ErrorAction SilentlyContinue | where-object { $_.Name -like "*$autoSnapshotName*" } | Sort-Object CreationTime | Select-Object -ExpandProperty Name
    }

    # Snapshot decision is based ONLY on CAS/Primary site servers in the Phase 8
    # set. They are the ones actually running CM setup; other Phase 8 VMs (DPMP,
    # PassiveSite, Secondary, etc.) are secondary work whose failure is
    # recoverable. Other roles (AAD-joined clients, etc.) don't even run in Phase 8.
    #
    # Snapshot only when there's a CAS/Primary in the set that has NOT yet finished
    # Phase 8 -- i.e. the risky first CM install is about to happen. If the
    # CAS/Primary in scope has already done Phase 8 once (re-run, validation pass,
    # adding a secondary), the install already succeeded and a new rollback point
    # is unnecessary. If there's no CAS/Primary in the Phase 8 set at all, no CM
    # site install is happening -- also skip. lastPhaseComplete is monotonic (see
    # Set-VMNote in Common.ps1), so '< 8' reliably means "this CAS/Primary has
    # never finished Phase 8" -- the only state where a pre-install rollback point
    # is useful. This covers both the happy first-deploy path AND a resume after an
    # earlier phase (e.g. Phase 4) failed, while skipping no-op re-runs on a lab
    # that already reached 8+.
    $phase8SiteServers = $cd.AllNodes | Where-Object {
        $_.NodeName -ne "*" -and ($_.Role -eq 'CAS' -or $_.Role -eq 'Primary')
    }
    $needsSnapshot = $false
    foreach ($node in $phase8SiteServers) {
        $vmNote = Get-VMNote -VMName $node.NodeName
        if (-not $vmNote -or -not $vmNote.lastPhaseComplete -or $vmNote.lastPhaseComplete -lt 8) {
            $needsSnapshot = $true
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
            # The Phase 8 pre-install rollback snapshot is taken earlier now, by
            # Invoke-Phase8PreInstallSnapshot in the phase orchestrator -- BEFORE
            # the CM media is mounted and BEFORE Start-PhaseJobs dispatches the DSC
            # workers -- so the checkpoint stays ISO-free and the media can be
            # locked in up front. Here we only build the configuration data.
            $cd = Get-Phase8ConfigurationData -deployConfig $deployConfig
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
    # Include SQL VMs (they install SQL) plus site servers / site systems even when
    # they use REMOTE SQL: Phase 4 installs the SqlServer PS module on them (module
    # only, no SQL install) so Invoke-Sqlcmd is available for later phases/testing.
    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.SqlVersion -or $_.Role -eq "DC" -or ($_.Role -in @("Primary", "CAS", "Secondary", "SiteSystem") -and -not $_.Hidden) }) {

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
                if ($vm.Role -eq "PassiveSite" -and $vm.remoteContentLibVM) {
                    # Add-to-existing configurations can reference an existing
                    # remote content-library server without carrying that VM in
                    # virtualMachines. InstallPassiveSiteServer configures the
                    # content-library share remotely; only include the generic
                    # FileServer DSC node when this run can dispatch its worker.
                    $remoteContentLibVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $vm.remoteContentLibVM } | Select-Object -First 1
                    if ($remoteContentLibVM -and $fsVMsAdded -notcontains $vm.remoteContentLibVM) {
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
            $json = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $deployConfig.vmOptions.domainName -SuppressLog -AsJob -TimeoutSeconds 30 -ScriptBlock {
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