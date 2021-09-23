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
    [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
    [switch]$WhatIf
)

# Dot source common
. $PSScriptRoot\Common.ps1

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
    . $using:PSScriptRoot\Common.ps1

    # Get required variables from parent scope
    $cmDscFolder = $using:cmDscFolder
    $currentItem = $using:currentItem
    $deployConfig = $using:deployConfig
    $forceNew = $using:ForceNew
    $domainName = $deployConfig.parameters.DomainName
    $network = $deployConfig.vmOptions.network

    # Determine which OS image file to use for the VM
    $imageFile = $Common.AzureFileList.OS | Where-Object { $_.id -eq $currentItem.operatingSystem }
    $vhdxPath = Join-Path $Common.AzureFilesPath $imageFile.filename

    # Set base VM path
    $virtualMachinePath = Join-Path $deployConfig.vmOptions.basePath $deployConfig.vmOptions.domainName

    # Create VM
    $created = New-VirtualMachine -VmName $currentItem.vmName -VmPath $virtualMachinePath -ForceNew:$forceNew -SourceDiskPath $vhdxPath -AdditionalDisks $currentItem.additionalDisks -Memory $currentItem.memory -Generation 2 -Processors $currentItem.virtualProcs -SwitchName $network -WhatIf:$using:WhatIf
    if (-not $created) {
        Write-Log "PSJOB: $($currentItem.vmName): VM was not created. Check vmbuild.log." -Failure -OutputStream -HostOnly
        return
    }

    # Wait for VM to finish OOBE
    $connected = Wait-ForVm -VmName $currentItem.vmName -OobeComplete -WhatIf:$using:WhatIf
    if (-not $connected) {
        Write-Log "PSJOB: $($currentItem.vmName): Could not verify if OOBE finished. Exiting." -Failure -OutputStream
        return
    }

    # Get VM Session
    $ps = Get-VmSession -VmName $currentItem.vmName

    if (-not $ps) {
        Write-Log "PSJOB: $($currentItem.vmName): Could not establish a session. Exiting." -Failure -OutputStream
        return
    }

    # Set PS Execution Policy (required on client OS)
    $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false } -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): Failed to set PS ExecutionPolicy to Bypass for LocalMachine. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Copy DSC files
    Write-Log "PSJOB: $($currentItem.vmName): Copying required PS modules to the VM."
    $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { New-Item -Path "C:\staging\DSC" -ItemType Directory -Force } -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to copy required PS modules to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
    }
    Copy-Item -ToSession $ps -Path "$using:PSScriptRoot\DSC\$cmDscFolder" -Destination "C:\staging\DSC" -Recurse -Container -Force

    # Extract DSC modules
    $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { Expand-Archive -Path "C:\staging\DSC\$using:cmDscFolder\DSC.zip" -DestinationPath "C:\staging\DSC\$using:cmDscFolder\modules" } -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to extract PS modules inside the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Copy SQL files to VM
    if ($currentItem.sqlVersion) {

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
        Copy-Item -ToSession $ps -Path $sqlCUPath -Destination "C:\temp\SQL_CU\$sqlCUFileName" -Force

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
        "`r`n=====`r`nDSC_InstallModules: Started at $time`r`n====="  | Out-File $log -Force

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

        # Set current role
        $dscRole = if ($currentItem.role -eq "DPMP") { "DomainMember" } else { $currentItem.role }

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

        "Writing DSC config to $configFilePath" | Out-File $log -Append
        $deployConfig | ConvertTo-Json -Depth 3 | Out-File $configFilePath -Force -Confirm:$false

        # Compile config, to create MOF
        "Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append
        & "$($dscRole)Configuration" -ConfigFilePath $configFilePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath $dscConfigPath
    }

    $DSC_StartConfig = {

        # Get required variables from parent scope
        $cmDscFolder = $using:cmDscFolder

        # Define DSC variables
        $dscConfigPath = "C:\staging\DSC\$cmDscFolder\DSCConfiguration"

        # Update init log
        $log = "C:\staging\DSC\DSC_Init.txt"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "`r`n=====`r`nDSC_StartConfig: Started at $time`r`n====="  | Out-File $log -Append

        "Set-DscLocalConfigurationManager for $dscConfigPath" | Out-File $log -Append
        Set-DscLocalConfigurationManager -Path $dscConfigPath -Verbose

        "Start-DscConfiguration for $dscConfigPath" | Out-File $log -Append
        Start-DscConfiguration -Wait -Path $dscConfigPath -Verbose -ErrorAction Stop
    }

    Write-Log "PSJOB: $($currentItem.vmName): Starting $($currentItem.role) role configuration via DSC." -OutputStream

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
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $domainName -ScriptBlock $DSC_StartConfig -DisplayName "DSC: Start $($currentItem.role) Configuration" -WhatIf:$WhatIf
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
                    Write-Progress "Waiting $timeout minutes for $($currentItem.role) Configuration. ConfigMgrSetup is running. Elapsed time: $($stopWatch.Elapsed)" -Status $logEntry -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                    $skipProgress = $true
                }
            }

            if (-not $skipProgress) {
                # Write progress
                Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed)" -Status $status.ScriptBlockOutput -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
            }

            # Check if complete
            $complete = $status.ScriptBlockOutput -eq "Complete!"
        }
    } until ($complete -or ($stopWatch.Elapsed -ge $timeSpan))

    if (-not $complete) {
        Write-Log "PSJOB: $($currentItem.vmName): Configuration did not complete in allotted time ($timeout minutes) for $($currentItem.role)." -OutputStream -Failure
    }
    else {
        Write-Progress "$($currentItem.role) configuration completed successfully. Elapsed time: $($stopWatch.Elapsed)" -Status $status.ScriptBlockOutput -Completed
        Write-Log "PSJOB: $($currentItem.vmName): Configuration completed successfully for $($currentItem.role)." -OutputStream -Success
    }
}

