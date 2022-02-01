
# Create VM script block
$global:VM_Create = {

    # Dot source common
    . $using:PSScriptRoot\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

    # Get variables from parent scope
    $deployConfig = $using:deployConfigCopy
    $currentItem = $using:currentItem
    $azureFileList = $using:Common.AzureFileList

    # Params for child script blocks
    $cmDscFolder = "configmgr"
    $createVM = $true
    if ($currentItem.hidden -eq $true) { $createVM = $false }

    # Change log location
    $domainNameForLogging = $deployConfig.vmOptions.domainName
    $Common.LogPath = $Common.LogPath -replace "VMBuild.log", "VMBuild.$domainNameForLogging.log"

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
        if ($currentItem.role -eq "OSDClient") {
            $created = New-VirtualMachine -VmName $currentItem.vmName -VmPath $virtualMachinePath -OSDClient -AdditionalDisks $currentItem.additionalDisks -Memory $currentItem.memory -Generation 2 -Processors $currentItem.virtualProcs -SwitchName $vmSwitch.Name -DeployConfig $deployConfig
        }
        else {
            $created = New-VirtualMachine -VmName $currentItem.vmName -VmPath $virtualMachinePath -SourceDiskPath $vhdxPath -AdditionalDisks $currentItem.additionalDisks -Memory $currentItem.memory -Generation 2 -Processors $currentItem.virtualProcs -SwitchName $vmSwitch.Name -DeployConfig $deployConfig
        }
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

    # Copy DSC files
    Write-Log "PSJOB: $($currentItem.vmName): Copying required PS modules to the VM."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { New-Item -Path "C:\staging\DSC" -ItemType Directory -Force }
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to copy required PS modules to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
    }
    Copy-Item -ToSession $ps -Path "$using:PSScriptRoot\DSC\$cmDscFolder" -Destination "C:\staging\DSC" -Recurse -Container -Force

    Write-Log "PSJOB: $($currentItem.vmName): Expanding modules inside the VM."
    $Expand_Archive = {
        param($cmDscFolder)
        $zipPath = "C:\staging\DSC\$cmDscFolder\DSC.zip"
        $extractPath = "C:\staging\DSC\$cmDscFolder\modules"
        try {
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
        }
        catch {

            if (Test-Path $extractPath) {
                Start-Sleep -Seconds 120
                Remove-Item -Path $extractPath -Force -Recurse | Out-Null
            }

            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
        }
    }

    # Extract DSC modules
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Expand_Archive -ArgumentList $cmDscFolder
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to extract PS modules inside the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
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

    # Install DSC Modules
    $DSC_InstallModules = {

        param($cmDscFolder)

        # Create init log
        $log = "C:\staging\DSC\DSC_Init.txt"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "`r`n=====`r`nDSC_InstallModules: Started at $time`r`n=====" | Out-File $log -Force

        # Install modules
        "Installing modules" | Out-File $log -Append
        $modules = Get-ChildItem -Path "C:\staging\DSC\$cmDscFolder\modules" -Directory
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

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_InstallModules -ArgumentList $cmDscFolder -DisplayName "DSC: Install Modules"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to install DSC modules. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    if ($createVM) {
        Write-Log "PSJOB: $($currentItem.vmName): VM Creation completed successfully for $($currentItem.role)." -OutputStream -Success
    }
    else {
        Write-Log "PSJOB: $($currentItem.vmName): Existing VM Preparation completed successfully for $($currentItem.role)." -OutputStream -Success
    }

}

