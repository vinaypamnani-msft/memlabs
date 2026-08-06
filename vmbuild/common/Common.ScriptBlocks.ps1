# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.


$global:Phase10Job = {
    param (
        [object] $vm,
        [array] $Dummy,
        [boolean] $FreshDeployOnly,
        [boolean] $Dummy2,
        [string] $ScriptRoot
    ) 
    # Suppress CIM cmdlet progress in child process (see VM_Create comment).
    # Safe for ThreadJob too: Write-Progress2 -force overrides when needed.
    $Global:ProgressPreference = 'SilentlyContinue'
       
    try {
        $global:ScriptBlockName = "Phase10Job"
        # Dot source common
        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose -DevBranch:$using:devBranchValue -GetLatestHotfixVersion
        #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

        # Get variables from parent scope
        $currentItem = $using:currentItem
        $Phase = $using:Phase
        if (-not $Phase) {
            $Phase = "Maintenance"
        }

        # Set domain-specific log path (same pattern as Phase11Job)
        try { Flush-LogBuffer -All } catch { }
        $domainNameForLogging = if ($using:deployConfigCopy) { ($using:deployConfigCopy).vmOptions.domainName } else { $currentItem.domain }
        if (-not $domainNameForLogging) {
            try { $domainNameForLogging = (Get-VMNote -VMName $currentItem.vmName).domain } catch { }
        }
        if ($domainNameForLogging) {
            $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"
        }

        if ($FreshDeployOnly) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Running fresh-deploy fixes only: $FreshDeployOnly"
        }
        if ($currentItem.Role -in @("OSDClient", "AADClient")) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Maintenance not required for $($currentItem.role)." -OutputStream -Success
        }
        # Linux VMs have no Windows-side maintenance; Start-VMMaintenance also
        # short-circuits, but log a clearer message here.
        $jobIsLinuxVm = $false
        if ($currentItem.role -eq 'Proxy') { $jobIsLinuxVm = $true }
        elseif ($currentItem.PSObject.Properties.Name -contains 'osFamily' -and $currentItem.osFamily -eq 'Linux') { $jobIsLinuxVm = $true }
        elseif ($currentItem.operatingSystem -and ($currentItem.operatingSystem -like 'Ubuntu*' -or $currentItem.operatingSystem -like 'Debian*' -or $currentItem.operatingSystem -like 'Linux*')) { $jobIsLinuxVm = $true }
        if ($jobIsLinuxVm) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux VM (role '$($currentItem.role)'); Windows maintenance not applicable. Skipping." -OutputStream -Success
            return
        }
        # Pre-flight: a VM can be Running with a healthy heartbeat yet have a
        # wedged PSDirect/VMBus channel, which would make Start-VMMaintenance
        # fail with "returned no data". Recover it (reboot once to clear VMBus)
        # before maintenance. Healthy VMs pass the probe instantly; Linux /
        # OSDClient / AADClient / StandaloneRootCA are skipped inside the helper.
        $null = Repair-VmPSDirectChannel -VmName $currentItem.vmName -VmDomainName $domainNameForLogging -Phase "$Phase"
        $worked = Start-VMMaintenance -VMName $currentItem.vmName -FreshDeployOnly:$FreshDeployOnly
        if (-not $worked) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed - Start-VMMaintenance returned no data." -OutputStream -Failure
            throw "Could not run VM Maintenance on $($currentItem.vmName)"
        }
        else {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Maintenance completed successfully for $($currentItem.role)." -OutputStream -Success
            # Record Phase 10 (maintenance) as the highest completed phase on this
            # VM. lastPhaseComplete is monotonic (Math.Max), so a higher prior value
            # (e.g. 11 from a previous full run) is never regressed. Without a stamp
            # here Phase 10/11 leave the note at the last DSC phase (8 for a
            # CAS/Primary), which later makes "add VMs to existing domain" validation
            # falsely report the domain never finished. See Common.Validation.ps1.
            try {
                $note10 = Get-VMNote -VMName $currentItem.vmName
                if ($note10) {
                    $existing10 = if ($note10.PSObject.Properties['lastPhaseComplete']) { [int]$note10.lastPhaseComplete } else { 0 }
                    $note10 | Add-Member -MemberType NoteProperty -Name 'lastPhaseComplete' -Value ([Math]::Max($existing10, 10)) -Force
                    Set-VMNote -VMName $currentItem.vmName -vmNote $note10
                }
            }
            catch {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to stamp lastPhaseComplete=10: $_" -LogOnly
            }
        }
    }
    catch {
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log -LogOnly "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)"
    }
    finally {
        # Maintenance dispatches this as a ThreadJob across EVERY VM, and a thread
        # job's sessions outlive Remove-Job (its runspace is reclaimed, runspaces
        # created inside it are not). Without this each pass leaks a runspace pair
        # per VM into the launcher for the rest of the week-long suite.
        # NOT wrapped in a silent catch: an empty catch here made "the fix is not
        # deployed" and "the fix ran and threw" indistinguishable for a whole day.
        try {
            if (Get-Command Clear-VmSessionCache -ErrorAction SilentlyContinue) {
                $null = Clear-VmSessionCache
            }
            else {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Clear-VmSessionCache NOT FOUND -- this worker's PSDirect sessions will leak. Common.ps1 in this runspace is stale." -Warning -LogOnly
            }
        }
        catch {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Clear-VmSessionCache threw: $($_.Exception.Message)" -Warning -LogOnly
        }
    }

}

$global:Phase11Job = {
    param (
        [object] $vm,
        [array] $Dummy,
        [boolean] $Dummy1,
        [boolean] $Dummy2,
        [string] $ScriptRoot
    )
    # Suppress CIM cmdlet progress (see VM_Create comment).
    $Global:ProgressPreference = 'SilentlyContinue'

    try {
        $global:ScriptBlockName = "Phase11Job"
        # Dot source common -- use bare $using:devBranchValue (not
        # $using:Common.DevBranch) so this scriptblock works under both
        # Start-Job and Start-ThreadJob. ThreadJob's $using: parser only
        # supports bare variable names. Start-PhaseJobs and Start-NormalJobs
        # both define $devBranchValue in their scope.
        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose -DevBranch:$using:devBranchValue

        # Get variables from parent scope
        $currentItem = $using:currentItem
        $deployConfig = $using:deployConfigCopy
        $Phase = 11

        # Set domain-specific log path (same pattern as VM_Create/VM_Config)
        try { Flush-LogBuffer -All } catch { }
        $domainNameForLogging = $deployConfig.vmOptions.domainName
        $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"

        Write-Log "[Phase $Phase]: $($currentItem.vmName): Starting functional validation for role '$($currentItem.role)'" -LogOnly

        # Pre-flight: recover a wedged PSDirect/VMBus channel before validation so
        # a VM that is Running-but-unreachable is remediated (reboot once to clear
        # VMBus) instead of failing validation with "no error detail returned".
        # Healthy VMs pass the probe instantly; Linux / OSDClient / AADClient /
        # StandaloneRootCA are skipped inside the helper. If this reboots the VM,
        # Test-VmFunctionality's own uptime settle-gate then lets it converge.
        $null = Repair-VmPSDirectChannel -VmName $currentItem.vmName -VmDomainName $domainNameForLogging -Phase "$Phase"

        $testResult = @(Test-VmFunctionality -VMName $currentItem.vmName -CurrentItem $currentItem -DeployConfig $deployConfig)
        $passed = $testResult.Count -eq 1 -and $testResult[0] -is [bool] -and $testResult[0]
        if ($testResult.Count -ne 1 -or $testResult[0] -isnot [bool]) {
            $types = @($testResult | ForEach-Object { if ($null -eq $_) { '<null>' } else { $_.GetType().FullName } }) -join ', '
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Validation returned unexpected output (count=$($testResult.Count), types=$types); treating as FAILED." -LogOnly
        }

        # Emit buffered output lines (failures/warnings collected during test)
        # This must happen at top-level where -OutputStream goes to job output.
        if ($script:Phase11OutputBuffer) {
            foreach ($entry in $script:Phase11OutputBuffer) {
                if ([string]::IsNullOrWhiteSpace($entry.Text)) { continue }
                switch ($entry.Level) {
                    'Failure' { Write-Log $entry.Text -OutputStream -Failure }
                    'Warning' { Write-Log $entry.Text -OutputStream -Warning }
                    'Success' { Write-Log $entry.Text -OutputStream -Success }
                    default   { Write-Log $entry.Text -OutputStream }
                }
            }
        }

        if ($passed) {
            # Validation passed: record Phase 11 as the highest completed phase on
            # this VM. This is the durable "deployment fully succeeded" marker read
            # by later validation (expected 11) in Common.Validation.ps1. Without it
            # a fully-validated lab stays at lastPhaseComplete=8 (the last DSC phase
            # for a CAS/Primary), so adding VMs to that domain is wrongly rejected
            # as "never finished deployment". Monotonic Math.Max never regresses a
            # higher value.
            try {
                $note11 = Get-VMNote -VMName $currentItem.vmName
                if ($note11) {
                    $existing11 = if ($note11.PSObject.Properties['lastPhaseComplete']) { [int]$note11.lastPhaseComplete } else { 0 }
                    $note11 | Add-Member -MemberType NoteProperty -Name 'lastPhaseComplete' -Value ([Math]::Max($existing11, 11)) -Force
                    Set-VMNote -VMName $currentItem.vmName -vmNote $note11
                }
            }
            catch {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to stamp lastPhaseComplete=11: $_" -LogOnly
            }

            # Remove the Read-DSCLog desktop shortcut now that validation passed
            # and re-enable WU services that Phase 1 disabled for the deploy.
            $domainName = $deployConfig.vmOptions.domainName
            # These two cleanups are Windows-only PSDirect operations. On a Linux VM
            # (or a no-PSDirect role like OSDClient/AADClient/StandaloneRootCA) they
            # just hang on the PSDirect connect timeout + retries for MINUTES with no
            # log output (everything here is -SuppressLog) -- this is the "LinuxClient
            # validation is slow / appears hung" symptom: the LinuxClient's real tests
            # (ping+SSH+SMB) finish in ~10s, then this block silently burned ~3 min
            # trying to PSDirect into a guest that has no Windows PSDirect endpoint.
            if (-not (Test-VmIsLinux -Vm $currentItem) -and $currentItem.role -notin @('OSDClient', 'AADClient', 'StandaloneRootCA')) {
            Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
                Remove-Item (Join-Path $desktop 'Read DSC Log.lnk') -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $desktop 'DSC ConfigurationStatus.lnk') -Force -ErrorAction SilentlyContinue
                # Re-enable Windows Update services disabled in Phase 1.
                # Services need to be startable for WSUS/ConfigMgr-initiated updates.
                foreach ($svc in @('UsoSvc', 'wuauserv')) {
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($s -and $s.StartType -eq 'Disabled') {
                        Set-Service $svc -StartupType Manual -ErrorAction SilentlyContinue
                    }
                }
            } -DisplayName "Phase11: Remove DSC shortcuts" -SuppressLog

            # --- Revert Windows Update lockdown set during Phase 2 ---
            # Only touch settings we own (WsusSetByMemLabs marker present).
            $useFakeWSUS = [bool]$currentItem.useFakeWSUSServer
            $revert_WindowsUpdateLockdown = {
                param([int]$UseFakeWSUS)
                $mlPath = "HKLM:\SOFTWARE\MemLabs"
                $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                $auPath = "$wuPath\AU"

                # Check our ownership marker
                $marker = Get-ItemProperty -Path $mlPath -Name "WsusSetByMemLabs" -ErrorAction SilentlyContinue
                if (-not $marker -or $marker.WsusSetByMemLabs -ne 1) {
                    return "Skipped: not set by MemLabs"
                }

                $isReal = 0
                $realMarker = Get-ItemProperty -Path $mlPath -Name "WsusIsReal" -ErrorAction SilentlyContinue
                if ($realMarker) { $isReal = $realMarker.WsusIsReal }

                # Always remove blocking keys (deploy is done)
                Remove-ItemProperty -Path $wuPath -Name "DoNotConnectToWindowsUpdateInternetLocations" -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $wuPath -Name "DisableWindowsUpdateAccess" -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $auPath -Name "NoAutoUpdate" -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $auPath -Name "AUOptions" -Force -ErrorAction SilentlyContinue

                if ($isReal -eq 1 -or $UseFakeWSUS -eq 1) {
                    # Real WSUS or user-chosen fake WSUS: keep WUServer/WUStatusServer/UseWUServer
                    $action = if ($isReal -eq 1) { "Kept real WSUS" } else { "Kept fake WSUS (user choice)" }
                }
                else {
                    # Fake localhost that we set as fallback — remove everything
                    Remove-ItemProperty -Path $wuPath -Name "WUServer" -Force -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $wuPath -Name "WUStatusServer" -Force -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $auPath -Name "UseWUServer" -Force -ErrorAction SilentlyContinue
                    $action = "Removed all WU policy (no WSUS)"
                }

                # Clean up MemLabs markers
                Remove-ItemProperty -Path $mlPath -Name "WsusSetByMemLabs" -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $mlPath -Name "WsusIsReal" -Force -ErrorAction SilentlyContinue
                # Remove MemLabs key if empty
                $remaining = Get-ItemProperty -Path $mlPath -ErrorAction SilentlyContinue
                if ($remaining) {
                    $props = $remaining.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }
                    if (-not $props) { Remove-Item -Path $mlPath -Force -ErrorAction SilentlyContinue }
                }

                return $action
            }

            $useFakeInt = if ($useFakeWSUS) { 1 } else { 0 }
            $revertResult = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $revert_WindowsUpdateLockdown -ArgumentList @($useFakeInt) -DisplayName "Phase11: Revert WU lockdown" -SuppressLog
            if ($revertResult.ScriptBlockOutput) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): WU lockdown revert: $($revertResult.ScriptBlockOutput)" -LogOnly
            }
            } # end Windows-only post-pass cleanup guard (skipped for Linux / no-PSDirect roles)

            Write-Log "[Phase $Phase]: $($currentItem.vmName): Functional validation PASSED for $($currentItem.role)." -OutputStream -Success
        }
        else {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Functional validation FAILED for $($currentItem.role)." -OutputStream -Failure
            throw "Functional validation failed for $($currentItem.vmName) ($($currentItem.role))"
        }
    }
    catch {
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log -LogOnly "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)"
    }
    finally {
        # Phase 11 runs as a ThreadJob, so its PSDirect sessions survive
        # Remove-Job unless the worker disposes its runspace-local cache.
        try {
            if (Get-Command Clear-VmSessionCache -ErrorAction SilentlyContinue) {
                $null = Clear-VmSessionCache
            }
            else {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Clear-VmSessionCache NOT FOUND -- this worker's PSDirect sessions will leak. Common.ps1 in this runspace is stale." -Warning -LogOnly
            }
        }
        catch {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Clear-VmSessionCache threw: $($_.Exception.Message)" -Warning -LogOnly
        }
    }
}

# Initialize disks
$global:Initialize_Disk = {
    param($letter,
        $size,
        $label
    )
    $OriginalPref = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        Import-Module Storage
    }
    catch {}
    if (-not $letter -or $letter -eq "AUTO") {
        $usedLetters = Get-Volume | Select-Object -ExpandProperty DriveLetter
        $allLetters = [char[]]([char]'E'..[char]'X')
        $availableLetters = $allLetters | Where-Object { $_ -notin $usedLetters }
        $letter = $availableLetters[0]
    }


    $size = ($size / 1 )
    try {
        $rawdisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -eq $size } | Select-Object -First 1
    }
    catch {
        try {
            (Get-Volume).DriveLetter | ForEach-Object { if ($_) { Write-VolumeCache -Driveletter $_ } }
            Get-Disk | Update-Disk
            start-sleep -Seconds 10
        }
        catch {}
        $rawdisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -eq $size } | Select-Object -First 1
    }
    if ($rawdisk) {
        try {
            $rawdisk | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter $letter | Format-Volume -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force | out-null     
        }
        catch {
            try {
                (Get-Volume).DriveLetter | ForEach-Object { if ($_) { Write-VolumeCache -Driveletter $_ } }
                Get-Disk | Update-Disk
                start-sleep -Seconds 10
            }
            catch {}
            $rawdisk | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter $letter | Format-Volume -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force | out-null 
        }
    }
    $ProgressPreference = $OriginalPref  

    # Create NO_SMS_ON_DRIVE.SMS
    New-Item "$env:systemdrive\NO_SMS_ON_DRIVE.SMS" -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
}

