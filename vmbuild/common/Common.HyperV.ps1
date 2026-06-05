# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
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

    # In job workers (Start-Job = separate process), skip Get-List entirely.
    # Get-List's cold path does Get-VM + Get-VMNetworkAdapter -All to build
    # the full VM cache — with 20+ workers all doing this simultaneously,
    # the WMI calls serialize on vmms.exe and create a 10+ minute logjam.
    # A direct Get-VM -Name is a single targeted WMI call.
    if ($Common.InJob) {
        return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
    }

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
function Test-TcpPort {
    # Hard-timeout TCP probe using TcpClient + WaitHandle. Test-NetConnection can hang
    # well past its own timeouts (DNS reverse lookups, ICMP fallbacks, etc.), so avoid it.
    param(
        [Parameter(Mandatory)] [string]$ComputerName,
        [Parameter(Mandatory)] [int]$Port,
        [int]$TimeoutMs = 3000,
        [int]$Retries = 3,
        [int]$RetryDelayMs = 1000
    )
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $client = $null
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                try {
                    $client.EndConnect($iar)
                    if ($client.Connected) { return $true }
                }
                catch { }
            }
        }
        catch { }
        finally {
            if ($client) { try { $client.Close() } catch { } }
        }
        if ($attempt -lt $Retries) { Start-Sleep -Milliseconds $RetryDelayMs }
    }
    return $false
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
        
        # Test RDP port with hard timeout + retry (Test-NetConnection can hang indefinitely)
        $tcpTimeoutMs = [Math]::Max(1000, $TimeoutSeconds * 1000 / 3)
        if (-not (Test-TcpPort -ComputerName $VmName -Port 3389 -TimeoutMs $tcpTimeoutMs -Retries 3 -RetryDelayMs 1000)) {
            Write-Log "VM $VmName RDP port test failed after retries" -Warning
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
    
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Log "Attempting to restart unresponsive VM: $VmName (attempt $attempt of $MaxRetries)" -Warning
        
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
            
            while (((Get-Date) - $startTime).TotalSeconds -lt $WaitTimeSeconds) {
                Start-Sleep -Seconds 10
                
                if (Test-VmResponsive -VmName $VmName -TimeoutSeconds 15) {
                    Write-Log "$VmName is now responsive"
                    return $true
                }
                
                Write-Log "Still waiting for $VmName to respond..."
            }
            
            Write-Log "VM $VmName did not become responsive within $WaitTimeSeconds seconds" -Warning
        }
        catch {
            Write-Log "Error restarting VM ${VmName}: $_" -Error
        }
    }
    
    Write-Log "VM $VmName failed to become responsive after $MaxRetries attempts" -Error
    return $false
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

        # Proactively invalidate the PSDirect session cache for this VM.
        # After a stop/restart cycle the session will be broken, and the
        # credential that last worked (e.g. local in Phase 1) may no
        # longer be valid (e.g. VM is now domain-joined after Phase 2).
        # Clearing here avoids a 30s timeout trying stale credentials on
        # the next Get-VmSession call.
        if ($global:ps_cache) {
            foreach ($key in @($global:ps_cache.Keys)) {
                if ($key -like "$Name-*") {
                    if (Get-Command Remove-VmSession -ErrorAction SilentlyContinue) {
                        Remove-VmSession $global:ps_cache[$key]
                    } else {
                        try { Remove-PSSession $global:ps_cache[$key] -ErrorAction SilentlyContinue } catch {}
                    }
                    $global:ps_cache.Remove($key)
                }
            }
        }
        if ($global:ps_lastGoodCred) {
            $global:ps_lastGoodCred.Remove($Name)
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
            start-sleep -Seconds 10
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

function Restore-DynamicMemory {
    <#
    .SYNOPSIS
        Restores dynamic memory settings on all VMs after deployment completes.
    .DESCRIPTION
        During deployment, VMs run with dynamic memory but min pinned at 99% of max.
        This function lowers the min back to the configured dynamicMinRam value.
        Since dynamic memory is already enabled, this works on running VMs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$DeployConfig
    )

    $domain = $DeployConfig.vmOptions.domainName

    # Linux VMs are pinned static (no balloon driver dependency); skip them.
    $vmsToRestore = @($DeployConfig.virtualMachines | Where-Object {
        $_.dynamicMinRam -and ($_.dynamicMinRam / 1) -ne 0 -and (($_.dynamicMinRam / 1) -lt ($_.memory / 1)) -and -not (Test-VmIsLinux -Vm $_)
    })

    if ($vmsToRestore.Count -eq 0) {
        Write-Log "[Phase 11] No VMs have dynamic memory configured for domain '$domain'; skipping restore" -LogOnly
        return
    }

    # Drop VMs that no longer exist - typically rolled back by a failed/cancelled
    # Phase 1 (VM_Create removes its half-built VM on failure). Restoring memory
    # on a missing VM is a no-op and just generates noise.
    $missing = @($vmsToRestore | Where-Object { -not (Get-VM2 -Name $_.vmName -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        Write-Log "[Phase 11] Skipping $($missing.Count) VM(s) that no longer exist (likely rolled back by failed Phase 1): $($missing.vmName -join ', ')" -LogOnly
        $vmsToRestore = @($vmsToRestore | Where-Object { $_.vmName -notin $missing.vmName })
    }

    if ($vmsToRestore.Count -eq 0) {
        Write-Log "[Phase 11] No live VMs need dynamic memory restored for domain '$domain'; skipping" -LogOnly
        return
    }

    # Only now (after we know there's work) emit the visible Activity header.
    Write-Log "[Phase 11] Restoring dynamic memory settings for domain '$domain'..." -Activity
    Write-Log "[Phase 11] Restoring dynamic memory on $($vmsToRestore.Count) VM(s)..." -SubActivity

    # Per-VM work is a couple of Hyper-V cmdlet calls (Get-VM, Set-VMMemory).
    # No Common.ps1 dot-source needed. Just fan out via ThreadJob so 20 VMs
    # don't take 20*per-call time when called from the finally block. Throttle
    # at 8 to avoid hammering VMMS with too many concurrent reconfigs.
    $useThreadJob = (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue) -ne $null

    $restoreWorker = {
        param($vmConfig)
        $vmName = $vmConfig.vmName
        $messages = New-Object System.Collections.Generic.List[object]
        try {
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if (-not $vm) {
                $messages.Add(@{ Level = 'LogOnly'; Text = "[Phase 11]   $vmName`: VM not found, skipping (likely rolled back by failed Phase 1)" })
                return @{ VmName = $vmName; Messages = $messages }
            }

            $minBytes = ($vmConfig.dynamicMinRam / 1)
            $maxBytes = ($vmConfig.memory / 1)

            $priority = 25
            $buffer = 10
            $role = $vmConfig.role
            if ($vmConfig.SqlVersion -and $role -eq "DomainMember") { $role = "SqlServer" }
            if ($role -in ("DC", "SqlServer", "Primary", "SQLAO", "CAS")) {
                $priority = 50
                $buffer = 20
            }

            if ($vm.DynamicMemoryEnabled) {
                $messages.Add(@{ Level = 'LogOnly'; Text = "[Phase 11]   $vmName`: Lowering dynamic memory min to $($vmConfig.dynamicMinRam) / $($vmConfig.memory)" })
                $vm | Set-VMMemory -MinimumBytes $minBytes -MaximumBytes $maxBytes -StartupBytes $maxBytes -Priority $priority -Buffer $buffer -ErrorAction Stop
            }
            else {
                $wasRunning = $vm.State -eq 'Running'
                if ($wasRunning) {
                    $messages.Add(@{ Level = 'Warning'; Text = "[Phase 11]   $vmName`: Stopping VM (static memory, must stop to enable dynamic)" })
                    $vm | Stop-VM -Force -ErrorAction Stop
                }
                $vm | Set-VMMemory -DynamicMemoryEnabled $true -MinimumBytes $minBytes -MaximumBytes $maxBytes -StartupBytes $maxBytes -Priority $priority -Buffer $buffer -ErrorAction Stop
                if ($wasRunning) {
                    $vm | Start-VM -ErrorAction Stop
                    $messages.Add(@{ Level = 'LogOnly'; Text = "[Phase 11]   $vmName`: Restarted with dynamic memory" })
                }
            }
        }
        catch {
            $messages.Add(@{ Level = 'Warning'; Text = "[Phase 11]   $vmName`: Failed to restore dynamic memory: $_" })
        }
        return @{ VmName = $vmName; Messages = $messages }
    }

    if ($useThreadJob) {
        $jobs = foreach ($vmConfig in $vmsToRestore) {
            Start-ThreadJob -ScriptBlock $restoreWorker -ArgumentList $vmConfig -ThrottleLimit 8
        }
        $results = $jobs | Wait-Job | Receive-Job
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        foreach ($r in $results) {
            foreach ($m in $r.Messages) {
                switch ($m.Level) {
                    'Warning' { Write-Log $m.Text -Warning }
                    'LogOnly' { Write-Log $m.Text -LogOnly }
                    default   { Write-Log $m.Text }
                }
            }
        }
    }
    else {
        foreach ($vmConfig in $vmsToRestore) {
            $r = & $restoreWorker $vmConfig
            foreach ($m in $r.Messages) {
                switch ($m.Level) {
                    'Warning' { Write-Log $m.Text -Warning }
                    'LogOnly' { Write-Log $m.Text -LogOnly }
                    default   { Write-Log $m.Text }
                }
            }
        }
    }

    Write-Log "[Phase 11] Dynamic memory restore complete" -Success
}


# region Proxy enforcement (Phase 6) --------------------------------------
#
# Enforces "you must use the proxy" at the Hyper-V vSwitch layer via
# VMNetworkAdapter Extended ACLs. We deny outbound TCP 80/443 and outbound
# DNS (53/UDP+TCP) to any destination, then allow:
#   - intra-lab subnet (so AD/SMB/CM/SQL keep working)
#   - the Linux Proxy VM on TCP/3128
#   - the DC on UDP+TCP 53 (legit DNS path)
#
# Why port ACLs and not Windows Firewall on the host: with Hyper-V Internal +
# New-NetNat the host firewall sees post-NAT traffic (source = host) so it
# can't filter by originating VM. Port ACLs sit on the VM's vNIC pre-NAT and
# can match the VM as source. They survive VM reboots and are removed
# automatically when the VM is removed, so no cleanup hook is needed in
# Remove-Lab.
#
# Weight ordering: Hyper-V evaluates highest weight first. We pick the band
# 5000-5099 so we can wipe-and-replace only our own rules without touching
# anything else (currently nothing else in memlabs uses extended ACLs).

$global:MemLabsProxyAclWeightMin = 5000
$global:MemLabsProxyAclWeightMax = 5099

function Clear-VmProxyEnforcement {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$VmName
    )
    try {
        $existing = Get-VMNetworkAdapterExtendedAcl -VMName $VmName -ErrorAction SilentlyContinue
        if (-not $existing) { return }
        # Pipe filtered ACLs straight into Remove so each rule is removed by
        # full identity (Direction+Weight+RemoteIP+Protocol+Port). Removing
        # by Direction+Weight alone is ambiguous when several rules share a
        # weight (e.g. one Allow per lab subnet at weight 5099), and can
        # leave stragglers that then collide on re-add with 0x800700B7.
        $existing |
            Where-Object { $_.Weight -ge $global:MemLabsProxyAclWeightMin -and $_.Weight -le $global:MemLabsProxyAclWeightMax } |
            Remove-VMNetworkAdapterExtendedAcl -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "[Proxy] $VmName`: Failed to clear existing enforcement ACLs: $_" -Warning
    }
}

function Set-VmProxyEnforcement {
    <#
    .SYNOPSIS
        Apply Hyper-V port-ACL "must use proxy" enforcement to a Windows VM.

    .DESCRIPTION
        Adds extended ACLs on the VM's network adapter that allow ALL traffic
        to/from any known memlabs lab subnet (so AD, SMB, CM, SQL, and
        inter-domain hierarchy traffic stay native), then deny outbound
        TCP 80/443 and DNS (UDP+TCP 53) to anything else. Net effect: free
        movement inside the lab, but any attempt to reach the public
        Internet on web or DNS ports is blocked -- forcing HTTP/HTTPS
        through the Squid proxy.

        Idempotent: removes any prior memlabs proxy ACLs (weight band
        5000-5099) before re-adding.

    .PARAMETER VmName
        The Windows VM whose vNIC ACLs are being managed.

    .PARAMETER LabSubnets
        Array of /24 subnet base addresses (e.g. "192.168.1.0") covering
        every memlabs network the VM is allowed to reach freely. Typically
        produced by combining this deployConfig's vmOptions.network with
        the output of Get-NetworkList so cross-domain hierarchies still
        work.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$VmName,
        [Parameter(Mandatory = $true)] [string[]]$LabSubnets
    )

    # Normalize -> "x.y.z.0/24", dedupe.
    $cidrs = @($LabSubnets |
        Where-Object { $_ } |
        ForEach-Object {
            $s = $_.Trim()
            if ($s -match '/\d+$') { $s } else { "$s/24" }
        } |
        Select-Object -Unique)

    if (-not $cidrs -or $cidrs.Count -eq 0) {
        Write-Log "[Proxy] $VmName`: No lab subnets provided; skipping enforcement (would be wide-open deny)" -Warning
        return $false
    }

    Clear-VmProxyEnforcement -VmName $VmName

    # Helper: Add-VMNetworkAdapterExtendedAcl can return 0x800700B7 when an
    # identical rule somehow survived the clear (e.g. switch port settings
    # cached the rule across a clear/add race). Treat that as benign --
    # the rule we wanted is already in place.
    $addAcl = {
        param([hashtable]$params)
        try {
            Add-VMNetworkAdapterExtendedAcl @params -ErrorAction Stop | Out-Null
        }
        catch {
            if ($_.Exception.Message -match '0x800700B7|already exists') {
                # Don't swallow silently -- if this fires it means a previous
                # rule with the same (Direction + Weight + Protocol) key is
                # still on the vNIC. Hyper-V's extended-ACL identity does
                # NOT include RemotePort, so two deny rules at the same
                # weight/direction/protocol but different ports will collide
                # and the second silently lose. Warn loudly so the next
                # diagnostic round-trip catches it.
                Write-Log "[Proxy] $VmName`: ACL add returned 'already exists' -- prior rule at same Weight+Direction+Protocol survived clear, NEW RULE LOST: $($params | Out-String)" -Warning
                return
            }
            throw
        }
    }

    try {
        # --- High-priority ALLOW rules (weight band 5090-5099) ---
        # Allow all traffic both directions to/from any known lab subnet.
        # Catches intra-subnet AD/SMB/SQL/CM, cross-subnet hierarchy traffic
        # (CAS<->Primary across separate networks), and the Linux proxy +
        # DCs which always live in one of these subnets.
        #
        # Each (subnet, direction) gets a unique weight: Hyper-V's
        # extended-ACL identity is (Direction + Weight + Protocol) and does
        # NOT include RemoteIPAddress, so multiple Allow rules sharing
        # Direction+Weight+Protocol collide -- only the first lands and the
        # rest are silently dropped (would block cross-subnet traffic).
        # Band 5020-5099 keeps us inside the 5000-5099 cleanup window
        # (deny rules occupy 5000-5003); 80 slots = 40 (subnet, direction)
        # pairs = 40 subnets per direction. Memlabs host-wide subnet union
        # is rarely more than a handful, so warn well before we'd overflow.
        $maxSubnets = 40
        if ($cidrs.Count -gt $maxSubnets) {
            Write-Log "[Proxy] $VmName`: $($cidrs.Count) lab subnets exceeds cap ($maxSubnets); only first $maxSubnets will be allowed" -Warning
        }
        $w = 5099
        foreach ($cidr in ($cidrs | Select-Object -First $maxSubnets)) {
            & $addAcl @{ VMName = $VmName; Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = $cidr; Weight = $w }
            & $addAcl @{ VMName = $VmName; Action = 'Allow'; Direction = 'Inbound';  RemoteIPAddress = $cidr; Weight = $w - 1 }
            $w -= 2
        }

        # --- Low-priority DENY rules (weights 5000-5004, one per rule) ---
        # Block outbound HTTP/HTTPS to anywhere not covered above (= Internet).
        # The proxy itself reaches the Internet via the host NAT, so clients
        # MUST go through the proxy for any web traffic.
        #
        # Each rule gets a unique weight: Hyper-V's extended-ACL identity
        # key is (Direction + Weight + Protocol), NOT including RemotePort.
        # If two rules share weight+direction+protocol, the second add fires
        # 0x800700B7 ("already exists") which our addAcl helper benignly
        # swallows -- and you end up with only the FIRST port enforced
        # (e.g. TCP/80 deny lands, TCP/443 deny silently lost).
        & $addAcl @{ VMName = $VmName; Action = 'Deny'; Direction = 'Outbound'; RemotePort = 80;  Protocol = 'TCP'; Weight = 5004 }
        & $addAcl @{ VMName = $VmName; Action = 'Deny'; Direction = 'Outbound'; RemotePort = 443; Protocol = 'TCP'; Weight = 5003 }

        # Block QUIC/HTTP3 (UDP 443). Without this, Chromium-based browsers
        # (Edge, Chrome) bypass the proxy entirely for domains in the QUIC
        # preload list (e.g. Google) -- connecting directly over UDP 443,
        # which the TCP-only deny above doesn't catch. Symptoms: Google
        # works but doesn't appear in Squid logs; non-preloaded domains
        # (Bing, microsoft.com) fail because Edge tries TCP 443 first
        # (blocked), and never attempts QUIC without a prior Alt-Svc header.
        & $addAcl @{ VMName = $VmName; Action = 'Deny'; Direction = 'Outbound'; RemotePort = 443; Protocol = 'UDP'; Weight = 5002 }

        # Block outbound DNS to non-lab resolvers (lab DCs are covered by
        # the lab-subnet allow above).
        & $addAcl @{ VMName = $VmName; Action = 'Deny'; Direction = 'Outbound'; RemotePort = 53; Protocol = 'UDP'; Weight = 5001 }
        & $addAcl @{ VMName = $VmName; Action = 'Deny'; Direction = 'Outbound'; RemotePort = 53; Protocol = 'TCP'; Weight = 5000 }

        Write-Log "[Proxy] $VmName`: Enforcement ACLs applied (lab subnets: $($cidrs -join ', '))"
        return $true
    }
    catch {
        Write-Log "[Proxy] $VmName`: Failed to apply enforcement ACLs: $_" -Warning
        return $false
    }
}

