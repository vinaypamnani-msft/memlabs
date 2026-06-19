# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
############################
### SnapShot Functions ###
############################
#Common.Snapshots.ps1

function Merge-Phase8AutoSnapshot {
    <#
    .SYNOPSIS
        Merges the Phase 8 auto-snapshot for all VMs in the domain after
        Phase 11 functional validation passes.
    .DESCRIPTION
        Finds all "MemLabs Phase 8 AutoSnapshot" checkpoints in the domain,
        verifies sufficient free disk space, then removes the checkpoints
        (triggering live AVHDX merge in background). VMs remain running.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$DeployConfig
    )

    $domain = $DeployConfig.vmOptions.domainName
    $snapshotPattern = "*MemLabs Phase 8 AutoSnapshot*"

    Write-Log "[Phase 11] Checking for Phase 8 auto-snapshot to merge..." -LogOnly

    # Get all VMs in this domain
    $vms = Get-List -Type VM -DomainName $domain
    if (-not $vms) {
        Write-Log "[Phase 11] No VMs found in domain '$domain'; skipping snapshot merge" -LogOnly
        return
    }

    # Find VMs that have the Phase 8 auto-snapshot
    $vmsWithSnapshot = @()
    foreach ($vm in $vms) {
        $snaps = @(Get-VMCheckpoint -VMName $vm.vmName -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $snapshotPattern })
        if ($snaps.Count -gt 0) {
            $vmsWithSnapshot += @{ VMName = $vm.vmName; Snapshots = $snaps }
        }
    }

    if ($vmsWithSnapshot.Count -eq 0) {
        Write-Log "[Phase 11] No Phase 8 auto-snapshot found on any VM; skipping merge" -LogOnly
        return
    }

    Write-Log "[Phase 11] Found Phase 8 auto-snapshot on $($vmsWithSnapshot.Count) VM(s); checking free space..." -Activity

    # Pre-flight: verify enough free disk space to absorb the AVHDX chain
    $insufficient = @()
    foreach ($entry in $vmsWithSnapshot) {
        try {
            $chk = Test-VMCheckpointMergeFreeSpace -VMName $entry.VMName
        }
        catch {
            Write-Log "[Phase 11] Free-space check for $($entry.VMName) failed: $($_.Exception.Message)" -Warning
            continue
        }
        if (-not $chk.Ok) {
            $insufficient += [PSCustomObject]@{ VMName = $entry.VMName; Reason = $chk.Reason }
            Write-Log "[Phase 11]   $($entry.VMName): $($chk.Reason)" -Failure
        }
    }
    if ($insufficient.Count -gt 0) {
        Write-Log "[Phase 11] Aborting snapshot merge: $($insufficient.Count) VM(s) do not have enough free disk space" -Warning
        return
    }

    Write-Log "[Phase 11] Free-space check passed; merging (live)..." -SubActivity

    # Remove the Phase 8 auto-snapshot from each VM (live merge)
    $mergeFailures = 0
    foreach ($entry in $vmsWithSnapshot) {
        foreach ($snap in $entry.Snapshots) {
            Write-Log "[Phase 11] Removing checkpoint '$($snap.Name)' from $($entry.VMName)" -LogOnly
            try {
                Remove-VMCheckpoint -VMName $entry.VMName -Name $snap.Name -ErrorAction Stop
                Write-Log "[Phase 11]   ok" -LogOnly
            }
            catch {
                Write-Log "[Phase 11]   Remove-VMCheckpoint failed: $($_.Exception.Message)" -Warning
                try {
                    Remove-VMSnapshot -VMSnapshot $snap -ErrorAction Stop
                    Write-Log "[Phase 11]   Remove-VMSnapshot fallback ok" -LogOnly
                }
                catch {
                    Write-Log "[Phase 11]   Remove-VMSnapshot also failed: $($_.Exception.Message)" -Failure
                    $mergeFailures++
                }
            }

            # Remove sidecar notes file if present
            $vmPath = (Get-VM -Name $entry.VMName -ErrorAction SilentlyContinue).Path
            if ($vmPath) {
                $notesFile = Join-Path $vmPath ($snap.Name + '.json')
                if (Test-Path $notesFile) {
                    Remove-Item $notesFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($mergeFailures -eq 0) {
        Write-Log "[Phase 11] Phase 8 auto-snapshot merge initiated successfully (merging in background)" -Success
    }
    else {
        Write-Log "[Phase 11] Phase 8 auto-snapshot merge completed with $mergeFailures failure(s)" -Warning
    }
}

function Test-Phase8AutoSnapshotExists {
    <#
    .SYNOPSIS
        Returns $true when a "MemLabs Phase 8 AutoSnapshot" checkpoint still
        exists on any VM in the domain.
    .DESCRIPTION
        Used to decide whether suggesting -restore after a Phase 8 failure /
        cancel is meaningful. The Phase 8 auto-snapshot is only ever created
        when a CAS/Primary is about to perform its first CM install (i.e. NOT a
        re-run of an already-installed site -- see Get-ConfigurationData), and
        it is merged/removed once Phase 11 validation passes. So its presence
        is a reliable proxy for "a fresh CM setup was attempted this run and a
        pre-install rollback point is available", which is exactly when
        restoring before retrying makes sense. When it's absent (re-run,
        -NoSnapshot, snapshot declined, or the run was cancelled before the
        snapshot was taken) restoring is pointless and should not be offered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$DeployConfig
    )

    $domain = $DeployConfig.vmOptions.domainName
    $snapshotPattern = "*MemLabs Phase 8 AutoSnapshot*"

    $vms = Get-List -Type VM -DomainName $domain
    if (-not $vms) { return $false }

    foreach ($vm in $vms) {
        $snaps = @(Get-VMCheckpoint -VMName $vm.vmName -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $snapshotPattern })
        if ($snaps.Count -gt 0) { return $true }
    }
    return $false
}

