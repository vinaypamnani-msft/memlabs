#New-Lab.ps1
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Lab Configuration: Standalone, Hierarchy, etc.")]
    [ArgumentCompleter( {
            param ( $CommandName,
                $ParameterName,
                $WordToComplete,
                $CommandAst,
                $FakeBoundParameters
            )
            $ConfigPaths = Get-ChildItem -Path "$PSScriptRoot\config" -Filter *.json | Sort-Object -Property { $_.LastWriteTime -as [Datetime] } -Descending
            if ($WordToComplete) { $ConfigPaths = $ConfigPaths | Where-Object { $_.Name.ToLowerInvariant().StartsWith($WordToComplete.ToLowerInvariant()) } }
            $ConfigNames = ForEach ($Path in $ConfigPaths) {
                if ($Path.Name -eq "_storageConfig.json") { continue }
                if ($Path.Name -eq "_storageConfig2022.json") { continue }
                if ($Path.Name -eq "_storageConfig2024.json") { continue }
                If (Test-Path $Path) {
                    (Get-ChildItem $Path).BaseName
                }
            }
            return [string[]] $ConfigNames
        })]
    [string]$Configuration,
    [Parameter(Mandatory = $false, HelpMessage = "Download all files required by the specified config without deploying any VMs.")]
    [switch]$DownloadFilesOnly,
    [Parameter(Mandatory = $false, HelpMessage = "Force redownload of required files, if already present.")]
    [switch]$ForceDownloadFiles,
    [Parameter(Mandatory = $false, HelpMessage = "Timeout in minutes for VM Configuration.")]
    [int]$RoleConfigTimeoutMinutes = 300,
    [Parameter(Mandatory = $false, HelpMessage = "Do not resize PS window.")]
    [switch]$NoWindowResize,
    [Parameter(Mandatory = $false, HelpMessage = "Use Azure CDN for download.")]
    [switch]$UseCDN,
    [Parameter(Mandatory = $false, HelpMessage = "Run specified Phase only. Applies to Phase > 1.")]
    [int[]]$Phase,
    [Parameter(Mandatory = $false, HelpMessage = "Skip specified Phase! Applies to Phase > 1.")]
    [int[]]$SkipPhase,
    [Parameter(Mandatory = $false, HelpMessage = "Run specified Phase and above. Applies to Phase > 1.")]
    [ValidateRange(2, 10)]
    [int]$StartPhase,
    [Parameter(Mandatory = $false, HelpMessage = "Stop at specified Phase!")]
    [ValidateRange(2, 10)]
    [int]$StopPhase,
    [Parameter(Mandatory = $false, HelpMessage = "Dry Run. Do not use. Deprecated.")]
    [switch]$WhatIf,
    [Parameter(Mandatory = $false, HelpMessage = "Best not to use this. Skips configuration validation.")]
    [switch]$SkipValidation,
    [Parameter(Mandatory = $false, HelpMessage = "Migrate old VMs")]
    [switch]$Migrate,
    [Parameter(Mandatory = $false, HelpMessage = "Activate restore menu before deployment")]
    [switch]$Restore,
    [Parameter(Mandatory = $false, HelpMessage = "No prompt for domain snapshot")]
    [switch]$NoSnapshot

)

$global:NoSnapshot = $NoSnapshot

try {
    $desktopPath = [Environment]::GetFolderPath("CommonDesktop")
    $shortcutLocation = "$desktopPath\MEMLABS - VMBuild.lnk"
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutLocation)
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition

    $shortcut.TargetPath = Join-Path $scriptDirectory "VmBuild.cmd"
    $shortcut.IconLocation = "%SystemRoot%\System32\SHELL32.dll,208"
    $shortcut.Save()
    $exitcode = 1
    $bytes = [System.IO.File]::ReadAllBytes($shortcutLocation)
    # Set byte 21 (0x15) bit 6 (0x20) ON
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($shortcutLocation, $bytes)
}
catch {
    write-log -Verbose "Could not Set Shortcut $_" -logonly
}

