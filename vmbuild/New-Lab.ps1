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
    [Parameter(Mandatory = $false, HelpMessage = "Skip to Phase 3!")]
    [switch]$Phase3,
    [Parameter(Mandatory = $false, HelpMessage = "Skip Phase 3!")]
    [switch]$SkipPhase3,
    [Parameter(Mandatory = $false, HelpMessage = "Dry Run. Do not use. Deprecated.")]
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
        Write-Log "Failed to set window size. $_" -LogOnly -Warning
    }
}

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Critical Failure! $($Common.FatalError)" -Failure
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

function New-VMJobs {

    param(
        [int]$Phase,
        [object]$deployConfig
    )

    switch ($Phase) {
        0 {
            $PhaseDescription = "Preparation"
            Write-Log "Phase $Phase - Preparing existing Virtual Machines" -Activity
        }

        1 {
            $PhaseDescription = "Creation"
            Write-Log "Phase $Phase - Creating Virtual Machines" -Activity
        }

        2 {
            $PhaseDescription = "Configuration"
            Write-Log "Phase $Phase - Configuring Virtual Machines" -Activity
        }

        3 {
            $PhaseDescription = "Configuration"
            Write-Log "Phase $Phase - Configuring SQL Always On" -Activity
        }
    }

    Write-Host


    [System.Collections.ArrayList]$jobs = @()
    $job_created_yes = 0
    $job_created_no = 0

    # Track all VM's for removal, if failures encountered
    $global:vm_remove_list = @()

    foreach ($currentItem in $deployConfig.virtualMachines) {

        # Don't touch non-hidden VM's in Phase 0
        if ($Phase -eq 0 -and -not $currentItem.hidden) {
            continue
        }

        # Don't touch hidden VM's in Phase 1
        if ($Phase -eq 1 -and $currentItem.hidden) {
            continue
        }

        # Add non-hidden VM's to removal list, in case Phase 1 fails
        if ($Phase -eq 1 -and -not $currentItem.hidden) {
            $global:vm_remove_list += $currentItem.vmName
        }

        # Skip Phase 2 for OSDClient, nothing for us to do
        if ($Phase -eq 2 -and $currentItem.role -eq "OSDClient") {
            continue
        }

        # Skip Phase 3 for all machines, except SQLAO's primary node
        if ($Phase -eq 3 -and ($currentItem.role -ne "SQLAO" -or ($currentItem.role -eq "SQLAO" -and -not $currentItem.OtherNode))) {
            continue
        }

        $deployConfigCopy = $deployConfig | ConvertTo-Json -Depth 3 | ConvertFrom-Json
        Add-PerVMSettings -deployConfig $deployConfigCopy -thisVM $currentItem

        if ($WhatIf) {
            Write-Log "Will start a job for VM $PhaseDescription $($currentItem.vmName)"
            continue
        }

        if ($Phase -eq 0 -or $Phase -eq 1) {
            $job = Start-Job -ScriptBlock $global:VM_Create -Name $currentItem.vmName -ErrorAction Stop -ErrorVariable Err
        }
        else {
            $job = Start-Job -ScriptBlock $global:VM_Config -Name $currentItem.vmName -ErrorAction Stop -ErrorVariable Err
        }

        if ($Err.Count -ne 0) {
            Write-Log "Failed to start job for VM $PhaseDescription $($currentItem.vmName). $Err" -Failure
            $job_created_no++
        }
        else {
            Write-Log "Created job $($job.Id) for VM $PhaseDescription $($currentItem.vmName)" -LogOnly
            $jobs += $job
            $job_created_yes++
        }
    }

    if ($job_created_no -eq 0) {
        Write-Log "Created $job_created_yes jobs for VM $PhaseDescription. Waiting for jobs."
    }
    else {
        Write-Log "Created $job_created_yes jobs for VM $PhaseDescription. Failed to create $job_created_no jobs."
    }

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

            # if ($Phase -eq 2) {
            #     Write-Host "`n=== $($job.Name) (Job ID $($job.Id)) output:" -ForegroundColor Yellow
            # }

            $jobOutput = $job | Select-Object -ExpandProperty childjobs | Select-Object -ExpandProperty Output
            $incrementCount = $true
            foreach ($line in $jobOutput) {
                $line = $line.ToString().Trim()
                if ($line.StartsWith("ERROR")) {
                    Write-Host $line -ForegroundColor Red
                    if ($incrementCount) { $failedCount++ }
                }
                elseif ($line.StartsWith("WARNING")) {
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

    Write-Log "`n$successCount jobs completed successfully; $warningCount warnings, $failedCount failures."

    if ($failedCount -gt 0) {
        return $false
    }

    return $true
}

Clear-Host

# Main script starts here
try {

    Write-Host ("`r`n" * 6)
    Start-Maintenance

    if ($Configuration) {
        # Get user configuration
        $configResult = Get-UserConfiguration -Configuration $Configuration
        if ($configResult.Loaded) {
            $userConfig = $configResult.Config
            # Write-Host ("`r`n" * (($userConfig.virtualMachines.Count * 3) + 3))
            Write-Log "### START." -Success
            Write-Log "Validating specified configuration: $Configuration" -Activity
        }
        else {
            Write-Log "### START." -Success
            Write-Log "Validating specified configuration: $Configuration" -Activity
            Write-Log $configResult.Message -Failure
            Write-Host
        }

    }
    else {
        Write-Log "No Configuration specified. Calling genconfig." -Activity
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
            # Clear-Host
            # Write-Host ("`r`n" * (($userConfig.virtualMachines.Count * 3) + 3))
            Write-Log "### START." -Success
            Write-Log "Using $($result.ConfigFileName) provided by genconfig" -Activity
            Write-Log "genconfig specified DeployNow: $($result.DeployNow); ForceNew: $($result.ForceNew)"
        }
        else {
            Write-Log "### START." -Success
            Write-Log "Validating specified configuration: $Configuration" -Activity
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
        if ($testConfigResult.Valid -or $Phase3.IsPresent) {
            $deployConfig = $testConfigResult.DeployConfig
            Add-ExistingVMsToDeployConfig -config $deployConfig
            $InProgessVMs = @()

            foreach ($thisVM in $deployConfig.virtualMachines) {
                $thisVMObject = Get-VMObjectFromConfigOrExisting -deployConfig $deployConfig -vmName $thisVM.vmName
                if ($thisVMObject.inProgress -eq $true) {
                    $InProgessVMs += $thisVMObject.vmName
                }

            }
            if ($InProgessVMs.Count -gt 0) {
                Write-Host
                write-host -ForegroundColor Blue "*************************************************************************************************************************************"
                write-host -ForegroundColor Red "ERROR: Virtual Machiness: [ $($InProgessVMs -join ",") ] ARE CURRENTLY IN A PENDING STATE."
                write-log "ERROR: Virtual Machiness: [ $($InProgessVMs -join ",") ] ARE CURRENTLY IN A PENDING STATE." -LogOnly
                write-host
                write-host -ForegroundColor White "The Previous deployment may be in progress, or may have failed. Please wait for existing deployments to finish, or delete these in-progress VMs"
                write-host -ForegroundColor Blue "*************************************************************************************************************************************"

                return
            }

            Write-Log "Config validated successfully." -Success
        }
        else {
            Write-Log "Config validation failed. `r`n$($testConfigResult.Message)" -Failure
            Write-Host
        }
    }
    catch {
        Write-Log "Failed to load $Configuration.json file. Review vmbuild.log. $_" -Failure
        Write-Host
        return
    }

    # Change log location
    $domainName = $deployConfig.vmOptions.domainName
    Write-Log "Starting deployment. Review VMBuild.$domainName.log" -Activity
    $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainName.log"

    # Download required files
    $success = Get-FilesForConfiguration -InputObject $deployConfig -WhatIf:$WhatIf -UseCDN:$UseCDN -ForceDownloadFiles:$ForceDownloadFiles
    if (-not $success) {
        Write-Host
        Write-Log "Failed to download all required files. Retrying download of missing files in 2 minutes... " -Warning
        Start-Sleep -Seconds 120
        $success = Get-FilesForConfiguration -InputObject $deployConfig -WhatIf:$WhatIf -UseCDN:$UseCDN -ForceDownloadFiles:$ForceDownloadFiles
        if (-not $success) {
            $timer.Stop()
            Write-Log "Failed to download all required files. Exiting." -Failure
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
    $worked = Add-SwitchAndDhcp -NetworkName $deployConfig.vmOptions.network -NetworkSubnet $deployConfig.vmOptions.network -DomainName $deployConfig.vmOptions.domainName
    if (-not $worked) {
        return
    }

    # Internet Client VM Switch and DHCP Scope
    $containsIN = ($deployConfig.virtualMachines.role -contains "InternetClient") -or ($deployConfig.virtualMachines.role -contains "AADClient")
    if ($containsIN) {
        $worked = Add-SwitchAndDhcp -NetworkName "Internet" -NetworkSubnet "172.31.250.0"
        if (-not $worked) {
            return
        }
    }

    $containsAO = ($deployConfig.virtualMachines.role -contains "SQLAO")
    if ($containsAO) {
        #$network = $deployConfig.vmOptions.network.Substring(0, $deployConfig.vmOptions.network.LastIndexOf("."))
        #$DNS = $network + ".1"
        $worked = Add-SwitchAndDhcp -NetworkName "cluster" -NetworkSubnet "10.250.250.0"
        if (-not $worked) {
            return
        }
    }

    # Remove existing jobs
    $existingJobs = Get-Job
    if ($existingJobs) {
        Write-Log "Stopping and removing existing jobs." -Verbose -LogOnly
        foreach ($job in $existingJobs) {
            Write-Log "Removing job $($job.Id) with name $($job.Name)" -Verbose -LogOnly
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -ErrorAction SilentlyContinue
        }
    }

    # Generate RDCMan file
    #New-RDCManFile $deployConfig $global:Common.RdcManFilePath

    # Existing DC scenario
    $existingDC = $deployConfig.parameters.ExistingDCName

    # Remove DNS records for VM's in this config, if existing DC
    if ($existingDC -and -not $Phase3.IsPresent) {
        Write-Log "Attempting to remove existing DNS Records" -Activity -HostOnly
        foreach ($item in $deployConfig.virtualMachines | Where-Object { -not ($_.hidden) } ) {
            Remove-DnsRecord -DCName $existingDC -Domain $deployConfig.vmOptions.domainName -RecordToDelete $item.vmName
        }
    }

    Write-Log "Deployment Summary" -Activity -HostOnly
    Write-Host
    Show-Summary -deployConfig $deployConfig

    # Return if debug enabled
    if ($enableDebug) {
        return $deployConfig
    }

    # Phases:
    # 0 - Prepare existing VMs
    # 1 - Create new VMs
    # 2 - Configure VMs (run DSC)
    # 3 - Configure SQL AO

    if ($Phase3.IsPresent) {
        $configured = New-VMJobs -Phase 3 -deployConfig $deployConfig
    }
    else {

        $containsHidden = $deployConfig.virtualMachines | Where-Object { $_.hidden -eq $true }
        if ($containsHidden) {
            $prepared = New-VMJobs -Phase 0 -deployConfig $deployConfig
        }
        else {
            $prepared = $true
        }

        if (-not $prepared) {
            Write-Log "Phase 1 - Skipped Virtual Machine Creation and Configuration because errors were encountered in Phase 0." -Activity
            $created = $configured = $false
        }
        else {

            $created = New-VMJobs -Phase 1 -deployConfig $deployConfig

            if (-not $created) {
                Write-Log "Phase 2 - Skipped Virtual Machine Configuration because errors were encountered in Phase 1." -Activity
            }
            else {

                # Clear out vm remove list
                $global:vm_remove_list = @()

                # Create/Updated RDCMan file
                if (Test-Path "C:\tools\rdcman.exe") {
                    Start-Sleep -Seconds 5
                    New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
                }

                $configured = New-VMJobs -Phase 2 -deployConfig $deployConfig

                if ($configured -and $containsAO) {
                    if (-not $SkipPhase3.IsPresent) {
                        $configured = New-VMJobs -Phase 3 -deployConfig $deployConfig
                    }
                }
            }
        }
    }

    $timer.Stop()

    if (-not $created -or -not $configured) {
        Write-Host
        Write-Log "### SCRIPT FINISHED WITH FAILURES. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Failure
    }
    else {
        Write-Host
        Write-Log "### SCRIPT FINISHED. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Success
    }

    $NewLabsuccess = $true
}
catch {
    Write-Exception -ExceptionInfo $_ -AdditionalInfo ($deployConfig | ConvertTo-Json)
}
finally {
    # Ctrl + C brings us here :)
    if ($NewLabsuccess -ne $true) {
        Write-Log "Script exited unsuccessfully. Ctrl-C may have been pressed. Killing running jobs." -LogOnly
    }

    Get-Job | Stop-Job

    # Close PS Sessions
    foreach ($session in $global:ps_cache.Keys) {
        Write-Log "Closing PS Session $session" -Verbose
        Remove-PSSession $global:ps_cache.$session -ErrorAction SilentlyContinue
    }

    # Delete in progress or failed VM's
    if ($global:vm_remove_list.Count -gt 0) {
        Write-Host
        if ($NewLabsuccess) {
            Write-Log "Phase 1 encountered failures. Removing all VM's created in Phase 1." -Warning
        }
        else {
            Write-Log "Script exited before Phase 1 completion. Removing all VM's created in Phase 1." -Warning
        }
        foreach ($vmname in $global:vm_remove_list) {
            Remove-VirtualMachine -VmName $vmname
        }
    }

    # Clear vm remove list
    $global:vm_remove_list = @()

    # uninit common
    $Common.Initialized = $false

    # Set quick edit back
    Set-QuickEdit
}

Write-Host