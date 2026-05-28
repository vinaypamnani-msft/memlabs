# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
############################
### Base Image Functions ###
############################
#Common.BaseImage.ps1
function Get-ToolsForBaseImage {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Force redownloading and copying/extracting tools.")]
        [switch]$ForceTools
    )

    # Purge all items inside existing tools folder
    $toolsPath = Join-Path $Common.StagingInjectPath "tools"
    if ((Test-Path $toolsPath) -and $ForceTools.IsPresent) {
        Write-Log "ForceTools switch is present, and '$toolsPath' exists. Purging items inside the folder." -Warning
        Remove-Item -Path $toolsPath\* -Force -Recurse -WhatIf:$WhatIf -ProgressAction SilentlyContinue | Out-Null
    }

    foreach ($item in $Common.AzureFileList.Tools) {

        $name = $item.Name
        $url = $item.URL
        $fileTargetRelative = $item.Target
        $fileName = Split-Path $url -Leaf
        $downloadPath = Join-Path $Common.AzureToolsPath $fileName

        Write-Log "Obtaining '$name'" -SubActivity

        if (-not $item.IsPublic) {
            $url = "$($StorageConfig.StorageLocation)/$url"
        }

        $download = $true

        if (Test-Path $downloadPath) {
            Write-Log "Found $fileName in $($Common.TempPath)."
            if ($ForceTools.IsPresent) {
                Write-Log "ForceTools switch present. Removing pre-existing $fileName file..." -Warning -Verbose
                Remove-Item -Path $downloadPath -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue | Out-Null 
            }
            else {
                # Write-Log "ForceTools switch not present. Skip downloading/recopying '$fileName'." -Warning
                $download = $false
                continue
            }
        }

        if ($download) {
            $worked = Get-File -Source $url -Destination $downloadPath -DisplayName "Downloading '$name' to $downloadPath..." -Action "Downloading" -WhatIf:$WhatIf

            if (-not $worked) {
                Write-Log "Failed to download '$name' to $downloadPath"
                continue
            }

            # Create final destination directory, if not present
            $fileDestination = Join-Path $Common.StagingInjectPath $fileTargetRelative
            if (-not (Test-Path $fileDestination)) {
                New-Item -Path $fileDestination -ItemType Directory -Force | Out-Null
            }

            # File downloaded
            $extractIfZip = $item.ExtractFolderIfZip
            if (Test-Path $downloadPath) {
                if ($downloadPath.ToLowerInvariant().EndsWith(".zip") -and $extractIfZip -eq $true) {
                    Write-Log "Extracting $fileName to $fileDestination."
                    Expand-Archive -Path $downloadPath -DestinationPath $fileDestination -Force
                }
                else {
                    Write-Log "Copying $fileName to $fileDestination."
                    Copy-Item -Path $downloadPath -Destination $fileDestination -Force -Confirm:$false
                }
            }
        }
    }
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
        Write-Log "WhatIf: Will get install.wim from $IsoPath as $WimName "
        return
    }

    #Mount ISO
    Write-Log "Mounting ISO..."
    try {
        $isomount = Mount-DiskImage -ImagePath $IsoPath -PassThru -NoDriveLetter -ErrorAction Stop
        $iso = $isomount.devicepath
        write-Log "$IsoPath mounted as $($isomount.devicepath)"

    }
    catch {
        Write-Log "Could not mount the ISO!"
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }

    # Get install.WIM
    if (Test-Path -Path (Join-Path $iso "sources\install.wim")) {
        $installWimFound = $true
        Write-Log "Found $iso\sources\install.wim"
    }
    else {
        Write-Log "Error accessing install.wim!" -Failure
        try {
            invoke-removeISOmount -inputObject $isomount
        }
        catch {
            Write-Log "Attempted to dismount iso - might have failed..." -Failure
            Write-Log "$($_.ScriptStackTrace)" -LogOnly
        }
        return $null
    }

    # Copy out the WIM file from the selected ISO
    try {
        Write-Log "Purging temp folder at $($Common.TempPath)..."
        if (-not (Test-Path $($Common.TempPath))) {
            New-Item -Path $($Common.TempPath)-ItemType Directory -Force | Out-Null
        }
        if ((Test-Path "$($Common.TempPath)\$WimName")) {
            Remove-Item -Path "$($Common.TempPath)\$WimName" -Force -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue | Out-Null
        }
        Write-Log "Purge complete."
        if ($installWimFound) {
            Write-Log "Copying WIM file to the temp folder..."
            Copy-Item -Path "$iso\sources\install.wim" -Destination $Common.TempPath -Force -ErrorAction Stop -PassThru | Out-Null
            #Change file attribute to normal
            Write-Log "Setting file attribute of install.wim to Normal"
            $attrib = Get-Item "$($Common.TempPath)\install.wim"
            $attrib.Attributes = 'Normal'
        }
    }
    catch {
        Write-Log "Couldn't copy from the source" -Failure
        Write-Log "$($_.ScriptStackTrace)" -Failure
        invoke-removeISOmount -inputObject $isomount
        return $null
    }

    # Move the imported WIM to the wim folder
    try {
        Write-Log "Moving $WimName to $($Common.StagingWimPath) folder..."
        Move-Item -Path "$($Common.TempPath)\install.wim" -Destination "$($Common.StagingWimPath)\$WimName" -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Couldn't move the new WIM to the staging folder." -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        invoke-removeISOmount -inputObject $isomount
        return $null
    }

    Write-Log "WIM import complete." -Success
    return (Join-Path $Common.StagingWimPath $WimName)
}

