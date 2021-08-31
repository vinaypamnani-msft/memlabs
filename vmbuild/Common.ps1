
########################
### Common Functions ###
########################

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Text,
        [Parameter(Mandatory=$false)]
        [switch]$Warning,
        [Parameter(Mandatory=$false)]
        [switch]$Failure,
        [Parameter(Mandatory=$false)]
        [switch]$Success,
        [Parameter(Mandatory=$false)]
        [switch]$Activity,
        [Parameter(Mandatory=$false)]
        [switch]$LogOnly
    )

    $time = Get-Date -Format 'HH:mm:ss'
    $Text = "$time $Text"

    If ($LogOnly.IsPresent) {                
        "LOG: $Text" | Out-File $Common.LogPath -Append
        return  
    }

    If ($Warning.IsPresent) {
        Write-Host $Text -ForegroundColor Yellow    
        "WARNING: $Text" | Out-File $Common.LogPath -Append
        return
    }

    If ($Failure.IsPresent) {
        Write-Host $Text -ForegroundColor Red
        "FAILURE: $Text" | Out-File $Common.LogPath -Append
        return  
    }

    If ($Success.IsPresent) {
        Write-Host $Text -ForegroundColor Green
        "SUCCESS: $Text" | Out-File $Common.LogPath -Append
        return  
    }

    If ($Activity.IsPresent) {
        Write-Host 
        Write-Host $Text -ForegroundColor Cyan
        "ACTIVITY: $Text" | Out-File $Common.LogPath -Append
        return  
    }

    Write-Host $Text -ForegroundColor White
    "INFO: $Text" | Out-File $Common.LogPath -Append
}