# Tell common to re-init
if ($Common.Initialized) {
    $Common.Initialized = $false
}

if ($Migrate) {
    $StopPhase = 2
}

$NewLabsuccess = $false

# Set Debug & Verbose
$enableVerbose = if ($PSBoundParameters.Verbose -eq $true) { $true } else { $false };
$enableDebug = if ($PSBoundParameters.Debug -eq $true) { $true } else { $false };

# Dot source common
. $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose -InJob:$false

if ($global:init_failed) {
    Write-Log "Failed to initialize common. Exiting." -Failure
    exit 1
}


Test-NoRRAS


if (((Get-VMHost).EnableEnhancedSessionMode) -eq $false) {
    Set-VMhost -EnableEnhancedSessionMode $True
}

if (-not $NoWindowResize.IsPresent) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Primary -eq $true }

        $percent = 0.85
        $percentheight = 0.90
        $width = $screen.Bounds.Width * $percent
        $height = $screen.Bounds.Height * $percentheight

        # Set Window
        Set-Window -ProcessID $PID -X 20 -Y 20 -Width $width -Height $height
        $parent = (Get-CimInstance win32_process -ErrorAction SilentlyContinue | Where-Object processid -eq  $PID).parentprocessid
        $null = (New-Object -ComObject WScript.Shell).AppActivate($PID)
        if ($parent) {
            # set parent, cmd -> ps
            Set-Window -ProcessID $parent -X 20 -Y 20 -Width $width -Height $height
        }       
    }
    catch {
        Write-Log "Failed to set window size. $_" -LogOnly -Warning
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
    }
}

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Critical Failure! $($Common.FatalError)" -Failure
    exit 1
}

# Validate PS7
if (-not $Common.PS7) {
    Write-Log "You must use PowerShell version 7.1 or above. `n  Please use VMBuild.cmd to automatically install latest version of PowerShell or install manually from https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows.`n  If PowerShell 7.1 or above is already installed, run pwsh.exe to launch PowerShell and run the script again." -Failure
    exit 1
}

Set-PS7ProgressWidth

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name "WinREVersion" -PropertyType String -Value "10.0.20348.2201" -Force | Out-Null

if (-not $Common.DevBranch) {
    $image = (Join-Path $PSScriptRoot "MemLabs.png")
    Set-BackgroundImage $image "right" 5 "uniform"
    Get-Animate
}
else {
    $image = (Join-Path $PSScriptRoot "DevLabs.png")
    Set-BackgroundImage $image "right" 5 "uniform"
    Get-Animate
}

function Write-Phase {

    param(
        [int]$Phase
    )

    switch ($Phase) {
        0 {
            Write-Log "Phase $Phase - Preparing existing Virtual Machines" -Activity
        }

        1 {
            Write-Log "Phase $Phase - Creating Virtual Machines" -Activity
        }

        2 {
            Write-Log "Phase $Phase - Setup and Join Domain" -Activity
        }

        3 {
            Write-Log "Phase $Phase - Configure Virtual Machine" -Activity
        }

        4 {
            Write-Log "Phase $Phase - Install SQL" -Activity
        }

        5 {
            Write-Log "Phase $Phase - Configuring SQL Always On" -Activity
        }

        6 {
            Write-Log "Phase $Phase - Install WSUS" -Activity
        }

        7 {
            Write-Log "Phase $Phase - Setup Reporting Services" -Activity
        }

        8 {
            Write-Log "Phase $Phase - Setup ConfigMgr" -Activity
        }

        9 {
            Write-Log "Phase $Phase - Setup Multi-Forest ConfigMgr" -Activity
        }
        10 {
            Write-Log "Phase $Phase - Run Maintenance" -Activity
        }
    }
}

