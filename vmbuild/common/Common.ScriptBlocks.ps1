
# Create VM script block
$global:VM_Create = {

    try {
        $global:ScriptBlockName = "VM_Create"
        # Dot source common
        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

        # Get variables from parent scope
        $deployConfig = $using:deployConfigCopy
        $currentItem = $using:currentItem
        $azureFileList = $using:Common.AzureFileList
        $Phase = $using:Phase

        if (-not ($Common.LogPath)) {
            Write-Output "ERROR: [Phase $Phase] $($currentItem.vmName): Logpath is null. Common.ps1 may not be initialized."
            return
        }

        # Validate token exists
        if ($Common.FatalError) {
            Write-Log "Critical Failure! $($Common.FatalError)" -Failure -OutputStream
            return
        }

        # Params for child script blocks
        $createVM = $true
        if ($currentItem.hidden -eq $true) { $createVM = $false }

        # Change log location
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
        }
        else {
            $domainName = "WORKGROUP"
        }

        # Determine which OS image file to use for the VM
        $imageFile = $azureFileList.OS | Where-Object { $_.id -eq $currentItem.operatingSystem }
        $vhdxPath = Join-Path $Common.AzureFilesPath $imageFile.filename

        # Set base VM path
        $virtualMachinePath = Join-Path $deployConfig.vmOptions.basePath $deployConfig.vmOptions.domainName

        if ($createVM) {

            # Check if VM already exists
            $exists = Get-VM2 -Name $currentItem.vmName -ErrorAction SilentlyContinue
            if ($exists) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM already exists. Exiting." -Failure -OutputStream -HostOnly
                return
            }

            # Create VM
            $vmSwitch = Get-VMSwitch2 -NetworkName $network

            $Generation = 2
            if ($currentItem.vmGeneration) {
                $Generation = $currentItem.vmGeneration
            }
            $tpmEnabled = $true
            if ($currentItem.tpmEnabled) {
                $tpmEnabled = $currentItem.tpmEnabled
            }
            $HashArguments = @{
                VmName          = $currentItem.vmName
                VmPath          = $virtualMachinePath
                AdditionalDisks = $currentItem.additionalDisks
                Memory          = $currentItem.memory
                Generation      = $Generation
                Processors      = $currentItem.virtualProcs
                SwitchName      = $vmSwitch.Name
                tpmEnabled      = $tpmEnabled
                DeployConfig    = $deployConfig
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

            if ($currentItem.role -eq "OSDClient") {
                New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $true -UpdateVersion
                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Creation completed successfully for $($currentItem.role)." -OutputStream -Success
                return
            }
            Write-Progress2 "Waiting for OOBE" -Status "Starting" -percentcomplete 0 -force
            start-sleep -seconds 3
            # Wait for VM to finish OOBE
            $oobeTimeout = 15
            if ($deployConfig.virtualMachines.Count -gt 5) {
                $oobeTimeout = $deployConfig.virtualMachines.Count + 10
            }

            $connected = Wait-ForVm -VmName $currentItem.vmName -OobeComplete -TimeoutMinutes $oobeTimeout
            if (-not $connected) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if OOBE finished. Exiting." -Failure -OutputStream
                return
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
                    if ($currentItem.role -eq "CAS") {
                        Remove-DhcpServerv4Reservation -IPAddress ($network + ".5") -ErrorAction SilentlyContinue
                        Add-DhcpServerv4Reservation -ScopeId $realnetwork -IPAddress ($network + ".5") -ClientId $vmnet.MacAddress -Description "Reservation for CAS" -ErrorAction Stop
                    }
                    if ($currentItem.role -eq "Primary") {
                        Remove-DhcpServerv4Reservation -IPAddress ($network + ".10") -ErrorAction SilentlyContinue
                        Add-DhcpServerv4Reservation -ScopeId $realnetwork -IPAddress ($network + ".10") -ClientId $vmnet.MacAddress -Description "Reservation for Primary" -ErrorAction Stop
                    }
                    if ($currentItem.role -eq "Secondary") {
                        Remove-DhcpServerv4Reservation -IPAddress ($network + ".15") -ErrorAction SilentlyContinue
                        Add-DhcpServerv4Reservation -ScopeId $realnetwork -IPAddress ($network + ".15") -ClientId $vmnet.MacAddress -Description "Reservation for Secondary" -ErrorAction Stop
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
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
            return
        }

        # Set PS Execution Policy (required on client OS)
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue }
        if ($result.ScriptBlockFailed) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set PS ExecutionPolicy to Bypass for LocalMachine. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
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

        # Add TLS keys, without these upgradeToLatest can fail when accessing the new endpoints that require TLS 1.2
        $Set_TLS12Keys = {

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
        }

        if ($createVM) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Updating Default user profile to fix a known sysprep issue."
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_DefaultProfile -DisplayName "Fix Default Profile"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to fix the default user profile." -Warning -OutputStream
                $skipVersionUpdate = $true
            }

            Write-Log "[Phase $Phase]: $($currentItem.vmName): Updating Password Expiration for vmbuildadmin account."
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_LocalAccount -DisplayName "Fix Local Account Password Expiration"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to fix the password expiration policy for vmbuildadmin." -Warning -OutputStream
                $skipVersionUpdate = $true
            }

            $timeZone = $deployConfig.vmOptions.timeZone
            if (-not $timeZone) {
                $timeZone = (Get-Timezone).id
            }

            Write-Log "[Phase $Phase]: $($currentItem.vmName): Setting timezone to '$timeZone'."
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { param ($timezone) Set-TimeZone -Id $timezone } -ArgumentList $timeZone -DisplayName "Setting timezone to '$timeZone'"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set the timezone." -Warning -OutputStream
            }

            Write-Log "[Phase $Phase]: $($currentItem.vmName): Setting TLS 1.2 registry keys."
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Set_TLS12Keys -DisplayName "Setting TLS 1.2 Registry Keys"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set TLS 1.2 Registry Keys." -Warning -OutputStream
            }

            # Set vm note
            if (-not $skipVersionUpdate) {
                New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -InProgress $true -UpdateVersion
            }
        }



        # Copy SQL files to VM
        if ($currentItem.sqlVersion -and $createVM) {

            Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying SQL installation files to the VM."
            Write-Progress2 -Activity "$($currentItem.vmName): Copying SQL installation files to the VM" -Completed

            # Determine which SQL version files should be used
            $sqlFiles = $azureFileList.ISO | Where-Object { $_.id -eq $currentItem.sqlVersion }

            # SQL Iso Path
            $sqlIso = $sqlFiles.filename | Where-Object { $_.EndsWith(".iso") }
            $sqlIsoPath = Join-Path $Common.AzureFilesPath $sqlIso

            # Add SQL ISO to guest
            Set-VMDvdDrive -VMName $currentItem.vmName -Path $sqlIsoPath

            # Create C:\temp\SQL & C:\temp\SQL_CU inside VM
            $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { New-Item -Path "C:\temp\SQL" -ItemType Directory -Force }
            $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { New-Item -Path "C:\temp\SQL_CU" -ItemType Directory -Force }

            # Copy files from DVD
            $result = Invoke-VmCommand -VmName $currentItem.vmName -DisplayName "Copy SQL Files" -ScriptBlock { $cd = Get-Volume | Where-Object { $_.DriveType -eq "CD-ROM" }; Copy-Item -Path "$($cd.DriveLetter):\*" -Destination "C:\temp\SQL" -Recurse -Force -Confirm:$false }
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy SQL installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
            }

            # Eject ISO from guest
            Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
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

        # Get variables from parent scope
        $deployConfig = $using:deployConfigCopy
        $currentItem = $using:currentItem
        $enableVerbose = $using:enableVerbose
        $Phase = $using:Phase
        $ConfigurationData = $using:ConfigurationData
        $multiNodeDsc = $using:multiNodeDsc

        # Dot source common
        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

        if (-not ($Common.LogPath)) {
            Write-Output "ERROR: [Phase $Phase] $($currentItem.vmName): Logpath is null. Common.ps1 may not be initialized."
            return
        }

        # Validate token exists
        if ($Common.FatalError) {
            Write-Log "Critical Failure! $($Common.FatalError)" -Failure -OutputStream
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

        # Change log location
        $domainNameForLogging = $deployConfig.vmOptions.domainName
        $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"

        # Set domain name, depending on whether we need to create new VM or use existing one
        if ($currentItem.hidden -or ($currentItem.role -in ("DC", "BDC")) -or $Phase -gt 2) {
            $domainName = $deployConfig.parameters.DomainName
        }
        else {
            $domainName = "WORKGROUP"
        }

        # Verify again that VM is connectable, in case DSC caused a reboot
        $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName
        if (-not $connected) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if VM is connectable. Exiting." -Failure -OutputStream
            return
        }
        Write-Progress2 $Activity -Status "Waiting for OOBE" -percentcomplete 0 -force
        # Get VM Session
        $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName

        if (-not $ps) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
            return
        }

        # inject tools
        if ($Phase -eq 2) {
            Write-Progress2 $Activity -Status "Injecting Tools" -percentcomplete 10 -force
            $injected = Install-Tools -VmName $currentItem.vmName -ShowProgress
            if (-not $injected) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not inject tools in the VM." -Warning
            }
        }

        $Stop_RunningDSC = {
            # Stop any existing DSC runs
            try {
                Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force
                Stop-DscConfiguration -Verbose -Force
                Disable-DscDebug
            }
            catch {
                Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force
                Stop-DscConfiguration -Verbose -Force
            }
        }
        Write-Progress2 $Activity -Status "Stopping DSCs" -percentcomplete 20 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Stopping any previously running DSC Configurations."
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
        if ($result.ScriptBlockFailed) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to stop any running DSC's. $($result.ScriptBlockOutput)" -Warning -OutputStream
        }

        # Boot To OOBE?
        $bootToOOBE = $currentItem.role -eq "AADClient"
        if ($bootToOOBE) {
            # Run Sysprep
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-NetFirewallProfile -All -Enabled false }
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { C:\Windows\system32\sysprep\sysprep.exe /generalize /oobe /shutdown }
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to boot the VM to OOBE. $($result.ScriptBlockOutput)" -Failure -OutputStream
            }
            else {
                $ready = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -VmState "Off" -TimeoutMinutes 15
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
            # Update VMNote and set new version, this code doesn't run when VM_Create failed
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $oobeStarted -UpdateVersion
            return
        }
        Write-Progress2 $Activity -Status "Enable PS-Remoting" -percentcomplete 25 -force
        # Enable PS Remoting on client OS before starting DSC. Ignore failures, this will work but reports a failure...
        if ($currentItem.operatingSystem -notlike "*SERVER*") {
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Enable-PSRemoting -ErrorAction SilentlyContinue -Confirm:$false -SkipNetworkProfileCheck } -DisplayName "DSC: Enable-PSRemoting. Ignore failures."
        }
        Write-Progress2 $Activity -Status "Upgrading Modules" -percentcomplete 30 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Detect if modules need to be updated."
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-FileHash -Path "C:\staging\DSC\DSC.zip" -Algorithm MD5 -ErrorAction SilentlyContinue } -DisplayName "DSC: Detect modules."
        $guestZipHash = $result.ScriptBlockOutput.Hash

        # Copy DSC files
        Write-Progress2 $Activity -Status "Copying DSC files to the VM." -percentcomplete 35 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying DSC files to the VM."
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { New-Item -Path "C:\staging\DSC" -ItemType Directory -Force }
        if ($result.ScriptBlockFailed) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to copy DSC Files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
        }
        Copy-Item -ToSession $ps -Path "$rootPath\DSC" -Destination "C:\staging" -Recurse -Container -Force

        $Expand_Archive = {
            $zipPath = "C:\staging\DSC\DSC.zip"
            $extractPath = "C:\staging\DSC\modules"
            try {
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
            }
            catch {

                if (Test-Path $extractPath) {
                    Start-Sleep -Seconds 60
                    Remove-Item -Path $extractPath -Force -Recurse | Out-Null
                }

                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
            }
        }

        # Install DSC Modules
        $DSC_InstallModules = {

            try {
                $global:ScriptBlockName = "DSC_InstallModules"

                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $Phase = $using:Phase

                # Create init log
                $log = "C:\staging\DSC\DSC_Init.txt"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
                "`r`n=====`r`nDSC_InstallModules: Started at $time`r`n=====" | Out-File $log -Force

                # Install modules
                "Installing modules" | Out-File $log -Append
                $modules = Get-ChildItem -Path "C:\staging\DSC\modules" -Directory
                foreach ($folder in $modules) {
                    try {
                        Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force -ErrorAction Stop
                        Import-Module $folder.Name -Force;
                    }
                    catch {
                        "Failed to copy $($folder.Name) to WindowsPowerShell\Modules. Retrying once after killing WMIPRvSe.exe hosting DSC modules." | Out-File $log -Append
                        Get-Process wmiprvse* -ErrorAction SilentlyContinue | Where-Object { $_.modules.ModuleName -like "*DSC*" } | Stop-Process -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 60
                        Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force -ErrorAction SilentlyContinue
                        Import-Module $folder.Name -Force;
                    }
                }
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                $error_message | Out-File $log -Append
                Write-Error $error_message
                return $error_message
            }
        }

        $dscZipHash = (Get-FileHash -Path "$rootPath\DSC\DSC.zip" -Algorithm MD5).Hash

        if ($dscZipHash -ne $guestZipHash) {
            Write-Progress2 $Activity -Status "Expanding Modules" -percentcomplete 40 -force
            # Extract DSC modules
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Expanding modules inside the VM."
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Expand_Archive -DisplayName "Expand_Archive ScriptBlock"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to extract PS modules inside the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
            }
            Write-Progress2 $Activity -Status "Installing Modules" -percentcomplete 55 -force
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Installing DSC Modules."
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_InstallModules -DisplayName "DSC: Install Modules"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to install DSC modules. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
            }
        }
        else {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Skipped expanding and installing modules since DSC.zip is not newer."
        }

        $DSC_ClearStatus = {
            param(
                [String]$DscFolder
            )

            try {
                $global:ScriptBlockName = "DSC_ClearStatus"

                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $Phase = $using:Phase

                $log = "C:\staging\DSC\DSC_Init.txt"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
                "`r`n=====`r`nDSC_ClearStatus: Started at $time`r`n=====" | Out-File $log -Append

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
                $dscLog = "C:\staging\DSC\DSC_Log.txt"
                if (Test-Path $dscLog) {
                    $newName = $dscLog -replace ".txt", ((get-date).ToString("_yyyyMMdd_HHmmss") + ".txt")
                    "Renaming $dscLog to $newName" | Out-File $log -Append
                    Rename-Item -Path $dscLog -NewName $newName -Force -Confirm:$false -ErrorAction Stop
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
                $error_message | Out-File $log -Append
                Write-Error $error_message
                return $error_message
            }

            # Do some cleanup after we re-worked folder structure
            try {
                Remove-Item -Path "C:\staging\DSC\configmgr\modules" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path "C:\staging\DSC\configmgr\TemplateHelpDSC" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path "C:\staging\DSC\configmgr\DSC.zip" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path "C:\staging\DSC\createGuestDscZip.ps1" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path "C:\staging\DSC\DummyConfig.ps1" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
            }
        }
        Write-Progress2 $Activity -Status "Clearing DSC Status" -percentcomplete 65 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Clearing previous DSC status"
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ClearStatus -ArgumentList $DscFolder -DisplayName "DSC: Clear Old Status"
        if ($result.ScriptBlockFailed) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to clear old status. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
        }
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Previous DSC status cleared"
        $DSC_CreateSingleConfig = {
            param($DscFolder)

            try {
                $global:ScriptBlockName = "DSC_CreateSingleConfig"
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
                    "BDC" { $dscRole += "BDC" }
                    "WorkgroupMember" { $dscRole += "WorkgroupMember" }
                    "AADClient" { $dscRole += "WorkgroupMember" }
                    "InternetClient" { $dscRole += "WorkgroupMember" }
                    default { $dscRole += "DomainMember" }
                }

                # Define DSC variables
                $dscConfigScript = "C:\staging\DSC\$DscFolder\$($dscRole).ps1"
                $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"
                $deployConfigPath = "C:\staging\DSC\deployConfig.json"

                # Update init log
                $log = "C:\staging\DSC\DSC_Init.txt"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
                "`r`n=====`r`nDSC_CreateConfig: Started at $time`r`n=====" | Out-File $log -Append
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
                "Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append
                & "$($dscRole)" -DeployConfigPath $deployConfigPath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath $dscConfigPath
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                $error_message | Out-File $log -Append
                Write-Error $error_message
                return $error_message
            }
        }

        $DSC_CreateMultiConfig = {
            param($DscFolder)
            try {
                $global:ScriptBlockName = "DSC_CreateMultiConfig"

                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $deployConfig = $using:deployConfig
                $ConfigurationData = $using:ConfigurationData
                $adminCreds = $using:Common.LocalAdmin
                $Phase = $using:Phase
                $dscRole = "Phase$Phase"

                # Define DSC variables
                $dscConfigScript = "C:\staging\DSC\$DscFolder\$($dscRole).ps1"
                $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"
                $deployConfigPath = "C:\staging\DSC\deployConfig.json"

                # Update init log
                $log = "C:\staging\DSC\DSC_Init.txt"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
                "`r`n=====`r`nDSC_CreateConfig: Started at $time`r`n=====" | Out-File $log -Append
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

                # Dump $cd, in case we need to review
                $cd | ConvertTo-Json -Depth 5 | Out-File "C:\staging\DSC\Phase$($Phase)_CD.json" -Force -Confirm:$false

                # Create domain creds
                $netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
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
                "Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append
                & "$($dscRole)" -DeployConfigPath $deployConfigPath -AdminCreds $credsForDSC -ConfigurationData $cd -OutputPath $dscConfigPath
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                $error_message | Out-File $log -Append
                Write-Error $error_message
                return $error_message
            }
        }

        $DSC_StartConfig = {
            param($DscFolder)
            try {
                $global:ScriptBlockName = "DSC_StartConfig"
                # Get required variables from parent scope
                $currentItem = $using:currentItem
                $ConfigurationData = $using:ConfigurationData
                $Phase = $using:Phase

                # Define DSC variables
                $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"

                # Update init log
                $log = "C:\staging\DSC\DSC_Init.txt"
                $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
                "`r`n=====`r`nDSC_StartConfig: Started at $time`r`n=====" | Out-File $log -Append

                # Run for single-node DSC, multi-node DSC fail with Set-DscLocalConfigurationManager
                if ($ConfigurationData.AllNodes.NodeName -contains "LOCALHOST") {
                    "Set-DscLocalConfigurationManager for $dscConfigPath" | Out-File $log -Append
                    Set-DscLocalConfigurationManager -Path $dscConfigPath -Verbose

                    "Start-DscConfiguration for $dscConfigPath" | Out-File $log -Append
                    Start-DscConfiguration -Wait -Path $dscConfigPath -Force -Verbose -ErrorAction Stop
                }
                else {
                    # Use domainCreds instead of local Creds for multi-node DSC
                    $userdomain = $deployConfig.vmOptions.domainName.Split(".")[0]
                    $user = "$userdomain\$($using:Common.LocalAdmin.UserName)"
                    $creds = New-Object System.Management.Automation.PSCredential ($user, $using:Common.LocalAdmin.Password)
                    "Start-DscConfiguration for $dscConfigPath with $user credentials" | Out-File $log -Append
                    Start-DscConfiguration -Path $dscConfigPath -Force -Verbose -ErrorAction Stop -Credential $creds -JobName $currentItem.vmName
                }
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                $error_message | Out-File $log -Append
                Write-Error $error_message
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
                do {
                    $attempts++
                    $allNodesReady = $true
                    $nonReadyNodes = $nodeList.Clone()
                    $percent = [Math]::Min($attempts, 100)
                    Write-Progress2 "Waiting for all nodes. Attempt #$attempts/100" -Status "Waiting for [$($nonReadyNodes -join ',')] to be ready." -PercentComplete $percent
                    foreach ($node in $nonReadyNodes) {
                        $result = Invoke-VmCommand -VmName $node -ScriptBlock { Test-Path "C:\staging\DSC\DSC_Status.txt" } -DisplayName "DSC: Check Nodes Ready"
                        if (-not $result.ScriptBlockFailed -and $result.ScriptBlockOutput -eq $true) {
                            Write-Log "[Phase $Phase]: Node $node is NOT ready."
                            $allNodesReady = $false
                        }
                        else {
                            $nodeList.Remove($node) | Out-Null
                            if ($nodeList.Count -eq 0) {
                                Write-Progress2 "Waiting for all nodes. Attempt #$attempts/100" -status "All nodes are ready" -PercentComplete 100
                                $allNodesReady = $true
                            }
                            Write-Progress2 "Waiting for all nodes. Attempt #$attempts/100" -Status "Waiting for [$($nodeList -join ',')] to be ready." -PercentComplete $percent
                        }
                    }

                    Start-Sleep -Seconds 6
                } until ($allNodesReady -or $attempts -ge 100)

                if (-not $allNodesReady) {
                    Write-Progress2 "Failed waiting on VMs [$($nodeList -join ',')].  Please cancel and retry this phase."
                    write-log "[Phase $Phase]: Node [$($nodeList -join ',')] is NOT ready after 100 attempts." -failure -OutputStream
                    return $false
                }

            }
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Finished waiting on all nodes"

            Write-Progress2 "Starting DSC" -status "Invoking DSC_CreateConfig" -PercentComplete 0
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_CreateConfig -ArgumentList $DscFolder -DisplayName "DSC: Create $($currentItem.role) Configuration"
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to create $($currentItem.role) configuration. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
            }

            Write-Progress2 "Starting DSC" -status "Invoking DSC_StartConfig" -PercentComplete 50
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
            if ($result.ScriptBlockFailed) {
                Start-Sleep -Seconds 15
                Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to start $($currentItem.role) configuration. Retrying once. $($result.ScriptBlockOutput)" -Warning
                # Retry once before exiting
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to Start $($currentItem.role) configuration. Exiting. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }
            }
            Write-Progress2 "Starting DSC" -status "[Phase $Phase]: $($currentItem.vmName): Started DSC for $($currentItem.role) configuration." -PercentComplete 100
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Started DSC for $($currentItem.role) configuration."
        }

        ### ===========================
        ### Start Monitoring the jobs
        ### ===========================

        $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
        $timeout = $using:RoleConfigTimeoutMinutes
        $timeSpan = New-TimeSpan -Minutes $timeout
        $stopWatch.Start()

        $complete = $false
        $previousStatus = ""
        $currentStatus = $null
        $suppressNoisyLogging = $Common.VerboseEnabled -eq $false
        [int]$failedHeartbeats = 0
        [int]$failedHeartbeatThreshold = 100 # 3 seconds * 100 tries = ~5 minutes

        $noStatus = $true

        Write-Log "[Phase $Phase]: $($currentItem.vmName): Started Monitoring $($currentItem.role) configuration."

        try {
            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Ready and Waiting for job progress"
        }
        catch {

        }
        $dscStatusPolls = 0
        [int]$failCount = 0
        try {
            do {

                #$bob =  (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { (get-job -Name AoG -IncludeChildJob).Progress | Select-Object -last 1 | select-object -ExpandProperty CurrentOperation }).ScriptBlockOutput
                #$bob = (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ((get-job -Name AoG)).StatusMessage }).ScriptBlockOutput
                #$bob2 = (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { (get-job -IncludeChildJob |  ConvertTo-Json) }).ScriptBlockOutput
                #write-log $bob2

                $dscStatusPolls++

                if ($dscStatusPolls -ge 10) {
                    $failure = $false
                    $dscStatusPolls = 0 # Do this every 30 seconds or so
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Polling DSC Status via Get-DscConfigurationStatus" -Verbose
                    $dscStatus = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                        $ProgressPreference = 'SilentlyContinue'
                        Get-DscConfigurationStatus
                        $ProgressPreference = 'Continue'
                    } -SuppressLog:$suppressNoisyLogging

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
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Status: $($dscStatus.ScriptBlockOutput.Status) : $msg" -Failure -OutputStream
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "[Phase $Phase]: $($currentItem.vmName): Status: $($dscStatus.ScriptBlockOutput.Status) : $msg"
                                    $failure = $true
                                }
                                else {
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "DSC is attempting to restart"
                                }
                            }

                            # Write-Output, and bail
                            if (-not $msg) {
                                #  [x] [<ScriptBlock>] ADA-W11Client1: DSC encountered failures. Attempting to continue. Status: Failure Output: Machine reboot failed. Please reboot it manually to finish processing the request.
                                # This condition is expected, and we are actually rebooting.
                                if ($($dscStatus.ScriptBlockOutput.Error) -like "*Machine reboot failed*") {
                                    #If we dont reboot, maybe have a counter here, and after 30 or so, we can invoke a reboot command.
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
                                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Attempting to continue. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)" -Warning -OutputStream
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text  "[Phase $Phase]: $($currentItem.vmName): DSC encountered failures. Attempting to continue. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)"
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
                $status = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt -ErrorAction SilentlyContinue } -SuppressLog:$suppressNoisyLogging
                $stopwatch2.Stop()

                if (-not $status -or ($status.ScriptBlockFailed)) {
                    if ($stopwatch2.elapsed.TotalSeconds -gt 10) {
                        [int]$failedHeartbeats = [int]$failedHeartbeats + ([math]::Round($stopwatch2.elapsed.TotalSeconds / 5, 0))
                    }
                    else {
                        [int]$failedHeartbeats++
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
                        Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt -ErrorAction SilentlyContinue } -ShowVMSessionError | Out-Null # Try the command one more time to get failure in logs

                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Failed to retrieve job status from VM, forcefully restarting the VM" -failcount $failedHeartbeats -failcountMax $failedHeartbeatThreshold

                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to retrieve job status from VM after $failedHeartbeatThreshold tries. Forcefully restarting the VM" -Warning
                        Stop-VM2 -name $currentItem.vmName -TurnOff
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Failed to retrieve job status from VM, VM Stopped"

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

                if ($status.ScriptBlockOutput -and $status.ScriptBlockOutput -is [string]) {
                    $noStatus = $false
                    $currentStatus = $status.ScriptBlockOutput | Out-String

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
                    }

                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $currentStatus
                    # Special case to write log ConfigMgrSetup.log entries in progress
                    $skipProgress = $false
                    $setupPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
                    if ($currentStatus.StartsWith($setupPrefix)) {
                        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content "C:\ConfigMgrSetup.log" -tail 1 } -SuppressLog
                        if (-not $result.ScriptBlockFailed) {
                            $logEntry = $result.ScriptBlockOutput
                            if (-not [string]::IsNullOrWhiteSpace($logEntry)) {
                                try {
                                    if ($logEntry.Contains("$")) {
                                        $logEntry = "ConfigMgrSetup.log: " + $logEntry.Substring(0, $logEntry.IndexOf("$"))
                                    }
                                }
                                catch {
                                    write-Log -LogOnly "[Phase $Phase]: $($currentItem.vmName): Failed SubString for ConfigMgrSetup.log in for line $logEntry : $_"
                                }
                                try {
                                    Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $logentry

                                }
                                catch {}
                            }
                            $skipProgress = $true
                        }
                    }

                    if (-not $skipProgress) {
                        # Write progress
                        try {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $status.ScriptBlockOutput
                        }
                        catch {

                        }
                    }

                    # Check if complete
                    $complete = $status.ScriptBlockOutput -eq "Complete!"
                    if ($complete) {
                        #~~===================== Failed Configuration Manager Server Setup =====================
                        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\ConfigMgrSetup.log -tail 10 | Select-String "Failed Configuration Manager Server Setup" -Context 0, 0 } -SuppressLog
                        if ($result.ScriptBlockOutput.Line) {
                            Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: $($currentItem.role) failed: $($result.ScriptBlockOutput.Line) Please Check C:\ConfigMgrSetup.log." -Failure -OutputStream
                            return
                        }
                    }
                    # ~Setup has encountered fatal errors
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\ConfigMgrSetup.log -tail 10 | Select-String "~Setup has encountered fatal errors" -Context 0, 0 } -SuppressLog
                    if ($result.ScriptBlockOutput.Line) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: $($currentItem.role) failed: $($result.ScriptBlockOutput.Line) Please Check C:\ConfigMgrSetup.log." -Failure -OutputStream
                        return
                    }
                    #ERROR: Computer account doesn't have admininstrative rights to the SQL Server~
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\ConfigMgrSetup.log -tail 10 | Select-String "ERROR: Computer account doesn't have admininstrative rights to the SQL Server~" -Context 0, 0 } -SuppressLog
                    if ($result.ScriptBlockOutput.Line) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: $($currentItem.role) failed: $($result.ScriptBlockOutput.Line) Please Check C:\ConfigMgrSetup.log." -Failure -OutputStream
                        return
                    }
                }
                else {
                    if ($noStatus) {
                        try {
                            Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Waiting for job progress"
                        }
                        catch { }
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
        }

        # Update VMNote and set new version, this code doesn't run when VM_Create failed
        if ($using:Phase -gt 1 -and -not $currentItem.hidden) {
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $complete -UpdateVersion
        }

        if (-not $complete) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Configuration did not finish successfully for $($currentItem.role). Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))" -OutputStream -Failure
        }
        else {
            Write-Progress2 "$($currentItem.role) Configuration completed successfully. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))" -Status $status.ScriptBlockOutput -Completed
            Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Configuration completed successfully for $($currentItem.role)." -OutputStream -Success
        }
    }
    catch {
        Write-Progress2 "Exception Occurred" -Status "Failed end2 $_"
        Write-Exception -ExceptionInfo $_
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)" -LogOnly
    }
}