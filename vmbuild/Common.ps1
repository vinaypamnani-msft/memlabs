
########################
### Common Functions ###
########################

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Text,
        [Parameter(Mandatory = $false)]
        [switch]$Warning,
        [Parameter(Mandatory = $false)]
        [switch]$Failure,
        [Parameter(Mandatory = $false)]
        [switch]$Success,
        [Parameter(Mandatory = $false)]
        [switch]$Activity,
        [Parameter(Mandatory = $false)]
        [switch]$VerboseOnly,
        [Parameter(Mandatory = $false)]
        [switch]$LogOnly,
        [Parameter(Mandatory = $false)]
        [switch]$OutputStream,
        [Parameter(Mandatory = $false)]
        [switch]$HostOnly
    )

    $HashArguments = @{}

    $info = $true

    If ($Success.IsPresent) {
        $info = $false
        $Text = "SUCCESS: $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Green)
    }

    If ($Activity.IsPresent) {
        $info = $false
        Write-Host
        $Text = "ACTIVITY: $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Magenta)
    }

    If ($Warning.IsPresent) {
        $info = $false
        $Text = "WARNING: $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Yellow)
    }

    If ($Failure.IsPresent) {
        $info = $false
        $Text = "ERROR: $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Red)
    }

    If ($VerboseOnly.IsPresent) {
        $info = $false
        $Text = "VERBOSE: $Text"
    }

    if ($info) {
        $Text = "INFO: $Text"
    }

    # Write to output stream
    if ($OutputStream.IsPresent) {
        Write-Output $Text
    }

    # Write progress if output stream and failure present
    if ($OutputStream.IsPresent -and $Failure.IsPresent) {
        Write-Progress -Activity $Text -Status "Failed :(" -Completed
    }

    # Write to console, if not logOnly and not OutputStream and not verbose
    If (-not $LogOnly.IsPresent -and -not $OutputStream.IsPresent -and -not $VerboseOnly.IsPresent) {
        Write-Host $Text @HashArguments
    }

    $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss:fff'
    $Text = "$time $Text"

    # Write to log, non verbose entries
    if (-not $HostOnly.IsPresent -and -not $VerboseOnly.IsPresent) {
        try {
            $Text | Out-File $Common.LogPath -Append
        }
        catch {
            # Retry
            $Text | Out-File $Common.LogPath -Append
        }
    }

    # Write verbose entries, if verbose logging enabled
    if ($VerboseOnly.IsPresent -and $Common.VerboseLog) {
        try {
            $Text | Out-File $Common.LogPath -Append
        }
        catch {
            # Retry
            $Text | Out-File $Common.LogPath -Append
        }
    }
}

function Get-File {
    param(
        [Parameter(Mandatory = $false)]
        $Source,
        [Parameter(Mandatory = $false)]
        $Destination,
        [Parameter(Mandatory = $false)]
        $DisplayName,
        [Parameter(Mandatory = $false)]
        [ValidateSet("Downloading", "Copying")]
        $Action,
        [Parameter(Mandatory = $false)]
        [switch]$Silent,
        [Parameter(Mandatory = $false, ParameterSetName = "WhatIf")]
        [switch]$WhatIf
    )

    # Display name for source
    $sourceDisplay = $Source

    # Add storage token, if source is like Storage URL
    if ($Source -and $Source -like "$($StorageConfig.StorageLocation)*") {
        $Source = "$Source`?$($StorageConfig.StorageToken)"
    }

    # What If
    if ($WhatIf -and -not $Silent) {
        Write-Log "Get-File - WhatIf: $Action $sourceDisplay file to $Destination"
        return
    }

    # Not making these mandatory to allow WhatIf to run with null values
    if (-not $Source -and -not $Destination) {
        Write-Log "Get-File: Source and Destination parameters must be specified." -Failure
        return
    }

    $HashArguments = @{
        Source      = $Source
        Destination = $Destination
    }

    if ($DisplayName) { $HashArguments.Add("DisplayName", $DisplayName) }
    if ($Action) { $HashArguments.Add("Description", "$Action using BITS") }

    if (-not $Silent) {
        Write-Log "Get-File: $Action $sourceDisplay using BITS to $Destination... "
        if ($DisplayName) { Write-Log "Get-File: $DisplayName" -LogOnly }
    }

    try {
        Start-BitsTransfer @HashArguments -Priority Foreground -ErrorAction Stop
    }
    catch {
        Write-Log "Get-File: $Action $sourceDisplay failed. Error: $($_.ToString().Trim())" -Failure
    }
}