function Invoke-AutoSnapShotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain,
        [Parameter(Mandatory = $true, HelpMessage = "Snapshot name (Must Contain MemLabs)")]
        [string] $comment
    )

    # Live (production) checkpoint -- VMs stay running.
    #
    # Previously we stopped every VM in the domain, snapshotted, then started
    # them back up in dependency order. That cold-snapshot pattern killed the
    # in-flight WSUS catalog sync kicked off in Phase 7 (and added several
    # minutes of stop+start overhead). Lab VMs are Gen2 with integration
    # services and default CheckpointType=Production, so Hyper-V uses VSS to
    # quiesce each VM and produce an application-consistent snapshot while
    # the VMs continue running. SQL, WSUS, AD are all VSS-aware.
    #
    # Per-VM VSS snapshots are not coordinated across VMs, but the wall-clock
    # drift is sub-second and the snapshot's purpose is "rollback point before
    # CM install" -- minor inter-VM drift is fine.
    $failures = Invoke-SnapshotDomain -domain $domain -comment $comment -quiet:$true
    if ($failures -ne 0) {
        write-log "$failures VM(s) could not be snapshotted" -Failure
    }
}

function Invoke-SnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "Comment")]
        [string] $comment = "",
        [Parameter(Mandatory = $false, HelpMessage = "Quiet Mode")]
        [bool] $quiet = $false
    )



    $vms = get-list -type vm -DomainName $domain

    $date = Get-Date -Format "yyyy-MM-dd hh.mmtt"
    $snapshot = $date + " (MemLabs) " + $comment

    $failures = 0
    if (-not $quiet) {
        Write-Log "Snapshotting Virtual Machines in '$domain'" -Activity
        Write-Log "Domain $domain has $(($vms | Measure-Object).Count) resources"
    }

    # Per-VM Checkpoint-VM is dominated by VHDX flush + AVHDX creation, mostly
    # disk I/O on whatever drive backs each VM. Parallelize via ThreadJob with
    # a modest throttle so we don't queue-storm the storage controller. Falls
    # back to sequential when ThreadJob isn't available.
    $useThreadJob = (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue) -ne $null

    $snapshotWorker = {
        param($vmName, $snapshotName)
        $messages = New-Object System.Collections.Generic.List[object]
        $ok = $false
        $tries = 0
        while (-not $ok) {
            try {
                if ($tries -gt 10) {
                    return @{ VmName = $vmName; Ok = $false; Messages = $messages }
                }
                # Inline Checkpoint-VM2 equivalent: write notes file then snapshot.
                # Get-VM2 (cache-aware) isn't available in the ThreadJob runspace.
                $vm = Get-VM -Name $vmName -ErrorAction Stop
                $notesFile = Join-Path $vm.Path ($snapshotName + ".json")
                $vm.notes | Out-File $notesFile
                # Force CheckpointType=Production before capture. Standard
                # (memory-including) checkpoints of AD-joined VMs are an
                # anti-pattern: restore wakes the VM in Saved state with
                # the original runtime tickets/secure-channel context, which
                # frequently desyncs from AD after the snapshot ages out and
                # produces phantom auth failures (broken secure channel,
                # WMI ACCESS_DENIED) that look exactly like real ACL gaps.
                # Production checkpoints use VSS for an app-consistent disk-
                # only capture; restore leaves the VM Off so the next start
                # is a clean cold boot. Idempotent: no-op on already-Production.
                if ($vm.CheckpointType -ne 'Production') {
                    $messages.Add("$vmName`: forcing CheckpointType Production (was $($vm.CheckpointType))")
                    Set-VM -VM $vm -CheckpointType Production -ErrorAction SilentlyContinue
                }
                Checkpoint-VM -VM $vm -SnapshotName $snapshotName -ErrorAction Stop
                $ok = $true
            }
            catch {
                $messages.Add("Error: $_")
                $tries++
                try { Stop-VM -Name $vmName -Force -ErrorAction SilentlyContinue } catch {}
                Start-Sleep 10
            }
        }
        return @{ VmName = $vmName; Ok = $ok; Messages = $messages }
    }

    if ($useThreadJob) {
        if (-not $quiet) {
            Show-StatusEraseLine "Checkpointing $(($vms | Measure-Object).Count) VM(s) to [$snapshot]" -indent
        }
        $jobs = foreach ($vm in $vms) {
            Start-ThreadJob -ScriptBlock $snapshotWorker -ArgumentList $vm.VmName, $snapshot -ThrottleLimit 4
        }
        $results = $jobs | Wait-Job | Receive-Job
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        foreach ($r in $results) {
            foreach ($m in $r.Messages) { Write-Log $m -LogOnly }
            if ($r.Ok) {
                if (-not $quiet) {
                    Write-GreenCheck "Checkpoint $($r.VmName) to [$snapshot] Complete                     "
                }
            }
            else {
                $failures++
                Write-RedX "Checkpoint $($r.VmName) to [$snapshot] Failed after retries. See Logs for error."
            }
        }
    }
    else {
        foreach ($vm in $vms) {
            $complete = $false
            $tries = 0
            While ($complete -ne $true) {
                try {
                    if ($tries -gt 10) {
                        $failures++
                        return $failures
                    }
                    if (-not $quiet) {
                        Show-StatusEraseLine "Checkpointing $($vm.VmName) to [$($snapshot)]" -indent
                    }

                    # Force CheckpointType=Production -- see ThreadJob branch
                    # above for rationale (Standard checkpoints of AD-joined
                    # VMs cause stale Kerberos/secure-channel state on restore).
                    $hvm = Get-VM -Name $vm.VmName -ErrorAction SilentlyContinue
                    if ($hvm -and $hvm.CheckpointType -ne 'Production') {
                        Write-Log "$($vm.VmName): forcing CheckpointType Production (was $($hvm.CheckpointType))" -LogOnly
                        Set-VM -VM $hvm -CheckpointType Production -ErrorAction SilentlyContinue
                    }
                    Checkpoint-VM2 -Name $vm.VmName -SnapshotName $snapshot -ErrorAction Stop
                    $complete = $true
                    if (-not $quiet) {
                        Write-GreenCheck "Checkpoint $($vm.VmName) to [$($snapshot)] Complete                     "
                    }
                }
                catch {
                    Write-RedX "Checkpoint $($vm.VmName) to [$($snapshot)] Failed. Retrying. See Logs for error."
                    write-log "Error: $_" -LogOnly
                    $tries++
                    stop-vm2 -name $vm.VmName
                    Start-Sleep 10
                }
            }
        }
    }
    return $failures
}