# Main script starts here
try {

    if ($Common.PS7) {
        Write-Host
    }
    else {
        Write-Host ("`r`n" * 6)
    }

    $global:SkipValidation = $false
    if ($SkipValidation.IsPresent) {
        $global:SkipValidation = $true
    }

    $principal = new-object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-RedX "MemLabs requires administrative rights to configure. Please run vmbuild.cmd as administrator." -ForegroundColor Red
        Write-Host
        Start-Sleep -seconds 60
        exit 1
    }

    Set-QuickEdit -DisableQuickEdit
    # $phasedRun = $Phase -or $SkipPhase -or $StopPhase -or $StartPhase

    # Automatically update DSC.Zip
    if ($Common.DevBranch) {
        Set-Location $PSScriptRoot  | Out-Null
        $psdLastWriteTime = (Get-ChildItem ".\DSC\TemplateHelpDSC\TemplateHelpDSC.psd1").LastWriteTime
        $psmLastWriteTime = (Get-ChildItem ".\DSC\TemplateHelpDSC\TemplateHelpDSC.psm1").LastWriteTime
        if (Test-Path ".\DSC\DSC.zip") {
            $zipLastWriteTime = (Get-ChildItem ".\DSC\DSC.zip").LastWriteTime + (New-TimeSpan -Minutes 1)
        }
        if (-not $zipLastWriteTime -or ($psdLastWriteTime -gt $zipLastWriteTime) -or ($psmLastWriteTime -gt $zipLastWriteTime)) {
            powershell .\dsc\createGuestDscZip.ps1 | Out-Host
            Set-Location $PSScriptRoot | Out-Null
            $exitcode = 55
            exit 55
        }
    }


    # Verify Hyper-V is installed
    Install-HyperV

    ### Run maintenance
    if (-not $Configuration) {
        Start-Maintenance
    }

    # Get config
    if (-not $Configuration) {
        Write-Log "No Configuration specified. Calling genconfig." -Activity
        Set-Location $PSScriptRoot
        $result = ./genconfig.ps1 -InternalUseOnly -Verbose:$enableVerbose -Debug:$enableDebug

        # genconfig was called with -Debug true, and returned DeployConfig instead of ConfigFileName
        if ($result.DeployConfig) {
            exit 0
        }

        # genconfig specified not to deploy
        if (-not $($result.DeployNow)) {
            exit 0
        }

        $Configuration = $result.ConfigFileName
    }

    Write-Log "### VALIDATE" -Activity

    # Load config
    if ($Configuration) {       
        $ConfigurationShort = Split-Path $Configuration -LeafBase
        Write-Log "Validating specified configuration: $Configuration"
        $configResult = Get-UserConfiguration -Configuration $Configuration  # Get user configuration
        if ($configResult.Loaded) {
            Write-GreenCheck "Loaded Configuration: $Configuration"
            $userConfig = $configResult.Config
            $Global:configfile = $configResult.ConfigPath
            Write-Log -LogOnly "Config file: $($configResult.ConfigPath)"
        }
        else {
            Write-Log $configResult.Message -Failure
            Write-Host
            exit 1
        }
    }
    else {
        Write-Host
        Write-Log "No Configuration was specified." -Failure
        Write-Host
        exit 1
    }

    # Determine if we need to run Phase 1
    $runPhase1 = $false
    $existingVMs = Get-List -Type VM -SmartUpdate
    $newVMs = @()
    $newVMs += $userConfig.virtualMachines | Where-Object { -not $_.Hidden -and ($userConfig.vmOptions.prefix + $_.vmName -notin $existingVMs.vmName) }
    $count = ($newVMs | Measure-Object).count
    if ($count -gt 0) {
        $runPhase1 = $true
        Write-Log -Verbose "Phase 1 is scheduled to run"
    }
    else {
        Write-Log -Verbose "Phase 1 is not scheduled to run: ExistingVMs = $($existingVMs.vmName -join ",") NewVMs = $($userConfig.virtualMachines.vmName -join ",")"
    }


    # Test Config
    try {
        $testConfigResult = Test-Configuration -InputObject $userConfig -Final
        if ($runPhase1 -eq $false -or $SkipValidation.IsPresent) {
            # Skip validation in phased run or when asked to skip
            $deployConfig = $testConfigResult.DeployConfig
            if (-not $testConfigResult.Valid) {
                Write-Host
                Write-Log "Configuration validation failed." -Failure
                Write-Host
                Write-ValidationMessages -TestObject $testConfigResult

                if ($runPhase1 -eq $false -and -not $SkipValidation.IsPresent) {         
                    Write-Host       
                    $response = Read-YesorNoWithTimeout -Prompt "Configuration failed to validate. Continue anyway? (Y/n)" -HideHelp -Default "y" -timeout 15
                    if (-not [String]::IsNullOrWhiteSpace($response)) {
                        if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {                           
                            write-host
                            Write-Log "Validation failed. If you want to continue bypassing the checks, run the following command" 
                            Write-Log "./New-Lab.ps1 -Configuration `"$Global:configfile`" -SkipValidation"
                            Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Global:configfile`" -SkipValidation"
                            write-host
                            exit 1
                        }
                    }
                }
                Write-ValidationMessages -TestObject $testConfigResult
                Write-OrangePoint "Configuration validation skipped."
            }
        }
        elseif ($testConfigResult.Valid) {
            $deployConfig = $testConfigResult.DeployConfig
            Write-GreenCheck "Configuration validated successfully." -ForeGroundColor SpringGreen
        }
        else {
            Write-Host
            Write-Log "Configuration validation failed." -Failure
            Write-Host
            Write-ValidationMessages -TestObject $testConfigResult
            write-host
            Write-Log "Validation failed. If you want to continue bypassing the checks, run the following command" 
            Write-Log "./New-Lab.ps1 -Configuration `"$Global:configfile`" -SkipValidation"
            Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Global:configfile`" -SkipValidation"
            write-host
            exit 1
        }
    }
    catch {
        Write-Log "Failed to load $Configuration.json file. Review vmbuild.log. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        Write-Host
        exit 1
    }
    #Create VM Mutexes
    $global:mutexes = @()
    foreach ($vm in $deployConfig.virtualMachines) {
        $mtx = New-Object System.Threading.Mutex($false, $vm.vmName)
        write-log -Verbose "Created Mutex $($vm.vmName)"
        if ($mtx.WaitOne(1000)) {
            $global:mutexes += $mtx
            write-log -Verbose "Acquired Mutex $($vm.vmName)"
        }
        else {
            Write-RedX "Could not acquire mutex for $(vm.vmName).  A deployment for this VM may already be in progress"
            exit 1
        }
        
    }
    # Skip if any VM in progress
    if ($runPhase1 -and (Test-InProgress -DeployConfig $deployConfig)) {
        Write-Host
        exit 1
    }

    # Timer
    $timer = New-Object -TypeName System.Diagnostics.Stopwatch
    $timer.Start()

    # Change log location
    $domainName = $deployConfig.vmOptions.domainName
    Write-Log "Starting deployment. Review VMBuild.$domainName.log"
    $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainName.log"

    #Rename the old log.
    try {
        Get-ChildItem $Common.LogPath -ErrorAction SilentlyContinue | Rename-Item -NewName { $_.BaseName + (Get-Date -Format "yyyyMMdd-HHmmss") + $_.Extension }
    }
    catch {
        Write-Log -verbose "Could not rename existing $($Common.LogPath)"
    }


    if ($Restore) {
        Write-Log "### RESTORE SNAPSHOT (Configuration '$Configuration') [MemLabs Version $($Common.MemLabsVersion)]" -Activity
        select-RestoreSnapshotDomain -domain $domainName -auto:$true
    }

    Write-Log "### START DEPLOYMENT (Configuration '$Configuration') [MemLabs Version $($Common.MemLabsVersion)]" -Activity

    if (-not $StartPhase -or ($StartPhase -and $StartPhase -le 2)) {
        # Download tools
        $success = Get-Tools -WhatIf:$WhatIf
        if (-not $success) {
            Write-Log "Failed to download tools to inject inside Virtual Machines." -Warning
        }
    }
 
    if ($runPhase1) {
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
                exit 1
            }
        }

        if ($DownloadFilesOnly.IsPresent) {
            $timer.Stop()
            Write-Host
            Write-Log "### SCRIPT FINISHED. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss"))" -Success
            Write-Host
            exit 0
        }
    }

    # Test if hyper-v switch exists, if not create it
    $AddedScopes = @($deployConfig.vmOptions.network)
    $worked = Add-SwitchAndDhcp -NetworkName $deployConfig.vmOptions.network -NetworkSubnet $deployConfig.vmOptions.network -DomainName $deployConfig.vmOptions.domainName -WhatIf:$WhatIf
    if (-not $worked) {
        exit 1
    }

    # Create additional switches
    foreach ($virtualMachine in $deployConfig.VirtualMachines) {
        if ($virtualMachine.network) {
            if ($AddedScopes -contains $virtualMachine.network) {
                continue
            }
            $AddedScopes += $virtualMachine.network
            $DC = get-list2 -deployConfig $deployConfig | where-object { $_.role -eq "DC" }
            $DNSServer = ($DC.Network.Substring(0, $DC.Network.LastIndexOf(".")) + ".1")
            $worked = Add-SwitchAndDhcp -NetworkName $virtualMachine.network -NetworkSubnet $virtualMachine.network -DomainName $deployConfig.vmOptions.domainName -DNSServer $DNSServer -WhatIf:$WhatIf
            if (-not $worked) {
                exit 1
            }
        }
    }

    # Internet Client VM Switch and DHCP Scope
    $containsIN = ($deployConfig.virtualMachines.role -contains "InternetClient") -or ($deployConfig.virtualMachines.role -contains "AADClient")
    $worked = Add-SwitchAndDhcp -NetworkName "Internet" -NetworkSubnet "172.31.250.0" -WhatIf:$WhatIf
    if ($containsIN -and (-not $worked)) {
        exit 1
    }

    # AO VM switch and DHCP scope
    $containsAO = ($deployConfig.virtualMachines.role -contains "SQLAO")
    if ($containsAO) {
        $worked = Add-SwitchAndDhcp -NetworkName "Cluster" -NetworkSubnet "10.250.250.0" -WhatIf:$WhatIf
        if (-not $worked) {
            exit 1
        }
    }

    #Make sure DHCP is still running
    get-service "DHCPServer" | Where-Object { $_.Status -eq 'Stopped' } | start-service
    $service = get-service "DHCPServer" | Where-Object { $_.Status -eq 'Stopped' }
    if ($service) {
        Write-Log "DHCPServer Service could not be started." -Failure
        exit 1
    }

    # Remove existing jobs
    $existingJobs = Get-Job
    if ($existingJobs) {
        Write-Log "Stopping and removing existing jobs." -Verbose -LogOnly
        foreach ($job in $existingJobs) {
            Write-Log "Removing job $($job.Id) with name $($job.Name)" -Verbose -LogOnly
            try {
                $job | Stop-Job -ErrorAction SilentlyContinue
                $job | Remove-Job -ErrorAction SilentlyContinue
            }
            catch {
                write-log "Failed to remove jobs $_"
                exit 1
            }
        }
    }

    # Show summary
    Write-Log "Deployment Summary" -Activity -HostOnly
    Show-Summary -deployConfig $deployConfig

    # Return if debug enabled
    if ($enableDebug) {
        return $deployConfig
    }

    # Prepare existing VM - Phase 0
    $prepared = $true
    $containsHidden = $deployConfig.virtualMachines | Where-Object { $_.hidden -eq $true }
    if ($containsHidden) {
        Write-Phase -Phase 0
        $prepared = Start-Phase -Phase 0 -deployConfig $deployConfig -WhatIf:$WhatIf
    }

    # Define phases
    $start = 1
    $maxPhase = 10
    if ($prepared) {

        for ($i = $start; $i -le $maxPhase; $i++) {
            Write-Phase -Phase $i

            if ($i -eq 1 -and -not $runPhase1) {
                Write-OrangePoint "[Phase $i] Not Applicable. Skipping." -ForegroundColor Yellow -WriteLog
                continue
            }

            if ($Phase -and $i -notin $Phase) {
                Write-OrangePoint "Skipped Phase $i because -Phase is $Phase." -ForegroundColor Yellow -WriteLog
                continue
            }

            if ($SkipPhase -and $i -in $SkipPhase) {
                Write-OrangePoint "Skipped Phase $i because -SkipPhase is $SkipPhase." -ForegroundColor Yellow -WriteLog
                continue
            }

            if ($StartPhase -and $i -lt $StartPhase) {
                Write-OrangePoint "Skipped Phase $i because -StartPhase is $StartPhase." -ForegroundColor Yellow -WriteLog
                continue
            }

            if ($StopPhase -and $i -gt $StopPhase) {
                Write-OrangePoint "Skipped Phase $i because -StopPhase is $StopPhase." -ForegroundColor Yellow -WriteLog
                continue
            }
            $lastPhase = $currentPhase
            $currentPhase = $i
            $configured = Start-Phase -Phase $i -deployConfig $deployConfig -WhatIf:$WhatIf
            if ($global:PhaseSkipped) {
                $currentPhase = $lastPhase
            }
            if (-not $configured) {
                break
            }
            else {
                if ($i -eq 1) {
                    # Clear out vm remove list
                    $global:vm_remove_list = @()

                    # Create RDCMan file
                    Start-Sleep -Seconds 5
                    New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false -NoActivity -WhatIf:$WhatIf
                    #Refresh deployConfig to add any props that may have been added in New-VirtualMachine, eg ClusterIPAddress
                    $deployConfig = ConvertTo-DeployConfigEx -DeployConfig $deployConfig
                }
            }
        }
    }

    $timer.Stop()

    if (-not $prepared -or -not $configured) {
        Write-Host
        Set-TitleBar "SCRIPT FINISHED WITH FAILURES"
        $NewLabsuccess = $false
        Write-Log "### SCRIPT FINISHED WITH FAILURES (Configuration '$Configuration'). Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss"))" -Failure -NoIndent
        if ($currentPhase -ge 2) {
            if ($currentPhase -eq 8) {
                write-host
                Write-Log "This failed on phase 8, please restore the phase 8 auto snapshot using the -restore option below before retrying." 
                Write-Log "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $currentPhase -restore"

                Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $currentPhase -restore"

            }
            else {
                Write-Host
                Write-Log "To Retry from the current phase, Reboot the VMs and run the following command from the current powershell window: " -Failure -NoIndent
                Write-Log "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $currentPhase"

                Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $currentPhase" 

            }


        }
        Write-Host
    }
    else {
        $currentPhase = 10
        foreach ($mutex in $global:mutexes) {
            try {
                [void]$mutex.ReleaseMutex()
            }
            catch {}
            try {
                [void]$mutex.Dispose()
            }
            catch {}

        }
        $global:mutexes = @()

        #This is now done in Phase 10
        # Start-Maintenance -DeployConfig $deployConfig

        $updateExistingRequired = $false
        foreach ($vm in $deployConfig.VirtualMachines | Where-Object { $_.ExistingVM }) {
            $updateExistingRequired = $true                    
        }

        # Update Existing VMs
        if ($updateExistingRequired) {
            Write-Log "Update Existing Virtual Machine Properties" -Activity -HostOnly
            foreach ($vm in $deployConfig.VirtualMachines | Where-Object { $_.ExistingVM }) {
                Write-Host "Updating VM Notes on $($vm.VmName)"
                foreach ($updatableEntry in $Global:Common.Supported.PropsToUpdate) {
                    if ($null -ne $vm."$updatableEntry") {
                        Write-Host "Updating $($vm.vmName) $updatableEntry to $($vm."$updatableEntry")"
                        Update-VMNoteProperty -vmName $vm.VmName -PropertyName $updatableEntry -PropertyValue $vm."$updatableEntry"
                    }
                }
            }
        }

        Write-Host
        Set-TitleBar "SCRIPT FINISHED"
        Write-Log "### SCRIPT FINISHED (Configuration '$Configuration'). Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss"))" -Activity
        $NewLabsuccess = $true
    }

}
catch {
    Write-Exception -ExceptionInfo $_ -AdditionalInfo ($deployConfig | ConvertTo-Json)
    $NewLabsuccess = $false
}
finally {

    foreach ($mutex in $global:mutexes) {
        try {
            [void]$mutex.ReleaseMutex()
        }
        catch {}
        try {
            [void]$mutex.Dispose()
        }
        catch {}

    }
    $global:mutexes = @()

    if ($enableDebug) {
        Write-Host 'Config Stored in $global:DebugConfig'
        $global:DebugConfig = $deployConfig
    }
    # Ctrl + C brings us here :)
    if ($NewLabsuccess -ne $true) {
        Write-Log "Script exited unsuccessfully. Ctrl-C may have been pressed. Killing running jobs." -LogOnly
        Set-TitleBar "Script Cancelled"
        Write-Log "### $Configuration Terminated $currentPhase" -HostOnly
        $exitcode = 2
        if ($currentPhase -ge 2 -and $currentPhase -le $maxPhase) {
            if ($currentPhase -eq 8) {
                write-host
                Write-Log "This failed on phase 8, please restore the phase 8 auto snapshot using the -restore option below before retrying." 
                Write-Log "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $currentPhase -restore"
                Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $currentPhase -restore"
            }
            else {
                write-host
                Write-Log "To Retry from the current phase, Reboot the VMs and run the following command from the current powershell window: " -Failure -NoIndent
                Write-Log "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $currentPhase"
                Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $currentPhase"
            }
        }
        Write-Host
    }
    Write-Host -NoNewline "Please Wait.. Stopping running jobs."

    foreach ($job in Get-Job) {
        if (-not $enableVerbose) {
            $job | Stop-Job
            Write-Host -NoNewline "."
        }
    }
    if (-not $global:Common.DevBranch) {
        foreach ($job in Get-Job) {
            if (-not $enableVerbose) {
                $job | Remove-Job
                Write-Host -NoNewline "."
            }
        }
    }
    Write-host "`r                                                                                                                              "
    # Close PS Sessions
    foreach ($session in $global:ps_cache.Keys) {
        Write-Log "Closing PS Session $session" -Verbose
        try { Remove-PSSession $global:ps_cache.$session -ErrorAction SilentlyContinue } catch {}
    }
    $global:ps_cache = @{}

    # Delete in progress or failed VM's
    if ($global:vm_remove_list.Count -gt 0) {
        if ($NewLabsuccess) {
            Write-Log "Phase 1 encountered failures. Removing all VM's created in Phase 1." -Warning
            $NewLabsuccess = $false
        }
        else {
            Write-Log "Script exited before Phase 1 completion. Removing all VM's created in Phase 1." -Warning
        }
        Write-Host

        foreach ($vmname in $global:vm_remove_list) {
            Remove-VirtualMachine -VmName $vmname -Migrate $Migrate -Force
        }

        # Get-Job | Stop-Job
    }

    # Clear vm remove list
    $global:vm_remove_list = @()

    # uninit common
    $Common.Initialized = $false

    # Set quick edit back
    Set-QuickEdit

    Write-Host
    if ($NewLabsuccess -ne $true) {
        if ($exitcode -ne 2) {
            Write-Host "Script exited (FAILED)."
            Set-TitleBar "SCRIPT FAILED"
        }
        if ($exitcode -gt 0) {
            exit $exitcode
        }
        else {
            exit 1
        }        
    }
    else {
        Write-Host "Script exited. SUCCESS"
        Set-TitleBar "SCRIPT FINISHED"
    }
    
}