# Create VM script block
$global:VM_Create = {

    # Suppress all progress in this child process. CIM cmdlets (Hyper-V,
    # DHCP) write progress records that leak through Start-Job's
    # PSDataCollection auto-renderer and produce blank lines in the
    # parent's terminal. Write-Progress2 -force overrides this for
    # our managed progress bars.
    $Global:ProgressPreference = 'SilentlyContinue'

    try {
        $global:ScriptBlockName = "VM_Create"
        # Dot source common
        #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose -DevBranch:$using:Common.DevBranch

        # Get variables from parent scope
        $deployConfig = $using:deployConfigCopy
        $currentItem = $using:currentItem
        $azureFileList = $using:Common.AzureFileList
        $Phase = $using:Phase
        $Migrate = $using:Migrate

        if (-not ($Common.LogPath)) {
            Write-Output "ERROR: [Phase $Phase] $($currentItem.vmName): Logpath is null. Common.ps1 may not be initialized."
            return
        }

        # Validate token exists
        if ($Common.FatalError) {
            Write-Output "Critical Failure! $($Common.FatalError)" -Failure -OutputStream
            return
        }

        # Params for child script blocks
        $createVM = $true
        if ($currentItem.hidden -eq $true) { $createVM = $false }

        # Change log location. Flush any buffered lines targeting the previous
        # path so they aren't lost or written to the new file out of order.
        try { Flush-LogBuffer -All } catch { }
        $domainNameForLogging = $deployConfig.vmOptions.domainName
        $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"

        # VM Network Switch
        $isInternet = ($currentItem.role -eq "InternetClient") -or ($currentItem.role -eq "AADClient")
        if ($isInternet) {
            $network = "Internet"
        }
        else {
            if ($currentItem.network) {
                $network = $currentItem.network
            }
            else {
                $network = $deployConfig.vmOptions.network
            }
        }

        # Set domain name, depending on whether we need to create new VM or use existing one
        if (-not $createVM -or ($currentItem.role -in ("DC", "BDC")) ) {
            $domainName = $deployConfig.parameters.DomainName
            if ($currentItem.domain) {
                $domainName = $currentItem.domain
            }
        }
        else {
            $domainName = "WORKGROUP"
        }

        # Set base VM path
        $virtualMachinePath = Join-Path $deployConfig.vmOptions.basePath $deployConfig.vmOptions.domainName

        $dynamicMinRam = 0
        if ($currentItem.dynamicMinRam) {
            $dynamicMinRam = $currentItem.dynamicMinRam
        }

        # During deployment, pin VMs near max RAM by setting dynamic min to 99% of max.
        # This keeps dynamic memory enabled (so Restore-DynamicMemory can adjust without stopping VMs)
        # but prevents balloon-down during heavy parallel workloads.
        if ($dynamicMinRam -and ($dynamicMinRam / 1) -ne 0 -and (($dynamicMinRam / 1) -lt ($currentItem.memory / 1))) {
            $raw99 = [long][math]::Floor(($currentItem.memory / 1) * 0.99)
            $dynamicMinRam = [string]($raw99 - ($raw99 % 2MB))
        }

        if (-not $CreateVM) {
            # Check if memory amount or processor count changed; skip dynamic memory toggle for existing VMs
            $restart = $false

            # Set-VMMemory on a RUNNING VM (the deploy-time 99% dynamic-memory pin
            # below) can block indefinitely inside VMMS with NO native timeout --
            # observed live: a Phase 0 pin hung the whole per-VM job for 14+ min
            # while the guest was "Operating normally" and MemoryMinimum never
            # changed, i.e. the cmdlet itself was wedged in the management path.
            # Run that best-effort pin under Start-ThreadJob (Start-Job fallback)
            # with a per-attempt kill-timeout so a wedged VMMS degrades to a logged
            # skip instead of stalling the phase. NB: killing the job cannot abort
            # the in-flight native VMMS call, but Wait-Job -Timeout returns control
            # so the phase proceeds while the orphan thread unwinds with its
            # runspace. Returns a status object; the caller logs. Only the pin uses
            # this (its -ErrorAction SilentlyContinue is already best-effort); the
            # other Set-VMMemory calls stop the VM first / run on a stopped VM and
            # keep their -ErrorAction Stop fatal semantics.
            function Invoke-VMMemoryPinWithWatchdog {
                param(
                    [Parameter(Mandatory)] [string] $VmName,
                    [Parameter(Mandatory)] [hashtable] $MemoryParams,
                    [int] $TimeoutSec = 60,
                    [int] $MaxAttempts = 2
                )
                $useThreadJob = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
                $body = {
                    param($name, $p)
                    Set-VMMemory -VMName $name @p -ErrorAction Stop
                }
                for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                    $job = $null
                    try {
                        if ($useThreadJob) {
                            $job = Start-ThreadJob -ScriptBlock $body -ArgumentList $VmName, $MemoryParams -ErrorAction Stop
                        }
                        else {
                            $job = Start-Job -ScriptBlock $body -ArgumentList $VmName, $MemoryParams -ErrorAction Stop
                        }
                        if (Wait-Job -Job $job -Timeout $TimeoutSec) {
                            $jobErrors = $null
                            Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors | Out-Null
                            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
                            if ($jobErrors -and $jobErrors.Count -gt 0) {
                                return [pscustomobject]@{ Status = 'Error'; Detail = $jobErrors[0].ToString(); Attempt = $attempt }
                            }
                            return [pscustomobject]@{ Status = 'OK'; Detail = $null; Attempt = $attempt }
                        }
                        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
                        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
                    }
                    catch {
                        if ($job) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {} }
                        return [pscustomobject]@{ Status = 'Error'; Detail = $_.Exception.Message; Attempt = $attempt }
                    }
                }
                return [pscustomobject]@{ Status = 'TimedOut'; Detail = $null; Attempt = $MaxAttempts }
            }

            Write-Log "[Phase $Phase]: $($currentItem.vmName): Checking if memory has changed."
            $vm = Get-VM2 -name $currentItem.VmName
            # VM vs Config
            $memory = ($currentItem.Memory / 1)            
            $currentMemory = $vm.MemoryStartup

            # Linux VMs get static memory; no balloon driver gymnastics.
            # If memory amount changed, stop, set static, restart. Otherwise
            # just ensure dynamic is off (cheap, no-op if already off).
            # NB: $IsLinux is a PowerShell automatic constant -- use a
            # different name or assignment throws "read-only or constant".
            $vmIsLinux = Test-VmIsLinux -Vm $currentItem

            if ($vmIsLinux) {
                if ($memory -ne $currentMemory) {
                    if ($vm.State -eq "Running") {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Memory changed ($currentMemory -> $memory). Stopping Linux VM."
                        stop-vm2 -name $vm.VmName
                        $restart = $true
                    }
                    $vm | Set-VMMemory -DynamicMemoryEnabled $false -StartupBytes $memory -ErrorAction Stop
                }
                elseif ($vm.DynamicMemoryEnabled) {
                    if ($vm.State -eq "Running") {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Disabling dynamic memory on Linux VM (requires stop)."
                        stop-vm2 -name $vm.VmName
                        $restart = $true
                    }
                    $vm | Set-VMMemory -DynamicMemoryEnabled $false -StartupBytes $memory -ErrorAction Stop
                }
            }
            elseif ($memory -ne $currentMemory) {
               
                if ($vm.State -eq "Running") {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Memory changed ($currentMemory -> $memory). Stopping VM."
                    stop-vm2 -name $vm.VmName
                    $restart = $true
                }

                # Keep dynamic memory enabled with min pinned at 99% so Restore-DynamicMemory
                # can lower it later on a running VM (switching static->dynamic requires a stop).
                $pinnedMin = [long][math]::Floor($memory * 0.99)
                $pinnedMin = $pinnedMin - ($pinnedMin % 2MB)
                if ($pinnedMin -lt 40MB) { $pinnedMin = $memory }
                $vm | Set-VMMemory -DynamicMemoryEnabled $true -MinimumBytes $pinnedMin -MaximumBytes $memory -StartupBytes $memory -ErrorAction Stop
            }
            elseif ($dynamicMinRam -and ($dynamicMinRam / 1) -ne 0) {
                # Memory amount unchanged but VM may need dynamic memory pinned at 99% during deploy.
                # If already dynamic, raise min to 99% while running. If static, must stop.
                $pinnedMin = [long][math]::Floor($memory * 0.99)
                $pinnedMin = $pinnedMin - ($pinnedMin % 2MB)
                if ($pinnedMin -lt 40MB) { $pinnedMin = $memory }
                if ($vm.DynamicMemoryEnabled) {
                    if ($vm.MemoryMinimum -ne $pinnedMin) {
                        # Hyper-V lets MemoryMinimum be DECREASED on a running VM but never
                        # increased, so raising the pin here can only ever throw ("minimum
                        # memory value can be only decreased") -- 25 times in 72h, each
                        # burning the watchdog's 2 x 60s. Say what happened instead.
                        if ($vm.State -eq 'Running' -and $pinnedMin -gt $vm.MemoryMinimum) {
                            # Hyper-V allows Buffer, Priority and Maximum to change on a live
                            # VM; only the Minimum (a standing reservation) is one-way down.
                            # Weight the balancer toward this VM instead of doing nothing --
                            # same values Restore-DynamicMemory uses.
                            $pinPriority = 25
                            $pinBuffer = 10
                            $pinRole = "$($currentItem.role)"
                            if ($currentItem.SqlVersion -and $pinRole -eq 'DomainMember') { $pinRole = 'SqlServer' }
                            if ($pinRole -in @('DC', 'SqlServer', 'Primary', 'SQLAO', 'CAS')) { $pinPriority = 50; $pinBuffer = 20 }
                            $biasResult = Invoke-VMMemoryPinWithWatchdog -VmName $currentItem.vmName -TimeoutSec 60 -MaxAttempts 2 -MemoryParams @{
                                MaximumBytes = $memory
                                Priority     = $pinPriority
                                Buffer       = $pinBuffer
                            }
                            $biasNote = if ($biasResult.Status -eq 'OK') { "applied priority=$pinPriority buffer=$pinBuffer instead" } else { "and the priority/buffer fallback also failed ($($biasResult.Status): $($biasResult.Detail))" }
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): cannot raise the dynamic-memory minimum from $([math]::Round($vm.MemoryMinimum / 1GB, 1))GB to $([math]::Round($pinnedMin / 1GB, 1))GB while the VM is running -- Hyper-V only allows a decrease. $biasNote." -Warning -LogOnly
                        }
                        else {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): Pinning dynamic memory min to 99% for deploy" -LogOnly
                            $pinResult = Invoke-VMMemoryPinWithWatchdog -VmName $currentItem.vmName -TimeoutSec 60 -MaxAttempts 2 -MemoryParams @{
                                MinimumBytes = $pinnedMin
                                MaximumBytes = $memory
                                StartupBytes = $memory
                            }
                            switch ($pinResult.Status) {
                                'OK' { }
                                'TimedOut' {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Dynamic memory pin timed out (VMMS unresponsive after $($pinResult.Attempt) attempt(s)); continuing without pin." -Warning -LogOnly
                                }
                                default {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Dynamic memory pin did not apply: $($pinResult.Detail); continuing." -Warning -LogOnly
                                }
                            }
                        }
                    }
                }
                else {
                    # Static memory from a pre-fix deploy; switch to dynamic (requires stop)
                    if ($vm.State -eq "Running") {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Switching from static to dynamic memory (99% pin)"
                        stop-vm2 -name $vm.VmName
                        $restart = $true
                    }
                    $vm | Set-VMMemory -DynamicMemoryEnabled $true -MinimumBytes $pinnedMin -MaximumBytes $memory -StartupBytes $memory -ErrorAction Stop
                }
            }

            $currentprocs = $vm.ProcessorCount
            $requestedprocs = $currentItem.VirtualProcs

            if ($currentprocs -ne $requestedprocs) {
                if ($vm.State -eq "Running") {
                    stop-vm2 -name $vm.VmName
                    $restart = $true
                }
                $vm | Set-VM -ProcessorCount $requestedprocs                
            }

            if ($restart) {
                if ($vm.Role -ne "DC") {
                    start-sleep -seconds 15
                }
                start-vm2 -name $vm.VmName
                Wait-ForHeartbeat -VmName $vm.VmName | Out-Null
            }
        }

        if ($createVM) {

            # Check if VM already exists
            $exists = Get-VM2 -Fallback -Name $currentItem.vmName -ErrorAction SilentlyContinue
            if ($exists) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM already exists. Exiting." -Failure -OutputStream -HostOnly
                return
            }

            # Determine which OS image file to use for the VM
            if ($currentItem.role -notin "OSDClient") {
                # Resolve the base VHDX from the Azure file list by
                # operatingSystem id -- for Windows and Linux alike. Ubuntu
                # Server/Desktop 24.04 are regular file-list entries stored in
                # Azure storage and downloaded like every other OS image, so the
                # LinuxClient (Ubuntu Desktop) vs LinuxServer/Proxy (Ubuntu
                # Server) distinction comes straight from operatingSystem -- no
                # per-role filename mapping and no local build step required.
                $imageFile = $azureFileList.OS | Where-Object { $_.id -eq $currentItem.operatingSystem }
                if ($imageFile) {
                    $vhdxPath = Join-Path $Common.AzureFilesPath $imageFile.filename
                }
                if (-not $vhdxPath) {
                    throw "Could not find $($currentItem.operatingSystem) in file list"
                }
                # Linux images ship as a downloaded VHDX; surface a clear,
                # actionable error if the download didn't land instead of
                # failing deep inside the create path.
                if ((Test-VmIsLinux -Vm $currentItem) -and -not (Test-Path $vhdxPath)) {
                    throw "Linux base image $vhdxPath not found. It is downloaded from Azure storage (file list id '$($currentItem.operatingSystem)') -- ensure file download succeeded before deploying."
                }
            }

            # Create VM
            $vmSwitch = Get-VMSwitch2 -NetworkName $network

            # Linux VMs follow a separate create path: Gen2 with cloud-init
            # seed ISO instead of sysprepped Windows + OOBE wait + DSC.
            # Test-VmIsLinux recognises osFamily=Linux as well as Ubuntu*/
            # Debian*/Linux* operatingSystem strings (forward-compatible).
            if (Test-VmIsLinux -Vm $currentItem) {
                $createdLinux = New-LinuxVirtualMachine `
                    -VmName $currentItem.vmName `
                    -VmPath $virtualMachinePath `
                    -SourceDiskPath $vhdxPath `
                    -Memory $currentItem.memory `
                    -DynamicMinRam $dynamicMinRam `
                    -Processors $currentItem.virtualProcs `
                    -SwitchName $vmSwitch.Name `
                    -Domain $deployConfig.vmOptions.domainName `
                    -DeployConfig $deployConfig
                if (-not ($createdLinux -eq $true)) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux VM creation failed." -Failure -OutputStream -HostOnly
                    return
                }

                $expectedIp = Get-LinuxVmExpectedStaticIP -VmObject $currentItem -DeployConfig $deployConfig
                $waitTimeout = Get-LinuxVmWaitTimeout -VmObject $currentItem -VmCount $deployConfig.virtualMachines.Count
                $linuxIP = Wait-LinuxVmReady -VmName $currentItem.vmName -TimeoutSeconds $waitTimeout -ExpectedIPAddress $expectedIp
                if (-not $linuxIP) {
                    $waitMin = [int]($waitTimeout / 60)
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux VM did not become SSH-ready within ${waitMin}min." -Failure -OutputStream
                    return
                }

                # Attach the IP to the VM config object so the New-VmNote
                # call below (which copies all $currentItem.PSObject.Properties)
                # persists it as LastKnownIP in the VM note. Remove-Lab uses
                # this to scrub known_hosts even when the VM is off.
                $currentItem | Add-Member -NotePropertyName LastKnownIP -NotePropertyValue $linuxIP -Force

                # DHCP reservation was already created by New-LinuxVirtualMachine
                # using the pre-assigned IP from Set-DeployConfigIPAddresses.

                # Push an A record to the domain DC so other VMs can resolve
                # this Linux host by name (Linux VMs do not perform secure
                # dynamic DNS registration themselves). Skip this when the DC
                # in the deploy is a brand-new (non-hidden) VM -- it hasn't
                # been promoted to a Domain Controller yet (DSC runs in
                # Phase 2), so the DNS Server role isn't installed and the
                # Add-DnsServerResourceRecordA call would just fail. The
                # post-Phase-2 Set-LinuxVmsDcDns path picks this up later.
                $dcVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
                if (-not $dcVm) {
                    $dcVm = Get-List -Type VM -DomainName $deployConfig.vmOptions.domainName | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
                }
                $dcIsExisting = $dcVm -and ($dcVm.hidden -eq $true)
                if ($dcVm -and $dcIsExisting) {
                    write-progress2 "Register DNS" -Status "$($currentItem.vmName): registering A record on DC" -force
                    $null = Register-LinuxVmDns -VmName $currentItem.vmName -Domain $deployConfig.vmOptions.domainName -DCName $dcVm.vmName -IPAddress $linuxIP
                }
                elseif ($dcVm) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Deferring DNS A record registration until DC '$($dcVm.vmName)' is promoted (Phase 2)." -LogOnly
                }
                else {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): No DC found in deployConfig or domain; skipping DNS registration." -Warning
                }

                New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $true
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux VM creation completed (IP $linuxIP)." -OutputStream -Success
                write-progress2 "Linux VM" -Status "$($currentItem.vmName): ready at $linuxIP" -force -Completed
                return
            }

            $Generation = 2
            if ($currentItem.vmGeneration) {
                $Generation = $currentItem.vmGeneration
            }

            $tpmEnabled = $true
            if ($null -ne $currentItem.tpmEnabled) {
                $tpmEnabled = $currentItem.tpmEnabled
            }
           

            if ($currentItem.Role -eq "DomainMember" -and $currentItem.SqlVersion) {
                $role = "SqlServer"                
            }
            else {
                $role = $currentItem.Role
            }
            $HashArguments = @{
                VmName          = $currentItem.vmName
                VmPath          = $virtualMachinePath
                AdditionalDisks = $currentItem.additionalDisks
                Memory          = $currentItem.memory
                Role            = $role
                DynamicMinRam   = $dynamicMinRam
                Generation      = $Generation
                Processors      = $currentItem.virtualProcs
                SwitchName      = $vmSwitch.Name
                tpmEnabled      = $tpmEnabled
                DeployConfig    = $deployConfig
                Migrate         = $Migrate
            }

            if ($currentItem.role -eq "OSDClient") {
                $HashArguments.Add("OSDClient", $true)
            }
            else {
                $HashArguments.Add("SourceDiskPath", $vhdxPath )
            }

            # NOTE: the SQLAO cluster heartbeat (2nd) NIC is intentionally NOT added here.
            # It is hot-added at the start of Phase 5 (Common.ScriptBlocks.ps1, the
            # "$Phase -eq 5 -and role -eq SQLAO" block) instead of during Phase 1 VM
            # creation, where adding it while every VM hammers OOBE in parallel was slow.

            $created = $false
            $oobeRetries = 0
            $maxOobeRetries = 1  # One full delete+recreate attempt after initial failure

            # AADClient: delay creation until host load settles. The sysprep
            # specialize pass (Phase 2) is sensitive to resource pressure —
            # CryptoSysPrep_Specialize can fail with 0x5 under I/O contention.
            # Phase 1 OOBE also runs slower. Since AADClient has no DSC phases
            # (3-9) and completes P1 fast, a startup delay doesn't increase
            # overall build time — other VMs are still running longer phases.
            #
            # Delay is based on the number of NON-AADClient VMs (the ones
            # causing I/O load). If the config is only AADClients, no delay.
            # Multiple AADClients are staggered by 15s each so they don't all
            # hit OOBE simultaneously.
            #
            # Polls every 10s and breaks early when ≥75% of other VMs have
            # heartbeat OkApplicationsHealthy (past OOBE, load settled).
            if ($currentItem.role -eq "AADClient") {
                $otherVmNames = @($deployConfig.virtualMachines | Where-Object { $_.role -ne "AADClient" -and $_.role -ne "OSDClient" -and -not $_.hidden } | ForEach-Object { $_.vmName })
                $aadClients = @($deployConfig.virtualMachines | Where-Object { $_.role -eq "AADClient" })
                $aadIndex = 0
                for ($ai = 0; $ai -lt $aadClients.Count; $ai++) {
                    if ($aadClients[$ai].vmName -eq $currentItem.vmName) { $aadIndex = $ai; break }
                }
                $baseDelay = if ($otherVmNames.Count -gt 3) { [Math]::Min($otherVmNames.Count * 8, 180) } else { 0 }
                $staggerDelay = $aadIndex * 15
                $maxDelay = $baseDelay + $staggerDelay
                if ($maxDelay -gt 0) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Deferring AADClient creation up to ${maxDelay}s (base=${baseDelay}s for $($otherVmNames.Count) other VMs + stagger=${staggerDelay}s, index $aadIndex of $($aadClients.Count))." -LogOnly
                    $deferSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $threshold = [Math]::Ceiling($otherVmNames.Count * 0.75)
                    while ($deferSw.Elapsed.TotalSeconds -lt $maxDelay) {
                        $remaining = [int]($maxDelay - $deferSw.Elapsed.TotalSeconds)
                        Write-Progress2 "AADClient" -Status "Waiting for host load to settle (${remaining}s remaining)" -force
                        Start-Sleep -Seconds 10
                        # Single Get-VM call for all VMs — faster and avoids
                        # per-VM Get-VM2 issues inside Start-Job.
                        try {
                            $allVms = Get-VM -ErrorAction SilentlyContinue
                            $readyCount = @($allVms | Where-Object { $_.Name -in $otherVmNames -and $_.Heartbeat -eq 'OkApplicationsHealthy' }).Count
                        }
                        catch {
                            $readyCount = 0
                        }
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Heartbeat poll: $readyCount/$($otherVmNames.Count) healthy (need $threshold)." -LogOnly
                        if ($readyCount -ge $threshold) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): $readyCount/$($otherVmNames.Count) VMs healthy after $([int]$deferSw.Elapsed.TotalSeconds)s — breaking early." -LogOnly
                            break
                        }
                    }
                    $deferSw.Stop()
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): AADClient defer completed after $([int]$deferSw.Elapsed.TotalSeconds)s." -LogOnly
                }
            }

            while ($true) {
                if ($oobeRetries -gt 0) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): OOBE retry $oobeRetries/$maxOobeRetries - deleting and recreating VM from base image." -Warning -OutputStream
                    # Delete the stuck VM completely
                    Remove-VirtualMachine -VmName $currentItem.vmName -Force -SkipProxyCleanup
                    Start-Sleep -Seconds 5
                }

                $created = New-VirtualMachine @HashArguments

                if (-not ($created -eq $true)) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): VM was not created. Check vmbuild logs. $created" -Failure -OutputStream -HostOnly
                    return
                }

                if (-not $Migrate) {
                    if ($currentItem.role -eq "OSDClient") {
                        New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $true
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Creation completed successfully for $($currentItem.role)." -OutputStream -Success
                        return
                    }
                    Write-Progress2 "Waiting for OOBE" -Status "Starting" -percentcomplete 0 -force
                    Start-Sleep -Seconds 3
                    # Wait for VM to finish OOBE
                    $oobeTimeout = 25
                    if ($deployConfig.virtualMachines.Count -gt 3) {
                        $oobeTimeout = $deployConfig.virtualMachines.Count + $oobeTimeout
                    }

                    $connected = Wait-ForVm -VmName $currentItem.vmName -OobeComplete -TimeoutMinutes $oobeTimeout
                    if (-not $connected) {
                        if ($oobeRetries -lt $maxOobeRetries) {
                            $oobeRetries++
                            continue  # Delete and recreate
                        }
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if OOBE finished after $($oobeRetries + 1) attempt(s). Exiting." -Failure -OutputStream
                        return
                    }
                }
                break  # OOBE succeeded, exit retry loop
            }
        }
        else {
            # Check if VM is connectable
            $exists = Get-VM2 -Name $currentItem.vmName -ErrorAction SilentlyContinue
            if ($exists -and $exists.State -ne "Running") {
                # Validation should prevent from ever getting in this block
                $started = Start-VM2 -Name $currentItem.vmName -Passthru
                if (-not $started) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not start the VM. Exiting." -Failure -OutputStream
                    return
                }
            }

            # Linux VMs (Proxy etc.) have no Windows PSDirect surface, so
            # Wait-ForVM -PathToVerify "C:\Users" would just time out trying
            # to Invoke-VmCommand. Probe over SSH instead.
            if (Test-VmIsLinux -Vm $currentItem) {
                $expectedIp = Get-LinuxVmExpectedStaticIP -VmObject $currentItem -DeployConfig $deployConfig
                $waitTimeout = Get-LinuxVmWaitTimeout -VmObject $currentItem -VmCount $deployConfig.virtualMachines.Count
                $linuxIP = Wait-LinuxVmReady -VmName $currentItem.vmName -TimeoutSeconds $waitTimeout -ExpectedIPAddress $expectedIp
                if (-not $linuxIP) {
                    $waitMin = [int]($waitTimeout / 60)
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux VM did not become SSH-ready within ${waitMin}min." -Failure -OutputStream
                    return
                }

                # Persist the IP so Remove-Lab can scrub known_hosts even if
                # the VM is off (KVP is unavailable after power-off).
                Set-VMNote -vmName $currentItem.vmName -vmNote ([pscustomobject]@{ LastKnownIP = $linuxIP })

                # Create/refresh DHCP reservation so the IP is stable across reboots.
                # DHCP/Hyper-V CIM calls run isolated (Get-VMMacIsolated /
                # *DHCPReservation* helpers) so their progress doesn't poison the
                # managed per-VM bars.
                try {
                    $vmMac = Get-VMMacIsolated -VmName $currentItem.vmName
                    if ($vmMac) {
                        $realnetwork = if ($currentItem.network) { $currentItem.network } else { $deployConfig.vmOptions.network }
                        Remove-DHCPReservation -mac $vmMac -vmName $currentItem.vmName
                        Add-DHCPReservationIsolated -ScopeId $realnetwork -IPAddress $linuxIP -Mac $vmMac -Description "Reservation for $($currentItem.vmName) (Linux)"
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DHCP reservation created for $linuxIP" -LogOnly
                    }
                }
                catch {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not create DHCP reservation for $linuxIP. $_" -Warning
                }

                Write-Log "[Phase $Phase]: $($currentItem.vmName): Existing VM Preparation completed successfully for $($currentItem.role) (Linux, IP $linuxIP)." -OutputStream -Success
                return
            }

            # Check if RDP is enabled on DC. We saw an issue where RDP was enabled on DC, but didn't take effect until reboot.
            if ($currentItem.role -eq "DC") {
                # Hard-timeout TCP probe (Test-TcpPort); Test-NetConnection can hang on
                # DNS reverse lookups / ICMP fallbacks well past its own timeout.
                $rdpOk = Test-TcpPort -ComputerName $currentItem.vmName -Port 3389 -TimeoutMs 3000 -Retries 2 -RetryDelayMs 1000
                if (-not $rdpOk) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if RDP is enabled. Restarting the computer." -OutputStream -Warning
                    Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Restart-Computer -Force } | Out-Null
                    Start-Sleep -Seconds 10
                }
            }

            $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName
            if (-not $connected) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if VM is connectable. Exiting." -Failure -OutputStream
                return
            }
        }

        # Get VM Session
        $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName

        if (-not $ps) {
            start-sleep -seconds 20
            $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName
            if (-not $ps) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
                return
            }
        }

        if ($Migrate) {
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Disk | Set-Disk -IsOffline 0 }
            if ($result.ScriptBlockFailed) {
                start-sleep -seconds 15
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Disk | Set-Disk -IsOffline 0 }
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed set-disk to online. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }
            }

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Disk | Where-Object { $_.IsReadOnly } | Set-Disk -IsReadOnly 0 }
            if ($result.ScriptBlockFailed) {
                start-sleep -seconds 15
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Disk | Where-Object { $_.IsReadOnly } | Set-Disk -IsReadOnly 0 }
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed set-disk to read-write. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }
            }

            $remove_old_nics_Scriptblock = {
                $Devs = Get-PnpDevice -class net | Where-Object Status -eq Unknown | Select-Object FriendlyName, InstanceId

                ForEach ($Dev in $Devs) {
                    if ($Dev.InstanceId -ne $null) {
                        Write-Host "Removing $($Dev.FriendlyName)" -ForegroundColor Cyan
                        $RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($Dev.InstanceId)"
                        Get-Item $RemoveKey | Select-Object -ExpandProperty Property | ForEach-Object { Remove-ItemProperty -Path $RemoveKey -Name $_ -Force -ErrorAction SilentlyContinue }
                    }
                }
            }

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $remove_old_nics_Scriptblock
            if ($result.ScriptBlockFailed) {
                start-sleep -seconds 10
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $remove_old_nics_Scriptblock
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to remove old nics. $($result.ScriptBlockOutput)" -Warning -OutputStream                    
                }
            }

            if ($currentItem.role -eq "WorkgroupMember" -or $currentItem.role -eq "InternetClient" -or $currentItem.role -eq "AADClient") {
                $netProfile = 1
            }
            else {
                $netProfile = 2
            } # 1 = Private, 2 = Domain

            $Trust_Ethernet = {
                param ($netProfile)
                Get-ChildItem -Force 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' -Recurse `
                | ForEach-Object { $_.PSChildName } `
                | ForEach-Object { Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\$($_)" -Name "Category" -Value $netProfile }
            }

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Trust_Ethernet -ArgumentList $netProfile -DisplayName "Set Ethernet as Trusted"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set Ethernet as Trusted. $($result.ScriptBlockOutput)" -Warning
            }
            


            Stop-VM2 -Name $currentItem.vmName
            Start-vm2 -Name $currentItem.vmName
            Wait-ForHeartbeat -VmName $currentItem.vmName | Out-Null
        }

        # Set PS Execution Policy (required on client OS)
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue }
        if ($result.ScriptBlockFailed) {
            start-sleep -seconds 15
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue }
            if ($result.ScriptBlockFailed) {
                start-sleep -seconds 15
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue }
                if ($result.ScriptBlockFailed) {
                    if (-not $currentItem.operatingSystem -like "*Server*") {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set PS ExecutionPolicy to Bypass for LocalMachine. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }
                    else {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set PS ExecutionPolicy to Bypass for LocalMachine. $($result.ScriptBlockOutput)"
                    }
                    
                }
            }
        }

        # This gets set to true later, if a required fix failed to get applied. When version isn't updated, VM Maintenance could attempt fix again.
        $skipVersionUpdate = $false

        # Combined scriptblock that runs Fix_DefaultProfile + Fix_LocalAccount +
        # Set-TimeZone + TLS 1.2 keys + WorkgroupMember fix in one PSDirect call.
        $Fix_NewVmSettings = {
            param([String]$timezone, [String]$domainName, [bool]$isWorkgroup)
            $warnings = @()

            # Some CIM/DCOM-backed cmdlets (Get-Service, Get/Disable-ScheduledTask,
            # Get-WmiObject) intermittently throw transient busy faults while ~20
            # VMs are configured in parallel during Phase 1 -- most commonly
            # "Cannot connect to CIM server. Call was canceled by the message
            # filter." (RPC_E_CALL_CANCELED 0x80010002) and "RPC server is too
            # busy" (0x800706BB). These are not real failures; the call succeeds
            # on a retry once the server drains. Run the operation through this
            # helper so a transient fault recovers silently instead of surfacing
            # as a warning. Non-transient errors are rethrown to the caller's catch.
            function Invoke-WithCimRetry {
                param([scriptblock]$Action, [int]$MaxAttempts = 4, [int]$DelaySeconds = 3)
                for ($cimAttempt = 1; $cimAttempt -le $MaxAttempts; $cimAttempt++) {
                    try {
                        & $Action
                        return
                    }
                    catch {
                        $cimMsg = "$_"
                        $isTransient = $cimMsg -match 'message filter|Cannot connect to CIM server|RPC server is (too )?busy|call was canceled|0x80010002|0x800706BB|0x800706BA'
                        if ($isTransient -and $cimAttempt -lt $MaxAttempts) {
                            Start-Sleep -Seconds $DelaySeconds
                            continue
                        }
                        throw
                    }
                }
            }

            # Fix Default Profile (sysprep issue)
            try {
                $path1 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCache"
                $path2 = "C:\Users\Default\AppData\Local\Microsoft\Windows\INetCache"
                $path3 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCacheLock.dat"
                if (Test-Path $path1) { Remove-Item -Path $path1 -Force -Recurse | Out-Null }
                if (Test-Path $path2) { Remove-Item -Path $path2 -Force -Recurse | Out-Null }
                if (Test-Path $path3) { Remove-Item -Path $path3 -Force | Out-Null }
            } catch { $warnings += "Fix Default Profile: $_" }

            # Fix Local Account Password Expiration
            # After sysprep/OOBE the local account may not be queryable
            # immediately even though PSDirect can already authenticate.
            # Retry a few times with a short delay.
            try {
                for ($acctTry = 1; $acctTry -le 5; $acctTry++) {
                    try {
                        $localUser = Get-LocalUser -Name "vmbuildadmin" -ErrorAction Stop
                        Set-LocalUser -Name $localUser.Name -PasswordNeverExpires $true -ErrorAction Stop
                        break
                    }
                    catch {
                        if ($acctTry -lt 5) { Start-Sleep -Seconds 3 }
                        else { throw }
                    }
                }
            } catch { $warnings += "Fix Local Account: $_" }

            # Set Timezone
            try {
                Set-TimeZone -Id $timezone
            } catch { $warnings += "Set Timezone: $_" }

            # TLS 1.2 Registry Keys
            try {
                $netRegKey = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
                if (Test-Path $netRegKey) {
                    New-ItemProperty -Path $netRegKey -Name "SystemDefaultTlsVersions" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $netRegKey -Name "SchUseStrongCrypto" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $netRegKey -Name "MemLabsComment" -Value "SystemDefaultTlsVersions and SchUseStrongCrypto set by MemLabs" -PropertyType STRING -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $netRegKey32 = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
                if (Test-Path $netRegKey32) {
                    New-ItemProperty -Path $netRegKey32 -Name "SystemDefaultTlsVersions" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $netRegKey32 -Name "SchUseStrongCrypto" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $netRegKey32 -Name "MemLabsComment" -Value "SystemDefaultTlsVersions and SchUseStrongCrypto set by MemLabs" -PropertyType STRING -Force -ErrorAction SilentlyContinue | Out-Null
                }
                try {
                    if ($domainName -and ($domainName -ne "WORKGROUP")) {
                        New-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains" -Force | Out-Null
                        New-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$domainName" -Force | Out-Null
                        Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains" -Name "@" -Value "" -Force
                        New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$domainName" -Name "*" -Value 1 -PropertyType DWORD -Force | Out-Null
                    }
                    New-Item -Path "HKLM:\Software\Policies\Microsoft\Edge" -Force | Out-Null
                    New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Edge" -Name "HideFirstRunExperience" -Value 1 -PropertyType DWORD -Force | Out-Null
                    New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Edge" -Name "AutoImportAtFirstRun " -Value 4 -PropertyType DWORD -Force | Out-Null
                } catch {}
            } catch { $warnings += "TLS 1.2 Keys: $_" }

            # WorkgroupMember fix
            if ($isWorkgroup) {
                try {
                    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "LocalAccountTokenFilterPolicy" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                } catch { $warnings += "Fix WorkGroup: $_" }
            }

            # Suppress Windows Update immediately so it can't install updates
            # and trigger pending reboots before Phase 2 gets a chance to run.
            # Disable the services rather than registry-only — UsoSvc on newer
            # OS ignores NoAutoUpdate and restarts wuauserv on its own.
            # Phase 2 sets the full policy (WSUS server + blocking keys per config).
            try {
                foreach ($svc in @('wuauserv', 'UsoSvc')) {
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($s) {
                        Stop-Service $svc -Force -ErrorAction SilentlyContinue
                        Set-Service  $svc -StartupType Disabled -ErrorAction SilentlyContinue
                    }
                }
                # Set blocking registry keys as defense-in-depth. Even if a
                # component (e.g. ccmsetup) re-enables the services later,
                # these policies prevent WU from reaching the internet.
                $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                $auPath = "$wuPath\AU"
                New-Item -Path $auPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $wuPath -Name "DoNotConnectToWindowsUpdateInternetLocations" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $wuPath -Name "DisableWindowsUpdateAccess" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $auPath -Name "NoAutoUpdate" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
            } catch { $warnings += "Disable Windows Update services: $_" }

            # Suppress Microsoft Edge Update — it auto-updates in background,
            # leaving PendingFileRenameOperations that trigger unnecessary
            # reboots at Phase 2 start (MicrosoftEdgeUpdate.exe.old, EdgeUpdate
            # folder deletions). Disable the services and scheduled tasks.
            try {
                Invoke-WithCimRetry {
                foreach ($svc in @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')) {
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($s) {
                        Stop-Service $svc -Force -ErrorAction SilentlyContinue
                        Set-Service  $svc -StartupType Disabled -ErrorAction SilentlyContinue
                    }
                }
                Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
                    Where-Object { $_.TaskName -match 'MicrosoftEdgeUpdate' } |
                    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
                }
            } catch { $warnings += "Disable Edge Update: $_" }

            # Suppress telemetry, diagnostics, and background tasks that
            # generate network traffic, disk I/O, or PendingFileRename entries.
            try {
                Invoke-WithCimRetry {
                foreach ($svc in @('DiagTrack', 'dmwappushservice')) {
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($s) {
                        Stop-Service $svc -Force -ErrorAction SilentlyContinue
                        Set-Service  $svc -StartupType Disabled -ErrorAction SilentlyContinue
                    }
                }
                # Telemetry registry keys
                $dtPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
                New-Item -Path $dtPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $dtPath -Name 'AllowTelemetry' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $dtPath -Name 'DoNotShowFeedbackNotifications' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                # Advertising ID
                $advIdPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'
                New-Item -Path $advIdPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $advIdPath -Name 'DisabledByGroupPolicy' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                # Activity History
                $actPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
                New-Item -Path $actPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $actPath -Name 'PublishUserActivities' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $actPath -Name 'UploadUserActivities' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $actPath -Name 'EnableActivityFeed' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                # Tailored experiences, feedback, speech, inking, app tracking, location, WiFi Sense
                $tailoredPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
                New-Item -Path $tailoredPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $tailoredPath -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                $siufPath = 'HKCU:\Software\Microsoft\Siuf\Rules'
                New-Item -Path $siufPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $siufPath -Name 'NumberOfSIUFInPeriod' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                $speechPath = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'
                New-Item -Path $speechPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $speechPath -Name 'AllowInputPersonalization' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $speechPath -Name 'RestrictImplicitInkCollection' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $speechPath -Name 'RestrictImplicitTextCollection' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackProgs' -Value 0 -Force -ErrorAction SilentlyContinue
                $locPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
                New-Item -Path $locPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $locPath -Name 'DisableLocation' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                $wfPath = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config'
                New-Item -Path $wfPath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $wfPath -Name 'AutoConnectAllowedOEM' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                # Consumer experience / spotlight
                $cePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
                New-Item -Path $cePath -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path $cePath -Name 'DisableWindowsConsumerFeatures' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                # Disable noisy scheduled tasks
                $disableTasks = @(
                    '\Microsoft\Windows\Defrag\ScheduledDefrag'
                    '\Microsoft\Windows\Server Manager\ServerManager'
                    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
                    '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
                    '\Microsoft\Windows\Autochk\Proxy'
                    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
                    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
                    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
                )
                foreach ($taskFullName in $disableTasks) {
                    $taskName = Split-Path $taskFullName -Leaf
                    $taskPath = (Split-Path $taskFullName -Parent) + '\'
                    $t = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                    if ($t -and $t.State -ne 'Disabled') {
                        Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                # NGEN tasks (version-specific paths)
                Get-ScheduledTask -TaskPath '\Microsoft\Windows\.NET Framework\' -ErrorAction SilentlyContinue |
                    Where-Object { $_.TaskName -match 'NGEN' } |
                    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
                }
            } catch { $warnings += "Disable telemetry/tasks: $_" }

            # Visual performance: "Adjust for best performance" + disable
            # transparency, animations, Welcome Experience, Widgets, Copilot,
            # SysMain, and first-logon animation.
            try {
                # UserPreferencesMask = best performance
                $vfxPath = 'HKCU:\Control Panel\Desktop'
                Set-ItemProperty -Path $vfxPath -Name 'UserPreferencesMask' -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $vfxPath -Name 'MenuShowDelay' -Value '0' -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0' -Force -ErrorAction SilentlyContinue
                $advPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Set-ItemProperty -Path $advPath -Name 'TaskbarAnimations' -Value 0 -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $advPath -Name 'ListviewAlphaSelect' -Value 0 -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $advPath -Name 'ListviewShadow' -Value 0 -Force -ErrorAction SilentlyContinue
                $vfxSys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
                New-Item -Path $vfxSys -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $vfxSys -Name 'VisualFXSetting' -Value 2 -Force -ErrorAction SilentlyContinue
                # Transparency + DWM
                $themePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
                New-Item -Path $themePath -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $themePath -Name 'EnableTransparency' -Value 0 -Force -ErrorAction SilentlyContinue
                $dwmPath = 'HKCU:\Software\Microsoft\Windows\DWM'
                New-Item -Path $dwmPath -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $dwmPath -Name 'EnableAeroPeek' -Value 0 -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $dwmPath -Name 'AlwaysHibernateThumbnails' -Value 0 -Force -ErrorAction SilentlyContinue
                # Win11 client: Widgets, Copilot, Chat
                $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
                if ($os -and $os.ProductType -eq 1) {
                    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path $advPath -Name 'TaskbarDa' -Value 0 -Force -ErrorAction SilentlyContinue
                    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path $advPath -Name 'TaskbarMn' -Value 0 -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $advPath -Name 'EnableSnapAssistFlyout' -Value 0 -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $advPath -Name 'SnapAssist' -Value 0 -Force -ErrorAction SilentlyContinue
                }
                # Content Delivery Manager (Welcome Experience, suggested apps, tips)
                $cdmPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                New-Item -Path $cdmPath -Force -ErrorAction SilentlyContinue | Out-Null
                foreach ($cdmVal in @(
                    'SubscribedContent-310093Enabled', 'SubscribedContent-338389Enabled',
                    'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
                    'SubscribedContent-353696Enabled', 'SystemPaneSuggestionsEnabled',
                    'SilentInstalledAppsEnabled', 'SoftLandingEnabled',
                    'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled'
                )) {
                    New-ItemProperty -Path $cdmPath -Name $cdmVal -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                }
                # First-logon animation
                Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableFirstLogonAnimation' -Value 0 -Force -ErrorAction SilentlyContinue
                # Search highlights
                New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'EnableDynamicContentInWSB' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                # SysMain (Superfetch) — counterproductive on dynamic-memory VMs
                $s = Get-Service -Name 'SysMain' -ErrorAction SilentlyContinue
                if ($s) {
                    Stop-Service 'SysMain' -Force -ErrorAction SilentlyContinue
                    Set-Service  'SysMain' -StartupType Disabled -ErrorAction SilentlyContinue
                }
            } catch { $warnings += "Visual performance: $_" }

            [PSCustomObject]@{ Warnings = $warnings }
        }

        if ($createVM) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Configuring new VM settings (profile, account, timezone, TLS, etc.)"

            $timeZone = $deployConfig.vmOptions.timeZone
            if (-not $timeZone) {
                $timeZone = (Get-Timezone).id
            }
            $isWorkgroup = $currentItem.role -in "WorkgroupMember", "InternetClient"

            # -AsJob + -TimeoutSeconds so a wedged guest can't hang this step forever
            # (same hazard as disk init below). A healthy guest finishes in well under
            # 2 minutes, but when 15+ guests finish OOBE at once they all run this
            # PSDirect step simultaneously and a slow-but-healthy VM can exceed a
            # fixed 240s. Scale the timeout with lab size (same pattern as the DSC
            # stop): +10s per VM over 10, capped at 480s, floor 240s.
            $settingsVmCount = @($deployConfig.virtualMachines).Count
            $settingsTimeout = if ($settingsVmCount -gt 10) { [Math]::Min(480, 240 + 10 * ($settingsVmCount - 10)) } else { 240 }
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_NewVmSettings -ArgumentList @($timeZone, $domainNameForLogging, $isWorkgroup) -DisplayName "Configure new VM settings" -AsJob -TimeoutSeconds $settingsTimeout
            if ($result.ScriptBlockFailed) {
                # The step can fail two very different ways:
                #   1. Genuinely wedged guest WMI/CIM server (CIM/message-filter
                #      error, or a silent -AsJob timeout) - needs winmgmt restart /
                #      reboot recovery.
                #   2. A slow-but-healthy guest that just ran out of time under a
                #      concurrent-boot load spike - a reboot here is wasteful and
                #      adds minutes.
                # Probe liveness with a trivial PSDirect command (short timeout). If
                # the guest answers quickly it was only slow, so just retry the
                # idempotent settings step. Only when the probe fails (truly
                # unresponsive) do we escalate to Repair-VmCimServer's winmgmt
                # restart + reboot.
                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM settings step failed; probing guest liveness before escalating." -Warning
                $liveProbe = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { $env:COMPUTERNAME } -DisplayName "Liveness probe" -AsJob -TimeoutSeconds 60 -SuppressLog
                if (-not $liveProbe.ScriptBlockFailed) {
                    # Guest is responsive over PSDirect - it was just slow. Retry the
                    # idempotent step once with the scaled timeout before any reboot.
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Guest responded to liveness probe; retrying settings step (no recovery needed)." -Warning
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_NewVmSettings -ArgumentList @($timeZone, $domainNameForLogging, $isWorkgroup) -DisplayName "Configure new VM settings (retry)" -AsJob -TimeoutSeconds $settingsTimeout
                }
                if ($result.ScriptBlockFailed) {
                    # Either the probe failed (truly wedged) or the lightweight retry
                    # still didn't finish - now recover the guest in-place (restart
                    # winmgmt over PSDirect, escalate to reboot) and retry once. This
                    # is the first place the wedged-guest symptom usually surfaces, so
                    # healing here keeps the later disk-init step healthy too.
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Guest still failing; attempting CIM/WMI recovery." -Warning
                    if (Repair-VmCimServer -VmName $currentItem.vmName -VmDomainName $domainName -Phase $Phase -AllowReboot) {
                        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_NewVmSettings -ArgumentList @($timeZone, $domainNameForLogging, $isWorkgroup) -DisplayName "Configure new VM settings (post-recovery retry)" -AsJob -TimeoutSeconds $settingsTimeout
                    }
                }
            }
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to configure new VM settings." -Warning -OutputStream
                $skipVersionUpdate = $true
            }
            elseif ($result.ScriptBlockOutput.Warnings -and $result.ScriptBlockOutput.Warnings.Count -gt 0) {
                foreach ($w in $result.ScriptBlockOutput.Warnings) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): $w" -Warning -OutputStream
                }
            }
            # Set vm note
            if (-not $skipVersionUpdate) {
                $inProgress = (-not $Migrate)
                New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -InProgress $inProgress
            }
                   

            Write-Log "[Phase $Phase]: $($currentItem.vmName): Initializing Disks"
            Write-Progress2 -Activity "$($currentItem.vmName): Initializing disks" -Status "Starting" -force
            $count = 0
            $diskNum = 1
            $diskEntries = @()
            foreach ($disk in $currentItem.AdditionalDisks.psobject.properties) {
                $label = $null

                if ($currentItem.Role -eq "FileServer") {
                    if ($diskNum -eq 1) {
                        $label = "CONTENTLIB"
                    }
                    if ($diskNum -eq 2) {
                        $label = "CLUSTER"
                    }
                    $diskNum++
                }
                if ($currentItem.cmInstallDir -like "$($disk.Name)*") {
                    if ($label) {
                        $label = $label + "_"
                    }
                    $label = $label + "CM"
                }
                if ($currentItem.sqlInstanceDir -like "$($disk.Name)*") {
                    if ($label) {
                        $label = $label + "_"
                    }
                    $label = $label + "SQL"
                }
                if ($currentItem.wsusContentDir -like "$($disk.Name)*") {
                    if ($label) {
                        $label = $label + "_"
                    }
                    $label = $label + "WSUS"
                }

                if (-not $label) {
                    $label = "DATA`_$count"
                    $count++
                }
                $diskEntries += @{ Letter = $disk.Name; Size = $disk.Value; Label = $label }
            }

            if ($diskEntries.Count -gt 0) {
                $diskInitAttempts = 0
                $diskInitMaxAttempts = 5
                $diskInitSuccess = $false
                $cimWmiRestarted = $false
                $cimRebooted = $false
                while (-not $diskInitSuccess -and $diskInitAttempts -lt $diskInitMaxAttempts) {
                    $diskInitAttempts++
                    if ($diskInitAttempts -gt 1) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Disk init attempt $diskInitAttempts/$diskInitMaxAttempts" -Warning
                        Start-Sleep -Seconds 10
                    }
                    # Run as a job with a hard timeout. A wedged guest WMI/VDS service
                    # makes the Storage cmdlets (Get-Disk/Initialize-Disk) block forever
                    # WITHOUT returning an error, so a synchronous call would hang the
                    # whole Phase 1 job indefinitely (one stuck VM = the build never
                    # finishes). -AsJob + -TimeoutSeconds surfaces the hang as a failure
                    # so the recovery/retry logic below can run. Reuse the lab-size
                    # scaled timeout so a slow-but-healthy guest under concurrent-boot
                    # load isn't misread as wedged (same rationale as the settings step).
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Initialize $($diskEntries.Count) disk(s)" -AsJob -TimeoutSeconds $settingsTimeout -ScriptBlock {
                    param($entries)
                    $OriginalPref = $ProgressPreference
                    $ProgressPreference = "SilentlyContinue"
                    try { Import-Module Storage } catch {}

                    foreach ($entry in $entries) {
                        $letter = $entry.Letter
                        $size = ($entry.Size / 1)
                        $label = $entry.Label

                        if (-not $letter -or $letter -eq "AUTO") {
                            $usedLetters = Get-Volume | Select-Object -ExpandProperty DriveLetter
                            $allLetters = [char[]]([char]'E'..[char]'X')
                            $availableLetters = $allLetters | Where-Object { $_ -notin $usedLetters }
                            $letter = $availableLetters[0]
                        }

                        try {
                            $rawdisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -eq $size } | Select-Object -First 1
                        }
                        catch {
                            try {
                                (Get-Volume).DriveLetter | ForEach-Object { if ($_) { Write-VolumeCache -Driveletter $_ } }
                                Get-Disk | Update-Disk
                                Start-Sleep -Seconds 10
                            } catch {}
                            $rawdisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -eq $size } | Select-Object -First 1
                        }
                        if ($rawdisk) {
                            try {
                                $rawdisk | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter $letter | Format-Volume -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force | Out-Null
                            }
                            catch {
                                try {
                                    (Get-Volume).DriveLetter | ForEach-Object { if ($_) { Write-VolumeCache -Driveletter $_ } }
                                    Get-Disk | Update-Disk
                                    Start-Sleep -Seconds 10
                                } catch {}
                                $rawdisk | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter $letter | Format-Volume -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force | Out-Null
                            }
                        }
                    }

                    # Create NO_SMS_ON_DRIVE.SMS
                    New-Item "$env:systemdrive\NO_SMS_ON_DRIVE.SMS" -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null

                    $ProgressPreference = $OriginalPref
                } -ArgumentList @(, $diskEntries)
                    if (-not $result.ScriptBlockFailed) {
                        $diskInitSuccess = $true
                    }
                    elseif ($diskInitAttempts -lt $diskInitMaxAttempts) {
                        $diskErrText = "$($result.ScriptBlockOutput) $($result.ErrorDetails -join ' ')"
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Disk init failed (attempt $diskInitAttempts): $diskErrText" -Warning
                        # The guest's Storage stack depends on WMI/CIM/VDS. When that's
                        # wedged the call either fails with "Cannot connect to CIM server /
                        # message filter" or just times out silently (the -AsJob timeout
                        # above). PSDirect still works, so recover the guest in-place
                        # (restart WMI, then reboot) instead of failing the phase and
                        # rolling back every VM. Escalate on ANY repeated failure, since a
                        # silent timeout carries no CIM error text to match on.
                        if (-not $cimWmiRestarted) {
                            $cimWmiRestarted = $true
                            Repair-VmCimServer -VmName $currentItem.vmName -VmDomainName $domainName -Phase $Phase | Out-Null
                        }
                        elseif (-not $cimRebooted) {
                            $cimRebooted = $true
                            Repair-VmCimServer -VmName $currentItem.vmName -VmDomainName $domainName -Phase $Phase -AllowReboot | Out-Null
                        }
                    }
                }
                if (-not $diskInitSuccess) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to initialize disks after $diskInitMaxAttempts attempts. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }
                Write-Progress2 -Activity "$($currentItem.vmName): Initializing disks" -Status "Done" -Completed -Log -force
            }
            # SQL installation media is no longer copied to the VM at create time.
            # The SQL ISO is mounted to the VM's DVD drive by the host just before
            # Phase 4 (Mount-SqlIsoForPhase in Common.Phases.ps1) and Phase 4 DSC
            # installs SQL directly from it (drive letter S:). See plan: mount-
            # install-eject, single DVD reused after the create-time CM/OSD copies.
            #CM media is no longer copied to the VM at create time. When the CM
            #version is an ISO, the host mounts the CM ISO on-demand to the site
            #server's DVD drive right before Phase 8 (and Phase 9 / cross-forest
            #Phase 2) via Mount-CmIsoForPhase in Common.Phases.ps1, and CM is
            #installed directly from the DVD (REdist stays local at C:\CMCB\REdist).
            #URL-download CM versions still extract to C:\CMCB via the DownloadSCCM
            #DSC resource in Phase 8. So there is nothing to do here at create time.
            if ($currentItem.CMInstallDir -and $createVM) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): CM installation media will be mounted from ISO at install time (no create-time copy to C:\CMCB)." -LogOnly
            }
        }
        
        if ($deployConfig.cmOptions.PrePopulateObjects -and $currentItem.role -eq 'Primary' -and $createVM) {
            Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Copying OSD ISOs to Primary" -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Primary site server — copying OSD content for perfloading"

                if ($currentItem.cmInstallDir) {
                    $driveLetter = (Split-Path -Path $currentItem.cmInstallDir -Qualifier)
                }

                Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Copying baselines.zip" -force
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying baselines.zip to the VM."
                $sourceLocation = Join-Path $Common.AzureFilesPath "support\baselines.zip"
                Copy-ItemSafe -VmName $currentItem.vmName -VMDomainName $domainName -Path $sourceLocation -Destination "C:\tools" -Recurse -Container -Force
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Finished copying baselines.zip to the VM."

                Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying OS ISO files to the VM."

                $OsVersionsToGet = @("Windows 11 24h2", "Windows 10 22h2")

                $isoFiles = $azureFileList.OSISO | Where-Object { $_.id -in $OsVersionsToGet }
                $isoIndex = 0
                $isoTotal = @($isoFiles).Count

                foreach ($isoFile in $isoFiles) {
                    $isoIndex++

                    # OS ISO Path
                    $Iso = $isoFile.filename | Where-Object { $_.ToLowerInvariant().EndsWith(".iso") }
                    Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Mounting $($isoFile.id) ($isoIndex/$isoTotal)" -force
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying $iso files to the VM."
                    $IsoPath = Join-Path $Common.AzureFilesPath $Iso
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Mounting $IsoPath to the VM."
                    # Idempotent, per-drive, multi-drive-safe mount (gets its own drive
                    # if a cache/other disc is already mounted). The guest copy below
                    # picks THIS OS disc by content (sources\install.wim), never "the
                    # CD-ROM", so a co-mounted disc can't be copied by mistake.
                    if (-not (Mount-IsoOnVm -VmName $currentItem.vmName -IsoPath $IsoPath -Context "OS ($($isoFile.id))" -Phase $Phase)) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to mount OS ISO $IsoPath after retries" -Failure -OutputStream
                        return
                    }
                    $dirname = (join-path $driveLetter "OSD" $isoFile.id)

                    $CopyIsoFiles = {
                        param ($dirname)
                        New-Item -Path $dirname -ItemType Directory -Force | Out-Null
                        $cd = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } | Where-Object {
                            Test-Path ("$($_.DriveLetter):\sources\install.wim")
                        } | Select-Object -First 1
                        if (-not $cd) { throw "OS media DVD not visible (no CD-ROM with sources\install.wim)" }
                        Copy-Item -Path "$($cd.DriveLetter):\*" -Destination $dirname -Recurse -Force -Confirm:$false
                    }

                    # Copy files from DVD
                    Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Copying $($isoFile.id) ISO to VM ($isoIndex/$isoTotal)" -force
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying ISO WIM files to $dirname"
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Copy ISO WIM Files" -ScriptBlock $CopyIsoFiles -ArgumentList $dirname
                    if ($result.ScriptBlockFailed) {
                        $result2 = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Show Data" -ScriptBlock { Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter): $($_.FileSystemLabel)" } }
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): CD-ROM volumes: $($result2.ScriptBlockOutput)"
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy ISO WIM files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }

                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Test WIM Files" -ScriptBlock { param ($dirname) get-item "$dirname\sources\install.wim" } -ArgumentList $dirname 
                    if ($result.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy WIM installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }

                    Dismount-IsoFromVm -VmName $currentItem.vmName -IsoPath $IsoPath -Context "OS ($($isoFile.id))" -Phase $Phase
                }
                Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Done" -Completed -force
        }

        if ($createVM) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Creation completed successfully for $($currentItem.role)." -OutputStream -Success
        }
        else {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Existing VM Preparation completed successfully for $($currentItem.role)." -OutputStream -Success
        }
    }
    catch {
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log -LogOnly "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)"
    }
    finally {
        # VM creation can also run as a ThreadJob, so dispose its runspace-local
        # PSDirect cache before the worker exits.
        try {
            if (Get-Command Clear-VmSessionCache -ErrorAction SilentlyContinue) {
                $null = Clear-VmSessionCache
            }
            else {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Clear-VmSessionCache NOT FOUND -- this worker's PSDirect sessions will leak. Common.ps1 in this runspace is stale." -Warning -LogOnly
            }
        }
        catch {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Clear-VmSessionCache threw: $($_.Exception.Message)" -Warning -LogOnly
        }
    }
}

function Save-CMSetupLogsFromVm {
    <#
    .SYNOPSIS
        Pulls C:\ConfigMgrSetup.log and C:\staging\DSC\InstallCMLog.log out of
        a CM-setup VM (CAS / Primary / Secondary / PassiveSite) and writes
        them next to the host VMBuild log so operators can inspect them
        without RDP'ing the VM.
    .DESCRIPTION
        InstallCMLog.log (DSC wrapper transcript, normally <1 MB) is ALWAYS
        pulled in full. ConfigMgrSetup.log is pulled FULL on failure and as
        the last 5000 lines on success -- on CAS after a CB upgrade the full
        file routinely runs 100-300 MB, so the tail keeps disk + PSDirect
        serialization cost bounded while still preserving the operationally
        useful end-of-install context.
        Files land in (Split-Path $Common.LogPath -Parent) as:
            <VmName>-Phase<N>-<timestamp>-ConfigMgrSetup.log          (Failure: full)
            <VmName>-Phase<N>-<timestamp>-ConfigMgrSetup.tail5000.log (Success: tail)
            <VmName>-Phase<N>-<timestamp>-InstallCMLog.log            (always: full)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$DomainName,
        [Parameter(Mandatory)][int]$Phase,
        [Parameter(Mandatory)][ValidateSet('Success', 'Failure')][string]$Mode
    )

    $probeAndRead = {
        param([string]$Mode)
        $out = [ordered]@{
            SetupExists    = $false
            SetupBytes     = 0
            SetupContent   = $null
            SetupTail      = $false
            WrapperExists  = $false
            WrapperBytes   = 0
            WrapperContent = $null
        }
        if (Test-Path 'C:\ConfigMgrSetup.log') {
            $fi = Get-Item 'C:\ConfigMgrSetup.log' -ErrorAction SilentlyContinue
            if ($fi) {
                $out.SetupExists = $true
                $out.SetupBytes  = $fi.Length
                if ($Mode -eq 'Failure') {
                    $out.SetupContent = Get-Content -LiteralPath $fi.FullName -Raw -ErrorAction SilentlyContinue
                }
                else {
                    $out.SetupTail = $true
                    $out.SetupContent = (Get-Content -LiteralPath $fi.FullName -Tail 5000 -ErrorAction SilentlyContinue) -join "`r`n"
                }
            }
        }
        if (Test-Path 'C:\staging\DSC\InstallCMLog.log') {
            $fi = Get-Item 'C:\staging\DSC\InstallCMLog.log' -ErrorAction SilentlyContinue
            if ($fi) {
                $out.WrapperExists  = $true
                $out.WrapperBytes   = $fi.Length
                $out.WrapperContent = Get-Content -LiteralPath $fi.FullName -Raw -ErrorAction SilentlyContinue
            }
        }
        [pscustomobject]$out
    }

    try {
        $res = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -ScriptBlock $probeAndRead -ArgumentList @($Mode) -SuppressLog -DisplayName "Pull CM setup logs ($Mode)"
    }
    catch {
        Write-Log "[Phase $Phase]: $VmName`: CMLog capture: PSDirect call threw: $($_.Exception.Message)" -Warning
        return
    }
    if (-not $res -or $res.ScriptBlockFailed -or -not $res.ScriptBlockOutput) {
        Write-Log "[Phase $Phase]: $VmName`: CMLog capture: no response from VM" -Warning
        return
    }

    $r = $res.ScriptBlockOutput
    $logDir = $null
    if ($Common -and $Common.LogPath) { $logDir = Split-Path $Common.LogPath -Parent }
    if (-not $logDir -or -not (Test-Path $logDir)) {
        Write-Log "[Phase $Phase]: $VmName`: CMLog capture: host log dir not resolvable ($logDir)" -Warning
        return
    }

    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $base  = "$VmName-Phase$Phase-$stamp"

    if ($r.SetupExists) {
        if ($r.SetupContent) {
            $suffix = if ($r.SetupTail) { 'ConfigMgrSetup.tail5000.log' } else { 'ConfigMgrSetup.log' }
            $dest = Join-Path $logDir "$base-$suffix"
            try {
                Set-Content -LiteralPath $dest -Value $r.SetupContent -Encoding UTF8 -ErrorAction Stop
                $mb = [math]::Round($r.SetupBytes / 1MB, 2)
                $note = if ($r.SetupTail) { "tail of ${mb}MB in-VM" } else { "full ${mb}MB" }
                Write-Log "[Phase $Phase]: $VmName`: Pulled ConfigMgrSetup.log ($note) -> $dest" -OutputStream
            }
            catch {
                Write-Log "[Phase $Phase]: $VmName`: CMLog capture: failed to write ConfigMgrSetup copy: $_" -Warning
            }
        }
        else {
            Write-Log "[Phase $Phase]: $VmName`: ConfigMgrSetup.log present in VM ($($r.SetupBytes) bytes) but Get-Content returned empty" -Warning
        }
    }

    if ($r.WrapperExists) {
        if ($r.WrapperContent) {
            $dest = Join-Path $logDir "$base-InstallCMLog.log"
            try {
                Set-Content -LiteralPath $dest -Value $r.WrapperContent -Encoding UTF8 -ErrorAction Stop
                $kb = [math]::Round($r.WrapperBytes / 1KB, 1)
                Write-Log "[Phase $Phase]: $VmName`: Pulled InstallCMLog.log (${kb}KB) -> $dest" -OutputStream
            }
            catch {
                Write-Log "[Phase $Phase]: $VmName`: CMLog capture: failed to write InstallCMLog copy: $_" -Warning
            }
        }
        else {
            Write-Log "[Phase $Phase]: $VmName`: InstallCMLog.log present in VM ($($r.WrapperBytes) bytes) but Get-Content returned empty" -Warning
        }
    }
}

