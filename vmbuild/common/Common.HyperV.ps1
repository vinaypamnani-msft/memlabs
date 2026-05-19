function Install-HyperV {
    # Cache the Hyper-V feature state — Get-WindowsFeature is a CIM call via
    # ServerManager that shows "Collecting data..." and can stall for minutes.
    # Once Hyper-V is installed it stays installed; only re-check once per 24 hours.
    $hvCacheFile = Join-Path $Common.CachePath "hyperv-feature-state.json"
    $hvInstalled = $false
    if (Test-Path $hvCacheFile) {
        try {
            $hvCache = Get-Content $hvCacheFile -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($hvCache -and $hvCache.Installed -eq $true) {
                $hvAge = ((Get-Date) - [DateTime]::Parse($hvCache.CheckedUtc)).TotalHours
                if ($hvAge -le 24) {
                    $hvInstalled = $true
                    Write-Log "Install-HyperV: Hyper-V already installed (cached, age=$([Math]::Round($hvAge,1))h)." -LogOnly
                }
            }
        }
        catch {}
    }
    if (-not $hvInstalled) {
        Write-Log "Install-HyperV: Calling Get-WindowsFeature Hyper-V (CIM — may be slow)..." -LogOnly
        if ((Get-WindowsFeature -Name Hyper-V).InstallState -ne 'Installed') {

            Install-WindowsFeature -Name 'Hyper-V', 'Hyper-V-Tools', 'Hyper-V-PowerShell' -IncludeAllSubFeature -IncludeManagementTools

            Install-WindowsFeature -Name 'DHCP', 'RSAT-DHCP' -IncludeAllSubFeature -IncludeManagementTools

            if ((Get-WindowsFeature -Name Hyper-V).InstallState -eq 'Installed') {
                Write-Log "Hyper-V and management tools installed successfully." -Success
            }
            else {
                Write-Log "Failed to install Hyper-V and management tools." -Failure
            }
        }
        # Cache the result (installed)
        try {
            [PSCustomObject]@{
                CheckedUtc = (Get-Date).ToUniversalTime().ToString("o")
                Installed  = $true
            } | ConvertTo-Json | Set-Content -Path $hvCacheFile -Encoding UTF8
        }
        catch {}
    }

    if ((get-service -name vmms).Status -ne "Running") {
        Start-Service vmms
        if ((get-service -name vmms).Status -eq "Running") {
            Write-Log "Hyper-V Virtual Machine Management Service started successfully." -Success
        }
        else {
            Write-Log "Failed to start Hyper-V Virtual Machine Management Service." -Failure
        }
    }
}

function Get-VM2 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Fallback
    )

    $vmFromList = Get-List -Type VM | Where-Object { $_.vmName -eq $Name }

    if ($vmFromList) {
        return (Get-VM -Id $vmFromList.vmId)
    }
    else {
        $vmFromList = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $Name }
        if ($vmFromList) {
            return (Get-VM -Id $vmFromList.vmId)
        }
        else {
            # VM may exist, without vmNotes object, try fallback if caller explicitly wants it.
            if ($Fallback.IsPresent) {
                return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
            }

            return [System.Management.Automation.Internal.AutomationNull]::Value
        }
    }
}

function Get-VMSwitch2 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$NetworkName
    )

    return (Get-VMSwitch -SwitchType Internal | Where-Object { $_.Name -like "*$NetworkName*" })
}

function Remove-VMSwitch2 {
    param (
        [Parameter(Mandatory = $true)]
        [string] $NetworkName,
        [Parameter()]
        [switch] $WhatIf
    )
    try {
        $switch = Get-VMSwitch2 -NetworkName $NetworkName
        if ($switch) {
            Write-Log "Hyper-V VM Switch '$($switch.Name)' exists. Removing." -SubActivity
            $switch | Remove-VMSwitch -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }
    }
    catch {
        # We tried..
    }
}

