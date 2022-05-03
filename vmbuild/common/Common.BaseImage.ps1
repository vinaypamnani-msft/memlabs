############################
### Base Image Functions ###
############################

function Get-ToolsForBaseImage {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Force redownloading and copying/extracting tools.")]
        [switch]$ForceTools
    )

    # Purge all items inside existing tools folder
    $toolsPath = Join-Path $Common.StagingInjectPath "tools"
    if ((Test-Path $toolsPath) -and $ForceTools.IsPresent) {
        Write-Log "ForceTools switch is present, and '$toolsPath' exists. Purging items inside the folder." -Warning
        Remove-Item -Path $toolsPath\* -Force -Recurse -WhatIf:$WhatIf | Out-Null
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
                Remove-Item -Path $downloadPath -Force -WhatIf:$WhatIf | Out-Null
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

    }
    catch {
        Write-Log "Could not mount the ISO!"
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }

    # Get install.WIM
    if (Test-Path -Path (Join-Path $iso "sources\install.wim")) {
        $installWimFound = $true
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
        Remove-Item -Path "$($Common.TempPath)\$WimName" -Force -ErrorAction SilentlyContinue
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
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
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

    Write-Log "Installing and importing WindowsImageTools module."
    Install-Module -Name WindowsImageTools
    Import-Module WindowsImageTools

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
    }
    else {
        Write-Log "Answer file doesn't contain '%vmbuildpassword%' placeholder." -Failure
        return $false
    }

    if (-not (Test-Path $unattendPathToInject)) {
        Write-Log "Answer file preparation failed." -Failure
        return $false
    }

    Write-Log "Creating $vhdxPath"

    # Prepare filesToInject
    $filesToInject = @()
    $items = Get-ChildItem -Directory -Path $Common.StagingInjectPath -ErrorAction SilentlyContinue
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
            -Unattend $unattendPathToInject `
            -filesToInject $filesToInject `
            -Confirm:$False

        Write-Log "Converted WIM to VHDX." -Success
        return $true

    }
    catch {
        Write-Log "Failed to Convert WIM to VHDX. $($_)" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
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