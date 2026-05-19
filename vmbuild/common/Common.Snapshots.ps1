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
        stops VMs, removes the checkpoints (triggering AVHDX merge), waits
        for merges to settle, then restarts VMs in correct order.
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

    Write-Log "[Phase 11] Found Phase 8 auto-snapshot on $($vmsWithSnapshot.Count) VM(s); merging..." -Activity

    # Get critical server list for ordered restart
    $nodes = $vms | ForEach-Object { $_.vmName }
    $critList = Get-CriticalVMs -domain $domain -vmNames $nodes

    # Stop all VMs in domain
    Write-Log "[Phase 11] Stopping VMs for snapshot merge"
    Invoke-StopVMs -domain $domain -quiet:$true

    # Remove the Phase 8 auto-snapshot from each VM
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

    # Wait for AVHDX merges to settle (simplified version of Compact-Disks settle loop)
    $settleTimeoutMin = 30
    $mergeDeadline = (Get-Date).AddMinutes($settleTimeoutMin)
    Write-Log "[Phase 11] Waiting for AVHDX merges to settle (max $settleTimeoutMin min)..."

    $allSettled = $false
    while ((Get-Date) -lt $mergeDeadline) {
        $pendingCount = 0
        foreach ($entry in $vmsWithSnapshot) {
            $hds = @(Get-VMHardDiskDrive -VMName $entry.VMName -ErrorAction SilentlyContinue)
            $avhdx = @($hds | Where-Object { $_.Path -and $_.Path -match '\.avhdx?$' })
            $chks = @(Get-VMCheckpoint -VMName $entry.VMName -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $snapshotPattern })
            $pendingCount += $avhdx.Count + $chks.Count
        }

        if ($pendingCount -eq 0) {
            $allSettled = $true
            break
        }

        Start-Sleep -Seconds 5
    }

    if ($allSettled) {
        Write-Log "[Phase 11] All AVHDX merges settled successfully" -Success
    }
    else {
        Write-Log "[Phase 11] AVHDX merge settle timed out after $settleTimeoutMin min; VMs may still be merging in background" -Warning
    }

    # Restart VMs in correct order
    Write-Log "[Phase 11] Restarting VMs after snapshot merge"
    $startFailures = Invoke-SmartStartVMs -CritList $critList
    if ($startFailures -ne 0) {
        Write-Log "[Phase 11] $startFailures VM(s) could not be restarted" -Warning
    }

    if ($mergeFailures -eq 0) {
        Write-Log "[Phase 11] Phase 8 auto-snapshot merge completed successfully" -Success
    }
    else {
        Write-Log "[Phase 11] Phase 8 auto-snapshot merge completed with $mergeFailures failure(s)" -Warning
    }
}

function Invoke-AutoSnapShotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain,
        [Parameter(Mandatory = $true, HelpMessage = "Snapshot name (Must Contain MemLabs)")]
        [string] $comment
    )

    #Get Critical Server list.  These VM's should be stopped before snapshot
    $critlist = Get-CriticalVMs -domain $deployConfig.vmOptions.domainName -vmNames $nodes

    #Stop all VMs in Domain
    Invoke-StopVMs -domain $domain -quiet:$true

    #Take Snapshot
    $failures = Invoke-SnapshotDomain -domain $domain -comment $comment -quiet:$true
    if ($failures -ne 0) {
        write-log "$failures VM(s) could not be snapshotted" -Failure
    }

    #Start VMs in correct order
    $failures = Invoke-SmartStartVMs -CritList $critlist
    if ($failures -ne 0) {
        write-log "$failures VM(s) could not be started" -Failure
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
    $result = Select-StopDomain -domain $domain -AllSelected
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
                    $checkPoint | Restore-VMCheckpoint -Confirm:$false
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
        }

    }
    #write-host
    #Write-GreenCheck "$domain has been Restored!"
    Select-StartDomain -domain $domain -response $startAll
}