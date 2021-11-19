[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Lab Configuration: Standalone, Hierarchy, etc.")]
    [string]$Configuration,
    [Parameter(Mandatory = $false, HelpMessage = "Download all files required by the specified config without deploying any VMs.")]
    [switch]$DownloadFilesOnly,
    [Parameter(Mandatory = $false, HelpMessage = "Force recreation of virtual machines, if already present.")]
    [switch]$ForceNew,
    [Parameter(Mandatory = $false, HelpMessage = "Force redownload of required files, if already present.")]
    [switch]$ForceDownloadFiles,
    [Parameter(Mandatory = $false, HelpMessage = "Timeout in minutes for VM Configuration.")]
    [int]$RoleConfigTimeoutMinutes = 300,
    [Parameter(Mandatory = $false, HelpMessage = "Do not resize PS window.")]
    [switch]$NoWindowResize,
    [Parameter(Mandatory = $false, HelpMessage = "Use Azure CDN for download.")]
    [switch]$UseCDN,
    [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
    [switch]$WhatIf
)

# Tell common to re-init
if ($Common.Initialized) {
    $Common.Initialized = $false
}

$NewLabsuccess = $false

# Set Debug & Verbose
$enableVerbose = if ($PSBoundParameters.Verbose -eq $true) { $true } else { $false };
$enableDebug = if ($PSBoundParameters.Debug -eq $true) { $true } else { $false };

# Dot source common
. $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose

if (-not $NoWindowResize.IsPresent) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Primary -eq $true }

        $percent = 0.70
        $width = $screen.Bounds.Width * $percent
        $height = $screen.Bounds.Height * $percent

        # Set Window
        Set-Window -ProcessID $PID -X 20 -Y 20 -Width $width -Height $height
        $parent = (Get-WmiObject win32_process -ErrorAction SilentlyContinue | Where-Object processid -eq  $PID).parentprocessid
        if ($parent) {
            # set parent, cmd -> ps
            Set-Window -ProcessID $parent -X 20 -Y 20 -Width $width -Height $height
        }

    }
    catch {
        Write-Log "Main: Failed to set window size. $_" -LogOnly -Warning
    }
}

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Main: Critical Failure! $($Common.FatalError)" -Failure
    return
}

function Write-JobProgress {
    param($Job)

    #Make sure the first child job exists
    if ($null -ne $Job.ChildJobs[0].Progress) {
        #Extracts the latest progress of the job and writes the progress
        $latestPercentComplete = 0
        $lastProgress = $Job.ChildJobs[0].Progress | Where-Object { $_.Activity -ne "Preparing modules for first use." } | Select-Object -Last 1

        if ($lastProgress) {
            $latestPercentComplete = $lastProgress | Select-Object -expand PercentComplete;
            $latestActivity = $lastProgress | Select-Object -expand Activity;
            $latestStatus = $lastProgress | Select-Object -expand StatusDescription;
            $jobName = $job.Name
            $latestActivity = $latestActivity.Replace("$jobName`: ", "")
        }

        if ($latestActivity -and $latestStatus) {
            #When adding multiple progress bars, a unique ID must be provided. Here I am providing the JobID as this
            Write-Progress -Id $Job.Id -Activity "$jobName`: $latestActivity" -Status $latestStatus -PercentComplete $latestPercentComplete;
        }
    }
}

