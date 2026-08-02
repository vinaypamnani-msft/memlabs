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

    # Fast pre-check: the vmms service is registered when the Hyper-V role is
    # installed and the Hyper-V PowerShell module ships with Hyper-V-PowerShell.
    # Both checks are local-registry lookups (sub-millisecond) — far faster
    # than Get-WindowsFeature, which goes through ServerManager/CIM and can
    # stall for minutes when WMI is busy or the system is under load.
    # Skip the slow CIM call entirely when both signals say "installed".
    if (-not $hvInstalled) {
        $vmmsRegistered = [bool](Get-Service -Name vmms -ErrorAction SilentlyContinue)
        $hvModuleAvailable = [bool](Get-Command -Name Get-VM -Module Hyper-V -ErrorAction SilentlyContinue)
        if ($vmmsRegistered -and $hvModuleAvailable) {
            $hvInstalled = $true
            Write-Log "Install-HyperV: Hyper-V detected via vmms service + Hyper-V module (skipped Get-WindowsFeature)." -LogOnly
            try {
                [PSCustomObject]@{
                    CheckedUtc = (Get-Date).ToUniversalTime().ToString("o")
                    Installed  = $true
                } | ConvertTo-Json | Set-Content -Path $hvCacheFile -Encoding UTF8
            }
            catch {}
        }
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

    $vmmsService = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $vmmsService) {
        throw "Install-HyperV: The Hyper-V Virtual Machine Management Service (vmms) is not registered on this host. Hyper-V does not appear to be installed."
    }
    if ($vmmsService.Status -ne "Running") {
        Start-Service vmms
        if ((Get-Service -Name vmms).Status -eq "Running") {
            Write-Log "Hyper-V Virtual Machine Management Service started successfully." -Success
        }
        else {
            throw "Install-HyperV: Failed to start the Hyper-V Virtual Machine Management Service (vmms). Cannot continue without Hyper-V."
        }
    }

    # Wait for vmms to be genuinely READY, not just "Running". Immediately after
    # the service transitions to Running (cold host boot, or a just-started
    # service), the VM object store isn't warm yet and the first Get-VM throws
    # "Hyper-V encountered an error trying to access an object ... because the
    # object was not found. ... Verify that the Virtual Machine Management
    # service on the computer is running." Downstream callers (Get-List at
    # Common.Config.ps1, Start-Maintenance -> Get-VMFixes) then cascade into a
    # cryptic null-valued-expression crash. Poll Get-VM here until it succeeds
    # so the rest of the run sees a ready service instead of failing hard.
    $vmmsReadyTimeoutSec = 120
    $vmmsReadySw = [System.Diagnostics.Stopwatch]::StartNew()
    $vmmsReady = $false
    $lastVmmsError = $null
    while ($vmmsReadySw.Elapsed.TotalSeconds -lt $vmmsReadyTimeoutSec) {
        try {
            # -ErrorAction Stop so the transient "object was not found" surfaces
            # as a catchable exception instead of a non-terminating error.
            $null = Get-VM -ErrorAction Stop
            $vmmsReady = $true
            break
        }
        catch {
            $lastVmmsError = $_.Exception.Message
            Start-Sleep -Seconds 3
        }
    }
    $vmmsReadySw.Stop()

    if (-not $vmmsReady) {
        throw "Install-HyperV: Hyper-V Virtual Machine Management Service (vmms) reports Running but is not answering Get-VM after $vmmsReadyTimeoutSec seconds. Last error: $lastVmmsError"
    }
    elseif ($vmmsReadySw.Elapsed.TotalSeconds -ge 3) {
        Write-Log "Install-HyperV: vmms became ready for Get-VM after $([Math]::Round($vmmsReadySw.Elapsed.TotalSeconds,1))s." -LogOnly
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

    # NOTE: Get-VM -Id is queried with -ErrorAction SilentlyContinue throughout.
    # Get-List can return a STALE cache entry whose vmId no longer exists in
    # Hyper-V (e.g. the VM was deleted out-of-band, or Remove-Lab is cleaning up
    # after a partial teardown). A bare Get-VM -Id THROWS "Hyper-V was unable to
    # find a virtual machine with id ..." on such an entry, which aborted callers
    # like Remove-Lab. Returning $null on a stale id and falling through to a
    # cache refresh lets the caller treat the VM as gone (which it is).
    $vmFromList = Get-List -Type VM | Where-Object { $_.vmName -eq $Name }

    if ($vmFromList) {
        $vm = Get-VM -Id $vmFromList.vmId -ErrorAction SilentlyContinue
        if ($vm) { return $vm }
        # Stale cache entry: id no longer in Hyper-V. Fall through to refresh.
    }

    $vmFromList = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $Name }
    if ($vmFromList) {
        $vm = Get-VM -Id $vmFromList.vmId -ErrorAction SilentlyContinue
        if ($vm) { return $vm }
    }

    # VM may exist, without vmNotes object, try fallback if caller explicitly wants it.
    if ($Fallback.IsPresent) {
        return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
    }

    return [System.Management.Automation.Internal.AutomationNull]::Value
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

        # Always attempt NAT + DHCP cleanup for this network, even if the
        # switch was already gone.  This closes the leak where a switch is
        # removed but the NAT / DHCP scope survives.
        if (-not $WhatIf) {
            $nat = Get-NetNat -Name $NetworkName -ErrorAction SilentlyContinue
            if ($nat) {
                Write-Log "  Removing NAT '$NetworkName'" -SubActivity
                Remove-NetNat -Name $NetworkName -Confirm:$false -ErrorAction SilentlyContinue
            }
            $dhcp = Get-DhcpServerv4Scope -ScopeID $NetworkName -ErrorAction SilentlyContinue
            if ($dhcp) {
                Write-Log "  Removing DHCP scope '$NetworkName'" -SubActivity
                $dhcp | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
            }
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

# Best-effort host memory reclamation, used before retrying a Start-VM that
# failed with OOM (0x8007000E). Nothing here kills a process or touches a VM -
# it only asks Windows to hand physical RAM back to the available pool so the
# next Start-VM has room to back the guest's startup memory:
#
#   1. .NET GC in THIS host process. The parent pwsh holds the whole
#      deployConfig, loaded modules and per-phase state; a full collect +
#      finalize + compacting LOH collect frees managed heap.
#   2. Trim the working set of every pwsh/powershell process (this one and the
#      ~N concurrent VM_Create job workers). SetProcessWorkingSetSize(-1,-1)
#      tells Windows to page each process down to its minimum resident set,
#      pushing private committed pages out to the pagefile and returning the
#      physical frames to the free/zeroed list. The pages fault back in on
#      demand, so this is safe - just slower for those idle workers.
#   3. Flush the system file cache working set (SetSystemFileCacheSize with
#      -1,-1), releasing cached file pages that Phase 1's VHD copy/inject left
#      resident.
#
# Returns the change in '\Memory\Available MBytes' (MB freed) for logging.
function Invoke-HostMemoryReclaim {
    [CmdletBinding()]
    param(
        [switch]$CurrentProcessOnly
    )

    $beforeMB = $null
    try { $beforeMB = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue } catch {}

    # Native helpers (idempotent Add-Type; -ErrorAction SilentlyContinue so a
    # second load in the same session is a no-op).
    try {
        if (-not ('MemLabs.MemReclaim' -as [type])) {
            Add-Type -ErrorAction SilentlyContinue -Namespace 'MemLabs' -Name 'MemReclaim' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetProcessWorkingSetSize(System.IntPtr proc, System.IntPtr min, System.IntPtr max);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetSystemFileCacheSize(System.IntPtr minSize, System.IntPtr maxSize, int flags);
'@
        }
    }
    catch {}

    # Snapshot after one-time Add-Type initialization so helper compilation is
    # not mistaken for private-memory growth caused by cleanup.
    $beforeWorkingSetMB = $null
    $beforePrivateMB = $null
    $managedBeforeMB = $null
    try {
        $beforeProcess = Get-Process -Id $PID -ErrorAction Stop
        $beforeWorkingSetMB = [Math]::Round($beforeProcess.WorkingSet64 / 1MB, 0)
        $beforePrivateMB = [Math]::Round($beforeProcess.PrivateMemorySize64 / 1MB, 0)
        $managedBeforeMB = [Math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 0)
    }
    catch {}

    # 1. Managed GC in the host process.
    try {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
    }
    catch {}

    # 2. Trim working sets of our PowerShell processes (host + job workers).
    $trimmed = 0
    try {
        $psProcs = if ($CurrentProcessOnly) {
            @(Get-Process -Id $PID -ErrorAction SilentlyContinue)
        }
        else {
            @(Get-Process -Name 'pwsh', 'powershell' -ErrorAction SilentlyContinue)
        }
        foreach ($p in $psProcs) {
            try {
                if ([MemLabs.MemReclaim]::SetProcessWorkingSetSize($p.Handle, [System.IntPtr](-1), [System.IntPtr](-1))) {
                    $trimmed++
                }
            }
            catch {}
        }
    }
    catch {}

    # 3. Flush the system file cache working set during host-wide OOM recovery.
    if (-not $CurrentProcessOnly) {
        try { [void][MemLabs.MemReclaim]::SetSystemFileCacheSize([System.IntPtr](-1), [System.IntPtr](-1), 0) } catch {}
    }

    $afterMB = $null
    try { $afterMB = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue } catch {}
    $afterWorkingSetMB = $null
    $afterPrivateMB = $null
    $managedAfterMB = $null
    try {
        $afterProcess = Get-Process -Id $PID -ErrorAction Stop
        $afterWorkingSetMB = [Math]::Round($afterProcess.WorkingSet64 / 1MB, 0)
        $afterPrivateMB = [Math]::Round($afterProcess.PrivateMemorySize64 / 1MB, 0)
        $managedAfterMB = [Math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 0)
    }
    catch {}

    $freedMB = if (($null -ne $beforeMB) -and ($null -ne $afterMB)) { [Math]::Round($afterMB - $beforeMB, 0) } else { $null }
    try {
        if ($CurrentProcessOnly -and ($null -ne $beforeWorkingSetMB) -and ($null -ne $afterWorkingSetMB)) {
            Write-Log "Invoke-HostMemoryReclaim: launcher pid $PID after cleanup - managed ${managedBeforeMB}MB -> ${managedAfterMB}MB, private ${beforePrivateMB}MB -> ${afterPrivateMB}MB, WS ${beforeWorkingSetMB}MB -> ${afterWorkingSetMB}MB" -LogOnly
        }
        elseif ($null -ne $freedMB) {
            Write-Log "Invoke-HostMemoryReclaim: GC + trimmed $trimmed PowerShell working set(s) + flushed file cache; available memory changed by ${freedMB}MB (now $([Math]::Round($afterMB,0))MB)" -LogOnly
        }
        else {
            Write-Log "Invoke-HostMemoryReclaim: GC + trimmed $trimmed PowerShell working set(s) + flushed file cache" -LogOnly
        }
    }
    catch {}

    return $freedMB
}

function Write-HostMemoryPressureDiag {
    <#
    .SYNOPSIS
    Log WHICH VMs are holding the host's RAM, so a memory failure is actionable.

    .DESCRIPTION
    The Phase 1 OOM on CSTest2-H burned 22 minutes and a full rollback, and the
    only memory evidence in the log was a running "~8.6GB available" counter. That
    says the host is full but not what filled it -- and on a cumulative CSTest run
    the answer ("the previous lab's VMs are still up") is the whole fix.
    Lists running VMs by assigned memory, plus the dynamic-memory demand/assigned
    split that decides whether waiting will actually free anything. Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$Context = 'memory pressure',
        [switch]$OutputStream
    )

    function Write-MemDiagLine {
        param([string]$Text)
        if ($OutputStream) { Write-Log "[MemDiag] $Context`: $Text" -OutputStream } else { Write-Log "[MemDiag] $Context`: $Text" -LogOnly }
    }

    try {
        $availMB = $null
        try { $availMB = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue } catch { }
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $totalGB = if ($os) { [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1) } else { 0 }
        Write-MemDiagLine ("host total={0}GB available={1}GB" -f $totalGB, $(if ($availMB) { [Math]::Round($availMB / 1024, 1) } else { '?' }))

        $running = @(Get-VM2 -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' })
        $assignedGB = 0
        foreach ($v in $running) { try { $assignedGB += $v.MemoryAssigned } catch { } }
        $assignedGB = [Math]::Round($assignedGB / 1GB, 1)
        Write-MemDiagLine ("{0} running VM(s) holding {1}GB assigned" -f $running.Count, $assignedGB)

        # Group by lab prefix -- on a cumulative CSTest run this immediately names
        # the earlier lab whose VMs are the ones to shut down.
        $byPrefix = $running | Group-Object { ("$($_.Name)" -split '-')[0] } | Sort-Object { ($_.Group | Measure-Object MemoryAssigned -Sum).Sum } -Descending
        foreach ($g in $byPrefix) {
            $gb = [Math]::Round((($g.Group | Measure-Object MemoryAssigned -Sum).Sum) / 1GB, 1)
            Write-MemDiagLine ("  prefix '{0}': {1} VM(s), {2}GB" -f $g.Name, $g.Count, $gb)
        }

        foreach ($v in ($running | Sort-Object MemoryAssigned -Descending | Select-Object -First 12)) {
            $a = [Math]::Round($v.MemoryAssigned / 1MB)
            $d = 0
            try { $d = [Math]::Round($v.MemoryDemand / 1MB) } catch { }
            # assigned >> demand on a dynamic VM = memory that WILL come back on its
            # own; assigned ~= demand = it is genuinely in use and waiting is futile.
            $slack = $a - $d
            Write-MemDiagLine ("  {0,-18} assigned={1,6}MB demand={2,6}MB reclaimable~={3,6}MB dynamic={4} status='{5}'" -f $v.Name, $a, $d, $slack, $v.DynamicMemoryEnabled, $v.MemoryStatus)
        }
    }
    catch { try { Write-MemDiagLine "diag failed: $($_.Exception.Message)" } catch { } }
}

function Write-PowerShellJobLeakDiag {
    <#
    .SYNOPSIS
    Inventory the PowerShell jobs and job worker processes this process still owns.

    .DESCRIPTION
    Every Start-Job spawns a `pwsh.exe -s -NoLogo -NoProfile` child, and memlabs
    starts one per VM per phase (VM_Create, VM_Config, Proxy_Install,
    Linux_Configure) plus one per Copy-ItemSafe. Measured, a worker costs ~85MB
    idle and 300MB+ once it has dot-sourced Common.ps1 -- so a lab host showing
    39 pwsh processes / 7.6GB is holding roughly a phase's worth of workers that
    never went away. That is memory the Phase 1 pre-flight then finds missing.

    A worker exits on its own the moment its scriptblock completes (verified:
    temp/probe-job-child-pids2.ps1 -- Remove-Job is NOT required for the process
    to go), so anything still alive here is a job that never finished, and the
    only way to know which is to name it.

    Reports jobs by state with age and name, plus every pwsh descendant of this
    process with its working set. Best-effort; never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$Context = 'end of run',
        [switch]$Quiet
    )

    $result = [pscustomobject]@{ Jobs = 0; RunningJobs = 0; WorkerProcs = 0; WorkerMB = 0; SelfMB = 0 }

    try {
        $jobs = @(Get-Job -ErrorAction SilentlyContinue)
        $result.Jobs = $jobs.Count
        $result.RunningJobs = @($jobs | Where-Object { $_.State -eq 'Running' }).Count

        # This process's own footprint. The launcher is the single biggest
        # PowerShell consumer on a long run (observed 2.27GB after 33h under
        # Start-Test -All) and none of the per-worker accounting explains it.
        # clrHeap vs ws is the fork in the road: if the CLR heap is small while
        # the working set is huge, the growth is unmanaged (handles/CIM/
        # fragmentation) and no amount of clearing PowerShell state will help.
        try {
            $self = Get-Process -Id $PID -ErrorAction Stop
            $result.SelfMB = [Math]::Round($self.WorkingSet64 / 1MB)
            $gcMB = [Math]::Round([GC]::GetTotalMemory($false) / 1MB)
            $selfAge = -1
            try { $selfAge = [Math]::Round(((Get-Date) - $self.StartTime).TotalMinutes) } catch { }
            $cacheCounts = @()
            try { if ($global:ps_cache) { $cacheCounts += "ps_cache=$(@($global:ps_cache.Keys).Count)" } } catch { }
            try { if ($global:vm_List) { $cacheCounts += "vm_List=$(@($global:vm_List).Count)" } } catch { }
            try { if ($global:ps_inflight) { $cacheCounts += "ps_inflight=$(@($global:ps_inflight.Keys).Count)" } } catch { }
            Write-Log "[JobLeak] $Context`: this process age=${selfAge}m ws=$($result.SelfMB)MB private=$([Math]::Round($self.PrivateMemorySize64/1MB))MB clrHeap=${gcMB}MB handles=$($self.HandleCount) threads=$($self.Threads.Count) $($cacheCounts -join ' ')" -LogOnly

            # Log buffers retain StringBuilder CAPACITY across flushes -- Length=0
            # does not release chunks -- and Start-Test keeps one entry per log
            # path for every lab it has ever built in this shell.
            try {
                $bufTotal = 0
                $bufCount = 0
                foreach ($k in @($global:LogBuffers.Keys)) {
                    $b = $global:LogBuffers[$k].Builder
                    if ($b) { $bufTotal += $b.Capacity; $bufCount++ }
                }
                if ($bufCount -gt 0) {
                    Write-Log "[JobLeak] $Context`: $bufCount log buffer(s) retaining $([Math]::Round($bufTotal/1KB))KB of StringBuilder capacity." -LogOnly
                }
            }
            catch { }

            # Biggest global collections. A launcher that grows GB over a multi-lab
            # run is accumulating in one of these; naming the top few turns a
            # guess into a measurement.
            try {
                $big = @()
                foreach ($v in @(Get-Variable -Scope Global -ErrorAction SilentlyContinue)) {
                    if ($v.Name -in 'args', 'input', 'PSBoundParameters', 'MyInvocation', 'PSCmdlet', 'Matches', 'Error', 'foreach', 'switch', 'this', '_') { continue }
                    $val = $v.Value
                    if ($null -eq $val) { continue }
                    $count = 0
                    if ($val -is [string]) { $count = $val.Length }
                    elseif ($val -is [System.Collections.ICollection]) { $count = $val.Count }
                    else { continue }
                    if ($count -ge 1000) { $big += [pscustomobject]@{ Name = $v.Name; Count = $count; Type = $val.GetType().Name } }
                }
                foreach ($b in ($big | Sort-Object Count -Descending | Select-Object -First 8)) {
                    Write-Log "[JobLeak] $Context`: large global `$$($b.Name) [$($b.Type)] holds $($b.Count) item(s)/char(s)." -LogOnly
                }
                # Every swallowed catch in this codebase still appends to $Error, and
                # an ErrorRecord can retain whatever object threw (job objects, big
                # strings). PS7 caps the list, so a count at the cap means it is full.
                try { Write-Log "[JobLeak] $Context`: `$Error holds $(@($global:Error).Count) retained ErrorRecord(s)." -LogOnly } catch { }
            }
            catch { }
        }
        catch { }

        # Job workers are children of THIS process; a worker that itself started a
        # job (Copy-ItemSafe inside a phase worker) adds a grandchild, so walk the
        # whole tree rather than one level.
        $all = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue)
        $byParent = @{}
        foreach ($p in $all) {
            $key = [int]$p.ParentProcessId
            if (-not $byParent.ContainsKey($key)) { $byParent[$key] = @() }
            $byParent[$key] += $p
        }
        $descendants = New-Object System.Collections.Generic.List[object]
        $queue = New-Object System.Collections.Generic.Queue[int]
        $queue.Enqueue([int]$PID)
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            foreach ($child in @($byParent[$cur])) {
                if (-not $child) { continue }
                $descendants.Add($child)
                $queue.Enqueue([int]$child.ProcessId)
            }
        }

        $totalMB = 0
        $rows = New-Object System.Collections.Generic.List[string]
        $procInfo = New-Object System.Collections.Generic.List[object]
        foreach ($d in $descendants) {
            $proc = Get-Process -Id $d.ProcessId -ErrorAction SilentlyContinue
            if (-not $proc) { continue }
            $mb = [Math]::Round($proc.WorkingSet64 / 1MB)
            $totalMB += $mb
            $ageMin = -1
            $started = $null
            try { $started = $proc.StartTime; $ageMin = [Math]::Round(((Get-Date) - $started).TotalMinutes) } catch { }
            $isWorker = ("$($d.CommandLine)" -match '-s\s+-NoLogo')
            $procInfo.Add([pscustomobject]@{ Pid = [int]$d.ProcessId; MB = $mb; AgeMin = $ageMin; Started = $started; Worker = $isWorker })
            $rows.Add(("  pid={0,-7} parent={1,-7} ws={2,5}MB age={3,4}m jobWorker={4}" -f $d.ProcessId, $d.ParentProcessId, $mb, $ageMin, $isWorker))
        }
        $result.WorkerProcs = $rows.Count
        $result.WorkerMB = $totalMB

        if ($rows.Count -eq 0 -and $jobs.Count -eq 0) {
            if (-not $Quiet) { Write-Log "[JobLeak] $Context`: clean -- no PowerShell jobs and no pwsh descendants." -LogOnly }
            return $result
        }

        $summary = "[JobLeak] $Context`: $($jobs.Count) job(s) in the table ($($result.RunningJobs) still Running), $($rows.Count) pwsh descendant process(es) holding ${totalMB}MB."
        if ($rows.Count -gt 0 -or $result.RunningJobs -gt 0) { Write-Log $summary -Warning }
        else { Write-Log $summary -LogOnly }

        # Pair each job with the worker process started closest to it. The job
        # object does not expose its worker pid (NewProcessConnectionInfo.Process
        # is internal and comes back empty via reflection), but a job and its
        # worker are created within ~1s of each other, so start-time proximity is
        # exact in practice -- and it is what turns "pid 14272 has been alive 5
        # hours" into "CS4-CS1SQL [DomainMember] has been stuck 5 hours".
        $unmatched = [System.Collections.Generic.List[object]]::new($procInfo)
        foreach ($j in $jobs) {
            $ageMin = -1
            $begin = $null
            try { $begin = $j.PSBeginTime; if ($begin) { $ageMin = [Math]::Round(((Get-Date) - $begin).TotalMinutes) } } catch { }
            $match = $null
            if ($begin) {
                $best = [double]::MaxValue
                foreach ($pi in $unmatched) {
                    if (-not $pi.Started) { continue }
                    $delta = [Math]::Abs(($pi.Started - $begin).TotalSeconds)
                    if ($delta -lt $best) { $best = $delta; $match = $pi }
                }
                if ($match -and $best -gt 30) { $match = $null }
            }
            $procNote = 'worker=<not matched>'
            if ($match) {
                $procNote = "worker pid=$($match.Pid) ws=$($match.MB)MB"
                [void]$unmatched.Remove($match)
            }
            Write-Log ("  job id={0,-5} state={1,-10} age={2,4}m {3} name='{4}'" -f $j.Id, $j.State, $ageMin, $procNote, $j.Name) -LogOnly
        }

        # A worker much older than its siblings is a job that never finished --
        # the one thing worth chasing when the rest are a phase legitimately in
        # flight. Compare against the median so a whole slow phase isn't flagged.
        $workerAges = @($procInfo | Where-Object { $_.Worker -and $_.AgeMin -ge 0 } | Select-Object -ExpandProperty AgeMin | Sort-Object)
        if ($workerAges.Count -ge 3) {
            $median = $workerAges[[int]($workerAges.Count / 2)]
            foreach ($pi in ($procInfo | Where-Object { $_.Worker -and $_.AgeMin -gt 30 -and $_.AgeMin -gt ($median * 3) })) {
                Write-Log "[JobLeak] $Context`: worker pid=$($pi.Pid) is $($pi.AgeMin)m old against a median of ${median}m for the other $($workerAges.Count - 1) worker(s) -- that job never finished. It is holding $($pi.MB)MB." -Warning
            }
        }

        foreach ($r in $rows) { Write-Log $r -LogOnly }
    }
    catch {
        try { Write-Log "[JobLeak] $Context`: diag failed: $($_.Exception.Message)" -LogOnly } catch { }
    }

    return $result
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
                    # Collapse the (often multi-line) Hyper-V error message to a
                    # single line BEFORE it touches any progress/log surface.
                    # Start-VM out-of-memory errors in particular come back as
                    # "'VM' failed to start.`r`n`r`nNot enough memory in the
                    # system...`r`n(0x8007000E)..." - feeding those embedded
                    # CR/LFs to the cursor-positioned Write-Progress2 renderer
                    # shoves every managed bar around and makes the host spew
                    # "...) contains new-line" hundreds of times (corrupted UI).
                    $errMsg = ($StopError.Exception.Message -replace '\s*\r?\n\s*', ' ').Trim()

                    $isOutOfMemory = ($errMsg -match '0x8007000E') -or ($errMsg -match 'not enough memory')
                    if ($isOutOfMemory) {
                        # Phase 1 starts every new VM concurrently for file
                        # injection, so the host's committed memory peaks while
                        # they all boot at once. A late VM can hit OOM
                        # (0x8007000E) on that peak even though the config "fit"
                        # the pre-flight check - the pressure is transient and
                        # eases as earlier VMs finish OOBE and their dynamic
                        # memory balloons back down. Back off and retry instead
                        # of failing the whole build and rolling everything back.
                        $oomAttempt = 0
                        $oomMaxAttempts = 6
                        $oomBackoffSec = 30
                        while (($oomAttempt -lt $oomMaxAttempts) -and ($vm.State -ne 'Running')) {
                            $oomAttempt++

                            # Diagnostics: how much RAM is free, and which host
                            # processes are holding it. We deliberately do NOT
                            # auto-kill anything (killing the wrong host process
                            # can corrupt a running VM or take down Hyper-V) -
                            # we surface the top consumers so the operator can
                            # decide what to close to relieve pressure.
                            $availGB = $null
                            try { $availGB = [Math]::Round((Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1024, 1) } catch {}
                            try {
                                $allProcs = Get-Process -ErrorAction SilentlyContinue
                                $topProcs = $allProcs |
                                    Where-Object { $_.WorkingSet64 -gt 500MB -and $_.Name -notin @('vmms', 'vmwp', 'vmmem', 'System', 'Memory Compression', 'MsMpEng') } |
                                    Sort-Object WorkingSet64 -Descending | Select-Object -First 5
                                if ($topProcs) {
                                    $procList = ($topProcs | ForEach-Object {
                                        "$($_.Name)(pid=$($_.Id), WS=$([Math]::Round($_.WorkingSet64 / 1GB, 1))GB, private=$([Math]::Round($_.PrivateMemorySize64 / 1GB, 1))GB)"
                                    }) -join ', '
                                    Write-Log "${Name}: OOM reclaim hint - top non-HyperV host memory users: $procList" -LogOnly
                                }
                                # The Phase 1 VM_Create jobs each spawn a pwsh.exe,
                                # so ~N concurrent workers individually fall below the
                                # top-5 cut yet together hold a big chunk of RAM. Sum
                                # them (plus powershell.exe) so the operator sees the
                                # aggregate pressure the build itself is creating.
                                $psProcs = @($allProcs | Where-Object { $_.Name -in @('pwsh', 'powershell') })
                                if ($psProcs.Count -gt 0) {
                                    $psWorkingSetGB = [Math]::Round((($psProcs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1GB), 1)
                                    $psPrivateGB = [Math]::Round((($psProcs | Measure-Object -Property PrivateMemorySize64 -Sum).Sum / 1GB), 1)
                                    Write-Log "${Name}: OOM reclaim hint - $($psProcs.Count) PowerShell process(es) (pwsh/powershell): WS=${psWorkingSetGB}GB, private=${psPrivateGB}GB total" -LogOnly
                                }
                            }
                            catch {}

                            $waitSec = $oomBackoffSec * $oomAttempt
                            write-progress2 "Start VM" -Status "$Name : not enough host memory; ~${availGB}GB free, reclaiming + waiting ${waitSec}s then retry ($oomAttempt/$oomMaxAttempts)" -force
                            try { Write-Log "${Name}: Start-VM out of memory (attempt $oomAttempt/$oomMaxAttempts); ~${availGB}GB available; backing off ${waitSec}s for concurrent VMs to finish booting before retry" -Warning } catch {}

                            # Best-effort: GC the host process, trim PowerShell
                            # working sets, and flush the file cache so physical
                            # RAM returns to the available pool before we retry.
                            try { Invoke-HostMemoryReclaim | Out-Null } catch {}

                            Start-Sleep -Seconds $waitSec

                            $StopError = $null
                            Start-VM -VM $vm -ErrorVariable StopError -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                            $vm = Get-VM2 -Name $Name -Fallback
                            if ($vm.State -eq 'Running') {
                                $StopError = $null
                                try { Write-Log "${Name}: VM started after OOM back-off (attempt $oomAttempt/$oomMaxAttempts)." } catch {}
                                break
                            }

                            # If the failure mode changed to something other than
                            # OOM, stop the memory-wait loop and let the normal
                            # stray-mount / outer-retry handling take over.
                            if ($StopError -and ($StopError.Exception.Message -notmatch '0x8007000E') -and ($StopError.Exception.Message -notmatch 'not enough memory')) {
                                try { Write-Log "${Name}: Start-VM error changed from OOM to: $(($StopError.Exception.Message -replace '\s*\r?\n\s*', ' ').Trim())" -Warning } catch {}
                                break
                            }
                        }
                    }
                    else {
                        $isFileInUse = ($errMsg -match 'being used by another process') -or
                                       ($errMsg -match '0x80070020')
                        $reason = if ($isFileInUse) { "file-in-use" } else { "Start-VM failed: $errMsg" }
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
                # Flatten the error(s) to a single line - a raw multi-line
                # Hyper-V message (e.g. OOM 0x8007000E) corrupts the progress UI.
                $stopErrText = (($StopError | ForEach-Object { $_.ToString() }) -join '; ') -replace '\s*\r?\n\s*', ' '
                Write-Log "${Name}: Failed to start the VM. $stopErrText" -Warning
                # A terminal memory failure is the one case where the operator needs
                # to know what is holding the RAM, not just that it ran out.
                if ($stopErrText -match '0x8007000E|not enough memory|Insufficient system resources|allocate') {
                    Write-HostMemoryPressureDiag -Context "$Name Start-VM gave up (out of memory)" -OutputStream
                }
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

function Wait-ForHeartbeat {
    <#
    .SYNOPSIS
        Waits for a VM's heartbeat to reach OkApplicationsHealthy after a start/restart.
    .DESCRIPTION
        Polls the VM heartbeat every PollSeconds until it reaches OkApplicationsHealthy
        or the timeout expires. This prevents PSDirect attempts against a VM that is
        still booting (which just generates log noise) and—more importantly—prevents
        subsequent hard-resets from firing before the OS has finished booting, which
        can trip Windows into the recovery console after 2-3 incomplete boots.
    .PARAMETER VmName
        Name of the VM to wait on.
    .PARAMETER TimeoutSeconds
        Maximum time to wait. Defaults to 240 (4 minutes).
    .PARAMETER PollSeconds
        Interval between heartbeat checks. Defaults to 10.
    .PARAMETER Stopwatch
        Optional parent stopwatch for progress display. If supplied, progress is
        shown via Write-ProgressElapsed; otherwise the function is silent.
    .PARAMETER Timespan
        Required when Stopwatch is supplied. The parent timeout timespan.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [int]$TimeoutSeconds = 240,
        [int]$PollSeconds = 10,
        [System.Diagnostics.Stopwatch]$Stopwatch,
        [TimeSpan]$Timespan
    )

    $hbWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $hbLimit = New-TimeSpan -Seconds $TimeoutSeconds
    $hbState = "Unknown"
    # Grace period: when we first see OkApplicationsUnknown, wait up to this
    # many additional seconds for it to promote to OkApplicationsHealthy.
    # If it doesn't, accept Unknown — the heartbeat IC is responding, meaning
    # the VM is booted and PSDirect-ready; the "Applications" sub-report just
    # hasn't loaded (common on Server OS or older integration services).
    $unknownGrace = 30
    $unknownSince = $null

    while ($hbWatch.Elapsed -lt $hbLimit) {
        # If a parent timeout was supplied, bail if it expired too
        if ($Stopwatch -and $Stopwatch.Elapsed -ge $Timespan) { break }

        Start-Sleep -Seconds $PollSeconds
        $vmObj = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
        $hbState = if ($vmObj) { $vmObj.Heartbeat } else { "N/A" }

        if ($Stopwatch -and $Timespan) {
            try {
                Write-ProgressElapsed -showTimeout -stopwatch $Stopwatch -timespan $Timespan -text "Waiting for VM heartbeat after restart (heartbeat: $hbState)"
            } catch {}
        }

        if ($hbState -eq "OkApplicationsHealthy") {
            Write-Log "$VmName`: Heartbeat healthy after $([int]$hbWatch.Elapsed.TotalSeconds)s." -Verbose
            return $true
        }

        if ($hbState -eq "OkApplicationsUnknown") {
            if (-not $unknownSince) {
                $unknownSince = $hbWatch.Elapsed
                Write-Log "$VmName`: Heartbeat is OkApplicationsUnknown at $([int]$hbWatch.Elapsed.TotalSeconds)s — waiting up to ${unknownGrace}s for Healthy." -Verbose
            }
            elseif (($hbWatch.Elapsed - $unknownSince).TotalSeconds -ge $unknownGrace) {
                Write-Log "$VmName`: Heartbeat stayed OkApplicationsUnknown for ${unknownGrace}s (total $([int]$hbWatch.Elapsed.TotalSeconds)s). VM is responsive — proceeding." -Verbose
                return $true
            }
        }
        else {
            # State regressed (e.g. back to NoContact during a reboot cycle) — reset grace
            $unknownSince = $null
        }
    }

    Write-Log "$VmName`: Heartbeat did not reach OkApplicationsHealthy after $([int]$hbWatch.Elapsed.TotalSeconds)s (last: $hbState). Proceeding anyway." -Warning
    return $false
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
        
        # Test heartbeat integration service (only fail on explicit error statuses;
        # null/empty means the service hasn't reported yet, not that the VM is down)
        $heartbeat = $vm | Get-VMIntegrationService | Where-Object { $_.Name -eq 'Heartbeat' }
        if ($heartbeat -and $heartbeat.Enabled -and $heartbeat.PrimaryStatusDescription) {
            if ($heartbeat.PrimaryStatusDescription -notin 'OK', 'OkApplicationsHealthy', 'OkApplicationsUnknown') {
                Write-Log "VM $VmName heartbeat status: $($heartbeat.PrimaryStatusDescription)" -Warning
                return $false
            }
        }
        
        # Get the VM's IP from Hyper-V directly (avoids DNS, which may point at
        # the DC we're testing and can hang Test-Connection indefinitely).
        $vmIp = ($vm | Get-VMNetworkAdapter | Select-Object -First 1).IPAddresses |
                    Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        if (-not $vmIp) {
            Write-Log "VM $VmName has no IPv4 address from Hyper-V" -Warning
            return $false
        }

        # Test RDP port with hard timeout + retry (never uses Test-Connection or
        # Test-NetConnection — both can hang on DNS reverse lookups).
        $tcpTimeoutMs = [Math]::Max(1000, $TimeoutSeconds * 1000 / 3)
        if (-not (Test-TcpPort -ComputerName $vmIp -Port 3389 -TimeoutMs $tcpTimeoutMs -Retries 3 -RetryDelayMs 1000)) {
            Write-Log "VM $VmName ($vmIp) RDP port test failed after retries" -Warning
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
                Stop-VM2 -Name $VmName -TurnOff
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

function Repair-VmCimServer {
    # Recovers a guest whose WMI/CIM server is wedged (Storage and many other
    # cmdlets fail with "Cannot connect to CIM server. Call was canceled by the
    # message filter"). PowerShell Direct (used by Invoke-VmCommand) runs over
    # VMBus and keeps working even when the guest CIM/DCOM stack is hung, so we
    # can restart winmgmt in-place and, if that is not enough, reboot the VM.
    # Returns $true when a follow-up CIM probe succeeds.
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$VmDomainName,
        [Parameter(Mandatory = $false)]
        [int]$Phase = 1,
        [Parameter(Mandatory = $false)]
        [switch]$AllowReboot
    )

    # Step 1: restart the WMI service inside the guest via PSDirect.
    # MUST run -AsJob: Invoke-VmCommand only honors -TimeoutSeconds on the -AsJob
    # path. A guest whose WMI is truly wedged makes 'Restart-Service Winmgmt -Force'
    # (it stops/starts dependent services too) block indefinitely, and a SYNCHRONOUS
    # Invoke-Command over PSDirect has no timeout -- it would hang this whole repair
    # (and the caller's Phase 11 job) forever. -AsJob lets the 120s Wait-Job reap it.
    Write-Log "[Phase $Phase]: ${VmName}: Guest WMI/CIM server unresponsive. Restarting winmgmt in-guest..." -Warning
    $restart = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog -AsJob -DisplayName "Restart guest WMI (winmgmt)" -TimeoutSeconds 120 -ScriptBlock {
        try {
            # -Force also restarts winmgmt's dependent services.
            Restart-Service -Name Winmgmt -Force -ErrorAction Stop
            Start-Sleep -Seconds 5
            # The Storage stack also leans on the Virtual Disk Service.
            try { Restart-Service -Name vds -Force -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Seconds 3
            # Probe CIM to confirm the provider is answering again.
            $null = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            return $true
        }
        catch {
            return $false
        }
    }

    if ($restart -and -not $restart.ScriptBlockFailed -and ($restart.ScriptBlockOutput -eq $true)) {
        Write-Log "[Phase $Phase]: ${VmName}: WMI restart succeeded; CIM probe OK."
        return $true
    }

    Write-Log "[Phase $Phase]: ${VmName}: WMI restart did not recover the CIM server." -Warning
    if (-not $AllowReboot) {
        return $false
    }

    # Step 2: reboot the VM and wait for it to come back.
    Write-Log "[Phase $Phase]: ${VmName}: Rebooting VM to clear wedged WMI/CIM server..." -Warning
    Stop-VM2 -Name $VmName -TurnOff -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    Start-VM2 -Name $VmName -ErrorAction SilentlyContinue

    $connected = Wait-ForVm -VmName $VmName -OobeComplete -TimeoutMinutes 15 -VmDomainName $VmDomainName -Quiet
    if (-not $connected) {
        Write-Log "[Phase $Phase]: ${VmName}: VM did not become ready after reboot." -Warning
        return $false
    }

    # Probe CIM again after the reboot. -AsJob so the 120s timeout is enforced
    # (a still-wedged guest must not hang this synchronous probe indefinitely).
    $probe = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog -AsJob -DisplayName "Probe guest CIM after reboot" -TimeoutSeconds 120 -ScriptBlock {
        try {
            $null = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            return $true
        }
        catch {
            return $false
        }
    }

    if ($probe -and -not $probe.ScriptBlockFailed -and ($probe.ScriptBlockOutput -eq $true)) {
        Write-Log "[Phase $Phase]: ${VmName}: CIM server healthy after reboot."
        return $true
    }

    Write-Log "[Phase $Phase]: ${VmName}: CIM server still unresponsive after reboot." -Warning
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
        [switch]$TurnOff,
        # Accepted but intentionally ignored. Stop-VM2 always force-stops
        # internally (see $force below), so callers that assume a -Force
        # switch exists (mirroring Hyper-V's Stop-VM) bind cleanly instead
        # of throwing "A parameter cannot be found that matches parameter
        # name 'Force'."
        [Parameter(Mandatory = $false)]
        [switch]$Force
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
                # Use -AsJob so a wedged VM doesn't block forever
                $stopJob = Stop-VM -VM $vm -TurnOff -Force -WarningAction SilentlyContinue -AsJob
                $null = $stopJob | Wait-Job -Timeout 15
                if ($stopJob.State -eq 'Running') { Stop-Job $stopJob -ErrorAction SilentlyContinue }
                Remove-Job $stopJob -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
                $vm = Get-VM2 -Name $Name -Fallback
                if ($vm.State -eq "Off") {
                    Write-Log "${Name}: VM is stopped." -LogOnly
                    if ($Passthru.IsPresent) {
                        return $true
                    }
                    return
                }
                Write-Log "${Name}: VM still in '$($vm.State)' after TurnOff, escalating..." -Warning
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

                # Escalation: TurnOff via -AsJob with timeout
                $stopJob = Stop-VM -VM $vm -TurnOff -Force -WarningAction SilentlyContinue -AsJob
                $null = $stopJob | Wait-Job -Timeout 15
                if ($stopJob.State -eq 'Running') { Stop-Job $stopJob -ErrorAction SilentlyContinue }
                Remove-Job $stopJob -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds $RetrySeconds
                $vm = Get-VM2 -Name $Name -Fallback
                if ($vm.State -eq "Off") {
                    if ($Passthru.IsPresent) {
                        return $true
                    }
                    return
                }

                # Nuclear option: kill the VM worker process when Stop-VM is
                # completely stuck (e.g. VM wedged in "Shutting Down" state).
                Write-Log "${Name}: Stop-VM failed, killing VM worker process" -Warning
                try {
                    $vmId = $vm.Id.ToString()
                    $targetProc = Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -match [regex]::Escape($vmId) }
                    if ($targetProc) {
                        Stop-Process -Id $targetProc.ProcessId -Force -ErrorAction Stop
                        Start-Sleep -Seconds 5
                        $vm = Get-VM2 -Name $Name -Fallback
                        if ($vm.State -eq "Off") {
                            Write-Log "${Name}: VM stopped after killing worker process" -Warning
                            if ($Passthru.IsPresent) {
                                return $true
                            }
                            return
                        }
                    }
                }
                catch {
                    Write-Log "${Name}: Failed to kill VM worker process: $_" -Warning
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


function Restart-VM2Smart {
    # Graceful-first VM restart with an optional last-resort hard power-off.
    #
    # A hard -TurnOff landing in a fragile guest window (OOBE / specialize /
    # rename or domain-join reboot) can corrupt the guest onto the Windows
    # recovery screen, so this helper ALWAYS tries a graceful guest-OS shutdown
    # first (bounded by -GracefulTimeoutSeconds so a hung guest can't block the
    # caller forever). It only escalates to a hard power-off when -AllowTurnOff
    # is set AND the graceful shutdown did not bring the VM down.
    #
    # Returns $true if the VM was restarted (graceful succeeded, or TurnOff was
    # used), $false if the graceful shutdown did not complete and TurnOff was
    # not permitted (the VM is left running for the caller to keep waiting on).
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$AllowTurnOff,
        [Parameter(Mandatory = $false)]
        [int]$GracefulTimeoutSeconds = 180,
        [Parameter(Mandatory = $false)]
        [string]$Reason = "restart",
        [Parameter(Mandatory = $false)]
        [object]$Stopwatch,
        [Parameter(Mandatory = $false)]
        [object]$Timespan
    )

    $vm = Get-VM2 -Name $Name -Fallback
    if (-not $vm) {
        Write-Log "${Name}: Restart-VM2Smart ($Reason): VM not found." -Warning
        return $false
    }

    # 1) Graceful guest-OS shutdown first, bounded so a hung guest can't block.
    if ($vm.State -eq 'Running') {
        Write-Log "${Name}: Restart ($Reason): attempting graceful shutdown (up to ${GracefulTimeoutSeconds}s)..." -LogOnly
        try {
            $gracefulJob = Stop-VM -VM $vm -Force -WarningAction SilentlyContinue -AsJob
            $null = $gracefulJob | Wait-Job -Timeout $GracefulTimeoutSeconds
            if ($gracefulJob.State -eq 'Running') { Stop-Job $gracefulJob -ErrorAction SilentlyContinue }
            Remove-Job $gracefulJob -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "${Name}: Restart ($Reason): graceful shutdown attempt errored: $_" -LogOnly
        }
    }

    # 2) Did graceful bring it down? If not, escalate only when permitted.
    $vm = Get-VM2 -Name $Name -Fallback
    if (-not ($vm -and $vm.State -eq 'Off')) {
        if ($AllowTurnOff) {
            Write-Log "${Name}: Restart ($Reason): graceful shutdown did not complete; escalating to a hard TurnOff (last resort)." -Warning
            Stop-VM2 -Name $Name -TurnOff
        }
        else {
            Write-Log "${Name}: Restart ($Reason): graceful shutdown did not complete and TurnOff is not permitted; leaving VM running." -Warning
            return $false
        }
    }

    # 3) Start it back up and wait for it to respond.
    Start-Sleep -Seconds 10
    Start-VM2 -Name $Name
    if ($Stopwatch -and $Timespan) {
        Wait-ForHeartbeat -VmName $Name -Stopwatch $Stopwatch -Timespan $Timespan | Out-Null
    }
    else {
        Wait-ForHeartbeat -VmName $Name | Out-Null
    }
    return $true
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
                # On a running VM, Hyper-V only allows max memory to be
                # increased, never decreased. Clamp to at least the current
                # value to avoid "Invalid maximum memory amount" errors on
                # legacy/existing VMs whose previous config was higher.
                $effectiveMax = $maxBytes
                if ($vm.State -eq 'Running' -and $vm.MemoryMaximum -gt $maxBytes) {
                    $messages.Add(@{ Level = 'LogOnly'; Text = "[Phase 11]   $vmName`: Keeping current max memory $($vm.MemoryMaximum) (config wants $maxBytes but VM is running)" })
                    $effectiveMax = $vm.MemoryMaximum
                }
                $messages.Add(@{ Level = 'LogOnly'; Text = "[Phase 11]   $vmName`: Lowering dynamic memory min to $($vmConfig.dynamicMinRam) / $($vmConfig.memory)" })
                $vm | Set-VMMemory -MinimumBytes $minBytes -MaximumBytes $effectiveMax -StartupBytes $effectiveMax -Priority $priority -Buffer $buffer -ErrorAction Stop
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
        to/from any RFC 1918 private address (10/8, 172.16/12, 192.168/16),
        then deny outbound TCP 80/443, UDP 443 (QUIC), and DNS (UDP+TCP 53)
        to anything else. Net effect: free movement to any private IP
        (intra-lab AD, SMB, SQL, CM, cross-domain hierarchies), but any
        attempt to reach PUBLIC Internet IPs on web or DNS ports is blocked
        -- forcing HTTP/HTTPS through the Squid proxy.

        Because the allow rules cover all private space, the ACL set is
        identical for every VM on the host. No per-subnet computation or
        cross-lab reconciliation is needed.

        Idempotent: removes any prior memlabs proxy ACLs (weight band
        5000-5099) before re-adding.

    .PARAMETER VmName
        The Windows VM whose vNIC ACLs are being managed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$VmName
    )

    # Fixed RFC 1918 ranges -- covers every possible lab subnet without
    # needing to enumerate them. Only public-IP traffic hits the deny rules.
    $cidrs = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')

    # Fast-path: if existing ACLs already match the desired state, skip the
    # expensive clear+re-add cycle (~11 WMI calls saved per VM).
    try {
        $existingAcls = @(Get-VMNetworkAdapterExtendedAcl -VMName $VmName -ErrorAction SilentlyContinue |
            Where-Object { $_.Weight -ge $global:MemLabsProxyAclWeightMin -and $_.Weight -le $global:MemLabsProxyAclWeightMax })
        $expectedTotal = ($cidrs.Count * 2) + 5   # 2 allow (in+out) per range + 5 deny rules = 11
        if ($existingAcls.Count -eq $expectedTotal) {
            $existingAllowCidrs = @($existingAcls |
                Where-Object { $_.Action -eq 'Allow' } |
                ForEach-Object { $_.RemoteIPAddress } |
                Sort-Object -Unique)
            $desiredCidrs = @($cidrs | Sort-Object)
            if (($existingAllowCidrs -join ',') -eq ($desiredCidrs -join ',')) {
                Write-Log "[Proxy] $VmName`: ACLs already current; skipping" -Verbose
                return $true
            }
        }
    }
    catch {
        # If we can't read ACLs, fall through to the full clear+re-add path.
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
        # --- High-priority ALLOW rules (weights 5093-5099) ---
        # Allow all traffic both directions to/from any RFC 1918 private IP.
        # This covers every memlabs lab subnet regardless of how many labs
        # or subnets exist on the host (no per-subnet enumeration needed).
        # Intra-lab AD/SMB/SQL/CM and cross-domain hierarchy traffic all
        # stay native. Only public-IP traffic on the denied ports is blocked.
        #
        # Each (range, direction) gets a unique weight: Hyper-V's
        # extended-ACL identity is (Direction + Weight + Protocol) and does
        # NOT include RemoteIPAddress, so rules sharing
        # Direction+Weight+Protocol collide.
        $w = 5099
        foreach ($cidr in $cidrs) {
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

        Write-Log "[Proxy] $VmName`: Enforcement ACLs applied (allow all RFC 1918 private, deny public 80/443/53)"
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
        Enumerates the deployConfig, filters via Test-VmUsesProxy, then
        calls Set-VmProxyEnforcement per VM. No-op when no Proxy VM or no
        opted-in clients exist.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object]$deployConfig
    )

    $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    # Linux clients are intentionally EXCLUDED here: their proxy env/apt
    # config is applied in Phase 3 (roles/proxy-client), which runs AFTER
    # this Phase 2 post-hook. Stamping the deny-ACL now would block the
    # Phase 3 apt installs (xrdp/gnome/realm-join hit public archive.ubuntu.com
    # on 80/443) before the guest knows to route through Squid. Linux VM ACLs
    # are stamped later by Set-VmProxyEnforcementForAllLabs (post-Phase-11),
    # by which time the Phase 3 proxy config is in place.
    $clients = @($deployConfig.virtualMachines | Where-Object { (Test-VmUsesProxy -Vm $_ -DeployConfig $deployConfig) -and -not (Test-VmIsLinux -Vm $_) })

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

    $ok = $true
    foreach ($vm in $clients) {
        $r = Set-VmProxyEnforcement -VmName $vm.vmName
        if (-not $r) { $ok = $false }
    }
    return $ok
}

function Set-VmProxyEnforcementForAllLabs {
    <#
    .SYNOPSIS
        Reconcile Hyper-V proxy enforcement ACLs across every memlabs VM
        on the host, not just the VMs in the current deployConfig.

    .DESCRIPTION
        Enumerates every memlabs VM on the host via Get-List -Type VM.
        For each VM with useProxy=true in its VM Note (Windows, not
        role-excluded) -> stamps the fixed RFC 1918 allow + deny ACL set.
        For each opted-out VM that still has stale ACLs in the memlabs
        weight band (5000-5099) -> clears them.

        Because the allow rules cover all RFC 1918 private space, the ACL
        set is identical for every VM and never needs per-subnet
        computation or cross-lab reconciliation.

        Safe to call repeatedly; per-VM failures are logged and never
        abort the sweep.

    .PARAMETER WhatIf
        Standard PowerShell switch; reports the intended actions without
        touching any ACLs.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param ()

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

    # Hard-exclude roles (mirrors Test-VmUsesProxy). The Linux Proxy VM is
    # excluded via the Proxy role itself. Other Linux VMs DO participate:
    # the extended-ACL set is OS-agnostic (it operates on the Hyper-V vNIC),
    # and Linux clients that opted into useProxy have their guest-side proxy
    # config applied in Phase 3, so stamping their deny-ACL here (post-Phase-11)
    # is safe and enforces the "must use proxy" policy the same way as Windows.
    $hardExclude = @('Proxy', 'DC', 'BDC', 'StandaloneRootCA')

    $applied = 0; $cleared = 0; $skipped = 0; $failed = 0
    foreach ($vm in $allVms) {
        if (-not $vm.vmName) { continue }
        if ($vm.role -in $hardExclude) { $skipped++; continue }

        $optedIn = $false
        if ($vm.PSObject.Properties.Name -contains 'useProxy') {
            $optedIn = [bool]$vm.useProxy
        }

        try {
            if ($optedIn) {
                if ($PSCmdlet.ShouldProcess($vm.vmName, "Apply proxy enforcement ACLs")) {
                    $r = Set-VmProxyEnforcement -VmName $vm.vmName
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

    Write-Log "[Proxy] Reconcile complete: $applied applied, $cleared cleared, $skipped skipped (excluded roles), $failed failed"
    return ($failed -eq 0)
}
# endregion Proxy enforcement ---------------------------------------------