# Clear-StrayVhdMounts
#
# Walks every disk on the host whose backing Location ends in
# .vhd / .vhdx / .avhdx and dismounts any that no current VM owns. This
# catches "ghost" host mounts left behind when something (typically the
# Compact-Disks worker) mounted an .avhdx leaf that Hyper-V then merged
# away in the background - the AVHDX file is gone but the host's storage
# subsystem still has the chain wired up, which locks the parent VHDX
# and breaks Start-VM with "The process cannot access the file because
# it is being used by another process." (0x80070020).
#
# Dismount-VHD -Path can't fix that because it does a Test-Path on the
# path first and silently fails for ghosts. -DiskNumber operates on the
# storage subsystem directly and works regardless of whether the
# backing file still exists.
#
# Safe to call any time: an attached VHD that IS owned by a VM is
# skipped, so we never disturb a running VM.
function Clear-StrayVhdMounts {
    [CmdletBinding()]
    param(
        # Optional VM name. If supplied, the function will only consider
        # ghosts whose Location filename root matches this VM's name.
        # Stays defensive: if the match fails we fall back to the full
        # host-wide sweep behaviour.
        [Parameter(Mandatory = $false)]
        [string]$VMName
    )
    try {
        $vmOwned = @{}
        foreach ($hd in (Get-VM -ErrorAction SilentlyContinue | Get-VMHardDiskDrive -ErrorAction SilentlyContinue)) {
            if ($hd.Path) { $vmOwned[$hd.Path.ToLowerInvariant()] = $true }
        }
        $stray = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object {
            $_.Location -and ($_.Location -match '\.a?vhdx?$')
        })
        $count = 0
        foreach ($s in $stray) {
            $loc = $s.Location
            if ($vmOwned.ContainsKey($loc.ToLowerInvariant())) { continue }
            if ($VMName) {
                # Ignore ghosts that don't look like they belong to this VM.
                # Filename pattern: <VMName>_<role>[_<GUID>].avhdx|.vhdx
                $leaf = [System.IO.Path]::GetFileName($loc)
                if ($leaf -notlike "$VMName*") { continue }
            }
            try {
                Dismount-VHD -DiskNumber $s.Number -ErrorAction Stop
                $count++
                try { Write-Log "Clear-StrayVhdMounts: dismounted stray (disk #$($s.Number)): $loc" -LogOnly } catch {}
            } catch {
                try { Write-Log "Clear-StrayVhdMounts: failed to dismount disk #$($s.Number) ($loc): $($_.Exception.Message)" -Warning } catch {}
            }
        }
        return $count
    } catch {
        try { Write-Log "Clear-StrayVhdMounts: sweep failed: $($_.Exception.Message)" -Warning } catch {}
        return 0
    }
}