function select-DeleteSnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain
    )
    $vms = get-list -type vm -DomainName $domain
    $dc = $vms | Where-Object { $_.role -eq "DC" }

    $snapshots = Get-VMCheckpoint2 -VMName $dc.vmName -ErrorAction SilentlyContinue | where-object { $_.Name -like "*MemLabs*" } | Sort-Object CreationTime | Select-Object -ExpandProperty Name
    if (-not $snapshots) {
        Write-OrangePoint "No snapshots found for $domain"
        return
    }
    $response = get-menu2 -MenuName "VM Snapshot merge" -Prompt "Select Snapshot to merge/delete" -OptionArray $snapshots -additionalOptions @{"A" = "All Snapshots" } -test:$false -return
    if ([string]::IsNullOrWhiteSpace($response) -or $response -eq "None" -or $response -eq "ESCAPE") {
        return
    }

    Write-Log "Removing previous snapshots of Virtual Machines in '$domain'" -Activity
    $vms = get-list -type vm -DomainName $domain

    # --- Pre-flight: confirm every VM has enough free disk on the parent VHDX's
    # drive(s) to absorb its AVHDX chain. If any VM fails the check, abort
    # before we kick off Remove-VMCheckpoint - running out of space mid-merge
    # leaves the VHDX chain in a state the VM cannot boot from.
    Write-Log "Checking free disk space for snapshot merge..." -SubActivity
    $insufficient = @()
    foreach ($vm in $vms) {
        try {
            $chk = Test-VMCheckpointMergeFreeSpace -VMName $vm.vmName
        } catch {
            Write-Log "Free-space check for $($vm.vmName) failed: $($_.Exception.Message)" -Warning
            continue
        }
        if (-not $chk.Ok) {
            $insufficient += [PSCustomObject]@{ VMName = $vm.vmName; Reason = $chk.Reason }
            Write-Log "  $($vm.vmName): $($chk.Reason)" -Failure
        }
    }
    if ($insufficient.Count -gt 0) {
        Write-Host
        Write-Host2 -ForegroundColor Red "Aborting merge: $($insufficient.Count) VM(s) do not have enough free disk space."
        Write-Host2 -ForegroundColor Red "Free up space (or compact the parent VHDX) and try again. Merging without enough space will hang and may leave the VM unbootable."
        foreach ($i in $insufficient) {
            Write-Host2 -ForegroundColor Yellow "  $($i.VMName): $($i.Reason)"
        }
        return
    }
    Write-Log "  Free-space check passed for $($vms.Count) VM(s)." -Success

    foreach ($vm in $vms) {
        $complete = $false
        $tries = 0
        While ($complete -ne $true) {
            try {
                if ($tries -gt 10) {
                    return
                }
                $snapshots = Get-VMCheckpoint2 -VMName $vm.vmName -ErrorAction SilentlyContinue | where-object { $_.Name -like "*MemLabs*" } | Sort-Object CreationTime | Select-Object -ExpandProperty Name
                #$checkPoint = Get-VMCheckpoint2 -VMName $vm.vmName -Name 'MemLabs Snapshot' -ErrorAction SilentlyContinue

                if ($snapshots) {
                    foreach ($snapshot in $snapshots) {
                        if ($snapshot -eq $response -or $response -eq "A") {
                            Show-StatusEraseLine "Removing $snapshot for $($vm.VmName) and merging into vhdx" -indent
                            Remove-VMCheckpoint2 -VMName $vm.vmName -Name $snapshot

                            if ($snapshot -eq "MemLabs Snapshot") {
                                $notesFile = Join-Path (Get-VM2 -Name $($vm.VmName)).Path 'MemLabs.Notes.json'
                            }
                            else {
                                $notesFile = Join-Path (Get-VM2 -Name $($vm.VmName)).Path $snapshot + '.json'
                            }

                            if (Test-Path $notesFile) {
                                Remove-Item $notesFile -Force -ProgressAction SilentlyContinue
                            }
                            Write-GreenCheck "Merge of $snapshot into $($vm.VmName) complete                            "
                        }
                    }
                }

                $complete = $true
            }
            catch {
                Start-Sleep 10
                $tries++

            }
        }
    }
    get-list -type vm -SmartUpdate | out-null
    write-host
    Write-Host "  $domain snapshots have been merged"

}

