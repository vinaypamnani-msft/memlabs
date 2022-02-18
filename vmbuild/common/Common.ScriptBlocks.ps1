
# Create VM script block
$global:VM_Create = {

    # Dot source common
    $rootPath = Split-Path $using:PSScriptRoot -Parent
    . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

    if (-not ($Common.LogPath)) {
        Write-Output "ERROR: $($currentItem.vmName): Logpath is null. Common.ps1 may not be initialized."
        return
    }

    # Get variables from parent scope
    $deployConfig = $using:deployConfigCopy
    $currentItem = $using:currentItem
    $azureFileList = $using:Common.AzureFileList

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
        $network = $deployConfig.vmOptions.network
    }

    # Set domain name, depending on whether we need to create new VM or use existing one
    if (-not $createVM -or ($currentItem.role -eq "DC") ) {
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
            Write-Log "PSJOB: $($currentItem.vmName): VM already exists. Exiting." -Failure -OutputStream -HostOnly
            return
        }

        # Create VM
        $vmSwitch = Get-VMSwitch2 -NetworkName $network

        $HashArguments = @{
            VmName          = $currentItem.vmName
            VmPath          = $virtualMachinePath
            AdditionalDisks = $currentItem.additionalDisks
            Memory          = $currentItem.memory
            Generation      = 2
            Processors      = $currentItem.virtualProcs
            SwitchName      = $vmSwitch.Name
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

        if (-not $created) {
            Write-Log "PSJOB: $($currentItem.vmName): VM was not created. Check vmbuild logs." -Failure -OutputStream -HostOnly
            return
        }

        if ($currentItem.role -eq "OSDClient") {
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $true -UpdateVersion
            Write-Log "PSJOB: $($currentItem.vmName): VM Creation completed successfully for $($currentItem.role)." -OutputStream -Success
            return
        }

        # Wait for VM to finish OOBE
        $oobeTimeout = 15
        if ($deployConfig.virtualMachines.Count -gt 5) {
            $oobeTimeout = $deployConfig.virtualMachines.Count + 10
        }

        $connected = Wait-ForVm -VmName $currentItem.vmName -OobeComplete -TimeoutMinutes $oobeTimeout
        if (-not $connected) {
            Write-Log "PSJOB: $($currentItem.vmName): Could not verify if OOBE finished. Exiting." -Failure -OutputStream
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
                Write-Log "PSJOB: $($currentItem.vmName): Could not start the VM. Exiting." -Failure -OutputStream
                return
            }
        }

        # Check if RDP is enabled on DC. We saw an issue where RDP was enabled on DC, but didn't take effect until reboot.
        if ($currentItem.role -eq "DC") {
            $testNet = Test-NetConnection -ComputerName $currentItem.vmName -Port 3389
            if (-not $testNet.TcpTestSucceeded) {
                Write-Log "PSJOB: $($currentItem.vmName): Could not verify if RDP is enabled. Restarting the computer." -OutputStream -Warning
                Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Restart-Computer -Force } | Out-Null
                Start-Sleep -Seconds 10
            }
        }

        $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName
        if (-not $connected) {
            Write-Log "PSJOB: $($currentItem.vmName): Could not verify if VM is connectable. Exiting." -Failure -OutputStream
            return
        }
    }

    # Assign DHCP reservation for PS/CS
    if ($currentItem.role -in "Primary", "CAS", "Secondary" -and $createVM) {
        try {
            $vmnet = Get-VM2 -Name $currentItem.vmName -ErrorAction SilentlyContinue | Get-VMNetworkAdapter
            #$vmnet = Get-VMNetworkAdapter -VMName $currentItem.vmName -ErrorAction Stop
            if ($vmnet) {
                $network = $deployConfig.vmOptions.network.Substring(0, $deployConfig.vmOptions.network.LastIndexOf("."))
                if ($currentItem.role -eq "CAS") {
                    Remove-DhcpServerv4Reservation -IPAddress ($network + ".5") -ErrorAction SilentlyContinue
                    Add-DhcpServerv4Reservation -ScopeId $deployConfig.vmOptions.network -IPAddress ($network + ".5") -ClientId $vmnet.MacAddress -Description "Reservation for CAS" -ErrorAction Stop
                }
                if ($currentItem.role -eq "Primary") {
                    Remove-DhcpServerv4Reservation -IPAddress ($network + ".10") -ErrorAction SilentlyContinue
                    Add-DhcpServerv4Reservation -ScopeId $deployConfig.vmOptions.network -IPAddress ($network + ".10") -ClientId $vmnet.MacAddress -Description "Reservation for Primary" -ErrorAction Stop
                }
                if ($currentItem.role -eq "Secondary") {
                    Remove-DhcpServerv4Reservation -IPAddress ($network + ".15") -ErrorAction SilentlyContinue
                    Add-DhcpServerv4Reservation -ScopeId $deployConfig.vmOptions.network -IPAddress ($network + ".15") -ClientId $vmnet.MacAddress -Description "Reservation for Secondary" -ErrorAction Stop
                }
            }
        }
        catch {
            Write-Log "PSJOB: $($currentItem.vmName): Could not assign DHCP Reservation for $($currentItem.role). $_" -Warning
        }
    }

    # Get VM Session
    $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName

    if (-not $ps) {
        Write-Log "PSJOB: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
        return
    }

    # Set PS Execution Policy (required on client OS)
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue }
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): Failed to set PS ExecutionPolicy to Bypass for LocalMachine. $($result.ScriptBlockOutput)" -Failure -OutputStream
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
        Write-Log "PSJOB: $($currentItem.vmName): Updating Default user profile to fix a known sysprep issue."
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_DefaultProfile -DisplayName "Fix Default Profile"
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): Failed to fix the default user profile." -Warning -OutputStream
            $skipVersionUpdate = $true
        }

        Write-Log "PSJOB: $($currentItem.vmName): Updating Password Expiration for vmbuildadmin account."
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_LocalAccount -DisplayName "Fix Local Account Password Expiration"
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): Failed to fix the password expiration policy for vmbuildadmin." -Warning -OutputStream
            $skipVersionUpdate = $true
        }

        $timeZone = $deployConfig.vmOptions.timeZone
        if (-not $timeZone) {
            $timeZone = (Get-Timezone).id
        }

        Write-Log "PSJOB: $($currentItem.vmName): Setting timezone to '$timeZone'."
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { param ($timezone) Set-TimeZone -Id $timezone } -ArgumentList $timeZone -DisplayName "Setting timezone to '$timeZone'"
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): Failed to set the timezone." -Warning -OutputStream
        }

        Write-Log "PSJOB: $($currentItem.vmName): Setting TLS 1.2 registry keys."
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Set_TLS12Keys -DisplayName "Setting TLS 1.2 Registry Keys"
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): Failed to set TLS 1.2 Registry Keys." -Warning -OutputStream
        }

        # Set vm note
        if (-not $skipVersionUpdate) {
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -InProgress $true -UpdateVersion
        }
    }



    # Copy SQL files to VM
    if ($currentItem.sqlVersion -and $createVM) {

        Write-Log "PSJOB: $($currentItem.vmName): Copying SQL installation files to the VM."
        Write-Progress -Activity "$($currentItem.vmName): Copying SQL installation files to the VM" -Activity "Working" -Completed

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
            Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to copy SQL installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
        }

        # Eject ISO from guest
        Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
    }

    if ($createVM) {
        Write-Log "PSJOB: $($currentItem.vmName): VM Creation completed successfully for $($currentItem.role)." -OutputStream -Success
    }
    else {
        Write-Log "PSJOB: $($currentItem.vmName): Existing VM Preparation completed successfully for $($currentItem.role)." -OutputStream -Success
    }

}