function Start-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Passthru,
        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 1,
        [Parameter(Mandatory = $false)]
        [int]$RetrySeconds = 60
    )

    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'SilentlyContinue'
    $vmLockMx = $null
    $vmLockHeld = $false
    try {
        # Per-VM cross-process lock. If Compact-Disks (or another MemLabs
        # operation that honors MemLabs_VM_<name>) is currently working
        # on this VM - merging checkpoints, mounting the VHDX for offline
        # cleanup, running Optimize-VHD - starting the VM right now would
        # either fail with 0x80070020 file-in-use, or worse, cause the
        # other tool to dismount the VHDX out from under us. Try briefly
        # then bail with a clear error rather than silently waiting.
        try {
            $vmLockMx = [System.Threading.Mutex]::new($false, "MemLabs_VM_$Name")
            try { $vmLockHeld = $vmLockMx.WaitOne([TimeSpan]::FromSeconds(5)) }
            catch [System.Threading.AbandonedMutexException] { $vmLockHeld = $true }
            if (-not $vmLockHeld) {
                Write-Log "${Name}: another MemLabs operation holds the VM lock (MemLabs_VM_$Name); refusing to start VM. Wait for the other operation (e.g. Compact-Disks) to finish and retry." -Warning
                try { $vmLockMx.Dispose() } catch {}
                $vmLockMx = $null
                if ($Passthru) { return $false }
                return
            }
        } catch {
            # If the mutex object itself can't be created (extremely rare),
            # log it and continue without the lock - we can't make this a
            # hard failure or the host would become unable to start VMs.
            try { Write-Log "${Name}: failed to acquire VM lock object: $($_.Exception.Message); proceeding without it" -Warning } catch {}
            $vmLockMx = $null
            $vmLockHeld = $false
        }

        $vm = Get-VM2 -Name $Name -Fallback

        if ($vm.State -eq "Running") {
            Write-Log "${Name}: VM is already running." -LogOnly
            if ($Passthru) {
                return $true
            }
            return
        }

        if ($vm) {
            $i = 0
            $running = $false
            do {
                $i++
                if ($i -gt 1) {
                    write-progress2 "Start VM" -Status "Retry Start VM $Name"  -force
                    Start-Sleep -Seconds $RetrySeconds
                }
                else {
                    write-progress2 "Start VM" -Status "Starting VM $Name"  -force
                }
                $StopError = $null
                Start-VM -VM $vm -ErrorVariable StopError -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                if (($StopError -ne $null) -and ($StopError.Exception.Message.contains("authentication tag"))) {
                    write-progress2 "Start VM" -Status "Removing saved state for $Name"  -force
                    try {
                        Remove-VMSavedState -vm $vm -ErrorAction Stop
                    }
                    catch {
                        start-sleep -seconds 3
                        Remove-VMSavedState -vm $vm -ErrorAction SilentlyContinue 

                        stop-vm -vm $vm -TurnOff -force:$true -WarningAction SilentlyContinue   
                        start-sleep -seconds 3
                        Remove-VMSavedState -vm $vm -ErrorAction SilentlyContinue 
                    }                                        
                    Start-VM -VM $vm -ErrorVariable StopError -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
                # Broad self-heal: any non-empty $StopError after the
                # auth-tag handler ran. Most commonly caused by a ghost
                # host VHD mount (left behind when a tool mounted an
                # .avhdx leaf that Hyper-V later merged away in the
                # background, OR by a previous PowerShell process
                # crashing mid-merge while it had a host mount on a
                # soon-to-be-deleted AVHDX). Other Hyper-V "VM didn't
                # start" failure modes also occasionally clear after
                # the storage subsystem is poked, so we do this for
                # ANY Start-VM error rather than gating on a specific
                # message - if there's nothing to clean up,
                # Clear-StrayVhdMounts is a no-op and we just don't
                # retry. The previous narrow message-match missed
                # localized error strings on non-English hosts and
                # wrapped exceptions.
                if (($StopError -ne $null) -and ($vm.State -ne 'Running')) {
                    $isFileInUse = ($StopError.Exception.Message -match 'being used by another process') -or
                                   ($StopError.Exception.Message -match '0x80070020')
                    $reason = if ($isFileInUse) { "file-in-use" } else { "Start-VM failed: $($StopError.Exception.Message)" }
                    write-progress2 "Start VM" -Status "Sweeping stray host mounts for $Name ($reason)" -force
                    try { Write-Log "${Name}: Start-VM failed ($reason); running Clear-StrayVhdMounts before retry" -LogOnly } catch {}
                    $cleared = Clear-StrayVhdMounts -VMName $Name
                    if ($cleared -gt 0) {
                        try { Write-Log "${Name}: cleared $cleared stray host mount(s); retrying Start-VM" -LogOnly } catch {}
                        $StopError = $null
                        Start-VM -VM $vm -ErrorVariable StopError -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    }
                    elseif ($isFileInUse) {
                        # No ghosts to clear, but error explicitly says
                        # the file is locked. The lock is held by something
                        # we can't fix from here (vmms internal handle,
                        # antivirus, etc.) - log the diagnostic and let
                        # the outer retry loop give it another try.
                        try { Write-Log "${Name}: file-in-use error but Clear-StrayVhdMounts found nothing to clear; lock is held externally" -Warning } catch {}
                    }
                }
                $vm = Get-VM2 -Name $Name -Fallback
                if ($vm.State -eq "Running") {
                    $running = $true
                }
            }

            until ($i -gt $retryCount -or $running)

            if ($running) {
                # Invalidate the Get-List cache so the next SmartUpdate
                # sees the updated state without waiting for the throttle.
                $global:vm_List_LastUpdate = $null
                Write-Log "${Name}: VM was started." -LogOnly
                if ($Passthru.IsPresent) {
                    return $true
                }
            }

            if ($StopError.Count -ne 0) {
                Write-Log "${Name}: Failed to start the VM. $StopError" -Warning
                if ($Passthru.IsPresent) {
                    return $false
                }
            }
            else {
                $vm = Get-VM2 -Name $Name -Fallback
                if ($vm.State -eq "Running") {
                    Write-Log "${Name}: VM was started." -LogOnly
                    if ($Passthru.IsPresent) {
                        return $true
                    }
                }
                else {
                    Write-Log "${Name}: VM was not started. Current State $($vm.State)" -Warning
                    if ($Passthru.IsPresent) {
                        return $false
                    }
                }
            }
        }
        else {
            Write-Log "$Name`: VM was not found in Hyper-V." -Warning
            if ($Passthru.IsPresent) {
                return $false
            }
        }
    }
    catch {
        Write-Exception -ExceptionInfo $_
    }
    finally {
        write-progress2 "Start VM" -Status "Started VM $Name" -force -Completed
        $Global:ProgressPreference = $OriginalProgressPreference
        if ($vmLockMx) {
            if ($vmLockHeld) { try { $vmLockMx.ReleaseMutex() } catch {} }
            try { $vmLockMx.Dispose() } catch {}
        }
    }
}
function Test-VmResponsive {
    param(
        [string]$VmName,
        [int]$TimeoutSeconds = 30
    )
    
    try {
        # Check if VM is running
        $vm = Get-VM2 -Name $VmName -ErrorAction Stop
        if ($vm.State -ne 'Running') {
            Write-Log "VM $VmName is not running (State: $($vm.State))" -Warning
            return $false
        }
        
        # Test heartbeat integration service
        $heartbeat = $vm | Get-VMIntegrationService | Where-Object { $_.Name -eq 'Heartbeat' }
        if ($heartbeat -and $heartbeat.Enabled -and $heartbeat.PrimaryStatusDescription -ne 'OK') {
            Write-Log "VM $VmName heartbeat status: $($heartbeat.PrimaryStatusDescription)" -Warning
            return $false
        }
        
        # Test basic ping with timeout
        $pingTest = Test-Connection -ComputerName $VmName -Count 2 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingTest) {
            Write-Log "VM $VmName not responding to ping" -Warning
            return $false
        }
        
        # Test RDP port with timeout using job
        $job = Start-Job -ScriptBlock {
            param($computerName)
            Test-NetConnection -ComputerName $computerName -Port 3389 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationLevel Quiet
        } -ArgumentList $VmName
        
        $testNet = Wait-Job -Job $job -Timeout $TimeoutSeconds | Receive-Job
        Remove-Job -Job $job -Force
        
        if ($null -eq $testNet -or -not $testNet) {
            Write-Log "VM $VmName RDP port test failed or timed out" -Warning
            return $false
        }
        
        return $true
    }
    catch {
        Write-Log "Error testing VM $VmName responsiveness: $_" -Warning
        return $false
    }
}