function New-Directory {
    param(
        $DirectoryPath
    )

    if (-not (Test-Path -Path $DirectoryPath)) {
        New-Item -Path $DirectoryPath -ItemType Directory -Force | Out-Null
    }

    return $DirectoryPath
}

function Import-WimFromIso {

    param (
        [Parameter(Mandatory = $true)]
        [string]$IsoPath,
        [Parameter(Mandatory = $true)]
        [string]$WimName,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "Import-WimFromIso - WhatIf: Will get install.wim from $IsoPath as $WimName "
        return
    }

    #Mount ISO
    Write-Log "Import-WimFromIso: Mounting ISO..."
    try {
        $isomount = Mount-DiskImage -ImagePath $IsoPath -PassThru -NoDriveLetter -ErrorAction Stop
        $iso = $isomount.devicepath

    }
    catch {
        Write-Log "Import-WimFromIso: Could not mount the ISO!"
        return $null
    }

    # Get install.WIM
    if (Test-Path -Path (Join-Path $iso "sources\install.wim")) {
        $installWimFound = $true
    }
    else {
        Write-Log "Import-WimFromIso: Error accessing install.wim!" -Failure
        try {
            invoke-removeISOmount -inputObject $isomount
        }
        catch {
            Write-Log "Import-WimFromIso: Attempted to dismount iso - might have failed..." -Failure
        }
        return $null
    }

    # Copy out the WIM file from the selected ISO
    try {
        Write-Log "Import-WimFromIso: Purging temp folder at $($Common.TempPath)..."
        Remove-Item -Path "$($Common.TempPath)\$WimName" -Force -ErrorAction SilentlyContinue
        Write-Log "Import-WimFromIso: Purge complete."
        if ($installWimFound) {
            Write-Log "Import-WimFromIso: Copying WIM file to the temp folder..."
            Copy-Item -Path "$iso\sources\install.wim" -Destination $Common.TempPath -Force -ErrorAction Stop -PassThru | Out-Null
            #Change file attribute to normal
            Write-Log "Import-WimFromIso: Setting file attribute of install.wim to Normal"
            $attrib = Get-Item "$($Common.TempPath)\install.wim"
            $attrib.Attributes = 'Normal'
        }
    }
    catch {
        Write-Log "Import-WimFromIso: Couldn't copy from the source" -Failure
        invoke-removeISOmount -inputObject $isomount
        return $null
    }

    # Move the imported WIM to the wim folder
    try {
        Write-Log "Import-WimFromIso: Moving $WimName to wim folder..."
        Move-Item -Path "$($Common.TempPath)\install.wim" -Destination "$($Common.WimagePath)\$WimName" -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Import-WimFromIso: Couldn't move the new WIM to the staging folder." -Failure
        invoke-removeISOmount -inputObject $isomount
        return $null
    }

    Write-Log "Import-WimFromIso: WIM import complete." -Success
    return (Join-Path $Common.WimagePath $WimName)
}

function Invoke-RemoveISOmount ($inputObject) {
    Write-Log "Invoke-RemoveISOmount: Dismount started"
    do {
        Dismount-DiskImage -InputObject $inputObject
    }
    while (Dismount-DiskImage -InputObject $inputObject)
    Write-Log "Invoke-RemoveISOmount: Dismount complete"
}

