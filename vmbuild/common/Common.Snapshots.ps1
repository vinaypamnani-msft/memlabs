############################
### SnapShot Functions ###
############################
#Common.Snapshots.ps1

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
                                Remove-Item $notesFile -Force
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
    Write-Host2 -ForegroundColor Orange "It is reccommended to stop Critical VM's before snapshotting. Please select which VM's to stop."
    #Invoke-StopVMs -domain $domain
    $result = Select-StopDomain -domain $domain -AllSelected
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
        $DeleteVMs = Read-Host2 -Prompt "The following VM's do not have checkpoints. [$($missingVMs -join ",")]  Delete them? (y/N)" -HideHelp
    }

    if ($auto -and $snapshots.Count -eq 1) {
        $startAll = "A"
    }
    else {
        $startAll = Read-YesorNoWithTimeout -Prompt "Start All VMs after restore? (Y/n)" -HideHelp -Default "y"
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