# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
############################
### Base Image Functions ###
############################
#Common.BaseImage.ps1
function Get-ToolsForBaseImage {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Force redownloading and copying/extracting tools.")]
        [switch]$ForceTools,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $allSucceeded = $true
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
                $download = $false
            }
        }

        if ($download) {
            $worked = Get-File -Source $url -Destination $downloadPath -DisplayName "Downloading '$name' to $downloadPath..." -Action "Downloading" -WhatIf:$WhatIf

            if (-not $worked) {
                Write-Log "Failed to download '$name' to $downloadPath" -Failure
                $allSucceeded = $false
                continue
            }
        }

        if ($WhatIf) {
            Write-Log "WhatIf: Will stage '$name' from '$downloadPath'."
            continue
        }

        if (-not (Test-Path $downloadPath -PathType Leaf)) {
            Write-Log "Tool source '$downloadPath' is unavailable after download." -Failure
            $allSucceeded = $false
            continue
        }

        $fileDestination = Join-Path $Common.StagingInjectPath $fileTargetRelative
        if (-not (Test-Path $fileDestination)) {
            New-Item -Path $fileDestination -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        try {
            $extractIfZip = $item.ExtractFolderIfZip
            if ($downloadPath.ToLowerInvariant().EndsWith(".zip") -and $extractIfZip -eq $true) {
                Write-Log "Extracting $fileName to $fileDestination."
                Expand-Archive -Path $downloadPath -DestinationPath $fileDestination -Force -ErrorAction Stop
            }
            else {
                Write-Log "Copying $fileName to $fileDestination."
                Copy-Item -Path $downloadPath -Destination $fileDestination -Force -Confirm:$false -ErrorAction Stop
            }
        }
        catch {
            Write-Log "Failed to stage '$name' in '$fileDestination': $($_.Exception.Message)" -Failure
            $allSucceeded = $false
        }
    }

    return $allSucceeded
}

function Get-BaseImageIsoFromStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        [Parameter(Mandatory = $false)]
        [string]$ExpectedHash = "NONE",
        [Parameter(Mandatory = $false)]
        [ValidateSet("MD5", "SHA256")]
        [string]$HashAlgorithm = "MD5",
        [Parameter(Mandatory = $false)]
        [switch]$ForceDownload,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $normalizedFileName = $FileName.Trim().Replace("/", "\")
    if ([string]::IsNullOrWhiteSpace($normalizedFileName) -or
        [IO.Path]::IsPathRooted($normalizedFileName) -or
        ($normalizedFileName -split '\\') -contains "..") {
        throw "ISO file name must be a relative path inside the MemLabs Azure file store."
    }
    if ([IO.Path]::GetExtension($normalizedFileName) -ine ".iso") {
        throw "ISO file name '$normalizedFileName' must end in .iso."
    }

    $localIsoPath = Join-Path $Common.AzureFilesPath $normalizedFileName
    $hashMarkerPath = "$localIsoPath.$HashAlgorithm"

    if ($WhatIf) {
        Write-Log "WhatIf: Will obtain Azure ISO '$normalizedFileName' as '$localIsoPath'."
        return $localIsoPath
    }

    if ([string]::IsNullOrWhiteSpace($StorageConfig.StorageLocation)) {
        throw "Azure storage is unavailable; StorageConfig.StorageLocation is empty."
    }

    $effectiveExpectedHash = $ExpectedHash.Trim()
    if ([string]::IsNullOrWhiteSpace($effectiveExpectedHash)) {
        $effectiveExpectedHash = "NONE"
    }

    if ($effectiveExpectedHash -eq "NONE" -and -not $ForceDownload -and (Test-Path $hashMarkerPath -PathType Leaf)) {
        $cachedHash = "$(Get-Content -LiteralPath $hashMarkerPath -ErrorAction Stop | Select-Object -First 1)".Trim()
        if ($cachedHash) {
            $effectiveExpectedHash = $cachedHash
            Write-Log "Using cached $HashAlgorithm for '$normalizedFileName'." -LogOnly
        }
    }

    if ($effectiveExpectedHash -eq "NONE" -and $ForceDownload -and (Test-Path $localIsoPath -PathType Leaf)) {
        if (Get-Command Dismount-IsoFromAllVMs -ErrorAction SilentlyContinue) {
            $null = Dismount-IsoFromAllVMs -IsoPath $localIsoPath
        }
        Remove-Item -LiteralPath $localIsoPath -Force -ErrorAction Stop
        Remove-Item -LiteralPath $hashMarkerPath -Force -ErrorAction SilentlyContinue
    }

    $urlRelativePath = $normalizedFileName.Replace("\", "/")
    $fileUrl = "$($StorageConfig.StorageLocation.TrimEnd('/'))/$urlRelativePath"
    $downloadResult = Get-FileWithHash -FileName $normalizedFileName -FileDisplayName ([IO.Path]::GetFileName($normalizedFileName)) -FileUrl $fileUrl -ExpectedHash $effectiveExpectedHash -HashAlg $HashAlgorithm -ForceDownload:$ForceDownload -UseCDN:$UseCDN
    if (-not $downloadResult.success) {
        throw "Failed to download or verify Azure ISO '$normalizedFileName'."
    }
    if (-not (Test-Path $localIsoPath -PathType Leaf)) {
        throw "Azure ISO download reported success, but '$localIsoPath' does not exist."
    }

    if ($effectiveExpectedHash -eq "NONE") {
        Write-Log "The Azure blob has no independent expected hash. Calculating $HashAlgorithm after download..." -Warning
        $calculatedHash = (Get-FileHash -LiteralPath $localIsoPath -Algorithm $HashAlgorithm -ErrorAction Stop).Hash
        Set-Content -LiteralPath $hashMarkerPath -Value $calculatedHash -Encoding ASCII -Force
        Write-Log "Cached $HashAlgorithm for '$normalizedFileName': $calculatedHash" -Success
    }

    return $localIsoPath
}

function Resolve-BaseImageUnattendFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WimName,
        [Parameter(Mandatory = $false)]
        [string]$UnattendFileName
    )

    $candidates = New-Object Collections.Generic.List[string]
    if ($UnattendFileName) {
        $candidates.Add($UnattendFileName)
    }
    else {
        $candidates.Add(([IO.Path]::GetFileNameWithoutExtension($WimName) + ".xml"))
        if ($WimName -like "WIN10-*") {
            $candidates.Add("WIN10-64.xml")
        }
        elseif ($WimName -like "WIN11-*") {
            $candidates.Add("WIN11-RTM.xml")
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $candidatePath = Join-Path $Common.StagingAnswerFilePath $candidate
        if (Test-Path $candidatePath -PathType Leaf) {
            return $candidatePath
        }
    }

    throw "No unattend file was found for '$WimName'. Tried: $($candidates -join ', ')."
}

