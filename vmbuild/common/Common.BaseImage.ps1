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
            Write-Log "Get-ToolsForBaseImage: Found $fileName in $($Common.TempPath)."
            if ($ForceTools.IsPresent) {
                Write-Log "Get-ToolsForBaseImage: ForceTools switch present. Removing pre-existing $fileName file..." -Warning -Verbose
                Remove-Item -Path $downloadPath -Force -WhatIf:$WhatIf | Out-Null
            }
            else {
                # Write-Log "Get-ToolsForBaseImage: ForceTools switch not present. Skip downloading/recopying '$fileName'." -Warning
                $download = $false
                continue
            }
        }

        if ($download) {
            $worked = Get-File -Source $url -Destination $downloadPath -DisplayName "Downloading '$name' to $downloadPath..." -Action "Downloading" -WhatIf:$WhatIf

            if (-not $worked) {
                Write-Log "Get-ToolsForBaseImage: Failed to download '$name' to $downloadPath"
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
                if ($downloadPath.EndsWith(".zip") -and $extractIfZip -eq $true) {
                    Write-Log "Get-ToolsForBaseImage: Extracting $fileName to $fileDestination."
                    Expand-Archive -Path $downloadPath -DestinationPath $fileDestination -Force
                }
                else {
                    Write-Log "Get-ToolsForBaseImage: Copying $fileName to $fileDestination."
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
        Move-Item -Path "$($Common.TempPath)\install.wim" -Destination "$($Common.StagingWimPath)\$WimName" -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Import-WimFromIso: Couldn't move the new WIM to the staging folder." -Failure
        invoke-removeISOmount -inputObject $isomount
        return $null
    }

    Write-Log "Import-WimFromIso: WIM import complete." -Success
    return (Join-Path $Common.StagingWimPath $WimName)
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

    $wimPath = Join-Path $Common.StagingWimPath $WimName
    $unattendFile = $WimName -replace ".wim", ".xml"

    try {
        Write-Log "New-VhdxFile: Obtaining image from $wimPath."
        $windowsImage = Get-WindowsImage -ImagePath $wimPath -ErrorVariable Failed | Select-Object ImageName, ImageIndex, ImageDescription

        if ($WimName -like "SERVER-*") {
            $selectedImage = $windowsImage | Where-Object { $_.ImageName -like "*DATACENTER*Desktop*" }
        }

        if ($WimName -like "WIN10-*") {
            $selectedImage = $windowsImage | Where-Object { $_.ImageName -eq "Windows 10 Enterprise" }
            if ($WimName -like "WIN10-*-64.wim") {
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

    $unattendPath = Join-Path $Common.StagingAnswerFilePath $unattendFile
    $unattendPathToInject = Join-Path $Common.TempPath $unattendFile

    Write-Log "New-VhdxFile: Will inject $unattendPath"
    Write-Log "New-VhdxFile: Will inject directories inside $($Common.StagingInjectPath)"
    Write-Log "New-VhdxFile: Will use ImageIndex $($selectedImage.ImageIndex) for $($selectedImage.ImageName)"

    if (-not (Test-Path $unattendPath)) {
        Write-Log "New-VhdxFile: $unattendFile not found." -Failure
        return $false
    }

    Write-Log "New-VhdxFile: Preparing answer file"
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
        Write-Log "New-VhdxFile: Answer file doesn't contain '%vmbuildpassword%' placeholder." -Failure
        return $false
    }

    if (-not (Test-Path $unattendPathToInject)) {
        Write-Log "New-VhdxFile: Answer file preparation failed." -Failure
        return $false
    }

    Write-Log "New-VhdxFile: Creating $vhdxPath"

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

        Write-Log "New-VhdxFile: Converted WIM to VHDX." -Success
        return $true

    }
    catch {
        Write-Log "New-VhdxFile: Failed to Convert WIM to VHDX. $($_)" -Failure
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