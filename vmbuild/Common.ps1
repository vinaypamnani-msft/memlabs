
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
        [switch]$SubActivity,
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
        $Text = "=== $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Cyan)
    }

    If ($SubActivity.IsPresent) {
        $info = $false
        Write-Host
        $Text = "====== $Text"
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
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::White)
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
        $sourceDisplay = Split-Path $sourceDisplay -Leaf
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

    # Create destination directory if it doesn't exist
    $destinationDirectory = Split-Path $Destination -Parent
    if (-not (Test-Path $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
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

function Test-NetworkSwitch {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Network Subnet.")]
        [string]$Network,
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name.")]
        [string]$DomainName
    )

    $exists = Get-VMSwitch -SwitchType Internal | Where-Object { $_.Name -eq $Network }
    if (-not $exists) {
        Write-Log "Get-NetworkSwitch: HyperV Network switch for $Network not found. Creating a new one."
        New-VMSwitch -Name $Network -SwitchType Internal -Notes $DomainName | Out-Null
        Start-Sleep -Seconds 5 # Sleep to make sure network adapter is present
    }

    $exists = Get-VMSwitch -SwitchType Internal | Where-Object { $_.Name -eq $Network }
    if (-not $exists) {
        Write-Log "Get-NetworkSwitch: HyperV Network switch could not be created."
        return $false
    }

    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$Network*" }

    if (-not $adapter) {
        Write-Log "Get-NetworkSwitch: Network adapter for $Network was not found."
        return $false
    }

    $interfaceAlias = $adapter.InterfaceAlias
    $desiredIp = $Network.Substring(0, $Network.LastIndexOf(".")) + ".200"

    $currentIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $interfaceAlias -ErrorAction SilentlyContinue
    if ($currentIp.IPAddress -ne $desiredIp) {
        Write-Log "Get-NetworkSwitch: $interfaceAlias IP is $($currentIp.IPAddress). Changing it to $desiredIp."
        New-NetIPAddress -InterfaceAlias $interfaceAlias -IPAddress $desiredIp -PrefixLength 24 | Out-Null
        Start-Sleep -Seconds 5 # Sleep to make sure IP changed
    }

    $currentIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $interfaceAlias -ErrorAction SilentlyContinue
    if ($currentIp.IPAddress -ne $desiredIp) {
        Write-Log "Get-NetworkSwitch: Unable to set IP for '$interfaceAlias' network adapter to $desiredIp."
        return $false
    }

    $text = & netsh routing ip nat show interface
    if ($text -like "*$interfaceAlias*") {
        Write-Log "Get-NetworkSwitch: '$interfaceAlias' interface is already present in NAT." -Success
        return $true
    }
    else {
        Write-Log "Get-NetworkSwitch: '$interfaceAlias' not found in NAT. Restarting RemoteAccess service before adding it."
        Restart-Service RemoteAccess
        & netsh routing ip nat add interface "$interfaceAlias"
    }

    $text = & netsh routing ip nat show interface
    if ($text -like "*$interfaceAlias*") {
        Write-Log "Get-NetworkSwitch: '$interfaceAlias' interface added to NAT." -Success
        return $true
    }
    else {
        Write-Log "Get-NetworkSwitch: Unable to add '$interfaceAlias' to NAT."
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
        [object]$AdditionalDisks,
        [Parameter(Mandatory = $false)]
        [switch]$ForceNew,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    # WhatIf
    if ($WhatIf) {
        Write-Log "New-VirtualMachine - WhatIf: Will create VM $VmName in $VmPath using VHDX $SourceDiskPath, Memory: $Memory, Processors: $Processors, Generation: $Generation, AdditionalDisks: $AdditionalDisks, SwitchName: $SwitchName, ForceNew: $ForceNew"
        return $true
    }

    Write-Log "New-VirtualMachine: $VmName`: Creating Virtual Machine"

    # Test if source file exists
    if (-not (Test-Path $SourceDiskPath)) {
        Write-Log "New-VirtualMachine: $VmName`: $SourceDiskPath not found. Cannot create new VM."
        return $false
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
        Write-Log "New-VirtualMachine: $VmName`: Failed to create new VM. $_"
        return $false
    }

    # Copy sysprepped image to VM location
    $osDiskName = "$($VmName)_OS.vhdx"
    $osDiskPath = Join-Path $vm.Path $osDiskName
    Get-File -Source $SourceDiskPath -Destination $osDiskPath -DisplayName "$VmName`: Making a copy of base image in $osDiskPath" -Action "Copying"

    Write-Log "New-VirtualMachine: $VmName`: Setting Processor count to $Processors"
    Set-VM -Name $vmName -ProcessorCount $Processors

    Write-Log "New-VirtualMachine: $VmName`: Adding virtual disk $osDiskPath"
    Add-VMHardDiskDrive -VMName $VmName -Path $osDiskPath -ControllerType SCSI -ControllerNumber 0

    Write-Log "New-VirtualMachine: $VmName`: Adding a DVD drive"
    Add-VMDvdDrive -VMName $VmName

    Write-Log "New-VirtualMachine: $VmName`: Changing boot order"
    $f = Get-VM $VmName | Get-VMFirmware
    $f_file = $f.BootOrder | Where-Object { $_.BootType -eq "File" }
    $f_net = $f.BootOrder | Where-Object { $_.BootType -eq "Network" }
    $f_hd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive] }
    $f_dvd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive] }

    # Add additional disks
    if ($AdditionalDisks) {
        $count = 0
        $label = "DATA"
        foreach ($disk in $AdditionalDisks.psobject.properties) {
            $newDiskName = "$VmName`_$label`_$count.vhdx"
            $newDiskPath = Join-Path $vm.Path $newDiskName
            Write-Log "New-VirtualMachine: $VmName`: Adding $newDiskPath"
            New-VHD -Path $newDiskPath -SizeBytes ($disk.Value / 1) -Dynamic
            Add-VMHardDiskDrive -VMName $VmName -Path $newDiskPath
            $count++
        }
    }

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