function Restart-UnresponsiveVm {
    param(
        [string]$VmName,
        [int]$MaxRetries = 2,
        [int]$WaitTimeSeconds = 60
    )
    
    Write-Log "Attempting to restart unresponsive VM: $VmName" -Warning
    
    try {
        # Try graceful shutdown first
        Write-Log "Attempting graceful shutdown of $VmName..."
        Stop-VM2 -Name $VmName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Start-Sleep -Seconds 10
        
        # Force stop if still running
        $vm = Get-VM2 -Name $VmName
        if ($vm.State -ne 'Off') {
            Write-Log "Forcing stop of $VmName..."
            Stop-VM2 -Name $VmName -Force -TurnOff
            Start-Sleep -Seconds 5
        }
        
        # Start the VM
        Write-Log "Starting $VmName..."
        Start-VM2 -Name $VmName
        
        # Wait for VM to boot and become responsive
        Write-Log "Waiting for $VmName to become responsive (up to $WaitTimeSeconds seconds)..."
        $startTime = Get-Date
        $isResponsive = $false
        
        while (((Get-Date) - $startTime).TotalSeconds -lt $WaitTimeSeconds) {
            Start-Sleep -Seconds 10
            
            if (Test-VmResponsive -VmName $VmName -TimeoutSeconds 15) {
                $isResponsive = $true
                Write-Log "$VmName is now responsive"
                break
            }
            
            Write-Log "Still waiting for $VmName to respond..."
        }
        
        return $isResponsive
    }
    catch {
        Write-Log "Error restarting VM ${VmName}: $_" -Error
        return $false
    }
}