Clear-Host

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
    $result = ./genconfig.ps1 -InternalUseOnly

    if (-not $result.DeployNow) {
        return
    }

    if ($result.ForceNew) {
        $ForceNew = $true
    }

    $configResult = Get-UserConfiguration -Configuration $result.ConfigFileName

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

# Timer
$timer = New-Object -TypeName System.Diagnostics.Stopwatch
$timer.Start()

# Load configuration
try {
    $result = Test-Configuration -InputObject $userConfig
    if ($result.Valid) {
        $deployConfig = $result.DeployConfig
        Write-Log "Main: Config validated successfully." -Success
    }
    else {
        Write-Log "Main: Config validation failed. `r`n$($result.Message)" -Failure
        return
    }
}
catch {
    Write-Log "Main: Failed to load $Configuration.json file. Review vmbuild.log. $_" -Failure
    return
}

# Download required files
Get-FilesForConfiguration -InputObject $deployConfig -WhatIf:$WhatIf -ForceDownloadFiles:$ForceDownloadFiles

if ($DownloadFilesOnly.IsPresent) {
    $timer.Stop()
    Write-Host
    Write-Log "### SCRIPT FINISHED. Elapsed Time: $($timer.Elapsed)" -Success
    Write-Host
    return
}

# Test if hyper-v switch exists, if not create it
Write-Log "Main: Creating/verifying whether a Hyper-V switch for specified network exists." -Activity
$switch = Test-NetworkSwitch -Network $deployConfig.vmOptions.network -DomainName $deployConfig.vmOptions.domainName
if (-not $switch) {
    Write-Log "Main: Failed to verify/create Hyper-V switch for specified network ($($deployConfig.vmOptions.network)). Exiting." -Failure
    return
}

# DSC Folder
$cmDscFolder = "configmgr"

# Remove existing jobs
$existingJobs = Get-Job
if ($existingJobs) {
    Write-Log "Main: Stopping and removing existing jobs." -Activity
    foreach ($job in $existingJobs) {
        Write-Log "Main: Removing job $($job.Id) with name $($job.Name)"
        $job | Stop-Job -ErrorAction SilentlyContinue
        $job | Remove-Job -ErrorAction SilentlyContinue
    }
}

Write-Log "Main: Creating RDCMan file for specified config" -Activity
$desktopPath = [Environment]::GetFolderPath("Desktop")
$rdcManFilePath = Join-Path $DesktopPath "memlabs.rdg"
New-RDCManFile $deployConfig $rdcManFilePath

Write-Log "Main: Creating Virtual Machines." -Activity

# Array to store PS jobs
[System.Collections.ArrayList]$jobs = @()

foreach ($currentItem in $deployConfig.virtualMachines) {

    if ($WhatIf) {
        Write-Log "Main: Will start a job to create VM $($currentItem.vmName)"
        continue
    }

    $job = Start-Job -ScriptBlock $VM_Create -Name $currentItem.vmName -ErrorAction Stop -ErrorVariable Err

    if ($Err.Count -ne 0) {
        Write-Log "Main: Failed to start job to create VM $($currentItem.vmName). $Err" -Failure
    }
    else {
        Write-Log "Main: Created job $($job.Id) to create VM $($currentItem.vmName)"
        $jobs += $job
    }
}

Write-Log "Main: Waiting for VM Jobs to deploy and configure the virtual machines." -Activity

do {
    $runningJobs = $jobs | Where-Object { $_.State -ne "Completed" } | Sort-Object -Property Id
    foreach ($job in $runningJobs) {
        Write-JobProgress($job)
    }

    $completedJobs = $jobs | Where-Object { $_.State -eq "Completed" } | Sort-Object -Property Id
    foreach ($job in $completedJobs) {
        Write-Host "`n=== $($job.Name) (Job ID $($job.Id)) output:" -ForegroundColor Cyan
        $job | Select-Object -ExpandProperty childjobs | Select-Object -ExpandProperty Output
        Write-JobProgress($job)
        #$job | Remove-Job -Force -Confirm:$false
        $jobs.Remove($job)
    }

    # Sleep
    Start-Sleep -Seconds 1

} until ($runningJobs.Count -eq 0)

# Write-Progress -Activity "Waiting for virtual machines to be created" -Completed

$timer.Stop()
Write-Host
Write-Log "### SCRIPT FINISHED. Elapsed Time: $($timer.Elapsed)" -Success
Write-Host