function select-SnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain
    )
    Write-Host
    Write-Host2 -ForegroundColor Orange "It is recommended to stop Critical VMs before snapshotting. Please select which VMs to stop."
    #Invoke-StopVMs -domain $domain
    $result = Select-StopDomain -domain $domain -AllSelected -Sync
    write-log "Snapshotting Virtual Machines in '$domain' result: $result"
    if ($result -eq "ESCAPE") {
        return
    }
    
    get-SnapshotDomain -domain $domain

    #$critlist = Get-CriticalVMs -domain $deployConfig.vmOptions.domainName -vmNames $nodes
    #$failures = Invoke-SmartStartVMs -CritList $critlist
    #if ($failures -ne 0) {
    #    write-log "$failures VM(s) could not be started" -Failure
    #}
    Select-StartDomain -domain $domain

}

function get-SnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "Comment")]
        [string] $comment
    )

    $valid = $false
    while (-not $valid) {
        if (-not $comment) {
            $comment = Read-Single -timeout 30 -Prompt "Snapshot Comment (Optional) []" -useReadHost
            #$comment = Read-Host2 -Prompt "Snapshot Comment (Optional) []" $splitpath -HideHelp
        }
        if (-not [string]::IsNullOrWhiteSpace($comment) -and $comment -match "^[\\\/\:\*\?\<\>\|]*$") {
            Write-Host "$comment contains invalid characters"
            $comment = $null
        }
        else {
            $valid = $true
        }
    }

    $failures = Invoke-SnapshotDomain -domain $domain -comment $comment
    if ($failures -ne 0) {
        Write-RedX "$failures VM(s) could not be snapshotted" -Failure
    }

}