function New-VhdxFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$WimName,
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "New-VhdxFile: WhatIf: Will convert WIM $WimName to VHDX $VhdxPath"
        return $true
    }

    $wimPath = Join-Path $Common.WimagePath $WimName

    try {
        Write-Log "New-VhdxFile: Obtaining image from $wimPath."
        $windowsImage = Get-WindowsImage -ImagePath $wimPath -ErrorVariable Failed | Select-Object ImageName, ImageIndex, ImageDescription

        if ($WimName -like "SERVER-*") {
            $selectedImage = $windowsImage | Where-Object { $_.ImageName -like "*DATACENTER*Desktop*" }
        }
        else {
            $selectedImage = $windowsImage | Out-GridView -Title "Select Image for creating a VHDX file." -OutputMode Single
        }
    }
    catch {
        Write-Log "New-VhdxFile: Failed to get windows image. $($Failed.Message)" -Failure
        return $false
    }

    if (-not $selectedImage) {
        Write-Log "New-VhdxFile: No image was selected. $($Failed.Message)" -Failure
        return $false
    }

    Write-Log "New-VhdxFile: Installing and importing WindowsImageTools module."
    Install-Module -Name WindowsImageTools
    Import-Module WindowsImageTools

    $unattendFile = $WimName -replace ".wim", ".xml"
    $unattendPath = Join-Path $Common.AnswerFilePath $unattendFile

    Write-Log "New-VhdxFile: Will inject $unattendPath"
    Write-Log "New-VhdxFile: Will inject directories inside $($Common.InjectPath)"
    Write-Log "New-VhdxFile: Will use ImageIndex $($selectedImage.ImageIndex) for $($selectedImage.ImageName)"

    if (-not (Test-Path $unattendPath)) {
        Write-Log "New-VhdxFile: $unattendFile not found." -Failure
        return $false
    }

    Write-Log "New-VhdxFile: Creating $vhdxPath"

    # Prepare filesToInject
    $filesToInject = @()
    $items = Get-ChildItem -Directory -Path $Common.InjectPath -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        $filesToInject += $item.FullName
    }

    # Convert WIM to VHDX
    # Probably better to add an option to use without unattend/filesToInject, but we alwasy need it so don't care ATM.
    try {
        Convert-Wim2VHD -Path $VhdxPath `
            -SourcePath $WimPath `
            -Index ($selectedImage.ImageIndex) `
            -Size 127GB `
            -DiskLayout UEFI `
            -Dynamic `
            -Unattend $unattendPath `
            -filesToInject $filesToInject `
            -Confirm:$False

        Write-Log "New-VhdxFile: Converted WIM to VHDX." -Success
        return $true

    }
    catch {
        Write-Log "New-VhdxFile: Failed to Convert WIM to VHDX. $($_)" -Failure
        return $false
    }
}