$global:VM_Config = {
    # Suppress CIM cmdlet progress in child process (see VM_Create comment).
    $Global:ProgressPreference = 'SilentlyContinue'

    try {
        $global:ScriptBlockName = "VM_Config"
        #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        # Get variables from parent scope
        $deployConfig = $using:deployConfigCopy
        $currentItem = $using:currentItem
        $enableVerbose = $using:enableVerbose
        $Phase = $using:Phase
        $ConfigurationData = $using:ConfigurationData
        $multiNodeDsc = $using:multiNodeDsc
        $reservation = $using:reservation
        $alreadyCopiedDSC = $using:alreadyCopiedDSC
        $phaseRunGuid = $using:phaseRunGuid
        $quietWUThisRun = $using:quietWUThisRun
        # Dot source common
        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose -DevBranch:$using:Common.DevBranch

        if (-not ($Common.LogPath)) {
            Write-Output "ERROR: [Phase $Phase] $($currentItem.vmName): Logpath is null. Common.ps1 may not be initialized."
            return
        }
    }
    catch {
        write-host "[$global:ScriptBlockName] had an exception during initialization $_"
        $msg = $ExceptionInfo.ScriptStackTrace
        write-host $msg
        $msg = (Get-PSCallStack | Select-Object Command, Location, Arguments | Format-Table | Out-String).Trim()
        write-host $msg
        throw
    }
    try {
        # Validate token exists
        if ($Common.FatalError) {
            Write-Output "Critical Failure! $($Common.FatalError)" -Failure -OutputStream
            return
        }

        $Activity = "Configure VM Phase $Phase"

        # Params for child script blocks
        $DscFolder = "phases"

        # Don't start DSC on any node except DC, for multi-DSC
        $skipStartDsc = $false
        if ($multiNodeDsc -and $currentItem.role -ne "DC") {
            $skipStartDsc = $true
        }

        # Change log location. Flush buffered lines to the previous path first.
        try { Flush-LogBuffer -All } catch { }
        $domainNameForLogging = $deployConfig.vmOptions.domainName
        $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"

        # Set domain name, depending on whether we need to create new VM or use existing one
        if ($currentItem.hidden -or ($currentItem.role -in ("DC", "BDC")) -or $Phase -gt 2) {
            $domainName = $deployConfig.parameters.DomainName
            if ($currentItem.domain) {
                $domainName = $currentItem.domain
            }
        }
        else {
            $domainName = "WORKGROUP"
        }

        # AADClient idempotency: once OOBE has been reached, the VM has no
        # usable accounts (sysprep /generalize wiped them).  A persistent
        # 'oobeComplete' flag in the VM note lets us skip the entire block
        # on reruns without probing connectivity.
        if ($currentItem.role -eq "AADClient") {
            $aadNote = Get-VMNote -VMName $currentItem.vmName
            if ($aadNote -and $aadNote.oobeComplete) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): OOBE already completed on a previous run. Skipping." -OutputStream -Success
                return
            }
        }

        # Get VM Session
        Write-Progress2 $Activity -Status "Waiting for VM to respond" -percentcomplete 0 -force

        # Verify again that VM is connectable, in case DSC caused a reboot
        $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName -SkipDiskTest:$alreadyCopiedDSC
        if (-not $connected) {
            # AADClient: if the VM is running but unreachable, it was already
            # sysprepped on a prior run and is sitting at OOBE with no local
            # accounts. PSDirect can't connect.  Mark complete so subsequent
            # re-runs skip it via the oobeComplete check above.
            if ($currentItem.role -eq "AADClient") {
                $vmState = (Get-VM2 -Name $currentItem.vmName -ErrorAction SilentlyContinue).State
                if ($vmState -eq "Running") {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): AADClient running but not connectable (likely at OOBE from a prior sysprep). Marking complete." -OutputStream -Success
                    $note = Get-VMNote -VMName $currentItem.vmName
                    if ($note) {
                        $note | Add-Member -MemberType NoteProperty -Name "oobeComplete" -Value $true -Force
                        Set-VMNote -VMName $currentItem.vmName -vmNote $note
                    }
                    return
                }
                if ($vmState -eq "Off") {
                    # VM was sysprepped and shut down on a prior run but never
                    # started back up. Start it and wait for OOBE.
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): AADClient is Off (post-sysprep from prior run). Starting and waiting for OOBE." -OutputStream -Warning
                    $started = Start-VM2 -Name $currentItem.vmName -Passthru
                    if ($started) {
                        $oobeStartedRecovery = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -OobeStarted -TimeoutMinutes 45
                        if ($oobeStartedRecovery) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): AADClient recovered — OOBE started. Marking complete." -OutputStream -Success
                        }
                        else {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): AADClient started but OOBE did not appear within 30 minutes." -OutputStream -Failure
                            return
                        }
                    }
                    else {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to start AADClient VM." -OutputStream -Failure
                        return
                    }
                    $note = Get-VMNote -VMName $currentItem.vmName
                    if ($note) {
                        $note | Add-Member -MemberType NoteProperty -Name "oobeComplete" -Value $true -Force
                        Set-VMNote -VMName $currentItem.vmName -vmNote $note
                    }
                    return
                }
            }
            # Last-resort failsafe: reboot the VM and give it 5 minutes before
            # failing the entire phase.  Even when channel-broken detection
            # didn't trigger (auth errors, unknown failures, etc.), a hard
            # reboot may clear a transient PSDirect or OS-level problem.
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Wait-ForVm timed out. Attempting last-resort reboot before failing." -Warning -OutputStream
            stop-vm2 -Name $currentItem.vmName -TurnOff
            Start-Sleep -seconds 10
            start-vm2 -Name $currentItem.vmName
            Start-Sleep -seconds 20
            $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName -TimeoutMinutes 5 -SkipDiskTest
            if (-not $connected) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if VM is connectable after last-resort reboot. Exiting." -Failure -OutputStream
                return
            }
            Write-Log "[Phase $Phase]: $($currentItem.vmName): VM responded after last-resort reboot." -Success -OutputStream
        }

        Write-Progress2 $Activity -Status "Establishing a session with the VM" -percentcomplete 2 -force
        $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName

        if (-not $ps) {

            Write-Progress2 $Activity -Status "Session failed, rebooting VM and retrying" -percentcomplete 3 -force
            Write-Log "$($currentItem.vmName)`: Failed to connect.  Attempting to reboot vm." 
            stop-vm2 -Name $currentItem.vmName
            Start-Sleep -seconds 10
            start-vm2 -Name $currentItem.vmName
            Start-Sleep -seconds 20
            
            $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName -SkipDiskTest
            if (-not $connected) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if VM is connectable. Exiting." -Failure -OutputStream
                return
            }

            $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName
            
            if (-not $ps) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
                return
            }
        }


        # Re-assert the Windows Update service stop+disable once per run per VM
        # (gated by $quietWUThisRun, computed in Common.Phases.ps1 -- mirrors the
        # once-per-run $alreadyCopiedDSC gate). The create-time disable only runs
        # at VM-create (Phase 1); a -StartPhase re-run skips it and the prior
        # deploy's Phase 11 re-enabled these services, so without this a re-run
        # services Windows Updates mid-build and slows every feature install.
        # Only the two services are touched (NOT TrustedInstaller -- DSC feature
        # installs need it, and NOT the WU policy keys -- those are Phase 2's to
        # set and Phase 11's marker-gated revert to clear). Phase 11 re-enables
        # wuauserv/UsoSvc unconditionally at the end, so disabling only the
        # services is self-cleaning without touching the marker design.
        if ($quietWUThisRun) {
            try {
                $wuResult = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Quiet Windows Update (stop+disable wuauserv/UsoSvc)" -ScriptBlock {
                    $acted = @()
                    foreach ($svc in @('wuauserv', 'UsoSvc')) {
                        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                        if ($s) {
                            if ($s.Status -eq 'Running') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
                            if ($s.StartType -ne 'Disabled') { Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue }
                            $acted += $svc
                        }
                    }
                    if ($acted.Count -gt 0) { "stopped+disabled: $($acted -join ', ')" } else { "no WU services present" }
                }
                if ($wuResult.ScriptBlockOutput) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Windows Update quieted for build ($($wuResult.ScriptBlockOutput))." -LogOnly
                }
            }
            catch {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Quiet Windows Update step failed (non-fatal): $($_.Exception.Message)" -Warning -LogOnly
            }
        }


        $Stop_RunningDSC = {
            # Helper: hard-delete the LCM's on-disk documents and disable the
            # DSC scheduled tasks so it cannot auto-resume from a doc we
            # missed. Remove-DscConfigurationDocument goes through CIM/WMI --
            # exactly the surface that hangs when LCM is mid-apply -- so it
            # silently no-ops on a stuck LCM. The MOFs live as plain files
            # under C:\Windows\System32\Configuration and admins can unlink
            # them directly. NEVER touch MetaConfig.mof: that is the LCM's
            # own settings (RebootNodeIfNeeded, ConfigurationMode, etc.); if
            # it disappears the LCM falls back to defaults and rejects the
            # next Set-DscLocalConfigurationManager push.
            $Force_PurgeDsc = {
                $cfgDir = 'C:\Windows\System32\Configuration'
                $docs = @(
                    'Current.mof', 'Current.mof.checksum',
                    'Pending.mof', 'Pending.mof.checksum',
                    'Previous.mof', 'Previous.mof.checksum',
                    'backup.mof', 'backup.mof.checksum',
                    'DSCEngineCache.mof'
                )
                foreach ($d in $docs) {
                    $p = Join-Path $cfgDir $d
                    if (Test-Path -LiteralPath $p) {
                        try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }
                # Disable the LCM's auto-run hooks so a respawned WmiPrvSE
                # can't re-launch consistency or boot-time recovery against
                # whatever document slipped past the purge.
                foreach ($task in @('Consistency', 'DSCRestartBootTask')) {
                    try {
                        $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Desired State Configuration\' -TaskName $task -ErrorAction SilentlyContinue
                        if ($t) {
                            if ($t.State -eq 'Running') { Stop-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue }
                            Disable-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue | Out-Null
                        }
                    } catch {}
                }
            }

            # Interrogate BEFORE destroying anything. Everything below runs
            # unconditionally today -- document purge, Stop-DscConfiguration with a
            # 30s wait, and a WmiPrvSE kill -- on EVERY VM at the start of EVERY
            # phase, whether or not the LCM is doing anything. Killing WmiPrvSE
            # takes the WMI provider host away from every other consumer on the box,
            # which on a site server includes ConfigMgr's own providers, so it is
            # worth knowing first whether there was ever anything to stop.
            #
            # The LCM query goes through CIM -- the same surface that hangs when the
            # LCM is mid-apply -- so it MUST be bounded, hence Invoke-CimMethod with
            # -OperationTimeoutSec rather than Get-DscLocalConfigurationManager. A
            # timeout is not a failure here: it is positive evidence that WMI is
            # wedged, which is exactly when the force path below is warranted.
            #
            # Anything other than a confident "Idle with no documents on disk" falls
            # through to the original path unchanged, so a wrong or unreadable answer
            # can only ever degrade to today's behaviour.
            $preLcmState = 'Unknown'
            $preLcmDetail = ''
            try {
                $mc = Invoke-CimMethod -Namespace 'root/Microsoft/Windows/DesiredStateConfiguration' `
                    -ClassName 'MSFT_DSCLocalConfigurationManager' -MethodName 'GetMetaConfiguration' `
                    -OperationTimeoutSec 10 -ErrorAction Stop
                if ($mc -and $mc.MetaConfiguration) {
                    $preLcmState = "$($mc.MetaConfiguration.LCMState)"
                    # LCMStateDetail names the resource actually being applied, which is
                    # the difference between "we killed idle housekeeping" and "we killed
                    # a 40-minute SQL install".
                    $preLcmDetail = "$($mc.MetaConfiguration.LCMStateDetail)"
                }
            }
            catch { $preLcmState = 'Unreadable' }

            $preDocs = @()
            foreach ($d in @('Current.mof', 'Pending.mof', 'Previous.mof')) {
                if (Test-Path -LiteralPath "C:\Windows\System32\Configuration\$d") { $preDocs += $d }
            }

            if ($preLcmState -eq 'Idle' -and $preDocs.Count -eq 0) {
                # Provably nothing to stop: no apply is running and there is no
                # document for a respawned provider host to resume from. Skip the
                # purge and the 30s stop. The final WmiPrvSE kill still happens
                # below -- a later phase relies on it to pick up machine.config
                # <defaultProxy> changes in a fresh AppDomain.
                try {
                    Get-Process WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Get-Process WmiApSrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                catch {}
                return [PSCustomObject]@{ Stopped = $true; LCMState = 'Idle'; PreLCMState = 'Idle'; PreLCMDetail = $preLcmDetail; PreDocs = ''; Action = 'skipped-nothing-to-stop' }
            }

            # 1. Try a clean stop first (flushes DSC logs so they're readable).
            #    Use a short timeout — on first run there's nothing to stop and
            #    it should return instantly; on re-runs a healthy LCM stops in
            #    seconds.
            $cleanStop = $false
            try {
                get-job | remove-job -ErrorAction SilentlyContinue
                Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force -ErrorAction SilentlyContinue | Out-Null
                $job = Stop-DscConfiguration -Force -AsJob
                $wait = Wait-Job -Timeout 30 $job
                if ($wait.State -eq "Completed") {
                    get-job | remove-job -ErrorAction SilentlyContinue
                    $cleanStop = $true
                }
                else {
                    # Clean stop timed out — kill the job
                    Stop-Job $job -ErrorAction SilentlyContinue
                    get-job | remove-job -ErrorAction SilentlyContinue
                }
            }
            catch {}

            # 2. If clean stop failed/timed out, kill WMI provider hosts to
            #    force-terminate a stuck DSC LCM, then retry.
            if (-not $cleanStop) {
                try {
                    Get-Process WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Get-Process WmiApSrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                } catch {}
                # Brief pause for WMI service to respawn
                Start-Sleep -Seconds 2
                # Take the documents away on disk so the respawned WmiPrvSE
                # has nothing to resume from. Without this, killing WmiPrvSE
                # only pauses the apply -- it can immediately re-load the
                # still-present Current.mof and pick up where it left off,
                # leaving LCMState=Busy and stranding DSC_ClearStatus.
                & $Force_PurgeDsc
                try {
                    Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force -ErrorAction SilentlyContinue | Out-Null
                    # Bound this second stop. Killing WmiPrvSE above already
                    # force-terminated the stuck LCM; this call is belt-and-
                    # suspenders, but run synchronously it re-attaches to the
                    # LCM (respawning WmiPrvSE) and can block indefinitely on a
                    # config that's mid-apply. Unbounded, it blew past the
                    # caller's 60s Invoke-VmCommand timeout, so the host marked
                    # the whole stop FAILED and escalated to a full VM reboot --
                    # even though the WMI kill had already cleared the LCM. Run
                    # it as a job with a short timeout and kill it if it hangs,
                    # so the scriptblock always returns well within 60s.
                    $stopJob2 = Stop-DscConfiguration -Force -AsJob
                    $wait2 = Wait-Job -Timeout 15 $stopJob2
                    if (-not $wait2 -or $wait2.State -ne "Completed") {
                        Stop-Job $stopJob2 -ErrorAction SilentlyContinue
                    }
                    get-job | remove-job -Force -ErrorAction SilentlyContinue
                } catch {}
            }

            # 3. Always kill WmiPrvSE at the end so .NET picks up any
            #    machine.config changes (e.g. <defaultProxy> from a prior
            #    phase) in a fresh AppDomain.
            try {
                Get-Process WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Get-Process WmiApSrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            } catch {}

            try { Disable-DscDebug -Force -ErrorAction SilentlyContinue | Out-Null } catch {}

            # Stop the ScriptWorkflow scheduled task if still running from a previous phase.
            # Phase 8/9 register this task to run ScriptWorkflow.ps1 which writes to DSC_Status.txt
            # independently of DSC LCM. Without stopping it, stale status from a prior phase
            # bleeds into the monitoring loop of the current phase.
            try {
                $swTask = Get-ScheduledTask -TaskName 'ScriptWorkflow' -ErrorAction SilentlyContinue
                if ($swTask) {
                    if ($swTask.State -eq 'Running') {
                        Stop-ScheduledTask -TaskName 'ScriptWorkflow' -ErrorAction SilentlyContinue
                    }
                    Unregister-ScheduledTask -TaskName 'ScriptWorkflow' -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            catch {}

            # 4. Verify the LCM actually stopped and report it back. The bounded
            #    stops above can be killed while still hung, so a bare "the
            #    scriptblock returned" is NOT proof the LCM is idle -- a still-
            #    Busy LCM means an old config is mid-apply and could leak forward
            #    into the new push. Return the real state so the host escalates
            #    to a reboot (the guaranteed way to clear an in-memory apply)
            #    only when DSC genuinely did not stop.
            #    If still Busy, retry the kill+purge cycle up to 4 more times.
            #    A WmiPrvSE that respawns can re-load a doc we missed (race
            #    between Stop-Process and Force_PurgeDsc's file unlink), so
            #    loop: re-purge, re-kill, re-check. Each iteration takes ~3s,
            #    bounded total ~12s extra -- well inside the outer 60-180s
            #    Invoke-VmCommand budget. DSC_ClearStatus depends on Busy=false
            #    here to write its readiness token, so kicking and screaming is
            #    the whole point.
            $lcmState = 'Unknown'
            $stopped = $true
            for ($drain = 0; $drain -lt 5; $drain++) {
                try {
                    $lcmState = (Get-DscLocalConfigurationManager -ErrorAction Stop).LCMState
                    # Busy = a configuration is actively applying. Anything else
                    # (Idle, PendingConfiguration, Ready) means no apply is running.
                    $stopped = ($lcmState -ne 'Busy')
                }
                catch {
                    # LCM unreadable right after we killed WmiPrvSE -- the provider
                    # host was just terminated, so there is no running apply. Treat
                    # as stopped (matches DSC_ClearStatus's LCM-gate logic).
                    $lcmState = 'Unknown'
                    $stopped = $true
                }
                if ($stopped) { break }
                # Still Busy. Repeat the on-disk purge + WmiPrvSE kill so the
                # respawned provider host has nothing to resume from.
                try { & $Force_PurgeDsc } catch {}
                try {
                    Get-Process WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Get-Process WmiApSrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                } catch {}
                Start-Sleep -Seconds 2
            }
            return [PSCustomObject]@{ Stopped = $stopped; LCMState = $lcmState; PreLCMState = $preLcmState; PreLCMDetail = $preLcmDetail; PreDocs = ($preDocs -join ','); Action = 'stopped' }
        }

        Write-Progress2 $Activity -Status "Stopping DSCs" -percentcomplete 5 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Stopping any previously running DSC Configurations."
        # Scale the stop timeout with lab size. After the bounded in-guest stop,
        # the scriptblock always returns in ~47s regardless of VM count; only the
        # WinRM/PSDirect transport setup grows with lab size under host CPU/disk
        # contention. Add 10s per VM over 10, capped at 180s so a genuinely dead
        # VM still escalates to the reboot that actually fixes it.
        $stopVmCount = @($deployConfig.virtualMachines).Count
        $stopTimeout = if ($stopVmCount -gt 10) { [Math]::Min(180, 60 + 10 * ($stopVmCount - 10)) } else { 60 }
        $result = Invoke-VmCommand -AsJob -TimeoutSeconds $stopTimeout -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
        # An LCM found Busy at PHASE START means the previous phase never finished --
        # we are force-terminating real work, not tidying up. That deserves to be
        # visible; it used to be sledgehammered silently.
        $sbo = $result.ScriptBlockOutput
        if ($sbo -and $sbo.PreLCMState) {
            if ($sbo.PreLCMState -eq 'Busy') {
                $what = if ($sbo.PreLCMDetail) { " applying '$($sbo.PreLCMDetail)'" } else { '' }
                Write-Log "[Phase $Phase]: $($currentItem.vmName): LCM was ACTIVELY APPLYING at phase start$what (docs: $($sbo.PreDocs)) -- forcing it down. A previous phase's configuration did not finish." -Warning
            }
            else {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): pre-stop LCM='$($sbo.PreLCMState)' docs='$($sbo.PreDocs)' -> $($sbo.Action)" -LogOnly
            }
        }
        # Escalate not only on a job timeout/failure, but also when the in-guest
        # stop reported the LCM is still Busy (a bounded stop that got killed
        # while hung). Either way the LCM is not confirmed idle, so we must not
        # let an old DSC leak forward into the new push.
        $stopFailed = $result.ScriptBlockFailed -or ($result.ScriptBlockOutput -and ($result.ScriptBlockOutput.Stopped -eq $false))
        if ($stopFailed) {
            Write-Progress2 $Activity -Status "Retry Stopping DSCs" -percentcomplete 5 -force
            $result = Invoke-VmCommand -AsJob -TimeoutSeconds $stopTimeout -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
            $stopFailed = $result.ScriptBlockFailed -or ($result.ScriptBlockOutput -and ($result.ScriptBlockOutput.Stopped -eq $false))
            if ($stopFailed) {
                $lcmInfo = if ($result.ScriptBlockOutput -and $result.ScriptBlockOutput.LCMState) { " (LCM='$($result.ScriptBlockOutput.LCMState)')" } else { "" }
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC did not stop$lcmInfo; rebooting VM to clear the running configuration." -Warning
                Write-Progress2 $Activity -Status "Restarting VM then Stopping DSCs" -percentcomplete 5 -force
                Stop-vm2 -name $currentItem.vmName
                Start-Sleep -Seconds 10
                start-vm2 -name  $currentItem.vmName
                Write-Progress2 $Activity -Status "Restarting VM then Stopping DSCs" -percentcomplete 5 -force
                Wait-ForHeartbeat -VmName $currentItem.vmName | Out-Null
                $result = Invoke-VmCommand -AsJob -TimeoutSeconds $stopTimeout -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
                $stopFailed = $result.ScriptBlockFailed -or ($result.ScriptBlockOutput -and ($result.ScriptBlockOutput.Stopped -eq $false))
                if ($stopFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to stop any running DSC's. $($result.ScriptBlockOutput)" -Warning -OutputStream
                }
            }
        }

        if ($Phase -eq 2) {
            $retryCount = 0
            $success = $false
          
            while ($retrycount -le 3 -and $success -eq $false) {
                Write-Progress2 $Activity -Status "Testing IP Address" -percentcomplete 9 -force
                #169.254.239.16
                $IPAddress = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { (Get-NetIPConfiguration).Ipv4Address.IpAddress } -DisplayName "GetIPs"
                $success = $true
                if ($IPAddress.ScriptBlockOutput) {
                    # A VM with multiple NICs (e.g. SQLAO with a ClusterV2 NIC)
                    # may have 169.254 on NICs that intentionally have no DHCP.
                    # Only fail if there are NO valid (non-APIPA) IPs at all.
                    $allIPs = @($IPAddress.ScriptBlockOutput)
                    $validIPs = @($allIPs | Where-Object { $_ -and -not $_.StartsWith("169.254") })
                    $apipaIPs = @($allIPs | Where-Object { $_ -and $_.StartsWith("169.254") })

                    if ($validIPs.Count -eq 0 -and $apipaIPs.Count -gt 0) {
                            $success = $false
                            $ip = $apipaIPs[0]
                            $currentNetwork = $currentItem.network
                            if (-not $currentNetwork) {
                                $currentNetwork = $deployConfig.vmOptions.Network
                            }
                            if ($retryCount -eq 1) {
                                try {
                                    Write-Progress2 $Activity -Status "Attempting to repair network $($currentNetwork) " -percentcomplete 10 -force
                                    # Disconnect and reconnect the VM's NIC to force
                                    # a fresh DHCP discover, without destroying the
                                    # scope (which nukes reservations for ALL VMs).
                                    $vmNic = Get-VMNetworkAdapter -VMName $currentItem.vmName -ErrorAction SilentlyContinue |
                                        Where-Object { $_.SwitchName -and $_.SwitchName -like "*$currentNetwork*" } |
                                        Select-Object -First 1
                                    if ($vmNic) {
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Disconnecting/reconnecting NIC '$($vmNic.Name)' on switch '$($vmNic.SwitchName)'" -Warning -OutputStream
                                        $savedSwitch = $vmNic.SwitchName
                                        Disconnect-VMNetworkAdapter -VMNetworkAdapter $vmNic -ErrorAction SilentlyContinue
                                        Start-Sleep -Seconds 3
                                        Connect-VMNetworkAdapter -VMNetworkAdapter $vmNic -SwitchName $savedSwitch -ErrorAction SilentlyContinue
                                    }
                                    # Restart DHCP service to clear any stale state.
                                    # Serialize under the host-wide DHCP mutex so this
                                    # VM's recovery doesn't take the shared DHCP server
                                    # down while other VMs' parallel Phase 2 jobs are
                                    # mid-reservation (that cascades "Failed to reserve
                                    # IP address" onto every concurrent job).
                                    Invoke-WithDhcpMutex -ScriptBlock {
                                        Stop-Service "DHCPServer" -ErrorAction SilentlyContinue | Out-Null
                                        Start-Sleep -Seconds 3
                                        $null = Start-DHCP
                                    }
                                    Start-Sleep -Seconds 10
                                    $null = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ipconfig /renew } -DisplayName "FixIPs"
                                }
                                catch {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to repair network $($currentNetwork). $($_.Exception.Message)" -Warning -OutputStream
                                    return
                                }
                            }
                            if ($retryCount -eq 0) {
                                try {
                                    # Serialize the shared-DHCP-server bounce (see retry 1 above).
                                    Invoke-WithDhcpMutex -ScriptBlock {
                                        Stop-Service "DHCPServer" -ErrorAction SilentlyContinue | Out-Null
                                        Start-Sleep -Seconds 5
                                        $null = Start-DHCP
                                    }
                                    $null = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ipconfig /renew } -DisplayName "FixIPs"
                                }
                                catch {                                   
                                }
                            }
                            if ($retryCount -eq 2) {
                                # Stronger recovery before giving up. An APIPA-stuck guest
                                # adapter frequently will NOT take a lease from a plain
                                # 'ipconfig /renew' (retries 0/1) -- the DHCP client is
                                # wedged in the fallback state. Force a full release +
                                # adapter restart (a clean DORA from scratch) IN-GUEST, and
                                # make sure the host scope is Active before the last check.
                                try {
                                    # Capture the PRISTINE state first: the adapter reset
                                    # below rewrites exactly the evidence that says whether
                                    # the guest ever put a DISCOVER on the wire.
                                    try {
                                        $preResetMac = Get-VMMacIsolated -VmName $currentItem.vmName -ExcludeCluster
                                        Write-DhcpLeaseFailureDiag -VmName $currentItem.vmName -ScopeId $currentNetwork -Mac $preResetMac -VmDomainName $domainName -Tag "[Phase $Phase]: DIAG(pre-reset)" -Quiet
                                    }
                                    catch { }

                                    Write-Progress2 $Activity -Status "Resetting guest network adapter on $($currentItem.vmName)" -percentcomplete 11 -force
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Still APIPA after NIC reconnect; forcing full guest adapter reset (release/restart/renew)." -Warning -OutputStream

                                    # An Inactive scope hands out nothing -> guest falls to
                                    # APIPA. Re-activate it if it somehow went Inactive.
                                    try {
                                        $scopeState = Get-DhcpServerv4Scope -ScopeId $currentNetwork -ErrorAction SilentlyContinue
                                        if ($scopeState -and $scopeState.State -ne 'Active') {
                                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DHCP scope $currentNetwork state is '$($scopeState.State)'; re-activating." -Warning -OutputStream
                                            Set-DhcpServerv4Scope -ScopeId $currentNetwork -State Active -ErrorAction SilentlyContinue
                                        }
                                    }
                                    catch { }

                                    # Full guest-side DORA. The PSDirect (VMBus) session is
                                    # NOT over IP, so restarting the guest NIC is safe -- it
                                    # doesn't drop our management channel.
                                    $null = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "ResetGuestNet" -ScriptBlock {
                                        try { ipconfig /release | Out-Null } catch { }
                                        Start-Sleep -Seconds 2
                                        try { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' } | Restart-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue } catch { }
                                        Start-Sleep -Seconds 6
                                        try { ipconfig /renew | Out-Null } catch { }
                                    }
                                    Start-Sleep -Seconds 12
                                }
                                catch {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Guest adapter reset attempt threw: $($_.Exception.Message)" -Warning -OutputStream
                                }
                            }
                            if ($retryCount -eq 3) {
                                $count = (Get-VMSwitch).Count
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Could not obtain a DHCP IP Address ($ip) Should be on $($currentNetwork) ($count Hyper-V switches in use. If this is over 20, this could be the issue)" -Failure -OutputStream

                                # ---- Rich diagnostics so the next occurrence is actionable ----
                                # host-side NIC binding (right switch? connected?)
                                try {
                                    $diagNic = Get-VMNetworkAdapter -VMName $currentItem.vmName -ErrorAction SilentlyContinue
                                    foreach ($n in @($diagNic)) {
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG host NIC '$($n.Name)' Switch='$($n.SwitchName)' Connected=$($n.Connected) MAC=$($n.MacAddress)" -OutputStream
                                    }
                                }
                                catch { }
                                # host-side scope state + exhaustion
                                try {
                                    $diagScope = Get-DhcpServerv4Scope -ScopeId $currentNetwork -ErrorAction SilentlyContinue
                                    if ($diagScope) {
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG DHCP scope $currentNetwork State=$($diagScope.State) Range=$($diagScope.StartRange)-$($diagScope.EndRange)" -OutputStream
                                        $diagStats = Get-DhcpServerv4ScopeStatistics -ScopeId $currentNetwork -ErrorAction SilentlyContinue
                                        if ($diagStats) {
                                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG DHCP scope stats Free=$($diagStats.Free) InUse=$($diagStats.InUse) Reserved=$($diagStats.Reserved) PercentInUse=$($diagStats.PercentageInUse)" -OutputStream
                                        }
                                    }
                                    else {
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG DHCP scope $currentNetwork NOT FOUND on host DHCP server." -OutputStream
                                    }
                                }
                                catch { }
                                # host-side reservation for this VM's MAC
                                try {
                                    $diagMac = Get-VMMacIsolated -VmName $currentItem.vmName -ExcludeCluster
                                    if ($diagMac) {
                                        $diagResv = Get-DhcpServerv4Reservation -ScopeId $currentNetwork -ErrorAction SilentlyContinue | Where-Object { ($_.ClientId -replace '-', '') -eq ($diagMac -replace '-', '') }
                                        if ($diagResv) {
                                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG reservation for MAC $diagMac -> $($diagResv.IPAddress)" -OutputStream
                                        }
                                        else {
                                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG no DHCP reservation found for MAC $diagMac in scope $currentNetwork." -OutputStream
                                        }
                                    }
                                }
                                catch { }
                                # guest-side ipconfig /all (to the build log)
                                try {
                                    $diagGuest = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "DiagIpconfig" -ScriptBlock { ipconfig /all | Out-String }
                                    if ($diagGuest -and $diagGuest.ScriptBlockOutput) {
                                        foreach ($gline in ($diagGuest.ScriptBlockOutput -split "`r?`n")) {
                                            if ($gline.Trim()) { Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG guest ipconfig: $($gline.Trim())" -LogOnly }
                                        }
                                    }
                                }
                                catch { }
                                # DHCP bindings / audit log / lease census / guest DHCP-client
                                # event log. Everything above was already proven HEALTHY on both
                                # recorded APIPA failures, so the answer is in here.
                                try {
                                    $finalMac = Get-VMMacIsolated -VmName $currentItem.vmName -ExcludeCluster
                                    Write-DhcpLeaseFailureDiag -VmName $currentItem.vmName -ScopeId $currentNetwork -Mac $finalMac -VmDomainName $domainName -Tag "[Phase $Phase]: DIAG(final)"
                                }
                                catch { }
                                return
                            }
                            $retryCount++
                    }
                }
            }

            # Persist the VM's real IP as LastKnownIP. Priority:
            # 1. DHCP reservation (authoritative — created by us in Phase 1)
            # 2. AssignedIP from deployConfig (set before Phase 1)
            # 3. GetIPs from guest, filtered to exclude SQLAO virtual IPs
            # LastKnownIP from a previous run is NOT used here — it may
            # itself have been poisoned by a virtual IP (the bug we're fixing).
            if ($success -and $IPAddress.ScriptBlockOutput) {
                $resolvedIP = $null
                $ipSource = 'none'
                $reservationIP = $null

                # 1. DHCP reservation — most authoritative.
                # DHCP/Hyper-V CIM calls run isolated so they don't poison the bars.
                try {
                    $vmMac = Get-VMMacIsolated -VmName $currentItem.vmName -ExcludeCluster
                    if ($vmMac) {
                        $scopeId = if ($currentItem.role -in 'InternetClient', 'AADClient') { '172.31.250.0' } else { if ($currentItem.network) { $currentItem.network } else { $deployConfig.vmOptions.network } }
                        $reservationIP = Get-DHCPReservationIPForMac -ScopeId $scopeId -Mac $vmMac
                        if ($reservationIP) {
                            $resolvedIP = $reservationIP
                            $ipSource = 'DHCP'
                        }
                    }
                }
                catch {}

                # 2. AssignedIP from pre-Phase-1 allocation
                if (-not $resolvedIP -and $currentItem.AssignedIP) {
                    $resolvedIP = $currentItem.AssignedIP
                    $ipSource = 'AssignedIP'
                }

                # 3. GetIPs result, filtered for SQLAO virtual IPs
                if (-not $resolvedIP) {
                    # Build exclusion set from SQLAO virtual IPs in deployConfig
                    $sqlaoExclude = [System.Collections.Generic.HashSet[string]]::new()
                    foreach ($sqlaoVm in ($deployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' })) {
                        if ($sqlaoVm.ClusterIPAddress)    { $null = $sqlaoExclude.Add(($sqlaoVm.ClusterIPAddress -replace '/\d+$','')) }
                        if ($sqlaoVm.AGIPAddress)         { $null = $sqlaoExclude.Add(($sqlaoVm.AGIPAddress -replace '/\d+$','')) }
                        if ($sqlaoVm.ClusterHeartbeatIP)  { $null = $sqlaoExclude.Add($sqlaoVm.ClusterHeartbeatIP) }
                    }
                    # Also check VM Notes for the IPs (available on reruns)
                    if ($sqlaoExclude.Count -eq 0 -and $currentItem.role -eq 'SQLAO') {
                        try {
                            foreach ($sqlaoVm in ($deployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' })) {
                                $note = Get-VMNote -VMName $sqlaoVm.vmName
                                if ($note) {
                                    if ($note.ClusterIPAddress)    { $null = $sqlaoExclude.Add(($note.ClusterIPAddress -replace '/\d+$','')) }
                                    if ($note.AGIPAddress)         { $null = $sqlaoExclude.Add(($note.AGIPAddress -replace '/\d+$','')) }
                                    if ($note.ClusterHeartbeatIP)  { $null = $sqlaoExclude.Add($note.ClusterHeartbeatIP) }
                                }
                            }
                        } catch {}
                    }

                    $filteredIPs = @($IPAddress.ScriptBlockOutput | Where-Object {
                        $_ -and
                        -not $_.StartsWith("169.254") -and
                        -not $sqlaoExclude.Contains($_)
                    })
                    if ($filteredIPs.Count -gt 0) {
                        $resolvedIP = $filteredIPs[0]
                        $ipSource = 'GetIPs'
                        if ($filteredIPs.Count -gt 1 -or $sqlaoExclude.Count -gt 0) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): GetIPs returned $($IPAddress.ScriptBlockOutput -join ', '); after filtering ($($sqlaoExclude.Count) SQLAO IPs): $($filteredIPs -join ', ')" -LogOnly
                        }
                    }
                    else {
                        # Last resort: take first non-APIPA even if it might be virtual
                        $resolvedIP = $IPAddress.ScriptBlockOutput | Where-Object { $_ -and -not $_.StartsWith("169.254") } | Select-Object -First 1
                        if ($resolvedIP) { $ipSource = 'GetIPs-unfiltered' }
                    }
                }

                if ($resolvedIP) {
                    $existingIP = $currentItem.LastKnownIP
                    if (-not $existingIP -or $existingIP -ne $resolvedIP) {
                        $wasIP = if ($existingIP) { $existingIP } else { 'unset' }
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Setting LastKnownIP to $resolvedIP via $ipSource (was: $wasIP)" -LogOnly
                        $currentItem | Add-Member -NotePropertyName LastKnownIP -NotePropertyValue $resolvedIP -Force
                    }

                    # Create a DHCP reservation so the IP is stable across reboots.
                    # CAS/Primary/Secondary get fixed-IP reservations in Phase 1.
                    # Linux VMs get theirs during Phase 1 creation. OSDClient has no network.
                    if ($currentItem.role -notin "CAS", "Primary", "Secondary", "OSDClient" -and -not (Test-VmIsLinux -Vm $currentItem)) {
                        if ($reservationIP -and $reservationIP -eq $resolvedIP) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DHCP reservation already matches $resolvedIP" -LogOnly
                        }
                        else {
                            # DHCP/Hyper-V CIM calls run isolated so they don't poison the bars.
                            try {
                                $vmMac = Get-VMMacIsolated -VmName $currentItem.vmName
                                if ($vmMac) {
                                    if ($currentItem.role -in "InternetClient", "AADClient") {
                                        $realnetwork = "172.31.250.0"
                                    }
                                    else {
                                        # Derive the scope from the IP we're actually reserving so a VM on a
                                        # secondary subnet (e.g. an existing DC on a different network than the
                                        # VMs being added this run) reserves in ITS OWN /24 scope rather than
                                        # vmOptions.network (which is the NEW deployment's network). A DHCP
                                        # reservation must live in the scope that contains the IP, so reserving
                                        # a .110.1 address against a .112.0 scope fails every retry.
                                        $ipOctets = ([string]$resolvedIP).Split('.')
                                        if ($ipOctets.Count -eq 4) {
                                            $realnetwork = "$($ipOctets[0]).$($ipOctets[1]).$($ipOctets[2]).0"
                                        }
                                        elseif ($currentItem.network) { $realnetwork = $currentItem.network }
                                        else { $realnetwork = $deployConfig.vmOptions.network }
                                    }
                                    Remove-DHCPReservation -mac $vmMac -vmName $currentItem.vmName
                                    Add-DHCPReservationIsolated -ScopeId $realnetwork -IPAddress $resolvedIP -Mac $vmMac -Description "Reservation for $($currentItem.vmName)"
                                }
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DHCP reservation created for $resolvedIP" -LogOnly
                            }
                            catch {
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not create DHCP reservation for $resolvedIP. $_" -Warning
                            }
                        }
                    }
                }
            }
        }

        # inject tools
        if ($Phase -eq 2) {

            Write-Progress2 $Activity -Status "Injecting Tools" -percentcomplete 10 -force
            $SkipAutoDeploy = $false
            if ($deployConfig.cmOptions.PrePopulateObjects) {
                if ($deployConfig.cmOptions.Install) {
                    $SkipAutoDeploy = $true
                }
            }
            $injected = Install-Tools -VmName $currentItem.vmName -ShowProgress -SkipAutoDeploy:$SkipAutoDeploy
            # Coerce: a stray object on Install-Tools' output stream would make $injected a
            # truthy array and silently skip everything below (that is exactly what happened
            # on CS4-CS1SQL). Judge on the boolean the function actually returned.
            $injectedOk = ((@($injected) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) -eq $true)
            if (-not $injectedOk) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not inject tools in the VM." -Warning -OutputStream

                # The VM may be wedged (PSDirect OutOfMemoryException, "remote session might have
                # ended", repeated Get-VmSession failures all indicate the guest is dead). Probe
                # the session; if it's gone, hard reset and retry Install-Tools once before we
                # fall through to DSC module detection, which would otherwise also fail.
                $probeSession = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName
                if (-not $probeSession) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): No session after Install-Tools failure. VM appears wedged; performing hard reset." -Warning -OutputStream
                    Write-Progress2 $Activity -Status "VM unresponsive after Install-Tools, hard resetting" -percentcomplete 12 -force
                    try { Stop-VM2 -Name $currentItem.vmName -TurnOff } catch { Stop-VM2 -Name $currentItem.vmName }
                    Start-Sleep -Seconds 10
                    Start-VM2 -Name $currentItem.vmName
                    Start-Sleep -Seconds 20

                    $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName -SkipDiskTest
                    if (-not $connected) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): VM did not come back after hard reset. Exiting." -Failure -OutputStream
                        return
                    }

                    Write-Progress2 $Activity -Status "Retrying tool injection after reboot" -percentcomplete 13 -force
                    $injected = Install-Tools -VmName $currentItem.vmName -ShowProgress -SkipAutoDeploy:$SkipAutoDeploy
                    $injectedOk = ((@($injected) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) -eq $true)
                    if (-not $injectedOk) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Tool injection still failing after hard reset." -Warning -OutputStream
                    }
                }
                if (-not $injectedOk) {
                    # Surface it to the phase tally. Tools are a hard dependency for later
                    # phases, so a phase that ends with them missing must not report clean.
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Tool injection FAILED -- later phases depend on the injected tools. See the Copy-ItemSafe stall-diag lines above for why the copy died." -Failure -OutputStream
                }
            }
        }
        
        # copy language packs when locale is set to other than en-US
        if (($Phase -eq 2) -and ($deployConfig.vmOptions.locale -and $deployConfig.vmOptions.locale -ne "en-US")) {
            Write-Progress2 $Activity -Status "Copying language packs" -percentcomplete 15 -force
            $copied = Copy-LanguagePacksToVM -VmName $currentItem.vmName -ShowProgress
            if (-not $copied) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not copy language packs to the VM." -Warning
            }
        }

        # Ad-hoc: copy _localeConfig.json
        if (($Phase -eq 2) -and ($deployConfig.vmOptions.locale -and $deployConfig.vmOptions.locale -ne "en-US")) {
            Write-Progress2 $Activity -Status "Copying language packs" -percentcomplete 18 -force
            $copied = Copy-LocaleConfigToVM -VmName $currentItem.vmName -ShowProgress
            if (-not $copied) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not copy _localeConfig.json to the VM." -Warning
            }
        }


        if ($Phase -eq 5 -and $currentItem.role -eq "SQLAO") {
            # --- Hot-add the cluster heartbeat (2nd) NIC here, at the start of Phase 5,
            # instead of during Phase 1 VM creation (slow under the parallel-OOBE storm).
            # SQLAO VMs are Gen2 so the NIC hot-adds to the running VM. The host adapter is
            # named "Cluster"; the in-guest connection is also renamed to "Cluster" by the
            # DisableClusterNicDnsRegistration DSC resource (keyed off the 10.250.251.* subnet).
            # Idempotent: never add a 2nd NIC if a ClusterV2/Cluster NIC already exists --
            # a duplicate heartbeat NIC breaks the cluster network.
            #
            # Heartbeat IPs are pre-allocated SERIALLY by Set-SQLAOHeartbeatIPs immediately
            # before the Phase 5 jobs fan out, so there is NO per-node allocation and NO
            # GetIP-mutex contention here. (The old per-node Phase 5 allocation raced across
            # multiple clusters and handed the same 10.250.251.20 to several nodes -> Windows
            # flagged it Duplicate -> APIPA -> no cluster network.) Add-VMNetworkAdapter below
            # acts on this one distinct VM, so it needs no mutex either.
            Write-Progress2 $Activity -Status "SQLAO: Preparing heartbeat NIC" -percentcomplete 5 -force

            $vmObj = Get-VM2 $currentItem.vmName
            $hasClusterNic = $false
            if ($vmObj) {
                $hasClusterNic = [bool]($vmObj.NetworkAdapters | Where-Object { $_.SwitchName -in @("ClusterV2", "Cluster") })
            }

            $nicFailure = $null
            $addedNic = $false
            if (-not $hasClusterNic) {
                Write-Progress2 $Activity -Status "SQLAO: Adding heartbeat NIC" -percentcomplete 6 -force
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Adding heartbeat NIC 'Cluster' on switch ClusterV2" -OutputStream
                $Global:ProgressPreference = 'SilentlyContinue'
                try {
                    $vmnet = Add-VMNetworkAdapter -VMName $currentItem.vmName -SwitchName "ClusterV2" -Name "Cluster" -Passthru
                    $addedNic = $true
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): NIC added MAC: $($vmnet.MacAddress)" -LogOnly
                    if (-not $($vmnet.MacAddress)) {
                        Start-Sleep -Seconds 60
                        if (-not $($vmnet.MacAddress)) { $nicFailure = "Heartbeat NIC has no MAC address: $($vmnet)" }
                    }
                }
                catch {
                    Write-Exception $_
                    $nicFailure = "Failed to add heartbeat NIC: $_"
                }
            }

            if ($nicFailure) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): $nicFailure. SQLAO cluster network will not form without the heartbeat NIC." -Failure -OutputStream
            }
            elseif ($addedNic) {
                # Hot-add: give the guest a moment to enumerate the new adapter before the
                # static-IP config below looks it up by MAC (handled with a retry there too).
                Start-Sleep -Seconds 3
            }

            # Set static IP on the cluster heartbeat NIC before DSC runs.
            # The heartbeat NIC has no DHCP — we configure it directly via
            # PowerShell Direct using the pre-allocated IP.
            Write-Progress2 $Activity -Status "Configuring heartbeat NIC" -percentcomplete 9 -force
            $heartbeatIP = $currentItem.ClusterHeartbeatIP
            if (-not $heartbeatIP) {
                # Pre-allocated on the deploy config by Set-SQLAOHeartbeatIPs; on a
                # deep-copied per-job config or a later rerun, fall back to the VM Note.
                Write-Log "[Phase $Phase]: $($currentItem.vmName): ClusterHeartbeatIP not in deploy config, reading from VM Note" -LogOnly
                $vmNote = Get-VMNote -VMName $currentItem.vmName
                if ($vmNote) { $heartbeatIP = $vmNote.ClusterHeartbeatIP }
            }
            if ($heartbeatIP) {
                $vm = Get-VM2 $currentItem.vmName
                # Try ClusterV2 first (new deployments), fall back to Cluster (legacy)
                $clusterMAC = ($vm.NetworkAdapters | Where-Object { $_.SwitchName -eq "ClusterV2" }).MacAddress
                if (-not $clusterMAC) {
                    $clusterMAC = ($vm.NetworkAdapters | Where-Object { $_.SwitchName -eq "Cluster" }).MacAddress
                }
                if ($clusterMAC) {
                    $setStaticIP = {
                        param($targetIP, $targetMAC)
                        $targetMAC = ($targetMAC -replace '-','').ToLower()
                        # The heartbeat NIC is hot-added at the start of Phase 5, so the
                        # guest may take a few seconds to enumerate it. Retry up to ~30s.
                        $nic = $null
                        for ($findTry = 0; $findTry -lt 15; $findTry++) {
                            $nic = Get-NetAdapter | Where-Object { ($_.MacAddress -replace '-','').ToLower() -eq $targetMAC }
                            if ($nic) { break }
                            Start-Sleep -Seconds 2
                        }
                        if (-not $nic) { throw "Could not find NIC with MAC $targetMAC after 30s" }
                        $idx = $nic.InterfaceIndex
                        $info = ""

                        # Check if DHCP is active on this NIC and kill it first.
                        # On legacy "Cluster" switches, the DHCP scope hands out
                        # 10.250.250.x which fights with the static 10.250.251.x
                        # we want to assign. Release the lease and disable DHCP
                        # before touching IP addresses.
                        $dhcpStatus = (Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
                        if ($dhcpStatus -eq 'Enabled') {
                            $dhcpIPs = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                                Where-Object { $_.PrefixOrigin -eq 'Dhcp' })
                            if ($dhcpIPs) {
                                $info = "Removed DHCP IP(s) $($dhcpIPs.IPAddress -join ','); "
                            }
                            # Release the DHCP lease via ipconfig (works even when
                            # Set-NetIPInterface hasn't disabled DHCP yet)
                            $alias = $nic.InterfaceAlias
                            & ipconfig /release "$alias" 2>&1 | Out-Null
                            # Disable DHCP client on this interface
                            Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -ErrorAction SilentlyContinue
                        }

                        # Check if the IP is already configured (idempotent for reruns)
                        $existing = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object { $_.IPAddress -eq $targetIP }
                        if ($existing) {
                            # Ensure DHCP stays disabled even on idempotent rerun
                            Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -ErrorAction SilentlyContinue
                            # Ensure DNS registration is impossible even on rerun:
                            # no DNS servers + no suffix + registration flag off
                            Set-DnsClient -InterfaceIndex $idx -RegisterThisConnectionsAddress $false -ConnectionSpecificSuffix '' -ErrorAction SilentlyContinue
                            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @() -ErrorAction SilentlyContinue
                            return "${info}Already configured"
                        }

                        # Remove APIPA or stale IPs from this adapter
                        Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
                            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                        # Disable DHCP on this interface so it can't reclaim the address
                        Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -ErrorAction SilentlyContinue

                        # Make DNS registration impossible — heartbeat IPs must not appear in DNS.
                        # Three layers: flag off + no DNS servers + no suffix.
                        Set-DnsClient -InterfaceIndex $idx -RegisterThisConnectionsAddress $false -ConnectionSpecificSuffix '' -ErrorAction SilentlyContinue
                        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @() -ErrorAction SilentlyContinue

                        # Assign static IP — no gateway, no DNS (heartbeat only)
                        New-NetIPAddress -InterfaceIndex $idx -IPAddress $targetIP -PrefixLength 24 | Out-Null

                        # Verify the IP actually took — if it didn't, SQLAO will
                        # hang for hours waiting for a cluster network that can't form.
                        Start-Sleep -Seconds 2
                        $verify = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object { $_.IPAddress -eq $targetIP }
                        if (-not $verify) {
                            # Dump current state for diagnostics
                            $currentIPs = (Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -join ', '
                            $dhcpNow = (Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
                            throw "New-NetIPAddress did not error but $targetIP is not on the adapter. Current IPs: [$currentIPs] DHCP: $dhcpNow"
                        }
                        return "${info}Configured $targetIP (verified)"
                    }
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName `
                        -ScriptBlock $setStaticIP -ArgumentList @($heartbeatIP, $clusterMAC) `
                        -DisplayName "Set heartbeat static IP $heartbeatIP"
                    if ($result.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set heartbeat IP $heartbeatIP. SQLAO cluster network will not form without this. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    }
                    else {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Heartbeat NIC: $($result.ScriptBlockOutput)"
                    }
                }
                else {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): No Cluster/ClusterV2 NIC found on VM. SQLAO requires a dedicated heartbeat NIC." -Failure -OutputStream
                }
            }
            else {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): No ClusterHeartbeatIP found in deploy config or VM Note. Cannot configure heartbeat NIC — SQLAO will fail." -Failure -OutputStream
            }
        }


        # Boot To OOBE?
        $bootToOOBE = $currentItem.role -eq "AADClient"
        $oobeStarted = $false
        if ($bootToOOBE) {
            # Prepare the VM for sysprep /generalize /oobe /shutdown.
            # The base image is cloned so /generalize is needed to reset the SID.
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-NetFirewallProfile -All -Enabled false }
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                # 1. Disable the built-in Administrator account before sysprep.
                #    CryptoSysPrep_Specialize calls DisableAdministratorIfApplicable
                #    during the specialize pass. If it actually disables the account
                #    mid-execution, subsequent crypto operations fail with 0x5
                #    (ACCESS_DENIED). Pre-disabling makes it a no-op.
                Disable-LocalUser -Name "Administrator" -ErrorAction SilentlyContinue

                # 2. Disable Defender real-time protection. Defender can hold locks
                #    on crypto stores during the specialize pass, contributing to
                #    CryptoSysPrep_Specialize 0x5 failures.
                Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue

                # 3. Bypass hardware requirement checks during the specialize pass.
                #    Windows 11 24H2 re-checks TPM/SecureBoot/etc. after /generalize.
                $labConfig = 'HKLM:\SYSTEM\Setup\LabConfig'
                if (-not (Test-Path $labConfig)) { New-Item -Path $labConfig -Force | Out-Null }
                Set-ItemProperty -Path $labConfig -Name BypassTPMCheck -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $labConfig -Name BypassSecureBootCheck -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $labConfig -Name BypassRAMCheck -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $labConfig -Name BypassStorageCheck -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $labConfig -Name BypassCPUCheck -Value 1 -Type DWord -Force
                $moSetup = 'HKLM:\SYSTEM\Setup\MoSetup'
                if (-not (Test-Path $moSetup)) { New-Item -Path $moSetup -Force | Out-Null }
                Set-ItemProperty -Path $moSetup -Name AllowUpgradesWithUnsupportedTPMOrCPU -Value 1 -Type DWord -Force
            }

            # 4. Settle delay — let services stabilize after first boot before
            #    sysprep tears everything down.
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Waiting 90s for services to settle before sysprep..." -LogOnly
            Start-Sleep -Seconds 90

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { C:\Windows\system32\sysprep\sysprep.exe /generalize /oobe /shutdown }
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to boot the VM to OOBE. $($result.ScriptBlockOutput)" -Failure -OutputStream
            }
            else {
                $ready = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -VmState "Off" -TimeoutMinutes 30
                if (-not $ready) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Timed out while waiting for sysprep to shut the VM down." -OutputStream -Failure
                }
                else {
                    $started = Start-VM2 -Name $currentItem.vmName -Passthru
                    if ($started) {
                        $oobeStarted = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -OobeStarted -TimeoutMinutes 45
                        if ($oobeStarted) {
                            Write-Progress2 -Activity "Wait for VM to start OOBE" -Status "Complete!" -Completed -force
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): Configuration completed successfully for $($currentItem.role). VM is at OOBE." -OutputStream -Success
                        }
                        else {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): Timed out while waiting for OOBE to start." -OutputStream -Failure
                        }
                    }
                    else {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Failed to start." -OutputStream -Failure
                    }
                }
            }
            # Update VMNote; persist oobeComplete so reruns skip this block entirely.
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $oobeStarted
            if ($oobeStarted) {
                $note = Get-VMNote -VMName $currentItem.vmName
                $note | Add-Member -MemberType NoteProperty -Name "oobeComplete" -Value $true -Force
                Set-VMNote -VMName $currentItem.vmName -vmNote $note
            }
            return
        }

        Write-Progress2 $Activity -Status "Enable PS-Remoting" -percentcomplete 25 -force
        # Enable PS Remoting on client OS before starting DSC. Ignore failures, this will work but reports a failure...
        if ($currentItem.operatingSystem -notlike "*SERVER*") {
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Enable-PSRemoting -ErrorAction SilentlyContinue -Confirm:$false -SkipNetworkProfileCheck } -DisplayName "DSC: Enable-PSRemoting. Ignore failures."
        }

        Write-Progress2 $Activity -Status "Checking DSC modules" -percentcomplete 30 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Detect if modules need to be updated."
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
            New-Item -Path "C:\staging\DSC" -ItemType Directory -Force | Out-Null
            $flagPath = "C:\staging\DSC\DSC.zip.Installed"
            $sigPath  = "C:\staging\DSC\DSC.SourceSignature"
            [PSCustomObject]@{
                Hash            = (Get-FileHash -Path "C:\staging\DSC\DSC.zip" -Algorithm MD5 -ErrorAction SilentlyContinue).Hash
                FlagExists      = Test-Path $flagPath
                InstalledHash   = if (Test-Path $flagPath) { $c = Get-Content $flagPath -First 1 -ErrorAction SilentlyContinue; if ($c) { $c.Trim() } } else { $null }
                SourceSignature = if (Test-Path $sigPath) { $s = Get-Content $sigPath -First 1 -ErrorAction SilentlyContinue; if ($s) { $s.Trim() } } else { $null }
            }
        } -DisplayName "DSC: Detect modules and ensure staging directory."
        $guestZipHash = $result.ScriptBlockOutput.Hash
        $guestFlagExists = $result.ScriptBlockOutput.FlagExists
        $guestInstalledHash = $result.ScriptBlockOutput.InstalledHash
        $guestSourceSignature = $result.ScriptBlockOutput.SourceSignature

        $dscZipHash = (Get-FileHash -Path "$rootPath\DSC\DSC.zip" -Algorithm MD5).Hash

        # Signature of the ENTIRE DSC payload we copy, not just DSC.zip.
        # Copy-ItemSafe below ships the whole DSC folder -- DSC.zip PLUS the
        # loose phase scripts (phases\*.ps1, ScriptWorkflow.ps1, helper .ps1s,
        # etc.). The DSC.zip MD5 only fingerprints the compiled module archive
        # and does NOT change when a loose script is edited, so the zip hash
        # alone could not gate the copy -- which is why the old gate fell back
        # to "-not $alreadyCopiedDSC" and force-recopied the whole folder on the
        # first sight of every VM each run (the reported "recopies every re-run
        # even when the guest is up to date").
        #
        # Composite signature = DSC.zip content hash + newest loose-file write
        # time (UTC ticks) + loose-file count. It advances on ANY change to ANY
        # copied file (zip rebuild via content hash; loose-script edit via
        # mtime; loose-script add/delete via mtime+count) and stays identical
        # across re-runs when nothing changed. Both sides of the comparison are
        # host-generated values (the guest just stores whatever the host last
        # wrote), so there is no host/guest clock-skew concern.
        $dscSourceSignature = $dscZipHash
        try {
            $looseFiles = @(Get-ChildItem -Path "$rootPath\DSC" -File -Recurse -ErrorAction Stop | Where-Object { $_.Name -ne 'DSC.zip' })
            $looseCount = $looseFiles.Count
            $looseMaxTicks = 0
            if ($looseCount -gt 0) {
                $looseMaxTicks = ($looseFiles | ForEach-Object { $_.LastWriteTimeUtc.Ticks } | Measure-Object -Maximum).Maximum
            }
            $dscSourceSignature = "$dscZipHash`:$looseMaxTicks`:$looseCount"
        }
        catch {
            # If the host folder scan fails, fall back to the zip hash alone so
            # the gate still functions (it just loses loose-file-change detection).
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC source-signature scan failed: $($_.Exception.Message). Falling back to DSC.zip hash." -Warning
            $dscSourceSignature = $dscZipHash
        }

        # Copy when the guest's recorded signature differs from the host
        # signature (payload changed, or the VM has never been copied to), OR
        # the guest's DSC.zip hash drifted (defensive). $alreadyCopiedDSC short-
        # circuits the copy on subsequent phases within the SAME run -- the host
        # payload cannot change mid-run, so once we've copied (and stamped the
        # signature) there is nothing to re-evaluate. It no longer FORCES a copy.
        $signatureMatches = ($guestSourceSignature -eq $dscSourceSignature) -and ($guestZipHash -eq $dscZipHash)
        if (-not $alreadyCopiedDSC -and -not $signatureMatches) {

            # PS5.1 parse-check all guest scripts once per build (not per VM).
            # Guest VMs run PS 5.1 which reads non-BOM files as Windows-1252;
            # non-ASCII in string literals silently breaks dot-sourced scripts.
            if (-not $script:dscParseChecked) {
                $script:dscParseChecked = $true
                $dscPhasesDir = Join-Path $rootPath "DSC" "phases"
                $dscModuleDir = Join-Path $rootPath "DSC" "TemplateHelpDSC"
                $guestScripts = @()
                if (Test-Path $dscPhasesDir) { $guestScripts += Get-ChildItem -Path $dscPhasesDir -Filter '*.ps1' -Recurse }
                if (Test-Path $dscModuleDir) {
                    $guestScripts += Get-ChildItem -Path $dscModuleDir -Filter '*.ps1' -Recurse
                    $guestScripts += Get-ChildItem -Path $dscModuleDir -Filter '*.psm1' -Recurse
                }
                $parseFailures = @()
                foreach ($gs in $guestScripts) {
                    $bytes = [System.IO.File]::ReadAllBytes($gs.FullName)
                    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
                    if (-not $hasBom) {
                        # Check for non-ASCII bytes that PS5.1 would misinterpret
                        for ($bi = 0; $bi -lt $bytes.Length; $bi++) {
                            if ($bytes[$bi] -gt 127) {
                                $parseFailures += "$($gs.Name): non-ASCII byte 0x$($bytes[$bi].ToString('X2')) at offset $bi (no UTF-8 BOM)"
                                break
                            }
                        }
                    }
                }
                if ($parseFailures.Count -gt 0) {
                    foreach ($pf in $parseFailures) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC parse-check WARNING: $pf" -Warning
                    }
                }
            }

            # Copy DSC files
            Write-Progress2 $Activity -Status "Copying DSC files to the VM" -percentcomplete 35 -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying DSC files to the VM."

            $copyResults = $false

            # FAST PATH (optimization): deliver the DSC payload via a content-
            # addressed, read-only ISO mounted on the VM's DVD, then copy it off the
            # local DVD INSIDE the guest. This replaces the slow host->guest PSDirect
            # transfer (Copy-ItemSafe over the VMBus pipe -- minutes for the modules
            # zip plus many small loose scripts) with an instant mount + a fast local
            # disk copy. The ISO carries the SAME $rootPath\DSC folder Copy-ItemSafe
            # ships (DSC.zip + loose scripts), so the guest ends with an identical
            # C:\staging\DSC regardless of which path delivered it. Fully reversible:
            # any miss (Gen1 VM without a reusable DVD, build/mount/copy failure,
            # or the $env:MEMLABS_NO_DSC_ISO kill switch) falls through to the
            # legacy copy.
            if (-not $env:MEMLABS_NO_DSC_ISO) {
                try {
                    $dscVm = Get-VM -Name $currentItem.vmName -ErrorAction SilentlyContinue
                    if ($dscVm) {
                        $dscIso = Get-MemlabsDscIsoForPayload -RootPath $rootPath -Signature $dscSourceSignature
                        if ($dscIso -and (Mount-MemlabsDscIsoToVm -VmName $currentItem.vmName -IsoPath $dscIso)) {
                            Write-Progress2 $Activity -Status "Copying DSC files from mounted ISO" -percentcomplete 35 -force
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying DSC files from mounted ISO $([System.IO.Path]::GetFileName($dscIso))."
                            try {
                                $isoCopy = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                                    # Locate the MEMLABSDSC volume and copy its contents into C:\staging\DSC.
                                    $vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'MEMLABSDSC' -and $_.DriveLetter } | Select-Object -First 1
                                    if (-not $vol) { return [PSCustomObject]@{ Ok = $false; Reason = 'MEMLABSDSC volume not found' } }
                                    $src = "$($vol.DriveLetter):\"
                                    New-Item -Path "C:\staging\DSC" -ItemType Directory -Force | Out-Null
                                    try {
                                        Copy-Item -Path (Join-Path $src '*') -Destination "C:\staging\DSC" -Recurse -Force -ErrorAction Stop
                                        if (-not (Test-Path "C:\staging\DSC\DSC.zip")) { return [PSCustomObject]@{ Ok = $false; Reason = 'DSC.zip missing after copy' } }
                                        return [PSCustomObject]@{ Ok = $true; Reason = '' }
                                    }
                                    catch { return [PSCustomObject]@{ Ok = $false; Reason = $_.Exception.Message } }
                                } -DisplayName "DSC: Copy payload from mounted ISO"
                                if (-not $isoCopy.ScriptBlockFailed -and $isoCopy.ScriptBlockOutput -and $isoCopy.ScriptBlockOutput.Ok) {
                                    $copyResults = $true
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC payload delivered via ISO." -LogOnly
                                }
                                else {
                                    $reason = if ($isoCopy.ScriptBlockOutput) { $isoCopy.ScriptBlockOutput.Reason } else { 'in-guest copy failed' }
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC ISO in-guest copy did not complete ($reason); falling back to direct copy." -Warning
                                }
                            }
                            finally {
                                # Always eject our DSC ISO so the single DVD is free for the
                                # cache-ISO mount that follows (and any later SQL/CM/OS mount).
                                Dismount-MemlabsDscIsoFromVm -VmName $currentItem.vmName
                            }
                        }
                    }
                }
                catch {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC ISO delivery failed (non-fatal, will direct-copy): $($_.Exception.Message)" -Warning
                    try { Dismount-MemlabsDscIsoFromVm -VmName $currentItem.vmName } catch {}
                }
            }

            # LEGACY/FALLBACK PATH: host->guest PSDirect copy. Runs when the ISO path
            # was skipped or failed. Copy-ItemSafe has 3 internal retries (~12 min
            # worst case); DSC copy is critical, so retry up to 2 more times here.
            if (-not $copyResults) {
                for ($copyAttempt = 1; $copyAttempt -le 3; $copyAttempt++) {
                    if ($copyAttempt -gt 1) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Caller retry $($copyAttempt - 1)/2 after 30s delay..." -Warning
                        Start-Sleep -Seconds 30
                        Write-Progress2 $Activity -Status "Copying DSC files to the VM (retry $($copyAttempt - 1)/2)" -percentcomplete 36 -force
                    }
                    $copyResults = Copy-ItemSafe -VmName $currentItem.vmName -VMDomainName $domainName -Path "$rootPath\DSC" -Destination "C:\staging" -Recurse -Container -Force
                    if ($copyResults -ne $false) { break }
                }
            }
            if ($copyResults -eq $false) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy DSC files to the VM." -Failure -OutputStream
                return
            }

            # Stamp the host payload signature on the guest so a later re-run
            # whose DSC folder is unchanged skips this copy entirely. Written
            # only AFTER a confirmed-successful copy, so a partial/failed copy
            # never leaves a matching signature that would suppress the next copy.
            $sigResult = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ArgumentList $dscSourceSignature -ScriptBlock {
                param($sig)
                New-Item -Path "C:\staging\DSC" -ItemType Directory -Force | Out-Null
                $sig | Out-File "C:\staging\DSC\DSC.SourceSignature" -Force -Encoding ascii
            } -DisplayName "DSC: Record source signature on guest"
            if ($sigResult.ScriptBlockFailed) {
                # Non-fatal: the copy already succeeded. Without the stamp the
                # next run just recopies (the prior, safe default), so warn only.
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Could not write source-signature flag on guest; next run will recopy DSC files. $($sigResult.ScriptBlockOutput)" -Warning
            }
        }
        else {
            Write-Progress2 $Activity -Status "Skip copying DSC files to the VM." -percentcomplete 35 -force -Log
        }

        # Download cache: ensure the host has this deployment's small Tier-1
        # installers (SSMS, .NET, ODBC, OleDB, SQLClient, VCredist, ReportBuilder,
        # PMPC) baked into a content-addressed, read-only ISO and mount it on this
        # VM, so the guest's Invoke-DownloadFile serves them off the local DVD
        # instead of downloading over the slow internal NAT. Pure optimization:
        # fully gated ($env:MEMLABS_NO_DOWNLOAD_CACHE kill switch + needed-key
        # gating), with a guest-side fall-through to direct download on any miss.
        # Gen1/OSD VMs are skipped (the cache only targets Gen2 server VMs, whose
        # SCSI DVD can be hot-added while running). Build is once-per-content
        # (content-addressed ISO + mutex), so concurrent VMs/deploys are safe.
        try {
            if (Test-MemlabsDownloadCacheEnabled) {
                $cacheVm = Get-VM -Name $currentItem.vmName -ErrorAction SilentlyContinue
                if ($cacheVm -and $cacheVm.Generation -ne 1) {
                    $cacheIso = Get-MemlabsCacheIsoForDeploy -DeployConfig $deployConfig -StartPhase $Phase
                    if ($cacheIso -and (Mount-MemlabsCacheIsoToVm -VmName $currentItem.vmName -IsoPath $cacheIso)) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Mounted download cache $([System.IO.Path]::GetFileName($cacheIso))." -LogOnly
                    }
                }
            }
        }
        catch {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Download cache step failed (non-fatal): $($_.Exception.Message)" -LogOnly
        }

        # WSUS categories baseline cab. Ship to EVERY ConfigMgr SUP VM
        # (installSUP=true, not just top-of-hierarchy) so InstallRoles (Phase 8)
        # can run `wsusutil import` locally and pre-populate dbo.UpdateCategories
        # before CM's first categories sync. Without the local cab a
        # Primary-under-CAS SUP (or any downstream SUP) falls back to pulling the
        # full ~13K-entry taxonomy from its upstream source -- whether that's MU
        # or another WSUS -- which is the multi-hour path we want to avoid. The
        # import is idempotent: Start-WsusBaselineImportBackground short-circuits
        # with 'already-imported' once dbo.UpdateCategories is populated, so
        # re-running Phase <=7 on a healthy box is a fast no-op.
        # A PURE standalone WSUS (role=WSUS without installSUP) is deliberately
        # EXCLUDED: it has no InstallRoles/Phase-8 import path, so it always
        # populates its catalog via a natural Microsoft Update sync (Phase 7
        # WSUSSync) instead of the cab.
        # No-op when the cab is absent on host, the flag is off, the VM is
        # not a ConfigMgr SUP, or the guest already has a matching cab on disk.
        if ($Phase -le 7) {
            $cmoForCab = if ($currentItem.cmOptions) { $currentItem.cmOptions } else { $deployConfig.cmOptions }
            $cabEnabled = $true
            if ($cmoForCab -and $cmoForCab.PSObject.Properties['WsusImportBaseline'] -and $cmoForCab.WsusImportBaseline -eq $false) {
                $cabEnabled = $false
            }
            $isWsusVm = ($currentItem.installSUP -eq $true)
            $hostCabPath = Join-Path $Common.AzureFilesPath "tools\wsus\WsusCategoriesBaseline.cab"
            if ($cabEnabled -and $isWsusVm -and (Test-Path $hostCabPath)) {
                try {
                    # Staleness warning: cab >540 days old (based on host
                    # LastWriteTime -- when it was placed in this checkout).
                    # Replaces the old per-DSC-run sidecar-based age check.
                    try {
                        $cabAgeDays = [int](((Get-Date) - (Get-Item $hostCabPath).LastWriteTime).TotalDays)
                        if ($cabAgeDays -gt 540) {
                            Write-Log "[Phase $Phase]: WSUS baseline cab is $cabAgeDays days old (>540). Consider regenerating via baseimagestaging\New-WsusCategoriesBaseline.ps1." -Warning
                        }
                    } catch {}
                    $hostCabHash = (Get-FileHash -Path $hostCabPath -Algorithm MD5 -ErrorAction Stop).Hash
                    $guestProbe = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                        New-Item -Path 'C:\staging\wsus' -ItemType Directory -Force | Out-Null
                        (Get-FileHash -Path 'C:\staging\wsus\WsusCategoriesBaseline.cab' -Algorithm MD5 -ErrorAction SilentlyContinue).Hash
                    } -DisplayName "DSC: Detect existing WSUS baseline cab"
                    $guestHash = if ($guestProbe -and $guestProbe.ScriptBlockOutput) { $guestProbe.ScriptBlockOutput } else { $null }
                    if ($guestHash -ne $hostCabHash) {
                        $sizeMB = [math]::Round((Get-Item $hostCabPath).Length / 1MB, 1)
                        Write-Progress2 $Activity -Status "Copying WSUS categories baseline ($sizeMB MB)" -percentcomplete 38 -force
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying WSUS categories baseline cab ($sizeMB MB) to the VM."
                        $cabCopyOk = Copy-ItemSafe -VmName $currentItem.vmName -VMDomainName $domainName -Path $hostCabPath -Destination 'C:\staging\wsus' -Force
                        if ($cabCopyOk -eq $false) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): WSUS baseline cab copy failed; InstallRoles will skip wsusutil import and Phase 7 WSUSSync will fall back to a Microsoft Update sync." -Warning
                        }
                    }
                }
                catch {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): WSUS baseline cab pre-copy probe threw: $($_.Exception.Message). Skipping; InstallRoles will skip wsusutil import and Phase 7 WSUSSync will fall back to MU sync." -Warning
                }
            }
        }

        # Expand DSC.zip and install modules in one PSDirect round-trip
        $DSC_ExpandAndInstall = {
            try {
                $global:ScriptBlockName = "DSC_ExpandAndInstall"
                $currentItem = $using:currentItem
                $Phase = $using:Phase
                try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

                $log = "C:\staging\DSC\DSC_Init.log"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'

                # C:\staging\DSC must exist for the write to succeed; if a
                # prior phase's copy was interrupted the folder may be absent.
                # Create it (idempotent), then retry the initial write to
                # absorb a transient lock on DSC_Init.log (a tail/reader or a
                # previous run's handle not yet released). A persisted failure
                # still throws.
                $logDir = Split-Path -Path $log -Parent
                if (-not (Test-Path -LiteralPath $logDir)) {
                    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $writeOk = $false
                $writeErr = $null
                for ($writeAttempt = 1; $writeAttempt -le 5; $writeAttempt++) {
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force
                        $writeOk = $true
                        break
                    }
                    catch {
                        $writeErr = $_
                        Start-Sleep -Seconds 3
                    }
                }
                if (-not $writeOk) {
                    # The canonical DSC_Init.log is durably locked or unwritable.
                    # Don't abort the phase over a log write -- fall back to a
                    # timestamped alternate and continue. Every later write in
                    # this scriptblock uses $log, so re-pointing it keeps them
                    # flowing to the fallback file.
                    $fallbackLog = $log -replace "DSC_Init\.log", ("DSC_Init_" + (Get-Date).ToString("yyyyMMdd_HHmmss") + ".log")
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time (fallback; '$log' unwritable after 5 attempts: $writeErr)`r`n=====" | Out-File $fallbackLog -Append -Force -ErrorAction Stop
                    }
                    catch {
                        # Even the fallback could not be created; continue
                        # without a log rather than fail the DSC phase. Later
                        # Out-File calls are best-effort against this path.
                    }
                    $log = $fallbackLog
                }

                # Remove stale flag (idempotent)
                Remove-Item -Path "C:\staging\DSC\DSC.zip.Installed" -Force -ErrorAction SilentlyContinue

                # Expand archive
                $zipPath = "C:\staging\DSC\DSC.zip"
                $extractPath = "C:\staging\DSC\modules"

                if (Test-Path -PathType Container $extractPath) {
                    "$time : Removing existing folder $extractPath" | Out-File $log -Append
                    try {
                        Remove-Item -Force -Recurse $extractPath -ErrorAction Continue
                    }
                    catch {
                        "$time : Failed to Remove $extractPath" | Out-File $log -Append
                    }
                }

                "$time : Expanding $zipPath to $extractPath" | Out-File $log -Append
                try {
                    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
                }
                catch {
                    if (Test-Path $extractPath) {
                        Start-Sleep -Seconds 10
                        Remove-Item -Path $extractPath -Force -Recurse | Out-Null
                    }
                    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
                }

                # Install modules
                "Installing modules" | Out-File $log -Append
                $modules = Get-ChildItem -Path $extractPath -Directory

                # Kill WmiPrvSE hosting DSC modules up front so Remove-Item can
                # delete the old module files. On existing VMs that already ran
                # DSC, WmiPrvSE holds a lock on the .psm1 and Remove-Item with
                # SilentlyContinue silently fails, leaving stale module code.
                $dscHosts = Get-Process wmiprvse* -ErrorAction SilentlyContinue | Where-Object { $_.modules.ModuleName -like "*DSC*" }
                if ($dscHosts) {
                    "Killing $($dscHosts.Count) WmiPrvSE process(es) holding DSC modules before module install." | Out-File $log -Append
                    $dscHosts | Stop-Process -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 5
                }

                foreach ($folder in $modules) {
                    try {
                        $targetFolder = Join-Path "C:\Program Files\WindowsPowerShell\Modules" $folder.Name
                        "Removing $targetFolder in WindowsPowerShell\Modules." | Out-File $log -Append
                        Remove-Item -Recurse -Force $targetFolder -ErrorAction SilentlyContinue
                    }
                    catch {
                        "Failed to delete $targetFolder in WindowsPowerShell\Modules. Continuing" | Out-File $log -Append
                    }
                }

                foreach ($folder in $modules) {
                    try {
                        "Copying $($folder.FullName) to WindowsPowerShell\Modules." | Out-File $log -Append
                        Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force -ErrorAction Stop
                    }
                    catch {
                        "Failed to copy $($folder.Name) to WindowsPowerShell\Modules. Retrying once after killing WMIPRvSe.exe hosting DSC modules." | Out-File $log -Append
                        Get-Process wmiprvse* -ErrorAction SilentlyContinue | Where-Object { $_.modules.ModuleName -like "*DSC*" } | Stop-Process -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 10
                        Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force -ErrorAction Stop
                    }
                }

                # Verify installed modules match the extracted source.
                # Compare file count + total size per module — catches silent
                # copy failures (locked files, permission errors) that would
                # leave stale code. Cost: ~5ms per module (directory listing).
                $verifyFailures = @()
                foreach ($folder in $modules) {
                    $targetFolder = Join-Path "C:\Program Files\WindowsPowerShell\Modules" $folder.Name
                    if (-not (Test-Path $targetFolder)) {
                        $verifyFailures += "$($folder.Name): target folder missing"
                        continue
                    }
                    $srcFiles  = Get-ChildItem -Path $folder.FullName -File -Recurse
                    $destFiles = Get-ChildItem -Path $targetFolder -File -Recurse
                    if ($srcFiles.Count -ne $destFiles.Count) {
                        $verifyFailures += "$($folder.Name): file count mismatch (source=$($srcFiles.Count), installed=$($destFiles.Count))"
                    }
                    else {
                        $srcTotal  = ($srcFiles | Measure-Object -Property Length -Sum).Sum
                        $destTotal = ($destFiles | Measure-Object -Property Length -Sum).Sum
                        if ($srcTotal -ne $destTotal) {
                            $verifyFailures += "$($folder.Name): total size mismatch (source=$srcTotal, installed=$destTotal)"
                        }
                    }
                }
                if ($verifyFailures.Count -gt 0) {
                    foreach ($vf in $verifyFailures) { "VERIFY FAILED: $vf" | Out-File $log -Append }
                    throw "Module install verification failed: $($verifyFailures -join '; ')"
                }

                # Write the zip hash into the flag file so the host can verify
                # which version is installed without re-hashing on the guest.
                $installedHash = (Get-FileHash -Path $zipPath -Algorithm MD5).Hash
                $installedHash | Out-File "C:\staging\DSC\DSC.zip.Installed" -Force
                "Modules installed and verified. Hash: $installedHash" | Out-File $log -Append
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                try { $error_message | Out-File $log -Append } catch {}
                throw $error_message
            }
        }

        # Reinstall if: zip hash changed, flag missing, or flag hash doesn't
        # match the expected zip (catches stale installs from old empty-flag
        # format or partial installs that wrote the wrong hash).
        $needsInstall = ($dscZipHash -ne $guestZipHash) -or (-not $guestFlagExists) -or ($guestInstalledHash -ne $dscZipHash)
        if ($needsInstall) {
            Write-Progress2 $Activity -Status "Expanding and installing modules" -percentcomplete 40 -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Expanding and installing DSC modules inside the VM."
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ExpandAndInstall -DisplayName "DSC: Expand and Install Modules"
            if ($result.ScriptBlockFailed) {
                Start-Sleep -Seconds 15
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ExpandAndInstall -DisplayName "DSC: Expand and Install Modules"
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to expand and install DSC modules. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }
            }
        }
        else {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Skipped expanding and installing modules since DSC.zip is not newer."
        }

        # Create DSC troubleshooting shortcuts on Phase 2 (first DSC phase)
        if ($Phase -eq 2) {
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                try {
                    # Grant Users read access to DSC configuration folders
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        'BUILTIN\Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                    foreach ($folder in @(
                        'C:\Windows\System32\Configuration',
                        'C:\Windows\System32\Configuration\ConfigurationStatus'
                    )) {
                        if (Test-Path $folder) {
                            $acl = Get-Acl $folder
                            $acl.AddAccessRule($rule)
                            Set-Acl $folder $acl
                        }
                    }

                    $desktopPath = [Environment]::GetFolderPath('CommonDesktopDirectory')
                    $shell = New-Object -ComObject WScript.Shell

                    $linkPath = Join-Path $desktopPath 'Read DSC Log.lnk'
                    if (-not (Test-Path $linkPath)) {
                        $shortcut = $shell.CreateShortcut($linkPath)
                        $shortcut.TargetPath = 'powershell.exe'
                        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "C:\staging\DSC\Read-DSCLog.ps1"'
                        $shortcut.WorkingDirectory = 'C:\staging\DSC'
                        $shortcut.Save()
                    }

                    $linkPath2 = Join-Path $desktopPath 'DSC ConfigurationStatus.lnk'
                    if (-not (Test-Path $linkPath2)) {
                        $shortcut2 = $shell.CreateShortcut($linkPath2)
                        $shortcut2.TargetPath = 'C:\Windows\System32\Configuration\ConfigurationStatus'
                        $shortcut2.Save()
                    }
                } catch { }
            } -DisplayName "DSC: Create desktop shortcuts"
        }

        $DSC_ClearStatus = {
            param(
                [String]$DscFolder,
                [String]$RunGuid
            )

            try {
                $global:ScriptBlockName = "DSC_ClearStatus"
                try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $Phase = $using:Phase

                $log = "C:\staging\DSC\DSC_Init.log"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'

                # C:\staging\DSC must exist for the write to succeed; if a
                # prior phase's copy was interrupted the folder may be absent.
                # Create it (idempotent), then retry the initial write to
                # absorb a transient lock on DSC_Init.log (a tail/reader or a
                # previous run's handle not yet released). A persisted failure
                # still throws.
                $logDir = Split-Path -Path $log -Parent
                if (-not (Test-Path -LiteralPath $logDir)) {
                    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $writeOk = $false
                $writeErr = $null
                for ($writeAttempt = 1; $writeAttempt -le 5; $writeAttempt++) {
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force
                        $writeOk = $true
                        break
                    }
                    catch {
                        $writeErr = $_
                        Start-Sleep -Seconds 3
                    }
                }
                if (-not $writeOk) {
                    # The canonical DSC_Init.log is durably locked or unwritable.
                    # Don't abort the phase over a log write -- fall back to a
                    # timestamped alternate and continue. Every later write in
                    # this scriptblock uses $log, so re-pointing it keeps them
                    # flowing to the fallback file.
                    $fallbackLog = $log -replace "DSC_Init\.log", ("DSC_Init_" + (Get-Date).ToString("yyyyMMdd_HHmmss") + ".log")
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time (fallback; '$log' unwritable after 5 attempts: $writeErr)`r`n=====" | Out-File $fallbackLog -Append -Force -ErrorAction Stop
                    }
                    catch {
                        # Even the fallback could not be created; continue
                        # without a log rather than fail the DSC phase. Later
                        # Out-File calls are best-effort against this path.
                    }
                    $log = $fallbackLog
                }

                # Remove DSC_Status.txt EARLY, and only once DSC is confirmed
                # stopped. The DC's multi-node monitoring loop treats this
                # file's disappearance as the signal that this node has cleared
                # its previous status and is ready for the new config push. The
                # original removal sat near the end of this scriptblock, behind
                # several Rename-Item (-ErrorAction Stop) calls; if any of those
                # threw (locked file, etc.) the scriptblock aborted before the
                # removal and the DC dead-waited the full 150 attempts. Do it up
                # front so a later failure can't strand the orchestrator -- but
                # gate it on the LCM not being Busy so we never signal "ready"
                # while a configuration is still actively running on this node.
                $dscStatus = "C:\staging\DSC\DSC_Status.txt"
                $runGuidPath = "C:\staging\DSC\RunGuid.txt"
                # Stop_RunningDSC just finished a hard drain (kill WmiPrvSE +
                # purge on-disk MOFs + loop until LCM!=Busy or unreadable).
                # If LCM is STILL Busy here, something is genuinely stuck and
                # we must NOT silently fall through: the old 'Deferring' branch
                # deleted RunGuid.txt, returned success, and let the DC's
                # Check-Nodes-Ready loop dead-wait the full 150 attempts before
                # failing the phase. Throw immediately so the outer retry path
                # (which re-runs Stop_RunningDSC, and ultimately reboots the
                # VM if that fails too) takes over.
                #
                # Short 15s grace poll first to absorb the small race between
                # Stop_RunningDSC returning to PSDirect and this scriptblock
                # actually running -- a final state assertion can briefly tip
                # LCM back to Busy. Anything beyond 15s is a real stuck apply.
                $lcmStopped = $false
                $lcmState = 'Unknown'
                for ($wait = 0; $wait -lt 5; $wait++) {
                    try {
                        $lcmState = (Get-DscLocalConfigurationManager -ErrorAction Stop).LCMState
                        if ($lcmState -ne 'Busy') { $lcmStopped = $true; break }
                    }
                    catch {
                        # LCM unreadable: WmiPrvSE was just killed, no apply is
                        # running. Treat as stopped.
                        $lcmState = 'Unknown'
                        $lcmStopped = $true
                        break
                    }
                    "LCM is Busy (attempt $($wait + 1)/5); waiting 3s before recheck" | Out-File $log -Append -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                }
                if ($lcmStopped) {
                    if (Test-Path $dscStatus) {
                        "Removing $dscStatus (LCM='$lcmState')" | Out-File $log -Append -ErrorAction SilentlyContinue
                        Remove-Item -Path $dscStatus -Force -Confirm:$false -ErrorAction SilentlyContinue
                    }
                    # Ready signal: write this run's GUID to RunGuid.txt as the
                    # LAST step of clearing, ONLY after DSC is confirmed stopped
                    # and DSC_Status.txt is cleared. The DC's node-ready loop
                    # treats this node as ready iff RunGuid.txt == the current
                    # run's GUID. Because the token is unique per run, neither
                    # stale prior-run state nor a self-recovery that later
                    # re-creates DSC_Status.txt can produce a false "ready".
                    if ($RunGuid) {
                        "Writing ready token to $runGuidPath (RunGuid=$RunGuid)" | Out-File $log -Append -ErrorAction SilentlyContinue
                        Set-Content -Path $runGuidPath -Value $RunGuid -Force -Encoding ASCII -ErrorAction SilentlyContinue
                    }
                }
                else {
                    # LCM still Busy after Stop_RunningDSC + 15s drain wait.
                    # Delete any stale RunGuid.txt and fail loudly so the outer
                    # retry path can re-run Stop_RunningDSC (and reboot the VM
                    # if needed) instead of letting the DC dead-wait.
                    "LCM still Busy after 15s drain wait; throwing to trigger outer retry" | Out-File $log -Append -ErrorAction SilentlyContinue
                    Remove-Item -Path $runGuidPath -Force -Confirm:$false -ErrorAction SilentlyContinue
                    throw "DSC_ClearStatus: LCMState='Busy' after Stop_RunningDSC drain + 15s wait. Cannot safely clear status (would strand DC handshake). Outer retry will re-run Stop_RunningDSC or reboot the VM."
                }

                # Rename the DSC_Events.json file, if it exists for DSC re-run
                $jsonPath = Join-Path "C:\staging\DSC" "DSC_Events.json"
                if (Test-Path $jsonPath) {
                    $newName = $jsonPath -replace ".json", ((get-date).ToString("_yyyyMMdd_HHmmss") + ".json")
                    "Renaming $jsonPath to $newName" | Out-File $log -Append
                    Rename-Item -Path $jsonPath -NewName $newName -Force -Confirm:$false -ErrorAction Stop
                }

                # For re-run, mark ScriptWorkflow not started
                $ConfigurationFile = Join-Path -Path "C:\staging\DSC" -ChildPath "ScriptWorkflow.json"
                if (Test-Path $ConfigurationFile) {
                    "Resetting $ConfigurationFile" | Out-File $log -Append
                    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
                    if ($Configuration.ScriptWorkflow) {
                        $Configuration.ScriptWorkflow.Status = 'NotStart'
                        $Configuration.ScriptWorkflow.StartTime = ''
                        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
                    }
                    else {
                        Remove-Item $ConfigurationFile -Force -Confirm:$false -ErrorAction Stop
                    }
                }

                # Rename the DSC_Log that controls execution flow of DSC Logging and completion event before each run
                $dscLog = "C:\staging\DSC\DSC_Log.log"
                if (Test-Path $dscLog) {
                    $newName = $dscLog -replace "Log.log", ((get-date).ToString("_yyyyMMdd_HHmmss") + ".log")
                    "Renaming $dscLog to $newName" | Out-File $log -Append
                    Rename-Item -Path $dscLog -NewName $newName -Force -Confirm:$false -ErrorAction Stop
                }
                $dscLogOld = "C:\staging\DSC\DSC_Log.txt"
                if (Test-Path $dscLogOld) {
                    Remove-Item $dscLog -Force -Confirm:$false -ErrorAction SilentlyContinue                    
                }

                # Rename previous MOF path
                $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"
                if (Test-Path $dscConfigPath) {
                    $newName = $dscConfigPath -replace "DSCConfiguration", ("DSCConfiguration" + (get-date).ToString("_yyyyMMdd_HHmmss"))
                    "Renaming $dscConfigPath to $newName" | Out-File $log -Append
                    Rename-Item -Path $dscConfigPath -NewName $newName -Force -Confirm:$false -ErrorAction Stop
                }

                $SccmLogFilePath = "C:\ConfigMgrSetup.log"
                if (Test-Path $SccmLogFilePath) {
                    $newName = $SccmLogFilePath -replace "ConfigMgrSetup", ("ConfigMgrSetup" + (get-date).ToString("_yyyyMMdd_HHmmss"))
                    "Renaming $SccmLogFilePath to $newName" | Out-File $log -Append
                    Rename-Item -Path $SccmLogFilePath -NewName $newName -Force -Confirm:$false -ErrorAction Stop
                }


                # DSC_Status.txt is removed early (and LCM-gated) near the top
                # of this scriptblock so a rename failure above cannot strand
                # the DC's multi-node monitoring loop.

                # Write config to file
                $deployConfig = $using:deployConfig
                $deployConfigPath = "C:\staging\DSC\deployConfig.json"

                "Writing DSC config to $deployConfigPath" | Out-File $log -Append
                if (Test-Path $deployConfigPath) {
                    $newName = $deployConfigPath -replace ".json", ((get-date).ToString("_yyyyMMdd_HHmmss") + ".json")
                    "Renaming $deployConfigPath to $newName" | Out-File $log -Append
                    Rename-Item -Path $deployConfigPath -NewName $newName -Force -Confirm:$false -ErrorAction Stop
                }
                $deployConfig | ConvertTo-Json -Depth 5 | Out-File $deployConfigPath -Force -Confirm:$false
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                try {
                    $error_message | Out-File $log -Append -ErrorAction SilentlyContinue
                }
                catch {
                }
                Write-Error $error_message
                throw $error_message
                return $error_message
            }

            # Do some cleanup after we re-worked folder structure
            try {
                Remove-Item -Path "C:\staging\DSC\configmgr" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path "C:\staging\DSC\createGuestDscZip.ps1" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path "C:\staging\DSC\DummyConfig.ps1" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
            }
        }

        Write-Progress2 $Activity -Status "Clearing DSC Status" -percentcomplete 65 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName):DSC_ClearStatus Clearing previous DSC status"
        $result = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ClearStatus -ArgumentList $DscFolder, $phaseRunGuid -DisplayName "DSC: Clear Old Status"
        if ($result.ScriptBlockFailed) {
            # DSC_ClearStatus now throws when LCM is still Busy after its 15s
            # drain wait. The most common cause is a transient post-stop state
            # that didn't settle in time -- re-running Stop_RunningDSC's full
            # kill+purge+drain cycle usually clears it. If it still fails after
            # a fresh Stop_RunningDSC, escalate to a VM reboot (the guaranteed
            # way to clear an in-memory LCM apply).
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Clear Old Status failed (likely LCM=Busy); re-running Stop_RunningDSC before retry. $($result.ScriptBlockOutput)" -Warning
            $stopRetry = Invoke-VmCommand -AsJob -TimeoutSeconds $stopTimeout -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's (retry)"
            $stopRetryFailed = $stopRetry.ScriptBlockFailed -or ($stopRetry.ScriptBlockOutput -and ($stopRetry.ScriptBlockOutput.Stopped -eq $false))
            if ($stopRetryFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Stop_RunningDSC retry also failed; rebooting VM to clear the LCM." -Warning
                Stop-Vm2 -Name $currentItem.vmName
                Start-Sleep -Seconds 10
                Start-VM2 -Name $currentItem.vmName
                Wait-ForHeartbeat -VmName $currentItem.vmName | Out-Null
                # After a reboot the LCM is fresh; one more Stop_RunningDSC to
                # also clear PendingConfiguration if the doc auto-loaded.
                Invoke-VmCommand -AsJob -TimeoutSeconds $stopTimeout -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's (post-reboot)" | Out-Null
            }
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ClearStatus -ArgumentList $DscFolder, $phaseRunGuid -DisplayName "DSC: Clear Old Status"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to clear old status after Stop_RunningDSC retry / reboot. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
            }
        }

        $DSC_CreateSingleConfig = {
            param($DscFolder)

            try {
                $global:ScriptBlockName = "DSC_CreateSingleConfig"
                try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $deployConfig = $using:deployConfig
                $ConfigurationData = $using:ConfigurationData
                $adminCreds = $using:Common.LocalAdmin
                $Phase = $using:Phase

                $dscRole = "Phase$Phase"

                # Set current role
                switch (($currentItem.role)) {
                    "DC" { $dscRole += "DC" }
                    "OtherDC" { $dscRole += "OtherDC" }
                    "BDC" { $dscRole += "BDC" }
                    "WorkgroupMember" { $dscRole += "WorkgroupMember" }
                    "AADClient" { $dscRole += "WorkgroupMember" }
                    "InternetClient" { $dscRole += "WorkgroupMember" }
                    "StandaloneRootCA" { $dscRole += "WorkgroupMember" }
                    default { $dscRole += "DomainMember" }
                }

                # Define DSC variables
                $dscConfigScript = "C:\staging\DSC\$DscFolder\$($dscRole).ps1"
                $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"
                $deployConfigPath = "C:\staging\DSC\deployConfig.json"

                # Update init log
                $log = "C:\staging\DSC\DSC_Init.log"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'

                # C:\staging\DSC must exist for the write to succeed; if a
                # prior phase's copy was interrupted the folder may be absent.
                # Create it (idempotent), then retry the initial write to
                # absorb a transient lock on DSC_Init.log (a tail/reader or a
                # previous run's handle not yet released). A persisted failure
                # still throws.
                $logDir = Split-Path -Path $log -Parent
                if (-not (Test-Path -LiteralPath $logDir)) {
                    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $writeOk = $false
                $writeErr = $null
                for ($writeAttempt = 1; $writeAttempt -le 5; $writeAttempt++) {
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force
                        $writeOk = $true
                        break
                    }
                    catch {
                        $writeErr = $_
                        Start-Sleep -Seconds 3
                    }
                }
                if (-not $writeOk) {
                    # The canonical DSC_Init.log is durably locked or unwritable.
                    # Don't abort the phase over a log write -- fall back to a
                    # timestamped alternate and continue. Every later write in
                    # this scriptblock uses $log, so re-pointing it keeps them
                    # flowing to the fallback file.
                    $fallbackLog = $log -replace "DSC_Init\.log", ("DSC_Init_" + (Get-Date).ToString("yyyyMMdd_HHmmss") + ".log")
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time (fallback; '$log' unwritable after 5 attempts: $writeErr)`r`n=====" | Out-File $fallbackLog -Append -Force -ErrorAction Stop
                    }
                    catch {
                        # Even the fallback could not be created; continue
                        # without a log rather than fail the DSC phase. Later
                        # Out-File calls are best-effort against this path.
                    }
                    $log = $fallbackLog
                }
                "Running as $env:USERDOMAIN\$env:USERNAME`r`n" | Out-File $log -Append
                "Current Item = $currentItem" | Out-File $log -Append
                "Role Name = $dscRole" | Out-File $log -Append
                "Config Script = $dscConfigScript" | Out-File $log -Append
                "Config Path = $dscConfigPath" | Out-File $log -Append

                if (-not $deployConfig.vmOptions.domainName) {
                    $error_message = "Could not get domainName name from deployConfig"
                    $error_message | Out-File $log -Append
                    Write-Error $error_message
                    return $error_message
                }

                $env:PSModulePath = "C:\Program Files\WindowsPowerShell\Modules;C:\Windows\system32\WindowsPowerShell\v1.0\Modules"

                # Dot Source config script
                . "$dscConfigScript"

                # Configuration Data
                $cd = @{
                    AllNodes = @(
                        @{
                            NodeName                    = 'LOCALHOST'
                            PSDscAllowDomainUser        = $true
                            PSDscAllowPlainTextPassword = $true
                        }
                    )
                }

                if (-not $adminCreds) {
                    $error_message = "Failed to get local admin credentials for DSC."
                    $error_message | Out-File $log -Append
                    Write-Error $error_message
                    return $error_message
                }

                # Compile config, to create MOF
                "[Phase $Phase]: $($currentItem.vmName): Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append                
                & "$($dscRole)" -DeployConfigPath $deployConfigPath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath $dscConfigPath
                "[Phase $Phase]: $($currentItem.vmName): Done Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                try {
                    $error_message | Out-File $log -Append
                }
                catch {}
                Write-Error $error_message
                throw $error_message
                return $error_message
            }
        }

        $DSC_CreateMultiConfig = {
            param($DscFolder)
            try {
                $global:ScriptBlockName = "DSC_CreateMultiConfig"
                try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $deployConfig = $using:deployConfig
                $ConfigurationData = $using:ConfigurationData
                $adminCreds = $using:Common.LocalAdmin
                $Phase = $using:Phase
                $dscRole = "Phase$Phase"


                switch (($currentItem.role)) {
                    "OtherDC" { return }
                }

                # Define DSC variables
                $dscConfigScript = "C:\staging\DSC\$DscFolder\$($dscRole).ps1"
                $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"
                $deployConfigPath = "C:\staging\DSC\deployConfig.json"

                # Update init log
                $log = "C:\staging\DSC\DSC_Init.log"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'

                # C:\staging\DSC must exist for the write to succeed; if a
                # prior phase's copy was interrupted the folder may be absent.
                # Create it (idempotent), then retry the initial write to
                # absorb a transient lock on DSC_Init.log (a tail/reader or a
                # previous run's handle not yet released). A persisted failure
                # still throws.
                $logDir = Split-Path -Path $log -Parent
                if (-not (Test-Path -LiteralPath $logDir)) {
                    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $writeOk = $false
                $writeErr = $null
                for ($writeAttempt = 1; $writeAttempt -le 5; $writeAttempt++) {
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force
                        $writeOk = $true
                        break
                    }
                    catch {
                        $writeErr = $_
                        Start-Sleep -Seconds 3
                    }
                }
                if (-not $writeOk) {
                    # The canonical DSC_Init.log is durably locked or unwritable.
                    # Don't abort the phase over a log write -- fall back to a
                    # timestamped alternate and continue. Every later write in
                    # this scriptblock uses $log, so re-pointing it keeps them
                    # flowing to the fallback file.
                    $fallbackLog = $log -replace "DSC_Init\.log", ("DSC_Init_" + (Get-Date).ToString("yyyyMMdd_HHmmss") + ".log")
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time (fallback; '$log' unwritable after 5 attempts: $writeErr)`r`n=====" | Out-File $fallbackLog -Append -Force -ErrorAction Stop
                    }
                    catch {
                        # Even the fallback could not be created; continue
                        # without a log rather than fail the DSC phase. Later
                        # Out-File calls are best-effort against this path.
                    }
                    $log = $fallbackLog
                }
                "Running as $env:USERDOMAIN\$env:USERNAME`r`n" | Out-File $log -Append
                "Current Item = $currentItem" | Out-File $log -Append
                "Role Name = $dscRole" | Out-File $log -Append
                "Config Script = $dscConfigScript" | Out-File $log -Append
                "Config Path = $dscConfigPath" | Out-File $log -Append

                if (-not $ConfigurationData) {
                    $error_message = "No Configuration data was supplied."
                    $error_message | Out-File $log -Append
                    Write-Error $error_message
                    return $error_message
                }

                if (-not $deployConfig.vmOptions.domainName) {
                    $error_message = "Could not get domainName name from deployConfig"
                    $error_message | Out-File $log -Append
                    Write-Error $error_message
                    return $error_message
                }

                # Dot Source config script
                $env:PSModulePath = "C:\Program Files\WindowsPowerShell\Modules;C:\Windows\system32\WindowsPowerShell\v1.0\Modules"
                . "$dscConfigScript"

                # Configuration Data
                $cd = @{
                    AllNodes = @()
                }

                foreach ($node in $ConfigurationData.AllNodes | where-object { $_ }) {
                    #foreach ($node in $ConfigurationData.AllNodes) {
                    $cd.AllNodes += $node
                }

                # Add locale settings to Configuration Data
                # Default is en-US and may not be used
                $cd.LocaleSettings = @{ LanguageTag = "en-US" }
                $locale = $deployConfig.vmOptions.locale
                if ($locale -and $locale -ne "en-US") {
                    $localeConfigPath = "C:\staging\locale\_localeConfig.json"
                    $localeConfig = Get-Content -Path $localeConfigPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

                    # Picking up current locale
                    $l = @{
                        LanguageTag          = $locale

                        # These are used for LanguageDsc
                        LocationID           = $localeConfig.$locale.LocationID
                        MUILanguage          = $localeConfig.$locale.MUILanguage
                        MUIFallbackLanguage  = $localeConfig.$locale.MUIFallbackLanguage
                        SystemLocale         = $localeConfig.$locale.SystemLocale
                        AddInputLanguages    = $localeConfig.$locale.AddInputLanguages
                        RemoveInputLanguages = $localeConfig.$locale.RemoveInputLanguages
                        UserLocale           = $localeConfig.$locale.UserLocale
                        # This is used for SSMS (TBD)
                        LanguageID           = $localeConfig.$locale.LanguageID
                    }
                    $cd.LocaleSettings = $l
                }

                # Dump $cd, in case we need to review
                $cd | ConvertTo-Json -Depth 5 | Out-File "C:\staging\DSC\Phase$($Phase)_CD.json" -Force -Confirm:$false

                # Create domain creds
                #$netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
                $netbiosName = $deployConfig.vmOptions.domainNetBiosName
                $user = "$netBiosName\$($using:Common.LocalAdmin.UserName)"
                $domainCreds = New-Object System.Management.Automation.PSCredential ($user, $using:Common.LocalAdmin.Password)

                # Use localAdmin creds for Phase 1, domainCreds after that
                $credsForDSC = $adminCreds
                if ($Phase -gt 1) {
                    $credsForDSC = $domainCreds
                }

                if (-not $credsForDSC) {
                    $error_message = "Failed to create credentials for DSC."
                    $error_message | Out-File $log -Append
                    Write-Error $error_message
                    return $error_message
                }

                # Compile config, to create MOF
                $cd
                "[Phase $Phase]: $($currentItem.vmName): Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append
                & "$($dscRole)" -DeployConfigPath $deployConfigPath -AdminCreds $credsForDSC -ConfigurationData $cd -OutputPath $dscConfigPath
                "[Phase $Phase]: $($currentItem.vmName): Done Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                try { $error_message | Out-File $log -Append } 
                catch {}
                Write-Error $error_message
                throw $error_message
                return $error_message
            }
        }

        $DSC_StartConfig = {
            param($DscFolder)
            try {
                $global:ScriptBlockName = "DSC_StartConfig"

                # When Start-DscConfiguration fails, the generic wrapper string
                # we return to the host ("Could not run Start-DscConfiguration...")
                # hides the real cause. The authoritative detail -- which resource
                # failed and its exception -- lives in the LCM ConfigurationStatus
                # record and the operational event log on this guest. Mine them so
                # the failing resource + error travels back to the host build log
                # instead of forcing a manual in-guest dig.
                function Get-DscFailureDetail {
                    param($ErrorRecord)
                    $detail = New-Object System.Collections.Generic.List[string]
                    if ($ErrorRecord) {
                        $msg = $null
                        try { $msg = $ErrorRecord.Exception.Message } catch {}
                        if (-not [string]::IsNullOrWhiteSpace($msg)) {
                            $detail.Add("Error: " + ($msg -replace '\s+', ' ').Trim())
                        }
                    }
                    # Authoritative: every resource the last apply left not-in-state, with its own error text.
                    try {
                        $status = Get-DscConfigurationStatus -ErrorAction Stop
                        if ($status -and $status.ResourcesNotInDesiredState) {
                            foreach ($r in $status.ResourcesNotInDesiredState) {
                                $rerr = $r.Error
                                if ([string]::IsNullOrWhiteSpace($rerr)) { $rerr = '(no error text)' }
                                $detail.Add("Failed resource " + $r.ResourceId + ": " + ($rerr -replace '\s+', ' ').Trim())
                            }
                        }
                    }
                    catch {
                        # Get-DscConfigurationStatus refuses while the LCM is mid-apply; fall back to the event log.
                        try {
                            $evts = Get-WinEvent -LogName 'Microsoft-Windows-DSC/Operational' -MaxEvents 40 -ErrorAction Stop |
                                Where-Object { $_.LevelDisplayName -eq 'Error' } | Select-Object -First 3
                            foreach ($e in $evts) {
                                $em = ($e.Message -replace '\s+', ' ').Trim()
                                if ($em.Length -gt 300) { $em = $em.Substring(0, 300) }
                                $detail.Add("DSC error event: " + $em)
                            }
                        }
                        catch {}
                    }
                    if ($detail.Count -gt 0) { return ($detail -join ' || ') }
                    return $null
                }
                #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $ConfigurationData = $using:ConfigurationData
                $Phase = $using:Phase

                # Define DSC variables
                $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"
                # Update init log
                $log = "C:\staging\DSC\DSC_Init.log"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'

                # C:\staging\DSC must exist for the write to succeed; if a
                # prior phase's copy was interrupted the folder may be absent.
                # Create it (idempotent), then retry the initial write to
                # absorb a transient lock on DSC_Init.log (a tail/reader or a
                # previous run's handle not yet released). A persisted failure
                # still throws.
                $logDir = Split-Path -Path $log -Parent
                if (-not (Test-Path -LiteralPath $logDir)) {
                    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $writeOk = $false
                $writeErr = $null
                for ($writeAttempt = 1; $writeAttempt -le 5; $writeAttempt++) {
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force
                        $writeOk = $true
                        break
                    }
                    catch {
                        $writeErr = $_
                        Start-Sleep -Seconds 3
                    }
                }
                if (-not $writeOk) {
                    # The canonical DSC_Init.log is durably locked or unwritable.
                    # Don't abort the phase over a log write -- fall back to a
                    # timestamped alternate and continue. Every later write in
                    # this scriptblock uses $log, so re-pointing it keeps them
                    # flowing to the fallback file.
                    $fallbackLog = $log -replace "DSC_Init\.log", ("DSC_Init_" + (Get-Date).ToString("yyyyMMdd_HHmmss") + ".log")
                    try {
                        "`r`n=====`r`n$($global:ScriptBlockName): Started at $time (fallback; '$log' unwritable after 5 attempts: $writeErr)`r`n=====" | Out-File $fallbackLog -Append -Force -ErrorAction Stop
                    }
                    catch {
                        # Even the fallback could not be created; continue
                        # without a log rather than fail the DSC phase. Later
                        # Out-File calls are best-effort against this path.
                    }
                    $log = $fallbackLog
                }


                if (-not (Test-Path $dscConfigPath)) {
                    $data = "Could not find path $dscConfigPath"
                    $data | Out-File $log -Append                    
                    Write-Error $data
                    return $data
                }
                else {
                    "Found DSC Configuration in $dscConfigPath" | Out-File $log -Append  
                }



                # Run for single-node DSC, multi-node DSC fail with Set-DscLocalConfigurationManager
                if ($ConfigurationData.AllNodes.NodeName -contains "LOCALHOST") {
                    try {
                        "Set-DscLocalConfigurationManager for $dscConfigPath" | Out-File $log -Append
                        Set-DscLocalConfigurationManager -Path $dscConfigPath -Verbose -force
                    }
                    catch {
                        $data = "Could not run Set-DscLocalConfigurationManager -Path $dscConfigPath -Verbose -force"
                        $data | Out-File $log -Append      
                        $_ | Out-File $log -Append              
                        Write-Error $data
                        Write-Error $_
                        return $data
                    }

                    try {
                        "Start-DscConfiguration for $dscConfigPath" | Out-File $log -Append
                        Start-DscConfiguration -Wait -Path $dscConfigPath -Force -Verbose -ErrorAction Stop
                    }
                    catch {
                        $data = "Could not run Start-DscConfiguration -Wait -Path $dscConfigPath -Force -Verbose -ErrorAction Stop"
                        $data | Out-File $log -Append      
                        $_ | Out-File $log -Append              
                        $dscDetail = Get-DscFailureDetail -ErrorRecord $_
                        if ($dscDetail) {
                            $dscDetail | Out-File $log -Append
                            $data = "$data | $dscDetail"
                        }
                        Write-Error $data
                        Write-Error $_
                        return $data
                    }
                }
                else {
                    # Use domainCreds instead of local Creds for multi-node DSC
                    #$userdomain = $deployConfig.vmOptions.domainName.Split(".")[0]
                    $userdomain = $deployConfig.vmOptions.domainNetBiosName

                    if ($phase -eq 9) {
                        $RemoteSiteServer = $deployConfig.VirtualMachines | Where-Object { $_.Hidden -and $_.Role -eq "Primary" -and $_.Domain }
                        "Phase 9 Remote Site Server $($RemoteSiteServer.vmName) $($RemoteSiteServer.Domain)" | Out-File $log -Append
                        if ($RemoteSiteServer) {
                            $userdomain = $RemoteSiteServer.Domain
                        }
                    }
                    $user = "$userdomain\$($using:Common.LocalAdmin.UserName)"
                    $creds = New-Object System.Management.Automation.PSCredential ($user, $using:Common.LocalAdmin.Password)
                    get-job  | Stop-Job | out-null
                    get-job  | Remove-Job | out-null

                    # Pre-flight: verify WinRM connectivity to each target node.
                    # Start-DscConfiguration pushes MOFs via CIM/WinRM. If a node
                    # is unreachable, the push silently fails for that node. Test
                    # each one upfront so failures are logged with diagnostics.
                    $mofFiles = Get-ChildItem -Path $dscConfigPath -Filter '*.mof' -ErrorAction SilentlyContinue |
                        Where-Object { $_.BaseName -ne $env:COMPUTERNAME }
                    $unreachable = @()
                    foreach ($mof in $mofFiles) {
                        $targetNode = $mof.BaseName
                        $wsmanOk = $false
                        try {
                            $ws = Test-WSMan -ComputerName $targetNode -Credential $creds -Authentication Default -ErrorAction Stop
                            if ($ws) { $wsmanOk = $true }
                        } catch {}

                        if ($wsmanOk) {
                            "  WinRM pre-check: $targetNode OK" | Out-File $log -Append
                        } else {
                            "  WinRM pre-check: $targetNode UNREACHABLE" | Out-File $log -Append
                            $unreachable += $targetNode
                            # Attempt remediation: enable WinRM via WMI (out-of-band)
                            try {
                                $wmiFix = Invoke-WmiMethod -ComputerName $targetNode -Credential $creds `
                                    -Class Win32_Process -Name Create `
                                    -ArgumentList 'powershell.exe -NoProfile -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck; Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -Enabled True -ErrorAction SilentlyContinue"' `
                                    -ErrorAction Stop
                                "  WinRM remediation via WMI on ${targetNode}: ReturnValue=$($wmiFix.ReturnValue)" | Out-File $log -Append
                                Start-Sleep -Seconds 5
                            } catch {
                                "  WinRM remediation via WMI on ${targetNode}: FAILED $_" | Out-File $log -Append
                            }
                        }
                    }
                    if ($unreachable.Count -gt 0) {
                        "WARNING: $($unreachable.Count) node(s) unreachable via WinRM: $($unreachable -join ', ')" | Out-File $log -Append
                    }

                    "Start-DscConfiguration for $dscConfigPath with $user credentials" | Out-File $log -Append
                    $null = Start-DscConfiguration -Path $dscConfigPath -Force -Verbose -ErrorAction Stop -Credential $creds -JobName $currentItem.vmName

                    # A healthy push stays Running for the whole apply, so Wait-Job -Timeout 30
                    # always burned its full timeout. Poll instead: leave as soon as every child
                    # job is off NotStarted and the push has held Running for a short settle
                    # window (long enough to still catch an immediate WinRM/CIM failure), and
                    # keep Wait-Job's contract of returning the job only on a terminal state.
                    $startSettleSeconds = 5
                    $startWaitSeconds = 30
                    $wait = $null
                    $startWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($startWatch.Elapsed.TotalSeconds -lt $startWaitSeconds) {
                        $probe = Get-Job -Name $currentItem.vmName -ErrorAction SilentlyContinue
                        if (-not $probe) { break }
                        if ($probe.State -ne 'Running' -and $probe.State -ne 'NotStarted') { $wait = $probe; break }
                        if ($probe.State -eq 'Running' -and $startWatch.Elapsed.TotalSeconds -ge $startSettleSeconds) {
                            $notStarted = @($probe.ChildJobs | Where-Object { $_.State -eq 'NotStarted' })
                            if ($notStarted.Count -eq 0) { break }
                        }
                        Start-Sleep -Seconds 1
                    }
                    $startWatch.Stop()
                    $job = get-job -name $currentItem.vmName
                    "Job.State $($job.State) after $([math]::Round($startWatch.Elapsed.TotalSeconds,1))s" | Out-File $log -Append

                    # Log per-node child job status for diagnostics.
                    # Even when the overall job is Running, individual
                    # node pushes may have already failed (WinRM timeout,
                    # CIM session error, etc.) - capture that early.
                    foreach ($cj in $job.ChildJobs) {
                        $cjMsg = "  ChildJob $($cj.Location): $($cj.State)"
                        if ($cj.Error.Count -gt 0) {
                            $cjMsg += " | Errors: $(($cj.Error | ForEach-Object { $_.ToString() }) -join '; ')"
                        }
                        $cjMsg | Out-File $log -Append
                    }

                    # If the job never reached Running, or already finished, log an error
                    if ($job.State -ne "Running") {
                        "Job detail: Name=$($job.Name) State=$($job.State) HasErrors=$($job.HasMoreData)" | Out-File $log -Append
                        $data = Receive-Job -name $currentItem.vmName 2>&1
                        $dataStr = ($data | Out-String).Trim()
                        if ($wait.State -eq "Completed") {
                            "Receive-Job output: $dataStr" | Out-File $log -Append
                        }
                        else {
                            "Receive-Job output (job not running): $dataStr" | Out-File $log -Append
                            $childErrors = ($job.ChildJobs | ForEach-Object { $_.Error } | Out-String).Trim()
                            if ($childErrors) { "ChildJob errors: $childErrors" | Out-File $log -Append }
                            $errMsg = if ($dataStr) { $dataStr } elseif ($childErrors) { $childErrors } else { "Job State: $($job.State), no output" }
                            Write-Error $errMsg
                            return $errMsg
                        }
                    }

                }
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                try {
                    $error_message | Out-File $log -Append
                }
                catch {}
                if ($error_message -is [String]) {
                    Write-Error $error_message
                }
                throw $error_message
                return $error_message
            }
        }

        $DSC_CreateConfig = $DSC_CreateSingleConfig
        if ($multiNodeDsc) {
            $DSC_CreateConfig = $DSC_CreateMultiConfig
        }

        # Phase 5 SQLAO DNS preflight (deadlock-breaker for already-poisoned nodes).
        # A SQLAO node stranded by a PRIOR run's DNS scrub (domain NIC registration
        # disabled -> no A record on the DC) can't be reached by the DC's DSC push,
        # which then dead-waits ("No DSC status after 3 min"). The post-complete
        # scrubDns self-heal can't rescue it because it only runs AFTER Phase 5
        # succeeds -- which can't happen while the node is unresolvable. Break that
        # deadlock here, BEFORE the push: cheaply check (host-side, against the DC)
        # whether the node's own A record is correctly published; only when it's
        # missing/wrong/VIP-polluted do we invoke the in-guest SkipAsSource-aware
        # re-register. No-op (single DC DNS query) on healthy/fresh nodes.
        if ($currentItem.role -eq 'SQLAO' -and $skipStartDsc) {
            $pfFqdn = "$($currentItem.vmName).$($deployConfig.vmOptions.domainName)"
            $pfOwnIp = $currentItem.AssignedIP
            if (-not $pfOwnIp) { $pfOwnIp = $currentItem.LastKnownIP }
            $pfVips = @()
            foreach ($vp in @('ClusterIPAddress', 'AGIPAddress')) {
                if ($currentItem.$vp) { $pfVips += ($currentItem.$vp -replace '/\d+$', '') }
            }
            # Ask the DC VM where it actually is. vmOptions.network is the network of the
            # VMs in THIS config, which on an add-to-existing-domain deploy is a DIFFERENT
            # subnet from the DC's -- pstest3 ran vmOptions.network=192.168.131.0 for the new
            # secondary while the DC and both SQLAO nodes live on 192.168.130.x. Deriving .1
            # from it aimed every query at a DNS server that does not exist, so the probe came
            # back empty and declared "not published" on every phase.
            $pfDcVm = $deployConfig.virtualMachines | Where-Object { $_.Role -eq 'DC' } | Select-Object -First 1
            $pfDcVmName = $pfDcVm.vmName
            $pfDcIp = $pfDcVm.AssignedIP
            if (-not $pfDcIp) { $pfDcIp = $pfDcVm.LastKnownIP }
            if (-not $pfDcIp) { $pfDcIp = ($deployConfig.vmOptions.network -replace '\.\d+$', '.1') }
            $needsDnsFix = $false
            $pfResolvedIps = @()
            try {
                $pfResolved = @(Resolve-DnsName -Name $pfFqdn -Server $pfDcIp -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' })
                # Filter out null/empty IPs: an empty/partial DC reply can otherwise
                # yield a phantom 1-element array (@($emptyResult.IPAddress)) that masks
                # a genuinely-missing record and makes the check wrongly say "no action".
                $pfResolvedIps = @($pfResolved | ForEach-Object { $_.IPAddress } | Where-Object { $_ })
                # A node that resolves ONLY to its cluster VIP(s) still needs its own A
                # record, so judge "healthy" on the non-VIP records only.
                $pfNodeOwnResolved = @($pfResolvedIps | Where-Object { $pfVips -notcontains $_ })
                if ($pfOwnIp) {
                    if ($pfResolvedIps -notcontains $pfOwnIp) { $needsDnsFix = $true }
                }
                elseif (-not $pfNodeOwnResolved.Count) {
                    # Node's own IP not known host-side: fix unless the DC already
                    # returns at least one non-VIP A record for this name.
                    $needsDnsFix = $true
                }
                # A cluster VIP published under the node's own name is also wrong.
                foreach ($v in $pfVips) { if ($pfResolvedIps -contains $v) { $needsDnsFix = $true } }
            }
            catch {
                $needsDnsFix = $true
            }

            if (-not $needsDnsFix) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DNS preflight: node A record OK on DC $pfDcIp ($($pfResolvedIps -join ',')); no action." -LogOnly
            }
            else {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DNS preflight: node not correctly published on DC $pfDcIp [resolved: $($pfResolvedIps -join ',')]; re-registering its own IP." -Warning
                $preflightFix = {
                    param($nodeSubnet, $nodeOwnIp, $clusterVips, $dcIp, $fqdn)
                    $out = @()
                    $vipSet = @()
                    if ($clusterVips) { $vipSet = @($clusterVips | Where-Object { $_ }) }
                    # Find the domain NIC (the one carrying this node's own subnet IP).
                    $domainAdapter = $null
                    foreach ($adapter in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
                        $ips = @((Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress)
                        if ($ips | Where-Object { $_ -like "$nodeSubnet*" }) { $domainAdapter = $adapter; break }
                    }
                    if (-not $domainAdapter) { return "no domain NIC on $nodeSubnet*; skipped" }
                    # Mark cluster VIPs SkipAsSource so registerdns publishes ONLY the
                    # node's own IP under its name (never a cluster core / AG listener VIP).
                    foreach ($addr in (Get-NetIPAddress -InterfaceIndex $domainAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                        if (-not ($addr.IPAddress -like "$nodeSubnet*")) { continue }
                        if ($nodeOwnIp -and $addr.IPAddress -eq $nodeOwnIp) {
                            if ($addr.SkipAsSource) { Set-NetIPAddress -InterfaceIndex $addr.InterfaceIndex -IPAddress $addr.IPAddress -SkipAsSource $false -ErrorAction SilentlyContinue }
                            continue
                        }
                        $isVip = $false
                        if ($nodeOwnIp) { $isVip = $true }
                        elseif ($vipSet -contains $addr.IPAddress) { $isVip = $true }
                        elseif ($addr.PrefixOrigin -eq 'Manual') { $isVip = $true }
                        if ($isVip -and -not $addr.SkipAsSource) {
                            Set-NetIPAddress -InterfaceIndex $addr.InterfaceIndex -IPAddress $addr.IPAddress -SkipAsSource $true -ErrorAction SilentlyContinue
                            $out += "marked VIP $($addr.IPAddress) SkipAsSource"
                        }
                    }
                    Set-DnsClient -InterfaceIndex $domainAdapter.InterfaceIndex -RegisterThisConnectionsAddress $true -ErrorAction SilentlyContinue
                    & ipconfig /registerdns 2>&1 | Out-Null
                    $out += "enabled reg + registerdns on '$($domainAdapter.InterfaceAlias)'"
                    # Wait (up to ~30s) for the DC to publish the node's own A record,
                    # so the DC's subsequent DSC push can resolve the node.
                    if ($nodeOwnIp -and $dcIp -and $fqdn) {
                        $published = $false
                        for ($i = 0; $i -lt 10; $i++) {
                            Start-Sleep -Seconds 3
                            $r = @(Resolve-DnsName -Name $fqdn -Server $dcIp -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' })
                            if (@($r.IPAddress) -contains $nodeOwnIp) { $published = $true; break }
                        }
                        if ($published) { $out += "A record $nodeOwnIp visible on DC" }
                        else { $out += "A record not visible after 30s (registration submitted)" }
                    }
                    return ($out -join '; ')
                }
                # The node's own IP is ground truth for which NIC is the domain NIC; the
                # configured network can belong to a different subnet (see $pfDcIp above),
                # which made the in-guest fix find no matching NIC and silently no-op.
                $pfNodeSubnetSource = $pfOwnIp
                if (-not $pfNodeSubnetSource) { $pfNodeSubnetSource = $currentItem.network }
                if (-not $pfNodeSubnetSource) { $pfNodeSubnetSource = $deployConfig.vmOptions.network }
                $pfNodeSubnet = ($pfNodeSubnetSource -replace '\.\d+$', '.')
                $pf = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName `
                    -ScriptBlock $preflightFix -ArgumentList @($pfNodeSubnet, $pfOwnIp, $pfVips, $pfDcIp, $pfFqdn) `
                    -DisplayName "Ensure node DNS published"
                if ($pf.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DNS preflight fix failed: $($pf.ScriptBlockOutput)" -Warning
                }
                else {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DNS preflight fix: $($pf.ScriptBlockOutput)"
                }
            }

            # Flush the DC's resolver cache before the DC pushes DSC to this node --
            # but ONLY when we just re-registered the node above ($needsDnsFix).
            # Even once the node's A record IS present in the zone, the DC's CLIENT
            # resolver can hold a stale NEGATIVE entry (NXDOMAIN) cached from a push
            # attempt made BEFORE the node registered. That negative cache makes the
            # DC's Start-DscConfiguration -ComputerName push fail to resolve the node
            # ("WinRM ... the server name cannot be resolved") even though DNS is now
            # correct. That stale negative entry is only created when the node was
            # NOT yet published, i.e. exactly the $needsDnsFix path -- so the flush is
            # only meaningful there.
            #
            # When the node was already correctly published (the common re-run case,
            # "node A record OK ... no action"), nothing this run poisoned the DC's
            # cache and any older negative entry has long since aged out (default
            # negative TTL <= 15 min). Skipping the flush there avoids a needless
            # PSDirect round-trip to the DC -- which, with every SQLAO node hitting the
            # DC's PSDirect channel concurrently, was contending and TIMING OUT at
            # ~54s per node ("cache flush failed:") and adding ~1 min to the critical
            # path of phases 3/4/5 for no benefit (the push succeeds regardless).
            if ($needsDnsFix -and $pfDcVmName) {
                $pfDcFlush = Invoke-VmCommand -VmName $pfDcVmName -VmDomainName $domainName -ScriptBlock {
                    param($fqdn)
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                    $a = @(Resolve-DnsName -Name $fqdn -Type A -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' -and $_.IPAddress })
                    $ips = @($a | ForEach-Object { $_.IPAddress })
                    return "flushed; DC resolves $fqdn -> $($ips -join ',')"
                } -ArgumentList $pfFqdn -DisplayName "Flush DC DNS cache for $($currentItem.vmName)"
                if ($pfDcFlush.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DNS preflight: DC ($pfDcVmName) cache flush failed: $($pfDcFlush.ScriptBlockOutput)" -Warning
                }
                else {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DNS preflight: DC ($pfDcVmName) cache $($pfDcFlush.ScriptBlockOutput)"
                }
            }
        }

        if ($skipStartDsc) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC for $($currentItem.role) configuration will be started on the DC."
            Write-Progress2 $Activity -Status "Waiting for DC to start DSC" -percentcomplete 75 -force
        }
        else {
            Write-Progress2 $Activity -Status "Starting DSC" -percentcomplete 75 -force
            if ($multiNodeDsc) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC for $($currentItem.role) Starting"
                # Wait until every member node has written THIS run's GUID to
                # RunGuid.txt before the DC pushes the multi-node config. A node
                # writes the token as the LAST step of DSC_ClearStatus, only
                # after its old DSC is stopped and DSC_Status.txt is cleared, so
                # a matching token positively proves the node stopped + cleared
                # and is ready for the push. (The old signal -- DSC_Status.txt
                # absent -- was defeated both by stale prior-run files and by a
                # member's self-recovery re-creating DSC_Status.txt, which
                # dead-waited this loop the full 150 attempts.)
                $nodeList = New-Object System.Collections.ArrayList
                $nonReadyNodes = New-Object System.Collections.ArrayList
                foreach ($node in ($ConfigurationData.AllNodes.NodeName | Where-Object { $_ -ne "*" })) {
                    $nodeList.Add($node) | Out-Null
                }

                
                $attempts = 0
                $maxAttempts = 150
                do {
                    $attempts++
                    $allNodesReady = $true
                    $nonReadyNodes = $nodeList.Clone()
                    $percent = [Math]::Min($attempts, $maxAttempts)
                    Write-Progress2 "Waiting for all nodes. Attempt #$attempts/100" -Status "Waiting for [$($nonReadyNodes -join ',')] to be ready." -PercentComplete $percent -force

                    # Periodically check DSC_Init.log to see if DSC_ClearStatus started/progressed.
                    # Readiness itself is keyed off RunGuid.txt == this run's GUID (written last by
                    # DSC_ClearStatus), so a self-recovery that re-creates DSC_Status.txt no longer
                    # blocks the loop.
                    $detailedCheck = ($attempts -ge 15 -and ($attempts % 15) -eq 0)

                    foreach ($node in $nonReadyNodes) {
                        if (-not $node) {
                            continue
                        }
                        $result = Invoke-VmCommand -VmName $node -VmDomainName $deployConfig.vmOptions.domainName -CommandReturnsBool -ScriptBlock {
                            param($expectedGuid)
                            $f = "C:\staging\DSC\RunGuid.txt"
                            if (-not (Test-Path $f)) { return $false }
                            $content = Get-Content $f -ErrorAction SilentlyContinue | Select-Object -First 1
                            if ($content) { $content = $content.Trim() }
                            return ($content -eq $expectedGuid)
                        } -ArgumentList $phaseRunGuid -DisplayName "DSC: Check Nodes Ready"
                        if ($result.ScriptBlockFailed -or ($result.ScriptBlockOutput -ne $true)) {
                            if ($result.ScriptBlockFailed) {
                                $errDetail = if ($result.ErrorDetails) { $result.ErrorDetails -join '; ' } else { 'No session / VM unreachable' }
                                Write-Log "[Phase $Phase]: Node $node is NOT ready. Command failed: $errDetail" -Warning
                            }
                            elseif ($detailedCheck) {
                                # Only read DSC_Init.log (written at the start of DSC_ClearStatus) to check cleanup progress
                                $initResult = Invoke-VmCommand -VmName $node -VmDomainName $deployConfig.vmOptions.domainName -SuppressLog -ScriptBlock {
                                    Get-Content "C:\staging\DSC\DSC_Init.log" -Tail 5 -ErrorAction SilentlyContinue
                                } -DisplayName "DSC: Check Init Log"
                                if (-not $initResult.ScriptBlockFailed -and $initResult.ScriptBlockOutput) {
                                    Write-Log "[Phase $Phase]: Node $node is NOT ready (attempt $attempts). DSC_Init.log tail: $($initResult.ScriptBlockOutput -join ' | ')"
                                }
                                else {
                                    Write-Log "[Phase $Phase]: Node $node is NOT ready (attempt $attempts). DSC_ClearStatus may not have started yet."
                                }
                            }
                            else {
                                Write-Log "[Phase $Phase]: Node $node is NOT ready. RunGuid match: $($result.ScriptBlockOutput) (attempt $attempts)" -LogOnly
                            }
                            $allNodesReady = $false
                        }
                        else {
                            $nodeList.Remove($node) | Out-Null
                            if ($nodeList.Count -eq 0) {
                                Write-Progress2 "Waiting for all nodes. Attempt #$attempts/$maxAttempts" -status "All nodes are ready" -PercentComplete 100 -force
                                $allNodesReady = $true
                            }
                            else {
                                Write-Progress2 "Waiting for all nodes. Attempt #$attempts/$maxAttempts" -Status "Waiting for [$($nodeList -join ',')] to be ready." -PercentComplete $percent -force
                            }
                        }
                    }

                    if ($attempts -eq 80) {
                        foreach ($node in $nodeList) {
                            # Log DSC_Init.log before rebooting to see what DSC_ClearStatus did
                            Write-Log "[Phase $Phase]: Rebooting stuck node $node at attempt $attempts" -Warning
                            $preRebootResult = Invoke-VmCommand -VmName $node -VmDomainName $deployConfig.vmOptions.domainName -SuppressLog -ScriptBlock {
                                $info = @{}
                                $info.InitLogTail = Get-Content "C:\staging\DSC\DSC_Init.log" -Tail 10 -ErrorAction SilentlyContinue
                                $info.LcmState = try { (Get-DscLocalConfigurationManager).LCMState } catch { 'Unknown' }
                                $info
                            } -DisplayName "DSC: Pre-Reboot Diagnostics"
                            if (-not $preRebootResult.ScriptBlockFailed -and $preRebootResult.ScriptBlockOutput) {
                                $diag = $preRebootResult.ScriptBlockOutput
                                Write-Log "[Phase $Phase]: Node $node pre-reboot: LCM='$($diag.LcmState)'" -Warning
                                if ($diag.InitLogTail) {
                                    Write-Log "[Phase $Phase]: Node $node DSC_Init.log (last 10 lines):" -LogOnly
                                    foreach ($logLine in $diag.InitLogTail) { Write-Log "  $logLine" -LogOnly }
                                }
                            }
                            else {
                                Write-Log "[Phase $Phase]: Node $node pre-reboot: Could not retrieve diagnostics (VM unreachable)" -Warning
                            }
                            Write-Progress2 "Restarting $node" -PercentComplete $percent -force
                            Stop-Vm2 -Name $node
                            Start-Sleep -seconds 20
                            Start-VM2 -Name $node
                            Start-Sleep -seconds 60
                        }
                    }

                    Start-Sleep -Seconds 3
                } until ($allNodesReady -or $attempts -ge $maxAttempts)

                if (-not $allNodesReady) {
                    # Gather final diagnostics from each stuck node.
                    # After 150 attempts + a reboot, DSC_ClearStatus has either completed or failed,
                    # so reading DSC_Status.txt here is safe - its presence means cleanup genuinely failed.
                    foreach ($node in $nodeList) {
                        Write-Log "[Phase $Phase]: FINAL DIAGNOSTICS for stuck node $node" -Failure
                        $diagResult = Invoke-VmCommand -VmName $node -VmDomainName $deployConfig.vmOptions.domainName -SuppressLog -ScriptBlock {
                            $info = @{}
                            $info.StatusContent = Get-Content "C:\staging\DSC\DSC_Status.txt" -ErrorAction SilentlyContinue
                            $info.RunGuidContent = Get-Content "C:\staging\DSC\RunGuid.txt" -ErrorAction SilentlyContinue
                            $info.InitLogTail = Get-Content "C:\staging\DSC\DSC_Init.log" -Tail 20 -ErrorAction SilentlyContinue
                            $info.LcmState = try { (Get-DscLocalConfigurationManager).LCMState } catch { 'Unknown' }
                            $info.LastDscStatus = try { (Get-DscConfigurationStatus -ErrorAction SilentlyContinue).Status } catch { 'Unknown' }
                            $info.PendingReboot = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
                            $info.StagingFiles = try { (Get-ChildItem "C:\staging\DSC" -File -ErrorAction SilentlyContinue).Name -join ', ' } catch { 'N/A' }
                            $info
                        } -DisplayName "DSC: Final Diagnostics"
                        if (-not $diagResult.ScriptBlockFailed -and $diagResult.ScriptBlockOutput) {
                            $diag = $diagResult.ScriptBlockOutput
                            Write-Log "[Phase $Phase]: Node ${node}: RunGuid.txt = '$($diag.RunGuidContent)' (expected '$phaseRunGuid')" -Failure
                            Write-Log "[Phase $Phase]: Node ${node}: DSC_Status.txt = '$($diag.StatusContent)'" -Failure
                            Write-Log "[Phase $Phase]: Node ${node}: LCM State = $($diag.LcmState), Last DSC Status = $($diag.LastDscStatus), Reboot Pending = $($diag.PendingReboot)" -Failure
                            Write-Log "[Phase $Phase]: Node ${node}: Staging files: $($diag.StagingFiles)" -LogOnly
                            if ($diag.InitLogTail) {
                                Write-Log "[Phase $Phase]: Node $node DSC_Init.log (last 20 lines):" -Failure
                                foreach ($logLine in $diag.InitLogTail) { Write-Log "  $logLine" -LogOnly }
                            }
                        }
                        else {
                            $errDetail = if ($diagResult.ErrorDetails) { $diagResult.ErrorDetails -join '; ' } else { 'No session / VM unreachable' }
                            Write-Log "[Phase $Phase]: Node ${node}: Could not retrieve diagnostics: $errDetail" -Failure
                        }
                    }
                    Write-Progress2 "Failed waiting on VMs [$($nodeList -join ',')].  Please cancel and retry this phase." -force
                    write-log "[Phase $Phase]: Node [$($nodeList -join ',')] is NOT ready after $maxAttempts attempts." -failure -OutputStream
                    return $false
                }

            }
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Finished waiting on all nodes"

            Write-Progress2 "Creating DSC" -status "Invoking DSC_CreateConfig" -PercentComplete 0 -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Creating DSC configuration."
            $dscCreateStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_CreateConfig -ArgumentList $DscFolder -DisplayName "DSC: Create $($currentItem.role) Configuration"
            $dscCreateStopWatch.Stop()
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to create $($currentItem.role) configuration after $([math]::Round($dscCreateStopWatch.Elapsed.TotalSeconds, 1)) seconds. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
            }
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC configuration creation completed in $([math]::Round($dscCreateStopWatch.Elapsed.TotalSeconds, 1)) seconds."

            Write-Progress2 "Starting DSC" -status "Invoking DSC_StartConfig" -PercentComplete 50 -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Starting DSC configuration."
            $dscStartStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
            if ($result.ScriptBlockFailed) {
                Start-Sleep -Seconds 15
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to start $($currentItem.role) configuration. Retrying. $($result.ScriptBlockOutput)" -Warning
                # Retry once before exiting
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to Start $($currentItem.role) configuration. Rebooting. $($result.ScriptBlockOutput)" -Warning
                    Restart-VM2Smart -Name $currentItem.vmName -AllowTurnOff -Reason "DSC start retry" | Out-Null
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
                    if ($result.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to Start $($currentItem.role) configuration. Exiting. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }
                                        
                }
            }
            $dscStartStopWatch.Stop()
            Write-Progress2 "Starting DSC" -status "[Phase $Phase]: $($currentItem.vmName): DSC start command returned." -PercentComplete 100 -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC start command returned after $([math]::Round($dscStartStopWatch.Elapsed.TotalSeconds, 1)) seconds."
        }

        # =============================================================
        # Stamp a per-deploy RunId on the VM and clear any stale
        # completion marker. ScriptWorkflow.ps1 will echo this RunId
        # into ScriptWorkflow.completed.runid once it finishes ALL of
        # its post-install scripts (InstallProvider, PushClients,
        # EnableBLM, etc.). The monitoring loop below treats matching
        # RunIds as authoritative completion, eliminating the race
        # where Complete! status is overwritten by later writes.
        # =============================================================
        $expectedRunId = [guid]::NewGuid().ToString()
        $stampResult = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -SuppressLog -ScriptBlock {
            param($runId)
            $dir = 'C:\staging\DSC'
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            # Delete any stale completion marker from a prior deploy BEFORE writing expected -- guarantees no false positive
            Remove-Item -Path (Join-Path $dir 'ScriptWorkflow.completed.runid') -Force -ErrorAction SilentlyContinue
            Set-Content -Path (Join-Path $dir 'ScriptWorkflow.expected.runid') -Value $runId -Force -Encoding ASCII
        } -ArgumentList $expectedRunId -DisplayName "DSC: Stamp Phase RunId"
        if ($stampResult.ScriptBlockFailed) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to stamp RunId (will rely on status-string fallback). $($stampResult.ScriptBlockOutput)" -Warning
            $expectedRunId = $null
        }

        ### ===========================
        ### Start Monitoring the jobs
        ### ===========================

        $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
        $timeout = $using:RoleConfigTimeoutMinutes
        if ($Phase -eq 8) {
            $timeout = $timeout * 2
        }
        $timeSpan = New-TimeSpan -Minutes $timeout
        $stopWatch.Start()

        $complete = $false
        $previousStatus = ""
        $currentStatus = $null
        $suppressNoisyLogging = $Common.VerboseEnabled -eq $false
        [int]$failedHeartbeats = 0
        # Reboot is a LAST resort. Scale heartbeat patience by host load: when
        # many VMs deploy at once, PSDirect/CPU/disk contention makes a HEALTHY
        # guest legitimately go silent far longer (especially across a
        # rename/OOBE/specialize reboot), so we must wait longer before assuming
        # it is hung. Base ~100 tries + 25 per running VM over 8 (each try ~3-10s).
        $heartbeatRunningVmCount = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }).Count
        $heartbeatExtraVms = [Math]::Max(0, $heartbeatRunningVmCount - 8)
        [int]$failedHeartbeatThreshold = 100 + ($heartbeatExtraVms * 25)
        # A guest that has NOT yet produced any DSC status this phase is most
        # likely still in first-boot / OOBE / specialize / rename-reboot, where a
        # forced power-off corrupts it (lands at the Windows recovery screen,
        # unrecoverable). Demand a much longer silence before the FIRST restart.
        [int]$firstRestartHeartbeatThreshold = $failedHeartbeatThreshold * 3
        [int]$forcedRestartCount = 0   # restarts since the last status progress
        [int]$forcedRestartMax = 3     # after this many with no progress, FAIL the VM instead of power-cycling forever
        Write-Log "[Phase $Phase]: $($currentItem.vmName): heartbeat-recovery: $heartbeatRunningVmCount running VMs -> threshold=$failedHeartbeatThreshold (first restart at $firstRestartHeartbeatThreshold), maxRestarts=$forcedRestartMax" -LogOnly

        $noStatus = $true
        $lastStatusChangeTime = [DateTime]::UtcNow
        $staleWarningMinutes = 15
        $staleRestartMinutes = 30
        $staleRestartCount = 0
        $staleRestartMax = 2
        $lastStaleWarningTime = [DateTime]::MinValue
        $lcmIdleSince = $null              # when the DSC LCM was FIRST seen continuously idle (null = not idle / unknown)
        $lcmRebootPendingSince = $null     # when the DSC LCM was FIRST seen parked reboot-pending (null = not parked / unknown)
        $lcmProbeStartMinutes = 5          # begin sampling the guest LCM once the status has been frozen this long
        $rebootStuckMinutes = 4            # resume/restart the VM once a stranded PendingConfiguration stays this long with frozen status
        $rebootPendingStuckMinutes = 2     # restart the VM once the LCM stays reboot-pending (reboot genuinely owed) this long with frozen status -- shorter than the stranded case because the LCM is literally asking for a restart
        $lcmPendingNoRebootSince = $null   # when the LCM was FIRST seen PendingConfiguration with NO reboot owed (stranded apply)
        $dscResumeCount = 0                # in-place Stop+Start-DscConfiguration -UseExisting attempts this stall episode
        $dscResumeMax = 1                  # gentle in-place resumes before escalating a stranded PendingConfiguration to a reboot
        $dscResumeTotal = 0                # in-place resumes across the WHOLE phase (per-episode count resets on every status change)
        $dscResumeTotalMax = 3             # hard cap: a node that inches forward one status line per resume must still escalate
        $lastLcmSampleTime = [DateTime]::MinValue  # throttle for the guest LCM-state poll
        $certPulseDone = $false   # one-shot guard for the PKI cert pre-stage handshake
        $sqlSetupSummaryDumped = $false   # one-shot: dump SQL Setup Summary.txt to the build log on the first SQL-install stall

        Write-Log "[Phase $Phase]: $($currentItem.vmName): Started Monitoring $($currentItem.role) configuration."
        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Ready and Waiting for job progress"
        $rebooted = $false
        $dscFails = 0
        $dscStatusPolls = 0
        [int]$failCount = 0
        $dscRecoveryAttempted = $false
        $dcReadySince = $null  # track when DC became reachable for non-DC nodes
        $sqlaoStuckRemediated = $false   # one-shot guard: bounce SQL on a stuck SQLAO replica at most once per deploy
        try {
            do {

                $dscStatusPolls++

                # Self-recovery: if the DC was supposed to push DSC to this
                # node but nothing arrived, compile and start DSC locally.
                # This handles transient WinRM/DNS failures during the DC's
                # multi-node Start-DscConfiguration push.
                # Base timeout: 3 min after the DC is confirmed reachable.
                # Add 20s per VM beyond 10 to give the DC time to push to
                # large labs sequentially.  If the DC is still rebooting
                # (no heartbeat), defer the timer until it comes back.
                $nodeCount = @($ConfigurationData.AllNodes | Where-Object { $_.NodeName -ne '*' }).Count
                $recoveryMinutes = 3 + [Math]::Max(0, ($nodeCount - 10) * 20 / 60)
                if ($skipStartDsc -and $noStatus -and -not $dscRecoveryAttempted) {
                    # Find DC readiness: don't start the recovery clock until
                    # the DC VM has a heartbeat AND AD Web Services are responding.
                    # Heartbeat OK just means the OS is running; ADWS/DNS/Kerberos
                    # may still be starting. DSC resources that use PsDscRunAsCredential
                    # need working AD services for GP processing and credential validation.
                    if (-not $dcReadySince) {
                        $dcVmObj = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
                        if ($dcVmObj) {
                            $dcHb = $null
                            try { $dcHb = (Get-VM -Name $dcVmObj.vmName -ErrorAction SilentlyContinue).Heartbeat } catch {}
                            if ($dcHb -and $dcHb.ToString() -match 'Ok') {
                                # Heartbeat OK — now verify ADWS (port 9389) is accepting connections.
                                # Without this, DSC local recovery fails with "Unable to find a default
                                # server with Active Directory Web Services running" or GP error 1053.
                                $dcIp = $deployConfig.vmOptions.network
                                if ($dcIp) {
                                    # DC is always .1 on the lab network
                                    $dcIp = ($dcIp -replace '\.\d+$', '.1')
                                }
                                $adwsUp = $false
                                if ($dcIp) {
                                    $tcp = $null
                                    try {
                                        $tcp = [System.Net.Sockets.TcpClient]::new()
                                        $task = $tcp.ConnectAsync($dcIp, 9389)
                                        $adwsUp = $task.Wait(2000)  # 2-second timeout
                                    } catch { $adwsUp = $false }
                                    finally { if ($tcp) { $tcp.Dispose() } }
                                }
                                if ($adwsUp) {
                                    $dcReadySince = [DateTime]::UtcNow
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DC ($($dcVmObj.vmName)) heartbeat OK, ADWS responding — recovery timer starts now." -LogOnly
                                } elseif ($stopWatch.Elapsed.TotalMinutes -gt 1 -and ($dscStatusPolls % 20) -eq 0) {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DC ($($dcVmObj.vmName)) heartbeat OK but ADWS not yet responding (elapsed $([Math]::Round($stopWatch.Elapsed.TotalMinutes, 1)) min)." -LogOnly
                                }
                            } elseif ($stopWatch.Elapsed.TotalMinutes -gt 1 -and ($dscStatusPolls % 20) -eq 0) {
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): Waiting for DC ($($dcVmObj.vmName)) heartbeat before recovery timer (elapsed $([Math]::Round($stopWatch.Elapsed.TotalMinutes, 1)) min, heartbeat=$dcHb)." -LogOnly
                            }
                        } else {
                            # No DC in config (shouldn't happen) — fall back to original timer
                            $dcReadySince = [DateTime]::UtcNow
                        }
                    }

                    $minutesSinceDcReady = if ($dcReadySince) { ([DateTime]::UtcNow - $dcReadySince).TotalMinutes } else { 0 }
                    if ($dcReadySince -and $minutesSinceDcReady -gt $recoveryMinutes) {
                        # "No status yet" only means the GUEST hasn't written DSC_Status.txt -- NOT that the
                        # DC's push failed. A long first resource (Phase 4's SQL install) keeps the LCM busy
                        # for many minutes before any status lands, so this fired on 5 of 7 Phase 4 nodes and
                        # every one came back LCM_Busy. Confirm the guest LCM actually has nothing to do before
                        # crying wolf: a Busy/Pending LCM proves the push DID arrive, so extend the window
                        # instead of emitting a warning (which also downgrades the phase summary from success)
                        # and spending a 300s round-trip on a recovery that can only no-op.
                        $lcmPush = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 60 -ScriptBlock {
                            try { (Get-DscLocalConfigurationManager -ErrorAction Stop).LCMState } catch { 'unreachable' }
                        } -SuppressLog
                        $lcmPushState = if ((-not $lcmPush.ScriptBlockFailed) -and $lcmPush.ScriptBlockOutput) { [string]$lcmPush.ScriptBlockOutput } else { 'unreachable' }
                        if ($lcmPushState -ne 'Idle') {
                            $dcReadySince = [DateTime]::UtcNow
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): No DSC status after $([Math]::Round($recoveryMinutes, 1)) min ($nodeCount nodes), but the guest LCM is '$lcmPushState' -- the DC's push arrived and is still applying. Extending the window; not compiling locally." -LogOnly
                        }
                        else {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): No DSC status after $([Math]::Round($recoveryMinutes, 1)) min ($nodeCount nodes) since DC ready and the guest LCM is Idle -- DC failed to push config. Attempting local compile+start." -Warning -OutputStream
                    $DSC_RecoverLocal = {
                        param($DscFolder)
                        $log = "C:\staging\DSC\DSC_Init.log"
                        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
                        "`r`n=====`r`nDSC_RecoverLocal: $time`r`n=====" | Out-File $log -Append -Force

                        $lcm = Get-DscLocalConfigurationManager
                        if ($lcm.LCMState -ne 'Idle') {
                            "LCM is $($lcm.LCMState), skipping" | Out-File $log -Append
                            return "LCM_$($lcm.LCMState)"
                        }

                        $Phase = $using:Phase
                        $deployConfig = Get-Content 'C:\staging\DSC\deployConfig.json' -Force | ConvertFrom-Json
                        $dscRole = "Phase$Phase"
                        $dscConfigScript = "C:\staging\DSC\$DscFolder\$dscRole.ps1"
                        $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"
                        $deployConfigPath = 'C:\staging\DSC\deployConfig.json'

                        if (-not (Test-Path $dscConfigScript)) {
                            "Script not found: $dscConfigScript" | Out-File $log -Append
                            return "SCRIPT_NOT_FOUND"
                        }

                        $netbiosName = $deployConfig.vmOptions.domainNetBiosName
                        $user = "$netbiosName\$($using:Common.LocalAdmin.UserName)"
                        $creds = New-Object System.Management.Automation.PSCredential ($user, $using:Common.LocalAdmin.Password)

                        $nodeName = $env:COMPUTERNAME
                        $thisVm = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $nodeName }

                        # Map VM role to the DSC Node-block role the phase config expects.
                        # Get-Phase*ConfigurationData does this mapping when the DC pushes;
                        # the local recovery must match or it compiles against a non-existent
                        # Node block and produces no MOF (MOF_NOT_FOUND).
                        $nodeRole = if ($thisVm) { $thisVm.Role } else { 'DomainMember' }
                        if ($nodeRole -eq 'SQLAO') {
                            if ($Phase -eq 5) {
                                # Phase 5 splits SQLAO into ClusterNode1 (has OtherNode) / ClusterNode2
                                $nodeRole = if ($thisVm.OtherNode) { 'ClusterNode1' } else { 'ClusterNode2' }
                            }
                            else {
                                # Phases 8/9 treat SQLAO as SqlServer
                                $nodeRole = 'SqlServer'
                            }
                        }
                        elseif ($Phase -eq 6) {
                            # Get-Phase6ConfigurationData synthesizes Role='WSUS' for every VM
                            # picked up by the filter (Role='WSUS' OR installSUP=$true). A
                            # dual-role VM (e.g. Primary/CAS/FileServer with installSUP) keeps
                            # its real role on disk but the DC-pushed MOF expects 'WSUS'.
                            if ($thisVm -and ($thisVm.Role -eq 'WSUS' -or $thisVm.installSUP -eq $true)) {
                                $nodeRole = 'WSUS'
                            }
                        }
                        elseif ($Phase -eq 7) {
                            # Get-Phase7ConfigurationData filter: installRP OR installSUP OR Role='WSUS'.
                            # Synthetic role: PBIRS if installRP, else WSUS.
                            if ($thisVm -and $thisVm.installRP -eq $true) {
                                $nodeRole = 'PBIRS'
                            }
                            elseif ($thisVm -and ($thisVm.Role -eq 'WSUS' -or $thisVm.installSUP -eq $true)) {
                                $nodeRole = 'WSUS'
                            }
                        }

                        $cd = @{
                            AllNodes = @(
                                @{ NodeName = '*'; PSDscAllowDomainUser = $true; PSDscAllowPlainTextPassword = $true }
                                @{ NodeName = $nodeName; Role = $nodeRole }
                            )
                        }

                        $env:PSModulePath = "C:\Program Files\WindowsPowerShell\Modules;C:\Windows\system32\WindowsPowerShell\v1.0\Modules"
                        . "$dscConfigScript"

                        "Compiling $dscRole for $nodeName (Role: $($cd.AllNodes[1].Role))" | Out-File $log -Append
                        try {
                            & "$dscRole" -DeployConfigPath $deployConfigPath -AdminCreds $creds -ConfigurationData $cd -OutputPath $dscConfigPath
                        }
                        catch {
                            "Compilation failed: $_" | Out-File $log -Append
                            return "COMPILE_FAILED"
                        }

                        $mofPath = Join-Path $dscConfigPath "$nodeName.mof"
                        if (-not (Test-Path $mofPath)) {
                            "MOF not found: $mofPath" | Out-File $log -Append
                            return "MOF_NOT_FOUND"
                        }

                        Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force -ErrorAction SilentlyContinue
                        "Starting DSC locally from $dscConfigPath" | Out-File $log -Append
                        $null = Start-DscConfiguration -Path $dscConfigPath -Force -Verbose
                        return "STARTED"
                    }
                    $recoveryResult = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_RecoverLocal -ArgumentList $DscFolder -DisplayName "DSC: Local Recovery" -AsJob -TimeoutSeconds 300
                    $recoveryOutput = if ($recoveryResult.ScriptBlockOutput) { $recoveryResult.ScriptBlockOutput } else { "no output" }
                    if ($recoveryResult.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC local recovery failed: $recoveryOutput" -Warning
                    }
                    else {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC local recovery: $recoveryOutput" -Warning -OutputStream
                    }
                    # Only consume the one-shot when a recovery actually ran. The guest-side guard returns
                    # LCM_<state> without touching anything, so treating that as "attempted" would permanently
                    # disable the real recovery for a node that merely happened to be busy at that instant.
                    if ($recoveryResult.ScriptBlockFailed -or ("$recoveryOutput" -like 'LCM_*')) {
                        $dcReadySince = [DateTime]::UtcNow
                    }
                    else {
                        $dscRecoveryAttempted = $true
                    }
                    } # else: LCM idle -- local recovery ran
                    } # if dcReadySince and minutesSinceDcReady > recoveryMinutes
                } # if skipStartDsc and noStatus

                if ($dscStatusPolls -ge 10) {
                    $failure = $false
                    $dscStatusPolls = 0 # Do this every 30 seconds or so
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Polling DSC Status via Get-DscConfigurationStatus" -Verbose
                    $dscStatus = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 120 -ScriptBlock {
                        $ProgressPreference = 'SilentlyContinue'
                        try { 
                            Get-DscConfigurationStatus | out-null
                        }
                        catch {}

                        $ProgressPreference = 'Continue'
                    } -SuppressLog:$suppressNoisyLogging

                    if ($dscStatus.ScriptBlockFailed -or $dscStatus.ScriptBlockOutput.Error) {
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Get-DscConfigurationStatus did not complete"
                        Write-log "[Phase $Phase]: $($currentItem.vmName): $($dscStatus.ScriptBlockOutput) $($dscStatus.ScriptBlockOutput) $($dscStatus.ScriptBlockOutput.Error)"
                        $dscFails++
                        if ($dscFails -ge 20) {
                            stop-vm2 -name $currentItem.vmName
                            start-sleep -Seconds 10
                            start-vm2 -name $currentItem.vmName
                            Wait-ForHeartbeat -VmName $currentItem.vmName -Stopwatch $stopWatch -Timespan $timespan | Out-Null
                            $dscFails = 0
                        }
                        continue
                    }
                    else {
                        $dscFails = 0
                    }

                    if (-not $rebooted -and $dscStatus.ScriptBlockOutput.RebootRequested -eq $true) {
                        # Reboot the machine
                        start-sleep -Seconds 30 # Wait 30 seconds and re-request.. maybe its going to reboot itself.
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC requested reboot, Waiting 30 seconds to see if it reboots itself."
                        $dscStatus = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 120 -ScriptBlock {
                            $ProgressPreference = 'SilentlyContinue'
                            try { 
                                Get-DscConfigurationStatus | out-null
                            }
                            catch {}

                            $ProgressPreference = 'Continue'
                        } -SuppressLog:$suppressNoisyLogging
                        # Reboot the machine
                        if ($dscStatus.ScriptBlockOutput.RebootRequested) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC requested reboot, but has not rebooted.  Forcing Restart."
                            stop-vm2 -name $currentItem.vmName
                            start-sleep -Seconds 10
                            start-vm2 -name $currentItem.vmName
                            Wait-ForHeartbeat -VmName $currentItem.vmName -Stopwatch $stopWatch -Timespan $timespan | Out-Null
                            $rebooted = $true
                        }
                    }
                    else {
                        $rebooted = $false
                    }



                    if ($dscStatus.ScriptBlockFailed) {
                        if ($currentStatus -is [string]) {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $($currentStatus.Trim() + "... ")
                        }
                        else {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "DSC In Progress. No Status. "
                        }
                        # This cmd fails when DSC is running, so it's 'good'
                    }
                    else {
                        if ($dscStatus.ScriptBlockOutput -and $dscStatus.ScriptBlockOutput.Status -ne "Success") {
                            $badResources = $dscStatus.ScriptBlockOutput.ResourcesNotInDesiredState
                            foreach ($badResource in $badResources) {
                                if (-not $badResource.Error) {
                                    continue
                                }
                                $errorResourceId = $badResource.ResourceId
                                $errorObject = $badResource.Error | ConvertFrom-Json -ErrorAction SilentlyContinue
                                if ($errorObject.FullyQualifiedErrorId -ne "NonTerminatingErrorFromProvider") {
                                    $msg = "$errorResourceId`: $($errorObject.FullyQualifiedErrorId) $($errorObject.Exception.Message)"
                                    if ($msg.Contains("does not exist on SQL server")) {
                                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Waiting on AD Replication to add account to machine"
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Status: $($dscStatus.ScriptBlockOutput.Status) : $msg" -Warning -LogOnly
                                        continue
                                    }
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Status: $($dscStatus.ScriptBlockOutput.Status) : $msg" -Warning -OutputStream
                                    $FailtimeSpan = New-TimeSpan -Minutes 35
                                    if ($FailStopWatch -and $FailStopWatch.Elapsed.TotalMinutes -gt 35) {
                                        $FailStopWatch.Stop()
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Status: $($dscStatus.ScriptBlockOutput.Status) : $msg" -Failure -OutputStream
                                        $failure = $true
                                    }
                                    else {
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Status: $($dscStatus.ScriptBlockOutput.Status) : $msg" -Warning -LogOnly
                                    }
                                    if (-not $FailStopWatch) {
                                        $FailStopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
                                        $FailStopWatch.Start()
                                    }
                                    Write-ProgressElapsed -stopwatch $FailStopWatch -timespan $FailtimeSpan -text "[Phase $Phase]: $($currentItem.vmName): Status: $($dscStatus.ScriptBlockOutput.Status) (Currently Retrying) : $msg"
                                    if ($msg.Contains("ADServerDownException")) {
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: ADServerDownException from VM. Restarting the VM" -Warning
                                        Restart-VM2Smart -Name $currentItem.vmName -AllowTurnOff -Reason "ADServerDownException" -Stopwatch $stopWatch -Timespan $timespan | Out-Null
                                        Continue
                                    }
                                    if (-not $failure) {
                                        continue
                                    }
                                }
                                else {
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Non Terminating error from DSC. Attempting to restart."
                                }
                            }

                            # Write-Output, and bail
                            if (-not $msg) {
                                #  [x] [<ScriptBlock>] ADA-W11Client1: DSC encountered failures. Attempting to continue. Status: Failure Output: Machine reboot failed. Please reboot it manually to finish processing the request.
                                # This condition is expected, and we are actually rebooting.
                                if ($($dscStatus.ScriptBlockOutput.Error) -like "*Machine reboot failed*") {
                                    #If we do not reboot, maybe have a counter here, and after 30 or so, we can invoke a reboot command.
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "DSC is attempting to reboot"
                                    continue
                                }
                                if ($($dscStatus.ScriptBlockOutput.Error) -like "*Could not find mandatory property*") {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)" -Failure -OutputStream
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)"
                                    $failure = $true
                                }

                                if ($($dscStatus.ScriptBlockOutput.Error) -like "*Compilation errors occurred*") {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)" -Failure -OutputStream
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)"
                                    $failure = $true
                                }

                                if ($($dscStatus.ScriptBlockOutput.Error) -ne $lasterror) {
                                    [int]$failCount = 0
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status); Output: $($dscStatus.ScriptBlockOutput.Error). Attempting to continue." -Warning -OutputStream
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text  "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status); Output: $($dscStatus.ScriptBlockOutput.Error). Attempting to continue."
                                }
                                $failCount++
                                if ($failCount -gt 100) {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)" -Failure -OutputStream
                                    $failure = $true
                                }
                                $lasterror = $($dscStatus.ScriptBlockOutput.Error)
                            }
                            if ($dscStatus.ScriptBlockOutput.Status -eq "Failure" -and $failure) {
                                Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "DSC has encountered unrecoverable errors"
                                return
                            }
                        }
                        else {
                            # Can't determine what DSC Status is, so do nothing and wait for timer to expire?
                        }
                    }
                }
                $stopwatch2 = [System.Diagnostics.Stopwatch]::new()
                $stopwatch2.Start()
                # Single round-trip: fetch DSC_Status.txt AND the completion-runid sentinel
                $status = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -ScriptBlock {
                    $statusText = Get-Content C:\staging\DSC\DSC_Status.txt -ErrorAction SilentlyContinue
                    $completedRunId = $null
                    if (Test-Path C:\staging\DSC\ScriptWorkflow.completed.runid) {
                        $completedRunId = (Get-Content C:\staging\DSC\ScriptWorkflow.completed.runid -ErrorAction SilentlyContinue | Select-Object -First 1)
                    }
                    # Emit status text first (preserves legacy string consumers) then runid as a side property
                    [pscustomobject]@{ StatusText = $statusText; CompletedRunId = $completedRunId }
                } -SuppressLog:$suppressNoisyLogging
                # Unwrap the bundled object into local snapshots WITHOUT mutating
                # $status. On some failure paths Invoke-VmCommand returns an
                # object whose ScriptBlockOutput is read-only/non-settable, and
                # assigning to it threw "The property 'ScriptBlockOutput' cannot
                # be found on this object" during Phase 2 startup.
                $completedRunIdSnapshot = $null
                $statusTextSnapshot = $null
                if ($status -and $status.ScriptBlockOutput -is [pscustomobject]) {
                    $completedRunIdSnapshot = $status.ScriptBlockOutput.CompletedRunId
                    $statusTextSnapshot = $status.ScriptBlockOutput.StatusText
                }
                elseif ($status) {
                    # Fallback (e.g. when the scriptblock failed before returning a pscustomobject)
                    $statusTextSnapshot = $status.ScriptBlockOutput
                }
                $stopwatch2.Stop()

                if (-not $status -or ($status.ScriptBlockFailed)) {
                    if ($stopwatch2.elapsed.TotalSeconds -gt 10) {
                        [int]$failedHeartbeats = [int]$failedHeartbeats + ([math]::Round($stopwatch2.elapsed.TotalSeconds / 5, 0))
                    }
                    else {
                        [int]$failedHeartbeats++
                        start-sleep -Seconds 10
                    }

                    # Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to get job status update. Failed Heartbeat Count: $failedHeartbeats" -Verbose
                    if ($failedHeartbeats -gt 10) {
                        try {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Trying to retrieve job status from VM" -failcount $failedHeartbeats -failcountMax $failedHeartbeatThreshold
                        }
                        catch {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "$_"
                        }
                    }
                }
                else {
                    start-sleep -seconds 3
                    [int]$failedHeartbeats = 0
                }

                # Reboot is a LAST resort. A guest that has never produced a DSC
                # status this phase is most likely still mid first-boot / OOBE /
                # specialize / rename-reboot, where a power-cycle can corrupt it,
                # so demand a much longer silence before the FIRST restart.
                $effectiveThreshold = $failedHeartbeatThreshold
                if ($noStatus) { $effectiveThreshold = $firstRestartHeartbeatThreshold }

                if ($failedHeartbeats -ge $effectiveThreshold) {
                    # Fail-fast on a corrupt / bugchecking guest. A guest that is
                    # triple-faulting or BSODing on boot (commonly the result of a hard
                    # power-off during OOBE/specialize) can NEVER be recovered by another
                    # power-cycle -- it just crashes again on the next boot. Hyper-V logs
                    # this on the HOST (this loop runs host-side) as Worker-Admin events
                    # 18560 (triple fault) / 18590 (unrecoverable processor error) /
                    # 18602 (guest reported a fatal error / bugcheck). None of these are
                    # ever emitted by a healthy-but-slow boot, so their presence is an
                    # unambiguous "the guest OS is broken" signal. Detecting >=2 in the
                    # recent window (a genuine loop, not a single transient BSOD) lets us
                    # stop after the first restart instead of burning the full restart
                    # budget + ~150 heartbeat tries (~30+ min) on a VM that must be
                    # deleted and recreated. Best-effort: any query failure falls through
                    # to the normal restart/timeout behavior.
                    try {
                        $fatalEvents = @(Get-WinEvent -FilterHashtable @{
                                LogName   = 'Microsoft-Windows-Hyper-V-Worker-Admin'
                                Id        = 18560, 18590, 18602
                                StartTime = (Get-Date).AddMinutes(-20)
                            } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match [regex]::Escape($currentItem.vmName) })
                        if ($fatalEvents.Count -ge 2) {
                            $codes = ($fatalEvents | Group-Object Id | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: guest OS is bugchecking / triple-faulting on boot (Hyper-V-Worker events $codes in the last 20 min). The guest is CORRUPT -- almost always from a hard power-off during OOBE/specialize -- and cannot be recovered by another power-cycle. Failing this VM now; DELETE and RECREATE it (remove the VM + its folder, then re-run New-Lab), then resume the deploy." -Failure -OutputStream
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Guest is corrupt (BSOD/triple-fault boot loop); failing -- delete + recreate this VM"
                            return
                        }
                    }
                    catch {}
                    if ($forcedRestartCount -ge $forcedRestartMax) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: VM still unresponsive after $forcedRestartCount restart attempt(s) and $failedHeartbeats heartbeat tries. Failing this VM instead of power-cycling it again (a forced power-off mid-OOBE/specialize corrupts the guest)." -Failure -OutputStream
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "VM unresponsive; failing after $forcedRestartCount restart attempt(s)"
                        return
                    }
                    try {
                        $forcedRestartCount++
                        $isLastAttempt = ($forcedRestartCount -ge $forcedRestartMax)
                        # Hard power-off is permitted ONLY on the final attempt AND
                        # only for a guest that already reached a running OS this
                        # phase (past OOBE). A guest that never produced any status is
                        # most likely still in first-boot / OOBE / specialize, where a
                        # hard TurnOff would corrupt it and would not recover it anyway
                        # -- so we keep trying graceful and ultimately fail it cleanly.
                        $allowTurnOff = ($isLastAttempt -and (-not $noStatus))
                        if ($allowTurnOff) {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Job status not retrievable; last-resort restart $forcedRestartCount/$forcedRestartMax (hard TurnOff permitted)" -failcount $failedHeartbeats -failcountMax $effectiveThreshold
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Job status not retrievable after $failedHeartbeats tries. Final restart $forcedRestartCount/$forcedRestartMax; graceful first, hard TurnOff permitted as a last resort (guest reached a running OS earlier this phase)." -Warning
                        }
                        else {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Job status not retrievable; gentle restart $forcedRestartCount/$forcedRestartMax (graceful only)" -failcount $failedHeartbeats -failcountMax $effectiveThreshold
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Job status not retrievable after $failedHeartbeats tries. Gentle (graceful-only) restart $forcedRestartCount/$forcedRestartMax; hard TurnOff reserved for the final attempt." -Warning
                        }

                        $restarted = Restart-VM2Smart -Name $currentItem.vmName -AllowTurnOff:$allowTurnOff -Reason "heartbeat recovery $forcedRestartCount/$forcedRestartMax" -Stopwatch $stopWatch -Timespan $timespan
                        if ($restarted) {
                            # Graceful shutdown succeeded (or TurnOff was used on the
                            # final attempt) and the VM was restarted -> give it a
                            # fresh window to come back and report status.
                            $failedHeartbeats = 0
                        }
                        else {
                            # Graceful shutdown did not complete and TurnOff was not
                            # permitted (still a gentler attempt, or a never-booted
                            # guest we won't power-cut). Leave it running and keep
                            # waiting; half-reset so we don't re-trigger every
                            # iteration but still re-reach the threshold (and the
                            # restart cap / TurnOff escalation) after more silence.
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: graceful shutdown did not complete; continuing to wait (no hard power-off this attempt)." -Warning
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Graceful shutdown did not complete; waiting (TurnOff reserved for final attempt)"
                            $failedHeartbeats = [int]($effectiveThreshold * 0.5)
                        }
                    }
                    catch {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Heartbeat recovery failed: $_" -Failure
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "$_"
                    }
                }

                if ($statusTextSnapshot -and $statusTextSnapshot -is [string]) {
                    $noStatus = $false
                    $currentStatus = $statusTextSnapshot | Out-String

                    # Write to log if status changed
                    if ($currentStatus -ne $previousStatus) {
                        # Trim status for logging
                        if ($currentStatus.Contains("; checking again in ")) {
                            try {
                                $currentStatusTrimmed = $currentStatus.Substring(0, $currentStatus.IndexOf("; checking again in "))
                            }
                            catch {
                                write-Log -LogOnly "[Phase $Phase]: $($currentItem.vmName): Failed SubString for checking again for $currentStatus in: $_" -failure
                            }
                        }
                        else {
                            $currentStatusTrimmed = $currentStatus
                        }

                        if ($currentStatusTrimmed.Contains("JOBFAILURE: ")) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: $($currentItem.role) failed: $currentStatusTrimmed" -Failure -OutputStream
                            break
                        }

                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Current Status for $($currentItem.role): $currentStatusTrimmed"
                        $previousStatus = $currentStatus
                        $lastStatusChangeTime = [DateTime]::UtcNow
                        $lastStaleWarningTime = [DateTime]::MinValue
                        $lcmIdleSince = $null   # status advanced -> work is progressing; reset every stuck clock
                        $lcmRebootPendingSince = $null
                        $lcmPendingNoRebootSince = $null
                        $dscResumeCount = 0
                        $forcedRestartCount = 0 # real progress -> reset the reboot-of-last-resort budget

                        # Cross-tier PKI pre-stage. The guest ScriptWorkflow emits this
                        # sentinel right before client push, then sleeps ~60s. It cannot
                        # PSDirect into the clients, but we (the host) can -- pulse +
                        # verify the cert chain on every push target now so the offline
                        # root + sub-CA land in each client's LocalMachine stores BEFORE
                        # auto-push runs ccmsetup (a missing chain => GetDPLocations
                        # 0x87d00454 over HTTPS). One-shot, best-effort, non-fatal.
                        if (-not $certPulseDone -and $currentStatusTrimmed -match 'MEMLABS-PULSE-CERTS') {
                            $certPulseDone = $true
                            $pkiOn = $false
                            try { $pkiOn = [bool]$deployConfig.cmOptions.UsePKI } catch { $pkiOn = $false }
                            if ($pkiOn) {
                                # Resolve this site server's push-client list.
                                $pulseTargets = @()
                                try {
                                    if ($currentItem.thisParams -and $currentItem.thisParams.ClientPush) {
                                        $pulseTargets = @($currentItem.thisParams.ClientPush)
                                    }
                                    elseif ($deployConfig -and $deployConfig.virtualMachines) {
                                        $meVm = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $currentItem.vmName } | Select-Object -First 1
                                        if ($meVm -and $meVm.thisParams -and $meVm.thisParams.ClientPush) {
                                            $pulseTargets = @($meVm.thisParams.ClientPush)
                                        }
                                    }
                                }
                                catch { $pulseTargets = @() }
                                $pulseTargets = @($pulseTargets | Where-Object { $_ -and $_ -ne $currentItem.vmName } | Select-Object -Unique)
                                if ($pulseTargets.Count -gt 0) {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): PKI pre-stage -- pulsing cert chain on $($pulseTargets.Count) push client(s): $($pulseTargets -join ', ')" -OutputStream
                                    # Runs on each client (guest PS5.1) via PSDirect: pull GP/autoenroll
                                    # so the published root + sub-CA propagate, then verify the client-auth
                                    # cert builds a complete chain to a trusted root.
                                    $certPulseBlock = {
                                        $o = [ordered]@{ CertFound = $false; ChainOk = $false; ChainStatus = 'n/a' }
                                        try { & certutil.exe -pulse 2>&1 | Out-Null } catch { }
                                        try { & gpupdate.exe /target:computer /force 2>&1 | Out-Null } catch { }
                                        Start-Sleep -Seconds 5
                                        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                                            Where-Object {
                                                ($_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.2') -and
                                                ($_.Subject -ne $_.Issuer) -and ($_.Issuer -notmatch 'O=Microsoft')
                                            } | Select-Object -First 1
                                        if ($cert) {
                                            $o.CertFound = $true
                                            try {
                                                $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                                                $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                                                $built = $chain.Build($cert)
                                                $st = (@($chain.ChainStatus) | ForEach-Object { $_.Status }) -join ','
                                                if (-not $st) { $st = 'OK' }
                                                $o.ChainOk = [bool]$built
                                                $o.ChainStatus = $st
                                            }
                                            catch { $o.ChainStatus = "chain-error: $($_.Exception.Message)" }
                                        }
                                        return $o
                                    }
                                    foreach ($pt in $pulseTargets) {
                                        $ptDomain = $domainName
                                        try {
                                            $ptVm = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $pt } | Select-Object -First 1
                                            if ($ptVm -and $ptVm.domain) { $ptDomain = $ptVm.domain }
                                        }
                                        catch { $ptDomain = $domainName }
                                        try {
                                            $pr = Invoke-VmCommand -VmName $pt -VmDomainName $ptDomain -ScriptBlock $certPulseBlock -AsJob -TimeoutSeconds 120 -SuppressLog -DisplayName "PKI cert pre-stage"
                                            $po = $pr.ScriptBlockOutput
                                            if ($po -and $po.ChainOk) {
                                                Write-Log "[Phase $Phase]: ${pt}: PKI pre-stage OK -- client cert chains to trusted root ($($po.ChainStatus))." -LogOnly
                                            }
                                            elseif ($po -and $po.CertFound) {
                                                Write-Log "[Phase $Phase]: ${pt}: PKI pre-stage pulsed, but chain still incomplete ($($po.ChainStatus)); should converge before ccmsetup retry." -Warning
                                            }
                                            else {
                                                Write-Log "[Phase $Phase]: ${pt}: PKI pre-stage pulsed, no client-auth cert yet (auto-enroll pending)." -Warning
                                            }
                                        }
                                        catch {
                                            Write-Log "[Phase $Phase]: ${pt}: PKI pre-stage pulse failed: $($_.Exception.Message)" -Warning
                                        }
                                    }
                                }
                                else {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): PKI pre-stage sentinel seen but no push clients resolved." -LogOnly
                                }
                            }
                            else {
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): PKI pre-stage sentinel seen but UsePKI=false; skipping." -LogOnly
                            }
                        }
                    }
                    else {
                        # Status text unchanged. A frozen status by itself does NOT mean the VM is stuck:
                        # a node can legitimately hold one status for hours (e.g. a PassiveSite sitting in a
                        # cross-node WaitForAll, or a long ConfigMgr setup step). The only reliable "stuck"
                        # signal is the DSC LCM being CONTINUOUSLY IDLE for a sustained window -- if the LCM
                        # is Busy/Pending it is still applying (or queued to auto-re-apply) the configuration.
                        # We require the LCM to stay idle for the full $staleRestartMinutes (>= the DSC
                        # consistency-engine interval) before concluding it is wedged, so the LCM gets a
                        # complete chance to auto-rerun its configuration on its own before we reboot. A
                        # momentary idle (a step that just completed, or the gap between DSC resources) resets
                        # the idle clock on the next sample and never triggers a restart. This is intentionally
                        # independent of the status TEXT -- we never branch on what the status string says.
                        $staleMins = [int][Math]::Floor(([DateTime]::UtcNow - $lastStatusChangeTime).TotalMinutes)

                        # Sample the LCM (throttled to once/min; we do NOT poll the guest on every ~3s
                        # heartbeat) once the status has been stalled past the probe threshold.
                        if ($staleMins -ge $lcmProbeStartMinutes -and ([DateTime]::UtcNow - $lastLcmSampleTime).TotalSeconds -ge 60) {
                            $lastLcmSampleTime = [DateTime]::UtcNow
                            # Sample LCMState AND the last apply's RebootRequested flag in one guest round-trip.
                            # Per the Windows DSC LCM source (EngineHelper.c GetLCMState): LCMState reports
                            # 'PendingConfiguration' whenever a pending.mof exists on disk, and 'PendingReboot'
                            # is the IN-MEMORY state set right after a resource sets DSCMachineStatus=1 -- a fresh
                            # query process reads from disk and sees PendingConfiguration. Neither word alone
                            # proves a reboot is needed, so we also read Get-DscConfigurationStatus.RebootRequested
                            # (the recorded fact that the last apply asked for a restart). Get-DscConfigurationStatus
                            # throws while the LCM is Busy, so a populated RebootRequested also implies 'not Busy'.
                            $lcmCheck = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 30 -ScriptBlock {
                                $st = try { (Get-DscLocalConfigurationManager -ErrorAction Stop).LCMState } catch { 'unreachable' }
                                $rr = $false
                                try { $rr = [bool]((Get-DscConfigurationStatus -ErrorAction Stop | Select-Object -First 1).RebootRequested) } catch { }
                                [PSCustomObject]@{ LCMState = $st; RebootRequested = $rr }
                            } -SuppressLog
                            $lcmReadable = (-not $lcmCheck.ScriptBlockFailed) -and $lcmCheck.ScriptBlockOutput
                            $lcmState = if ($lcmReadable) { [string]$lcmCheck.ScriptBlockOutput.LCMState } else { 'unreachable' }
                            $rebootRequested = $lcmReadable -and $lcmCheck.ScriptBlockOutput.RebootRequested
                            # A reboot is genuinely OWED only when the last apply asked for one (RebootRequested)
                            # or the in-memory state is PendingReboot. A bare PendingConfiguration (pending.mof on
                            # disk) with RebootRequested=False is a STRANDED apply -- interrupted mid-flight, NOT
                            # waiting on a restart; and because every phase config runs ConfigurationMode=ApplyOnly,
                            # the consistency engine never auto-reruns, so it sits there forever unless we resume it.
                            $needsReboot = $lcmReadable -and ($rebootRequested -or ($lcmState -eq 'PendingReboot'))
                            $pendingNoReboot = $lcmReadable -and ($lcmState -eq 'PendingConfiguration') -and -not $needsReboot
                            if ($lcmReadable -and $lcmState -eq 'Idle') {
                                # Idle this sample -- start the idle clock on the FIRST idle observation.
                                if (-not $lcmIdleSince) { $lcmIdleSince = [DateTime]::UtcNow }
                                $lcmRebootPendingSince = $null
                                $lcmPendingNoRebootSince = $null
                            }
                            elseif ($needsReboot) {
                                # Parked waiting for a reboot that's actually owed -- start the reboot-stuck clock.
                                if (-not $lcmRebootPendingSince) { $lcmRebootPendingSince = [DateTime]::UtcNow }
                                $lcmIdleSince = $null
                                $lcmPendingNoRebootSince = $null
                            }
                            elseif ($pendingNoReboot) {
                                # Stranded apply (pending.mof on disk, no reboot owed) -- start the pending clock.
                                if (-not $lcmPendingNoRebootSince) { $lcmPendingNoRebootSince = [DateTime]::UtcNow }
                                $lcmIdleSince = $null
                                $lcmRebootPendingSince = $null
                            }
                            else {
                                # Busy (actively applying) or unreadable (can't confirm) -> reset all clocks. Not stuck.
                                $lcmIdleSince = $null
                                $lcmRebootPendingSince = $null
                                $lcmPendingNoRebootSince = $null
                            }
                        }

                        # [int] ROUNDS in PowerShell, so [int]3.6 == 4 -- every one of these clocks used to
                        # trip ~30s early and report a minute more than had elapsed. Floor them.
                        $idleMins = if ($lcmIdleSince) { [int][Math]::Floor(([DateTime]::UtcNow - $lcmIdleSince).TotalMinutes) } else { 0 }
                        $rebootMins = if ($lcmRebootPendingSince) { [int][Math]::Floor(([DateTime]::UtcNow - $lcmRebootPendingSince).TotalMinutes) } else { 0 }
                        $pendingMins = if ($lcmPendingNoRebootSince) { [int][Math]::Floor(([DateTime]::UtcNow - $lcmPendingNoRebootSince).TotalMinutes) } else { 0 }

                        if ($lcmRebootPendingSince -and $rebootMins -ge $rebootPendingStuckMinutes -and $staleRestartCount -lt $staleRestartMax) {
                            # The LCM has been parked reboot-pending (PendingReboot / PendingConfiguration /
                            # RebootRequested) with the status frozen for the confirmation window -- the restart
                            # DSC scheduled never fired. Observed on Win10/11 client renames, where the LCM logs
                            # 'A reboot is scheduled to progress further' but the box never restarts, leaving the
                            # whole phase waiting forever. Unlike a Busy LCM, a reboot-pending park is literally
                            # asking for a restart, so a host reboot is the correct, non-destructive recovery -- it
                            # lets the LCM resume from pending.mof. Respect a running ScriptWorkflow task (Phase 8/9
                            # can legitimately hold a reboot-pending state while a task does background work).
                            $swTaskRunning = $false
                            $swCheck = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 30 -ScriptBlock {
                                $t = Get-ScheduledTask -TaskName 'ScriptWorkflow' -ErrorAction SilentlyContinue
                                if ($t -and $t.State -eq 'Running') { 'Running' } else { $null }
                            } -SuppressLog
                            if (-not $swCheck.ScriptBlockFailed -and $swCheck.ScriptBlockOutput -eq 'Running') {
                                $swTaskRunning = $true
                            }
                            if ($swTaskRunning) {
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: LCM reboot-pending ${rebootMins}m but ScriptWorkflow task is still running. Not restarting." -Warning
                                $lcmRebootPendingSince = [DateTime]::UtcNow   # task is doing work -- restart the reboot-pending window
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                            else {
                                $staleRestartCount++
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: LCM parked reboot-pending ($lcmState) for ${rebootMins}m with status unchanged for ${staleMins}m ('$($currentStatus.Trim())'). The DSC-scheduled reboot never fired -- restarting VM to let the LCM resume (attempt $staleRestartCount/$staleRestartMax)." -Warning -OutputStream
                                Restart-VM2Smart -Name $currentItem.vmName -AllowTurnOff -Reason "DSC reboot-pending stuck" -Stopwatch $stopWatch -Timespan $timespan | Out-Null
                                $lastStatusChangeTime = [DateTime]::UtcNow
                                $lcmRebootPendingSince = $null
                                $lcmIdleSince = $null
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                        }
                        elseif ($lcmPendingNoRebootSince -and $pendingMins -ge $rebootStuckMinutes -and ((($dscResumeCount -lt $dscResumeMax) -and ($dscResumeTotal -lt $dscResumeTotalMax)) -or $staleRestartCount -lt $staleRestartMax)) {
                            # Stranded PendingConfiguration with NO reboot owed (pending.mof staged, last apply
                            # didn't request a restart). In ApplyOnly mode nothing auto-resumes it. Tier 1: resume
                            # the pending config IN PLACE via Stop + Start-DscConfiguration -UseExisting (no reboot --
                            # pending.mof is already on disk). Tier 2 (if it's STILL stranded a window later): restart
                            # the VM so the boot-resume path re-applies pending.mof. Respect a running ScriptWorkflow task.

                            # SQL install stall: when DSC_SqlSetup fails it re-stages pending.mof, so a SQL-install
                            # stall shows up here as a stranded PendingConfiguration. Pull the SQL Setup Summary.txt
                            # (and the referenced component log) into the build log so the operator sees the ACTUAL
                            # setup error instead of just the frozen "Installing 'SQL Server ...'" status. On a
                            # non-recoverable failure -- corrupt install media (MSI 1335 'the cabinet file ... is
                            # corrupt') -- every resume re-reads the same bad file and loops until the phase times
                            # out, so fail the VM fast with a clear remediation instead of resuming.
                            if (-not $sqlSetupSummaryDumped -and $currentStatus -match 'SQL Server') {
                                $sqlSum = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 60 -ScriptBlock {
                                    $sum = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' -ErrorAction SilentlyContinue |
                                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                                    if (-not $sum) { return $null }
                                    $text = @(Get-Content -LiteralPath $sum.FullName -ErrorAction SilentlyContinue)
                                    $grab = { param($rx) @($text | Where-Object { $_ -match $rx }) }
                                    $exit = (& $grab 'Exit code \(Decimal\):|Exit code \(HRESULT\):' | Select-Object -First 2) -join ' | '
                                    $final = & $grab 'Final result:'
                                    $compErr = & $grab 'Component error code:'
                                    $errDesc = & $grab 'Error description:'
                                    $compLog = @(& $grab 'Component log file:' | ForEach-Object { ($_ -split ':', 2)[1].Trim() })
                                    $compTail = $null
                                    if ($compLog.Count -gt 0 -and (Test-Path -LiteralPath $compLog[0])) {
                                        $compTail = (@(Get-Content -LiteralPath $compLog[0] -Tail 40 -ErrorAction SilentlyContinue)) -join "`r`n"
                                    }
                                    $hard = $false
                                    foreach ($d in $errDesc) { if ($d -match 'corrupt|cannot be used|cabinet') { $hard = $true } }
                                    foreach ($c in $compErr) { if ($c -match '(^|\D)1335(\D|$)') { $hard = $true } }
                                    [pscustomobject]@{
                                        Path      = $sum.FullName
                                        LastWrite = $sum.LastWriteTime
                                        Fresh     = ($sum.LastWriteTime -gt (Get-Date).AddMinutes(-60))
                                        Exit      = ("" + $exit).Trim()
                                        Final     = ("" + ($final | Select-Object -First 1)).Trim()
                                        CompErr   = (($compErr | ForEach-Object { $_.Trim() }) -join '; ')
                                        ErrDesc   = (($errDesc | ForEach-Object { $_.Trim() }) -join '; ')
                                        CompLog   = ($compLog -join '; ')
                                        CompTail  = $compTail
                                        IsHard    = $hard
                                        Full      = ($text -join "`r`n")
                                    }
                                } -SuppressLog
                                if (-not $sqlSum.ScriptBlockFailed -and $sqlSum.ScriptBlockOutput) {
                                    $s = $sqlSum.ScriptBlockOutput
                                    $sqlSetupSummaryDumped = $true
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): SQL Setup FAILED. $($s.Final); $($s.Exit); $($s.CompErr); $($s.ErrDesc); log: $($s.CompLog)" -Warning -OutputStream
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): SQL Setup Summary.txt ($($s.Path), written $($s.LastWrite)):`r`n$($s.Full)" -LogOnly
                                    if ($s.CompTail) { Write-Log "[Phase $Phase]: $($currentItem.vmName): SQL Setup component log tail:`r`n$($s.CompTail)" -LogOnly }
                                    if ($s.IsHard -and $s.Fresh) {
                                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: $($currentItem.role) failed: SQL Server setup hit a NON-RECOVERABLE error ($($s.ErrDesc)) -- resuming would loop on the same fault. This is corrupt install media: verify/replace the SQL ISO (its cabinet is corrupt), then re-run Phase $Phase." -Failure -OutputStream
                                        break
                                    }
                                }
                            }

                            $swTaskRunning = $false
                            $swCheck = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 30 -ScriptBlock {
                                $t = Get-ScheduledTask -TaskName 'ScriptWorkflow' -ErrorAction SilentlyContinue
                                if ($t -and $t.State -eq 'Running') { 'Running' } else { $null }
                            } -SuppressLog
                            if (-not $swCheck.ScriptBlockFailed -and $swCheck.ScriptBlockOutput -eq 'Running') {
                                $swTaskRunning = $true
                            }
                            if ($swTaskRunning) {
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: LCM PendingConfiguration ${pendingMins}m but ScriptWorkflow task is still running. Not intervening." -Warning
                                $lcmPendingNoRebootSince = [DateTime]::UtcNow   # task is doing work -- restart the window
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                            elseif (($dscResumeCount -lt $dscResumeMax) -and ($dscResumeTotal -lt $dscResumeTotalMax)) {
                                # TIER 1: gentle in-place resume (fire-and-forget, bounded). No reboot.
                                $dscResumeCount++
                                $dscResumeTotal++
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: LCM stranded PendingConfiguration for ${pendingMins}m (no reboot owed) with status unchanged for ${staleMins}m ('$($currentStatus.Trim())'). Resuming the pending config in place: Stop + Start-DscConfiguration -UseExisting (resume $dscResumeCount/$dscResumeMax this stall, $dscResumeTotal/$dscResumeTotalMax this phase)." -Warning -OutputStream
                                # Capture the tail of the guest's most recent DSC ConfigurationStatus record
                                # (C:\Windows\System32\Configuration\ConfigurationStatus\*.json -- the actual last
                                # LCM run, what Get-DscConfigurationStatus reads) so the build log shows which
                                # resource the last apply died on before we resume it.
                                $dscEventsTail = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 30 -ScriptBlock {
                                    $scPath = Join-Path $env:windir 'System32\Configuration\ConfigurationStatus'
                                    $f = Get-ChildItem -Path $scPath -Filter *.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                                    if (-not $f) { return $null }
                                    $lines = $null
                                    try {
                                        # The LCM may hold the file open; open shared read/write so we can still read it.
                                        $fs = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                                        try {
                                            $sr = New-Object System.IO.StreamReader($fs)
                                            $lines = ($sr.ReadToEnd() -split "`r?`n")
                                            $sr.Dispose()
                                        }
                                        finally { $fs.Dispose() }
                                    }
                                    catch {
                                        $lines = Get-Content -Path $f.FullName -ErrorAction SilentlyContinue
                                    }
                                    $tail = ($lines | Select-Object -Last 10) -join "`r`n"
                                    [pscustomobject]@{ File = $f.Name; LastWrite = $f.LastWriteTime; Tail = $tail }
                                } -SuppressLog
                                if (-not $dscEventsTail.ScriptBlockFailed -and $dscEventsTail.ScriptBlockOutput) {
                                    $sbo = $dscEventsTail.ScriptBlockOutput
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: last ConfigurationStatus record $($sbo.File) (written $($sbo.LastWrite)); last 10 lines:`r`n$($sbo.Tail)" -LogOnly
                                }
                                else {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: could not read the last ConfigurationStatus record at stranded point." -LogOnly
                                }
                                $null = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 60 -ScriptBlock {
                                    Stop-DscConfiguration -Force -ErrorAction SilentlyContinue
                                    Start-DscConfiguration -UseExisting -Force -ErrorAction SilentlyContinue
                                } -SuppressLog
                                $lcmPendingNoRebootSince = [DateTime]::UtcNow   # give the resume a window to apply before escalating
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                            else {
                                # TIER 2: the in-place resume did not clear it -- escalate to a VM restart.
                                $staleRestartCount++
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: in-place resume did not clear the stranded PendingConfiguration (${pendingMins}m) -- restarting VM so the boot-resume path re-applies pending.mof (attempt $staleRestartCount/$staleRestartMax)." -Warning -OutputStream
                                Restart-VM2Smart -Name $currentItem.vmName -AllowTurnOff -Reason "DSC stranded PendingConfiguration" -Stopwatch $stopWatch -Timespan $timespan | Out-Null
                                $lastStatusChangeTime = [DateTime]::UtcNow
                                $lcmPendingNoRebootSince = $null
                                $lcmIdleSince = $null
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                        }
                        elseif ($lcmIdleSince -and $idleMins -ge $staleRestartMinutes -and $staleRestartCount -lt $staleRestartMax) {
                            # LCM has been continuously idle for >= the restart window (it had a full
                            # consistency-engine cycle to auto-rerun and did not). Before rebooting, check the
                            # ScriptWorkflow task -- Phase 8/9 keep a scheduled task running after DSC goes
                            # idle (e.g. during WSUS sync waits); restarting would kill it mid-work.
                            $swTaskRunning = $false
                            $swCheck = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 30 -ScriptBlock {
                                $t = Get-ScheduledTask -TaskName 'ScriptWorkflow' -ErrorAction SilentlyContinue
                                if ($t -and $t.State -eq 'Running') { 'Running' } else { $null }
                            } -SuppressLog
                            if (-not $swCheck.ScriptBlockFailed -and $swCheck.ScriptBlockOutput -eq 'Running') {
                                $swTaskRunning = $true
                            }
                            if ($swTaskRunning) {
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: LCM idle ${idleMins}m but ScriptWorkflow task is still running. Not restarting." -Warning
                                $lcmIdleSince = [DateTime]::UtcNow   # task is doing work -- restart the idle window
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                            else {
                                # Genuinely stuck: LCM idle >= $staleRestartMinutes, status frozen, no task running.
                                $staleRestartCount++
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: LCM idle for ${idleMins}m with status unchanged for ${staleMins}m ('$($currentStatus.Trim())'). Restarting VM (attempt $staleRestartCount/$staleRestartMax)." -Warning -OutputStream
                                Restart-VM2Smart -Name $currentItem.vmName -AllowTurnOff -Reason "stale LCM/status" -Stopwatch $stopWatch -Timespan $timespan | Out-Null
                                $lastStatusChangeTime = [DateTime]::UtcNow
                                $lcmIdleSince = $null
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                        }
                        elseif ($staleMins -ge $staleWarningMinutes -and ([DateTime]::UtcNow - $lastStaleWarningTime).TotalMinutes -ge 5) {
                            $idleNote = if ($lcmIdleSince) { " (LCM idle ${idleMins}m)" } elseif ($lcmRebootPendingSince) { " (LCM reboot-pending ${rebootMins}m)" } elseif ($lcmPendingNoRebootSince) { " (LCM PendingConfiguration ${pendingMins}m)" } else { " (LCM busy/applying)" }
                            # A busy LCM with a frozen status is normally a resource mid-work, but it is
                            # also exactly what a DEAD ScriptWorkflow looks like: WaitForEvent keeps the
                            # LCM busy polling a json nothing is writing any more. The idle branch above
                            # already probes the task; this is the blind spot, so name it here.
                            $workflowNote = ''
                            if (-not $lcmIdleSince -and -not $lcmRebootPendingSince -and -not $lcmPendingNoRebootSince) {
                                $swStale = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 30 -ScriptBlock {
                                    $t = Get-ScheduledTask -TaskName 'ScriptWorkflow' -ErrorAction SilentlyContinue
                                    if ($t) { "$($t.State)" } else { $null }
                                } -SuppressLog
                                if (-not $swStale.ScriptBlockFailed -and $swStale.ScriptBlockOutput -and $swStale.ScriptBlockOutput -ne 'Running') {
                                    $workflowNote = " -- ScriptWorkflow task is '$($swStale.ScriptBlockOutput)', NOT Running: the workflow exited without finishing, so this wait cannot clear on its own."
                                }
                            }
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Status unchanged for ${staleMins}m${idleNote} ('$($currentStatus.Trim())')${workflowNote}" -Warning
                            $lastStaleWarningTime = [DateTime]::UtcNow
                        }
                    }

                    # Special case to write log ConfigMgrSetup.log entries in progress
                    $skipProgress = $false
                    $setupPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
                    if ($currentStatus.StartsWith($setupPrefix)) {
                        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content "C:\ConfigMgrSetup.log" -tail 1 } -SuppressLog
                        if (-not $result.ScriptBlockFailed) {
                            $logEntry = $result.ScriptBlockOutput
                            # Get-Content -Tail 1 can return an array; collapse to a single string
                            if ($logEntry -is [array]) { $logEntry = $logEntry[-1] }
                            $skipProgress = $true
                            if (-not [string]::IsNullOrWhiteSpace($logEntry)) {
                                try {
                                    if ($logEntry -is [string] -and $logEntry.Contains("$")) {
                                        $logEntry = "ConfigMgrSetup.log: " + $logEntry.Substring(0, $logEntry.IndexOf("$"))
                                    }
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $logEntry
                                }
                                catch {
                                    # write-Log -LogOnly "[Phase $Phase]: $($currentItem.vmName): Failed SubString for ConfigMgrSetup.log in for line: $logEntry : $_"
                                }
                            }
                        }
                    }

                    # Special case: tail SQL Server setup log during installation
                    if (-not $skipProgress -and $currentStatus -match "^Installing '.*SQL Server") {
                        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                            # Find the most recent Detail.txt under Setup Bootstrap
                            $logDirs = @(Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\*\Detail.txt' -ErrorAction SilentlyContinue |
                                Sort-Object LastWriteTime -Descending)
                            if ($logDirs.Count -gt 0) {
                                # Skip stale logs from previous runs (older than 5 min)
                                if ($logDirs[0].LastWriteTime -lt (Get-Date).AddMinutes(-5)) { return $null }
                                # Read the last few lines and skip telemetry noise
                                $tailLines = @(Get-Content $logDirs[0].FullName -Tail 5 -ErrorAction SilentlyContinue)
                                for ($i = $tailLines.Count - 1; $i -ge 0; $i--) {
                                    if ([string]::IsNullOrWhiteSpace($tailLines[$i])) { continue }
                                    if ($tailLines[$i] -notmatch 'telemetry|usage and performance data') {
                                        $last = $tailLines[$i]; break
                                    }
                                }
                                if (-not $last) { return $null }
                                if ($last -match 'Running Action:\s*(.+)') { return "SQL Setup: $($Matches[1].Trim())" }
                                if ($last -match ':\s*([^:]+)$') { return "SQL Setup: $($Matches[1].Trim())" }
                                return "SQL Setup: $last"
                            }
                            # Fallback: Summary.txt (also check staleness)
                            $summaryFiles = @(Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' -ErrorAction SilentlyContinue |
                                Sort-Object LastWriteTime -Descending)
                            if ($summaryFiles.Count -gt 0 -and $summaryFiles[0].LastWriteTime -ge (Get-Date).AddMinutes(-5)) {
                                return "SQL Setup: " + (Get-Content $summaryFiles[0].FullName -Tail 1 -ErrorAction SilentlyContinue)
                            }
                        } -SuppressLog
                        if (-not $result.ScriptBlockFailed -and -not [string]::IsNullOrWhiteSpace($result.ScriptBlockOutput)) {
                            $skipProgress = $true
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $result.ScriptBlockOutput
                        }
                    }

                    if (-not $skipProgress) {
                        # Write progress
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $statusTextSnapshot
                    }

                    # Check if complete
                    $complete = $statusTextSnapshot -eq "Complete!"
                    if (-not $complete) {
                        $complete = $statusTextSnapshot -eq "Setting up ConfigMgr. Status: Complete!"
                    }
                    # Authoritative path: ScriptWorkflow.ps1 echoes our per-deploy RunId into
                    # ScriptWorkflow.completed.runid only after ALL its post-install scripts
                    # finish. Immune to status-string overwrites and stale state from prior deploys.
                    if (-not $complete -and $expectedRunId -and $completedRunIdSnapshot -eq $expectedRunId) {
                        $complete = $true
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Completion confirmed via RunId match ($expectedRunId)"
                    }
                    if (-not $complete) {
                        #$complete = ($dscStatus.ScriptBlockOutput -and $dscStatus.ScriptBlockOutput.Status -eq "Success")
                    }

                    $bailEarly = $false
                    # Check ConfigMgrSetup.log for fatal errors in a single PSDirect call.
                    # The in-VM script renames any prior ConfigMgrSetup.log before each
                    # setup.exe launch, so errors here are always from the current run.
                    # Prereq failures are NOT checked here — the guest script
                    # (InstallAndUpdateSCCM.ps1) handles prereq retries internally
                    # by renaming the log and re-launching setup.exe. If the retry
                    # also fails, the guest writes a JOBFAILURE status that the
                    # normal monitoring loop above detects.
                    #
                    # Also pull a wider context window when a fatal is seen so we
                    # can recognize specific failure shapes (e.g. SQLAO Init_Database
                    # AGWaitForSynchronizationHealth) and emit actionable guidance.
                    #
                    # Live SQLAO stuck-replica detection: while ConfigMgr is inside
                    # AGWaitForSynchronizationHealth (the ~15min budget), it logs one
                    # 'AG replica X ... Operational State: UNKNOWN, Recovery Health
                    # UNKNOWN, Synchronization Health: NOT_HEALTHY' line every 15s.
                    # Each line carries its own timestamp in the CMTrace tail
                    # ($$<Configuration Manager Setup><MM-dd-yyyy HH:mm:ss.fff+TZ>).
                    # If the same replica is reported stuck across a span of >= 5 min
                    # without recovery, the only reliable in-place fix is to bounce
                    # the SQL service on that replica so its recovery thread starts
                    # fresh. We do that ONCE per deploy and let setup.exe observe
                    # HEALTHY on its next poll (CM still has ~10 min of budget left).
                    $cmLogCheck = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -SuppressLog -ScriptBlock {
                        if (Test-Path C:\ConfigMgrSetup.log) {
                            $tail = Get-Content C:\ConfigMgrSetup.log -tail 30
                            $hit  = $tail | Select-String "Failed Configuration Manager Server Setup|fatal errors|cannot be completed|doesn't have administrative rights" | Select-Object -First 1

                            # Stuck-replica probe: scan a wider tail (~25 min worth at
                            # 15s cadence) and find replicas whose UNKNOWN-state span
                            # is the longest. Returns the worst (longest-stuck) replica.
                            $stuckTail   = Get-Content C:\ConfigMgrSetup.log -tail 200 -ErrorAction SilentlyContinue
                            $rxStuck     = [regex]'AG replica (\S+) in group .+ is not ready - Operational State: UNKNOWN, Connected State: \S+, Recovery Health UNKNOWN, Synchronization Health: NOT_HEALTHY.*?\$\$<Configuration Manager Setup><(\d{2}-\d{2}-\d{4} \d{2}:\d{2}:\d{2}\.\d{3})'
                            $rxRecovered = [regex]'AGWaitForSynchronizationHealth - Availability group .+ is now healthy\.\s*\$\$<Configuration Manager Setup><(\d{2}-\d{2}-\d{4} \d{2}:\d{2}:\d{2}\.\d{3})'
                            $stuckByVm   = @{}
                            $lastHealthy = [datetime]::MinValue
                            foreach ($line in $stuckTail) {
                                $hm = $rxRecovered.Match($line)
                                if ($hm.Success) {
                                    $t = [datetime]::ParseExact($hm.Groups[1].Value,'MM-dd-yyyy HH:mm:ss.fff',$null)
                                    if ($t -gt $lastHealthy) { $lastHealthy = $t }
                                    continue
                                }
                                $sm = $rxStuck.Match($line)
                                if ($sm.Success) {
                                    $name = $sm.Groups[1].Value
                                    $t    = [datetime]::ParseExact($sm.Groups[2].Value,'MM-dd-yyyy HH:mm:ss.fff',$null)
                                    if (-not $stuckByVm.ContainsKey($name)) {
                                        $stuckByVm[$name] = [pscustomobject]@{ First = $t; Last = $t; Count = 1 }
                                    }
                                    else {
                                        $entry = $stuckByVm[$name]
                                        if ($t -lt $entry.First) { $entry.First = $t }
                                        if ($t -gt $entry.Last)  { $entry.Last  = $t }
                                        $entry.Count++
                                    }
                                }
                            }
                            # Discard any entry whose First < lastHealthy: that's a stale
                            # window from a prior failover the AG already recovered from.
                            $stuckOut = $null
                            foreach ($kv in $stuckByVm.GetEnumerator()) {
                                if ($kv.Value.First -lt $lastHealthy) { continue }
                                $spanMin = ($kv.Value.Last - $kv.Value.First).TotalMinutes
                                if ($null -eq $stuckOut -or $spanMin -gt $stuckOut.SpanMinutes) {
                                    $stuckOut = [pscustomobject]@{
                                        Replica     = $kv.Key
                                        SpanMinutes = [math]::Round($spanMin, 2)
                                        First       = $kv.Value.First
                                        Last        = $kv.Value.Last
                                        Count       = $kv.Value.Count
                                    }
                                }
                            }

                            if ($hit -or $stuckOut) {
                                [pscustomobject]@{
                                    Line    = if ($hit) { $hit.Line } else { $null }
                                    Context = ($tail -join "`n")
                                    Stuck   = $stuckOut
                                }
                            }
                        }
                    }
                    if ($cmLogCheck.ScriptBlockOutput.Line) {
                        $failEntry   = $cmLogCheck.ScriptBlockOutput.Line
                        $failContext = $cmLogCheck.ScriptBlockOutput.Context
                        $bailEarly = $true
                    }

                    # Live SQLAO auto-remediation: if a replica has been UNKNOWN for >= 5 min
                    # within the current AGWait window (and we haven't already remediated this
                    # deploy), restart SQL on that replica. CM Setup will observe HEALTHY on its
                    # next poll and finish Init_Database. ONE-SHOT to avoid bounce loops.
                    if (-not $bailEarly -and -not $sqlaoStuckRemediated -and $cmLogCheck.ScriptBlockOutput.Stuck) {
                        $stuck = $cmLogCheck.ScriptBlockOutput.Stuck
                        if ($stuck.SpanMinutes -ge 5) {
                            $stuckVmName = [string]$stuck.Replica
                            # The replica name in the log is the SQL Server's NETBIOS / computer name,
                            # which equals the VM name in memlabs. Confirm we own it before acting.
                            $vmIsOurs = $false
                            if ($deployConfig -and $deployConfig.virtualMachines) {
                                $vmIsOurs = [bool]($deployConfig.virtualMachines | Where-Object { $_.vmName -eq $stuckVmName })
                            }
                            if (-not $vmIsOurs) {
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): SQLAO auto-remediate: replica '$stuckVmName' has been UNKNOWN for $($stuck.SpanMinutes) min in ConfigMgrSetup.log, but no VM by that name is in the deploy config. Skipping remediation; will bail-early when CM Setup gives up." -Warning
                                $sqlaoStuckRemediated = $true
                            }
                            else {
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): SQLAO auto-remediate: replica '$stuckVmName' has been Op=UNKNOWN/Rec=UNKNOWN/Sync=NOT_HEALTHY for $($stuck.SpanMinutes) min ($($stuck.Count) consecutive AGWaitForSynchronizationHealth poll(s) in ConfigMgrSetup.log). Restarting SQL on '$stuckVmName' to clear the stuck recovery thread." -Warning -OutputStream
                                $bounceResult = Invoke-VmCommand -VmName $stuckVmName -VmDomainName $domainName -DisplayName "SQLAO auto-remediate: bounce SQL on $stuckVmName" -ScriptBlock {
                                    $svc = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
                                    if (-not $svc) {
                                        $svc = Get-Service -Name 'MSSQL$*' -ErrorAction SilentlyContinue | Select-Object -First 1
                                    }
                                    if (-not $svc) { return [pscustomobject]@{ Ok = $false; Error = 'No MSSQLSERVER service found' } }
                                    $svcName = $svc.Name
                                    try {
                                        Restart-Service -Name $svcName -Force -ErrorAction Stop
                                        # Don't restart SQLSERVERAGENT explicitly — it has Restart-Service dependency
                                        # behavior and will be restarted as part of the SQL stop.
                                        return [pscustomobject]@{ Ok = $true; Service = $svcName }
                                    }
                                    catch {
                                        return [pscustomobject]@{ Ok = $false; Service = $svcName; Error = $_.Exception.Message }
                                    }
                                }
                                $sqlaoStuckRemediated = $true
                                if ($bounceResult.ScriptBlockFailed -or -not $bounceResult.ScriptBlockOutput -or -not $bounceResult.ScriptBlockOutput.Ok) {
                                    $errMsg = if ($bounceResult.ScriptBlockOutput) { $bounceResult.ScriptBlockOutput.Error } else { 'no output' }
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): SQLAO auto-remediate: SQL restart on '$stuckVmName' FAILED: $errMsg. CM Setup will likely bail with 'did not return to a healthy state' once its 15min budget expires." -Warning -OutputStream
                                }
                                else {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): SQLAO auto-remediate: restarted '$($bounceResult.ScriptBlockOutput.Service)' on '$stuckVmName'. AG should re-converge within ~90s; CM Setup's AGWaitForSynchronizationHealth poll will pick HEALTHY on its next 15s tick." -OutputStream
                                }
                            }
                        }
                    }

                    if ($bailEarly) {
                        if ($failEntry -is [string] -and $failEntry.Contains("$")) {
                            $failEntry = $failEntry.Substring(0, $failEntry.IndexOf("$"))
                        }
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: $($currentItem.role) failed: $failEntry. Check C:\ConfigMgrSetup.log for more." -Failure -OutputStream
                        # Recognize the SQLAO Init_Database AG wait-for-health timeout
                        # and surface explicit remediation. CM Setup creates the site
                        # database BEFORE the failover/failback, so a blind retry
                        # against a partial install is unsafe — checkpoint restore is
                        # required. A SQL restart on the secondary almost always
                        # un-sticks an UNKNOWN-state replica after the failback.
                        if ($failContext -and (
                                $failContext -match 'did not return to a healthy state in the alloted time' -or
                                $failContext -match 'Init_Database \(AG\) - Something went wrong waiting for synchronization' -or
                                $failContext -match 'AGWaitForSynchronizationHealth'
                            )) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG: SQLAO Init_Database failure detected. ConfigMgr Setup failed over to the secondary to set db_owner, failed back to the primary, and the secondary replica did not re-converge to HEALTHY/SYNCHRONIZED within ConfigMgr's ~15min budget." -OutputStream
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DIAG: The CM site DB is partially committed (created before the failover); re-running setup.exe is unsafe. Restore the Phase 8 checkpoint on this VM, then before redeploying restart the SQL service on the SQLAO secondary node (the one that was UNKNOWN in ConfigMgrSetup.log) to clear the stuck replica state-machine, wait ~2 min for AG to report HEALTHY on both replicas, then resume Phase 8. The new pre-flight AG stability gate will hold setup.exe until the AG has been HEALTHY for 60s, which prevents this in most cases." -OutputStream
                        }
                        if ($using:Phase -eq 8 -and $currentItem.role -in @('CAS', 'Primary', 'Secondary', 'PassiveSite')) {
                            Save-CMSetupLogsFromVm -VmName $currentItem.vmName -DomainName $domainName -Phase $using:Phase -Mode 'Failure'
                        }
                        return
                    }
                }
                else {
                    if ($noStatus) {
                        if ($failedHeartbeats -eq 0) {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Waiting for job progress. Polls: $dscStatusPolls Status: $($dscStatus.ScriptBlockOutput.Status)"
                        }
                        else {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Waiting for job progress. Failed Heartbeats: $failedHeartbeats Polls: $dscStatusPolls  Status: $($dscStatus.ScriptBlockOutput.Status)"
                        }
                    }
                    else {
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $currentStatus
                    }

                }

            } until ($complete -or ($stopWatch.Elapsed -ge $timeSpan))
        }
        catch {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Monitoring Exception (See Logs): $_" -Failure -OutputStream
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)" -LogOnly
            Write-Progress2 "Exception" -Status "Failed end $_" -force
            if ($using:Phase -eq 8 -and $currentItem.role -in @('CAS', 'Primary', 'Secondary', 'PassiveSite')) {
                Save-CMSetupLogsFromVm -VmName $currentItem.vmName -DomainName $domainName -Phase $using:Phase -Mode 'Failure'
            }
            return
        }

        # Phase 8 CM-setup roles: pull ConfigMgrSetup.log + InstallCMLog.log
        # off the VM into the host log folder so operators don't have to RDP
        # in to read them. Full ConfigMgrSetup.log on failure (incl. timeout),
        # tail-5000 on success; InstallCMLog.log is always full.
        if ($using:Phase -eq 8 -and $currentItem.role -in @('CAS', 'Primary', 'Secondary', 'PassiveSite')) {
            $cmLogMode = if ($complete) { 'Success' } else { 'Failure' }
            Save-CMSetupLogsFromVm -VmName $currentItem.vmName -DomainName $domainName -Phase $using:Phase -Mode $cmLogMode
        }


        if ($using:Phase -eq 2) {
            # NLA Service starts before domain is ready sometimes, and causes RDP to fail because network is considered public by firewall.
            if ($currentItem.role -eq "WorkgroupMember" -or $currentItem.role -eq "InternetClient" -or $currentItem.role -eq "AADClient") {
                $netProfile = 1
            }
            else {
                $netProfile = 2
            } # 1 = Private, 2 = Domain

            $Trust_Ethernet = {
                param ($netProfile)
                Get-ChildItem -Force 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' -Recurse `
                | ForEach-Object { $_.PSChildName } `
                | ForEach-Object { Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\$($_)" -Name "Category" -Value $netProfile }
            }

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Trust_Ethernet -ArgumentList $netProfile -DisplayName "Set Ethernet as Trusted"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set Ethernet as Trusted. $($result.ScriptBlockOutput)" -Warning
            }

            $disable_StickyKeys = {
                Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Type String -Value "506"
                Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name "Flags" -Type String -Value "58"
                Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "Flags" -Type String -Value "122"
            }

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $disable_StickyKeys -DisplayName "Disable StickyKeys"

            # --- Windows Update lockdown + WSUS pre-configuration ---
            # Determine the correct WSUS server for this VM (real SUP, standalone WSUS, or fake localhost).
            # Skip if WSUS is already configured externally (check for our marker first to handle deploy restarts).
            $check_ExternalWsus = {
                $markerPath = "HKLM:\SOFTWARE\MemLabs"
                $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                $marker = Get-ItemProperty -Path $markerPath -Name "WsusSetByMemLabs" -ErrorAction SilentlyContinue
                if ($marker -and $marker.WsusSetByMemLabs -eq 1) {
                    return "OwnedByMemLabs"
                }
                $existing = Get-ItemProperty -Path $wuPath -Name "WUServer" -ErrorAction SilentlyContinue
                if ($existing -and $existing.WUServer) {
                    return "External"
                }
                return "NotSet"
            }

            $wsusCheckResult = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $check_ExternalWsus -DisplayName "Check existing WSUS config" -SuppressLog
            $wsusState = if ($wsusCheckResult.ScriptBlockOutput) { $wsusCheckResult.ScriptBlockOutput } else { "NotSet" }

            if ($wsusState -eq "External") {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): WSUS already configured externally, skipping WU lockdown"
            }
            else {
                # Resolve the WSUS URL for this VM
                $wsusInfo = Get-LabWsusUrl -DeployConfig $deployConfig -CurrentItem $currentItem
                $wsusUrl = $wsusInfo.WsusUrl
                $isRealWsus = $wsusInfo.IsRealWsus
                $wsusLabel = if ($isRealWsus) { "real SUP ($wsusUrl)" } else { "fake ($wsusUrl)" }
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Configuring WU lockdown with $wsusLabel"

                $configure_WindowsUpdate = {
                    param($WsusUrl, [int]$IsReal)
                    $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                    $auPath = "$wuPath\AU"
                    $mlPath = "HKLM:\SOFTWARE\MemLabs"

                    # Create registry paths
                    New-Item -Path $auPath -Force | Out-Null
                    New-Item -Path $mlPath -Force | Out-Null

                    # Blocking keys — prevent all WU internet access
                    New-ItemProperty -Path $wuPath -Name "DoNotConnectToWindowsUpdateInternetLocations" -PropertyType DWord -Value 1 -Force | Out-Null
                    New-ItemProperty -Path $wuPath -Name "DisableWindowsUpdateAccess" -PropertyType DWord -Value 1 -Force | Out-Null

                    # WSUS server redirection
                    New-ItemProperty -Path $wuPath -Name "WUServer" -PropertyType String -Value $WsusUrl -Force | Out-Null
                    New-ItemProperty -Path $wuPath -Name "WUStatusServer" -PropertyType String -Value $WsusUrl -Force | Out-Null

                    # AU policy
                    New-ItemProperty -Path $auPath -Name "UseWUServer" -PropertyType DWord -Value 1 -Force | Out-Null
                    New-ItemProperty -Path $auPath -Name "NoAutoUpdate" -PropertyType DWord -Value 1 -Force | Out-Null
                    New-ItemProperty -Path $auPath -Name "AUOptions" -PropertyType DWord -Value 2 -Force | Out-Null

                    # MemLabs markers for Phase 11 cleanup
                    New-ItemProperty -Path $mlPath -Name "WsusSetByMemLabs" -PropertyType DWord -Value 1 -Force | Out-Null
                    New-ItemProperty -Path $mlPath -Name "WsusIsReal" -PropertyType DWord -Value $IsReal -Force | Out-Null
                }

                $isRealInt = if ($isRealWsus) { 1 } else { 0 }
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $configure_WindowsUpdate -ArgumentList @($wsusUrl, $isRealInt) -DisplayName "Configure WU lockdown + WSUS ($wsusLabel)"
            }

            # Per-VM proxy client config. Runs inside this VM's Phase 2 job so
            # it parallelizes with every other VM's job instead of serial-looping
            # in the post-Phase-2 hook. No-op for VMs without useProxy=true and
            # for hard-excluded roles (handled inside Test-VmUsesProxy).
            try {
                if (Test-VmUsesProxy -Vm $currentItem -DeployConfig $deployConfig) {
                    $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
                    if (-not $proxyVm) {
                        $existingProxyName = Get-ExistingForDomain -DomainName $deployConfig.vmOptions.domainName -Role 'Proxy' | Select-Object -First 1
                        if ($existingProxyName) {
                            $proxyVm = [pscustomobject]@{ vmName = $existingProxyName; role = 'Proxy' }
                        }
                    }
                    if ($proxyVm) {
                        $proxyFqdn = "$($proxyVm.vmName).$($deployConfig.vmOptions.domainName)"
                        # Bypass this VM's OWN subnet; fall back to the deployment default
                        # only when the VM has no explicit network (e.g. default subnet).
                        $bypassNet = if ($currentItem.network) { $currentItem.network } else { $deployConfig.vmOptions.network }
                        $null = Set-WindowsClientProxy -VmName $currentItem.vmName -Domain $deployConfig.vmOptions.domainName `
                            -ProxyFqdn $proxyFqdn -BypassNetwork $bypassNet
                    }
                    else {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): useProxy=true but no Proxy VM in config or domain; skipping client config" -Warning
                    }
                }
            }
            catch {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Proxy client config failed: $_" -Warning
            }
        }

        # Update VMNote and set new version, this code doesn't run when VM_Create failed
        if ($using:Phase -gt 1 -and -not $currentItem.hidden) {

            # After Phase 5 DSC creates the failover cluster, the cluster
            # virtual adapter and heartbeat NIC may have registered in DNS.
            # Disable DNS registration on all non-domain adapters and scrub
            # the stale A records so the hostname only resolves to the domain IP.
            if ($Phase -eq 5 -and $currentItem.role -eq "SQLAO" -and $complete) {
                Write-Progress2 $Activity -Status "Cleaning heartbeat DNS records" -percentcomplete 98 -force
                $scrubDns = {
                    param($hostname, $nodeSubnet, $clusterVips, $nodeOwnIp)
                    $results = @()
                    # Watchdog: run a risky call under Start-ThreadJob (or Start-Job
                    # fallback) with a per-attempt timeout + retry, so a DC-side DNS
                    # cmdlet that hangs with no native timeout is KILLED instead of
                    # blocking the whole phase. Mirrors the validator's Invoke-WithWatchdog.
                    function Invoke-WithWatchdog {
                        param(
                            [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
                            [object[]] $ArgumentList = @(),
                            [int] $TimeoutSec = 20,
                            [int] $MaxAttempts = 2
                        )
                        $useThreadJob = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
                        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                            $job = $null
                            try {
                                $job = if ($useThreadJob) {
                                    Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
                                } else {
                                    Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
                                }
                                if (Wait-Job -Job $job -Timeout $TimeoutSec) {
                                    $jobErrors = $null
                                    $output = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors
                                    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
                                    $status = if ($jobErrors -and $jobErrors.Count -gt 0) { 'Error' } else { 'OK' }
                                    return [pscustomobject]@{ Status = $status; Output = $output }
                                }
                                try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
                                try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
                            }
                            catch {
                                if ($job) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {} }
                            }
                        }
                        return [pscustomobject]@{ Status = 'TimedOut'; Output = $null }
                    }
                    # Heartbeat / cluster NICs are the ONLY adapters that must never
                    # publish the host's name in DNS. Identify them POSITIVELY (an IP in
                    # a known heartbeat subnet, or a Cluster/isatap virtual adapter) and
                    # disable registration only on those. The previous logic disabled
                    # registration on every adapter NOT on the domain's *default* network
                    # (vmOptions.network) -- which on a node placed on a non-default
                    # network misclassified that node's own domain NIC as non-domain and
                    # killed its DNS registration, so the node never published its A record.
                    $clusterPrefixes = @('10.250.250.', '10.250.251.')
                    foreach ($adapter in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
                        $ips = @((Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress)
                        $isCluster = $false
                        foreach ($p in $clusterPrefixes) { if ($ips | Where-Object { $_ -like "$p*" }) { $isCluster = $true; break } }
                        if (-not $isCluster -and $adapter.InterfaceAlias -like '*Cluster*') { $isCluster = $true }
                        if ($isCluster) {
                            Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
                            $results += "Disabled DNS reg on heartbeat NIC '$($adapter.InterfaceAlias)' ($($ips -join ','))"
                        }
                    }
                    # Cluster virtual / isatap adapters not enumerated by Get-NetAdapter.
                    foreach ($iface in (Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                        if ($iface.InterfaceAlias -like '*Cluster*' -or $iface.InterfaceAlias -like '*isatap*') {
                            Set-DnsClient -InterfaceIndex $iface.ifIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
                        }
                    }
                    # Self-heal: ensure the DOMAIN NIC (the one carrying this node's own
                    # subnet IP) is ALLOWED to register, in case a prior buggy run disabled
                    # it -- then re-register so ONLY the node's own domain IP is published.
                    #
                    # CRITICAL: an AG node's domain NIC also carries the cluster core IP and
                    # the AG listener IP whenever this node owns those groups. Those VIPs must
                    # NOT register under the NODE's name (that yields round-robin DNS where the
                    # node name can resolve to a cluster VIP). Mark every VIP SkipAsSource first
                    # so the DNS client never publishes it under the computer name. A VIP is any
                    # domain-subnet address that is NOT the node's own IP -- confirmed by the
                    # passed-in node IP when known, else by an explicit VIP-list match or a
                    # static (PrefixOrigin=Manual) origin (the node's own IP is the DHCP
                    # reservation, PrefixOrigin=Dhcp).
                    $vipSet = @()
                    if ($clusterVips) { $vipSet = @($clusterVips | Where-Object { $_ }) }
                    foreach ($adapter in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
                        $addrs = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
                        $ips = @($addrs.IPAddress)
                        if (-not ($ips | Where-Object { $_ -like "$nodeSubnet*" })) { continue }
                        foreach ($addr in ($addrs | Where-Object { $_.IPAddress -like "$nodeSubnet*" })) {
                            if ($nodeOwnIp -and $addr.IPAddress -eq $nodeOwnIp) {
                                # The node's own IP must remain registrable.
                                if ($addr.SkipAsSource) {
                                    Set-NetIPAddress -InterfaceIndex $addr.InterfaceIndex -IPAddress $addr.IPAddress -SkipAsSource $false -ErrorAction SilentlyContinue
                                }
                                continue
                            }
                            # Everything else on the domain subnet is a cluster VIP. When the
                            # node's own IP is known, that's definitive; otherwise require an
                            # explicit-list match or a Manual origin so we never skip the node IP.
                            $isVip = $false
                            if ($nodeOwnIp) { $isVip = $true }
                            elseif ($vipSet -contains $addr.IPAddress) { $isVip = $true }
                            elseif ($addr.PrefixOrigin -eq 'Manual') { $isVip = $true }
                            if ($isVip -and -not $addr.SkipAsSource) {
                                Set-NetIPAddress -InterfaceIndex $addr.InterfaceIndex -IPAddress $addr.IPAddress -SkipAsSource $true -ErrorAction SilentlyContinue
                                $results += "Marked cluster VIP $($addr.IPAddress) SkipAsSource (won't register under node name)"
                            }
                        }
                        Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -RegisterThisConnectionsAddress $true -ErrorAction SilentlyContinue
                        $results += "Ensured DNS reg ENABLED on domain NIC '$($adapter.InterfaceAlias)' ($($ips -join ','))"
                    }
                    # Force re-registration so ONLY the domain adapter's own (non-skip) IP is published.
                    & ipconfig /registerdns 2>&1 | Out-Null
                    # Remove stale heartbeat A records for this hostname (keep the domain IP).
                    #
                    # Both the lookup and the delete go to the DC via Get/Remove-DnsServerResourceRecord
                    # -- CDXML/WMI cmdlets that open an implicit CIM session to the DC with NO native
                    # timeout. If the DC's WinRM/CIM is briefly wedged the call BLOCKS for the full outer
                    # Invoke-VmCommand budget (observed on FAB-CS1SQLAO1: DSC 'Complete!' then a multi-minute
                    # stall here). A bare try/catch only catches THROWS, not HANGS -- so (a) gate the
                    # expensive DC query behind a cheap, bounded local resolve and (b) run every DC-side
                    # DNS call under the kill-and-retry watchdog above.
                    try {
                        $dnsServer = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses[0]
                        $zone = ($hostname -split '\.', 2)[1]
                        $shortName = ($hostname -split '\.')[0]
                        if ($dnsServer -and $zone) {
                            # Helper: is this IP a heartbeat/VIP record that must NOT live under the node name?
                            $isBadIp = {
                                param($ip)
                                $bad = $false
                                foreach ($p in $clusterPrefixes) { if ($ip -like "$p*") { $bad = $true; break } }
                                if (-not $bad -and ($vipSet -contains $ip)) { $bad = $true }
                                if ($nodeOwnIp -and $ip -eq $nodeOwnIp) { $bad = $false }
                                return $bad
                            }

                            # Pre-check (cheap, bounded): resolve our own name locally and see if any
                            # heartbeat/VIP IP is actually published under it. The expensive DC RPC only
                            # runs when there's genuinely something to remove -- on a clean deploy this
                            # short-circuits and we never touch the DC at all.
                            $badIps = @()
                            $resolveWd = Invoke-WithWatchdog -TimeoutSec 10 -MaxAttempts 2 -ArgumentList @($hostname) -ScriptBlock {
                                param($fqdn)
                                @(Resolve-DnsName -Name $fqdn -Type A -ErrorAction SilentlyContinue |
                                    Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
                            }
                            if ($resolveWd.Status -eq 'OK') {
                                foreach ($ip in @($resolveWd.Output)) { if (& $isBadIp $ip) { $badIps += $ip } }
                            }
                            else {
                                # Local resolve itself timed out/failed -- fall back to the authoritative
                                # DC query (still watchdog'd) so we don't miss a stale record just because
                                # the local resolver was slow.
                                $listWd = Invoke-WithWatchdog -TimeoutSec 20 -MaxAttempts 2 -ArgumentList @($zone, $shortName, $dnsServer) -ScriptBlock {
                                    param($z, $n, $srv)
                                    @(Get-DnsServerResourceRecord -ZoneName $z -Name $n -RRType A -ComputerName $srv -ErrorAction SilentlyContinue |
                                        ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                                }
                                if ($listWd.Status -eq 'OK') {
                                    foreach ($ip in @($listWd.Output)) { if (& $isBadIp $ip) { $badIps += $ip } }
                                }
                                else {
                                    $results += "DNS record cleanup skipped (DC DNS query did not respond: $($listWd.Status))"
                                }
                            }

                            $badIps = @($badIps | Select-Object -Unique)
                            if ($badIps.Count -eq 0) {
                                $results += "No stale heartbeat/VIP DNS records to clean"
                            }
                            else {
                                foreach ($ip in $badIps) {
                                    $delWd = Invoke-WithWatchdog -TimeoutSec 20 -MaxAttempts 2 -ArgumentList @($zone, $shortName, $ip, $dnsServer) -ScriptBlock {
                                        param($z, $n, $rip, $srv)
                                        Remove-DnsServerResourceRecord -ZoneName $z -Name $n -RRType A -RecordData $rip -ComputerName $srv -Force -ErrorAction SilentlyContinue
                                    }
                                    if ($delWd.Status -eq 'OK') {
                                        $results += "Removed stale DNS A record $ip"
                                    }
                                    else {
                                        $results += "Stale DNS A record $ip removal did not complete ($($delWd.Status))"
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        $results += "DNS record cleanup skipped: $_"
                    }
                    return ($results -join '; ')
                }
                # Use the NODE's own network (it may sit on a non-default network),
                # not vmOptions.network, so the domain NIC is correctly identified.
                $nodeNetwork = if ($currentItem.network) { $currentItem.network } else { $deployConfig.vmOptions.network }
                $nodeSubnet = ($nodeNetwork -replace '\.\d+$', '.')
                $fqdn = "$($currentItem.vmName).$($deployConfig.vmOptions.domainName)"
                # Pass the node's own IP and the known cluster/AG VIPs so the in-guest
                # self-heal registers ONLY the node's own IP and marks the VIPs
                # SkipAsSource (so they never resolve under the node's own name).
                $nodeOwnIp = $currentItem.AssignedIP
                if (-not $nodeOwnIp) { $nodeOwnIp = $currentItem.LastKnownIP }
                $clusterVips = @()
                foreach ($vipProp in @('ClusterIPAddress', 'AGIPAddress')) {
                    if ($currentItem.$vipProp) { $clusterVips += ($currentItem.$vipProp -replace '/\d+$', '') }
                }
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName `
                    -ScriptBlock $scrubDns -ArgumentList @($fqdn, $nodeSubnet, $clusterVips, $nodeOwnIp) `
                    -DisplayName "Scrub heartbeat DNS records"
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DNS scrub failed: $($result.ScriptBlockOutput)" -Warning
                }
                else {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DNS scrub: $($result.ScriptBlockOutput)"
                }
            }

            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $complete -Phase $Phase
        }

        if (-not $complete) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName)  [$($currentItem.role)] : Failed after $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))" -OutputStream -Failure
        }
        else {
            Write-Progress2 "$($currentItem.role) Configuration completed in $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))" -Status $status.ScriptBlockOutput -Completed -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName)  [$($currentItem.role)] : Completed in $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))" -OutputStream -Success
        }
    }
    catch {
        Write-Exception -ExceptionInfo $_
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)" -LogOnly
        Write-Progress "Exception Occurred" -Status "Failed end2 $_"
    }
}
# Per-VM Phase 2 job for the Linux Proxy VM. Runs Install-LinuxProxyServer
# inside the same Wait-Phase tracking loop as the Windows VM_Config jobs so
# progress and elapsed time render consistently with the rest of Phase 2.
$global:Proxy_Install = {
    # Suppress CIM cmdlet progress (see VM_Create comment).
    $Global:ProgressPreference = 'SilentlyContinue'

    try {
        $global:ScriptBlockName = "Proxy_Install"
        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose -DevBranch:$using:Common.DevBranch

        $deployConfig = $using:deployConfigCopy
        $currentItem  = $using:currentItem
        $Phase        = $using:Phase

        if (-not ($Common.LogPath)) {
            Write-Output "ERROR: [Phase $Phase] $($currentItem.vmName): Logpath is null. Common.ps1 may not be initialized."
            return
        }
        try { Flush-LogBuffer -All } catch {}
        $domainNameForLogging = $deployConfig.vmOptions.domainName
        $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"

        Write-Progress2 -Activity "$($currentItem.vmName) [$($currentItem.role)]" -Status "Installing Squid forward proxy" -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Installing Squid forward proxy" -OutputStream

        $ok = Install-LinuxProxyServer -deployConfig $deployConfig -ProxyVM $currentItem
        if (-not $ok) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Squid install failed." -OutputStream -Failure
            return
        }

        # Mark Phase 2 complete on the VM note so re-runs short-circuit.
        try {
            $note = Get-VMNote -VMName $currentItem.vmName
            if ($note) {
                $note.lastPhaseComplete = [Math]::Max([int]$note.lastPhaseComplete, 2)
                Set-VMNote -VMName $currentItem.vmName -vmNote $note
            }
        } catch {}

        Write-Progress2 -Activity "$($currentItem.vmName) [$($currentItem.role)]" -Status "Squid install complete" -Completed -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Squid install complete." -OutputStream -Success
    }
    catch {
        Write-Exception -ExceptionInfo $_
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)" -LogOnly
    }
}