function Import-WimFromIso {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$IsoPath,
        [Parameter(Mandatory = $true)]
        [string]$WimName,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $destinationPath = Join-Path $Common.StagingWimPath $WimName
    if ($WhatIf) {
        Write-Log "WhatIf: Will import install.wim from '$IsoPath' as '$destinationPath'."
        return $destinationPath
    }

    $resolvedIsoPath = $null
    $isoMount = $null
    $mountedByThisCall = $false
    $partialPath = "$destinationPath.partial.$PID"
    $resultPath = $null

    try {
        $resolvedIsoPath = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
        $isoMount = Get-DiskImage -ImagePath $resolvedIsoPath -ErrorAction Stop
        if (-not $isoMount.Attached) {
            Write-Log "Mounting ISO '$resolvedIsoPath'..."
            $isoMount = Mount-DiskImage -ImagePath $resolvedIsoPath -PassThru -ErrorAction Stop
            $mountedByThisCall = $true
        }
        else {
            Write-Log "ISO '$resolvedIsoPath' is already mounted; reusing the existing mount."
        }

        $installWimPath = $null
        foreach ($volume in @($isoMount | Get-Volume -ErrorAction Stop)) {
            if (-not $volume.DriveLetter) { continue }
            $candidate = Join-Path "$($volume.DriveLetter):\" "sources\install.wim"
            if (Test-Path $candidate -PathType Leaf) {
                $installWimPath = $candidate
                break
            }
        }

        if (-not $installWimPath) {
            throw "The mounted ISO does not contain sources\install.wim on an accessible volume."
        }

        if (-not (Test-Path $Common.StagingWimPath -PathType Container)) {
            New-Item -Path $Common.StagingWimPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue

        Write-Log "Copying '$installWimPath' to '$partialPath'..."
        Copy-Item -LiteralPath $installWimPath -Destination $partialPath -Force -ErrorAction Stop
        (Get-Item -LiteralPath $partialPath -ErrorAction Stop).Attributes = "Normal"

        $sourceLength = (Get-Item -LiteralPath $installWimPath -ErrorAction Stop).Length
        $destinationLength = (Get-Item -LiteralPath $partialPath -ErrorAction Stop).Length
        if ($sourceLength -ne $destinationLength) {
            throw "Copied WIM size mismatch. Source=$sourceLength bytes, destination=$destinationLength bytes."
        }

        Move-Item -LiteralPath $partialPath -Destination $destinationPath -Force -ErrorAction Stop
        $resultPath = $destinationPath
        Write-Log "WIM import complete: '$destinationPath'." -Success
    }
    catch {
        Write-Log "Failed to import WIM from '$IsoPath': $($_.Exception.Message)" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
    }
    finally {
        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
        if ($mountedByThisCall -and $isoMount) {
            try {
                Invoke-RemoveISOMount -InputObject $isoMount -ErrorAction Stop
            }
            catch {
                Write-Log "Failed to dismount ISO '$resolvedIsoPath': $($_.Exception.Message)" -Warning
            }
        }
    }

    return $resultPath
}

function Invoke-RemoveISOMount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $imagePath = $InputObject.ImagePath
    $currentMount = if ($imagePath) {
        Get-DiskImage -ImagePath $imagePath -ErrorAction Stop
    }
    else {
        $InputObject
    }

    if ($currentMount.Attached) {
        Write-Log "Dismounting ISO '$($currentMount.ImagePath)'..."
        Dismount-DiskImage -InputObject $currentMount -ErrorAction Stop | Out-Null
    }
}