function New-VirtualMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$VmPath,
        [Parameter(Mandatory = $true)]
        [string]$SourceDiskPath,
        [Parameter(Mandatory = $true)]
        [string]$Memory,
        [Parameter(Mandatory = $true)]
        [int]$Processors,
        [Parameter(Mandatory = $true)]
        [int]$Generation,
        [Parameter(Mandatory = $true)]
        [string]$SwitchName,
        [Parameter(Mandatory = $false)]
        [switch]$ForceNew,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    # WhatIf
    if ($WhatIf) {
        Write-Log "New-VirtualMachine - WhatIf: Will create VM $VmName in $VmPath using VHDX $SourceDiskPath, Memory: $Memory, Processors: $Processors, Generation: $Generation, SwitchName: $SwitchName, ForceNew: $ForceNew"
        return $true
    }

    Write-Log "New-VirtualMachine: $VmName`: Creating Virtual Machine"

    # Create a Switch
    if (-not (Get-VMSwitch -Name $SwitchName  -ErrorAction SilentlyContinue)) {
        Write-Log "New-VirtualMachine: $VmName`: Creating Virtual Machine Switch $SwitchName"
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    }

    # VM Exists
    $vmTest = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vmTest -and $ForceNew.IsPresent) {
        Write-Log "New-VirtualMachine: $VmName`: Virtual machine already exists. ForceNew switch is present."
        if ($vmTest.State -ne "Off") {
            Write-Log "New-VirtualMachine: $VmName`: Turning the VM off forcefully..."
            $vmTest | Stop-VM -TurnOff -Force
        }
        $vmTest | Remove-VM -Force
        Write-Log "New-VirtualMachine: $VmName`: Purging $($vmTest.Path) folder..."
        Remove-Item -Path $($vmTest.Path) -Force -Recurse
        Write-Log "New-VirtualMachine: $VmName`: Purge complete."
    }

    if ($vmTest -and -not $ForceNew.IsPresent) {
        Write-Log "New-VirtualMachine: $VmName`: Virtual machine already exists. ForceNew switch is NOT present. Exit."
        return $false
    }

    # Make sure Existing VM Path is gone!
    $VmSubPath = Join-Path $VmPath $VmName
    if (Test-Path -Path $VmSubPath) {
        Write-Log "New-VirtualMachine: $VmName`: Found existing directory for $vmName. Purging $VmSubPath folder..."
        Remove-Item -Path $VmSubPath -Force -Recurse
        Write-Log "New-VirtualMachine: $VmName`: Purge complete."
    }

    # Create new VM
    try {
        $vm = New-VM -Name $vmName -Path $VmPath -Generation $Generation -MemoryStartupBytes ($Memory / 1) -SwitchName $SwitchName -ErrorAction Stop
    }
    catch {
        Write-Log "New-VirtualMachine: $VmName`: New-VM failed for $VmName. $_"
        return $false
    }

    # Copy sysprepped image to VM location
    $osDiskName = "$($VmName)_OS.vhdx"
    $osDiskPath = Join-Path $vm.Path $osDiskName
    Get-File -Source $SourceDiskPath -Destination $osDiskPath -DisplayName "$VmName`: Making a copy of base image in $osDiskPath" -Action "Copying"

    Write-Log "New-VirtualMachine: $VmName`: Setting Processor count for $VmName to $Processors"
    Set-VM -Name $vmName -ProcessorCount $Processors

    Write-Log "New-VirtualMachine: $VmName`: Adding virtual disk $osDiskPath to $VmName"
    Add-VMHardDiskDrive -VMName $VmName -Path $osDiskPath -ControllerType SCSI -ControllerNumber 0

    Write-Log "New-VirtualMachine: $VmName`: Adding a DVD drive to $VmName"
    Add-VMDvdDrive -VMName $VmName

    Write-Log "New-VirtualMachine: $VmName`: Changing boot order of $VmName"
    $f = Get-VM $VmName | Get-VMFirmware
    $f_file = $f.BootOrder | Where-Object { $_.BootType -eq "File" }
    $f_net = $f.BootOrder | Where-Object { $_.BootType -eq "Network" }
    $f_hd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive] }
    $f_dvd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive] }

    # 'File' firmware is not present on new VM, seems like it's created after Windows setup.
    if ($null -ne $f_file) {
        Set-VMFirmware -VMName $VmName -BootOrder $f_file, $f_dvd, $f_hd, $f_net
    }
    else {
        Set-VMFirmware -VMName $VmName -BootOrder $f_dvd, $f_hd, $f_net
    }

    Write-Log "New-VirtualMachine: $VmName`: Starting virtual machine"
    Start-VM -Name $VmName

    return $true
}