function Stop-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Passthru,
        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 1,
        [Parameter(Mandatory = $false)]
        [int]$RetrySeconds = 10,
        [Parameter(Mandatory = $false)]
        [switch]$TurnOff
    )

    try {
        $force = $true
        $vm = Get-VM2 -Name $Name -Fallback

        if ($vm.State -eq "Off") {
            Write-Log "${Name}: VM is already stopped." -LogOnly
            if ($Passthru) {
                return $true
            }
            return
        }

        Write-Log "${Name}: Stopping VM" -LogOnly

        if ($vm) {
            $i = 0
            if ($TurnOff) {
                Stop-VM -VM $vm -TurnOff -force:$force -WarningAction SilentlyContinue
                start-sleep -seconds 5
            }
            do {
                $i++
                if ($i -gt 1) {
                    Start-Sleep -Seconds $RetrySeconds
                }
                Stop-VM -VM $vm -force:$force -ErrorVariable StopError -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            }
            until ($i -gt $retryCount -or $StopError.Count -eq 0)

            if ($StopError.Count -ne 0) {
                
                Stop-VM -VM $vm -TurnOff -force:$true -WarningAction SilentlyContinue
                Start-Sleep -Seconds $RetrySeconds
                $vm = Get-VM2 -Name $Name -Fallback
                if ($vm.State -eq "Off") {
                    return $true
                }
                
                Write-Log "${Name}: Failed to stop the VM. $StopError" -Warning
                
                if ($Passthru.IsPresent) {
                    return $false
                }
            }
            else {
                if ($Passthru.IsPresent) {
                    return $true
                }
            }
        }
        else {
            if ($Passthru.IsPresent) {
                Write-Log "$Name`: VM was not found in Hyper-V." -Warning
                return $false
            }
        }
    }
    catch {
        if ($Passthru) {
            Write-Log "$Name`: Exception stopping VM $_" -Failure
            return $false
        }
        else {
            Write-Log "$Name`: Exception stopping VM $_" -Failure -LogOnly
        }
    }
}


function Get-VMCheckpoint2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $false)]
        [string]$Name
    )

    $vm = Get-VM2 -Name $VMName -Fallback

    if ($vm) {
        if ($name) {
            return Get-VMCheckpoint -VM $vm -Name $Name -ErrorAction SilentlyContinue
        }
        else {
            return Get-VMCheckpoint -VM $vm  -ErrorAction SilentlyContinue
        }
    }
    return [System.Management.Automation.Internal.AutomationNull]::Value
}

function Remove-VMCheckpoint2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $vm = Get-VM2 -Name $VMName -Fallback

    if ($vm) {
        return Remove-VMCheckpoint -VM $vm -Name $Name -ErrorAction SilentlyContinue
    }
    return [System.Management.Automation.Internal.AutomationNull]::Value
}