function Get-StorageConfig {

    $configPath = Join-Path $Common.ConfigPath "_storageConfig.json"

    if (-not (Test-Path $configPath)) {
        $Common.FatalError = "Get-StorageConfig: Storage Config not found. Refer internal documentation."
    }

    try {

        # Disable Progress UI
        $ProgressPreference = 'SilentlyContinue'

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
            $Common.AzureFileList = Get-Content -Path $fileListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $updateList = $Common.AzureFileList.UpdateFromStorage
        }

        # Update file list
        if ($updateList) {

            # Get file list
            Get-File -Source $fileListLocation -Destination $fileListPath -DisplayName "Updating file list" -Action "Downloading" -Silent
            $Common.AzureFileList = Get-Content -Path $fileListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

        }

        # Get local admin password, regardless of whether we should update file list
        $username = "vmbuildadmin"
        $item = $Common.AzureFileList.OS | Where-Object { $_.id -eq $username }
        $fileUrl = "$($StorageConfig.StorageLocation)/$($item.filename)?$($StorageConfig.StorageToken)"
        $response = Invoke-WebRequest -Uri $fileUrl -ErrorAction Stop
        $s = ConvertTo-SecureString $response.Content.Trim() -AsPlainText -Force
        $Common.LocalAdmin = New-Object System.Management.Automation.PSCredential ($username, $s)

    }
    catch {
        $Common.FatalError = "Get-StorageConfig: Storage Config found, but storage access failed. $_"
    }
    finally {
        $ProgressPreference = 'Continue'
    }
}