function Set-VmProxyEnforcementForConfig {
    <#
    .SYNOPSIS
        Apply Hyper-V proxy enforcement to every opted-in VM in a deploy
        configuration.

    .DESCRIPTION
        Mirrors Set-WindowsClientProxyForConfig: enumerates the deployConfig,
        filters via Test-VmUsesProxy, builds a union of every known memlabs
        lab subnet (this deploy's vmOptions.network + every VM's .network +
        Get-NetworkList for cross-domain hierarchies), then calls
        Set-VmProxyEnforcement per VM. No-op when no Proxy VM or no
        opted-in clients exist.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object]$deployConfig
    )

    $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    $clients = @($deployConfig.virtualMachines | Where-Object { Test-VmUsesProxy -Vm $_ -DeployConfig $deployConfig })

    if (-not $clients) { return $true }
    if (-not $proxyVm) {
        # Add-to-existing case: Proxy lives in the existing hierarchy.
        $existingProxyName = Get-ExistingForDomain -DomainName $deployConfig.vmOptions.domainName -Role 'Proxy' | Select-Object -First 1
        if ($existingProxyName) {
            $proxyVm = [pscustomobject]@{ vmName = $existingProxyName; role = 'Proxy' }
            Write-Log "[Proxy] Using existing Proxy VM '$existingProxyName' from domain '$($deployConfig.vmOptions.domainName)' for enforcement"
        }
    }
    if (-not $proxyVm) {
        Write-Log "[Proxy] $($clients.Count) VM(s) opted-in but no Proxy VM in config or domain; skipping enforcement" -Warning
        return $false
    }

    # Union all known lab subnets so inter-domain hierarchy traffic isn't blocked.
    $subnetSet = New-Object System.Collections.Generic.HashSet[string]
    if ($deployConfig.vmOptions.network) { [void]$subnetSet.Add($deployConfig.vmOptions.network) }
    foreach ($vm in $deployConfig.virtualMachines) {
        if ($vm.network) { [void]$subnetSet.Add($vm.network) }
    }
    try {
        $allKnown = Get-NetworkList | Select-Object -ExpandProperty Network -ErrorAction Stop
        foreach ($n in $allKnown) { if ($n) { [void]$subnetSet.Add($n) } }
    }
    catch {
        Write-Log "[Proxy] Get-NetworkList failed: $_ -- continuing with config-only subnet set" -Warning
    }
    $labSubnets = @($subnetSet)
    Write-Log "[Proxy] Lab subnets allowed past enforcement: $($labSubnets -join ', ')"

    $ok = $true
    foreach ($vm in $clients) {
        $r = Set-VmProxyEnforcement -VmName $vm.vmName -LabSubnets $labSubnets
        if (-not $r) { $ok = $false }
    }
    return $ok
}