$global:VM_Config = {

    # Dot source common
    . $using:PSScriptRoot\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

    # Get variables from parent scope
    $deployConfig = $using:deployConfigCopy
    $currentItem = $using:currentItem

    # Params for child script blocks
    $cmDscFolder = "configmgr"
    $createVM = $true
    if ($currentItem.hidden -eq $true) { $createVM = $false }

    # Change log location
    $domainNameForLogging = $deployConfig.vmOptions.domainName
    $Common.LogPath = $Common.LogPath -replace "VMBuild.log", "VMBuild.$domainNameForLogging.log"

    # Set domain name, depending on whether we need to create new VM or use existing one
    if (-not $createVM -or ($currentItem.role -eq "DC") ) {
        $domainName = $deployConfig.parameters.DomainName
    }
    else {
        $domainName = "WORKGROUP"
    }

    $Stop_RunningDSC = {
        # Stop any existing DSC runs
        Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force -ErrorAction SilentlyContinue
        Stop-DscConfiguration -Verbose -Force -ErrorAction SilentlyContinue
    }

    Write-Log "PSJOB: $($currentItem.vmName): Stopping any previously running DSC Configurations."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): Failed to stop any running DSC's." -Warning -OutputStream
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

    $DSC_CreateConfig = {

        param($cmDscFolder)

        # Get required variables from parent scope
        $currentItem = $using:currentItem
        $adminCreds = $using:Common.LocalAdmin
        $deployConfig = $using:deployConfig

        # Set current role
        switch (($currentItem.role)) {
            "DPMP" { $dscRole = "DomainMember" }
            "FileServer" { $dscRole = "DomainMember" }
            "AADClient" { $dscRole = "WorkgroupMember" }
            "InternetClient" { $dscRole = "WorkgroupMember" }
            Default { $dscRole = $currentItem.role }
        }

        # Define DSC variables
        $dscConfigScript = "C:\staging\DSC\$cmDscFolder\$($dscRole)Configuration.ps1"
        $dscConfigPath = "C:\staging\DSC\$cmDscFolder\DSCConfiguration"

        # Update init log
        $log = "C:\staging\DSC\DSC_Init.txt"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "`r`n=====`r`nDSC_CreateConfig: Started at $time`r`n=====" | Out-File $log -Append
        "Running as $env:USERDOMAIN\$env:USERNAME`r`n" | Out-File $log -Append
        "Current Item = $currentItem" | Out-File $log -Append
        "Role Name = $dscRole" | Out-File $log -Append
        "Config Script = $dscConfigScript" | Out-File $log -Append
        "Config Path = $dscConfigPath" | Out-File $log -Append

        # Dot Source config script
        . "$dscConfigScript"

        # Configuration Data
        $cd = @{
            AllNodes = @(
                @{
                    NodeName                    = 'LOCALHOST'
                    PSDscAllowPlainTextPassword = $true
                }
            )
        }

        # Write config to file
        $configFilePath = "C:\staging\DSC\deployConfig.json"

        "Writing DSC config to $configFilePath" | Out-File $log -Append
        if (Test-Path $configFilePath) {
            $newName = $configFilePath -replace ".json", ((get-date).ToString("_yyyyMMdd_HHmmss") + ".json")
            Rename-Item -Path $configFilePath -NewName $newName -Force -Confirm:$false -ErrorAction Stop
        }
        $deployConfig | ConvertTo-Json -Depth 3 | Out-File $configFilePath -Force -Confirm:$false

        # Compile config, to create MOF
        "Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append
        & "$($dscRole)Configuration" -ConfigFilePath $configFilePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath $dscConfigPath
    }

    $DSC_StartConfig = {

        param($cmDscFolder)

        # Get required variables from parent scope
        $currentItem = $using:currentItem

        # Define DSC variables
        $dscConfigPath = "C:\staging\DSC\$cmDscFolder\DSCConfiguration"

        # Update init log
        $log = "C:\staging\DSC\DSC_Init.txt"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "`r`n=====`r`nDSC_StartConfig: Started at $time`r`n=====" | Out-File $log -Append

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

        # Rename the DSC_Events.json file, if it exists for DSC re-run
        $jsonPath = Join-Path "C:\staging\DSC" "DSC_Events.json"
        if (Test-Path $jsonPath) {
            $newName = $jsonPath -replace ".json", ((get-date).ToString("_yyyyMMdd_HHmmss") + ".json")
            Rename-Item -Path $jsonPath -NewName $newName -Force -Confirm:$false -ErrorAction Stop
        }

        # For re-run, mark ScriptWorkflow not started
        $ConfigurationFile = Join-Path -Path "C:\staging\DSC" -ChildPath "ScriptWorkflow.json"
        if (Test-Path $ConfigurationFile) {
            $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
            $Configuration.ScriptWorkFlow.Status = 'NotStart'
            $Configuration.ScriptWorkFlow.StartTime = ''
            $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
        }

        "Set-DscLocalConfigurationManager for $dscConfigPath" | Out-File $log -Append
        Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force
        Set-DscLocalConfigurationManager -Path $dscConfigPath -Verbose

        if ($currentItem.hidden) {
            # Don't wait, if we're not creating a new VM and running DSC on an existing VM
            "Start-DscConfiguration for $dscConfigPath for existing VM" | Out-File $log -Append
            Start-DscConfiguration -Path $dscConfigPath -Force -Verbose -ErrorAction Stop
            Start-Sleep -Seconds 60 # Wait for DSC Status to do tests, and wait on the latest action
        }
        else {
            "Start-DscConfiguration for $dscConfigPath for new VM" | Out-File $log -Append
            Start-DscConfiguration -Wait -Path $dscConfigPath -Force -Verbose -ErrorAction Stop
        }

    }

    Write-Log "PSJOB: $($currentItem.vmName): Starting $($currentItem.role) role configuration via DSC."

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_CreateConfig -ArgumentList $cmDscFolder -DisplayName "DSC: Create $($currentItem.role) Configuration"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to create $($currentItem.role) configuration. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Enable PS Remoting on client OS before starting DSC. Ignore failures, this will work but reports a failure...
    if ($currentItem.operatingSystem -notlike "*SERVER*") {
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Enable-PSRemoting -ErrorAction SilentlyContinue -Confirm:$false -SkipNetworkProfileCheck } -DisplayName "DSC: Enable-PSRemoting. Ignore failures."
    }

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $cmDscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to start $($currentItem.role) configuration. Retrying once. $($result.ScriptBlockOutput)" -Warning
        # Retry once before exiting
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -ArgumentList $cmDscFolder -DisplayName "DSC: Start $($currentItem.role) Configuration"
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to Start $($currentItem.role) configuration. Exiting. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
        }
    }
    # Wait for DSC, timeout after X minutes
    # Write-Log "PSJOB: $($currentItem.vmName): Waiting for $($currentItem.role) role configuration via DSC." -OutputStream

    $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
    $timeout = $using:RoleConfigTimeoutMinutes
    $timeSpan = New-TimeSpan -Minutes $timeout
    $stopWatch.Start()

    $complete = $false
    $previousStatus = ""
    $suppressNoisyLogging = $enableVerbose -eq $false
    $failedHeartbeats = 0
    $failedHeartbeatThreshold = 100 # 3 seconds * 100 tries = ~5 minutes

    do {
        $status = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt -ErrorAction SilentlyContinue } -SuppressLog:$suppressNoisyLogging
        Start-Sleep -Seconds 3

        if ($status.ScriptBlockFailed) {
            $failedHeartbeats++
            # Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to get job status update. Failed Heartbeat Count: $failedHeartbeats" -Verbose
            if ($failedHeartbeats -gt 10) {
                Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "Trying to retrieve job status from VM, attempt $failedHeartbeats/$failedHeartbeatThreshold" -PercentComplete ($failedHeartbeats / $failedHeartbeatThreshold * 100)
            }
        }
        else {
            $failedHeartbeats = 0
        }

        if ($failedHeartbeats -gt $failedHeartbeatThreshold) {
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

        if ($status.ScriptBlockOutput -and $status.ScriptBlockOutput -is [string]) {

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
                    Write-Progress "Waiting $timeout minutes for $($currentItem.role) Configuration. ConfigMgrSetup is running. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $logEntry -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                    $skipProgress = $true
                }
            }

            if (-not $skipProgress) {
                # Write progress
                Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $status.ScriptBlockOutput -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
            }

            # Check if complete
            $complete = $status.ScriptBlockOutput -eq "Complete!"
        }

    } until ($complete -or ($stopWatch.Elapsed -ge $timeSpan))

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

    if (-not $complete) {
        $worked = $false
        Write-Log "PSJOB: $($currentItem.vmName): VM Configuration did not finish successfully for $($currentItem.role). Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -OutputStream -Failure
    }
    else {
        $worked = $true
        Write-Progress "$($currentItem.role) Configuration completed successfully. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $status.ScriptBlockOutput -Completed
        Write-Log "PSJOB: $($currentItem.vmName): VM Configuration completed successfully for $($currentItem.role)." -OutputStream -Success
    }

    if ($createVM) {
        # Update VMNote and set new version, this code doesn't run when VM_Create failed
        New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $worked -UpdateVersion
    }
}