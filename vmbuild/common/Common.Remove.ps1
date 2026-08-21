# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
########################
### Remove Functions ###
########################

function Remove-ItemWithRetry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [int] $MaxAttempts = 3,
        [int] $DelaySeconds = 5,
        [switch] $WhatIf
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -Path $Path -Force -Recurse -WhatIf:$WhatIf -ProgressAction SilentlyContinue -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            Write-Log "Attempt $attempt/$MaxAttempts`: Failed to remove '$Path': $($_.Exception.Message)" -Warning
            if ($attempt -lt $MaxAttempts) {
                Write-Log "Sleeping $DelaySeconds seconds before retry..." -SubActivity
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }
    return $false
}

function Stop-LockingProcesses {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $FolderPath,
        [switch] $IdentifyOnly
    )

    $handleExe = "C:\tools\handle.exe"
    if (-not (Test-Path $handleExe)) {
        Write-Log "Downloading handle.exe from Sysinternals..." -SubActivity
        if (-not (Test-Path "C:\tools")) {
            New-Item -Path "C:\tools" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $originalProgressPreference = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Start-BitsTransfer -Source "https://live.sysinternals.com/handle.exe" -Destination $handleExe -ErrorAction Stop
        }
        catch {
            Write-Log "Could not download handle.exe: $($_.Exception.Message)" -Warning
            return $false
        }
        finally {
            $ProgressPreference = $originalProgressPreference
        }
    }

    try {
        $output = & $handleExe -accepteula -nobanner "$FolderPath" 2>&1 | Out-String
    }
    catch {
        Write-Log "handle.exe failed while inspecting '$FolderPath': $($_.Exception.Message)" -Warning
        return $false
    }

    if (-not $output -or $output -match 'No matching handles found') {
        Write-Log "No locking processes found by handle.exe for '$FolderPath'." -SubActivity
        return $false
    }

    $killedAny = $false
    $ownerCount = 0
    $pidsKilled = @{}
    $protectedProcesses = @('System', 'vmcompute.exe', 'vmms.exe', 'vmwp.exe')
    foreach ($line in $output -split "`r?`n") {
        if ($line -notmatch '^(?<name>.+?)\s+pid:\s+(?<pid>\d+).*?\s+(?<handle>[0-9A-F]+):\s+(?<path>.+)$') {
            continue
        }

        $ownerCount++
        $procName = $Matches['name']
        $procPid = [int]$Matches['pid']
        $heldPath = $Matches['path'].Trim()
        Write-Log "Lock owner: $procName (PID $procPid) holds '$heldPath'." -Warning

        if ($IdentifyOnly -or $protectedProcesses -contains $procName) {
            if (-not $IdentifyOnly -and $protectedProcesses -contains $procName) {
                Write-Log "Not terminating $procName (PID $procPid); Hyper-V/System processes must be released through their owning service or VM." -Warning
            }
            continue
        }

        if (-not $pidsKilled.ContainsKey($procPid)) {
            $pidsKilled[$procPid] = $true
            Write-Log "Terminating $procName (PID $procPid) so '$FolderPath' can be removed..." -Warning
            try {
                Stop-Process -Id $procPid -Force -ErrorAction Stop
                $killedAny = $true
            }
            catch {
                Write-Log "Could not terminate $procName (PID $procPid): $($_.Exception.Message)" -Warning
            }
        }
    }

    if ($ownerCount -eq 0) {
        $rawOutput = ($output -replace '\s+', ' ').Trim()
        if ($rawOutput.Length -gt 1000) { $rawOutput = $rawOutput.Substring(0, 1000) + '...' }
        Write-Log "handle.exe returned no parseable lock-owner rows for '$FolderPath'. Raw output: $rawOutput" -Warning
    }
    elseif ($killedAny) {
        Start-Sleep -Seconds 2
    }

    return $killedAny
}

function Get-DomainHyperVVM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $DomainName,
        [Parameter()]
        [string] $VmStorageRoot
    )

    $domainFolder = $null
    $domainPrefix = $null
    if ($VmStorageRoot) {
        $domainFolder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($VmStorageRoot, $DomainName)).TrimEnd('\')
        $domainPrefix = $domainFolder + '\'
    }
    $liveVms = @(Get-VM -ErrorAction Stop)
    foreach ($vm in $liveVms) {
        $belongsToDomain = $false
        if ($vm.Path) {
            try {
                $vmPath = [System.IO.Path]::GetFullPath("$($vm.Path)").TrimEnd('\')
                $pathSegments = @($vmPath -split '\\')
                $belongsToDomain = ($pathSegments -contains $DomainName)
                if (-not $belongsToDomain -and $domainFolder) {
                    $belongsToDomain = ($vmPath -ieq $domainFolder -or $vmPath.StartsWith($domainPrefix, [System.StringComparison]::OrdinalIgnoreCase))
                }
            }
            catch { }
        }
        if (-not $belongsToDomain -and $vm.Notes) {
            try {
                $vmNote = $vm.Notes | ConvertFrom-Json -ErrorAction Stop
                $belongsToDomain = ($vmNote.domain -and "$($vmNote.domain)" -ieq $DomainName)
            }
            catch { }
        }
        if ($belongsToDomain) { $vm }
    }
}