function select-RestoreSnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "Run automatically if only one snapshot")]
        [bool] $auto = $false
    )


    $vms = get-list -type vm -DomainName $domain
    $dc = $vms | Where-Object { $_.role -eq "DC" }

    $snapshots = Get-VMCheckpoint2 -VMName $dc.vmName -ErrorAction SilentlyContinue | where-object { $_.Name -like "*MemLabs*" } | Sort-Object CreationTime | Select-Object -ExpandProperty Name
    if (-not $snapshots) {
        Write-OrangePoint "No snapshots found for $domain"
        return
    }
    if ($auto -and $snapshots.Count -eq 1) {
        $response = $snapshots
        Write-Log "Auto restoring snapshot $response" -SubActivity
    }
    else {
        $response = get-menu2 -MenuName "Snapshot Restore" -Prompt "Select Snapshot to restore" -OptionArray $snapshots -test:$false -return
        if ([string]::IsNullOrWhiteSpace($response) -or $response -eq "None" -or $response -eq "ESCAPE") {
            return
        }
    }    
    $missingVMS = @()

    foreach ($vm in $vms) {
        $checkPoint = Get-VMCheckpoint2 -VMName $vm.vmName -Name $response -ErrorAction SilentlyContinue | Sort-Object CreationTime | Select-Object -Last 1
        if (-not $checkPoint) {
            $missingVMS += $vm.VmName
        }
    }
    if ($missingVMS.Count -gt 0) {
        Write-Host
        $DeleteVMs = Read-Host2 -Prompt "The following VMs do not have checkpoints. [$($missingVMs -join ",")]  Delete them? (y/N)" -HideHelp
    }

    if ($auto -and $snapshots.Count -eq 1) {
        $startAll = "A"
    }
    else {
        $startAll = Read-YesOrNoWithTimeout -Prompt "Start All VMs after restore? (Y/n)" -HideHelp -Default "y"
        if ($startAll -and ($startAll.ToLowerInvariant() -eq "n" -or $startAll.ToLowerInvariant() -eq "no")) {
            $startAll = $null
        }
        else {
            $startAll = "A"
        }
    }   

    Write-Log "Restoring Virtual Machines in '$domain' to previous snapshot" -Activity

    foreach ($vm in $vms) {
        $complete = $false
        $tries = 0
        While ($complete -ne $true) {
            try {
                if ($tries -gt 10) {
                    return
                }
                $checkPoint = Get-VMCheckpoint2 -VMName $vm.vmName -Name $response -ErrorAction SilentlyContinue | Sort-Object CreationTime | Select-Object -Last 1

                if ($checkPoint) {
                    Show-StatusEraseLine "Restoring $($vm.VmName)" -indent
                    # Hard-off the VM before reverting. Restore-VMCheckpoint will
                    # also stop a Running VM automatically, but doing it explicitly
                    # invalidates our PSDirect session cache (Stop-VM2 clears it),
                    # avoids the auto-stop racing with in-flight VSS writers, and
                    # gives a deterministic pre-revert state for every checkpoint
                    # type. No-op when the VM is already Off.
                    try { Stop-VM2 -Name $vm.VmName -TurnOff -ErrorAction SilentlyContinue | Out-Null } catch {}
                    $checkPoint | Restore-VMCheckpoint -Confirm:$false
                    # Defense in depth: a Standard (memory-including) checkpoint
                    # restore leaves the VM in Saved state -- starting from Saved
                    # resumes with the snapshot-time runtime context (stale
                    # Kerberos tickets, broken secure channel, dead WMI/DCOM
                    # connections), which is exactly the failure mode the
                    # 'live snapshot of an AD member' anti-pattern produces.
                    # Force any Saved/Running post-restore state to Off so the
                    # downstream Select-StartDomain always does a clean cold boot.
                    $postState = (Get-VM -Name $vm.VmName -ErrorAction SilentlyContinue).State
                    if ($postState -and $postState -ne 'Off') {
                        Write-Log "$($vm.VmName): post-restore state was $postState; forcing Off for clean cold boot" -LogOnly
                        try { Stop-VM2 -Name $vm.VmName -TurnOff -ErrorAction SilentlyContinue | Out-Null } catch {}
                    }
                    if ($response -eq "MemLabs Snapshot") {
                        $notesFile = Join-Path (Get-VM2 -Name $($vm.VmName)).Path 'MemLabs.Notes.json'
                    }
                    else {
                        $jsonfile = $response + ".json"
                        $notesFile = Join-Path (Get-VM2 -Name $($vm.VmName)).Path $jsonfile
                    }
                    if (Test-Path $notesFile) {
                        $notes = Get-Content $notesFile
                        set-vm -VMName $vm.vmName -notes $notes
                    }
                    Write-GreenCheck "Restore Completed for $($vm.VmName)                      "
                }
                $complete = $true
            }
            catch {
                Write-RedX "Restore of $($vm.VmName) Failed. Retrying. See Logs for error."
                write-log "Error: $_" -LogOnly
                Start-Sleep 10
                $tries++

            }
        }
    }

    #Show-StatusEraseLine "Waiting for all Restores to finish" -indent
    #Write-Log -HostOnly "Waiting for VM Start Jobs to complete" -Verbose
    #get-job | wait-job | out-null
    get-list -type VM -SmartUpdate | out-null
    #Write-GreenCheck "Restore complete"


    if ($missingVMS.Count -gt 0) {
        #Write-Host
        #$response2 = Read-Host2 -Prompt "The following VM's do not have checkpoints. [$($missingVMs -join ",")]  Delete them? (y/N)" -HideHelp
        if ($DeleteVMs -and ($DeleteVMs.ToLowerInvariant() -eq "y" -or $DeleteVMs.ToLowerInvariant() -eq "yes")) {
            foreach ($item in $missingVMS) {
                Remove-VirtualMachine -VmName $item
            }
            New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
            New-MRemoteNGFileFromHyperV -MRemoteNGFile $Global:Common.MRemoteNGFilePath
            Restore-TerminalFocus
        }

    }
    #write-host
    #Write-GreenCheck "$domain has been Restored!"
    Select-StartDomain -domain $domain -response $startAll
}