function Get-VmProxyEnforcementSubnets {
    <#
    .SYNOPSIS
        Build the global union of every memlabs lab subnet currently known
        to the host, normalized for use as Set-VmProxyEnforcement -LabSubnets.

    .DESCRIPTION
        Combines Get-NetworkList (every lab's subnet stored in cached VM
        metadata) with optional extras from an in-flight deployConfig
        (vmOptions.network + any per-VM .network overrides) so that the
        very deploy that's invoking us can also feed its brand-new subnets
        into the union before those subnets show up in Get-NetworkList.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)] [object]$deployConfig
    )

    $set = New-Object System.Collections.Generic.HashSet[string]
    try {
        $allKnown = Get-NetworkList | Select-Object -ExpandProperty Network -ErrorAction Stop
        foreach ($n in $allKnown) { if ($n) { [void]$set.Add($n) } }
    }
    catch {
        Write-Log "[Proxy] Get-NetworkList failed: $_ -- continuing with deploy-only subnet set" -Warning
    }
    if ($deployConfig) {
        if ($deployConfig.vmOptions -and $deployConfig.vmOptions.network) {
            [void]$set.Add($deployConfig.vmOptions.network)
        }
        if ($deployConfig.virtualMachines) {
            foreach ($vm in $deployConfig.virtualMachines) {
                if ($vm.network) { [void]$set.Add($vm.network) }
            }
        }
    }
    return @($set)
}