function Wait-ForVm {

    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true, ParameterSetName = "VmState")]
        [string]$VmState,
        [Parameter(Mandatory = $false, ParameterSetName = "OobeComplete")]
        [switch]$OobeComplete,
        [Parameter(Mandatory = $false, ParameterSetName = "VmTestPath")]
        [string]$PathToVerify,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 10,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "Wait-ForVm: WhatIf: Will wait for $VmName for $TimeoutMinutes minutes to become ready" -Warning
        return $true
    }

    $ready = $false

    $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
    $timeSpan = New-TimeSpan -Minutes $TimeoutMinutes
    $stopWatch.Start()

    if ($VmState) {
        Write-Log "Wait-ForVm: $VmName`: Waiting for VM to go in $VmState state..."
        do {
            try {
                $vmTest = Get-VM -Name $VmName
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "Waiting for VM to go in '$VmState' state. Current State: $($vmTest.State)" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                $ready = $vmTest.State -eq $VmState
                Start-Sleep -Seconds 5
            }
            catch {
                $ready = $false
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }

    if ($OobeComplete.IsPresent) {
        Write-Log "Wait-ForVm: $VmName`: Waiting for VM to complete OOBE..."
        $readyOobe = $false
        $readySmb = $false

        # SuppressLog for all Invoke-VmCommand calls here since we're in a loop.
        do {
            # Check OOBE complete registry key
            $out = Invoke-VmCommand -VmName $VmName -SuppressLog -ScriptBlock { Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ImageState }

            # Wait until OOBE is ready
            $status = "Waiting for OOBE to complete. "
            if ($null -ne $out.ScriptBlockOutput -and -not $readyOobe) {
                Write-Log "Wait-ForVm: $VmName`: OOBE State is $($out.ScriptBlockOutput)"
                $status += "Current State: $($out.ScriptBlockOutput)"
                $readyOobe = "IMAGE_STATE_COMPLETE" -eq $out.ScriptBlockOutput
            }

            Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status $status -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
            Start-Sleep -Seconds 5

            # Wait until \\localhost\c$ is accessible
            if ($readyOobe) {
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "OOBE complete. Waiting 15 seconds, before checking SMB access" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                Start-Sleep -Seconds 15
                $out = Invoke-VmCommand -VmName $VmName -SuppressLog -ScriptBlock { Test-Path -Path "\\localhost\c$" -ErrorAction SilentlyContinue }
                if ($null -ne $out.ScriptBlockOutput -and -not $readySmb) { Write-Log "Wait-ForVm: $VmName`: OOBE complete. \\localhost\c$ access result is $($out.ScriptBlockOutput)" }
                $readySmb = $true -eq $out.ScriptBlockOutput
            }

            # OOBE and SMB ready, buffer wait to ensure we're at login screen. Bad things happen if you reboot the machine before it really finished OOBE.
            if ($readySmb) {
                Write-Log "Wait-ForVm: $VmName`: OOBE complete, and SMB available. Waiting 30 seconds before continuing."
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "OOBE complete, and SMB available. Waiting 30 seconds before continuing" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                Start-Sleep -Seconds 30
                $ready = $true
            }

        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }

    if ($PathToVerify) {
        Write-Log "Wait-ForVm: $VmName`: Waiting for $PathToVerify to be present..."
        do {
            Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "Waiting for $PathToVerify to be present" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
            Start-Sleep -Seconds 5

            # Test if path exists; if present, VM is ready. SuppressLog since we're in a loop.
            $out = Invoke-VmCommand -VmName $VmName -ScriptBlock { Test-Path $using:PathToVerify } -SuppressLog
            $ready = $true -eq $out.ScriptBlockOutput

        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }

    Write-Progress -Activity "$VmName`: Waiting for virtual machine" -Status "Wait complete." -Completed

    if ($ready) {
        Write-Log "Wait-ForVm: $VmName`: VM is now available." -Success
    }

    if (-not $ready) {
        Write-Log "Wait-ForVm: $VmName`: Timer expired while waiting for VM" -Warning
    }

    return $ready
}

function Invoke-VmCommand {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $true, HelpMessage = "Script Block to execute")]
        [ScriptBlock]$ScriptBlock,
        [Parameter(Mandatory = $false, HelpMessage = "Argument List to supply to ScriptBlock")]
        [string[]]$ArgumentList,
        [Parameter(Mandatory = $false, HelpMessage = "Display Name of the script for log/console")]
        [string]$DisplayName,
        [Parameter(Mandatory = $false, HelpMessage = "Seconds to wait before running ScriptBlock")]
        [int]$SecondsToWaitBefore,
        [Parameter(Mandatory = $false, HelpMessage = "Seconds to wait after running ScriptBlock")]
        [int]$SecondsToWaitAfter,
        [Parameter(Mandatory = $false, HelpMessage = "Suppress log entries. Useful when waiting for VM to be ready to run commands.")]
        [switch]$SuppressLog,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName = "WORKGROUP",
        [Parameter(Mandatory = $false, HelpMessage = "What If")]
        [switch]$WhatIf
    )

    # Set display name for logging
    if (-not $DisplayName) {
        $DisplayName = $ScriptBlock
    }

    # WhatIf
    if ($WhatIf.IsPresent) {
        Write-Log "Invoke-VmCommand: WhatIf: Will run '$DisplayName' inside '$VmName'"
        return $true
    }

    # Fatal failure
    if ($null -eq $Common.LocalAdmin) {
        Write-Log "Invoke-VmCommand: $VmName`: Skip running '$DisplayName' since Local Admin creds not available" -Failure
        return $false
    }

    # Log entry
    if (-not $SuppressLog) {
        Write-Log "Invoke-VmCommand: $VmName`: Running '$DisplayName'" -VerboseOnly
    }

    # Create return object
    $return = [PSCustomObject]@{
        CommandResult     = $false
        ScriptBlockFailed = $false
        ScriptBlockOutput	= $null
    }

    # Prepare args
    $HashArguments = @{
        ScriptBlock = $ScriptBlock
    }

    if ($ArgumentList) {
        $HashArguments.Add("ArgumentList", $ArgumentList)
    }

    # Wait before
    if ($SecondsToWaitBefore) { Start-Sleep -Seconds $SecondsToWaitBefore }

    # Get VM Session
    $ps = Get-VmSession -VmName $VmName -DomainName $VmDomainName
    $failed = $null -eq $ps

    # Run script block inside VM
    if (-not $failed) {
        $return.ScriptBlockOutput = Invoke-Command -Session $ps @HashArguments -ErrorVariable Err2 -ErrorAction SilentlyContinue
        if ($Err2.Count -ne 0) {
            $failed = $true
            $return.ScriptBlockFailed = $true
            if (-not $SuppressLog) {
                Write-Log "Invoke-VmCommand: $VmName`: Failed to run '$DisplayName'. Error: $Err2" -Failure
            }
        }
    }

    # Set Command Result state in return object
    if (-not $failed) {
        $return.CommandResult = $true
        if (-not $SuppressLog) {
            Write-Log "Invoke-VmCommand: $VmName`: Successfully ran '$DisplayName'" -LogOnly -VerboseOnly
        }
    }

    # Wait after regardless of success/failure
    if ($SecondsToWaitAfter) { Start-Sleep -Seconds $SecondsToWaitAfter }

    return $return

}