function Invoke-RemoveISOmount ($inputObject) {
    Write-Log "Dismount started"
    do {
        Dismount-DiskImage -InputObject $inputObject
    }
    while (Dismount-DiskImage -InputObject $inputObject)
    Write-Log "Dismount complete"
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
        Write-Log "WhatIf: Will convert WIM $WimName to VHDX $VhdxPath"
        return $true
    }

    $wimPath = Join-Path $Common.StagingWimPath $WimName
    $unattendFile = $WimName -replace ".wim", ".xml"

    try {
        Write-Log "Obtaining image from $wimPath."
        $windowsImage = Get-WindowsImage -ImagePath $wimPath -ErrorVariable Failed | Select-Object ImageName, ImageIndex, ImageDescription

        if ($WimName -like "SERVER-*") {
            $selectedImage = $windowsImage | Where-Object { $_.ImageName -like "*DATACENTER*Desktop*" }
        }

        if ($WimName -like "WIN10-*") {
            $selectedImage = $windowsImage | Where-Object { $_.ImageName -eq "Windows 10 Enterprise" }
            if ($WimName -like "WIN10-*-64*.wim") {
                $unattendFile = "WIN10-64.xml"
            }
        }

        if ($WimName -like "WIN11-*") {
            $selectedImage = $windowsImage | Where-Object { $_.ImageName -eq "Windows 11 Enterprise" }
        }

        if (-not $selectedImage) {
            $selectedImage = $windowsImage | Out-GridView -Title "Select Image for creating a VHDX file." -OutputMode Single
        }
    }
    catch {
        Write-Log "Failed to get windows image. $($Failed.Message)" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $false
    }

    if (-not $selectedImage) {
        Write-Log "No image was selected. $($Failed.Message)" -Failure
        return $false
    }

    $unattendPath = Join-Path $Common.StagingAnswerFilePath $unattendFile
    $unattendPathToInject = Join-Path $Common.TempPath $unattendFile

    Write-Log "Will inject $unattendPath"
    Write-Log "Will inject directories inside $($Common.StagingInjectPath)"
    Write-Log "Will use ImageIndex $($selectedImage.ImageIndex) for $($selectedImage.ImageName)"

    if (-not (Test-Path $unattendPath)) {
        Write-Log "$unattendFile not found." -Failure
        return $false
    }

    Write-Log "Preparing answer file"
    $unattendContent = Get-Content $unattendPath -Force

    if ($unattendContent -match "%vmbuildpassword%" -and $unattendContent -match "%vmbuilduser%") {
        $vmbuilduser = $Common.LocalAdmin.UserName
        $vmbuildpass = Get-EncodedPassword -Text $Common.LocalAdmin.GetNetworkCredential().Password
        $adminpass = Get-EncodedPassword -Text $Common.LocalAdmin.GetNetworkCredential().Password -AdminPassword
        $unattendContent = $unattendContent.Replace("%vmbuilduser%", $vmbuilduser)
        $unattendContent = $unattendContent.Replace("%vmbuildpassword%", $vmbuildpass)
        $unattendContent = $unattendContent.Replace("%adminpassword%", $adminpass)
        $unattendContent | Out-File $unattendPathToInject -Force -Encoding utf8
        Write-Log "Saved updated unattend to $unattendPathToInject"
    }
    else {
        Write-Log "Answer file doesn't contain '%vmbuildpassword%' placeholder." -Failure
        return $false
    }

    if (-not (Test-Path $unattendPathToInject)) {
        Write-Log "Answer file preparation failed." -Failure
        return $false
    }

    Write-Log "Creating $vhdxPath (Estimated time 20 min)"

    # Prepare filesToInject
    $filesToInject = @()
    $items = Get-ChildItem -Directory -Path $Common.StagingInjectPath -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        $filesToInject += $item.FullName
    }

    # Create VHDX with native commands (explicit 512-byte sectors for BitLocker compatibility)
    try {
        # Create VHDX with 512n sector size to ensure BitLocker works in Hyper-V guests
        Write-Log "Creating VHDX with 512-byte sector sizes..."
        New-VHD -Path $VhdxPath -SizeBytes 127GB -Dynamic -LogicalSectorSizeBytes 512 -PhysicalSectorSizeBytes 512 | Out-Null

        # Mount and partition
        Write-Log "Mounting and partitioning VHDX (UEFI layout)..."
        $vhdMount = Mount-VHD -Path $VhdxPath -Passthru
        $diskNumber = $vhdMount.DiskNumber

        Initialize-Disk -Number $diskNumber -PartitionStyle GPT

        # Create UEFI partition layout: EFI System (260MB), MSR (128MB), Windows (remainder), Recovery (900MB)
        $efiPartition = New-Partition -DiskNumber $diskNumber -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        New-Partition -DiskNumber $diskNumber -Size 128MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
        $winPartition = New-Partition -DiskNumber $diskNumber -Size 125GB
        $recPartition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -GptType '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'

        # Format partitions
        Format-Volume -Partition $efiPartition -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Out-Null
        Format-Volume -Partition $winPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
        Format-Volume -Partition $recPartition -FileSystem NTFS -NewFileSystemLabel "Recovery" -Confirm:$false | Out-Null

        # Assign drive letters for image apply
        $efiPartition | Add-PartitionAccessPath -AssignDriveLetter
        $winPartition | Add-PartitionAccessPath -AssignDriveLetter
        $efiPartition = $efiPartition | Get-Partition
        $winPartition = $winPartition | Get-Partition
        $efiLetter = $efiPartition.DriveLetter
        $winLetter = $winPartition.DriveLetter

        # Apply Windows image
        Write-Log "Applying WIM image (Index $($selectedImage.ImageIndex)) to ${winLetter}:\..."
        Expand-WindowsImage -ImagePath $WimPath -Index $selectedImage.ImageIndex -ApplyPath "${winLetter}:\" | Out-Null

        # Configure BCD boot
        Write-Log "Configuring UEFI boot..."
        $bcdResult = & bcdboot "${winLetter}:\Windows" /s "${efiLetter}:" /f UEFI 2>&1
        Write-Log "bcdboot: $bcdResult"

        # Inject unattend file
        Write-Log "Injecting unattend file..."
        $panther = "${winLetter}:\Windows\Panther"
        if (-not (Test-Path $panther)) { New-Item -Path $panther -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $unattendPathToInject -Destination "$panther\unattend.xml" -Force

        # Inject files
        foreach ($injectDir in $filesToInject) {
            $destDir = "${winLetter}:\$($injectDir | Split-Path -Leaf)"
            Write-Log "Injecting directory: $($injectDir | Split-Path -Leaf)"
            Copy-Item -Path $injectDir -Destination $destDir -Recurse -Force
        }

        # Remove drive letters and dismount
        $efiPartition | Remove-PartitionAccessPath -AccessPath "${efiLetter}:\"
        $winPartition | Remove-PartitionAccessPath -AccessPath "${winLetter}:\"
        Dismount-VHD -Path $VhdxPath

        Write-Log "Created VHDX with native 512-byte sectors." -Success
        return $true
    }
    catch {
        Write-Log "Failed to create VHDX. $($_)" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        # Ensure cleanup on failure
        try { Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue } catch {}
        if (Test-Path $VhdxPath) { Remove-Item $VhdxPath -Force -ErrorAction SilentlyContinue }
        return $false
    }
    finally {
        if (Test-Path $unattendPathToInject) {
            Remove-Item -Path $unattendPathToInject -Force -ErrorAction SilentlyContinue 
        }
    }
}

function Get-EncodedPassword {
    param(
        [string]$Text,
        [switch]$AdminPassword
    )

    if ($AdminPassword.IsPresent) {
        $textToEncode = $Text + "AdministratorPassword"
    }
    else {
        $textToEncode = $Text + "Password"
    }
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($textToEncode)
    $encodedPassword = [Convert]::ToBase64String($bytes)
    return $encodedPassword
}