function Set-VmProxyEnforcementForAllLabs {
    <#
    .SYNOPSIS
        Reconcile Hyper-V proxy enforcement ACLs across every memlabs VM
        on the host, not just the VMs in the current deployConfig.

    .DESCRIPTION
        Adding a new domain / new subnet / new lab on a host that already
        hosts other proxy-enforced labs changes the "allowed lab subnet"
        union. The per-deploy Set-VmProxyEnforcementForConfig only touches
        VMs in the new deployConfig, so VMs in OTHER labs keep ACLs frozen
        at their original deploy time and would deny traffic to the new
        subnet (which the user almost certainly wants to permit, e.g. for
        a freshly added second hierarchy). Similarly when a lab is removed,
        the surviving labs keep stale allow rules for the gone subnet.

        This function:
          1. Builds the current global subnet union (Get-NetworkList +
             optional in-flight deployConfig extras).
          2. Enumerates every memlabs VM on the host via Get-List -Type VM.
          3. For each VM with useProxy=true in its VM Note (Windows, not
             role-excluded) -> re-stamps ACLs against the global union.
          4. For each opted-out VM that still has stale ACLs in the
             memlabs weight band (5000-5099) -> clears them.

        Safe to call repeatedly; per-VM failures are logged and never
        abort the sweep.

    .PARAMETER deployConfig
        Optional. If supplied, its subnets are folded into the union so
        the current deploy's brand-new networks are honored before
        Get-NetworkList sees them.

    .PARAMETER WhatIf
        Standard PowerShell switch; reports the intended actions without
        touching any ACLs.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)] [object]$deployConfig
    )

    $labSubnets = Get-VmProxyEnforcementSubnets -deployConfig $deployConfig
    if (-not $labSubnets -or $labSubnets.Count -eq 0) {
        Write-Log "[Proxy] Reconcile: no lab subnets known; skipping (would be wide-open deny)" -Warning
        return $false
    }

    try {
        $allVms = @(Get-List -Type VM)
    }
    catch {
        Write-Log "[Proxy] Reconcile: Get-List -Type VM failed: $_" -Warning
        return $false
    }

    if (-not $allVms -or $allVms.Count -eq 0) {
        Write-Log "[Proxy] Reconcile: no memlabs VMs found on host; nothing to do"
        return $true
    }

    # Cache-race guard: fold every enumerated VM's own subnet into the union
    # BEFORE we start stamping. Get-NetworkList reads cached VM Notes; if a
    # parallel deploy in another domain is mid-flight (Notes not yet written,
    # or our cache is stale), Get-NetworkList can return a partial view that
    # OMITS that domain's subnet. Without this guard we'd then re-stamp the
    # other domain's VMs with an allow-list missing their OWN subnet,
    # blocking their intra-lab AD / SQL / SMB / CM traffic the moment we
    # finished applying ACLs.
    #
    # The Get-List -Type VM call above iterates the same VM objects we're
    # about to touch, so any subnet we could harm by omission is right
    # here for us to add.
    $subnetSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in $labSubnets) { if ($s) { [void]$subnetSet.Add($s) } }
    foreach ($vm in $allVms) {
        if ($vm.network) { [void]$subnetSet.Add($vm.network) }
    }
    $labSubnets = @($subnetSet)
    Write-Log "[Proxy] Reconcile: lab subnet union = $($labSubnets -join ', ')"

    # Hard-exclude roles (mirrors Test-VmUsesProxy). Linux Proxy VM excluded
    # via the Proxy role itself; other Linux VMs are not Windows-NAT'd so
    # have no extended ACLs to manage.
    $hardExclude = @('Proxy', 'DC', 'BDC', 'StandaloneRootCA')

    $applied = 0; $cleared = 0; $skipped = 0; $failed = 0
    foreach ($vm in $allVms) {
        if (-not $vm.vmName) { continue }
        if ($vm.role -in $hardExclude) { $skipped++; continue }
        # OperatingSystem comes from deployedOS in VM Note; Linux distros contain "Linux" / "Ubuntu".
        if ($vm.OperatingSystem -and ($vm.OperatingSystem -match 'Linux|Ubuntu|Debian|CentOS|RHEL|Fedora')) {
            $skipped++; continue
        }

        $optedIn = $false
        if ($vm.PSObject.Properties.Name -contains 'useProxy') {
            $optedIn = [bool]$vm.useProxy
        }

        try {
            if ($optedIn) {
                # Safety net: never stamp a VM whose own subnet isn't in the
                # final allow list -- doing so would deny its intra-lab AD /
                # SQL / SMB traffic. Should never fire after the union-fold
                # guard above, but is cheap insurance against a regression
                # or a VM with a missing/blank .network property.
                if ($vm.network -and ($labSubnets -notcontains $vm.network)) {
                    Write-Log "[Proxy] Reconcile: $($vm.vmName): own subnet '$($vm.network)' not in union ($($labSubnets -join ', ')); refusing to stamp (would break intra-lab traffic)" -Warning
                    $failed++
                    continue
                }
                if ($PSCmdlet.ShouldProcess($vm.vmName, "Apply proxy enforcement ACLs")) {
                    $r = Set-VmProxyEnforcement -VmName $vm.vmName -LabSubnets $labSubnets
                    if ($r) { $applied++ } else { $failed++ }
                }
            }
            else {
                # Not opted-in: clear any stale ACLs from a prior deploy where
                # useProxy was true. Cheap no-op if the VM has none.
                $existing = Get-VMNetworkAdapterExtendedAcl -VMName $vm.vmName -ErrorAction SilentlyContinue
                $stale = @($existing | Where-Object {
                        $_.Weight -ge $global:MemLabsProxyAclWeightMin -and
                        $_.Weight -le $global:MemLabsProxyAclWeightMax
                    })
                if ($stale.Count -gt 0) {
                    if ($PSCmdlet.ShouldProcess($vm.vmName, "Clear stale proxy enforcement ACLs ($($stale.Count) rules)")) {
                        Clear-VmProxyEnforcement -VmName $vm.vmName
                        $cleared++
                        Write-Log "[Proxy] Reconcile: $($vm.vmName): cleared $($stale.Count) stale ACL(s) (useProxy=false/missing)"
                    }
                }
            }
        }
        catch {
            $failed++
            Write-Log "[Proxy] Reconcile: $($vm.vmName): unexpected error: $_" -Warning
        }
    }

    Write-Log "[Proxy] Reconcile complete: $applied applied, $cleared cleared, $skipped skipped (excluded/Linux), $failed failed"
    return ($failed -eq 0)
}
# endregion Proxy enforcement ---------------------------------------------