function Test-BaseImageSysprepComplete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        return [pscustomobject]@{
            Success = $true
            Message = "WhatIf: Will verify offline Sysprep completion in '$VhdxPath'."
            Warnings = @()
        }
    }

    $result = [pscustomobject]@{
        Success = $false
        Message = ""
        Warnings = @()
    }
    $diskImage = $null
    $assignedPartition = $null
    $assignedAccessPath = $null

    try {
        if (-not (Test-Path $VhdxPath -PathType Leaf)) {
            throw "VHDX '$VhdxPath' does not exist."
        }
        if ((Get-VHD -Path $VhdxPath -ErrorAction Stop).Attached) {
            throw "VHDX '$VhdxPath' is already attached."
        }

        $diskImage = Mount-DiskImage -ImagePath $VhdxPath -Access ReadOnly -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        $disk = $diskImage | Get-Disk -ErrorAction Stop
        $partitions = @($disk | Get-Partition -ErrorAction Stop | Sort-Object Size -Descending)
        $windowsRoot = $null

        foreach ($partition in $partitions) {
            if ($partition.Size -lt 10GB) { continue }

            $candidatePartition = $partition
            if (-not $candidatePartition.DriveLetter) {
                $candidatePartition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop | Out-Null
                $assignedPartition = $candidatePartition
                $candidatePartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $candidatePartition.PartitionNumber -ErrorAction Stop
                $assignedAccessPath = "$($candidatePartition.DriveLetter):\"
            }

            $candidateRoot = "$($candidatePartition.DriveLetter):\"
            if (Test-Path -LiteralPath (Join-Path $candidateRoot "Windows\System32\Sysprep") -PathType Container) {
                $windowsRoot = $candidateRoot
                break
            }

            if ($assignedPartition -and $assignedAccessPath) {
                $assignedPartition | Remove-PartitionAccessPath -AccessPath $assignedAccessPath -ErrorAction Stop | Out-Null
                $assignedPartition = $null
                $assignedAccessPath = $null
            }
        }

        if (-not $windowsRoot) {
            throw "No Windows partition was found in '$VhdxPath'."
        }

        $successTagPath = Join-Path $windowsRoot "Windows\System32\Sysprep\Sysprep_succeeded.tag"
        if (-not (Test-Path -LiteralPath $successTagPath -PathType Leaf)) {
            throw "Sysprep success tag is missing: '$successTagPath'."
        }
        $completionMarkerPath = Join-Path $windowsRoot "staging\SysprepComplete.txt"
        if (-not (Test-Path -LiteralPath $completionMarkerPath -PathType Leaf)) {
            throw "MemLabs Sysprep completion marker is missing: '$completionMarkerPath'."
        }
        $failureMarkerPath = Join-Path $windowsRoot "staging\SysprepFailed.txt"
        if (Test-Path -LiteralPath $failureMarkerPath -PathType Leaf) {
            $failureMarker = "$(Get-Content -LiteralPath $failureMarkerPath -Raw -ErrorAction SilentlyContinue)".Trim()
            throw "MemLabs Sysprep failure marker exists: $failureMarker"
        }

        $setupActPath = Join-Path $windowsRoot "Windows\System32\Sysprep\Panther\setupact.log"
        if (-not (Test-Path -LiteralPath $setupActPath -PathType Leaf)) {
            throw "Sysprep setup log is missing: '$setupActPath'."
        }

        $setupAct = @(Get-Content -LiteralPath $setupActPath -ErrorAction Stop)
        $lastRunStart = -1
        for ($i = 0; $i -lt $setupAct.Count; $i++) {
            if ($setupAct[$i] -match "Beginning of a new sysprep run") {
                $lastRunStart = $i
            }
        }
        if ($lastRunStart -lt 0) {
            throw "Sysprep setup log contains no run boundary."
        }

        $lastRun = @($setupAct[$lastRunStart..($setupAct.Count - 1)])
        $requiredPatterns = [ordered]@{
            GENERALIZE = "ParseCommands:Found supported command line option 'GENERALIZE'"
            OOBE       = "ParseCommands:Found supported command line option 'OOBE'"
            QUIT       = "ParseCommands:Found supported command line option 'QUIT'"
            SuccessTag = "FCreateTagFile:Successfully created tag file"
        }
        $missingEvidence = @()
        foreach ($evidenceName in $requiredPatterns.Keys) {
            if (-not ($lastRun -match [regex]::Escape($requiredPatterns[$evidenceName]))) {
                $missingEvidence += $evidenceName
            }
        }
        if ($missingEvidence.Count -gt 0) {
            throw "Final Sysprep run is missing evidence: $($missingEvidence -join ', ')."
        }

        $terminalErrors = @($lastRun | Where-Object { $_ -match '^\S+\s+\S+,\s+Error\s+' })
        if ($terminalErrors.Count -gt 0) {
            $result.Warnings = @($terminalErrors)
        }

        $result.Success = $true
        $result.Message = "Offline Sysprep verification passed for '$VhdxPath'. Windows recorded $($terminalErrors.Count) non-fatal provider error(s) before creating its success tag."
    }
    catch {
        $result.Message = $_.Exception.Message
    }
    finally {
        if ($assignedPartition -and $assignedAccessPath) {
            try {
                $assignedPartition | Remove-PartitionAccessPath -AccessPath $assignedAccessPath -ErrorAction Stop | Out-Null
            }
            catch {
                $result.Success = $false
                $result.Message = "Failed to remove temporary access path '$assignedAccessPath': $($_.Exception.Message)"
            }
        }
        if ($diskImage) {
            try {
                Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
            }
            catch {
                $result.Success = $false
                $result.Message = "Failed to dismount '$VhdxPath' after Sysprep verification: $($_.Exception.Message)"
            }
        }
    }

    return $result
}