$global:ps_cache = @{}
function Get-VmSession {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name for creating creds.")]
        [string]$DomainName = "WORKGROUP"
    )

    # Retrieve session from cache
    if ($global:ps_cache.ContainsKey($VmName)) {
        $ps = $global:ps_cache[$VmName]
        if ($ps.Availability -eq "Available") {
            # Write-Log "Get-VmSession: $VmName`: Returning session from cache." -LogOnly -VerboseOnly
            return $ps
        }
    }

    # Get PS Session
    $username = "$DomainName\$($Common.LocalAdmin.UserName)"

    $creds = New-Object System.Management.Automation.PSCredential ($username, $Common.LocalAdmin.Password)

    $ps = New-PSSession -Name $VmName -VMName $VmName -Credential $creds -ErrorVariable Err0 -ErrorAction SilentlyContinue
    if ($Err0.Count -ne 0) {
        Write-Log "Get-VmSession: $VmName`: Failed to establish a session using $username. Error: $Err0" -Warning -VerboseOnly
        return $null
    }

    # Cache & return session
    Write-Log "Get-VmSession: $VmName`: Created session with VM using $username." -Success -VerboseOnly
    $global:ps_cache[$VmName] = $ps
    return $ps
}


function Get-VmSession2 {
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "LocalCreds", HelpMessage = "VM Name")]
        [Parameter(Mandatory = $true, ParameterSetName = "DomainCreds", HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $true, ParameterSetName = "DomainCreds", HelpMessage = "Domain Name for creating creds.")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, ParameterSetName = "DomainCreds", HelpMessage = "If domain creds failed, return local creds.")]
        [switch]$FallbackLocal
    )

    $key = if ($DomainName) { "$VmName-Domain" } else { "$VmName-Local" }

    if ($global:ps_cache.ContainsKey($key)) {
        $ps = $global:ps_cache[$key]
        if ($ps.Availability -eq "Available") {
            Write-Log "Get-VmSession: $VmName`: Returning $key session from cache." -Warning
            return $ps
        }
    }

    # Domain
    if ($DomainName) {
        $username = "$DomainName\$($Common.LocalAdmin.UserName)"
        $domainCreds = New-Object System.Management.Automation.PSCredential ($username, $Common.LocalAdmin.Password)
        $ps_domain = New-PSSession -VMName $VmName -Credential $domainCreds -ErrorVariable Err0 -ErrorAction SilentlyContinue
        if ($Err0.Count -ne 0) {
            Write-Log "Get-VmSession: $VmName`: Failed to establish a session using domain creds. Error: $Err0" -Failure
            if (-not $FallbackLocal.IsPresent) {
                return $null
            }
            else {
                if ($global:ps_cache.ContainsKey($key.Replace("-Domain", "-Local"))) {
                    $ps = $global:ps_cache[$key]
                    if ($ps.Availability -eq "Available") {
                        Write-Log "Get-VmSession: $VmName`: Returning $key session from cache after falling back to local creds." -Warning
                        return $ps
                    }
                }
            }
        }
        else {
            $global:ps_cache["$VmName-Domain"] = $ps_domain
            return $ps_domain
        }
    }

    # Local
    $ps_local = New-PSSession -VMName $VmName -Credential $Common.LocalAdmin -ErrorVariable Err1 -ErrorAction SilentlyContinue
    if ($Err1.Count -ne 0) {
        Write-Log "Get-VmSession: $VmName`: Failed to establish a session using local creds. Error: $Err1" -Failure
        return $null
    }
    else {
        $global:ps_cache["$VmName-Local"] = $ps_local
        return $ps_local
    }
}