# Create VM script block
$VM_Create = {

    # Dot source common
    . $using:PSScriptRoot\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

    # Get required variables from parent scope
    $cmDscFolder = $using:cmDscFolder
    $currentItem = $using:currentItem
    $deployConfig = $using:deployConfig
    $forceNew = $using:ForceNew
    $createVM = $using:CreateVM
    $sqlCUUrl = $using:sqlCUUrl

    # Change log location
    $domainName = $using:domainName
    $Common.LogPath = $Common.LogPath -replace "VMBuild.log", "VMBuild.$domainName.log"

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
    $imageFile = $Common.AzureFileList.OS | Where-Object { $_.id -eq $currentItem.operatingSystem }
    $vhdxPath = Join-Path $Common.AzureFilesPath $imageFile.filename

    # Set base VM path
    $virtualMachinePath = Join-Path $deployConfig.vmOptions.basePath $deployConfig.vmOptions.domainName

    if ($createVM) {

        # Check if VM already exists
        $exists = Get-VM $currentItem.vmName -ErrorAction SilentlyContinue
        if ($exists -and -not $ForceNew.IsPresent) {
            Write-Log "PSJOB: $($currentItem.vmName): VM already exists. ForceNew switch is NOT present. Exiting." -Failure -OutputStream -HostOnly
            return
        }

        # Create VM
        if ($currentItem.role -eq "OSDClient") {
            $created = New-VirtualMachine -VmName $currentItem.vmName -VmPath $virtualMachinePath -ForceNew:$forceNew -OSDClient -AdditionalDisks $currentItem.additionalDisks -Memory $currentItem.memory -Generation 2 -Processors $currentItem.virtualProcs -SwitchName $network -DeployConfig $deployConfig -WhatIf:$using:WhatIf
        }
        else {
            $created = New-VirtualMachine -VmName $currentItem.vmName -VmPath $virtualMachinePath -ForceNew:$forceNew -SourceDiskPath $vhdxPath -AdditionalDisks $currentItem.additionalDisks -Memory $currentItem.memory -Generation 2 -Processors $currentItem.virtualProcs -SwitchName $network -DeployConfig $deployConfig -WhatIf:$using:WhatIf
        }
        if (-not $created) {
            Write-Log "PSJOB: $($currentItem.vmName): VM was not created. Check vmbuild.log." -Failure -OutputStream -HostOnly
            return
        }

        if ($currentItem.role -eq "OSDClient") {
            New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $true
            Write-Log "PSJOB: $($currentItem.vmName): Configuration completed successfully for $($currentItem.role)." -OutputStream -Success
            return
        }

        # Wait for VM to finish OOBE
        $connected = Wait-ForVm -VmName $currentItem.vmName -OobeComplete -WhatIf:$using:WhatIf
        if (-not $connected) {
            Write-Log "PSJOB: $($currentItem.vmName): Could not verify if OOBE finished. Exiting." -Failure -OutputStream
            return
        }
    }
    else {
        # Check if VM is connectable
        $exists = Get-Vm -Name $currentItem.vmName -ErrorAction SilentlyContinue
        if ($exists -and $exists.State -ne "Running") {
            # Validation should prevent from ever getting in this block
            Start-VM -Name $currentItem.vmName -ErrorAction SilentlyContinue -ErrorVariable StartErr
            if ($StartErr) {
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
    if ($currentItem.role -in "Primary", "CAS") {
        try {
            $vmnet = Get-VMNetworkAdapter -VMName $currentItem.vmName -ErrorAction Stop
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
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): Failed to set PS ExecutionPolicy to Bypass for LocalMachine. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    $Fix_DefaultProfile = {
        $path1 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCache"
        $path2 = "C:\Users\Default\AppData\Local\Microsoft\Windows\INetCache"
        $path3 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCacheLock.dat"
        if (Test-Path $path1) { Remove-Item -Path $path1 -Force -Recurse | Out-Null }
        if (Test-Path $path2) { Remove-Item -Path $path2 -Force -Recurse | Out-Null }
        if (Test-Path $path3) { Remove-Item -Path $path3 -Force | Out-Null }
    }

    Write-Log "PSJOB: $($currentItem.vmName): Updating Default user profile to fix a known sysprep issue."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Fix_DefaultProfile -DisplayName "Fix Default Profile" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): Failed to fix the default user profile." -Warning -OutputStream
    }

    $Stop_RunningDSC = {
        # Stop any existing DSC runs
        Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force -ErrorAction SilentlyContinue
        Stop-DscConfiguration -Verbose -Force -ErrorAction SilentlyContinue
        # Get-Process wmiprvse* -ErrorAction SilentlyContinue | Where-Object {$_.modules.ModuleName -like "*DSC*"} | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Write-Log "PSJOB: $($currentItem.vmName): Stopping any previously running DSC Configurations."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Stop_RunningDSC -DisplayName "Stop Any Running DSC's" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): Failed to stop any running DSC's." -Warning -OutputStream
    }

    # Boot To OOBE?
    $bootToOOBE = $currentItem.role -eq "AADClient"
    if ($bootToOOBE) {
        # Run Sysprep
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Set-NetFirewallProfile -All -Enabled false } -WhatIf:$WhatIf
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { C:\Windows\system32\sysprep\sysprep.exe /generalize /oobe /shutdown } -WhatIf:$WhatIf
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): Failed to boot the VM to OOBE. $($result.ScriptBlockOutput)" -Failure -OutputStream
        }
        else {
            $ready = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -VmState "Off" -TimeoutMinutes 15 -WhatIf:$WhatIf
            if (-not $ready) {
                Write-Log "PSJOB: $($currentItem.vmName): Timed out while waiting for sysprep to shut the VM down." -OutputStream -Failure
            }
            else {
                Start-VM -Name $currentItem.vmName -ErrorAction SilentlyContinue
                $oobeStarted = Wait-ForVm -VmName $currentItem.vmName -VmDomainName $domainName -OobeStarted -TimeoutMinutes 15 -WhatIf:$WhatIf
                if ($oobeStarted) {
                    Write-Progress -Activity "Wait for VM to start OOBE" -Status "Complete!" -Completed
                    Write-Log "PSJOB: $($currentItem.vmName): Configuration completed successfully for $($currentItem.role). VM is at OOBE." -OutputStream -Success
                }
                else {
                    Write-Log "PSJOB: $($currentItem.vmName): Timed out while waiting for OOBE to start." -OutputStream -Failure
                }
            }
        }
        # Update VMNote
        New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $oobeStarted
        return
    }

    # Copy DSC files
    Write-Log "PSJOB: $($currentItem.vmName): Copying required PS modules to the VM."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { New-Item -Path "C:\staging\DSC" -ItemType Directory -Force } -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to copy required PS modules to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
    }
    Copy-Item -ToSession $ps -Path "$using:PSScriptRoot\DSC\$cmDscFolder" -Destination "C:\staging\DSC" -Recurse -Container -Force

    $expandArchive = {
        try{
        Expand-Archive -Path "C:\staging\DSC\$using:cmDscFolder\DSC.zip" -DestinationPath "C:\staging\DSC\$using:cmDscFolder\modules" -Force
        }
        catch {
            #Timhe - Attempt to fix error: ERROR: Invoke-VmCommand: CON-PS1SITE: Failed to run ' Expand-Archive -Path "C:\staging\DSC$using:cmDscFolder\DSC.zip" -DestinationPath "C:\staging\DSC$using:cmDscFolder\modules" -Force '. Error: Exception calling "ExtractToFile" with "3" argument(s): "The file 'C:\staging\DSC\configmgr\modules\dscmetadata.json' already exists."
            #11/19/2021 09:56:59:274 ERROR: PSJOB: CON-PS1SITE: DSC: Failed to extract PS modules inside the VM.
            Remove-Item "C:\staging\DSC\$using:cmDscFolder\modules" -Filter *.* -Force -Confirm:$false
            Expand-Archive -Path "C:\staging\DSC\$using:cmDscFolder\DSC.zip" -DestinationPath "C:\staging\DSC\$using:cmDscFolder\modules" -Force
        }
    }
    # Extract DSC modules
    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $expandArchive -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to extract PS modules inside the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Copy SQL files to VM
    if ($currentItem.sqlVersion -and $createVM) {

        Write-Log "PSJOB: $($currentItem.vmName): Copying SQL installation files to the VM."
        Write-Progress -Activity "$($currentItem.vmName): Copying SQL installation files to the VM" -Activity "Working" -Completed

        # Determine which SQL version files should be used
        $sqlFiles = $Common.AzureFileList.ISO | Where-Object { $_.id -eq $currentItem.sqlVersion }

        # SQL Iso Path
        $sqlIso = $sqlFiles.filename | Where-Object { $_.EndsWith(".iso") }
        $sqlIsoPath = Join-Path $using:Common.AzureFilesPath $sqlIso

        # SQL CU Path and FileName
        $sqlCU = $sqlFiles.filename | Where-Object { $_.EndsWith(".exe") }
        $sqlCUPath = Join-Path $using:Common.AzureFilesPath $sqlCU
        $sqlCUFileName = Split-Path $sqlCUPath -Leaf

        # Add SQL ISO to guest
        Set-VMDvdDrive -VMName $currentItem.vmName -Path $sqlIsoPath

        # Create C:\temp\SQL & C:\temp\SQL_CU inside VM
        $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { New-Item -Path "C:\temp\SQL" -ItemType Directory -Force } -WhatIf:$WhatIf
        $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { New-Item -Path "C:\temp\SQL_CU" -ItemType Directory -Force } -WhatIf:$WhatIf

        # Copy files from DVD
        $result = Invoke-VmCommand -VmName $currentItem.vmName -DisplayName "Copy SQL Files" -ScriptBlock { $cd = Get-Volume | Where-Object { $_.DriveType -eq "CD-ROM" }; Copy-Item -Path "$($cd.DriveLetter):\*" -Destination "C:\temp\SQL" -Recurse -Force -Confirm:$false } -WhatIf:$WhatIf
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to copy SQL installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
        }

        # Copy SQL CU file to VM
        # Copy-Item -ToSession $ps -Path $sqlCUPath -Destination "C:\temp\SQL_CU\$sqlCUFileName" -Force

        # Eject ISO from guest
        Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
    }

    # Define DSC ScriptBlock
    $DSC_InstallModules = {

        # Get required variables from parent scope
        $cmDscFolder = $using:cmDscFolder

        # Create init log
        $log = "C:\staging\DSC\DSC_Init.txt"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "`r`n=====`r`nDSC_InstallModules: Started at $time`r`n=====" | Out-File $log -Force

        # Install modules
        "Installing modules" | Out-File $log -Append
        $modules = Get-ChildItem -Path "C:\staging\DSC\$cmDscFolder\modules" -Directory
        foreach ($folder in $modules) {
            Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force
            Import-Module $folder.Name -Force;
        }
    }

    $DSC_CreateConfig = {

        # Get required variables from parent scope
        $cmDscFolder = $using:cmDscFolder
        $currentItem = $using:currentItem
        $adminCreds = $using:Common.LocalAdmin
        $deployConfig = $using:deployConfig
        $sqlCUUrl = $using:sqlCUUrl

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
        $deployConfig.parameters.ThisMachineName = $currentItem.vmName
        $deployConfig.parameters.ThisMachineRole = $currentItem.role   # Don't override this to DomainMember, otherwise DSC won't run MPDP config

        if ($sqlCUUrl) {
            $deployConfig.parameters.ThisSQLCUURL = $sqlCUUrl
        }

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

        # Get required variables from parent scope
        $cmDscFolder = $using:cmDscFolder
        $createVM = $using:createVM
        $currentItem = $using:CurrentItem

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

        "Start-DscConfiguration for $dscConfigPath" | Out-File $log -Append
        if ($createVM) {
            Start-DscConfiguration -Wait -Path $dscConfigPath -Force -Verbose -ErrorAction Stop
        }
        else {
            # Don't wait, if we're not creating a new VM and running DSC on an existing VM
            Start-DscConfiguration -Path $dscConfigPath -Force -Verbose -ErrorAction Stop
            Start-Sleep -Seconds 60 # Wait for DSC Status to do tests, and wait on the latest action
        }

    }

    Write-Log "PSJOB: $($currentItem.vmName): Starting $($currentItem.role) role configuration via DSC."

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_InstallModules -DisplayName "DSC: Install Modules" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to install DSC modules. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_CreateConfig -DisplayName "DSC: Create $($currentItem.role) Configuration" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to create $($currentItem.role) configuration. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Enable PS Remoting on client OS before starting DSC. Ignore failures, this will work but reports a failure...
    if ($currentItem.operatingSystem -notlike "*SERVER*") {
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Enable-PSRemoting -ErrorAction SilentlyContinue -Confirm:$false -SkipNetworkProfileCheck } -DisplayName "DSC: Enable-PSRemoting. Ignore failures." -WhatIf:$WhatIf
    }

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -DisplayName "DSC: Start $($currentItem.role) Configuration" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "$($currentItem.vmName): DSC: Failed to start $($currentItem.role) configuration. Retrying once. $($result.ScriptBlockOutput)" -Warning
        # Retry once before exiting
        $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock $DSC_StartConfig -DisplayName "DSC: Start $($currentItem.role) Configuration" -WhatIf:$WhatIf
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
    do {
        $status = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt } -SuppressLog -WhatIf:$WhatIf
        Start-Sleep -Seconds 3

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
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock { Get-Content "C:\ConfigMgrSetup.log" -tail 1 } -SuppressLog -WhatIf:$WhatIf
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

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $Trust_Ethernet -ArgumentList $netProfile -DisplayName "Set Ethernet as Trusted" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): Failed to set Ethernet as Trusted. $($result.ScriptBlockOutput)" -Warning
    }

    if (-not $complete) {
        $worked = $false
        Write-Log "PSJOB: $($currentItem.vmName): Configuration did not finish successfully for $($currentItem.role). Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -OutputStream -Failure
    }
    else {
        $worked = $true
        Write-Progress "$($currentItem.role) configuration completed successfully. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $status.ScriptBlockOutput -Completed
        Write-Log "PSJOB: $($currentItem.vmName): Configuration completed successfully for $($currentItem.role)." -OutputStream -Success
    }

    if ($createVM) {
        # Set VM Note
        New-VmNote -VmName $currentItem.vmName -DeployConfig $deployConfig -Successful $worked
    }
}