function Remove-VirtualMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string] $VmName,
        [Parameter()]
        [switch] $WhatIf,
        [Parameter()]
        [switch] $Force,
        [Parameter()]
        [bool] $Migrate = $false,
        # Optional: caller-supplied VM list record (from a prior Get-List).
        # When provided, skip the inline Get-List -SmartUpdate call -- saves
        # ~1s per VM in parallel-removal scenarios where every worker would
        # otherwise re-enumerate the entire host VM inventory.
        [Parameter()]
        [object] $VmRecord,
        # When true, the caller is tearing down the entire domain (or
        # removing the DC). Skip expensive per-client proxy
        # unconfiguration since all VMs are going away anyway.
        [Parameter()]
        [switch] $RemovingDomain,
        # When true, skip the entire proxy cleanup block (client
        # unconfiguration, host shortcuts, guest shortcuts). Used when
        # removing VMs that never reached Phase 2+ (proxy was never
        # installed or configured).
        [Parameter()]
        [switch] $SkipProxyCleanup
    )

    function Test-VMReachedOff {
        param (
            [string] $VmName,
            [int] $TimeoutSeconds = 30
        )
        $elapsed = 0
        while ($elapsed -lt $TimeoutSeconds) {
            Start-Sleep -Seconds 1
            $elapsed += 1
            $refreshed = Get-VM -Name $VmName -ErrorAction SilentlyContinue
            if (-not $refreshed -or $refreshed.State -eq "Off") {
                Write-Log "VM '$VmName' is now Off." -SubActivity
                return $true
            }
        }
        return $false
    }

    # Helper: ensure VM is fully stopped with timeout.
    # Since we're deleting the VM, skip the graceful shutdown and TurnOff directly
    # (no point waiting for the guest OS to shut down cleanly).
    function Wait-VMStopped {
        param (
            [Microsoft.HyperV.PowerShell.VirtualMachine] $VM,
            [int] $TimeoutSeconds = 30,
            [switch] $WhatIf
        )
        if ($VM.State -eq "Off") { return $true }

        Write-Log "VM '$($VM.Name)' is in state '$($VM.State)'. Forcing power off (delete in progress)..." -SubActivity

        if ($WhatIf) {
            $VM | Stop-VM -TurnOff -Force -WhatIf -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            return $true
        }

        # -AsJob + Wait-Job, not a bare call: when the VM worker process is wedged
        # Stop-VM never returns, and an unbounded call makes the poll loop and the
        # worker-process kill below -- the only things that recover it -- unreachable.
        # -ErrorAction/-WarningAction silence errors; they do not bound a hang.
        $turnOffAnswered = $false
        try {
            $stopJob = $VM | Stop-VM -TurnOff -Force -WarningAction SilentlyContinue -AsJob
            $null = $stopJob | Wait-Job -Timeout $TimeoutSeconds
            if ($stopJob.State -eq 'Running') {
                Write-Log "VM '$($VM.Name)': TurnOff did not return within $TimeoutSeconds seconds; escalating." -Warning
                Stop-Job $stopJob -ErrorAction SilentlyContinue
            }
            else {
                $turnOffAnswered = $true
                if ($stopJob.State -eq 'Failed') {
                    # Hyper-V's -AsJob returns a VMJob, which does not always populate ChildJobs.
                    $reason = if (@($stopJob.ChildJobs).Count) { $stopJob.ChildJobs[0].JobStateInfo.Reason.Message } else { $stopJob.JobStateInfo.Reason.Message }
                    Write-Log "TurnOff failed: $reason" -Warning
                }
            }
            Remove-Job $stopJob -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "TurnOff threw $($_.Exception.GetType().Name): $($_.Exception.Message)" -Warning
        }

        # Only ask Hyper-V for the state if it just answered. A TurnOff that never
        # returned is itself proof the worker is wedged, and a wedged worker blocks
        # vmms for everyone -- Get-VM hangs too, and Hyper-V Manager sits on
        # "Loading virtual machines". Polling first would put the kill behind the
        # very hang it exists to clear.
        if ($turnOffAnswered -and (Test-VMReachedOff -VmName $VM.Name -TimeoutSeconds $TimeoutSeconds)) {
            return $true
        }

        # Nuclear option, same rung Stop-VM2 ends on: kill this VM's worker process.
        # Safe here because the VM is being deleted regardless, and an already-Off VM
        # has no worker to match. Target vmwp.exe by VM id -- never vmms.exe, which is
        # shared by every VM on the host and takes the whole console down with it.
        Write-Log "VM '$($VM.Name)' is not confirmed Off. Killing its worker process." -Warning
        try {
            $vmId = $VM.Id.ToString()
            $targetProc = Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match [regex]::Escape($vmId) }
            if ($targetProc) {
                Stop-Process -Id $targetProc.ProcessId -Force -ErrorAction Stop
                if (Test-VMReachedOff -VmName $VM.Name -TimeoutSeconds $TimeoutSeconds) {
                    Write-Log "VM '$($VM.Name)' stopped after killing worker process (PID $($targetProc.ProcessId))." -Warning
                    return $true
                }
            }
            else {
                Write-Log "VM '$($VM.Name)': no vmwp.exe found for id $vmId." -Warning
            }
        }
        catch {
            Write-Log "VM '$($VM.Name)': could not kill worker process: $($_.Exception.Message)" -Warning
        }

        Write-Log "VM '$($VM.Name)' could not be forced Off." -Warning
        return $false
    }

    # ── Main logic ────────────────────────────────────────────────────────────

    if ($VmRecord -and $VmRecord.vmName -eq $VmName) {
        $vmFromList = $VmRecord
    }
    else {
        $vmFromList = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VmName }
    }
    if ($vmFromList.vmBuild -eq $false) {
        if (-not ($Force.IsPresent)) {
            Write-Log "VM '$VmName' exists, but it was not deployed via MemLabs. Skipping." -SubActivity
            return
        }
    }

    $vmTest = Get-VM2 -Name $VmName -Fallback
    if (-not $vmTest) {
        Write-Log "VM '$VmName' does not exist in Hyper-V." -Warning
        return
    }

    $parentItem = Get-Item $vmTest.Path -ErrorAction SilentlyContinue
    $parent = if ($parentItem) { $parentItem.Parent } else { $null }

    Write-Log "VM '$VmName' exists. Removing." -SubActivity

    # -- DHCP cleanup --
    if ($vmFromList.ClusterIPAddress) {
        # Cluster IP is on the domain subnet — remove its DHCP exclusion range.
        $clusterScopeId = if ($vmFromList.network) { $vmFromList.network } else { $null }
        if ($clusterScopeId) {
            Write-Log "$VmName`: Removing $($vmFromList.ClusterIPAddress) Exclusion (scope $clusterScopeId)..." -HostOnly
            Remove-DhcpServerv4ExclusionRange -ScopeId $clusterScopeId `
                -StartRange $vmFromList.ClusterIPAddress -EndRange $vmFromList.ClusterIPAddress `
                -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }
    }
    if ($vmFromList.AGIPAddress) {
        # AG listener IP is on the domain subnet, not the cluster subnet.
        $agScopeId = if ($vmFromList.network) { $vmFromList.network } else { $null }
        if ($agScopeId) {
            Write-Log "$VmName`: Removing $($vmFromList.AGIPAddress) Exclusion (scope $agScopeId)..." -HostOnly
            Remove-DhcpServerv4ExclusionRange -ScopeId $agScopeId `
                -StartRange $vmFromList.AGIPAddress -EndRange $vmFromList.AGIPAddress `
                -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }
    }

    # -- Network adapter reservations --
    $adapters = $vmTest | Get-VMNetworkAdapter
    foreach ($adapter in $adapters) {
        Remove-DHCPReservation -mac $adapter.MacAddress -vmName $VmName   # fixed: was $currentItem.vmName
    }

    # -- Linux: capture IPs before stopping (KVP dies with the VM) --
    $linuxIPs = @()
    $isLinuxVm = $vmFromList -and ($vmFromList.role -in @('Proxy', 'LinuxServer', 'LinuxClient') -or $vmFromList.osFamily -eq 'Linux')
    if ($isLinuxVm) {
        # Live adapter IPs (available only while the VM is running)
        $linuxIPs = @($adapters | ForEach-Object { $_.IPAddresses } |
            Where-Object { $_ -and $_ -notmatch ':' -and $_ -notmatch '^169\.254\.' } |
            Select-Object -Unique)

        # Fallback: LastKnownIP from VM notes (works even if VM is already off)
        try {
            $vmNoteObj = Get-VMNote -VMName $VmName
            if ($vmNoteObj.LastKnownIP -and $vmNoteObj.LastKnownIP -notin $linuxIPs) {
                $linuxIPs += $vmNoteObj.LastKnownIP
            }
        }
        catch {}
    }

    # -- Ensure VM is stopped before touching files --
    $stopped = Wait-VMStopped -VM $vmTest -WhatIf:$WhatIf
    if (-not $stopped -and -not $WhatIf) {
        Write-Log "Could not confirm VM '$VmName' is stopped. File locks may persist." -Warning
    }

    # -- Cache file cleanup --
    foreach ($suffix in @(".disk.json", ".network.json")) {
        $cacheFile = Join-Path $global:common.CachePath ($vmTest.vmID.ToString() + $suffix)
        if (Test-Path $cacheFile) {
            Remove-Item -Path $cacheFile -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue | Out-Null
        }
    }
    # Also purge the in-memory network cache entry
    if ($global:Common.NetCache -and $vmTest.vmID) {
        $global:Common.NetCache.Remove($vmTest.vmID) | Out-Null
    }

    # -- Detach hard drives to prevent checkpoint merge during Remove-VM --
    # When a VM has checkpoints, Remove-VM triggers an AVHDX merge ("Destroying..."
    # state) which can take minutes. Detaching the disks first means there is
    # nothing for Hyper-V to merge, making Remove-VM instantaneous.
    if (-not $WhatIf) {
        try {
            $drives = Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue
            if ($drives) {
                $drives | Remove-VMHardDiskDrive -ErrorAction SilentlyContinue
                Write-Log "VM '$VmName': Detached $($drives.Count) disk(s) to skip merge." -SubActivity
            }
        }
        catch {
            Write-Log "VM '$VmName': Could not detach disks (non-fatal): $($_.Exception.Message)" -Warning
        }
    }

    # -- Remove VM from Hyper-V --
    # With disks detached, Remove-VM completes instantly (no checkpoint merge).
    # This also releases the vmms.exe lock on the .vmcx configuration file.
    try {
        $vmTest | Remove-VM -Force -WhatIf:$WhatIf -ErrorAction Stop
        Write-Log "VM '$VmName' removed from Hyper-V." -SubActivity
    }
    catch {
        $removeVmError = $_.Exception.Message
        Write-Log "Remove-VM failed for '$VmName': $removeVmError" -Warning
        if (-not $WhatIf) {
            $null = Stop-LockingProcesses -FolderPath $vmTest.Path -IdentifyOnly
        }
        throw "Remove-VM failed for '$VmName'; its files will not be deleted while the VM remains registered. $removeVmError"
    }

    # -- Folder removal (after Remove-VM has released file handles) --
    $folderRemoved = $false
    $folderCleanupFailed = $false
    if (-not $Migrate) {
        if (Test-Path $vmTest.Path) {
            Write-Log "$VmName`: Purging $($vmTest.Path) folder..." -HostOnly
            $folderRemoved = Remove-ItemWithRetry -Path $vmTest.Path -MaxAttempts 3 -DelaySeconds 5 -WhatIf:$WhatIf
            if (-not $folderRemoved -and -not $WhatIf) {
                # Initial retries exhausted -- try to kill whichever process
                # is holding a file lock and retry the removal.
                Write-Log "$VmName`: Attempting to identify and kill process holding file locks..." -SubActivity
                $killed = Stop-LockingProcesses -FolderPath $vmTest.Path
                if ($killed) {
                    $folderRemoved = Remove-ItemWithRetry -Path $vmTest.Path -MaxAttempts 3 -DelaySeconds 5
                }
                if (-not $folderRemoved) {
                    Write-Log "$VmName`: WARNING - Folder '$($vmTest.Path)' could not be removed. Manual cleanup required." -Warning
                    $folderCleanupFailed = $true
                }
            }
        }
        else {
            $folderRemoved = $true
        }
    }

    # -- Parent folder cleanup (only if now empty) --
    # Wrapped in try/catch because parallel VM-removal jobs race here:
    # two threads can both pass Test-Path/Get-ChildItem, then one deletes
    # the folder before the other's Remove-Item runs.
    try {
        if ($parent -and (Test-Path $parent.FullName) -and -not $Migrate -and -not $WhatIf) {
            $remaining = Get-ChildItem $parent.FullName -ErrorAction SilentlyContinue
            if (-not $remaining -or $remaining.Count -eq 0) {
                Write-Log "$VmName`: Removing empty parent folder '$($parent.FullName)'..." -SubActivity
                Remove-Item -Path $parent.FullName -Force -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue
            }
        }
    }
    catch {
        # Another job already removed it -- benign.
    }

    # -- Proxy: unconfigure clients + clean up host desktop shortcuts --
    # When removing a Proxy VM (but NOT tearing down the entire domain),
    # reverse proxy configuration on all opted-in Windows clients in the
    # domain: clear in-guest settings, remove Hyper-V port ACLs, and set
    # useProxy=false in VM Notes. Skip when -RemovingDomain since every
    # VM is going away anyway.
    if (-not $WhatIf -and -not $SkipProxyCleanup -and $vmFromList -and $vmFromList.role -eq 'Proxy' -and $vmFromList.domain) {
        if (-not $RemovingDomain) {
            if (Get-Command -Name Remove-WindowsClientProxyForDomain -ErrorAction SilentlyContinue) {
                Remove-WindowsClientProxyForDomain -DomainName $vmFromList.domain
            }
            # Reconcile cross-lab ACLs: the proxy's subnet may need to be
            # removed from allow-lists on VMs in other domains.
            if (Get-Command -Name Set-VmProxyEnforcementForAllLabs -ErrorAction SilentlyContinue) {
                Write-Log "$VmName`: Reconciling cross-lab proxy ACLs after Proxy removal"
                Set-VmProxyEnforcementForAllLabs
            }
        }
        # The shared ~/.ssh/id_ed25519 key stays put -- other domains' proxies
        # (and any future Linux VMs) still depend on it.
        if (Get-Command -Name Remove-HostProxyShortcuts -ErrorAction SilentlyContinue) {
            Remove-HostProxyShortcuts -ProxyFqdn "$VmName.$($vmFromList.domain)"
        }
        # Remove SSH shortcuts from guest VM desktops (DC, Primary, etc.)
        if (-not $RemovingDomain) {
            if (Get-Command -Name Remove-ProxyAdminAccessForDomain -ErrorAction SilentlyContinue) {
                Remove-ProxyAdminAccessForDomain -DomainName $vmFromList.domain -ProxyFqdn "$VmName.$($vmFromList.domain)"
            }
        }
    }

    # -- Linux: scrub stale known_hosts entries for the removed VM's IP --
    # A stale host-key entry causes ssh.exe to reject connections to a
    # future VM that reuses the same IP (different host keys after rebuild).
    # Scrub both the memlabs-private known_hosts (next to the shared key)
    # and the user's default ~/.ssh/known_hosts.
    if (-not $WhatIf -and $linuxIPs.Count -gt 0) {
        try {
            $keyPair = Get-LinuxAdminSshKeyPair
            $memlabsKH = Join-Path (Split-Path $keyPair.PrivateKeyPath) 'known_hosts'
            $userKH = Join-Path $env:USERPROFILE '.ssh\known_hosts'
            $scrubTargets = @($memlabsKH, $userKH) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
            foreach ($ip in $linuxIPs) {
                $pattern = "^[^ ]*\b$([regex]::Escape($ip))\b"
                foreach ($kh in $scrubTargets) {
                    $hits = @(Select-String -Path $kh -Pattern $pattern -ErrorAction SilentlyContinue)
                    if ($hits.Count -gt 0) {
                        $allLines = Get-Content -LiteralPath $kh -ErrorAction Stop
                        $keep = $allLines | Where-Object { $_ -notmatch $pattern }
                        Set-Content -LiteralPath $kh -Value $keep -Encoding ASCII -NoNewline:$false
                        Write-Log "$VmName`: Scrubbed $($hits.Count) known_hosts entry/entries for $ip from $kh" -SubActivity
                    }
                }
            }
        }
        catch {
            Write-Log "$VmName`: Failed to scrub known_hosts: $($_.Exception.Message)" -Warning
        }
    }

    if ($folderCleanupFailed) {
        throw "VM '$VmName' was unregistered, but folder '$($vmTest.Path)' remains after cleanup retries. Lock owners were reported above."
    }
}