function Get-StorageConfig {

    $configPath = Join-Path $Common.ConfigPath "_storageConfig.json"

    if (Test-Path $configPath) {
        try {
            # Get storage config
            $config = Get-Content -Path $configPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $StorageConfig.StorageLocation = $config.storageLocation
            $StorageConfig.StorageToken = $config.storageToken

            # Get image list from storage location
            $updateList = $true
            $fileListPath = Join-Path $Common.AzureFilesPath "_fileList.json"
            $fileListLocation = "$($StorageConfig.StorageLocation)/_fileList.json"

            # See if image list needs to be updated
            if (Test-Path $fileListPath) {
                $Common.ImageList = Get-Content -Path $fileListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $updateList = $Common.ImageList.UpdateFromStorage
            }

            if ($updateList) {
                Get-File -Source $fileListLocation -Destination $fileListPath -DisplayName "Updating file list" -Action "Downloading" -Silent
                $Common.ImageList = Get-Content -Path $fileListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
        }
        catch {
            $Common.FatalError = "Get-StorageConfig: Storage Config found, but storage access failed. $_"
        }
    }
    else {
        $Common.FatalError = "Get-StorageConfig: Storage Config not found. Refer internal documentation."
    }
}

function Get-LocalAdmin {

    # Dont bother, if storage config had failure
    if ($Common.FatalError) {
        return
    }

    $username = "vmbuildadmin"
    $guid = (New-Guid).Guid
    $destination = Join-Path $Common.AzureFilesPath "$guid.txt"
    $fileExists = Test-Path $destination
    $updateFile = $Common.ImageList.UpdateFromStorage

    if (-not $fileExists -and -not $updateFile) {
        $Common.FatalError = "Get-LocalAdmin: $destination not found, and UpdateFromStorage is not allowed."
        return
    }

    if ($updateFile) {
        try {
            $item = $Common.ImageList.Files | Where-Object { $_.id -eq $username }
            $fileUrl = "$($StorageConfig.StorageLocation)/$($item.filename)"
            Get-File -Source $fileUrl -Destination $destination -DisplayName "Obtaining local admin creds" -Action "Downloading" -Silent
        }
        catch {
            $Common.FatalError = "Get-LocalAdmin: $_"
            return
        }
    }

    if (Test-Path $destination) {
        $content = Get-Content -Path $destination
        $s = ConvertTo-SecureString $content.Trim() -AsPlainText -Force
        $Common.LocalAdmin = New-Object System.Management.Automation.PSCredential ($username, $s)
        Remove-Item -Path $destination -Force -ErrorAction SilentlyContinue
    }
    else {
        $Common.FatalError = "Get-LocalAdmin: Storage Config found, but could not create local admin creds."
    }
}

function Test-Configuration {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Configuration File")]
        [string]$FilePath
    )

    $return = [PSCustomObject]@{
        Valid        = $false
        DeployConfig = $null
        Message      = $null
    }

    $configJson = Get-Content $FilePath -Force | ConvertFrom-Json

    $containsDC = $configJson.virtualMachines.role.Contains("DC")
    $containsCAS = $configJson.virtualMachines.role.Contains("CS")

    # config must contain DC role, or existingDCName
    if (-not $containsDC) {
        $existingDC = $configJson.vmOptions.existingDCName
        if (-not $existingDC) {
            $return.Message = "DC role not specified in the configuration file and vmOptions.existingDCName not present."
            return $return
        }
    }

    # tech preview and CAS
    if ($containsCAS -and $configJson.cmOptions.version -eq "tech-preview") {
        $return.Message = "Tech-Preview specified in configuration along with CAS Role; Tech Preview doesn't support CAS."
        return $return
    }

    # hierarchy
    if ($containsCAS) {
        $scenario = "Hierarchy"
    }
    else {
        $scenario = "Standalone"
    }

    # standalone primary


    # everything is good, create deployJson

    # add prefix to vm names
    $virtualMachines = $configJson.virtualMachines
    $virtualMachines | foreach-object {$_.vmName = $configJson.vmOptions.prefix + $_.vmName}

    # create params object
    $network = $configJson.vmOptions.network.Substring(0, $configJson.vmOptions.network.LastIndexOf("."))
    $clientsCsv = $virtualMachines.vmName -join ","
    $params = [PSCustomObject]@{
        DomainName         = $configJson.vmOptions.domainName
        DCName             = $configJson.vmOptions.prefix + ($configJson.virtualMachines | Where-Object { $_.role -eq "DC" }).vmName
        CSName             = $configJson.vmOptions.prefix + ($configJson.virtualMachines | Where-Object { $_.role -eq "CS" }).vmName
        PSName             = $configJson.vmOptions.prefix + ($configJson.virtualMachines | Where-Object { $_.role -eq "PS" }).vmName
        DPMPName           = $configJson.vmOptions.prefix + ($configJson.virtualMachines | Where-Object { $_.role -eq "DPMP" }).vmName
        DomainMembers      = $clientsCsv
        Scenario           = $scenario
        DHCPScopeId        = $configJson.vmOptions.Network
        DHCPDNSAddress     = $network + ".1"
        DHCPDefaultGateway = $network + ".200"
        DHCPScopeStart     = $network + ".20"
        DHCPScopeEnd       = $network + ".199"
        ThisMachineName    = $null
        ThisMachineRole    = $null
    }

    $deploy = [PSCustomObject]@{
        cmOptions       = $configJson.cmOptions
        vmOptions       = $configJson.vmOptions
        virtualMachines = $virtualMachines
        parameters      = $params
    }

    $return.Valid = $true
    $return.DeployConfig = $deploy

    return $return
}

