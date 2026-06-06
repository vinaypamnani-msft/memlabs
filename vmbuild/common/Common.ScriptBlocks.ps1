# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.


$global:Phase10Job = {
    param (
        [object] $vm,
        [array] $Dummy,
        [boolean] $NewVMS,
        [boolean] $Dummy2,
        [string] $ScriptRoot
    ) 
       
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

        if ($NewVMS) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Running New Only: $NewVMS"
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
        $worked = Start-VMMaintenance -VMName $currentItem.vmName -ApplyNewOnly:$NewVMS
        if (-not $worked) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed - Start-VMMaintenance returned no data." -OutputStream -Failure
            throw "Could not run VM Maintenance on $($currentItem.vmName)"
        }
        else {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Maintenance completed successfully for $($currentItem.role)." -OutputStream -Success
        }
    }
    catch {
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log -LogOnly "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)"
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

        $passed = Test-VmFunctionality -VMName $currentItem.vmName -CurrentItem $currentItem -DeployConfig $deployConfig

        # Emit buffered output lines (failures/warnings collected during test)
        # This must happen at top-level where -OutputStream goes to job output.
        if ($script:Phase11OutputBuffer) {
            foreach ($entry in $script:Phase11OutputBuffer) {
                switch ($entry.Level) {
                    'Failure' { Write-Log $entry.Text -OutputStream -Failure }
                    'Warning' { Write-Log $entry.Text -OutputStream -Warning }
                    default   { Write-Log $entry.Text -OutputStream }
                }
            }
        }

        if ($passed) {
            # Remove the Read-DSCLog desktop shortcut now that validation passed
            $domainName = $deployConfig.vmOptions.domainName
            Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
                Remove-Item (Join-Path $desktop 'Read DSC Log.lnk') -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $desktop 'DSC ConfigurationStatus.lnk') -Force -ErrorAction SilentlyContinue
            } -DisplayName "Phase11: Remove DSC shortcuts" -SuppressLog
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
    New-Item "$env:systemdrive\NO_SMS_ON_DRIVE.SMS" -ItemType File -Force -ErrorAction SilentlyContinue
}

