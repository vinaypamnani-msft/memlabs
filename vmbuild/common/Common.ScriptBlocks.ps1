
# Create VM script block
$global:VM_Create = {

    try {
        $global:ScriptBlockName = "VM_Create"
        # Dot source common
        #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

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
            if ($currentItem.domain) {
                $domainName = $currentItem.domain
            }
        }
        else {
            $domainName = "WORKGROUP"
        }

        # Set base VM path
        $virtualMachinePath = Join-Path $deployConfig.vmOptions.basePath $deployConfig.vmOptions.domainName

        if ($createVM) {

            # Check if VM already exists
            $exists = Get-VM2 -Name $currentItem.vmName -ErrorAction SilentlyContinue
            if ($exists) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM already exists. Exiting." -Failure -OutputStream -HostOnly
                return
            }

            # Determine which OS image file to use for the VM
            if ($currentItem.role -notin "OSDClient") {
                $imageFile = $azureFileList.OS | Where-Object { $_.id -eq $currentItem.operatingSystem }
                if ($imageFile) {
                    $vhdxPath = Join-Path $Common.AzureFilesPath $imageFile.filename
                }
                if (-not $vhdxPath) {
                    $linuxFile = (Get-LinuxImages).Name | Where-Object { $_ -eq $currentItem.operatingSystem }
                    if ($linuxFile) {
                        $vhdxPath = Join-Path $Common.AzureImagePath $($linuxFile + ".vhdx")
                    }
                    if (-not $vhdxPath) {
                        throw "Could not find $($currentItem.operatingSystem) in file list"
                    }
                }
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

            if ($currentItem.role -eq "Linux") {
                $HashArguments.Add("DiskControllerType", "IDE")
            }

            $created = New-VirtualMachine @HashArguments

            if (-not ($created -eq $true)) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM was not created. Check vmbuild logs. $created" -Failure -OutputStream -HostOnly
                return
            }

            if (-not $Migrate) {
                if ($currentItem.role -in ("OSDClient", "Linux")) {
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
                        Write-Log -LogOnly '11Calling Remove-DhcpServerv4Reservation -IPAddress ($network + ".5") -ErrorAction SilentlyContinue'
                        Remove-DhcpServerv4Reservation -IPAddress ($network + ".5") -ErrorAction SilentlyContinue
                        Add-DhcpServerv4Reservation -ScopeId $realnetwork -IPAddress ($network + ".5") -ClientId $vmnet.MacAddress -Description "Reservation for CAS" -ErrorAction Stop
                    }
                    if ($currentItem.role -eq "Primary") {
                        Write-Log -LogOnly '12Calling Remove-DhcpServerv4Reservation -IPAddress ($network + ".10") -ErrorAction SilentlyContinue'
                        Remove-DhcpServerv4Reservation -IPAddress ($network + ".10") -ErrorAction SilentlyContinue
                        Add-DhcpServerv4Reservation -ScopeId $realnetwork -IPAddress ($network + ".10") -ClientId $vmnet.MacAddress -Description "Reservation for Primary" -ErrorAction Stop
                    }
                    if ($currentItem.role -eq "Secondary") {
                        Write-Log -LogOnly '13Calling Remove-DhcpServerv4Reservation -IPAddress ($network + ".15") -ErrorAction SilentlyContinue'
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
            start-sleep -seconds 60
            $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName
            if (-not $ps) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
                return
            }
        }

        if ($Migrate) {
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Disk | Set-Disk -IsOffline 0 }
            if ($result.ScriptBlockFailed) {
                start-sleep -seconds 60
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Disk | Set-Disk -IsOffline 0 }
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed set-disk to online. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }
            }

            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Disk | Where-Object { $_.IsReadOnly } | Set-Disk -IsReadOnly 0 }
            if ($result.ScriptBlockFailed) {
                start-sleep -seconds 60
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
                        Get-Item $RemoveKey | Select-Object -ExpandProperty Property | ForEach-Object { Remove-ItemProperty -Path $RemoveKey -Name $_ -Force }
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
            start-sleep -seconds 60
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue }
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set PS ExecutionPolicy to Bypass for LocalMachine. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
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
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Set_TLS12Keys -DisplayName "Setting TLS 1.2 Registry Keys" -ArgumentList $domainNameForLogging
            if ($result.ScriptBlockFailed) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed to set TLS 1.2 Registry Keys." -Warning -OutputStream
            }

            if ($currentItem.role -in "WorkgroupMember", "InternetClient") {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Fix_WorkGroupMachines"
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_WorkGroupMachines -DisplayName "Fix_WorkGroupMachines"
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): Failed Fix_WorkGroupMachines" -Warning -OutputStream
                }
            }
            # Set vm note
            if (-not $skipVersionUpdate) {
                $inProgress = (-not $Migrate)
                New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -InProgress $inProgress
            }
        }

        # Copy SQL files to VM
        if ($currentItem.sqlVersion -and $createVM) {

            Write-Log "[Phase $Phase]: $($currentItem.vmName): Copying SQL installation files to the VM."
            Write-Progress2 -Activity "$($currentItem.vmName): Copying SQL installation files to the VM" -Completed

            # Determine which SQL version files should be used
            $sqlFiles = $azureFileList.ISO | Where-Object { $_.id -eq $currentItem.sqlVersion }

            # SQL Iso Path
            $sqlIso = $sqlFiles.filename | Where-Object { $_.ToLowerInvariant().EndsWith(".iso") }
            $sqlIsoPath = Join-Path $Common.AzureFilesPath $sqlIso

            # Add SQL ISO to guest
            Set-VMDvdDrive -VMName $currentItem.vmName -Path $sqlIsoPath

            # Create C:\temp\SQL & C:\temp\SQL_CU inside VM
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { New-Item -Path "C:\temp\SQL" -ItemType Directory -Force }
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { New-Item -Path "C:\temp\SQL_CU" -ItemType Directory -Force }

            # Copy files from DVD
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -DisplayName "Copy SQL Files" -ScriptBlock { $cd = Get-Volume | Where-Object { $_.DriveType -eq "CD-ROM" }; Copy-Item -Path "$($cd.DriveLetter):\*" -Destination "C:\temp\SQL" -Recurse -Force -Confirm:$false }
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
        #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        # Get variables from parent scope
        $deployConfig = $using:deployConfigCopy
        $currentItem = $using:currentItem
        $enableVerbose = $using:enableVerbose
        $Phase = $using:Phase
        $ConfigurationData = $using:ConfigurationData
        $multiNodeDsc = $using:multiNodeDsc
        $reservation = $using:reservation

        # Dot source common
        $rootPath = Split-Path $using:PSScriptRoot -Parent
        . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

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
            if ($currentItem.domain) {
                $domainName = $currentItem.domain
            }
        }
        else {
            $domainName = "WORKGROUP"
        }

        # Get VM Session
        Write-Progress2 $Activity -Status "Establishing a connection with the VM" -percentcomplete 0 -force

        # Verify again that VM is connectable, in case DSC caused a reboot
        $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName
        if (-not $connected) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not verify if VM is connectable. Exiting." -Failure -OutputStream
            return
        }

        $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName

        if (-not $ps) {
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
            return
        }


        $Stop_RunningDSC = {
            # Stop any existing DSC runs
            try {
                get-job | remove-job

                Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force | out-null
                $job = Stop-DscConfiguration -Force -AsJob
                $wait = Wait-Job -Timeout 600 $job
                if ($wait.State -eq "Running") {
                    Stop-Job $job
                    get-job | remove-job
                    Restart-Service -Name WinMgmt -force
                }
                else {
                    if ($wait.State -eq "Completed") {
                        get-job | remove-job
                    }
                    else {
                        write-host "State = $($wait.State)"
                        Stop-Job $job
                        get-job | remove-job
                        Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force
                        Stop-DscConfiguration -Verbose -Force
                    }

                }
                Disable-DscDebug -force | Out-Null

            }
            catch {
                Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force
                Stop-DscConfiguration -Verbose -Force
            }
        }

        Write-Progress2 $Activity -Status "Stopping DSCs" -percentcomplete 5 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Stopping any previously running DSC Configurations."
        $result = Invoke-VmCommand -AsJob -TimeoutSeconds 60 -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
        if ($result.ScriptBlockFailed) {
            Write-Progress2 $Activity -Status "Retry Stopping DSCs" -percentcomplete 5 -force
            $result = Invoke-VmCommand -AsJob -TimeoutSeconds 60 -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
            if ($result.ScriptBlockFailed) {
                Write-Progress2 $Activity -Status "Restarting VM then Stopping DSCs" -percentcomplete 5 -force
                Stop-vm2 -name $currentItem.vmName -force
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

        if ($Phase -ge 2) {
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

                            if ($retryCount -eq 1) {
                                Write-Progress2 $Activity -Status "Attempting to repair network $($currentItem.network) " -percentcomplete 10 -force
                                stop-vm2 -Name $currentItem.vmname
                                Remove-VMSwitch2 -NetworkName $($currentItem.network)
                                Remove-DhcpServerv4Scope -scopeID $($currentItem.network) -ErrorAction SilentlyContinue
                                stop-service "DHCPServer" | Out-Null
                                $dhcp = Start-DHCP
                                start-sleep -seconds 10
                                $DC = get-list2 -deployConfig $deployConfig | where-object { $_.role -eq "DC" }
                                $DNSServer = ($DC.Network.Substring(0, $DC.Network.LastIndexOf(".")) + ".1")
                                $worked = Add-SwitchAndDhcp -NetworkName $currentItem.network -NetworkSubnet $currentItem.network -DomainName $deployConfig.vmOptions.domainName -DNSServer $DNSServer -WhatIf:$WhatIf -erroraction SilentlyContinue

                                start-vm2 -Name $currentItem.vmname
                                $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $deployConfig.vmOptions.domainName
                                $IPrenew = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ipconfig /renew .\cache } -DisplayName "FixIPs"
                            }
                            if ($retryCount -eq 0) {
                                stop-service "DHCPServer" | Out-Null
                                start-sleep -seconds 5
                                $dhcp = Start-DHCP
                                $IPrenew = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ipconfig /renew } -DisplayName "FixIPs"
                            }
                            if ($retryCount -eq 2) {
                                $count = (Get-VMSwitch).Count
                                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM Could not obtain a DHCP IP Address ($ip) Should be on $($currentItem.network) ($count Hyper-V switches in use. If this is over 20, this could be the issue)" -Failure -OutputStream
                                return
                            }
                            $retryCount++
                        }
                    }
                }
            }
        }

        # inject tools
        if ($Phase -eq 2) {

            Write-Progress2 $Activity -Status "Injecting Tools" -percentcomplete 10 -force
            $injected = Install-Tools -VmName $currentItem.vmName -ShowProgress
            if (-not $injected) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): Could not inject tools in the VM." -Warning
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
            Write-Progress2 $Activity -Status "Testing DHCP Reservations" -percentcomplete 9 -force
            $vm = Get-VM2 $currentItem.vmName
            $MAC = ($vm.NetworkAdapters | Where-Object { $_.SwitchName -eq "Cluster" }).MacAddress
            #$Get_MAC = {
            # (Get-NetAdapter | Where-Object { $_.InterfaceDescription.contains('#2') }).MacAddress
            #}
            # Test DHCP Reservations

            #$script = Invoke-VmCommand -SuppressLog -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Get_MAC -DisplayName "Get 2nd Mac"
            #Write-Progress2 $Activity -Status "Testing DHCP Reservations" -percentcomplete 9 -force
            #$MAC = $script.ScriptBlockOutput
            if ($MAC) {
                $MAC = $MAC.ToLower()
                if ($reservation) {
                    #Reservation is now a using statement, as getting the data here causes status to break
                    if ($reservation.Contains($MAC)) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Reservation for $MAC was found" -LogOnly
                    }
                    else {
                        #Get-DhcpServerv4Reservation -ClientId $MAC -ScopeId 10.250.250.0 -ErrorAction SilentlyContinue
                        #if (!$reservation) {
                        Write-Log "[Phase $Phase]: $($currentItem.vmName): Reservation for $MAC not found" -Warning -LogOnly
                        $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }
                        if (-not ($dc.network)) {
                            $dns = $deployConfig.vmOptions.network.Substring(0, $deployConfig.vmOptions.network.LastIndexOf(".")) + ".1"
                        }
                        else {
                            $dns = $dc.network.Substring(0, $dc.network.LastIndexOf(".")) + ".1"
                        }
                        $iprange = Get-DhcpServerv4FreeIPAddress -ScopeId "10.250.250.0" -NumAddress 2 -ErrorAction Stop
                        if (! $iprange) {
                            $iprange = Get-DhcpServerv4FreeIPAddress -ScopeId "10.250.250.0" -NumAddress 2 -ErrorAction Stop
                        }
                        if (! $iprange) {
                            Write-Log "$VmName`: Could not acquire a free cluster DHCP Address" -Failure
                            return $false
                        }
                        if ($currentItem.OtherNode) {
                            $ip = $iprange[1]
                        }
                        else {
                            $ip = $iprange[0]
                        }
                        if ($ip) {
                            Write-Log -LogOnly '14Calling $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" -erroraction SilentlyContinue | Where-Object { $_.IpAddress -eq $ip } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue  '
                            $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" -erroraction SilentlyContinue | Where-Object { $_.IpAddress -eq $ip } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue                              
                        }

                        Write-Log -LogOnly '15Calling Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.ClientId -replace "-", "" -eq $($vmnet.MacAddress) } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue -Force'
                        Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.ClientId -replace "-", "" -eq $($vmnet.MacAddress) } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue -Force
                        Write-Log -LogOnly '16Calling Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.Name -like $($currentItem.vmName) + ".*" } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue -Force'
                        Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.Name -like $($currentItem.vmName) + ".*" } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue -Force

                        Write-Progress2 $Activity -Status "Adding DHCP Reservations for scope 10.250.250.0 ip: $ip MAC: $MAC" -percentcomplete 11 -force
                        Add-DhcpServerv4Reservation -ScopeId "10.250.250.0" -IPAddress $ip -ClientId $MAC -Description "Reservation for $($currentItem.VMName)" -ErrorAction Stop | out-null
                        Set-DhcpServerv4OptionValue -optionID 6 -value $dns -ReservedIP $ip -Force -ErrorAction Stop | out-null
                        Set-DhcpServerv4OptionValue -optionID 44 -value $dns -ReservedIP $ip -Force -ErrorAction Stop | out-null
                        Set-DhcpServerv4OptionValue -optionID 15 -value $deployConfig.vmOptions.DomainName -ReservedIP $ip -Force -ErrorAction Stop | out-null
                        Start-DHCP
                        Start-Sleep -seconds 30
                        $script = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ipconfig /renew } -DisplayName "renew DHCP"
                    }
                }
            }
            else {
                Write-Log "[Phase $Phase]: $($currentItem.vmName):  $MAC was not found" -Warning
            }



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
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $oobeStarted
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
        $copyResults = Copy-ItemSafe -VmName $currentItem.vmName -VMDomainName $domainName -Path "$rootPath\DSC" -Destination "C:\staging" -Recurse -Container -Force

        $Expand_Archive = {

            $global:ScriptBlockName = "Expand_Archive"
            try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
            # Create init log
            $log = "C:\staging\DSC\DSC_Init.txt"
            $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'

            $zipPath = "C:\staging\DSC\DSC.zip"
            $extractPath = "C:\staging\DSC\modules"

            if (test-path -PathType Container $extractPath) {
                "$time : Expand_Archive is attempting to remove the existing folder $($extractPath)" | Out-File $log -Append

                try {
                    Remove-Item -Force -Recurse $extractPath -ErrorAction Continue
                }
                catch {
                    "$time : Failed to Remove $($extractPath)" | Out-File $log -Append
                }
            }

            "$time : Expand_Archive is attempting to expand $($zipPath) to $($extractPath)" | Out-File $log -Append
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
                try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
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
                        $targetFolder = Join-Path "C:\Program Files\WindowsPowerShell\Modules" $folder.Name
                        "Removing $($targetFolder) in WindowsPowerShell\Modules." | Out-File $log -Append
                        Remove-Item -Recurse -Force $targetFolder -ErrorAction SilentlyContinue
                    }
                    catch {
                        "Failed to delete $($targetFolder) in WindowsPowerShell\Modules. Continuing" | Out-File $log -Append
                    }

                }

                Start-Sleep 10

                foreach ($folder in $modules) {
                    try {

                        "Copying $($folder.FullName) to WindowsPowerShell\Modules." | Out-File $log -Append

                        Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force -ErrorAction Stop
                        "Import-Module $($folder.Name)" | Out-File $log -Append
                        Import-Module $folder.Name -Force
                    }
                    catch {
                        "Failed to copy $($folder.Name) to WindowsPowerShell\Modules. Retrying once after killing WMIPRvSe.exe hosting DSC modules." | Out-File $log -Append
                        Get-Process wmiprvse* -ErrorAction SilentlyContinue | Where-Object { $_.modules.ModuleName -like "*DSC*" } | Stop-Process -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 60
                        Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force -ErrorAction SilentlyContinue
                        Import-Module $folder.Name -Force
                    }
                }
            }
            catch {
                $error_message = "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName): Exception: $_ $($_.ScriptStackTrace)"
                $error_message | Out-File $log -Append
                Write-Error $error_message
                return $error_message
            }
            "Modules Installed" | Out-File $log -Append
        }

        $dscZipHash = (Get-FileHash -Path "$rootPath\DSC\DSC.zip" -Algorithm MD5).Hash

        if ($dscZipHash -ne $guestZipHash) {
            Write-Progress2 $Activity -Status "Expanding Modules" -percentcomplete 40 -force
            # Extract DSC modules
            Write-Log "[Phase $Phase]: $($currentItem.vmName): Expanding modules inside the VM."
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Expand_Archive -DisplayName "Expand_Archive ScriptBlock"
            if ($result.ScriptBlockFailed) {
                start-sleep -Seconds 60
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Expand_Archive -DisplayName "Expand_Archive ScriptBlock"
                if ($result.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase]: $($currentItem.vmName): DSC: Failed to extract PS modules inside the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
                    return
                }
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
                try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

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
                Remove-Item -Path "C:\staging\DSC\configmgr" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path "C:\staging\DSC\createGuestDscZip.ps1" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path "C:\staging\DSC\DummyConfig.ps1" -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
            }
        }

        Write-Progress2 $Activity -Status "Clearing DSC Status" -percentcomplete 65 -force
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Clearing previous DSC status"
        $result = Invoke-VmCommand -AsJob -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ClearStatus -ArgumentList $DscFolder -DisplayName "DSC: Clear Old Status"
        if ($result.ScriptBlockFailed) {
            start-sleep -seconds 60
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
                try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
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
                            Write-Error $data
                            return $data
                        }
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
                    foreach ($node in $nonReadyNodes) {
                        if (-not $node) {
                            continue
                        }
                        $result = Invoke-VmCommand -VmName $node -VmDomainName $deployConfig.vmOptions.domainName -ScriptBlock { Test-Path "C:\staging\DSC\DSC_Status.txt" } -DisplayName "DSC: Check Nodes Ready"
                        if (-not $result.ScriptBlockFailed -and $result.ScriptBlockOutput -eq $true) {
                            Write-Log "[Phase $Phase]: Node $node is NOT ready."
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
                            Write-Progress2 "Restarting $node" -PercentComplete $percent
                            Stop-Vm2 -Name $node -force:$true
                            Start-Sleep -seconds 20
                            Start-VM2 -Name $node
                            Start-Sleep -seconds 60
                        }
                    }

                    Start-Sleep -Seconds 6
                } until ($allNodesReady -or $attempts -ge $maxAttempts)

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
                        Get-DscConfigurationStatus
                        $ProgressPreference = 'Continue'
                    } -SuppressLog:$suppressNoisyLogging

                    if (-not $dscStatus) {
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Get-DscConfigurationStatus did not complete"
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

                    if (-not $rebooted -and $dscStatus.RebootRequested -eq $true) {
                        # Reboot the machine
                        start-sleep -Seconds 90 # Wait 90 seconds and re-request.. maybe its going to reboot itself.
                        $dscStatus = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -TimeoutSeconds 120 -ScriptBlock {
                            $ProgressPreference = 'SilentlyContinue'
                            Get-DscConfigurationStatus
                            $ProgressPreference = 'Continue'
                        } -SuppressLog:$suppressNoisyLogging
                        # Reboot the machine
                        if ($dscStatus.RebootRequested) {
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
                                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "ADServerDownException, VM Started. Waiting 300 seconds to check status."

                                        Start-Sleep -Seconds 100

                                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "ADServerDownException, VM Started. Waiting 200 seconds to check status."

                                        Start-Sleep -Seconds 100
                                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "ADServerDownException, VM Started. Waiting 100 seconds to check status."

                                        Start-Sleep -Seconds 90
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
                $status = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -AsJob -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt -ErrorAction SilentlyContinue } -SuppressLog:$suppressNoisyLogging
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
                        Stop-VM2 -name $currentItem.vmName -Force
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

                    if (-not $skipProgress) {
                        # Write progress
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text $status.ScriptBlockOutput
                    }

                    # Check if complete
                    $complete = $status.ScriptBlockOutput -eq "Complete!"
                    if (-not $complete) {
                        $complete = $status.ScriptBlockOutput -eq "Setting up ConfigMgr. Status: Complete!"
                    }
                    if (-not $complete) {
                        #$complete = ($dscStatus.ScriptBlockOutput -and $dscStatus.ScriptBlockOutput.Status -eq "Success")
                    }

                    $bailEarly = $false
                    if ($complete) {
                        #~~===================== Failed Configuration Manager Server Setup =====================
                        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\ConfigMgrSetup.log -tail 10 | Select-String "Failed Configuration Manager Server Setup" -Context 0, 0 } -SuppressLog
                        if ($result.ScriptBlockOutput.Line) {
                            $failEntry = $result.ScriptBlockOutput.Line
                            $bailEarly = $true
                        }
                    }

                    # ~Setup has encountered fatal errors
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\ConfigMgrSetup.log -tail 10 | Select-String "~Setup has encountered fatal errors" -Context 0, 0 } -SuppressLog
                    if ($result.ScriptBlockOutput.Line) {
                        $failEntry = $result.ScriptBlockOutput.Line
                        $bailEarly = $true
                    }

                    #ERROR: Computer account doesn't have admininstrative rights to the SQL Server~
                    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\ConfigMgrSetup.log -tail 10 | Select-String "ERROR: Computer account doesn't have admininstrative rights to the SQL Server~" -Context 0, 0 } -SuppressLog
                    if ($result.ScriptBlockOutput.Line) {
                        $failEntry = $result.ScriptBlockOutput.Line
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
                        Write-ProgressElapsed -stopwatch $stopWatch -timespan $timespan -text "Waiting for job progress. Polls: $dscStatusPolls Failed Heartbeats: $failedHeartbeats Status: $($dscStatus.ScriptBlockOutput.Status)"
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
        }

        # Update VMNote and set new version, this code doesn't run when VM_Create failed
        if ($using:Phase -gt 1 -and -not $currentItem.hidden) {
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $complete
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
        Write-Exception -ExceptionInfo $_
        Write-Log "[Phase $Phase]: $($currentItem.vmName): $($global:ScriptBlockName) Exception: $_" -OutputStream -Failure
        Write-Log "[Phase $Phase]: $($currentItem.vmName): Trace: $($_.ScriptStackTrace)" -LogOnly
        Write-Progress "Exception Occurred" -Status "Failed end2 $_"
    }
}