$global:VM_Config = {

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
        Write-Output "ERROR: $($currentItem.vmName): Logpath is null. Common.ps1 may not be initialized."
        return
    }

    # Params for child script blocks
    $DscFolder = "phases"

    # Don't start DSC on any node except DC, for multi-DSC
    $skipStartDsc = $false
    if ($multiNodeDsc -and $currentItem.role -ne "DC") {
        $skipStartDsc = $true
    }

    # Determine if new VM
    $createVM = $true
    if ($currentItem.hidden -eq $true) { $createVM = $false }

    # Change log location
    $domainNameForLogging = $deployConfig.vmOptions.domainName
    $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"

    # Set domain name, depending on whether we need to create new VM or use existing one
    if (-not $createVM -or ($currentItem.role -eq "DC") ) {
        $domainName = $deployConfig.parameters.DomainName
    }
    else {
        $domainName = "WORKGROUP"
    }

    # Verify again that VM is connectable, in case DSC caused a reboot
    $connected = Wait-ForVM -VmName $currentItem.vmName -PathToVerify "C:\Users" -VmDomainName $domainName
    if (-not $connected) {
        Write-Log "PSJOB: $($currentItem.vmName): Could not verify if VM is connectable. Exiting." -Failure -OutputStream
        return
    }

    # Get VM Session
    $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName

    if (-not $ps) {
        Write-Log "PSJOB: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
        return
    }

    $Stop_RunningDSC = {
        # Stop any existing DSC runs
        try {
            Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force
            Stop-DscConfiguration -Verbose -Force
        }
        catch {
            Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force
            Stop-DscConfiguration -Verbose -Force
        }
    }

    Write-Log "PSJOB: $($currentItem.vmName): Stopping any previously running DSC Configurations."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): Failed to stop any running DSC's. $($result.ScriptBlockOutput)" -Warning -OutputStream
    }

    # Boot To OOBE?
    $bootToOOBE = $currentItem.role -eq "AADClient"
    if ($bootToOOBE) {
        # Run Sysprep
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-NetFirewallProfile -All -Enabled false }
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { C:\Windows\system32\sysprep\sysprep.exe /generalize /oobe /shutdown }
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): Failed to boot the VM to OOBE. $($result.ScriptBlockOutput)" -Failure -OutputStream
        }
        else {
            $ready = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -VmState "Off" -TimeoutMinutes 15
            if (-not $ready) {
                Write-Log "PSJOB: $($currentItem.vmName): Timed out while waiting for sysprep to shut the VM down." -OutputStream -Failure
            }
            else {
                $started = Start-VM2 -Name $currentItem.vmName -Passthru
                if ($started) {
                    $oobeStarted = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -OobeStarted -TimeoutMinutes 15
                    if ($oobeStarted) {
                        Write-Progress -Activity "Wait for VM to start OOBE" -Status "Complete!" -Completed
                        Write-Log "PSJOB: $($currentItem.vmName): Configuration completed successfully for $($currentItem.role). VM is at OOBE." -OutputStream -Success
                    }
                    else {
                        Write-Log "PSJOB: $($currentItem.vmName): Timed out while waiting for OOBE to start." -OutputStream -Failure
                    }
                }
                else {
                    Write-Log "PSJOB: $($currentItem.vmName): VM Failed to start." -OutputStream -Failure
                }

            }
        }
        # Update VMNote and set new version, this code doesn't run when VM_Create failed
        New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $oobeStarted -UpdateVersion
        return
    }

    # Enable PS Remoting on client OS before starting DSC. Ignore failures, this will work but reports a failure...
    if ($currentItem.operatingSystem -notlike "*SERVER*") {
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Enable-PSRemoting -ErrorAction SilentlyContinue -Confirm:$false -SkipNetworkProfileCheck } -DisplayName "DSC: Enable-PSRemoting. Ignore failures."
    }

    # Copy DSC files
    Write-Log "PSJOB: $($currentItem.vmName): Copying required PS modules to the VM."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { New-Item -Path "C:\staging\DSC" -ItemType Directory -Force }
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to copy required PS modules to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
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

    # Extract DSC modules
    Write-Log "PSJOB: $($currentItem.vmName): Expanding modules inside the VM."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Expand_Archive -DisplayName "Expand_Archive ScriptBlock"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to extract PS modules inside the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Install DSC Modules
    $DSC_InstallModules = {

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

    Write-Log "PSJOB: $($currentItem.vmName): Installing DSC Modules."

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_InstallModules -DisplayName "DSC: Install Modules"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to install DSC modules. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    $DSC_ClearStatus = {

        param($DscFolder)

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
            $Configuration.ScriptWorkFlow.Status = 'NotStart'
            $Configuration.ScriptWorkFlow.StartTime = ''
            $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
        }

        # Rename the DSC_Log that controls execution flow of DSC Logging and completion event before each run
        $dscLog = "C:\staging\DSC\DSC_Log.txt"
        if (Test-Path $dscLog) {
            $newName = $dscLog -replace ".txt", ((get-date).ToString("_yyyyMMdd_HHmmss") + ".txt")
            "Renaming $dscLog to $newName" | Out-File $log -Append
            Rename-Item -Path $dscLog -NewName $newName -Force -Confirm:$false -ErrorAction Stop
        }

        # Remove DSC_Status file, if exists
        $dscStatus = "C:\staging\DSC\DSC_Status.txt"
        if (Test-Path $dscStatus) {
            "Removing $dscStatus" | Out-File $log -Append
            Remove-Item -Path $dscStatus -Force -Confirm:$false -ErrorAction Stop
        }

        #
        $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"
        if (Test-Path $dscConfigPath) {
            $newName = $dscConfigPath -replace "DSCConfiguration", ("DSCConfiguration" + (get-date).ToString("_yyyyMMdd_HHmmss"))
            "Renaming $dscConfigPath to $newName" | Out-File $log -Append
            Rename-Item -Path $dscConfigPath -NewName $newName -Force -Confirm:$false -ErrorAction Stop
        }

        # Write config to file
        $deployConfig = $using:deployConfig
        $configFilePath = "C:\staging\DSC\deployConfig.json"

        "Writing DSC config to $configFilePath" | Out-File $log -Append
        if (Test-Path $configFilePath) {
            $newName = $configFilePath -replace ".json", ((get-date).ToString("_yyyyMMdd_HHmmss") + ".json")
            "Renaming $configFilePath to $newName" | Out-File $log -Append
            Rename-Item -Path $configFilePath -NewName $newName -Force -Confirm:$false -ErrorAction Stop
        }
        $deployConfig | ConvertTo-Json -Depth 3 | Out-File $configFilePath -Force -Confirm:$false
    }

    Write-Log "$jobName`: Clearing previous DSC status"
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ClearStatus -ArgumentList $DscFolder -DisplayName "DSC: Clear Old Status"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to clear old status. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    $DSC_CreateSingleConfig = {

        param($DscFolder)

        # Get required variables from parent scope
        $currentItem = $using:currentItem
        $deployConfig = $using:deployConfig
        $ConfigurationData = $using:ConfigurationData
        $adminCreds = $using:Common.LocalAdmin
        $Phase = $using:Phase

        # Set current role
        switch (($currentItem.role)) {
            "DC" { $dscRole = "DC" }
            "WorkgroupMember" { $dscRole = "WorkgroupMember" }
            "AADClient" { $dscRole = "WorkgroupMember" }
            "InternetClient" { $dscRole = "WorkgroupMember" }
            default { $dscRole = "DomainMember" }
        }

        # Define DSC variables
        $dscConfigScript = "C:\staging\DSC\$DscFolder\$($dscRole)Configuration.ps1"
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
        & "$($dscRole)Configuration" -DeployConfigPath $deployConfigPath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath $dscConfigPath
    }

    $DSC_CreateMultiConfig = {

        param($DscFolder)

        # Get required variables from parent scope
        $currentItem = $using:currentItem
        $deployConfig = $using:deployConfig
        $ConfigurationData = $using:ConfigurationData
        $adminCreds = $using:Common.LocalAdmin
        $Phase = $using:Phase
        $dscRole = "Phase$Phase"

        # Define DSC variables
        $dscConfigScript = "C:\staging\DSC\$DscFolder\$($dscRole)Configuration.ps1"
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
        . "$dscConfigScript"

        # Configuration Data
        $cd = @{
            AllNodes = @()
        }

        foreach ($node in $ConfigurationData.AllNodes) {
            $cd.AllNodes += $node
        }

        # Dump $cd, in case we need to review
        $cd | ConvertTo-Json -Depth 4 | Out-File "C:\staging\DSC\Phase$($Phase)_CD.json" -Force -Confirm:$false

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
        & "$($dscRole)Configuration" -DeployConfigPath $deployConfigPath -AdminCreds $credsForDSC -ConfigurationData $cd -OutputPath $dscConfigPath
    }

    $DSC_StartConfig = {

        param($DscFolder)

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

    $DSC_CreateConfig = $DSC_CreateSingleConfig
    if ($multiNodeDsc) {
        $DSC_CreateConfig = $DSC_CreateMultiConfig
    }

    if ($skipStartDsc) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC for $($currentItem.role) configuration will be started on the DC."
    }
    else {
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_CreateConfig -ArgumentList $DscFolder -DisplayName "DSC: Create $($currentItem.role) Configuration"
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to create $($currentItem.role) configuration. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
        }

        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to start $($currentItem.role) configuration. Retrying once. $($result.ScriptBlockOutput)" -Warning
            # Retry once before exiting
            $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $DscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
            if ($result.ScriptBlockFailed) {
                Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to Start $($currentItem.role) configuration. Exiting. $($result.ScriptBlockOutput)" -Failure -OutputStream
                return
            }
        }
        Write-Log "PSJOB: $($currentItem.vmName): Started DSC for $($currentItem.role) configuration."
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
    $suppressNoisyLogging = $Common.VerboseEnabled -eq $false
    $failedHeartbeats = 0
    $failedHeartbeatThreshold = 100 # 3 seconds * 100 tries = ~5 minutes

    $noStatus = $true
    try {
        Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" `
            -Status "Waiting for job progress" `-PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
    }
    catch {}
    $dscStatusPolls = 0
    $failCount = 0
    do {

        #$bob =  (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { (get-job -Name AoG -IncludeChildJob).Progress | Select-Object -last 1 | select-object -ExpandProperty CurrentOperation }).ScriptBlockOutput
        #$bob = (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ((get-job -Name AoG)).StatusMessage }).ScriptBlockOutput
        #$bob2 = (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { (get-job -IncludeChildJob |  ConvertTo-Json) }).ScriptBlockOutput
        #write-log $bob2

        $dscStatusPolls++

        if ($dscStatusPolls -ge 10) {
            $failure = $false
            $dscStatusPolls = 0 # Do this every 30 seconds or so
            Write-Log "PSJOB: $($currentItem.vmName): Polling DSC Status via Get-DscConfigurationStatus" -Verbose
            $dscStatus = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock {
                $ProgressPreference = 'SilentlyContinue'
                Get-DscConfigurationStatus
                $ProgressPreference = 'Continue'
            } -SuppressLog:$suppressNoisyLogging

            if ($dscStatus.ScriptBlockFailed) {
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
                            Write-Log "PSJOB: $($currentItem.vmName): Status: $($dscStatus.ScriptBlockOutput.Status) : $msg" -Failure -OutputStream
                            $failure = $true
                        }
                    }

                    # Write-Output, and bail
                    if (-not $msg) {
                        #  [x] [<ScriptBlock>] PSJOB: ADA-W11Client1: DSC encountered failures. Attempting to continue. Status: Failure Output: Machine reboot failed. Please reboot it manually to finish processing the request.
                        # This condition is expected, and we are actually rebooting.
                        if ($($dscStatus.ScriptBlockOutput.Error) -like "*Machine reboot failed*") {
                            #If we dont reboot, maybe have a counter here, and after 30 or so, we can invoke a reboot command.
                            continue
                        }
                        if ($($dscStatus.ScriptBlockOutput.Error) -like "*Could not find mandatory property*") {
                            Write-Log "PSJOB: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)" -Failure -OutputStream
                            $failure = $true
                        }

                        if ($($dscStatus.ScriptBlockOutput.Error) -like "*Compilation errors occurred*") {
                            Write-Log "PSJOB: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)" -Failure -OutputStream
                            $failure = $true
                        }

                        if ($($dscStatus.ScriptBlockOutput.Error) -ne $lasterror) {
                            $failCount = 0
                            Write-Log "PSJOB: $($currentItem.vmName): DSC encountered failures. Attempting to continue. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)" -Warning -OutputStream
                        }
                        $failCount++
                        if ($failCount -gt 100) {
                            Write-Log "PSJOB: $($currentItem.vmName): DSC encountered failures. Status: $($dscStatus.ScriptBlockOutput.Status) Output: $($dscStatus.ScriptBlockOutput.Error)" -Failure -OutputStream
                            $failure = $true
                        }
                        $lasterror = $($dscStatus.ScriptBlockOutput.Error)
                    }
                    if ($dscStatus.ScriptBlockOutput.Status -eq "Failure" -and $failure) {
                        return
                    }
                }
                else {
                    # Can't determine what DSC Status is, so do nothing and wait for timer to expire?
                }
            }
        }

        $status = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt -ErrorAction SilentlyContinue } -SuppressLog:$suppressNoisyLogging
        Start-Sleep -Seconds 3

        if ($status.ScriptBlockFailed) {
            $failedHeartbeats++
            # Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to get job status update. Failed Heartbeat Count: $failedHeartbeats" -Verbose
            if ($failedHeartbeats -gt 10) {
                try {
                    Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "Trying to retrieve job status from VM, attempt $failedHeartbeats/$failedHeartbeatThreshold" -PercentComplete ($failedHeartbeats / $failedHeartbeatThreshold * 100)
                }
                catch {}
            }
        }
        else {
            $failedHeartbeats = 0
        }

        if ($failedHeartbeats -gt $failedHeartbeatThreshold) {
            try {
                Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt -ErrorAction SilentlyContinue } -ShowVMSessionError | Out-Null # Try the command one more time to get failure in logs
                Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "Failed to retrieve job status from VM, forcefully restarting the VM" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to retrieve job status from VM after $failedHeartbeatThreshold tries. Forcefully restarting the VM" -Warning
                $vm = Get-VM2 -Name $($currentItem.vmName)
                Stop-VM -VM $vm -TurnOff | Out-Null
                Start-Sleep -Seconds 5
                Start-VM2 -Name $currentItem.vmName
                Start-Sleep -Seconds 15
                $failedHeartbeats = 0 # Reset heartbeat counter so we don't keep shutting down the VM over and over while it's starting up
            }
            catch {}
        }

        if ($status.ScriptBlockOutput -and $status.ScriptBlockOutput -is [string]) {
            $noStatus = $false
            $currentStatus = $status.ScriptBlockOutput | Out-String

            # Write to log if status changed
            if ($currentStatus -ne $previousStatus) {
                # Trim status for logging
                if ($currentStatus.Contains("; checking again in ")) {
                    $currentStatusTrimmed = $currentStatus.Substring(0, $currentStatus.IndexOf("; checking again in "))
                }
                else {
                    $currentStatusTrimmed = $currentStatus
                }

                if ($currentStatusTrimmed.Contains("JOBFAILURE: ")) {
                    Write-Log "PSJOB: $($currentItem.vmName): DSC: $($currentItem.role) failed: $currentStatusTrimmed" -Failure -OutputStream
                    break
                }

                Write-Log "PSJOB: $($currentItem.vmName): DSC: Current Status for $($currentItem.role): $currentStatusTrimmed"
                $previousStatus = $currentStatus
            }

            # Special case to write log ConfigMgrSetup.log entries in progress
            $skipProgress = $false
            $setupPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
            if ($currentStatus.StartsWith($setupPrefix)) {
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content "C:\ConfigMgrSetup.log" -tail 1 } -SuppressLog
                if (-not $result.ScriptBlockFailed) {
                    $logEntry = $result.ScriptBlockOutput
                    $logEntry = "ConfigMgrSetup.log: " + $logEntry.Substring(0, $logEntry.IndexOf("$"))
                    try {
                        Write-Progress "Waiting $timeout minutes for $($currentItem.role) Configuration. ConfigMgrSetup is running. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $logEntry -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                    }
                    catch {}
                    $skipProgress = $true
                }
            }

            if (-not $skipProgress) {
                # Write progress
                try {
                    Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $status.ScriptBlockOutput -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                }
                catch {}
            }

            # Check if complete
            $complete = $status.ScriptBlockOutput -eq "Complete!"
        }
        else {
            if ($noStatus) {
                try {
                    Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "Waiting for job progress" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                }
                catch {}
            }
        }

    } until ($complete -or ($stopWatch.Elapsed -ge $timeSpan))

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
            Write-Log "PSJOB: $($currentItem.vmName): Failed to set Ethernet as Trusted. $($result.ScriptBlockOutput)" -Warning
        }
    }

    # Update VMNote and set new version, this code doesn't run when VM_Create failed
    if ($using:Phase -gt 1 -and -not $currentItem.hidden) {
        New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $complete -UpdateVersion
    }

    if (-not $complete) {
        Write-Log "PSJOB: $($currentItem.vmName): VM Configuration did not finish successfully for $($currentItem.role). Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -OutputStream -Failure
    }
    else {
        Write-Progress "$($currentItem.role) Configuration completed successfully. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $status.ScriptBlockOutput -Completed
        Write-Log "PSJOB: $($currentItem.vmName): VM Configuration completed successfully for $($currentItem.role)." -OutputStream -Success
    }

}