# Create VM script block
$global:VM_Create = {

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
            $dynamicMinRamDeferred = $dynamicMinRam
            $raw99 = [long][math]::Floor(($currentItem.memory / 1) * 0.99)
            $dynamicMinRam = [string]($raw99 - ($raw99 % 2MB))
        }

        if (-not $CreateVM) {
            # Check if memory amount or processor count changed; skip dynamic memory toggle for existing VMs
            $restart = $false
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
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Pinning dynamic memory min to 99% for deploy" -LogOnly
                        $vm | Set-VMMemory -MinimumBytes $pinnedMin -MaximumBytes $memory -StartupBytes $memory -ErrorAction SilentlyContinue
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
                start-sleep -Seconds 20
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
                # Linux VMs (Proxy etc.) don't ship in the Azure storage
                # catalog - the base VHDX is built locally by
                # baseimagestaging\New-LinuxBaseImage.ps1 and lives at a
                # well-known path. Resolve directly and skip the fileList
                # lookup, otherwise this throws "Could not find Ubuntu
                # Server 24.04 LTS in file list" on any environment whose
                # _fileList.json doesn't carry the Ubuntu entry.
                if (Test-VmIsLinux -Vm $currentItem) {
                    # Pick the per-role base VHDX. LinuxClient uses the Desktop
                    # variant (ubuntu-desktop-minimal + GDM3 + NetworkManager +
                    # xrdp, built by baseimagestaging\New-LinuxBaseImage.ps1
                    # -Desktop). Everything else Linux (Proxy, LinuxServer)
                    # uses the smaller server cloud image.
                    $linuxVhdxName = switch ($currentItem.role) {
                        'LinuxClient' { 'UbuntuDesktop2404.vhdx' }
                        default       { 'UbuntuServer2404.vhdx' }
                    }
                    $vhdxPath = Join-Path $Common.AzureImagePath $linuxVhdxName
                    if (-not (Test-Path $vhdxPath)) {
                        $buildHint = if ($linuxVhdxName -eq 'UbuntuDesktop2404.vhdx') {
                            "baseimagestaging\New-LinuxBaseImage.ps1 -Desktop"
                        } else {
                            "baseimagestaging\New-LinuxBaseImage.ps1"
                        }
                        throw "Linux base image $vhdxPath not found. Run $buildHint first."
                    }
                }
                else {
                    $imageFile = $azureFileList.OS | Where-Object { $_.id -eq $currentItem.operatingSystem }
                    if ($imageFile) {
                        $vhdxPath = Join-Path $Common.AzureFilesPath $imageFile.filename
                    }
                    if (-not $vhdxPath) {
                        throw "Could not find $($currentItem.operatingSystem) in file list"
                    }
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
                $waitTimeout = Get-LinuxVmWaitTimeout -VmObject $currentItem
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

            if ($currentItem.role -eq "SQLAO") {
                $HashArguments.Add("SwitchName2", "cluster")
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
                start-sleep -seconds 3
                # Wait for VM to finish OOBE
                $oobeTimeout = 25
                if ($deployConfig.virtualMachines.Count -gt 3) {
                    $oobeTimeout = $deployConfig.virtualMachines.Count + $oobeTimeout
                }

                $connected = Wait-ForVm -VmName $currentItem.vmName -OobeComplete -TimeoutMinutes $oobeTimeout
                if (-not $connected) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if OOBE finished. Exiting." -Failure -OutputStream
                    return
                }
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
                $waitTimeout = Get-LinuxVmWaitTimeout -VmObject $currentItem
                $linuxIP = Wait-LinuxVmReady -VmName $currentItem.vmName -TimeoutSeconds $waitTimeout -ExpectedIPAddress $expectedIp
                if (-not $linuxIP) {
                    $waitMin = [int]($waitTimeout / 60)
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux VM did not become SSH-ready within ${waitMin}min." -Failure -OutputStream
                    return
                }

                # Persist the IP so Remove-Lab can scrub known_hosts even if
                # the VM is off (KVP is unavailable after power-off).
                Set-VMNote -vmName $currentItem.vmName -vmNote ([pscustomobject]@{ LastKnownIP = $linuxIP })

                Write-Log "[Phase $Phase]: $($currentItem.vmName): Existing VM Preparation completed successfully for $($currentItem.role) (Linux, IP $linuxIP)." -OutputStream -Success
                return
            }

            # Check if RDP is enabled on DC. We saw an issue where RDP was enabled on DC, but didn't take effect until reboot.
            if ($currentItem.role -eq "DC") {
                $testNet = Test-NetConnection -ComputerName $currentItem.vmName -Port 3389
                if (-not $testNet.TcpTestSucceeded) {
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

        # Assign DHCP reservation for PS/CS
        if ($currentItem.role -in "Primary", "CAS", "Secondary" -and $createVM) {
            try {
                $vmnet = Get-VM2 -Name $currentItem.vmName -ErrorAction SilentlyContinue | Get-VMNetworkAdapter
                #$vmnet = Get-VMNetworkAdapter -VMName $currentItem.vmName -ErrorAction Stop
                if ($vmnet) {
                    $realnetwork = $deployConfig.vmOptions.network
                    if ($currentItem.network) {
                        $realnetwork = $currentItem.network
                    }
                    $network = $realnetwork.Substring(0, $realnetwork.LastIndexOf("."))

                    $splitNetwork = ($network.split(".") | Select-Object -First 3) -join "."
                    if ($currentItem.role -eq "CAS") {
                        Remove-DHCPReservation -ip ($splitNetwork + ".5") -vmName $currentItem.vmName
                        Add-DhcpServerv4Reservation -ScopeId $realnetwork -IPAddress ($splitNetwork + ".5") -ClientId $vmnet.MacAddress -Description "Reservation for CAS" -ErrorAction Stop
                    }
                    if ($currentItem.role -eq "Primary") {
                        Remove-DHCPReservation -ip ($splitNetwork + ".10") -vmName $currentItem.vmName
                        Add-DhcpServerv4Reservation -ScopeId $realnetwork -IPAddress ($splitNetwork + ".10") -ClientId $vmnet.MacAddress -Description "Reservation for Primary" -ErrorAction Stop
                    }
                    if ($currentItem.role -eq "Secondary") {
                        Remove-DHCPReservation -ip ($splitNetwork + ".15") -vmName $currentItem.vmName
                        Add-DhcpServerv4Reservation -ScopeId $realnetwork -IPAddress ($splitNetwork + ".15") -ClientId $vmnet.MacAddress -Description "Reservation for Secondary" -ErrorAction Stop
                    }
                }
            }
            catch {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not assign DHCP Reservation for $($currentItem.role). $_" -Warning
                Write-Log "[Phase $Phase]: $($currentItem.vmName): $($_.ScriptStackTrace)" -LogOnly
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

        $Fix_DefaultProfile = {
            $path1 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCache"
            $path2 = "C:\Users\Default\AppData\Local\Microsoft\Windows\INetCache"
            $path3 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCacheLock.dat"
            if (Test-Path $path1) { Remove-Item -Path $path1 -Force -Recurse | Out-Null }
            if (Test-Path $path2) { Remove-Item -Path $path2 -Force -Recurse | Out-Null }
            if (Test-Path $path3) { Remove-Item -Path $path3 -Force | Out-Null }
        }

        $Fix_LocalAccount = {
            Set-LocalUser -Name "vmbuildadmin" -PasswordNeverExpires $true
        }

        $Fix_WorkGroupMachines = {
            New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "LocalAccountTokenFilterPolicy" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
        }
        # Add TLS keys, without these upgradeToLatest can fail when accessing the new endpoints that require TLS 1.2
        $Set_TLS12Keys = {
            param([String]$domainName)

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

            # Set the domain to be included in intranet sites for IE/Edge for kerberos to work
            try {
                if ($domainName -and ($domainName -ne "WORKGROUP")) {
                    New-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains" -Force
                    New-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$domainName" -Force
                    Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains" -Name "@" -Value "" -Force
                    New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$domainName" -Name "*" -Value 1 -PropertyType DWORD -Force
                }
                New-Item -Path "HKLM:\Software\Policies\Microsoft\Edge" -Force
                New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Edge" -Name "HideFirstRunExperience" -Value 1 -PropertyType DWORD -Force
                New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Edge" -Name "AutoImportAtFirstRun " -Value 4 -PropertyType DWORD -Force
            }
            catch {}

        }

        # Combined scriptblock that runs Fix_DefaultProfile + Fix_LocalAccount +
        # Set-TimeZone + TLS 1.2 keys + WorkgroupMember fix in one PSDirect call.
        $Fix_NewVmSettings = {
            param([String]$timezone, [String]$domainName, [bool]$isWorkgroup)
            $warnings = @()

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
            try {
                Set-LocalUser -Name "vmbuildadmin" -PasswordNeverExpires $true
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

            [PSCustomObject]@{ Warnings = $warnings }
        }

        if ($createVM) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Configuring new VM settings (profile, account, timezone, TLS, etc.)"

            $timeZone = $deployConfig.vmOptions.timeZone
            if (-not $timeZone) {
                $timeZone = (Get-Timezone).id
            }
            $isWorkgroup = $currentItem.role -in "WorkgroupMember", "InternetClient"

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_NewVmSettings -ArgumentList @($timeZone, $domainNameForLogging, $isWorkgroup) -DisplayName "Configure new VM settings"
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
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Initialize $($diskEntries.Count) disk(s)" -ScriptBlock {
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
                    New-Item "$env:systemdrive\NO_SMS_ON_DRIVE.SMS" -ItemType File -Force -ErrorAction SilentlyContinue

                    $ProgressPreference = $OriginalPref
                } -ArgumentList @(, $diskEntries)
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to initialize disks. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }
                Write-Progress2 -Activity "$($currentItem.vmName): Initializing disks" -Status "Done" -Completed -Log
            }
            # Copy SQL files to VM
            if ($currentItem.sqlVersion -and $createVM) {

                Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying SQL installation files to the VM."
                Write-Progress2 -Activity "$($currentItem.vmName): Copying SQL installation files" -Status "Mounting ISO" -force

                # Determine which SQL version files should be used
                $sqlFiles = $azureFileList.ISO | Where-Object { $_.id -eq $currentItem.sqlVersion }

                # SQL Iso Path
                $sqlIso = $sqlFiles.filename | Where-Object { $_.ToLowerInvariant().EndsWith(".iso") }
                $sqlIsoPath = Join-Path $Common.AzureFilesPath $sqlIso

                # Add SQL ISO to guest
                Set-VMDvdDrive -VMName $currentItem.vmName -Path $sqlIsoPath

                # Create directories and copy files from DVD in one call
                Write-Progress2 -Activity "$($currentItem.vmName): Copying SQL installation files" -Status "Copying from DVD" -force
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Create SQL directories and copy from CD-ROM" -ScriptBlock {
                    New-Item -Path "C:\temp\SQL" -ItemType Directory -Force | Out-Null
                    New-Item -Path "C:\temp\SQL_CU" -ItemType Directory -Force | Out-Null
                    $cd = Get-Volume | Where-Object { $_.DriveType -eq "CD-ROM" }
                    Copy-Item -Path "$($cd.DriveLetter):\*" -Destination "C:\temp\SQL" -Recurse -Force -Confirm:$false
                }
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy SQL installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }

                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Test SQL Files" -ScriptBlock { get-item "c:\temp\SQL_CU"; get-item "c:\temp\SQL\setup.exe" }
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy SQL installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }

                # Eject ISO from guest
                Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
                Write-Progress2 -Activity "$($currentItem.vmName): Copying SQL installation files" -Status "Done" -Completed
            }
            #Copy CM to the VM
            if ($currentItem.CMInstallDir -and $createVM) {

                Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying CM installation files to the VM."
                Write-Progress2 -Activity "$($currentItem.vmName): Copying ConfigMgr installation files" -Status "Mounting ISO" -force

                # Determine which SQL version files should be used
                $CMFiles = $azureFileList.CMVersions | Where-Object { $deployConfig.cmOptions.version -in $_.versions }

                if ($CMFiles.filename) {
                    # CM Iso Path
                    $CMIso = $CMFiles.filename | Where-Object { $_.ToLowerInvariant().EndsWith(".iso") }                
                    $CMIsoPath = Join-Path $Common.AzureFilesPath $CMIso

                     Write-Log "[Phase $Phase]: $($currentItem.vmName): Mounting $CMIsoPath as a DVD drive"
                    # Add CM ISO to guest
                    $dvd = Set-VMDvdDrive -VMName $currentItem.vmName -Path $CMIsoPath -Passthru

                    if (-not $dvd) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed Mounting $CMIsoPath as a DVD drive. Retrying"
                        Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
                        start-sleep -Seconds 20
                        $dvd = Set-VMDvdDrive -VMName $currentItem.vmName -Path $CMIsoPath -Passthru
                    }
                    write-log "[Phase $Phase]: $($currentItem.vmName): DVD = $dvd"

                    if (-not $dvd) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed Mounting $CMIsoPath as a DVD drive" -Failure -OutputStream
                        return

                    }
                    # Create CM Dir inside VM
                    # Create directory and copy files from DVD in one call
                    Write-Progress2 -Activity "$($currentItem.vmName): Copying ConfigMgr installation files" -Status "Copying from DVD" -force
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Create CM directory and copy from CD-ROM" -ScriptBlock {
                        New-Item -Path "C:\CMCB\cd.retail.LN" -ItemType Directory -Force | Out-Null
                        $cd = Get-Volume | Where-Object { $_.DriveType -eq "CD-ROM" }
                        Copy-Item -Path "$($cd.DriveLetter):\*" -Destination "C:\CMCB\cd.retail.LN" -Recurse -Force -Confirm:$false
                    }
                    if ($result.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy CM installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }
               

                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Test CM Files" -ScriptBlock { get-item "c:\CMCB\cd.retail.LN\SMSSETUP\BIN\X64\setup.exe" }
                    if ($result.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy CM installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }

                    # Eject ISO from guest
                    Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
                    Write-Progress2 -Activity "$($currentItem.vmName): Copying ConfigMgr installation files" -Status "Done" -Completed
                }
                else {
                     Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying CM installation files : Not needed. $currentItem"
                }
            }
        }
        
        if ($deployConfig.cmOptions.PrePopulateObjects -and $currentItem.SiteCode -and $createVM) {
            Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Checking site server" -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Checking if this is the Top Level SiteServer to prepopulate objects"
            $Parent = Get-TopSiteServerForSiteCode -deployConfig $deployConfig -siteCode $currentItem.SiteCode -type Name -SmartUpdate:$false

            # This is the Top Level Site Server
            if ($Parent -eq $currentItem.vmName) {

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

                    # SQL Iso Path
                    $Iso = $isoFile.filename | Where-Object { $_.ToLowerInvariant().EndsWith(".iso") }
                    Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Mounting $($isoFile.id) ($isoIndex/$isoTotal)" -force
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying $iso files to the VM."
                    $IsoPath = Join-Path $Common.AzureFilesPath $Iso
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Mounting $IsoPath to the VM."
                    Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
                    $dvd = Set-VMDvdDrive -VMName $currentItem.vmName -Path $isoPath -Passthru -ErrorVariable $err
                    if ($dvd) {
                        write-Log "Dvd successfully mounted from $($dvd.Path)"
                    }
                    else {
                        write-Log "Failed to mount the dvd from $isoPath $err"
                        start-sleep -seconds 30
                        $dvd = Set-VMDvdDrive -VMName $currentItem.vmName -Path $isoPath -Passthru -ErrorVariable $err
                        if (-not $dvd) {
                            write-Log "2nd Try. Failed to mount the dvd from $isoPath $err"
                        }
                        else {
                            write-Log "Successfully mounted the dvd from $($dvd.Path)"
                        }
                    }
                    $dirname = (join-path $driveLetter "OSD" $isoFile.id)

                    $CopyIsoFiles = {
                        param ($dirname)
                        New-Item -Path $dirname -ItemType Directory -Force
                        $cd = Get-Volume | Where-Object { $_.DriveType -eq "CD-ROM" }
                        Copy-Item -Path "$($cd.DriveLetter):\*" -Destination $dirname -Recurse -Force -Confirm:$false
                    }

                    # Copy files from DVD
                    Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Copying $($isoFile.id) ISO to VM ($isoIndex/$isoTotal)" -force
                    Write-Log "Copying ISO WIM Files to $dirname"
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Copy ISO WIM Files" -ScriptBlock $CopyIsoFiles -ArgumentList $dirname
                    if ($result.ScriptBlockFailed) {
                        $result2 = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Show Data" -ScriptBlock { $cd = Get-Volume | Where-Object { $_.DriveType -eq "CD-ROM" }; Get-ChildItem "$($cd.DriveLetter):" }
                        Write-Log "Contents of Drive: $($result2.ScriptBlockOutput) Mounted on $((Get-VMDvdDrive -VMName $currentItem.vmName).Path)"
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy ISO WIM files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }

                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Test WIM Files" -ScriptBlock { param ($dirname) get-item "$dirname\sources\install.wim" } -ArgumentList $dirname 
                    if ($result.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy WIM installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }

                    Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
                }
                Write-Progress2 -Activity "$($currentItem.vmName): Pre-populating OSD content" -Status "Done" -Completed
            }
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
}