function Remove-DhcpScope {
    param (
        [Parameter(Mandatory = $true)]
        [string] $ScopeId,
        [Parameter()]
        [switch] $WhatIf
    )

    if ($ScopeId -eq "Internet") {
        $ScopeId = "172.31.250.0"
    }
    if ($ScopeId -eq "cluster") {
        $ScopeId = "10.250.250.0"
    }

    $dhcpScope = Get-DhcpServerv4Scope -ScopeID $ScopeId -ErrorAction SilentlyContinue
    if ($dhcpScope) {
        Write-Log "DHCP Scope '$($dhcpScope.Name)' exists. Removing." -SubActivity
        $dhcpScope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
    }
}

function Remove-OrphanedNetNats {
    <#
    .SYNOPSIS
        Silently remove memlabs-style NetNat entries that have no matching
        Hyper-V switch. Called automatically from Remove-Domain / Remove-All
        finally blocks so orphaned NATs never accumulate.
    #>
    [CmdletBinding()]
    param()
    try {
        $switchNames = @((Get-VMSwitch -ErrorAction SilentlyContinue).Name)
        # Also consider subnets from VMs still registered in Get-List
        $vmSwitches = @()
        try { $vmSwitches = @(Get-List -Type UniqueSwitch) } catch {}

        # Protect infrastructure switches only when VMs are connected.
        # If no VMs use them, they're genuinely orphaned.
        foreach ($infra in @('Internet', 'Cluster', 'ClusterV2')) {
            if ($infra -notin $switchNames -and $infra -notin $vmSwitches) { continue }
            $attached = @(Get-VM | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.SwitchName -eq $infra })
            if ($attached.Count -gt 0 -and $infra -notin $vmSwitches) {
                $vmSwitches += $infra
            }
        }

        # Map infrastructure switch names to their subnet equivalents so
        # NATs named by subnet (e.g. '10.250.250.0') are recognized.
        $inUse = @($switchNames + $vmSwitches) | ForEach-Object {
            switch ($_) {
                'Internet'  { '172.31.250.0'; $_ }
                'Cluster'   { '10.250.250.0'; $_ }
                'ClusterV2' { '10.250.251.0'; $_ }
                default     { $_ }
            }
        } | Select-Object -Unique

        $natEntries = @(Get-NetNat -ErrorAction SilentlyContinue)
        foreach ($nat in $natEntries) {
            # Only touch memlabs-style NATs named with a dotted-quad subnet
            if ($nat.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
            if ($nat.Name -in $inUse) { continue }

            Write-Log "Removing orphaned NAT '$($nat.Name)' ($($nat.InternalIPInterfaceAddressPrefix))" -Warning
            Remove-NetNat -Name $nat.Name -Confirm:$false -ErrorAction SilentlyContinue

            # Also clean up the DHCP scope for this orphan
            $dhcp = Get-DhcpServerv4Scope -ScopeID $nat.Name -ErrorAction SilentlyContinue
            if ($dhcp) {
                $dhcp | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Log "Remove-OrphanedNetNats: $($_.Exception.Message)" -Warning
    }
}

function Remove-Orphaned {

    param (
        [Parameter()]
        [switch] $WhatIf
    )

    Write-Log "Detecting orphaned Virtual Machines" -Activity
    $virtualMachines = Get-List -Type VM -SmartUpdate
    foreach ($vm in $virtualMachines) {

        if (-not $vm.Domain) {
            # Prompt for delete, likely no json object in vm notes
            $response = Read-YesOrNoWithTimeout -Prompt "  VM $($vm.VmName) may be orphaned. Delete? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
            }
        }
        else {
            if ($null -ne $vm.success -and $vm.success -eq $false) {
                Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
            }
        }
        Write-Host
    }

    # Loop through vm's again (in case some were deleted above)
    $vmNetworksInUse = Get-List -Type UniqueSwitch -SmartUpdate
    $vmNetworksInUse2 = $vmNetworksInUse -replace "Internet", "172.31.250.0"

    # Switches are decided FIRST because Remove-VMSwitch2 takes the NAT and the DHCP scope with
    # it, and a switch the operator KEEPS has to keep its scope and NAT too. Sweeping scopes and
    # NATs first deleted half a network out from under a switch that was then left in place.
    $keptSwitches = @()
    Write-Log "Detecting orphaned Hyper-V Switches" -Activity
    $switches = Get-VMSwitch -SwitchType Internal
    foreach ($switch in $switches) {
        $inUse = $false
        foreach ($network in $vmNetworksInUse) {
            if ($switch.Name -like "*$network*") {
                $inUse = $true
                break
            }
        }

        if (-not $inUse) {
            $response = Read-YesOrNoWithTimeout -Prompt "  Hyper-V Switch '$($switch.Name)' may be orphaned. Delete Switch? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-VMSwitch2 -NetworkName $switch.Name
            }
            else {
                $keptSwitches += $switch.Name
            }
            Write-Host
        }
    }
    # Scope ids use the subnet where the switch uses the name 'Internet'.
    $keptNetworks = @($keptSwitches | ForEach-Object { if ($_ -eq 'Internet') { '172.31.250.0' } else { $_ } })

    $keptScopes = @()
    Write-Log "Detecting orphaned DHCP Scopes" -Activity
    $scopes = Get-DhcpServerv4Scope
    foreach ($scope in $scopes) {
        $scopeId = $scope.ScopeId.ToString() # This requires us to replace "Internet" with subnet
        if ($vmNetworksInUse2 -notcontains $scopeId) {
            if ($keptNetworks -contains $scopeId) {
                Write-Log "  Keeping DHCP scope '$scopeId'; its Hyper-V switch was kept." -LogOnly
                continue
            }
            $response = Read-YesOrNoWithTimeout -Prompt "  DHCP Scope '$($scope.Name) [$($scope.ScopeId)]' may be orphaned. Delete DHCP Scope? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-DhcpScope -ScopeId $scopeId -WhatIf:$WhatIf
            }
            else {
                $keptScopes += $scopeId
            }
            Write-Host
        }
    }

    $keptNats = @()
    Write-Log "Detecting orphaned NAT entries" -Activity
    $natEntries = Get-NetNat -ErrorAction SilentlyContinue
    foreach ($nat in $natEntries) {
        # Memlabs NAT entries are named with the subnet (e.g. 192.168.1.0).
        # Skip entries whose name doesn't look like a subnet -- they belong
        # to something else (e.g. Docker, WSL).
        if ($nat.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
        if ($vmNetworksInUse2 -notcontains $nat.Name) {
            if ($keptNetworks -contains $nat.Name) {
                Write-Log "  Keeping NAT '$($nat.Name)'; its Hyper-V switch was kept." -LogOnly
                continue
            }
            $response = Read-YesOrNoWithTimeout -Prompt "  NAT entry '$($nat.Name)' ($($nat.InternalIPInterfaceAddressPrefix)) may be orphaned. Delete? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-NetNat -Name $nat.Name -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "Removed orphaned NAT entry '$($nat.Name)'" -SubActivity
            }
            else {
                $keptNats += $nat.Name
            }
            Write-Host
        }
    }

    # The prompts above default to "no" and time out after 10s, so walking away silently keeps
    # everything. Name what survived, or the leak is invisible.
    $survived = @()
    if ($keptSwitches.Count) { $survived += "switches: $($keptSwitches -join ', ')" }
    if ($keptScopes.Count) { $survived += "DHCP scopes: $($keptScopes -join ', ')" }
    if ($keptNats.Count) { $survived += "NATs: $($keptNats -join ', ')" }
    if ($survived.Count) {
        Write-Log "Orphan cleanup left these behind (not confirmed for deletion): $($survived -join ' | ')" -Warning
    }
}