# Per-VM Phase 3 job for Linux VMs. Runs Invoke-LinuxRoleConfiguration which
# applies role-driven post-boot config (xrdp/xfce4/Firefox for enableRDP,
# realm-join for joinDomain) over SSH. Sits inside the same Wait-Phase
# tracking loop as the Windows DSC jobs so progress renders consistently and
# the long apt-get installs run in parallel with Windows DSC instead of
# serializing into cloud-init first boot.
$global:Linux_Configure = {
    # Suppress CIM cmdlet progress (see VM_Create comment).
    $Global:ProgressPreference = 'SilentlyContinue'

    try {
        $global:ScriptBlockName = "Linux_Configure"
        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose -DevBranch:$using:Common.DevBranch

        $deployConfig = $using:deployConfigCopy
        $currentItem  = $using:currentItem
        $Phase        = $using:Phase

        if (-not ($Common.LogPath)) {
            Write-Output "ERROR: [Phase $Phase] $($currentItem.vmName): Logpath is null. Common.ps1 may not be initialized."
            return
        }
        try { Flush-LogBuffer -All } catch {}
        $domainNameForLogging = $deployConfig.vmOptions.domainName
        $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"

        Write-Progress2 -Activity "$($currentItem.vmName) [$($currentItem.role)]" -Status "Applying Linux role configuration" -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Applying Linux role configuration"

        $ok = Invoke-LinuxRoleConfiguration -Vm $currentItem -DeployConfig $deployConfig
        if (-not $ok) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux_Configure failed." -OutputStream -Failure
            return
        }

        try {
            $note = Get-VMNote -VMName $currentItem.vmName
            if ($note) {
                $note.lastPhaseComplete = [Math]::Max([int]$note.lastPhaseComplete, 3)
                Set-VMNote -VMName $currentItem.vmName -vmNote $note
            }
        } catch {}

        Write-Progress2 -Activity "$($currentItem.vmName) [$($currentItem.role)]" -Status "Linux configuration complete" -Completed -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux configuration complete." -OutputStream -Success
    }
    catch {
        Write-Exception -ExceptionInfo $_
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)" -LogOnly
    }
}