$global:VM_Config = {
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
                        $oobeStartedRecovery = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -OobeStarted -TimeoutMinutes 15
                        if ($oobeStartedRecovery) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): AADClient recovered — OOBE started. Marking complete." -OutputStream -Success
                        }
                        else {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): AADClient started but OOBE did not appear within 15 minutes." -OutputStream -Failure
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
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if VM is connectable. Exiting." -Failure -OutputStream
            return
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


        $Stop_RunningDSC = {
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
                try {
                    Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force -ErrorAction SilentlyContinue | Out-Null
                    Stop-DscConfiguration -Force -ErrorAction SilentlyContinue | Out-Null
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
        }

        Write-Progress2 $Activity -Status "Stopping DSCs" -percentcomplete 5 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Stopping any previously running DSC Configurations."
        $result = Invoke-VmCommand -AsJob -TimeoutSeconds 60 -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
        if ($result.ScriptBlockFailed) {
            Write-Progress2 $Activity -Status "Retry Stopping DSCs" -percentcomplete 5 -force
            $result = Invoke-VmCommand -AsJob -TimeoutSeconds 60 -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
            if ($result.ScriptBlockFailed) {
                Write-Progress2 $Activity -Status "Restarting VM then Stopping DSCs" -percentcomplete 5 -force
                Stop-vm2 -name $currentItem.vmName
                Start-Sleep -Seconds 10
                start-vm2 -name  $currentItem.vmName
                Write-Progress2 $Activity -Status "Restarting VM then Stopping DSCs" -percentcomplete 5 -force
                start-sleep -seconds 30
                $result = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to stop any running DSC's. $($result.ScriptBlockOutput)" -Warning -OutputStream
                }
            }
        }

        # Check if VM has a pending reboot (common after crashed/killed deploys).
        # A pending reboot can leave PSDirect file operations hanging indefinitely
        # even though sessions connect fine.
        $Test_PendingReboot = {
            # Component Based Servicing
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
            # Windows Update
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
            # Pending file rename operations
            $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
            if ($pfro) { return $true }
            # Pending computer rename
            $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
            $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
            if ($active -and $pending -and $active -ne $pending) { return $true }
            return $false
        }
        $rebootCheck = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Test_PendingReboot -DisplayName "Check pending reboot"
        if ($rebootCheck.ScriptBlockOutput -eq $true) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Pending reboot detected. Rebooting VM before proceeding." -Warning -OutputStream
            Write-Progress2 $Activity -Status "Rebooting VM (pending reboot detected)" -percentcomplete 7 -force
            Stop-VM2 -Name $currentItem.vmName
            Start-Sleep -Seconds 10
            Start-VM2 -Name $currentItem.vmName
            Start-Sleep -Seconds 15
            $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName -SkipDiskTest
            if (-not $connected) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM did not come back after pending-reboot restart. Exiting." -Failure -OutputStream
                return
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
                    foreach ($ip in $IPAddress.ScriptBlockOutput) {
                        if ($ip.StartsWith("169.254")) {
                            $success = $false
                            #$currentItem.network
                            $currentNetwork = $currentItem.network
                            if (-not $currentNetwork) {
                                $currentNetwork = $deployConfig.vmOptions.Network
                            }
                            if ($retryCount -eq 1) {
                                try {
                                    Write-Progress2 $Activity -Status "Attempting to repair network $($currentNetwork) " -percentcomplete 10 -force
                                    stop-vm2 -Name $currentItem.vmname
                                    Remove-VMSwitch2 -NetworkName $($currentNetwork)
                                    Remove-DhcpServerv4Scope -scopeID $($currentNetwork) -ErrorAction SilentlyContinue
                                    stop-service "DHCPServer" | Out-Null
                                    $dhcp = Start-DHCP
                                    start-sleep -seconds 10
                                    $DC = get-list2 -deployConfig $deployConfig | where-object { $_.role -eq "DC" }
                                    $DCNetwork = $DC.Network
                                    if (-not $DCNetwork) {
                                        $DCNetwork = $deployConfig.vmOptions.Network
                                    }
                                    $DNSServer = ($DCNetwork.Substring(0, $DCNetwork.LastIndexOf(".")) + ".1")
                                    $worked = Add-SwitchAndDhcp -NetworkName $currentNetwork -NetworkSubnet $currentNetwork -DomainName $deployConfig.vmOptions.domainName -DNSServer $DNSServer -WhatIf:$WhatIf -ErrorAction SilentlyContinue

                                    start-vm2 -Name $currentItem.vmname
                                    $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $deployConfig.vmOptions.domainName -SkipDiskTest
                                    $IPrenew = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ipconfig /renew .\cache } -DisplayName "FixIPs"
                                }
                                catch {
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to repair network $($currentNetwork). $($_.Exception.Message)" -Warning -OutputStream
                                    return
                                }
                            }
                            if ($retryCount -eq 0) {
                                try {
                                    stop-service "DHCPServer" | Out-Null
                                    start-sleep -seconds 5
                                    $dhcp = Start-DHCP
                                    $IPrenew = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ipconfig /renew } -DisplayName "FixIPs"
                                }
                                catch {                                   
                                }
                            }
                            if ($retryCount -eq 2) {
                                $count = (Get-VMSwitch).Count
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Could not obtain a DHCP IP Address ($ip) Should be on $($currentNetwork) ($count Hyper-V switches in use. If this is over 20, this could be the issue)" -Failure -OutputStream
                                return
                            }
                            $retryCount++
                        }
                    }
                }
            }

            # Persist the first valid (non-APIPA) IP as LastKnownIP on the VM
            # so it flows into the Hyper-V VM Note via New-VmNote. The background
            # IP refresh job only runs outside of deploy, so this is the earliest
            # opportunity to record a guest-confirmed IP for Windows VMs.
            if ($success -and $IPAddress.ScriptBlockOutput) {
                $validIP = $IPAddress.ScriptBlockOutput | Where-Object { $_ -and -not $_.StartsWith("169.254") } | Select-Object -First 1
                if ($validIP) {
                    $existingIP = $currentItem.LastKnownIP
                    if (-not $existingIP -or $existingIP -ne $validIP) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Setting LastKnownIP to $validIP" -LogOnly
                        $currentItem | Add-Member -NotePropertyName LastKnownIP -NotePropertyValue $validIP -Force
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
            if (-not $injected) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not inject tools in the VM." -Warning

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
                    if (-not $injected) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Tool injection still failing after hard reset." -Warning -OutputStream
                    }
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
            # Set static IP on the cluster heartbeat NIC before DSC runs.
            # The heartbeat NIC has no DHCP — we configure it directly via
            # PowerShell Direct using the IP allocated during VM creation.
            Write-Progress2 $Activity -Status "Configuring heartbeat NIC" -percentcomplete 9 -force
            $heartbeatIP = $currentItem.ClusterHeartbeatIP
            if ($heartbeatIP) {
                $vm = Get-VM2 $currentItem.vmName
                $clusterMAC = ($vm.NetworkAdapters | Where-Object { $_.SwitchName -eq "Cluster" }).MacAddress
                if ($clusterMAC) {
                    $setStaticIP = {
                        param($targetIP, $targetMAC)
                        $targetMAC = ($targetMAC -replace '-','').ToLower()
                        $nic = Get-NetAdapter | Where-Object { ($_.MacAddress -replace '-','').ToLower() -eq $targetMAC }
                        if (-not $nic) { throw "Could not find NIC with MAC $targetMAC" }

                        # Check if the IP is already configured (idempotent for reruns)
                        $existing = Get-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object { $_.IPAddress -eq $targetIP }
                        if ($existing) { return "Already configured" }

                        # Remove APIPA or stale IPs from this adapter
                        Get-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
                            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                        # Assign static IP — no gateway, no DNS (heartbeat only)
                        New-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -IPAddress $targetIP -PrefixLength 24 | Out-Null
                        return "Configured $targetIP"
                    }
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName `
                        -ScriptBlock $setStaticIP -ArgumentList @($heartbeatIP, $clusterMAC) `
                        -DisplayName "Set heartbeat static IP $heartbeatIP"
                    if ($result.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set heartbeat IP $heartbeatIP" -Warning
                    }
                    else {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Heartbeat NIC: $($result.ScriptBlockOutput)" -LogOnly
                    }
                }
                else {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): No Cluster NIC found on VM" -Warning
                }
            }
            else {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): No ClusterHeartbeatIP in deploy config — legacy cluster on DHCP?" -Warning
            }
        }


        # Boot To OOBE?
        $bootToOOBE = $currentItem.role -eq "AADClient"
        $oobeStarted = $false
        if ($bootToOOBE) {
            # Run Sysprep — first run only; the oobeComplete check above
            # ensures we never reach here on a rerun.
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-NetFirewallProfile -All -Enabled false }
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
                        $oobeStarted = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -OobeStarted -TimeoutMinutes 15
                        if ($oobeStarted) {
                            Write-Progress2 -Activity "Wait for VM to start OOBE" -Status "Complete!" -Completed
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
            [PSCustomObject]@{
                Hash        = (Get-FileHash -Path "C:\staging\DSC\DSC.zip" -Algorithm MD5 -ErrorAction SilentlyContinue).Hash
                FlagExists  = Test-Path "C:\staging\DSC\DSC.zip.Installed"
            }
        } -DisplayName "DSC: Detect modules and ensure staging directory."
        $guestZipHash = $result.ScriptBlockOutput.Hash
        $guestFlagExists = $result.ScriptBlockOutput.FlagExists

        $dscZipHash = (Get-FileHash -Path "$rootPath\DSC\DSC.zip" -Algorithm MD5).Hash


        if (-not $alreadyCopiedDSC -or ($guestZipHash -ne $dscZipHash)) {

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
                        Write-Log "[Phase $Phase]: DSC parse-check WARNING: $pf" -Warning
                    }
                }
            }

            # Copy DSC files
            Write-Progress2 $Activity -Status "Copying DSC files to the VM" -percentcomplete 35 -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying DSC files to the VM."

            # Copy-ItemSafe has 3 internal retries (~12 min worst case).
            # DSC copy is critical, so retry up to 2 more times at the caller level.
            $copyResults = $false
            for ($copyAttempt = 1; $copyAttempt -le 3; $copyAttempt++) {
                if ($copyAttempt -gt 1) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Caller retry $($copyAttempt - 1)/2 after 30s delay..." -Warning
                    Start-Sleep -Seconds 30
                    Write-Progress2 $Activity -Status "Copying DSC files to the VM (retry $($copyAttempt - 1)/2)" -percentcomplete 36 -force
                }
                $copyResults = Copy-ItemSafe -VmName $currentItem.vmName -VMDomainName $domainName -Path "$rootPath\DSC" -Destination "C:\staging" -Recurse -Container -Force
                if ($copyResults -ne $false) { break }
            }
            if ($copyResults -eq $false) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy DSC files to the VM after $copyAttempt attempts." -Failure -OutputStream
                return
            }
        }
        else {
            Write-Progress2 $Activity -Status "Skip copying DSC files to the VM." -percentcomplete 35 -force -Log
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
                try {
                    "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force
                }
                catch {
                    throw "Could not write to $log"
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
                        Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force -ErrorAction SilentlyContinue
                    }
                }

                # Create the zip flag
                New-Item -Path "C:\staging\DSC\DSC.zip.Installed" -ItemType File -Force -ErrorAction SilentlyContinue
                "Modules Installed" | Out-File $log -Append
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                try { $error_message | Out-File $log -Append } catch {}
                throw $error_message
            }
        }

        if ($dscZipHash -ne $guestZipHash -or -not $guestFlagExists) {
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
                [String]$DscFolder
            )

            try {
                $global:ScriptBlockName = "DSC_ClearStatus"
                try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $Phase = $using:Phase

                $log = "C:\staging\DSC\DSC_Init.log"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
                try {
                    "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force                
                }
                catch {
                    throw "Could not write to $log"
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


                # Remove DSC_Status file, if exists
                $dscStatus = "C:\staging\DSC\DSC_Status.txt"
                if (Test-Path $dscStatus) {
                    "Removing $dscStatus" | Out-File $log -Append
                    Remove-Item -Path $dscStatus -Force -Confirm:$false -ErrorAction Stop
                }

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
        $result = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ClearStatus -ArgumentList $DscFolder -DisplayName "DSC: Clear Old Status"
        if ($result.ScriptBlockFailed) {
            start-sleep -seconds 20
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ClearStatus -ArgumentList $DscFolder -DisplayName "DSC: Clear Old Status"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to clear old status. $($result.ScriptBlockOutput)" -Failure -OutputStream
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
                try {
                    "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force                
                }
                catch {
                    throw "Could not write to $log"
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
                try {
                    "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force                
                }
                catch {
                    throw "Could not write to $log"
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
                try {
                    "`r`n=====`r`n$($global:ScriptBlockName): Started at $time`r`n=====" | Out-File $log -Append -Force                
                }
                catch {
                    throw "Could not write to $log"
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

                    "Start-DscConfiguration for $dscConfigPath with $user credentials" | Out-File $log -Append
                    Start-DscConfiguration -Path $dscConfigPath -Force -Verbose -ErrorAction Stop -Credential $creds -JobName $currentItem.vmName

                    $wait = Wait-Job -Timeout 30 -name $currentItem.vmName
                    $job = get-job -name $currentItem.vmName
                    "Job.State $($job.State)" | Out-File $log -Append
                    
                    # Wait 30 seconds for job to start. If the job has not been started, or has not completed, then log an error
                    if ($job.State -ne "Running") {
                        $job | Out-File $log -Append
                        $data = Receive-Job -name $currentItem.vmName
                        if ($wait.State -eq "Completed") {
                            $data | Out-File $log -Append
                        }
                        else {
                            $data | Out-File $log -Append
                            if ($data -is [String]) {
                                Write-Error $data
                            }
                            return $data
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

        if ($skipStartDsc) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC for $($currentItem.role) configuration will be started on the DC."
            Write-Progress2 $Activity -Status "Waiting for DC to start DSC" -percentcomplete 75 -force
        }
        else {
            Write-Progress2 $Activity -Status "Starting DSC" -percentcomplete 75 -force
            if ($multiNodeDsc) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC for $($currentItem.role) Starting"
                # Check if DSC_Status.txt file has been removed on all nodes before continuing. This is to ensure that Stop-Dsc doesn't run after DC has started DSC.
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
                    Write-Progress2 "Waiting for all nodes. Attempt #$attempts/100" -Status "Waiting for [$($nonReadyNodes -join ',')] to be ready." -PercentComplete $percent

                    # Periodically check DSC_Init.log to see if DSC_ClearStatus started/progressed.
                    # Do NOT read DSC_Status.txt here - it contains stale content from the previous
                    # phase until DSC_ClearStatus deletes it, which is exactly what this loop waits for.
                    $detailedCheck = ($attempts -ge 15 -and ($attempts % 15) -eq 0)

                    foreach ($node in $nonReadyNodes) {
                        if (-not $node) {
                            continue
                        }
                        $result = Invoke-VmCommand -VmName $node -VmDomainName $deployConfig.vmOptions.domainName -CommandReturnsBool -ScriptBlock { Test-Path "C:\staging\DSC\DSC_Status.txt" } -DisplayName "DSC: Check Nodes Ready"
                        if ($result.ScriptBlockFailed -or ($result.ScriptBlockOutput -eq $true)) {
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
                                Write-Log "[Phase $Phase]: Node $node is NOT ready. File Exists: $($result.ScriptBlockOutput) (attempt $attempts)" -LogOnly
                            }
                            $allNodesReady = $false
                        }
                        else {
                            $nodeList.Remove($node) | Out-Null
                            if ($nodeList.Count -eq 0) {
                                Write-Progress2 "Waiting for all nodes. Attempt #$attempts/$maxAttempts" -status "All nodes are ready" -PercentComplete 100
                                $allNodesReady = $true
                            }
                            else {
                                Write-Progress2 "Waiting for all nodes. Attempt #$attempts/$maxAttempts" -Status "Waiting for [$($nodeList -join ',')] to be ready." -PercentComplete $percent
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
                            Write-Progress2 "Restarting $node" -PercentComplete $percent
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
                            $info.InitLogTail = Get-Content "C:\staging\DSC\DSC_Init.log" -Tail 20 -ErrorAction SilentlyContinue
                            $info.LcmState = try { (Get-DscLocalConfigurationManager).LCMState } catch { 'Unknown' }
                            $info.LastDscStatus = try { (Get-DscConfigurationStatus -ErrorAction SilentlyContinue).Status } catch { 'Unknown' }
                            $info.PendingReboot = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
                            $info.StagingFiles = try { (Get-ChildItem "C:\staging\DSC" -File -ErrorAction SilentlyContinue).Name -join ', ' } catch { 'N/A' }
                            $info
                        } -DisplayName "DSC: Final Diagnostics"
                        if (-not $diagResult.ScriptBlockFailed -and $diagResult.ScriptBlockOutput) {
                            $diag = $diagResult.ScriptBlockOutput
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
                    Write-Progress2 "Failed waiting on VMs [$($nodeList -join ',')].  Please cancel and retry this phase."
                    write-log "[Phase $Phase]: Node [$($nodeList -join ',')] is NOT ready after $maxAttempts attempts." -failure -OutputStream
                    return $false
                }

            }
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Finished waiting on all nodes"

            Write-Progress2 "Creating DSC" -status "Invoking DSC_CreateConfig" -PercentComplete 0
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_CreateConfig -ArgumentList $DscFolder -DisplayName "DSC: Create $($currentItem.role) Configuration"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to create $($currentItem.role) configuration. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
            }

            Write-Progress2 "Starting DSC" -status "Invoking DSC_StartConfig" -PercentComplete 50
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
            if ($result.ScriptBlockFailed) {
                Start-Sleep -Seconds 15
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to start $($currentItem.role) configuration. Retrying. $($result.ScriptBlockOutput)" -Warning
                # Retry once before exiting
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to Start $($currentItem.role) configuration. Rebooting. $($result.ScriptBlockOutput)" -Warning
                    stop-vm2 -name $currentItem.vmName
                    start-sleep -seconds 30
                    start-vm2 -name $currentItem.vmName
                    start-sleep -seconds 30 
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
                    if ($result.ScriptBlockFailed) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to Start $($currentItem.role) configuration. Exiting. $($result.ScriptBlockOutput)" -Failure -OutputStream
                        return
                    }
                                        
                }
            }
            Write-Progress2 "Starting DSC" -status "[Phase $Phase]: $($currentItem.vmName): Started DSC for $($currentItem.role) configuration." -PercentComplete 100
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Started DSC for $($currentItem.role) configuration."
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
        [int]$failedHeartbeatThreshold = 100 # 3 seconds * 100 tries = ~5 minutes

        $noStatus = $true
        $lastStatusChangeTime = [DateTime]::UtcNow
        $staleWarningMinutes = 15
        $staleRestartMinutes = 30
        $staleRestartCount = 0
        $staleRestartMax = 2
        $lastStaleWarningTime = [DateTime]::MinValue

        Write-Log "[Phase $Phase]: $($currentItem.vmName): Started Monitoring $($currentItem.role) configuration."
        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Ready and Waiting for job progress"
        $rebooted = $false
        $dscFails = 0
        $dscStatusPolls = 0
        [int]$failCount = 0
        try {
            do {

                $dscStatusPolls++

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
                            start-sleep -Seconds 30
                            start-vm2 -name $currentItem.vmName
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
                            start-sleep -Seconds 30
                            start-vm2 -name $currentItem.vmName
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
                                        Stop-VM2 -name $currentItem.vmName
                                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "ADServerDownException, VM Stopped"
                                        Start-Sleep -Seconds 20
                                        Start-VM2 -Name $currentItem.vmName
                                        

                                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "ADServerDownException, VM Started. Waiting 60 seconds to check status."

                                        Start-Sleep -Seconds 50
                                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "ADServerDownException, VM Started. Waiting 10 seconds to check status."

                                        Start-Sleep -Seconds 10
                                        $state = Get-VM2 -Name $currentItem.vmName
                                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "ADServerDownException, VM Current State: $($state.state)"
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

                if ($failedHeartbeats -ge $failedHeartbeatThreshold) {
                    try {
                        #Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt -ErrorAction SilentlyContinue } -ShowVMSessionError | Out-Null # Try the command one more time to get failure in logs

                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Failed to retrieve job status from VM, forcefully restarting the VM" -failcount $failedHeartbeats -failcountMax $failedHeartbeatThreshold

                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to retrieve job status from VM after $failedHeartbeatThreshold tries. Forcefully restarting the VM" -Warning
                        Stop-VM2 -name $currentItem.vmName
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Failed to retrieve job status from VM, VM Stopped"
                        Start-Sleep -Seconds 20
                        Start-VM2 -Name $currentItem.vmName
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Failed to retrieve job status from VM, VM Started"

                        Start-Sleep -Seconds 15
                        $state = Get-VM2 -Name $currentItem.vmName
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Failed to retrieve job status from VM, VM Current State: $($state.state)"
                        $failedHeartbeats = 0 # Reset heartbeat counter so we don't keep shutting down the VM over and over while it's starting up
                    }
                    catch {
                        Write-Log -Failure "$_"
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
                    }
                    else {
                        # Status unchanged — check for stale progress
                        $staleMins = [int]([DateTime]::UtcNow - $lastStatusChangeTime).TotalMinutes
                        if ($staleMins -ge $staleRestartMinutes -and $staleRestartCount -lt $staleRestartMax) {
                            # Before restarting, check if DSC is still actively running
                            $lcmCheck = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 30 -ScriptBlock {
                                (Get-DscLocalConfigurationManager).LCMState
                            } -SuppressLog
                            if (-not $lcmCheck.ScriptBlockFailed -and $lcmCheck.ScriptBlockOutput -eq 'Busy') {
                                # LCM is still actively applying configuration — not stuck
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Status unchanged for ${staleMins}m ('$($currentStatus.Trim())') but LCM is still Busy. Not restarting." -Warning
                                $lastStatusChangeTime = [DateTime]::UtcNow
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                            else {
                                # LCM is Idle/unreachable — VM may be genuinely stuck
                                $staleRestartCount++
                                $lcmState = if ($lcmCheck.ScriptBlockFailed) { "unreachable" } else { $lcmCheck.ScriptBlockOutput }
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Status unchanged for ${staleMins}m ('$($currentStatus.Trim())'). LCM state: $lcmState. Forcefully restarting VM (attempt $staleRestartCount/$staleRestartMax)." -Warning -OutputStream
                                Stop-VM2 -name $currentItem.vmName
                                Start-Sleep -Seconds 20
                                Start-VM2 -Name $currentItem.vmName
                                Start-Sleep -Seconds 15
                                $lastStatusChangeTime = [DateTime]::UtcNow
                                $lastStaleWarningTime = [DateTime]::MinValue
                            }
                        }
                        elseif ($staleMins -ge $staleWarningMinutes -and ([DateTime]::UtcNow - $lastStaleWarningTime).TotalMinutes -ge 5) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Status unchanged for ${staleMins}m ('$($currentStatus.Trim())')" -Warning
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
                    # Check ConfigMgrSetup.log for fatal errors in a single PSDirect call
                    $cmLogCheck = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -SuppressLog -ScriptBlock {
                        if (Test-Path C:\ConfigMgrSetup.log) {
                            Get-Content C:\ConfigMgrSetup.log -tail 10 | Select-String "Failed Configuration Manager Server Setup|fatal errors|cannot be completed|doesn't have administrative rights|Prereq check didn't pass" | Select-Object -First 1
                        }
                    }
                    if ($cmLogCheck.ScriptBlockOutput.Line) {
                        $failEntry = $cmLogCheck.ScriptBlockOutput.Line
                        $bailEarly = $true
                    }

                    if ($bailEarly) {
                        if ($failEntry -is [string] -and $failEntry.Contains("$")) {
                            $failEntry = $failEntry.Substring(0, $failEntry.IndexOf("$"))
                        }
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: $($currentItem.role) failed: $failEntry. Check C:\ConfigMgrSetup.log for more." -Failure -OutputStream
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
            Write-Progress2 "Exception" -Status "Failed end $_"
            return
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

            $disable_AutomaticUpdates = {
                New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force
                New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type Dword -Value 1 -Force
                New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type Dword -Value 2 -Force
            }

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $disable_AutomaticUpdates -DisplayName "Disable Automatic Updates"

            $disable_AutomaticUpdatesFakeWSUS = {
                New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force
                New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUServer" -Type String -Value "http://localhost" -Force
                New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUStatusServer" -Type String -Value "http://localhost" -Force
                New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "UseWUServer" -Type Dword -Value 1 -Force
            }

            if ($currentItem.useFakeWSUSServer) {
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $disable_AutomaticUpdatesFakeWSUS -DisplayName "Use Fake WSUS Server"
            }
            else {
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $disable_AutomaticUpdates -DisplayName "Disable Automatic Updates"
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
                        $null = Set-WindowsClientProxy -VmName $currentItem.vmName -Domain $deployConfig.vmOptions.domainName `
                            -ProxyFqdn $proxyFqdn -BypassNetwork $deployConfig.vmOptions.network
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
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $complete -Phase $Phase
        }

        # If the phase succeeded, check for a pending reboot and clear it now
        # while other VMs are still finishing their phase. Getting the reboot
        # out of the way early means the next phase doesn't have to wait for
        # Stop/Start + Wait-ForVM before it can begin DSC.
        if ($complete) {
            try {
                $reboot = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Test_PendingReboot -DisplayName "Post-phase reboot check" -SuppressLog
                if ($reboot.ScriptBlockOutput -eq $true) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Pending reboot detected after phase completion. Rebooting now."
                    Stop-VM2 -Name $currentItem.vmName
                    Start-Sleep -Seconds 5
                    Start-VM2 -Name $currentItem.vmName
                    $null = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName -SkipDiskTest
                }
            }
            catch {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Post-phase reboot check failed: $_" -Warning
            }
        }

        if (-not $complete) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName)  [$($currentItem.role)] : Failed after $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))" -OutputStream -Failure
        }
        else {
            Write-Progress2 "$($currentItem.role) Configuration completed in $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))" -Status $status.ScriptBlockOutput -Completed
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

        Write-Progress2 -Activity "$($currentItem.vmName) [$($currentItem.role)]" -Status "Squid install complete" -Completed
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

        Write-Progress2 -Activity "$($currentItem.vmName) [$($currentItem.role)]" -Status "Linux configuration complete" -Completed
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Linux configuration complete." -OutputStream -Success
    }
    catch {
        Write-Exception -ExceptionInfo $_
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)" -LogOnly
    }
}
