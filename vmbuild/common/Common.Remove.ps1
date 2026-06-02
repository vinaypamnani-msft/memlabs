# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
########################
### Remove Functions ###
########################

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

    # Helper: retry Remove-Item with configurable attempts and delay
    function Remove-ItemWithRetry {
        param (
            [string] $Path,
            [int]    $MaxAttempts = 3,
            [int]    $DelaySeconds = 5,
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
        try {
            $VM | Stop-VM -TurnOff -Force -WhatIf:$WhatIf -WarningAction SilentlyContinue -ErrorAction Stop
        }
        catch {
            Write-Log "TurnOff failed: $($_.Exception.Message)" -Warning
        }

        if ($WhatIf) { return $true }

        # Poll until Off or timeout
        $elapsed = 0
        while ($elapsed -lt $TimeoutSeconds) {
            Start-Sleep -Seconds 1
            $elapsed += 1
            $refreshed = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
            if (-not $refreshed -or $refreshed.State -eq "Off") {
                Write-Log "VM '$($VM.Name)' is now Off." -SubActivity
                return $true
            }
        }

        Write-Log "VM '$($VM.Name)' did not reach Off state within $TimeoutSeconds seconds." -Warning
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
        Write-Log "$VmName`: Removing $($vmFromList.ClusterIPAddress) Exclusion..." -HostOnly
        Remove-DhcpServerv4ExclusionRange -ScopeId 10.250.250.0 `
            -StartRange $vmFromList.ClusterIPAddress -EndRange $vmFromList.ClusterIPAddress `
            -ErrorAction SilentlyContinue -WhatIf:$WhatIf
    }
    if ($vmFromList.AGIPAddress) {
        Write-Log "$VmName`: Removing $($vmFromList.AGIPAddress) Exclusion..." -HostOnly
        Remove-DhcpServerv4ExclusionRange -ScopeId 10.250.250.0 `
            -StartRange $vmFromList.AGIPAddress -EndRange $vmFromList.AGIPAddress `
            -ErrorAction SilentlyContinue -WhatIf:$WhatIf
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
        Write-Log "Remove-VM failed for '$VmName': $($_.Exception.Message)" -Warning
    }

    # -- Folder removal (after Remove-VM has released file handles) --
    $folderRemoved = $false
    if (-not $Migrate) {
        if (Test-Path $vmTest.Path) {
            Write-Log "$VmName`: Purging $($vmTest.Path) folder..." -HostOnly
            $folderRemoved = Remove-ItemWithRetry -Path $vmTest.Path -MaxAttempts 3 -DelaySeconds 5 -WhatIf:$WhatIf
            if (-not $folderRemoved) {
                Write-Log "$VmName`: WARNING - Folder '$($vmTest.Path)' could not be removed. Manual cleanup required." -Warning
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

    Write-Log "Detecting orphaned DHCP Scopes" -Activity
    $scopes = Get-DhcpServerv4Scope
    foreach ($scope in $scopes) {
        $scopeId = $scope.ScopeId.ToString() # This requires us to replace "Internet" with subnet
        if ($vmNetworksInUse2 -notcontains $scopeId) {
            $response = Read-YesOrNoWithTimeout -Prompt "  DHCP Scope '$($scope.Name) [$($scope.ScopeId)]' may be orphaned. Delete DHCP Scope? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-DhcpScope -ScopeId $scopeId -WhatIf:$WhatIf
            }
            Write-Host
        }
    }

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
            Write-Host
        }
    }

    Write-Log "Detecting orphaned NAT entries" -Activity
    $natEntries = Get-NetNat -ErrorAction SilentlyContinue
    foreach ($nat in $natEntries) {
        # Memlabs NAT entries are named with the subnet (e.g. 192.168.1.0).
        # Skip entries whose name doesn't look like a subnet -- they belong
        # to something else (e.g. Docker, WSL).
        if ($nat.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
        if ($vmNetworksInUse2 -notcontains $nat.Name) {
            $response = Read-YesOrNoWithTimeout -Prompt "  NAT entry '$($nat.Name)' ($($nat.InternalIPInterfaceAddressPrefix)) may be orphaned. Delete? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-NetNat -Name $nat.Name -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "Removed orphaned NAT entry '$($nat.Name)'" -SubActivity
            }
            Write-Host
        }
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
        $vmsToDelete = Get-List -Type VM -DomainName $DomainName | Where-Object { $_.vmName -in $VMList }
    }
    else {
        $vmsToDelete = Get-List -Type VM -DomainName $DomainName
        $all = $true
    }
    $DC = $vmsToDelete | Where-Object { $_.Role -eq "DC" }

    $scopesToDelete = Get-List -Type UniqueSwitch -DomainName $DomainName | Where-Object { $_ -ne "Internet" -and $_ -ne "Cluster" } # Internet subnet could be shared between multiple domains

    if ($DC) {
        Remove-ForestTrust -DomainName $DomainName
    }

    # When removing the full domain ($all) or the DC, every VM is going
    # away -- skip the expensive per-client proxy unconfiguration inside
    # Remove-VirtualMachine.
    $removingDomain = ($all -or [bool]$DC)

    $DeleteVMs = {
    
        try {
            $global:ScriptBlockName = "Delete Domain"
            # Dot source common
            #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    
            $rootPath = Split-Path $using:PSScriptRoot -Parent
            # StartupProfile Fast skips Initialize-Storage (the main remaining
            # cost in -InJob mode) plus the 4 InJob-already-skipped probes.
            # Remove-VirtualMachine only needs Get-List / Get-VM2 / DHCP cmdlets
            # / $Common.CachePath -- none of which depend on storage init,
            # supported-options, hotfix lookup, or env detection.
            . $rootPath\Common.ps1 -InJob -StartupProfile Fast -VerboseEnabled:$using:enableVerbose -DevBranch:$using:devBranchValue

            $currentItem = $using:currentItem
            $Phase = $using:Phase
            $vm = $currentItem
            # Pass the already-resolved VM record so the worker doesn't
            # re-enumerate every VM on the host (~1s/worker saved).
            Remove-VirtualMachine -VmName $vm.VmName -VmRecord $vm -RemovingDomain:$using:removingDomain
            Write-Log "[Phase $Phase]: $($vm.vmName): Remove VM Successful" -OutputStream -Success
        }
        catch {
            Write-Log "[Phase $Phase]: $($vm.vmName): Failed to delete VM. $($_.Exception.Message)" -OutputStream -Failure
            Write-Log "$($_.ScriptStackTrace)" -LogOnly
        }
    }


    if ($vmsToDelete) {        
        # PreferThreadJob: removes share parent's Hyper-V/DhcpServer modules
        # and skip a fresh powershell.exe process per VM -- each worker's
        # init drops from ~10s to ~1-2s when combined with StartupProfile Fast.
        $start = Start-NormalJobs -machines $vmsToDelete -ScriptBlock $DeleteVMs -Phase "DomainRemove" -PreferThreadJob

        $result = Wait-Phase -Phase "DomainRemove" -Jobs $start.Jobs -AdditionalData $start.AdditionalData           
        
    }


    if ($DC) {
        if ($scopesToDelete) {
            Write-Log "Removing ALL DHCP Scopes for '$DomainName'" -Activity
            foreach ($scope in $scopesToDelete) {
                Remove-DhcpScope -ScopeId $scope -WhatIf:$WhatIf
            }

            Write-Log "Removing ALL Hyper-V Switches for '$DomainName'" -Activity
            foreach ($scope in $scopesToDelete) {
                Remove-VMSwitch2 -NetworkName $scope -WhatIf:$WhatIf
            }

            Write-Log "Removing NAT entries for '$DomainName'" -Activity
            foreach ($scope in $scopesToDelete) {
                $nat = Get-NetNat -Name $scope -ErrorAction SilentlyContinue
                if ($nat) {
                    Write-Log "Removing NAT entry '$scope'" -SubActivity
                    if (-not $WhatIf) {
                        Remove-NetNat -Name $scope -Confirm:$false -ErrorAction SilentlyContinue
                    }
                }
            }
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
        if (Test-Path "E:\virtualMachines\$DomainName") {
            Write-Log "Removing $DomainName folder" -SubActivity
            Remove-Item -Path "E:\virtualMachines\$DomainName" -Recurse -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue
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
    $scopesToDelete = Get-List -Type UniqueSwitch -DomainName $DomainName

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

        Write-Log "Removing ALL Hyper-V Switches" -Activity
        foreach ($scope in $scopesToDelete) {
            Remove-VMSwitch2 -NetworkName $scope -WhatIf:$WhatIf
        }

        Write-Log "Removing ALL NAT entries" -Activity
        foreach ($scope in $scopesToDelete) {
            $nat = Get-NetNat -Name $scope -ErrorAction SilentlyContinue
            if ($nat) {
                Write-Log "Removing NAT entry '$scope'" -SubActivity
                if (-not $WhatIf) {
                    Remove-NetNat -Name $scope -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Remove-Orphaned -WhatIf:$WhatIf
    Remove-Item -Path $Global:Common.RdcManFilePath -Force -WhatIf:$WhatIf -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue| Out-Null
    Remove-Item -Path $Global:Common.MRemoteNGFilePath -Force -WhatIf:$WhatIf -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue| Out-Null

    # Get all the folders in E:\VirtualMachines and delete them
    $folders = Get-ChildItem -Path "E:\VirtualMachines" -Directory
    foreach ($folder in $folders) {
        Write-Log "Removing $($folder.Name) folder" -SubActivity
        Remove-Item -Path $folder.FullName -Recurse -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue
    }

    Write-Host

}