function Get-FileFromStorage {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Storage File to download.")]
        [object]$File,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the file, if it exists.")]
        [switch]$ForceDownloadFiles,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $imageName = $File.id
    Write-Log "Get-FileFromStorage: Downloading/Verifying '$imageName'" -SubActivity

    foreach ($filename in $File.filename) {
        $imageUrl = "$($StorageConfig.StorageLocation)/$($filename)"
        $imageFileName = Split-Path $filename -Leaf
        $localImagePath = Join-Path $Common.AzureFilesPath $filename

        $download = $true

        if (Test-Path $localImagePath) {
            Write-Log "Get-FileFromStorage: Found $filename in $($Common.AzureFilesPath)."
            if ($ForceDownloadFiles.IsPresent) {
                Write-Log "Get-FileFromStorage: ForceDownloadFiles switch present. Removing pre-existing $imageFileName file..." -Warning
                Remove-Item -Path $localImagePath -Force -WhatIf:$WhatIf | Out-Null
            }
            else {
                Write-Log "Get-FileFromStorage: ForceDownloadFiles switch not present. Skip downloading '$imageFileName'." -LogOnly
                $download = $false
                continue
            }
        }

        if ($download) {
            # Write-Host "Get-FileFromStorage: Downloading '$imageName' to $localImagePath..."
            Get-File -Source $imageUrl -Destination $localImagePath -DisplayName "Downloading '$imageName' to $localImagePath..." -Action "Downloading" -WhatIf:$WhatIf
        }
    }
}

function Set-SupportedOptions {

    $roles = @(
        "DC",
        "PS",
        "CS",
        "DPMP",
        "DomainMember"
    )

    $rolesForExisting = @(
        "DPMP",
        "DomainMember"
    )

    $cmVersions = @(
        "current-branch",
        "tech-preview"
    )

    $operatingSystems = $Common.AzureFileList.OS.id | Where-Object { $_ -ne "vmbuildadmin" }

    $sqlVersions = $Common.AzureFileList.ISO.id | Select-Object -Unique

    $supported = [PSCustomObject]@{
        Roles            = $roles
        RolesForExisting = $rolesForExisting
        OperatingSystems = $operatingSystems
        SqlVersions      = $sqlVersions
        CMVersions       = $cmVersions
    }

    $Common.Supported = $supported

}

####################
### DOT SOURCING ###
####################
. $PSScriptRoot\common\Common.BaseImage.ps1
. $PSScriptRoot\common\Common.Config.ps1
. $PSScriptRoot\common\Common.RdcMan.ps1

############################
### Common Object        ###
############################

if (-not $Common.Initialized) {

    # Paths
    $staging = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "baseimagestaging")           # Path where staged files for base image creation go
    $storagePath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "azureFiles")             # Path for downloaded files

    # Common global props
    $global:Common = [PSCustomObject]@{
        Initialized           = $true
        TempPath              = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "temp")             # Path for temporary files
        ConfigPath            = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config")           # Path for Config files
        AzureFilesPath        = $storagePath                                                              # Path for downloaded files
        AzureImagePath        = New-Directory -DirectoryPath (Join-Path $storagePath "os")                # Path to store sysprepped gold image after customization
        AzureIsoPath          = New-Directory -DirectoryPath (Join-Path $storagePath "iso")               # Path for ISO's (typically for SQL)
        AzureToolsPath        = New-Directory -DirectoryPath (Join-Path $storagePath "tools")             # Path for downloading tools to inject in the VM
        StagingAnswerFilePath = New-Directory -DirectoryPath (Join-Path $staging "unattend")              # Path for Answer files
        StagingInjectPath     = New-Directory -DirectoryPath (Join-Path $staging "filesToInject")         # Path to files to inject in VHDX
        StagingWimPath        = New-Directory -DirectoryPath (Join-Path $staging "wim")                   # Path for WIM file imported from ISO
        StagingImagePath      = New-Directory -DirectoryPath (Join-Path $staging "vhdx-base")             # Path to store base image, before customization
        StagingVMPath         = New-Directory -DirectoryPath (Join-Path $staging "vm")                    # Path for staging VM for customization
        LogPath               = Join-Path $PSScriptRoot "vmbuild.log"                                     # Log File
        Supported             = $null                                                                     # Supported Configs
        AzureFileList         = $null
        LocalAdmin            = $null
        VerboseLog            = $false
        FatalError            = $null
    }

    # Storage config
    $global:StorageConfig = [PSCustomObject]@{
        StorageLocation = $null
        StorageToken    = $null
    }

    Write-Log "Common: Initializing common..." -LogOnly

    ### Test Storage config and access
    Get-StorageConfig

    ### Set supported options
    Set-SupportedOptions

}