############################
### Required Directories ###
############################

$staging = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "zStaging")                        # Path where staged files go
$inPath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "zInput")                          # Path where input files are found
$storagePath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "azureFiles")                 # Path for downloaded files

$global:Common = [PSCustomObject]@{
    TempPath       = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "zTemp")            # Path for temporary files
    ConfigPath     = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config")           # Path for Config files
    AzureFilesPath = $storagePath                                                              # Path for downloaded files
    GoldImagePath  = New-Directory -DirectoryPath (Join-Path $storagePath "os")                # Path to store sysprepped gold image after customization
    IsoPath        = New-Directory -DirectoryPath (Join-Path $storagePath "iso")               # Path for ISO's (typically for SQL)
    AnswerFilePath = New-Directory -DirectoryPath (Join-Path $inPath "unattend")               # Path for Answer files
    InjectPath     = New-Directory -DirectoryPath (Join-Path $inPath "filesToInject")          # Path to files to inject in VHDX
    WimagePath     = New-Directory -DirectoryPath (Join-Path $staging "wim")                   # Path for WIM file imported from ISO
    BaseImagePath  = New-Directory -DirectoryPath (Join-Path $staging "vhdx-base")             # Path to store base image, before customization
    StagingVMPath  = New-Directory -DirectoryPath (Join-Path $staging "vm")                    # Path for staging VM for customization
    LogPath        = Join-Path $PSScriptRoot "vmbuild.log"
    VerboseLog     = $false
    FatalError     = $null
    ImageList      = $null
    LocalAdmin     = $null
}

$global:StorageConfig = [PSCustomObject]@{
    StorageLocation = $null
    StorageToken    = $null
}

### Test Storage config and access
Get-StorageConfig

### Set Local Admin creds
Get-LocalAdmin