Clear-Host

try {
    if ($Configuration) {
        # Get user configuration
        $configResult = Get-UserConfiguration -Configuration $Configuration
        if ($configResult.Loaded) {
            $userConfig = $configResult.Config
            Write-Host ("`r`n" * (($userConfig.virtualMachines.Count * 3) + 3))
            Write-Log "### START." -Success
            Write-Log "Main: Validating specified configuration: $Configuration" -Activity
        }
        else {
            Write-Log "### START." -Success
            Write-Log "Main: Validating specified configuration: $Configuration" -Activity
            Write-Log $configResult.Message -Failure
            Write-Host
            return
        }

    }
    else {
        Write-Log "Main: No Configuration specified. Calling genconfig." -Activity
        Set-Location $PSScriptRoot
        $result = ./genconfig.ps1 -InternalUseOnly -Verbose:$enableVerbose -Debug:$enableDebug

        # genconfig was called with -Debug true, and returned DeployConfig instead of ConfigFileName
        if ($result.DeployConfig) {
            return $result
        }

        # genconfig specified not to deploy
        if (-not $result.DeployNow) {
            return
        }

        if ($result.ForceNew) {
            $ForceNew = $true
        }

        $configResult = Get-UserConfiguration -Configuration $result.ConfigFileName

        if (-not $($result.DeployNow)) {
            return
        }
        if ($configResult.Loaded) {
            $userConfig = $configResult.Config
            Clear-Host
            Write-Host ("`r`n" * (($userConfig.virtualMachines.Count * 3) + 3))
            Write-Log "### START." -Success
            Write-Log "Main: Using $($result.ConfigFileName) provided by genconfig" -Activity
            Write-Log "Main: genconfig specified DeployNow: $($result.DeployNow); ForceNew: $($result.ForceNew)"
        }
        else {
            Write-Log "### START." -Success
            Write-Log "Main: Validating specified configuration: $Configuration" -Activity
            Write-Log $configResult.Message -Failure
            Write-Host
            return
        }

    }
    Set-QuickEdit -DisableQuickEdit
    # Timer
    $timer = New-Object -TypeName System.Diagnostics.Stopwatch
    $timer.Start()

    # Load configuration
    try {
        $testConfigResult = Test-Configuration -InputObject $userConfig
        if ($testConfigResult.Valid) {
            $deployConfig = $testConfigResult.DeployConfig
            Write-Log "Main: Config validated successfully." -Success
        }
        else {
            Write-Log "Main: Config validation failed. `r`n$($testConfigResult.Message)" -Failure
            Write-Host
            return
        }
    }
    catch {
        Write-Log "Main: Failed to load $Configuration.json file. Review vmbuild.log. $_" -Failure
        Write-Host
        return
    }

    # Change log location
    $domainName = $deployConfig.vmOptions.domainName
    Write-Log "Starting deployment. Review VMBuild.$domainName.log" -Activity
    $Common.LogPath = $Common.LogPath -replace "VMBuild.log", "VMBuild.$domainName.log"

    # Download required files
    $success = Get-FilesForConfiguration -InputObject $deployConfig -WhatIf:$WhatIf -UseCDN:$UseCDN -ForceDownloadFiles:$ForceDownloadFiles
    if (-not $success) {
        Write-Host
        Write-Log "Main: Failed to download all required files. Retrying download of missing files in 2 minutes... " -Warning
        Start-Sleep -Seconds 120
        $success = Get-FilesForConfiguration -InputObject $deployConfig -WhatIf:$WhatIf -UseCDN:$UseCDN -ForceDownloadFiles:$ForceDownloadFiles
        if (-not $success) {
            $timer.Stop()
            Write-Log "Main: Failed to download all required files. Exiting." -Failure
            return
        }
    }

    if ($DownloadFilesOnly.IsPresent) {
        $timer.Stop()
        Write-Host
        Write-Log "### SCRIPT FINISHED. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Success
        Write-Host
        return
    }

    # Test if hyper-v switch exists, if not create it
    Write-Log "Main: Creating/verifying whether a Hyper-V switch for specified network exists." -Activity
    $switch = Test-NetworkSwitch -NetworkName $deployConfig.vmOptions.network -NetworkSubnet $deployConfig.vmOptions.network -DomainName $deployConfig.vmOptions.domainName
    if (-not $switch) {
        Write-Log "Main: Failed to verify/create Hyper-V switch for specified network ($($deployConfig.vmOptions.network)). Exiting." -Failure
        return
    }

    # Test if DHCP scope exists, if not create it
    Write-Log "Main: Creating/verifying DHCP scope options for specified network." -Activity
    $worked = Test-DHCPScope -ConfigParams $deployConfig.parameters
    if (-not $worked) {
        Write-Log "Main: Failed to verify/create DHCP Scope for specified network ($($deployConfig.vmOptions.network)). Exiting." -Failure
        return
    }

    # Internet Client VM Switch and DHCP Scope
    $containsIN = ($deployConfig.virtualMachines.role -contains "InternetClient") -or ($deployConfig.virtualMachines.role -contains "AADClient")
    if ($containsIN) {
        Write-Log "Main: Creating/verifying whether a Hyper-V switch for 'Internet' network exists." -Activity
        $internetSwitchName = "Internet"
        $internetSubnet = "172.31.250.0"
        $switch = Test-NetworkSwitch -NetworkName $internetSwitchName -NetworkSubnet $internetSubnet -DomainName $internetSwitchName
        if (-not $switch) {
            Write-Log "Main: Failed to verify/create Hyper-V switch for 'Internet' network ($internetSwitchName). Exiting." -Failure
            return
        }

        # Test if DHCP scope exists, if not create it
        Write-Log "Main: Creating/verifying DHCP scope options for the 'Internet' network." -Activity
        $dummyParams = [PSCustomObject]@{
            DHCPScopeId        = $internetSubnet
            DHCPScopeName      = $internetSwitchName
            DHCPScopeStart     = "172.31.250.20"
            DHCPScopeEnd       = "172.31.250.199"
            DHCPDefaultGateway = "172.31.250.200"
            DHCPDNSAddress     = @("4.4.4.4", "8.8.8.8")
        }
        $worked = Test-DHCPScope -ConfigParams $dummyParams
        if (-not $worked) {
            Write-Log "Main: Failed to verify/create DHCP Scope for the 'Internet' network. Exiting." -Failure
            return
        }
    }

    # DSC Folder
    $cmDscFolder = "configmgr"

    # Remove existing jobs
    $existingJobs = Get-Job
    if ($existingJobs) {
        Write-Log "Main: Stopping and removing existing jobs." -Verbose -LogOnly
        foreach ($job in $existingJobs) {
            Write-Log "Main: Removing job $($job.Id) with name $($job.Name)" -Verbose -LogOnly
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -ErrorAction SilentlyContinue
        }
    }

    # Generate RDCMan file
    New-RDCManFile $deployConfig $global:Common.RdcManFilePath

    # Array to store PS jobs
    [System.Collections.ArrayList]$jobs = @()
    $job_created_yes = 0
    $job_created_no = 0

    # Existing DC scenario
    $containsPS = $deployConfig.virtualMachines.role -contains "Primary"
    $existingDC = $deployConfig.parameters.ExistingDCName
    $containsPassive = $deployConfig.virtualMachines.role -contains "PassiveSite"
    $containsDPMP = $deployConfig.virtualMachines.role -contains "DPMP"
    $containsSecondary = $deployConfig.virtualMachines.role -contains "Secondary"

    # Remove DNS records for VM's in this config, if existing DC
    if ($existingDC) {
        Write-Log "Main: Attempting to remove existing DNS Records" -Activity -HostOnly
        foreach ($item in $deployConfig.virtualMachines) {
            Remove-DnsRecord -DCName $existingDC -Domain $deployConfig.vmOptions.domainName -RecordToDelete $item.vmName
        }
    }

    # Existing CAS scenario
    $existingCAS = $deployConfig.parameters.ExistingCASName

    if ($existingCAS -and $containsPS) {
        $existingSQLVMName = (get-list -Type VM | where-object { $_.vmName -eq $existingCAS }).RemoteSQLVM
        # create a dummy VM object for the existingCAS
        if ($existingSQLVMName) {
            $deployConfig.virtualMachines += [PSCustomObject]@{
                vmName      = $existingCAS
                role        = "CAS"
                RemoteSQLVM = $existingSQLVMName
                hidden      = $true
            }
        }
        else {
            $existingCASVM = (get-list -Type VM | where-object { $_.vmName -eq $existingCAS })
            $deployConfig.virtualMachines += [PSCustomObject]@{
                vmName          = $existingCAS
                SQLInstanceName = $existingCASVM.SQLInstanceName
                SQLVersion      = $existingCASVM.SQLVersion
                SQLInstanceDir  = $existingCASVM.SQLInstanceDir
                role            = "CAS"
                hidden          = $true
            }
        }
    }

    # Add DPMP to existing PS
    # $existingPSName = $deployConfig.parameters.ExistingPSName
    #
    # if ($containsDPMP -and $existingPSName) {
    #     $existingPSVM = (get-list -Type VM | where-object { $_.vmName -eq $existingPSName })
    #     $deployConfig.virtualMachines += [PSCustomObject]@{
    #         vmName          = $existingPSVM.vmName
    #         role            = $existingPSVM.role
    #         siteCode        = $existingPSVM.siteCode
    #         RemoteSQLVM     = $existingPSVM.remoteSQLVM
    #         SQLInstanceName = $existingPSVM.SQLInstanceName
    #         SQLVersion      = $existingPSVM.SQLVersion
    #         SQLInstanceDir  = $existingPSVM.SQLInstanceDir
    #         hidden          = $true
    #     }
    #
    # }
    #
    if ($containsDPMP) {
        $DPMPs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DPMP" }
        foreach ($dpmp in $DPMPS) {
            $existingPrimary = (get-list -type VM -Domainname $deployConfig.vmOptions.domainName | Where-Object { $_.role -eq "Primary" -and $_.siteCode -eq $($dpmp.siteCode) })
            if ($existingPrimary -and $deployConfig.virtualMachines.vmName -notcontains $existingPrimary.vmName) {
                $deployConfig.virtualMachines += [PSCustomObject]@{
                    vmName          = $existingPrimary.vmName
                    role            = $existingPrimary.role
                    siteCode        = $existingPrimary.siteCode
                    RemoteSQLVM     = $existingPrimary.remoteSQLVM
                    SQLInstanceName = $existingPrimary.SQLInstanceName
                    SQLVersion      = $existingPrimary.SQLVersion
                    SQLInstanceDir  = $existingPrimary.SQLInstanceDir
                    hidden          = $true
                }
            }
        }
    }

    # Adding Passive to existing
    if ($containsPassive) {
        $PassiveVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" }
        if (($PassiveVM | Measure-Object).Count -ne 1) {
            Write-Log "Main: Two Passive site servers found in deployment. We only support adding one at a time." -Failure
            return
        }
        else {
            $existingActive = $deployConfig.parameters.ExistingActiveName
            if ($existingActive) {
                $existingActiveVM = (get-list -Type VM | where-object { $_.vmName -eq $existingActive })
                if ($existingActiveVM.remoteSQLVM) {
                    $sqlVM = (get-list -Type VM | where-object { $_.vmName -eq $existingActiveVM.remoteSQLVM })
                    $deployConfig.virtualMachines += [PSCustomObject]@{
                        vmName          = $sqlVM.vmName
                        SQLInstanceName = $sqlVM.SQLInstanceName
                        SQLVersion      = $sqlVM.SQLVersion
                        SQLInstanceDir  = $sqlVM.SQLInstanceDir
                        role            = "DomainMember"
                        hidden          = $true
                    }
                }

                $deployConfig.virtualMachines += [PSCustomObject]@{
                    vmName          = $existingActiveVM.vmName
                    role            = $existingActiveVM.role
                    siteCode        = $existingActiveVM.siteCode
                    RemoteSQLVM     = $existingActiveVM.remoteSQLVM
                    SQLInstanceName = $existingActiveVM.SQLInstanceName
                    SQLVersion      = $existingActiveVM.SQLVersion
                    SQLInstanceDir  = $existingActiveVM.SQLInstanceDir
                    hidden          = $true
                }
            }
        }
    }

    if ($containsSecondary) {
        $existingPS = $deployConfig.parameters.ExistingPSName
        if ($existingPS) {
            $existingPSVM = (get-list -Type VM | where-object { $_.vmName -eq $existingPS })
            $deployConfig.virtualMachines += [PSCustomObject]@{
                vmName          = $existingPSVM.vmName
                role            = $existingPSVM.role
                siteCode        = $existingPSVM.siteCode
                RemoteSQLVM     = $existingPSVM.remoteSQLVM
                SQLInstanceName = $existingPSVM.SQLInstanceName
                SQLVersion      = $existingPSVM.SQLVersion
                SQLInstanceDir  = $existingPSVM.SQLInstanceDir
                hidden          = $true
            }
        }
    }


    # Add exising DC to list
    if ($existingDC -and ($containsPS -or $containsPassive -or $containsSecondary)) {
        # create a dummy VM object for the existingDC
        $deployConfig.virtualMachines += [PSCustomObject]@{
            vmName = $existingDC
            role   = "DC"
            hidden = $true
        }
    }

    if ($enableDebug) {
        return $deployConfig
    }

    Write-Log "Main: Creating Virtual Machine Deployment Jobs" -Activity

    # New scenario
    $CreateVM = $true
    foreach ($currentItem in $deployConfig.virtualMachines) {

        if ($WhatIf) {
            Write-Log "Main: Will start a job for VM $($currentItem.vmName)"
            continue
        }

        # Existing DC scenario
        $CreateVM = $true
        if ($currentItem.hidden -eq $true) { $CreateVM = $false }

        # Determine SQL CU URL for VM to download. This is done here instead of inside $VM_Create because we need $Common.AzureFileList
        $sqlCUUrl = $null
        if ($createVM -and $currentItem.sqlVersion) {
            $sqlFile = $Common.AzureFileList.ISO | Where-Object { $_.id -eq $currentItem.sqlVersion }
            $sqlCUUrl = $sqlFile.cuURL
        }

        $job = Start-Job -ScriptBlock $VM_Create -Name $currentItem.vmName -ErrorAction Stop -ErrorVariable Err

        if ($Err.Count -ne 0) {
            Write-Log "Main: Failed to start job for VM $($currentItem.vmName). $Err" -Failure
            $job_created_no++
        }
        else {
            Write-Log "Main: Created job $($job.Id) for VM $($currentItem.vmName)" -LogOnly
            $jobs += $job
            $job_created_yes++
        }
    }
    if ($job_created_no -eq 0) {
        Write-Log "Main: Created $job_created_yes jobs for VM deployment."
    }
    else {
        Write-Log "Main: Created $job_created_yes jobs for VM deployment. Failed to create $job_created_no jobs."
    }

    Write-Log "Deployment Summary" -Activity -HostOnly
    Write-Host
    Show-Summary -deployConfig $deployConfig

    Write-Log "Main: Waiting for VM Jobs to deploy and configure the virtual machines." -Activity
    $failedCount = 0
    $successCount = 0
    $warningCount = 0
    do {
        $runningJobs = $jobs | Where-Object { $_.State -ne "Completed" } | Sort-Object -Property Id
        foreach ($job in $runningJobs) {
            Write-JobProgress($job)
        }

        $completedJobs = $jobs | Where-Object { $_.State -eq "Completed" } | Sort-Object -Property Id
        foreach ($job in $completedJobs) {
            Write-JobProgress($job)
            Write-Host "`n=== $($job.Name) (Job ID $($job.Id)) output:" -ForegroundColor Cyan
            $jobOutput = $job | Select-Object -ExpandProperty childjobs | Select-Object -ExpandProperty Output

            $incrementCount = $true
            foreach ($line in $jobOutput) {
                if ($line.ToString().StartsWith("ERROR")) {
                    Write-Host $line -ForegroundColor Red
                    if ($incrementCount) { $failedCount++ }
                }
                elseif ($line.ToString().StartsWith("WARNING")) {
                    Write-Host $line -ForegroundColor Yellow
                    if ($incrementCount) { $warningCount++ }
                }
                else {
                    Write-Host $line -ForegroundColor Green
                    if ($incrementCount) { $successCount++ }
                }

                $incrementCount = $false
            }

            Write-Progress -Id $job.Id -Activity $job.Name -Completed
            $jobs.Remove($job)
        }

        # Sleep
        Start-Sleep -Seconds 1

    } until ($runningJobs.Count -eq 0)

    Write-Log "Main: Job Completion Status." -Activity
    Write-Log "Main: $successCount jobs completed successfully; $warningCount warnings, $failedCount failures."

    $timer.Stop()

    if (Test-Path "C:\tools\rdcman.exe") {
        $roles = $deployConfig.virtualMachines | Select-Object -ExpandProperty Role
        if (($roles -Contains "InternetClient") -or ($roles -Contains "AADClient") -or ($roles -Contains "DomainMember") -or ($roles -Contains "WorkgroupMember") -or ($roles -Contains "OSDClient") -or ($roles -Contains "DPMP")) {
            New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
        }
    }

    Write-Host
    Write-Log "### SCRIPT FINISHED. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Success
    $NewLabsuccess = $true
}
catch {
    Write-Exception -ExceptionInfo $_ -AdditionalInfo ($deployConfig | ConvertTo-Json)
}
finally {
    # Ctrl + C brings us here :)
    if ($NewLabsuccess -ne $true) {
        Write-Log "Script exited unsuccessfully. Ctrl-C may have been pressed. Killing running jobs" -LogOnly
    }
    $Common.Initialized = $false
    get-job | stop-job
    Set-QuickEdit
}

Write-Host