function Get-File {
    param(
        [Parameter(Mandatory=$false)]
        $Source,
        [Parameter(Mandatory=$false)]
        $Destination,
        [Parameter(Mandatory=$false)]
        $DisplayName,
        [Parameter(Mandatory=$false)]
        $Action,
        [Parameter(Mandatory=$false)]
        [switch]$Silent,
        [Parameter(Mandatory=$false, ParameterSetName="WhatIf")]
        [switch]$WhatIf
    )

    # Add storage token, if source is like Storage URL
    $sourceDisplay = $Source
    
    if ($Source -and $Source -like "$($StorageConfig.StorageLocation)*") {
        $Source = "$Source`?$($StorageConfig.StorageToken)"
    }

    if ($WhatIf -and -not $Silent) {
        Write-Log "Get-File - WhatIf: $Action $sourceDisplay file to $Destination"
        return
    }

    if (-not $Source -and -not $Destination) {
        # Not making these mandatory to allow WhatIf to run with null values
        Write-Log "Get-File: Source and Destination parameters must be specified." -Failure
        return
    }

    if (-not $Silent) {
        Write-Log "Get-File: $Action $sourceDisplay using BITS to $Destination... "
    }

    try {
        Start-BitsTransfer -Source $Source -Destination $Destination -DisplayName $DisplayName -Description "$Action using BITS" -Priority Foreground -ErrorAction Stop
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

function Import-WimFromIso{
    
    param (
        [Parameter(Mandatory=$true)]
        [string]$IsoPath,
        [Parameter(Mandatory=$true)]
        [string]$WimName,
        [Parameter(Mandatory=$false)]
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
        
    } catch {
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
        } catch {
            Write-Log "Import-WimFromIso: Attempted to dismount iso - might have failed..." -Failure
        }
        return $null
    }

    # Copy out the WIM file from the selected ISO
    try {
        Write-Log "Import-WimFromIso: Purging temp folder at $($Common.TempPath)..."
        Remove-Item -Path "$($Common.TempPath)\$WimName" -Force -ErrorAction SilentlyContinue
        Write-Log "Import-WimFromIso: Purge complete."
        if($installWimFound){
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
    do {
        Dismount-DiskImage -InputObject $inputObject
    }
    while(Dismount-DiskImage -InputObject $inputObject)    
    Write-Log "Dismount complete"
}

function New-VhdxFile {
    param (
        [Parameter(Mandatory=$true)]
        [string]$WimName,
        [Parameter(Mandatory=$true)]
        [string]$VhdxPath,
        [Parameter(Mandatory=$false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "New-VhdxFile - WhatIf: Will convert WIM $WimName to VHDX $VhdxPath"
        return $true
    }

    $wimPath = Join-Path $Common.WimagePath $WimName

    try {
        Write-Log "New-VhdxFile: Obtaining image from $wimPath."
        $windowsImage = Get-WindowsImage -ImagePath $wimPath -ErrorVariable Failed | Select-Object ImageName, ImageIndex, ImageDescription
        
        if ($WimName -like "SERVER-*") {
            $selectedImage = $windowsImage | Where-Object {$_.ImageName -like "*DATACENTER*Desktop*"}
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
    Write-Log "New-VhdxFile: Creating $vhdxPath"

    if (-not (Test-Path $unattendPath)) {
        Write-Log "New-VhdxFile: $unattendFile not found." -Failure
        return $false
    }

    # Prepare filesToInject
    $filesToInject = @()
    $items = Get-ChildItem -Directory -Path $Common.InjectPath -ErrorAction SilentlyContinue
    foreach($item in $items) {
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
        [Parameter(Mandatory=$true)]
        [string]$VmName,
        [Parameter(Mandatory=$true)]
        [string]$VmPath,
        [Parameter(Mandatory=$true)]
        [string]$SourceDiskPath,
        [Parameter(Mandatory=$true)]
        [string]$Memory,
        [Parameter(Mandatory=$true)]
        [int]$Processors,
        [Parameter(Mandatory=$true)]
        [int]$Generation,
        [Parameter(Mandatory=$true)]
        [string]$SwitchName,
        [Parameter(Mandatory=$false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "New-VirtualMachine - WhatIf: Will create VM $VmName in $VmPath using VHDX $SourceDiskPath, Memory: $Memory, Processors: $Processors, Generation: $Generation, SwitchName: $SwitchName"
        return $true
    }
    
    Write-Log "New-VirtualMachine: $VmName`: Creating Virtual Machine"

    # Create a Switch    
    if (-not (Get-VMSwitch -Name $SwitchName  -ErrorAction SilentlyContinue)) {
        Write-Log "New-VirtualMachine: $VmName`: Creating Virtual Machine Switch $SwitchName"
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    }

    $VmSubPath = Join-Path $VmPath $VmName
    if (Test-Path -Path $VmSubPath) {
        Write-Log "New-VirtualMachine: $VmName`: Found existing directory for $vmName. Purging $VmSubPath folder..."
        Remove-Item -Path $VmSubPath -Force -Recurse
        Write-Log "New-VirtualMachine: $VmName`: Purge complete."
    }

    try {
        $vm = New-VM -Name $vmName -Path $VmPath -Generation $Generation -MemoryStartupBytes ($Memory/1) -SwitchName $SwitchName -ErrorAction Stop
    }
    catch {
        Write-Log "New-VirtualMachine: $VmName`: New-VM failed for $VmName. $_"
        return $false
    }

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
    $f_file = $f.BootOrder | Where-Object{$_.BootType -eq "File" }
    $f_net = $f.BootOrder | Where-Object{$_.BootType -eq "Network" }
    $f_hd = $f.BootOrder | Where-Object{$_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive]}
    $f_dvd = $f.BootOrder | Where-Object{$_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive]}
    
    # File not present on new VM, seems like it's created after Windows setup.
    if ($null -ne $f_file) {
        Set-VMFirmware -VMName $VmName -BootOrder $f_file, $f_dvd, $f_hd, $f_net
    }
    else {
        Set-VMFirmware -VMName $VmName -BootOrder $f_dvd, $f_hd, $f_net
    }
    
    Write-Log "New-VirtualMachine: $VmName`: Starting VM"
    Start-VM -Name $VmName

    return $true
}

function Wait-ForVm {

    param (
        [Parameter(Mandatory=$true)]
        [string]$VmName,
        [Parameter(Mandatory=$true, ParameterSetName="VmState")]
        [string]$VmState,
        [Parameter(Mandatory=$false, ParameterSetName="OobeComplete")]
        [switch]$OobeComplete,
        [Parameter(Mandatory=$false, ParameterSetName="VmTestPath")]
        [string]$PathToVerify,
        [Parameter(Mandatory=$false)]
        [int]$TimeoutMinutes=10,
        [Parameter(Mandatory=$false)]
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
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "Waiting for VM to go in '$VmState' state" -PercentComplete ($stopWatch.ElapsedMilliseconds/$timespan.TotalMilliseconds * 100)
                Start-Sleep -Seconds 5
                $vmTest = Get-VM -Name $VmName
                $ready = $vmTest.State -eq $VmState
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
        do {            
            Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "Waiting for OOBE" -PercentComplete ($stopWatch.ElapsedMilliseconds/$timespan.TotalMilliseconds * 100)
            Start-Sleep -Seconds 5
            
            # Run a test command inside VM, if it works, VM is ready. SuppressLog since we're in a loop.
            $out = Invoke-VmCommand -VmName $VmName -ScriptBlock { Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue| Select-Object -ExpandProperty ImageState } -SuppressLog
            if ($null -ne  $out.ScriptBlockOutput -and -not $readyOobe) { Write-Log "Wait-ForVm: OOBE State is $($out.ScriptBlockOutput)" }
            $readyOobe = "IMAGE_STATE_COMPLETE" -eq $out.ScriptBlockOutput
            if ($readyOobe) {
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "OOBE complete. Waiting 15 seconds, before checking SMB access" -PercentComplete ($stopWatch.ElapsedMilliseconds/$timespan.TotalMilliseconds * 100)
                Start-Sleep -Seconds 15
                $out = Invoke-VmCommand -VmName $VmName -ScriptBlock { Test-Path -Path "\\localhost\c$" -ErrorAction SilentlyContinue } -SuppressLog
                if ($null -ne  $out.ScriptBlockOutput -and -not $readySmb) { Write-Log "Wait-ForVm: OOBE complete. \\localhost\c$ access result is $($out.ScriptBlockOutput)" }
                $readySmb = $true -eq $out.ScriptBlockOutput
            }
            if ($readySmb) {
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "OOBE complete, and SMB available. Waiting 30 seconds for login screen" -PercentComplete ($stopWatch.ElapsedMilliseconds/$timespan.TotalMilliseconds * 100)
                Start-Sleep -Seconds 30
                $ready = $true
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }

    if ($PathToVerify) {
        Write-Log "Wait-ForVm: $VmName`: Waiting for VM to have $PathToVerify..."
        do {            
            Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status "Waiting for $PathToVerify to be created" -PercentComplete ($stopWatch.ElapsedMilliseconds/$timespan.TotalMilliseconds * 100)
            Start-Sleep -Seconds 5
            
            # Test if path exists; if present, VM is ready. SuppressLog since we're in a loop.
            $out = Invoke-VmCommand -VmName $VmName -ScriptBlock { Test-Path $using:PathToVerify } -SuppressLog
            $ready = $true -eq $out.ScriptBlockOutput
            
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }    

    Write-Progress -Activity "$VmName`: Waiting for $VmName" -Status "Complete" -Completed

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
        [Parameter(Mandatory=$true, HelpMessage="VM Name")]
        [string]$VmName,
        [Parameter(Mandatory=$true, HelpMessage="Script Block to execute")] 
        [ScriptBlock]$ScriptBlock,
        [Parameter(Mandatory=$false, HelpMessage="Argument List to supply to ScriptBlock")] 
        [string[]]$ArgumentList,
        [Parameter(Mandatory=$false, HelpMessage="Seconds to wait before running ScriptBlock")]
        [int]$SecondsToWaitBefore,
        [Parameter(Mandatory=$false, HelpMessage="Seconds to wait after running ScriptBlock")]
        [int]$SecondsToWaitAfter,
        [Parameter(Mandatory=$false, HelpMessage="Suppress log entries. Useful when waiting for VM to be ready to run commands.")]
        [switch]$SuppressLog,
        [Parameter(Mandatory=$false, HelpMessage="What If")]
        [switch]$WhatIf
    )

    if ($WhatIf.IsPresent) {
        Write-Log "Invoke-VmCommand: WhatIf: Will run '$ScriptBlock' inside '$VmName'"
        return $true
    }

    Write-Log "Invoke-VmCommand: Starting command '$ScriptBlock' inside '$VmName'"

    $return = [PSCustomObject]@{
		CommandResult 	    = $false
		ScriptBlockOutput	= $null
	}

    $HashArguments = @{
        ScriptBlock = $ScriptBlock
    }

    if ($ArgumentList){
		$HashArguments.Add("ArgumentList", $ArgumentList)
	}
    
    # Wait before
    if ($SecondsToWaitBefore) { Start-Sleep -Seconds $SecondsToWaitBefore }

    $failed = $false
    $ps = New-PSSession -VMName $VmName -Credential $Common.LocalAdmin -ErrorVariable Err1 -ErrorAction SilentlyContinue
    
    if ($Err1.Count -ne 0) {
        $failed = $true
        if (-not $SuppressLog) {
            Write-Log "Invoke-VmCommand: Failed to establish a session with '$VmName'. Error: $Err1" -Failure
        }
    }
    
    if (-not $failed) {        
        $return.ScriptBlockOutput = Invoke-Command -Session $ps @HashArguments -ErrorVariable Err2 -ErrorAction SilentlyContinue
        
        if ($Err2.Count -ne 0) {
            $failed = $true
            if (-not $SuppressLog) {
                Write-Log "Invoke-VmCommand: Failed to invoke command '$ScriptBlock' inside '$VmName'. Error: $Err2" -Failure
            }
        }
    }

    if (-not $failed) { 
        $return.CommandResult = $true
        if (-not $SuppressLog) {
            Write-Log "Invoke-VmCommand: Ran command '$ScriptBlock' inside '$VmName'"
        }
    }

    # Wait after regardless of success/failure
    if ($SecondsToWaitAfter) { Start-Sleep -Seconds $SecondsToWaitAfter }

    return $return
    
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
            $imageListPath = Join-Path $Common.GoldImagePath "_imageList.json"
            $imageListLocation = "$($StorageConfig.StorageLocation)/images/_imageList.json"

            # See if image list needs to be updated
            if (Test-Path $imageListPath) {
                $Common.ImageList = Get-Content -Path $imageListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop                
                $updateList = $Common.ImageList.UpdateFromStorage
            }
            
            if($updateList) {
                Get-File -Source $imageListLocation -Destination $imageListPath -DisplayName "Updating image list" -Action "Downloading" -Silent
                $Common.ImageList = Get-Content -Path $imageListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
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
    $destination = Join-Path $Common.GoldImagePath "$username.txt"
    $fileExists = Test-Path $destination
    $updateFile = $Common.ImageList.UpdateFromStorage

    if (-not $fileExists -and -not $updateFile) {
        $Common.FatalError = "Get-LocalAdmin: $destination not found, and UpdateFromStorage is not allowed."
        return
    }

    if ($updateFile) {
        try {
            $item = $Common.ImageList.Files | Where-Object {$_.id -eq $username}
            $fileUrl = "$($StorageConfig.StorageLocation)/$($item.container)/$($item.filename)"
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

############################
### Required Directories ###
############################

$staging = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "zStaging")                        # Path where staged files go
$inPath  = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "zInput")                          # Path where input files are found

$global:Common = [PSCustomObject]@{	
	TempPath		    = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "zTemp")            # Path for temporary staging
    ConfigPath		    = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config")           # Path for Config files    
    GoldImagePath       = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "vhdx-gold")        # Path to store sysprepped gold image after customization    
    AnswerFilePath      = New-Directory -DirectoryPath (Join-Path $inPath "unattend")               # Path for Answer files
    InjectPath          = New-Directory -DirectoryPath (Join-Path $inPath "filesToInject")          # Path to files to inject in VHDX    
    WimagePath          = New-Directory -DirectoryPath (Join-Path $staging "wim")                   # Path for WIM file imported from ISO
    BaseImagePath       = New-Directory -DirectoryPath (Join-Path $staging "vhdx-base")             # Path to store base image, before customization
    StagingVMPath       = New-Directory -DirectoryPath (Join-Path $staging "vm")                    # Path for staging VM for customization
    LogPath             = Join-Path $PSScriptRoot "vmbuild.log"
    FatalError          = $null
    ImageList           = $null
    LocalAdmin          = $null
    DomainAdmin         = $null    
}

$global:StorageConfig = [PSCustomObject]@{
    StorageLocation = $null
    StorageToken    = $null
}

### Test Storage config and access
Get-StorageConfig

### Set Local Admin creds
Get-LocalAdmin