function Remove-InProgress {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter()]
        [switch] $WhatIf
    )

    Write-Log "Removing In-Progress Virtual Machines" -Activity

    if ($DomainName) {
        $virtualMachines = Get-List -Type VM -DomainName $DomainName
    }
    else {
        $virtualMachines = Get-List -Type VM
    }

    foreach ($vm in $virtualMachines) {
        if ($vm.inProgress) {
            Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
        }
    }

    Write-Host
}

function Remove-ForestTrust {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter()]
        [switch] $IfBroken,
        [Parameter()]
        [switch] $WhatIf
        
    )    
    $TrustedForests = Get-List -Type ForestTrust | Where-Object { $_.ForestTrust -eq $DomainName -or $_.Domain -eq $DomainName }
    
    if ($TrustedForests) {
        foreach ($TrustedForest in $TrustedForests) {
                        
            $DC1 = get-list -type VM -DomainName $TrustedForest.ForestTrust | Where-Object { $_.Role -eq "DC" }
            $DC2 = get-list -type VM -DomainName $TrustedForest.domain | Where-Object { $_.Role -eq "DC" }

            if ($DC1) {
                $forestDomain = $TrustedForest.ForestTrust
                $domainName = $TrustedForest.domain
                start-vm2 -Name $DC1.vmName
                Wait-ForHeartbeat -VmName $DC1.vmName | Out-Null

                $scriptBlockTest = {
                    param(
                        [String]$forestDomain,
                        [String]$DomainName,
                        [String]$adminName,
                        [String]$adminName2,
                        [String]$pw
                    )
                    & netdom trust $($forestDomain) /d:$($DomainName) /userD:$adminName /passwordD:$pw /userO:$adminName2 /PasswordO:$pw /verify /twoway
                }
                $result = Invoke-VmCommand -VmName $DC1.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlockTest -ArgumentList @($forestDomain, $domainName, $DC1.AdminName, $DC2.AdminName, $($Common.LocalAdmin.GetNetworkCredential().Password)) -SuppressLog  

                write-host -verbose "Netdom results: $($result.ScriptBlockOutput)"
                if ($result.ScriptBlockOutput -and $result.ScriptBlockOutput -like "*has been successfully verified*") {

                    if ($IfBroken) {
                        Write-GreenCheck "Trust Verified Successfully"
                        return
                    } 
                    else {
                        Write-OrangePoint "Trust Verified Successfully. Deleting Anyway"
                    }
                }
                else {

                    Write-RedX "Trust is not working. Removing."
                    write-log $result.ScriptBlockOutput                
                }

                Write-Log "Removing Trust on $DC1 for '$otherDomain'" -Activity
             
                
                $scriptBlock1 = {
                    param(
                        [String]$forestDomain,
                        [String]$DomainName
                    )
                    write-host "Running on $env:ComputerName as $env:Username"
                    write-host "Netdom trust $forestDomain /Domain:$DomainName /Remove /Force"
                    Netdom trust $forestDomain /Domain:$DomainName /Remove /Force
                }
                $result = Invoke-VmCommand -VmName $DC1.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlock1 -ArgumentList @($forestDomain, $domainName) -SuppressLog
                $result = Invoke-VmCommand -VmName $DC1.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlock1 -ArgumentList @($domainName, $forestDomain) -SuppressLog
                write-log $result.ScriptBlockOutput
            }

            if ($DC2) {
                $forestDomain = $TrustedForest.domain
                $domainName = $TrustedForest.ForestTrust
                Write-Log "Removing Trust on $DC2 for '$otherDomain'" -Activity

                start-vm2 -Name $DC2.vmName
                Wait-ForHeartbeat -VmName $DC2.vmName | Out-Null
                $scriptBlock1 = {
                    param(
                        [String]$forestDomain,
                        [String]$DomainName
                    )
                    write-host "Running on $env:ComputerName as $env:Username"
                    write-host "Netdom trust $forestDomain /Domain:$DomainName /Remove /Force"
                    Netdom trust $forestDomain /Domain:$DomainName /Remove /Force
                }
                $result = Invoke-VmCommand -VmName $DC2.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlock1 -ArgumentList @($forestDomain, $domainName) -SuppressLog
                $result = Invoke-VmCommand -VmName $DC2.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlock1 -ArgumentList @($domainName, $forestDomain) -SuppressLog
                write-log $result.ScriptBlockOutput
            }

        }
    }
}

