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
    [Parameter(Mandatory = $false, HelpMessage = "Run specified Phase only.")]
    [int]$Phase,
    [Parameter(Mandatory = $false, HelpMessage = "Skip specified Phase!")]
    [int[]]$SkipPhase,
    [Parameter(Mandatory = $false, HelpMessage = "Run specified Phase and above")]
    [int]$StartPhase,
    [Parameter(Mandatory = $false, HelpMessage = "Stop at specified Phase!")]
    [int]$StopPhase,
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



if (-not $Common.DevBranch) {
    Clear-Host
}

# Main script starts here
try {

    Write-Host ("`r`n" * 6)
    Start-Maintenance

    if ($Configuration) {
        Write-Log "### START." -Activity
        Write-Log "Validating specified configuration: $Configuration"
        $configResult = Get-UserConfiguration -Configuration $Configuration  # Get user configuration
        if ($configResult.Loaded) {
            $userConfig = $configResult.Config
            # Write-Host ("`r`n" * (($userConfig.virtualMachines.Count * 3) + 3))
        }
        else {
            Write-Log $configResult.Message -Failure
            Write-Host
            return
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

        if (-not $($result.DeployNow)) {
            return
        }

        Write-Log "### START." -Activity
        Write-Log "Using $($result.ConfigFileName) provided by genconfig"
        Write-Log "genconfig specified DeployNow: $($result.DeployNow); ForceNew: $($result.ForceNew)" -Verbose
        $configResult = Get-UserConfiguration -Configuration $result.ConfigFileName

        if ($configResult.Loaded) {
            $userConfig = $configResult.Config
        }
        else {
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
        if ($testConfigResult.Valid -or ($Phase -or $SkipPhase -or $StopPhase -or $StartPhase)) {
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

            Write-Log "Configuration validated successfully." -Success
        }
        else {
            Write-Host
            Write-Log "Configuration validation failed." -Failure
            Write-Host
            Write-ValidationMessages -TestObject $testConfigResult
            Write-Host
            return
        }
    }
    catch {
        Write-Log "Failed to load $Configuration.json file. Review vmbuild.log. $_" -Failure
        Write-Host
        return
    }

    # Change log location
    $domainName = $deployConfig.vmOptions.domainName
    Write-Log "Starting deployment. Review VMBuild.$domainName.log"
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
    #if ($containsIN) {
    $worked = Add-SwitchAndDhcp -NetworkName "Internet" -NetworkSubnet "172.31.250.0"
    if ($containsIN -and (-not $worked)) {
        return
    }
    #}

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

    Write-Log "Deployment Summary" -Activity -HostOnly
    Show-Summary -deployConfig $deployConfig

    # Return if debug enabled
    if ($enableDebug) {
        return $deployConfig
    }

    # Phases:
    # 0 - Prepare existing VMs
    # 1 - Create new VMs
    # 2 - Configure VMs (run DSC)
    # 3 - Configure Other
    # 4 - Configure SQL

    if ($Phase) {
        $created = $true
        $configured = Start-Phase -Phase $Phase -deployConfig $deployConfig
    }
    else {

        $containsHidden = $deployConfig.virtualMachines | Where-Object { $_.hidden -eq $true }
        if ($containsHidden) {
            $prepared = Start-Phase -Phase 0 -deployConfig $deployConfig
        }
        else {
            $prepared = $true
        }

        if (-not $prepared) {
            Write-Log "Phase 1 - Skipped Virtual Machine Creation and Configuration because errors were encountered in Phase 0." -Activity
            $created = $configured = $false
        }
        else {

            $created = Start-Phase -Phase 1 -deployConfig $deployConfig

            if (-not $created) {
                Write-Log "Phase 2 - Skipped Virtual Machine Configuration because errors were encountered in Phase 1." -Activity
            }
            else {

                # Clear out vm remove list
                $global:vm_remove_list = @()

                # Create/Updated RDCMan file
                Start-Sleep -Seconds 5
                New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false

                $start = 2
                if ($StartPhase) {
                    $start = $StartPhase
                }

                $maxPhase = 6
                if ($StopPhase) {
                    $maxPhase = $StopPhase
                }

                for ($i=$start; $i -le $maxPhase; $i++) {

                    if ($SkipPhase -and $i -in $SkipPhase) {
                        continue
                    }

                    $configured = Start-Phase -Phase $i -deployConfig $deployConfig
                    if (-not $configured) {
                        break
                    }
                }
            }
        }
    }

    $timer.Stop()

    if (-not $created -or -not $configured) {
        Write-Host
        Write-Log "### SCRIPT FINISHED WITH FAILURES. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Failure -NoIndent
        Write-Host
    }
    else {
        Write-Log "### SCRIPT FINISHED. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Activity
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