function New-VhdxFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$WimName,
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath,
        [Parameter(Mandatory = $false)]
        [string]$ImageName,
        [Parameter(Mandatory = $false)]
        [string]$UnattendFileName,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "WhatIf: Will convert WIM $WimName to VHDX $VhdxPath"
        return $true
    }

    $wimPath = Join-Path $Common.StagingWimPath $WimName
    if (-not (Test-Path $wimPath -PathType Leaf)) {
        Write-Log "WIM '$wimPath' does not exist." -Failure
        return $false
    }
    if (Test-Path $VhdxPath) {
        Write-Log "VHDX '$VhdxPath' already exists; refusing to overwrite it inside New-VhdxFile." -Failure
        return $false
    }

    try {
        Write-Log "Obtaining image from $wimPath."
        $windowsImages = @(Get-WindowsImage -ImagePath $wimPath -ErrorAction Stop | Select-Object ImageName, ImageIndex, ImageDescription)
        $selectedImage = $null

        if ($ImageName) {
            $selectedImage = $windowsImages | Where-Object { $_.ImageName -eq $ImageName } | Select-Object -First 1
        }
        elseif ($WimName -like "SERVER-*") {
            $selectedImage = $windowsImages | Where-Object { $_.ImageName -like "*DATACENTER*Desktop*" } | Select-Object -First 1
        }
        elseif ($WimName -like "WIN10-*") {
            $selectedImage = $windowsImages | Where-Object { $_.ImageName -eq "Windows 10 Enterprise" } | Select-Object -First 1
        }
        elseif ($WimName -like "WIN11-*") {
            $selectedImage = $windowsImages | Where-Object { $_.ImageName -eq "Windows 11 Enterprise" } | Select-Object -First 1
        }
    }
    catch {
        Write-Log "Failed to inspect Windows images in '$wimPath': $($_.Exception.Message)" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $false
    }

    if (-not $selectedImage) {
        $availableImageNames = @($windowsImages | Select-Object -ExpandProperty ImageName)
        $selectionHint = if ($ImageName) { "Requested image '$ImageName' was not found." } else { "The WIM name did not select an image automatically." }
        Write-Log "$selectionHint Available images: $($availableImageNames -join '; '). Use -WindowsImageName to select one." -Failure
        return $false
    }

    try {
        $unattendPath = Resolve-BaseImageUnattendFile -WimName $WimName -UnattendFileName $UnattendFileName
    }
    catch {
        Write-Log $_.Exception.Message -Failure
        return $false
    }
    $unattendPathToInject = Join-Path $Common.TempPath "$([IO.Path]::GetFileNameWithoutExtension($WimName)).$PID.xml"

    Write-Log "Will inject $unattendPath"
    Write-Log "Will inject directories inside $($Common.StagingInjectPath)"
    Write-Log "Will use ImageIndex $($selectedImage.ImageIndex) for $($selectedImage.ImageName)"

    Write-Log "Creating $vhdxPath (Estimated time 20 min)"

    $createdVhdx = $false
    $vhdMounted = $false
    $efiPartition = $null
    $winPartition = $null
    $efiLetter = $null
    $winLetter = $null
    $success = $false
    $failure = $null
    $cleanupFailure = $null

    try {
        Write-Log "Preparing answer file."
        $unattendContent = Get-Content -LiteralPath $unattendPath -Raw -Force -ErrorAction Stop
        if ($unattendContent -notmatch "%vmbuildpassword%" -or $unattendContent -notmatch "%vmbuilduser%") {
            throw "Answer file '$unattendPath' does not contain the required vmbuild credential placeholders."
        }

        $credentialPassword = $Common.LocalAdmin.GetNetworkCredential().Password
        $unattendContent = $unattendContent.Replace("%vmbuilduser%", $Common.LocalAdmin.UserName)
        $unattendContent = $unattendContent.Replace("%vmbuildpassword%", (Get-EncodedPassword -Text $credentialPassword))
        $unattendContent = $unattendContent.Replace("%adminpassword%", (Get-EncodedPassword -Text $credentialPassword -AdminPassword))
        Set-Content -LiteralPath $unattendPathToInject -Value $unattendContent -Force -Encoding UTF8 -ErrorAction Stop

        $filesToInject = @(Get-ChildItem -Directory -Path $Common.StagingInjectPath -ErrorAction Stop | Select-Object -ExpandProperty FullName)

        Write-Log "Creating VHDX with 512-byte sector sizes..."
        New-VHD -Path $VhdxPath -SizeBytes 127GB -Dynamic -LogicalSectorSizeBytes 512 -PhysicalSectorSizeBytes 512 -ErrorAction Stop | Out-Null
        $createdVhdx = $true

        Write-Log "Mounting and partitioning VHDX (UEFI layout)..."
        $vhdMount = Mount-VHD -Path $VhdxPath -Passthru -ErrorAction Stop
        $vhdMounted = $true
        $diskNumber = $vhdMount.DiskNumber

        Initialize-Disk -Number $diskNumber -PartitionStyle GPT -ErrorAction Stop | Out-Null

        $efiPartition = New-Partition -DiskNumber $diskNumber -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -ErrorAction Stop
        New-Partition -DiskNumber $diskNumber -Size 128MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -ErrorAction Stop | Out-Null
        $winPartition = New-Partition -DiskNumber $diskNumber -Size 125GB -ErrorAction Stop
        $recPartition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -GptType '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -ErrorAction Stop

        Format-Volume -Partition $efiPartition -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false -ErrorAction Stop | Out-Null
        Format-Volume -Partition $winPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false -ErrorAction Stop | Out-Null
        Format-Volume -Partition $recPartition -FileSystem NTFS -NewFileSystemLabel "Recovery" -Confirm:$false -ErrorAction Stop | Out-Null

        $efiPartition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop | Out-Null
        $winPartition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop | Out-Null
        $efiPartition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $efiPartition.PartitionNumber -ErrorAction Stop
        $winPartition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $winPartition.PartitionNumber -ErrorAction Stop
        $efiLetter = $efiPartition.DriveLetter
        $winLetter = $winPartition.DriveLetter
        if (-not $efiLetter -or -not $winLetter) {
            throw "Failed to assign temporary drive letters to the EFI and Windows partitions."
        }

        Write-Log "Applying WIM image (Index $($selectedImage.ImageIndex)) to ${winLetter}:\..."
        Expand-WindowsImage -ImagePath $WimPath -Index $selectedImage.ImageIndex -ApplyPath "${winLetter}:\" -ErrorAction Stop | Out-Null

        Write-Log "Configuring UEFI boot..."
        $bcdResult = & bcdboot "${winLetter}:\Windows" /s "${efiLetter}:" /f UEFI 2>&1
        Write-Log "bcdboot: $($bcdResult -join [Environment]::NewLine)"
        if ($LASTEXITCODE -ne 0) {
            throw "bcdboot failed with exit code $LASTEXITCODE."
        }

        Write-Log "Injecting unattend file..."
        $panther = "${winLetter}:\Windows\Panther"
        if (-not (Test-Path $panther)) {
            New-Item -Path $panther -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $unattendPathToInject -Destination "$panther\unattend.xml" -Force -ErrorAction Stop

        foreach ($injectDir in $filesToInject) {
            $injectName = Split-Path $injectDir -Leaf
            $destDir = "${winLetter}:\$injectName"
            Write-Log "Injecting directory: $injectName"
            Copy-Item -LiteralPath $injectDir -Destination $destDir -Recurse -Force -ErrorAction Stop
        }

        $stagedUnattendPath = "${winLetter}:\staging\Unattend.xml"
        if (-not (Test-Path (Split-Path $stagedUnattendPath -Parent) -PathType Container)) {
            New-Item -Path (Split-Path $stagedUnattendPath -Parent) -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $unattendPathToInject -Destination $stagedUnattendPath -Force -ErrorAction Stop

        $efiPartition | Remove-PartitionAccessPath -AccessPath "${efiLetter}:\" -ErrorAction Stop | Out-Null
        $efiLetter = $null
        $winPartition | Remove-PartitionAccessPath -AccessPath "${winLetter}:\" -ErrorAction Stop | Out-Null
        $winLetter = $null
        Dismount-VHD -Path $VhdxPath -ErrorAction Stop | Out-Null
        $vhdMounted = $false

        $vhdInfo = Get-VHD -Path $VhdxPath -ErrorAction Stop
        if ($vhdInfo.VhdFormat -ne "VHDX" -or $vhdInfo.LogicalSectorSize -ne 512 -or $vhdInfo.PhysicalSectorSize -ne 512) {
            throw "Created disk failed VHDX/sector validation."
        }
        $success = $true
        Write-Log "Created VHDX with native 512-byte sectors." -Success
    }
    catch {
        $failure = $_
    }
    finally {
        if ($vhdMounted) {
            try {
                if ($efiLetter -and $efiPartition) {
                    $efiPartition | Remove-PartitionAccessPath -AccessPath "${efiLetter}:\" -ErrorAction SilentlyContinue | Out-Null
                }
                if ($winLetter -and $winPartition) {
                    $winPartition | Remove-PartitionAccessPath -AccessPath "${winLetter}:\" -ErrorAction SilentlyContinue | Out-Null
                }
                Dismount-VHD -Path $VhdxPath -ErrorAction Stop | Out-Null
                $vhdMounted = $false
            }
            catch {
                $cleanupFailure = $_
            }
        }
        if (Test-Path $unattendPathToInject) {
            try {
                Remove-Item -LiteralPath $unattendPathToInject -Force -ErrorAction Stop
            }
            catch {
                Write-Log "Failed to remove temporary unattend file '$unattendPathToInject': $($_.Exception.Message)" -Warning
            }
        }
    }

    if ($cleanupFailure) {
        Write-Log "VHDX cleanup failed: $($cleanupFailure.Exception.Message)" -Failure
        $success = $false
    }
    if (-not $success) {
        if ($failure) {
            Write-Log "Failed to create VHDX: $($failure.Exception.Message)" -Failure
            Write-Log "$($failure.ScriptStackTrace)" -LogOnly
        }
        if ($createdVhdx -and -not $vhdMounted -and (Test-Path $VhdxPath)) {
            try {
                Remove-Item -LiteralPath $VhdxPath -Force -ErrorAction Stop
            }
            catch {
                Write-Log "Failed to remove partial VHDX '$VhdxPath': $($_.Exception.Message)" -Warning
            }
        }
        return $false
    }

    return $true
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