function Remove-Domain {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [object]$VMList,
        [Parameter()]
        [switch] $WhatIf
    )

    $all = $false
    Write-Log "Removing virtual machines for '$DomainName' domain." -Activity
    if ($VMList) {
        $vmsToDelete = Get-List -Type VM -DomainName $DomainName -ResetCache -SmartUpdate | Where-Object { $_.vmName -in $VMList }
    }
    else {
        $vmsToDelete = Get-List -Type VM -DomainName $DomainName -ResetCache -SmartUpdate
        $all = $true
    }
    $DC = $vmsToDelete | Where-Object { $_.Role -eq "DC" }

    # Capture scopes BEFORE deleting VMs — once VMs are gone, Get-List
    # can't discover which switches belonged to this domain.
    $scopesToDelete = @(Get-List -Type UniqueSwitch -DomainName $DomainName)
    # Get-List only sees LIVE VMs, so a subnet whose VMs were already deleted is
    # invisible to it. The vSwitch note carries the owning domain, so use it too.
    $scopesToDelete += @(Get-VMSwitch -SwitchType Internal -ErrorAction SilentlyContinue |
        Where-Object { $_.Notes -eq $DomainName } | Select-Object -ExpandProperty Name)
    # Internet/Cluster subnets could be shared between multiple domains
    $scopesToDelete = @($scopesToDelete | Where-Object { $_ -and $_ -notin @("Internet", "Cluster", "ClusterV2") } | Sort-Object -Unique)
    $vmStorageRoot = if ($all) { Get-MemlabsVmStorageRoot -NoPrompt } else { $null }

    try {

    # A subset removal leaves the domain standing, so only tear the trust down
    # when the whole domain goes or its DC does.
    if ($all -or $DC) {
        Remove-ForestTrust -DomainName $DomainName
    }

    # When removing the full domain ($all) or the DC, every VM is going
    # away -- skip the expensive per-client proxy unconfiguration inside
    # Remove-VirtualMachine.
    $removingDomain = ($all -or [bool]$DC)

    # Capture parent's $Common so ThreadJob workers can skip the init block.
    # ThreadJobs share the same process, so $using: gives the live object.
    $parentCommon = $global:Common

    $DeleteVMs = {
    
        try {
            $global:ScriptBlockName = "Delete Domain"
            # Dot source common
            #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    
            $rootPath = Split-Path $using:PSScriptRoot -Parent
            # Pre-seed $global:Common from the parent so Common.ps1's init
            # block (if -not $Common.Initialized) is skipped. The dot-source
            # still loads all function definitions; only the expensive init
            # (New-Directory x15, git branch, storage, etc.) is avoided.
            $global:Common = $using:parentCommon
            . $rootPath\Common.ps1 -InJob -StartupProfile RemoveOnly -VerboseEnabled:$using:enableVerbose -DevBranch:$using:devBranchValue

            $currentItem = $using:currentItem
            $Phase = $using:Phase
            $vm = $currentItem
            # Pass the already-resolved VM record so the worker doesn't
            # re-enumerate every VM on the host (~1s/worker saved).
            $null = Remove-VirtualMachine -VmName $vm.VmName -VmRecord $vm -RemovingDomain:$using:removingDomain
            Write-Log "[Phase $Phase]: $($vm.vmName): Remove VM Successful" -OutputStream -Success
        }
        catch {
            Write-Log "[Phase $Phase]: $($vm.vmName): Failed to delete VM. $($_.Exception.Message)" -OutputStream -Failure
            Write-Log "$($_.ScriptStackTrace)" -LogOnly
        }
    }


    $result = $null
    if ($vmsToDelete) {        
        # PreferThreadJob: removes share parent's Hyper-V/DhcpServer modules
        # and skip a fresh powershell.exe process per VM -- each worker's
        # init drops from ~10s to ~1-2s when combined with StartupProfile Fast.
        $start = Start-NormalJobs -machines $vmsToDelete -ScriptBlock $DeleteVMs -Phase "DomainRemove" -PreferThreadJob

        $result = Wait-Phase -Phase "DomainRemove" -Jobs $start.Jobs -AdditionalData $start.AdditionalData           
        
    }
    else {
        Write-Log "No virtual machines found for '$DomainName'." -Warning
    }

    if ($all -and -not $WhatIf) {
        if ($result -and $result.Failed -gt 0) {
            Write-Log "Parallel removal reported $($result.Failed) failed VM job(s); checking live Hyper-V state before removing network resources." -Warning
        }

        $survivors = @(Get-DomainHyperVVM -DomainName $DomainName -VmStorageRoot $vmStorageRoot)
        if ($survivors.Count -gt 0) {
            Write-Log "Live Hyper-V verification found $($survivors.Count) VM(s) still registered for '$DomainName': $($survivors.Name -join ', '). Retrying them once serially." -Warning
            $refreshedRecords = @(Get-List -Type VM -DomainName $DomainName -SmartUpdate)
            foreach ($survivor in $survivors) {
                $vmRecord = $refreshedRecords | Where-Object { $_.vmID -eq $survivor.vmID } | Select-Object -First 1
                try {
                    if ($vmRecord) {
                        $null = Remove-VirtualMachine -VmName $survivor.Name -VmRecord $vmRecord -RemovingDomain
                    }
                    else {
                        $null = Remove-VirtualMachine -VmName $survivor.Name -RemovingDomain
                    }
                }
                catch {
                    Write-Log "Serial removal retry failed for '$($survivor.Name)': $($_.Exception.Message)" -Failure
                }
            }

            $survivors = @(Get-DomainHyperVVM -DomainName $DomainName -VmStorageRoot $vmStorageRoot)
        }

        if ($survivors.Count -gt 0) {
            foreach ($survivor in $survivors) {
                Write-Log "Still registered: $($survivor.Name) (state=$($survivor.State), id=$($survivor.VMId), path='$($survivor.Path)')." -Failure
            }
            throw "Domain removal stopped because $($survivors.Count) VM(s) for '$DomainName' remain registered in Hyper-V. DHCP scopes and switches were left intact."
        }
    }

    # Gate on $all, not on the DC: a missing DC used to leak the whole domain's
    # networking, and a subset removal that happened to include the DC used to
    # delete the switches out from under the VMs that were staying.
    if ($all) {
        if ($scopesToDelete) {
            Write-Log "Removing ALL DHCP Scopes for '$DomainName'" -Activity
            foreach ($scope in $scopesToDelete) {
                Remove-DhcpScope -ScopeId $scope -WhatIf:$WhatIf
            }

            # Remove-VMSwitch2 now also removes the NAT + DHCP scope for
            # the network, so the explicit NAT loop is no longer needed.
            Write-Log "Removing ALL Hyper-V Switches for '$DomainName'" -Activity
            foreach ($scope in $scopesToDelete) {
                Remove-VMSwitch2 -NetworkName $scope -WhatIf:$WhatIf
            }
        }
        else {
            Write-Log "No DHCP scopes or Hyper-V switches are attributable to '$DomainName'." -Warning
        }
    }

    } # end try
    finally {
        # Sweep for orphaned NATs whose switch is already gone.
        # This catches leaks from partial deployments, crashes, or
        # cases where VMs were deleted before Remove-Lab ran.
        if (-not $WhatIf.IsPresent) {
            Remove-OrphanedNetNats
        }
    }

    if (-not $WhatIf.IsPresent) {
        Get-List -type VM -SmartUpdate | Out-Null
        New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
        New-MRemoteNGFileFromHyperV -MRemoteNGFile $Global:Common.MRemoteNGFilePath
        Restore-TerminalFocus
        Write-Host
    }
    
    if ($all) {
        if ($vmStorageRoot) {
            $domainFolder = Join-Path $vmStorageRoot $DomainName
            if (Test-Path $domainFolder) {
                Write-Log "Removing $DomainName folder" -SubActivity
                $domainFolderRemoved = Remove-ItemWithRetry -Path $domainFolder -MaxAttempts 3 -DelaySeconds 5 -WhatIf:$WhatIf
                if (-not $domainFolderRemoved -and -not $WhatIf) {
                    Write-Log "Domain folder '$domainFolder' remains after cleanup retries. Identifying every process with an open handle below it." -Warning
                    $null = Stop-LockingProcesses -FolderPath $domainFolder -IdentifyOnly
                    $survivors = @(Get-DomainHyperVVM -DomainName $DomainName -VmStorageRoot $vmStorageRoot)
                    foreach ($survivor in $survivors) {
                        Write-Log "Registered VM still references the folder: $($survivor.Name) (state=$($survivor.State), id=$($survivor.VMId), path='$($survivor.Path)')." -Failure
                    }
                    throw "Could not remove domain folder '$domainFolder' after 3 attempts. Lock owners were reported above."
                }
            }
        }
    }

    Start-Sleep -seconds 3
}

