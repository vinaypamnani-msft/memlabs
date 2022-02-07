
# Create VM script block
$global:VM_Create = {

    # Dot source common
    . $using:PSScriptRoot\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

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

    # Dot source common
    . $using:PSScriptRoot\Common.ps1 -InJob -VerboseEnabled:$enableVerbose

    # Params for child script blocks
    $DscFolder = "configmgr"
    if ($currentItem.role -eq "SQLAO" -and $using:Phase -eq 3) {
        $DscFolder = "AoG"
    }

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

    # Get VM Session
    $ps = Get-VmSession -VmName $currentItem.vmName -VmDomainName $domainName

    if (-not $ps) {
        Write-Log "PSJOB: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
        return
    }

    # Copy DSC files
    Write-Log "PSJOB: $($currentItem.vmName): Copying required PS modules to the VM."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { New-Item -Path "C:\staging\DSC" -ItemType Directory -Force }
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to copy required PS modules to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
    }
    Copy-Item -ToSession $ps -Path "$using:PSScriptRoot\DSC" -Destination "C:\staging" -Recurse -Container -Force

    Write-Log "PSJOB: $($currentItem.vmName): Expanding modules inside the VM."
    $Expand_Archive = {
        $zipPath = "C:\staging\DSC\DSC.zip"
        $extractPath = "C:\staging\DSC\modules"
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
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Expand_Archive
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

    $DSC_CreateSQLAOConfig = {

        param($DscFolder)

        # Get required variables from parent scope
        $currentItem = $using:currentItem
        $adminCreds = $using:Common.LocalAdmin
        $deployConfig = $using:deployConfig
        $dscRole = $currentItem.role

        # Define DSC variables
        $dscConfigScript = "C:\staging\DSC\$DscFolder\$($dscRole)Configuration.ps1"
        $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"

        # Update init log
        $log = "C:\staging\DSC\DSC_Init.txt"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "`r`n=====`r`nDSC_CreateSQLAOConfig: Started at $time`r`n=====" | Out-File $log -Append
        "Running as $env:USERDOMAIN\$env:USERNAME`r`n" | Out-File $log -Append
        "Current Item = $currentItem" | Out-File $log -Append
        "Role Name = $dscRole" | Out-File $log -Append
        "Config Script = $dscConfigScript" | Out-File $log -Append
        "Config Path = $dscConfigPath" | Out-File $log -Append

        # Dot Source config script
        . "$dscConfigScript"
        $netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
        if (-not $netbiosName) {
            "Could not get Netbios name from 'deployConfig.vmOptions.domainName' " | Out-File $log -Append
            return $false
        }
        if (-not $deployConfig.thisParams.thisVM.SQLAgentUser) {
            "Could not get SQLAgentUser name from deployConfig.thisParams.thisVM.SQLAgentUser " | Out-File $log -Append
            return $false
        }
        $sqlAgentUser = $netbiosName + "\" + $deployConfig.thisParams.thisVM.SQLAgentUser

        if (-not $deployConfig.thisParams.thisVM.fileServerVM) {
            "Could not get fileServerVM name from deployConfig.thisParams.thisVM.fileServerVM " | Out-File $log -Append
            return $false
        }
        $resourceDir = "\\" + $deployConfig.thisParams.thisVM.fileServerVM + "\" + $deployConfig.thisParams.SQLAO.WitnessShare
        if (-not $deployConfig.vmOptions.domainName) {
            "Could not get domainName name from deployConfig" | Out-File $log -Append
            return $false
        }
        $domainNameSplit = ($deployConfig.vmOptions.domainName).Split(".")

        $ADAccounts = @()
        $ADAccounts += $deployConfig.thisParams.MachineName + "$"
        $ADAccounts += $deployConfig.thisParams.thisVM.OtherNode + "$"
        $ADAccounts += $deployConfig.thisParams.thisVM.ClusterName + "$"

        $ADAccounts2 = @()
        $ADAccounts2 += $($domainNameSplit[0]) + "\" + $deployConfig.thisParams.MachineName + "$"
        $ADAccounts2 += $($domainNameSplit[0]) + "\" + $deployConfig.thisParams.thisVM.OtherNode + "$"
        $ADAccounts2 += $($domainNameSplit[0]) + "\" + $deployConfig.thisParams.thisVM.ClusterName + "$"
        $ADAccounts2 += $($domainNameSplit[0]) + "\" + $deployConfig.vmOptions.adminName

        # Configuration Data
        $cd = @{
            AllNodes = @(
                # Node01 - First cluster node.
                @{
                    # Replace with the name of the actual target node.
                    NodeName        = $deployConfig.thisParams.MachineName

                    # This is used in the configuration to know which resource to compile.
                    Role            = 'ClusterNode1'
                    CheckModuleName = 'SqlServer'
                    Address         = $deployConfig.thisParams.network
                    AddressMask     = '255.255.255.0'
                    Name            = 'Domain Network'
                    Address2        = '10.250.250.0'
                    AddressMask2    = '255.255.255.0'
                    Name2           = 'Cluster Network'
                    InstanceName    = $deployConfig.thisParams.thisVM.sqlInstanceName
                    ClusterNameAoG  = $deployConfig.thisParams.SQLAO.AlwaysOnName
                    SQLAgentUser    = $sqlAgentUser

                },

                # Node02 - Second cluster node
                @{
                    # Replace with the name of the actual target node.
                    NodeName                 = $deployConfig.thisParams.thisVM.OtherNode

                    # This is used in the configuration to know which resource to compile.
                    Role                     = 'ClusterNode2'
                    Resource                 = $resourceDir
                    PrimaryReplicaServerName = $deployConfig.thisParams.MachineName + "." + $deployConfig.vmOptions.DomainName
                },
                @{
                    NodeName                    = "*"
                    PSDscAllowDomainUser        = $true
                    PSDscAllowPlainTextPassword = $true
                    ClusterName                 = $deployConfig.thisParams.thisVM.ClusterName
                    ClusterIPAddress            = $deployConfig.thisParams.SQLAO.ClusterIPAddress + "/24"
                    AGIPAddress                 = $deployConfig.thisParams.SQLAO.AGIPAddress + "/255.255.255.0"
                    #ClusterIPAddress            = '10.250.250.30/24'
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
        $cd | ConvertTo-Json -Depth 3 | Out-File "C:\staging\DSC\SQLAOCD.json" -Force -Confirm:$false


        # Compile config, to create MOF
        $user = "$netBiosName\$($using:Common.LocalAdmin.UserName)"
        "User = $user" | Out-File $log -Append
        "Password =  $($using:Common.LocalAdmin.Password)" | Out-File $log -Append
        $creds = New-Object System.Management.Automation.PSCredential ($user, $using:Common.LocalAdmin.Password)
        if (-not $creds) {
            "Failed to create creds" | Out-File $log -Append -ErrorAction SilentlyContinue
            return $false
        }
        "Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append -ErrorAction SilentlyContinue
        & "$($dscRole)Configuration" -GroupName $deployConfig.thisParams.thisVM.ClusterName -Description "Cluster Access Group" -SqlAdministratorCredential $creds -ConfigurationData $cd -OutputPath $dscConfigPath | Out-File $log -Append -ErrorAction SilentlyContinue
        "Finished Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append -ErrorAction SilentlyContinue
    }

    $DSC_CreateConfig = {

        param($DscFolder)

        # Get required variables from parent scope
        $currentItem = $using:currentItem
        $adminCreds = $using:Common.LocalAdmin
        $deployConfig = $using:deployConfig

        # Set current role
        switch (($currentItem.role)) {
            "DPMP" { $dscRole = "DomainMember" }
            "SQLAO" { $dscRole = "DomainMember" }
            "AADClient" { $dscRole = "WorkgroupMember" }
            "InternetClient" { $dscRole = "WorkgroupMember" }
            Default { $dscRole = $currentItem.role }
        }

        # Define DSC variables
        $dscConfigScript = "C:\staging\DSC\$DscFolder\$($dscRole)Configuration.ps1"
        $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"

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

        param($DscFolder)

        # Get required variables from parent scope
        $currentItem = $using:currentItem

        # Define DSC variables
        $dscConfigPath = "C:\staging\DSC\$DscFolder\DSCConfiguration"

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

        Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force
        if (-not ($DscFolder -eq "AoG")) {
            "Set-DscLocalConfigurationManager for $dscConfigPath" | Out-File $log -Append
            Set-DscLocalConfigurationManager -Path $dscConfigPath -Verbose
        }

        if ($currentItem.hidden -or $DscFolder -eq "AoG") {
            $userdomain = $deployConfig.vmOptions.domainName.Split(".")[0]
            $user = "$userdomain\$($using:Common.LocalAdmin.UserName)"
            $creds = New-Object System.Management.Automation.PSCredential ($user, $using:Common.LocalAdmin.Password)
            "Start-DscConfiguration for $dscConfigPath with $user credentials" | Out-File $log -Append
            Start-DscConfiguration -Path $dscConfigPath -Force -Verbose -ErrorAction Stop -Credential $creds -JobName $currentItem.vmName
            Start-Sleep -Seconds 30
        }
        else {
            "Start-DscConfiguration for $dscConfigPath" | Out-File $log -Append
            Start-DscConfiguration -Wait -Path $dscConfigPath -Force -Verbose -ErrorAction Stop
        }

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

    Write-Log "PSJOB: $($currentItem.vmName): Starting $($currentItem.role) role configuration via DSC."

    $ConfigToCreate = $DSC_CreateConfig
    if ($currentItem.role -eq "SQLAO" -and $using:Phase -eq 3) {
        $ConfigToCreate = $DSC_CreateSQLAOConfig

        if ($currentItem.OtherNode) {
            #Add the note here, so the properties are set, even if we fail
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $true -UpdateVersion -AddSQLAOSpecifics
            write-Log "Adding SQLAO Specifics to Note object on $($currentItem.vmName)"

            $isClusterExcluded = Get-DhcpServerv4ExclusionRange -ScopeId 10.250.250.0 | Where-Object { $_.StartRange -eq $($deployConfig.thisParams.SQLAO.ClusterIPAddress) }
            $isAGExcluded = Get-DhcpServerv4ExclusionRange -ScopeId 10.250.250.0 | Where-Object { $_.StartRange -eq $($deployConfig.thisParams.SQLAO.AGIPAddress) }

            if (-not $isClusterExcluded) {
                Add-DhcpServerv4ExclusionRange -ScopeId "10.250.250.0" -StartRange $($deployConfig.thisParams.SQLAO.ClusterIPAddress) -EndRange $($deployConfig.thisParams.SQLAO.ClusterIPAddress) -ErrorAction SilentlyContinue
            }
            if (-not $isAGExcluded) {
                Add-DhcpServerv4ExclusionRange -ScopeId "10.250.250.0" -StartRange $($deployConfig.thisParams.SQLAO.AGIPAddress) -EndRange $($deployConfig.thisParams.SQLAO.AGIPAddress) -ErrorAction SilentlyContinue
            }

        }

    }

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $ConfigToCreate -ArgumentList $DscFolder -DisplayName "DSC: Create $($currentItem.role) Configuration"
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to create $($currentItem.role) configuration. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Enable PS Remoting on client OS before starting DSC. Ignore failures, this will work but reports a failure...
    if ($currentItem.operatingSystem -notlike "*SERVER*") {
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Enable-PSRemoting -ErrorAction SilentlyContinue -Confirm:$false -SkipNetworkProfileCheck } -DisplayName "DSC: Enable-PSRemoting. Ignore failures."
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

    Write-Log "PSJOB: $($currentItem.vmName): Started DSC for $($currentItem.role) configuration." -OutputStream

}

$global:VM_Monitor = {

    param ([bool]$clearPreviousDscStatus)

    $invokedFromScriptBlock = Test-Path ..\Common.ps1
    $currentItem = $using:currentItem
    $enableVerbose = $using:enableVerbose

    if ($invokedFromScriptBlock) {

        # Get variables from parent scope
        $deployConfig = $using:deployConfig

        # Dot source common
        . ..\Common.ps1 -InJob -VerboseEnabled:$enableVerbose
    }
    else {
        # Get variables from parent scope
        $deployConfig = $using:deployConfigCopy

        # Dot source common
        . $using:PSScriptRoot\Common.ps1 -InJob -VerboseEnabled:$enableVerbose
    }


    # Change log location
    $domainNameForLogging = $deployConfig.vmOptions.domainName
    $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"

    if ($currentItem.role -eq "DC") {
        $domainName = $deployConfig.parameters.DomainName
    }
    else {
        $domainName = "WORKGROUP"
    }

    $DSC_ClearStatus = {

        $log = "C:\staging\DSC\DSC_Init.txt"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "`r`n=====`r`nDSC_Monitor: Started at $time`r`n=====" | Out-File $log -Append

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
    }

    if ($clearPreviousDscStatus) {
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_ClearStatus -DisplayName "DSC: Clear Old Status"
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to clear old status. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
        }
    }

    $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
    $timeout = $using:RoleConfigTimeoutMinutes
    $timeSpan = New-TimeSpan -Minutes $timeout
    $stopWatch.Start()

    $complete = $false
    $previousStatus = ""
    $suppressNoisyLogging = $Common.VerboseEnabled -eq $false
    $failedHeartbeats = 0
    $failedHeartbeatThreshold = 100 # 3 seconds * 100 tries = ~5 minutes

    Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "Waiting for job progress" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)

    do {

        #$bob =  (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { (get-job -Name AoG -IncludeChildJob).Progress | Select-Object -last 1 | select-object -ExpandProperty CurrentOperation }).ScriptBlockOutput
        #$bob = (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { ((get-job -Name AoG)).StatusMessage }).ScriptBlockOutput

        #$bob2 = (Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { (get-job -IncludeChildJob |  ConvertTo-Json) }).ScriptBlockOutput
        #write-log $bob2

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
        else {
            if ($failedHeartbeats -le 10) {
                Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "Waiting for job progress" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
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

    if ($using:Phase -gt 1) {
        # Update VMNote and set new version, this code doesn't run when VM_Create failed
        if ($currentItem.role -eq "SQLAO" -and $currentItem.OtherNode -and $using:Phase -eq 3) {
            #It worked.. Add the note again..
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $complete -UpdateVersion -AddSQLAOSpecifics
            write-Log "Adding SQLAO Specifics to Note object on $($currentItem.vmName)"
        }
        else {
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $complete -UpdateVersion
        }
    }

    if (-not $complete) {
        Write-Log "PSJOB: $($currentItem.vmName): VM Configuration did not finish successfully for $($currentItem.role). Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -OutputStream -Failure
    }
    else {
        Write-Progress "$($currentItem.role) Configuration completed successfully. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $status.ScriptBlockOutput -Completed
        Write-Log "PSJOB: $($currentItem.vmName): VM Configuration completed successfully for $($currentItem.role)." -OutputStream -Success
    }

}