function Get-VMCheckpointMergeRequirements {
    <#
    .SYNOPSIS
        Returns the per-drive disk space requirements to merge a VM's
        checkpoint chain. Pure data, no free-space check.

    .OUTPUTS
        PSCustomObject with: VMName, ByDrive (hashtable: drive letter ->
        @{ AvhdxBytes; Files (paths); Parents (@{Path;Max}) }).
    #>
    [CmdletBinding()]
    param ( [Parameter(Mandatory = $true)] [string]$VMName )

    $byDrive = @{}
    try {
        $hds = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop)
    } catch {
        return [PSCustomObject]@{ VMName = $VMName; ByDrive = $byDrive; Error = $_.Exception.Message }
    }
    foreach ($hd in $hds) {
        if (-not $hd.Path) { continue }
        $cur = $null
        try { $cur = Get-VHD -Path $hd.Path -ErrorAction Stop } catch { continue }
        $avhdxBytes = 0L
        $avhdxFiles = @()
        while ($cur -and $cur.ParentPath) {
            if ($cur.Path -match '\.avhdx?$') {
                try { $avhdxBytes += ([System.IO.FileInfo]::new($cur.Path)).Length } catch {}
                $avhdxFiles += $cur.Path
            }
            try { $cur = Get-VHD -Path $cur.ParentPath -ErrorAction Stop } catch { $cur = $null }
        }
        if (-not $cur) { continue }
        if ($avhdxBytes -le 0) { continue }
        $parentPath = $cur.Path
        $drive = $null
        try { $drive = [System.IO.Path]::GetPathRoot($parentPath).TrimEnd('\') } catch {}
        if (-not $drive) { continue }
        if (-not $byDrive.ContainsKey($drive)) {
            $byDrive[$drive] = @{ AvhdxBytes = 0L; Files = @(); Parents = @() }
        }
        $byDrive[$drive].AvhdxBytes += $avhdxBytes
        $byDrive[$drive].Files      += $avhdxFiles
        $byDrive[$drive].Parents    += @{ Path = $parentPath; Max = [long]$cur.Size }
    }
    return [PSCustomObject]@{ VMName = $VMName; ByDrive = $byDrive }
}

function Get-DriveFreeBytes {
    param([Parameter(Mandatory = $true)][string]$Drive)
    try {
        $vol = Get-Volume -DriveLetter $Drive[0] -ErrorAction Stop
        return [long]$vol.SizeRemaining
    } catch {
        try {
            $di = New-Object System.IO.DriveInfo($Drive + '\')
            return [long]$di.AvailableFreeSpace
        } catch { return 0L }
    }
}

function Test-VMCheckpointMergeFreeSpace {
    <#
    .SYNOPSIS
        Confirms the host has enough free disk space to merge a VM's checkpoint
        chain into its parent VHDX(s) without hanging / corrupting the VM.

    .DESCRIPTION
        Hyper-V merges by writing the differencing AVHDX blocks back into the
        parent VHDX. If the destination volume runs out of space mid-merge, the
        operation stalls indefinitely and the VHDX chain can be left in a state
        the VM cannot boot from.

        Per attached drive, this groups every AVHDX in the chain by the volume
        their parent VHDX lives on, sums the AVHDX file sizes (incl. nested
        differencing chains), and confirms that drive has at least
        (sum * SafetyFactor) bytes free.

    .OUTPUTS
        PSCustomObject with: Ok (bool), VMName, Details (per-drive results),
        Reason (string, populated on Ok=$false).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$VMName,
        # Margin above the raw AVHDX bytes. Merge typically inflates the parent
        # by approximately the AVHDX size, but the parent can also grow
        # towards its MaxInternalSize. 1.2x covers metadata + small headroom.
        [double]$SafetyFactor = 1.20,
        # Absolute minimum free space we require on any involved drive, even
        # if the AVHDX chain is tiny. Defaults to 5 GB.
        [long]$MinFreeBytes = 5GB
    )

    $req = Get-VMCheckpointMergeRequirements -VMName $VMName
    $result = [PSCustomObject]@{
        Ok      = $true
        VMName  = $VMName
        Reason  = $null
        Details = @()
    }
    if ($req.PSObject.Properties['Error'] -and $req.Error) {
        $result.Ok = $false
        $result.Reason = "Get-VMHardDiskDrive failed: $($req.Error)"
        return $result
    }
    if ($req.ByDrive.Count -eq 0) { return $result }

    foreach ($drive in $req.ByDrive.Keys) {
        $needRaw = [long]$req.ByDrive[$drive].AvhdxBytes
        $needed  = [long][Math]::Max($MinFreeBytes, [Math]::Ceiling($needRaw * $SafetyFactor))
        $free    = Get-DriveFreeBytes -Drive $drive
        $detail = [PSCustomObject]@{
            Drive      = $drive
            Required   = $needed
            RawAvhdx   = $needRaw
            Available  = $free
            Ok         = ($free -ge $needed)
            AvhdxFiles = $req.ByDrive[$drive].Files
        }
        $result.Details += $detail
        if (-not $detail.Ok) { $result.Ok = $false }
    }

    if (-not $result.Ok) {
        $msgs = foreach ($d in $result.Details | Where-Object { -not $_.Ok }) {
            '{0} needs {1:N1} GB free (AVHDX={2:N1} GB, factor={3}), only {4:N1} GB available' -f `
                $d.Drive, ($d.Required / 1GB), ($d.RawAvhdx / 1GB), $SafetyFactor, ($d.Available / 1GB)
        }
        $result.Reason = ($msgs -join '; ')
    }

    return $result
}

function Resolve-VMCheckpointMergePlan {
    <#
    .SYNOPSIS
        Plans concurrent merges across multiple VMs to avoid disk-full hangs.

    .DESCRIPTION
        Given a set of VM names, computes:
          - Per-drive: total AVHDX bytes required across all VMs, the largest
            single VM's bytes, and currently available free space.
          - Drive classification:
              * Parallel: sum*SafetyFactor + MinFree fits in available -> OK to
                merge all VMs in parallel.
              * Serialize: sum doesn't fit but largest single VM does -> the
                drive must be merge-serialized (one VM at a time).
              * Fail: largest single VM still doesn't fit -> no amount of
                serialization helps; that VM cannot be merged safely.

    .OUTPUTS
        PSCustomObject with:
          VMs (array of per-VM requirement objects),
          Drives (per-drive plan: Drive, AvhdxTotal, AvhdxMax, Available,
                  Required, RequiredMax, Classification, FailingVMs),
          SerializeDrives (string[]),
          FailingVMs (string[]),
          Ok (bool - false if any FailingVMs).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string[]]$VMNames,
        [double]$SafetyFactor = 1.20,
        [long]$MinFreeBytes = 5GB
    )

    $vmReqs = @()
    foreach ($n in $VMNames) {
        $vmReqs += Get-VMCheckpointMergeRequirements -VMName $n
    }

    # Aggregate per drive: total, max-single-VM, list-of-VMs-touching-it
    $drives = @{}
    foreach ($r in $vmReqs) {
        foreach ($drv in $r.ByDrive.Keys) {
            $bytes = [long]$r.ByDrive[$drv].AvhdxBytes
            if (-not $drives.ContainsKey($drv)) {
                $drives[$drv] = @{ Total = 0L; Max = 0L; VMs = @() }
            }
            $drives[$drv].Total += $bytes
            if ($bytes -gt $drives[$drv].Max) { $drives[$drv].Max = $bytes }
            $drives[$drv].VMs   += [PSCustomObject]@{ VMName = $r.VMName; Bytes = $bytes }
        }
    }

    $plan = [PSCustomObject]@{
        VMs             = $vmReqs
        Drives          = @()
        SerializeDrives = @()
        FailingVMs      = @()
        Ok              = $true
    }

    foreach ($drv in $drives.Keys) {
        $free  = Get-DriveFreeBytes -Drive $drv
        $reqT  = [long][Math]::Max($MinFreeBytes, [Math]::Ceiling($drives[$drv].Total * $SafetyFactor))
        $reqM  = [long][Math]::Max($MinFreeBytes, [Math]::Ceiling($drives[$drv].Max   * $SafetyFactor))
        $cls   = if ($free -ge $reqT) { 'Parallel' }
                 elseif ($free -ge $reqM) { 'Serialize' }
                 else { 'Fail' }
        $failingVMs = @()
        if ($cls -eq 'Fail') {
            foreach ($v in $drives[$drv].VMs) {
                $vmReqBytes = [long][Math]::Max($MinFreeBytes, [Math]::Ceiling($v.Bytes * $SafetyFactor))
                if ($vmReqBytes -gt $free) { $failingVMs += $v.VMName }
            }
            if ($failingVMs.Count -eq 0) {
                # Defensive: every VM individually fits but at least one combined
                # group exceeds; serialize instead of failing.
                $cls = 'Serialize'
            }
        }
        $plan.Drives += [PSCustomObject]@{
            Drive          = $drv
            AvhdxTotal     = [long]$drives[$drv].Total
            AvhdxMax       = [long]$drives[$drv].Max
            Available      = $free
            Required       = $reqT
            RequiredMax    = $reqM
            Classification = $cls
            VMs            = $drives[$drv].VMs
            FailingVMs     = $failingVMs
        }
        if ($cls -eq 'Serialize') { $plan.SerializeDrives += $drv }
        if ($cls -eq 'Fail') {
            $plan.Ok = $false
            foreach ($v in $failingVMs) {
                if ($plan.FailingVMs -notcontains $v) { $plan.FailingVMs += $v }
            }
        }
    }
    return $plan
}


function Checkpoint-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$SnapshotName
    )

    $vm = Get-VM2 -Name $Name -Fallback

    if ($vm) {
        $json = $SnapshotName + ".json"
        $notesFile = Join-Path ($vm).Path $json
        $vm.notes | Out-File $notesFile
        try {
            Checkpoint-VM -VM $vm -SnapshotName $SnapshotName -ErrorAction Stop
        }
        catch {
            start-sleep -Seconds 20
            $snapshots = Get-VMSnapshot -VM $vm
            foreach ($snapshot in $snapshots) {
                if ($snapshot.Name -eq $SnapshotName) {
                    return [System.Management.Automation.Internal.AutomationNull]::Value
                }
            }
            throw
        }
    }
    return [System.Management.Automation.Internal.AutomationNull]::Value
}