function Remove-All {

    param (
        [Parameter()]
        [switch] $WhatIf
    )

    $vmsToDelete = Get-List -Type VM
    # Get all unique switches across all domains (no DomainName filter)
    $scopesToDelete = Get-List -Type UniqueSwitch

    try {

    if ($vmsToDelete) {
        Write-Log "Removing ALL virtual machines" -Activity
        foreach ($vm in $vmsToDelete) {
            Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf -RemovingDomain
        }
    }

    if ($scopesToDelete) {
        Write-Log "Removing ALL DHCP Scopes" -Activity
        foreach ($scope in $scopesToDelete) {
            Remove-DhcpScope -ScopeId $scope -WhatIf:$WhatIf
        }

        # Remove-VMSwitch2 now also removes the NAT + DHCP scope
        Write-Log "Removing ALL Hyper-V Switches" -Activity
        foreach ($scope in $scopesToDelete) {
            Remove-VMSwitch2 -NetworkName $scope -WhatIf:$WhatIf
        }
    }

    } # end try
    finally {
        # Sweep for any NATs that survived (switch already gone, partial
        # deploy, VMs deleted externally, etc.)
        if (-not $WhatIf.IsPresent) {
            Remove-OrphanedNetNats
        }
    }

    Remove-Orphaned -WhatIf:$WhatIf
    Remove-Item -Path $Global:Common.RdcManFilePath -Force -WhatIf:$WhatIf -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue| Out-Null
    Remove-Item -Path $Global:Common.MRemoteNGFilePath -Force -WhatIf:$WhatIf -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue| Out-Null

    # Get all the folders in the host VM-storage root and delete them
    $vmStorageRoot = Get-MemlabsVmStorageRoot -NoPrompt
    if ($vmStorageRoot -and (Test-Path $vmStorageRoot)) {
        $folders = Get-ChildItem -Path $vmStorageRoot -Directory -ErrorAction SilentlyContinue
        foreach ($folder in $folders) {
            Write-Log "Removing $($folder.Name) folder" -SubActivity
            Remove-Item -Path $folder.FullName -Recurse -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue
        }
    }

    Write-Host

}