param (
    [Parameter(Mandatory=$true, HelpMessage="Lab Configuration: Standalone, Hierarchy, SingleMachine.")]
    [string]$Configuration,
    [Parameter(Mandatory=$false, HelpMessage="Force recreation of virtual machines, if already present.")]
    [switch]$ForceNew,
    [Parameter(Mandatory=$false, HelpMessage="Timeout in minutes for VM Configuration.")]
    [int]$RoleConfigTimeoutMinutes,
    [Parameter(Mandatory=$false, HelpMessage="Dry Run.")]
    [switch]$WhatIf
)

# Dot source common
. $PSScriptRoot\Common.ps1

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Main: Critical Failure! $($Common.FatalError)" -Failure
    return
}

function Write-JobProgress
{
    param($Job)

    #Make sure the first child job exists
    if($null -ne $Job.ChildJobs[0].Progress)
    {
        #Extracts the latest progress of the job and writes the progress
        $latestPercentComplete = 0
        $lastProgress = $Job.ChildJobs[0].Progress | Where-Object {$_.Activity -ne "Preparing modules for first use."} | Select-Object -Last 1

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

#Clear-Host
Write-Host
Write-Host
Write-Host
Write-Host
Write-Host
Write-Host
Write-Host


Write-Log "### START." -Success
Write-Log "Main: Creating virtual machines for specified configuration: $Configuration" -Activity

# Timer
$timer = New-Object -TypeName System.Diagnostics.Stopwatch
$timer.Start()

# Get deployment configuration
$configPath = Join-Path $Common.ConfigPath "$Configuration.json"
if (-not (Test-Path $configPath)) {
    Write-Log "Main: $configPath not found for specified configuration. Please create the config, and try again." -Failure
    return
}
else {
    Write-Log "Main: $configPath will be used for creating the lab environment."
}

try {
    # Load configuration
    $jsonConfig = Get-Content -Path $configPath | ConvertFrom-Json
}
catch {
    Write-Log "Main: Failed to load $Configuration.json file. $_" -Failure
    return
}

# Create VM script block
$VM_Create = {

    # Dot source common
    . $using:PSScriptRoot\Common.ps1

    # Get required variables from parent scope
    $cmVersion = $using:cmVersion
    $currentItem = $using:currentItem
    $jsonConfig = $using:jsonConfig
    $forceNew = $using:ForceNew

    # TODO: Add Validation here & Switch Creation + NAT config code
    if ($cmVersion -eq "current-branch") {$SwitchName = "InternalSwitchCB1"} else { $SwitchName = "InternalSwitchTP1"}
    $imageFile = $Common.ImageList.Files | Where-Object {$_.id -eq $currentItem.operatingSystem }
    $imageFileName = $imageFile.filename
    $vhdxPath = Join-Path $Common.AzureFilesPath $imageFileName
    $virtualMachinePath = "E:\VirtualMachines"

    # Create VM
    $created = New-VirtualMachine -VmName $currentItem.vmName -VmPath $virtualMachinePath -ForceNew:$forceNew -SourceDiskPath $vhdxPath -Memory $currentItem.hardware.memory -Generation $currentItem.hardware.generation -Processors $currentItem.hardware.virtualProcs -SwitchName $SwitchName -WhatIf:$using:WhatIf
    if (-not $created) {
        Write-Log "PSJOB: $($currentItem.vmName): VM was not created. Use ForceNew switch if it already exists." -Warning
        Write-Log "PSJOB: $($currentItem.vmName): VM was not created. Use ForceNew switch if it already exists. Check vmbuild.log." -Warning -OutputStream -HostOnly
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
    Copy-Item -ToSession $ps -Path "$using:PSScriptRoot\DSC\$cmVersion" -Destination "C:\staging\DSC" -Recurse -Container -Force

    # Extract DSC modules
    $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { Expand-Archive -Path "C:\staging\DSC\$using:cmVersion\DSC.zip" -DestinationPath "C:\staging\DSC\$using:cmVersion\modules" } -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to extract PS modules inside the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Copy SQL files to VM for CS/PS roles
    Write-Log "PSJOB: $($currentItem.vmName): Copying SQL installation files to the VM."
    Write-Progress -Activity "$($currentItem.vmName): Copying SQL installation files to the VM" -Activity "Working" -Completed
    $sqlIsoPath = Join-Path $using:Common.IsoPath "SQL-2019\en_sql_server_2019_enterprise_x64_dvd_5e1ecc6b.iso"
    $sqlCUPath = Join-Path $using:Common.IsoPath "SQL-2019\SQLServer2019-KB5004524-x64.exe"
    $sqlCUFile = Split-Path $sqlCUPath -Leaf

    if ($currentItem.role -eq "PS" -or $currentItem.role -eq "CS") {

        # Get SQL 2019 CU12
        if (-not (Test-Path $sqlCUPath)) {
            Get-File -Source "https://download.microsoft.com/download/6/e/7/6e72dddf-dfa4-4889-bc3d-e5d3a0fd11ce/SQLServer2019-KB5004524-x64.exe" -Destination $sqlCUPath -Action "Downloading" -DisplayName "Obtaining SQL 2019 CU 12"
        }

        # Add SQL ISO to guess
        Set-VMDvdDrive -VMName $currentItem.vmName -Path $sqlIsoPath

        # Create C:\temp\SQL inside VM
        $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { New-Item -Path "C:\temp\SQL" -ItemType Directory -Force } -WhatIf:$WhatIf
        $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { Copy-Item -Path "D:\*" -Destination "C:\temp\SQL" -Recurse -Force -Confirm:$false } -WhatIf:$WhatIf
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to copy SQL installation files to the VM. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
        }

        $result = Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { New-Item -Path "C:\temp\SQL_CU" -ItemType Directory -Force } -WhatIf:$WhatIf
        Copy-Item -ToSession $ps -Path $sqlCUPath -Destination "C:\temp\SQL_CU\$sqlCUFile" -Force

        # Eject ISO from guest
        Get-VMDvdDrive -VMName $currentItem.vmName | Set-VMDvdDrive -Path $null
    }

    # Define DSC ScriptBlock
    $DSC_InstallModules = {

        # Get required variables from parent scope
        $cmVersion = $using:cmVersion

        # Create init log
        $log = "C:\staging\DSC\DSC_Init.log"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "DSC_InstallModules: Started at $time" | Out-File $log -Force

        # Install modules
        "Installing modules" | Out-File $log -Append
        $modules = Get-ChildItem -Path "C:\staging\DSC\$cmVersion\modules" -Directory
        foreach ($folder in $modules) {
            Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force
            Import-Module $folder.Name -Force;
        }
    }

    $DSC_CreateConfig = {

        # Get required variables from parent scope
        $cmVersion = $using:cmVersion
        $currentItem = $using:currentItem
        $adminCreds = $using:Common.LocalAdmin
        $jsonConfig = $using:jsonConfig

        # Define DSC variables
        $dscConfigScript = "C:\staging\DSC\$cmVersion\$($currentItem.role)Configuration.ps1"
        $dscConfigPath = "C:\staging\DSC\$cmVersion\DSCConfiguration"

        # Update init log
        $log = "C:\staging\DSC\DSC_Init.log"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "DSC_CreateConfig: Started at $time" | Out-File $log -Append
        "Running as $env:USERDOMAIN\$env:USERNAME" | Out-File $log -Append
        "" | Out-File $log -Append
        "Current Item = $currentItem" | Out-File $log -Append
        "Role Name = $($currentItem.role)" | Out-File $log -Append
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

        # Compile config to create MOFs
        "Running configuration script to create MOF in $dscConfigPath" | Out-File $log -Append

        # Define Arguments (TODO: convert this to a function which returns config values)
        $HashArguments = @{
            DomainName       = "contoso.com"
            DCName           = "CM-DC1"
            DPMPName         = "CM-MP1"
            CSName           = "CM-CS1"
            PSName           = "CM-PS1"
            ClientName       = "CM-CL1,CM-CL2"
            Configuration    = "Standalone"
            DNSIPAddress     = "192.168.1.1"
            AdminCreds       = $adminCreds
            DefaultGateway   = "192.168.1.200"
            DHCPScopeId      = "192.168.1.0"
            DHCPScopeStart   = "192.168.1.20"
            DHCPScopeEnd     = "192.168.1.199"
            InstallConfigMgr = $false
            UpdateToLatest   = $false
            PushClients      = $true
        }

        if ($currentItem.role -eq "DomainMember") {
            # Overwrite client name for Client Config, since it needs it's actual name
            $HashArguments["ClientName"] = $currentItem.vmName
        }

        # Compile config, to create MOF
        & "$($currentItem.role)Configuration" @HashArguments -ConfigurationData $cd -OutputPath $dscConfigPath
    }

    $DSC_StartConfig = {

        # Get required variables from parent scope
        $cmVersion = $using:cmVersion

        # Define DSC variables
        $dscConfigPath = "C:\staging\DSC\$cmVersion\DSCConfiguration"

        # Update init log
        $log = "C:\staging\DSC\DSC_Init.log"
        $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
        "DSC_StartConfig: Started at $time" | Out-File $log -Append

        "Set-DscLocalConfigurationManager for $dscConfigPath" | Out-File $log -Append
        Set-DscLocalConfigurationManager -Path $dscConfigPath -Verbose

        "Start-DscConfiguration for $dscConfigPath" | Out-File $log -Append
        Start-DscConfiguration -Wait -Path $dscConfigPath -Verbose -ErrorAction Stop
    }

    Write-Log "PSJOB: $($currentItem.vmName): Starting $($currentItem.role) role configuration via DSC." -OutputStream

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $currentItem.domainName -ScriptBlock $DSC_InstallModules -DisplayName "DSC: Install Modules" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to install DSC modules. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $currentItem.domainName -ScriptBlock $DSC_CreateConfig -DisplayName "DSC: Create $($currentItem.role) Configuration" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to create $($currentItem.role) configuration. $($result.ScriptBlockOutput)" -Failure -OutputStream
        return
    }

    # Enable PS Remoting on client OS before starting DSC. Ignore failures, this will work but reports a failure...
    if ($currentItem.operatingSystem -notlike "*SERVER*") {
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $currentItem.domainName -ScriptBlock { Enable-PSRemoting -ErrorAction SilentlyContinue -Confirm:$false -SkipNetworkProfileCheck } -DisplayName "DSC: Enable-PSRemoting. Ignore failures." -WhatIf:$WhatIf
    }

    $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $currentItem.domainName -ScriptBlock $DSC_StartConfig -DisplayName "DSC: Start $($currentItem.role) Configuration" -WhatIf:$WhatIf
    if ($result.ScriptBlockFailed) {
        Write-Log "$($currentItem.vmName): DSC: Failed to start $($currentItem.role) configuration. Retrying once. $($result.ScriptBlockOutput)" -Warning
        # Retry once before exiting
        $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $currentItem.domainName -ScriptBlock $DSC_StartConfig -DisplayName "DSC: Start $($currentItem.role) Configuration" -WhatIf:$WhatIf
        if ($result.ScriptBlockFailed) {
            Write-Log "PSJOB: $($currentItem.vmName): DSC: Failed to Start $($currentItem.role) configuration. Exiting. $($result.ScriptBlockOutput)" -Failure -OutputStream
            return
        }
    }

    # Wait for DSC, timeout after X minutes
    # Write-Log "PSJOB: $($currentItem.vmName): Waiting for $($currentItem.role) role configuration via DSC." -OutputStream

    $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
    $timeout = if ($using:RoleConfigTimeoutMinutes) { $using:RoleConfigTimeoutMinutes } else { 300 }
    $timeSpan = New-TimeSpan -Minutes $timeout
    $stopWatch.Start()

    $complete = $false
    $previousStatus = ""
    do {
        $status = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $currentItem.domainName -ScriptBlock { Get-Content C:\staging\DSC\DSC_Status.txt } -SuppressLog -WhatIf:$WhatIf
        Start-Sleep -Seconds 3

        if ($status.ScriptBlockOutput -and $status.ScriptBlockOutput -is [string]) {
            # Write to log if status changed
            if($status.ScriptBlockOutput -ne $previousStatus) {
                Write-Log "PSJOB: $($currentItem.vmName): DSC: Current Status for $($currentItem.role): $($status.ScriptBlockOutput)"
                $previousStatus = $status.ScriptBlockOutput
            }

            # Special case to write log ConfigMgrSetup.log entries in progress
            $skipProgress = $false
            $outString = $status.ScriptBlockOutput | Out-String
            $setupPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
            if($outString.StartsWith($setupPrefix)) {
                $result = Invoke-VmCommand -VmName $currentItem.vmName -VmDomainName $currentItem.domainName -ScriptBlock { Get-Content "C:\ConfigMgrSetup.log" -tail 1 } -SuppressLog -WhatIf:$WhatIf
                if (-not $result.ScriptBlockFailed) {
                    $logEntry = $result.ScriptBlockOutput
                    $logEntry = "ConfigMgrSetup.log: " + $logEntry.Substring(0, $logEntry.IndexOf("$"))
                    Write-Progress "Waiting $timeout minutes for $($currentItem.role) Configuration. ConfigMgrSetup is running. Elapsed time: $($stopWatch.Elapsed)" -Status $logEntry -PercentComplete ($stopWatch.ElapsedMilliseconds/$timespan.TotalMilliseconds * 100)
                    $skipProgress = $true
                }
            }

            if (-not $skipProgress) {
                # Write progress
                Write-Progress "Waiting $timeout minutes for $($currentItem.role) configuration. Elapsed time: $($stopWatch.Elapsed)" -Status $status.ScriptBlockOutput -PercentComplete ($stopWatch.ElapsedMilliseconds/$timespan.TotalMilliseconds * 100)
            }

            # Check if complete
            $complete = $status.ScriptBlockOutput -eq "Complete!"
        }
    } until ($complete -or ($stopWatch.Elapsed -ge $timeSpan))

    if (-not $complete) {
        Write-Log "PSJOB: $($currentItem.vmName): Configuration did not complete in allotted time ($timeout minutes) for $($currentItem.role)." -OutputStream -Failure
    }
    else {
        Write-Log "PSJOB: $($currentItem.vmName): Configuration completed successfully for $($currentItem.role)." -OutputStream -Success
    }
}

# CM Version
$cmVersion = "current-branch"

# Array to store PS jobs
[System.Collections.ArrayList]$jobs = @()

foreach ($currentItem in $jsonConfig) {

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

Write-Log "Main: Waiting for VM Jobs to deploy and finish configuring the virtual machines." -Activity

do {
    $runningJobs = $jobs | Where-Object { $_.State -ne "Completed" } | Sort-Object -Property Id
    foreach($job in $runningJobs) {
        Write-JobProgress($job)
    }

    $completedJobs = $jobs | Where-Object { $_.State -eq "Completed" } | Sort-Object -Property Id
    foreach($job in $completedJobs) {
        Write-Host "`n$($job.Name) (Job ID $($job.Id)) output:" -ForegroundColor Green
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
Write-Log "### COMPLETE. Elapsed Time: $($timer.Elapsed)" -Success
Write-Host