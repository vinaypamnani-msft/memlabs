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

function New-BaseImageAutoLogonPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AnswerDocuments,
        [Parameter(Mandatory = $true)][string]$UserName,
        [switch]$AllowExisting,
        [switch]$DisableAfterFirstLogon
    )

    if ([string]::IsNullOrWhiteSpace($UserName) -or $UserName -match '[\\@]') {
        throw 'First-boot sign-in requires the existing local lab-administrator account name.'
    }
    $entries = [Collections.Generic.List[object]]::new()
    $passwordTemplate = $null
    $passwordElementSource = $null
    $cleanupDescription = 'MemLabs disable first-boot autologon'
    $cleanupCommand = 'cmd.exe /c reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /t REG_DWORD /d 0 /f && reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f'
    foreach ($entry in $AnswerDocuments | Sort-Object @{ Expression = { $_.RelativePath -eq 'staging\Unattend.xml' }; Descending = $true }) {
        $components = @($entry.Document.SelectNodes('//*[local-name()="settings" and @pass="oobeSystem"]/*[local-name()="component" and @name="Microsoft-Windows-Shell-Setup"]'))
        if ($components.Count -ne 1) { throw 'Each available answer file must have one existing oobeSystem Shell-Setup component.' }
        $component = $components[0]
        $existingAuto = @($component.SelectNodes('*[local-name()="AutoLogon"]'))
        if ($existingAuto.Count -gt 1 -or ($existingAuto.Count -and -not $AllowExisting)) {
            throw 'An answer file already configures oobeSystem AutoLogon; this comparison is not applicable.'
        }
        $accounts = @($component.SelectNodes('*[local-name()="UserAccounts"]/*[local-name()="LocalAccounts"]/*[local-name()="LocalAccount"]') |
            Where-Object { $node = $_.SelectSingleNode('*[local-name()="Name"]'); $node -and $node.InnerText -ieq $UserName })
        if ($accounts.Count -ne 1) { throw 'The saved credential username does not uniquely match an existing local account configured by the image.' }
        $group = $accounts[0].SelectSingleNode('*[local-name()="Group"]')
        if (-not $group -or $group.InnerText -notmatch '(^|[,;])\s*Administrators\s*($|[,;])') {
            throw 'The matching source account is not explicitly configured as a local administrator.'
        }
        $password = $accounts[0].SelectSingleNode('*[local-name()="Password"]')
        if ($password) {
            $value = $password.SelectSingleNode('*[local-name()="Value"]')
            $plain = $password.SelectSingleNode('*[local-name()="PlainText"]')
            if (-not $passwordTemplate -and $value -and -not [string]::IsNullOrWhiteSpace($value.InnerText) -and
                $value.InnerText -notmatch 'SENSITIVE.*DELETED|^%.*%$' -and $plain -and $plain.InnerText -in @('true', 'false') -and
                ($plain.InnerText -eq 'true' -or $value.InnerText -match '^[A-Za-z0-9+/]+={0,2}$')) {
                $passwordTemplate = $password.CloneNode($true)
                $passwordElementSource = $entry.RelativePath
            }
        }
        $firstLogon = @($component.SelectNodes('*[local-name()="FirstLogonCommands"]'))
        $cleanup = @()
        $nextOrder = 1
        if ($DisableAfterFirstLogon) {
            if ($firstLogon.Count -gt 1) { throw 'The source has ambiguous FirstLogonCommands.' }
            if ($firstLogon.Count) {
                foreach ($command in @($firstLogon[0].SelectNodes('*[local-name()="SynchronousCommand"]'))) {
                    $orderNode = $command.SelectSingleNode('*[local-name()="Order"]')
                    $order = 0
                    if (-not $orderNode -or -not [int]::TryParse($orderNode.InnerText, [ref]$order) -or $order -lt 1 -or $order -gt 500) {
                        throw 'An existing first-logon command has an unsupported order.'
                    }
                    $nextOrder = [Math]::Max($nextOrder, $order + 1)
                }
                $cleanup = @($firstLogon[0].SelectNodes('*[local-name()="SynchronousCommand"]') |
                    Where-Object { $description = $_.SelectSingleNode('*[local-name()="Description"]'); $description -and $description.InnerText -eq $cleanupDescription })
                if ($cleanup.Count -gt 1 -or ($cleanup.Count -eq 1 -and
                        $cleanup[0].SelectSingleNode('*[local-name()="CommandLine"]').InnerText -cne $cleanupCommand)) {
                    throw 'An existing first-logon autologon cleanup command conflicts with the requested configuration.'
                }
                if (-not $cleanup.Count -and $nextOrder -gt 500) { throw 'No supported first-logon command order remains for autologon cleanup.' }
            }
        }
        $entries.Add([pscustomobject]@{
                Entry = $entry; Component = $component; ExistingAuto = $(if ($existingAuto.Count) { $existingAuto[0] } else { $null })
                FirstLogon = $(if ($firstLogon.Count) { $firstLogon[0] } else { $null })
                CleanupPresent = $cleanup.Count -eq 1; NextOrder = $nextOrder
            })
    }
    if ($entries.Count -eq 0 -or -not $passwordTemplate) {
        throw 'No usable existing account-password element was found in the source answer files. No password will be guessed, decoded, or reset.'
    }
    foreach ($item in $entries) {
        if ($item.Component.NamespaceURI -cne $passwordTemplate.NamespaceURI) { throw 'The source password and target setup components use different XML namespaces.' }
        if ($item.ExistingAuto) {
            $auto = $item.ExistingAuto
            if ($auto.SelectSingleNode('*[local-name()="Username"]').InnerText -cne $UserName -or
                $auto.SelectSingleNode('*[local-name()="Domain"]').InnerText -ne '.' -or
                $auto.SelectSingleNode('*[local-name()="Enabled"]').InnerText -ne 'true' -or
                $auto.SelectSingleNode('*[local-name()="LogonCount"]').InnerText -ne '1' -or
                $auto.SelectSingleNode('*[local-name()="Password"]/*[local-name()="PlainText"]').InnerText -cne $passwordTemplate.SelectSingleNode('*[local-name()="PlainText"]').InnerText -or
                $auto.SelectSingleNode('*[local-name()="Password"]/*[local-name()="Value"]').InnerText -cne $passwordTemplate.SelectSingleNode('*[local-name()="Value"]').InnerText) {
                throw 'Existing AutoLogon does not match the requested local-account configuration.'
            }
        }
    }
    return [pscustomobject]@{
        Entries = $entries.ToArray(); UserName = $UserName; PasswordTemplate = $passwordTemplate
        PasswordElementSource = $passwordElementSource; DisableAfterFirstLogon = [bool]$DisableAfterFirstLogon
        CleanupCommand = $cleanupCommand; CleanupDescription = $cleanupDescription
    }
}

function Write-BaseImageAutoLogonPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $patched = [Collections.Generic.List[string]]::new()
    foreach ($item in $Plan.Entries) {
        $entry = $item.Entry; $document = $entry.Document; $component = $item.Component
        if (-not $item.ExistingAuto) {
            $auto = $document.CreateElement('AutoLogon', $component.NamespaceURI)
            $null = $auto.AppendChild($document.ImportNode($Plan.PasswordTemplate, $true))
            foreach ($setting in @(
                    @{ Name = 'Domain'; Value = '.' }, @{ Name = 'Enabled'; Value = 'true' },
                    @{ Name = 'LogonCount'; Value = '1' }, @{ Name = 'Username'; Value = $Plan.UserName }
                )) {
                $node = $document.CreateElement($setting.Name, $component.NamespaceURI)
                $node.InnerText = $setting.Value
                $null = $auto.AppendChild($node)
            }
            $null = $component.AppendChild($auto)
        }
        if ($Plan.DisableAfterFirstLogon -and -not $item.CleanupPresent) {
            $firstLogon = $item.FirstLogon
            if (-not $firstLogon) {
                $firstLogon = $document.CreateElement('FirstLogonCommands', $component.NamespaceURI)
                $null = $component.AppendChild($firstLogon)
            }
            $command = $document.CreateElement('SynchronousCommand', $component.NamespaceURI)
            $null = $command.SetAttribute('action', 'http://schemas.microsoft.com/WMIConfig/2002/State', 'add')
            foreach ($setting in @(
                    @{ Name = 'CommandLine'; Value = $Plan.CleanupCommand }, @{ Name = 'Description'; Value = $Plan.CleanupDescription },
                    @{ Name = 'Order'; Value = "$($item.NextOrder)" }, @{ Name = 'RequiresUserInput'; Value = 'false' }
                )) {
                $node = $document.CreateElement($setting.Name, $component.NamespaceURI)
                $node.InnerText = $setting.Value
                $null = $command.AppendChild($node)
            }
            $null = $firstLogon.AppendChild($command)
        }
        $stream = [IO.File]::Open($entry.Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $document.Save($stream) } finally { $stream.Dispose() }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null; $settings.MaxCharactersInDocument = 1MB
        $stream = [IO.File]::OpenRead($entry.Path); $reader = $null
        try {
            $reader = [Xml.XmlReader]::Create($stream, $settings)
            $verified = [xml]::new(); $verified.XmlResolver = $null; $verified.Load($reader)
        }
        finally { if ($reader) { $reader.Dispose() }; $stream.Dispose() }
        $readBack = $verified.SelectSingleNode('//*[local-name()="settings" and @pass="oobeSystem"]/*[local-name()="component" and @name="Microsoft-Windows-Shell-Setup"]/*[local-name()="AutoLogon"]')
        if (-not $readBack -or $readBack.SelectSingleNode('*[local-name()="Username"]').InnerText -cne $Plan.UserName -or
            $readBack.SelectSingleNode('*[local-name()="Enabled"]').InnerText -ne 'true' -or
            $readBack.SelectSingleNode('*[local-name()="LogonCount"]').InnerText -ne '1' -or
            $readBack.SelectSingleNode('*[local-name()="Domain"]').InnerText -ne '.' -or
            $readBack.SelectSingleNode('*[local-name()="Password"]/*[local-name()="PlainText"]').InnerText -cne $Plan.PasswordTemplate.SelectSingleNode('*[local-name()="PlainText"]').InnerText -or
            $readBack.SelectSingleNode('*[local-name()="Password"]/*[local-name()="Value"]').InnerText -cne $Plan.PasswordTemplate.SelectSingleNode('*[local-name()="Value"]').InnerText) {
            throw 'The first-boot sign-in answer settings failed read-back verification.'
        }
        if ($Plan.DisableAfterFirstLogon) {
            $commands = @($verified.SelectNodes('//*[local-name()="settings" and @pass="oobeSystem"]/*[local-name()="component" and @name="Microsoft-Windows-Shell-Setup"]/*[local-name()="FirstLogonCommands"]/*[local-name()="SynchronousCommand"]') |
                Where-Object { $_.SelectSingleNode('*[local-name()="Description"]').InnerText -eq $Plan.CleanupDescription -and
                    $_.SelectSingleNode('*[local-name()="CommandLine"]').InnerText -ceq $Plan.CleanupCommand })
            if ($commands.Count -ne 1) { throw 'The first-boot autologon cleanup command failed read-back verification.' }
        }
        $patched.Add($entry.RelativePath)
    }
    return [pscustomobject]@{
        Configured = $patched.Count -gt 0; UserName = $Plan.UserName; LogonCount = 1
        AnswerFiles = $patched.ToArray(); PasswordElementSource = $Plan.PasswordElementSource
        DisableAfterFirstLogon = $Plan.DisableAfterFirstLogon
        PasswordHandling = 'Reused an existing local-account password XML element; not decoded, logged, or exported.'
    }
}

function Import-BaseImageOfflineSetupHelpers {
    [CmdletBinding()]
    param()

    $readerPath = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\Get-WindowsVmSetupDiagnostics.ps1"
    $parseErrors = $null
    $readerAst = [Management.Automation.Language.Parser]::ParseFile($readerPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Offline registry reader parse errors: $($parseErrors -join '; ')" }
    foreach ($name in @('Initialize-MemLabsOfflineSetupHiveType', 'Get-MemLabsOfflineSetupSourcePath')) {
        $definitions = @($readerAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true))
        if ($definitions.Count -ne 1) { throw "The offline setup helper '$name' is missing or ambiguous." }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
}

function Get-BaseImageInstallationType {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SoftwareHivePath)

    . Import-BaseImageOfflineSetupHelpers
    Initialize-MemLabsOfflineSetupHiveType

    $hive = [MemLabs.OfflineSetupHiveReader]::OpenReadOnly($SoftwareHivePath)
    $key = $null
    try {
        $key = $hive.OpenSubKey('Microsoft\Windows NT\CurrentVersion', $false)
        if (-not $key) { throw 'The installed Windows version key is missing.' }
        $installationType = $key.GetValue('InstallationType', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($installationType -notin @('Client', 'Server', 'Server Core')) {
            throw "The installed Windows installation type '$installationType' is missing or unsupported."
        }
        return $installationType
    }
    finally {
        if ($key) { $key.Dispose() }
        $hive.Dispose()
    }
}

function Invoke-BaseImageOfflineWindows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VhdxPath,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [switch]$ReadWrite
    )

    $diskImage = $null
    $assignedPartition = $null
    $assignedAccessPath = $null
    $items = @()
    $cleanupErrors = @()
    try {
        if (-not (Test-Path -LiteralPath $VhdxPath -PathType Leaf)) { throw "VHDX '$VhdxPath' does not exist." }
        if ((Get-VHD -Path $VhdxPath -ErrorAction Stop).Attached) { throw "VHDX '$VhdxPath' is already attached." }
        $access = if ($ReadWrite) { 'ReadWrite' } else { 'ReadOnly' }
        $diskImage = Mount-DiskImage -ImagePath $VhdxPath -Access $access -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        $disk = $diskImage | Get-Disk -ErrorAction Stop
        if ([bool]$disk.IsReadOnly -ne (-not [bool]$ReadWrite)) { throw 'The owned image was not mounted with the requested access mode.' }
        $windowsRoot = $null
        foreach ($partition in @($disk | Get-Partition -ErrorAction Stop | Sort-Object Size -Descending)) {
            if ($partition.Size -lt 10GB) { continue }
            $candidatePartition = $partition
            if (-not $candidatePartition.DriveLetter) {
                $candidatePartition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop | Out-Null
                $assignedPartition = $candidatePartition
                $candidatePartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $candidatePartition.PartitionNumber -ErrorAction Stop
                if (-not $candidatePartition.DriveLetter) { throw 'The owned Windows partition was not assigned an access path.' }
                $assignedAccessPath = "$($candidatePartition.DriveLetter):\"
            }
            $candidateRoot = "$($candidatePartition.DriveLetter):\"
            if (Test-Path -LiteralPath (Join-Path $candidateRoot "Windows\System32\Sysprep") -PathType Container) {
                $windowsRoot = $candidateRoot
                break
            }
            if ($assignedPartition -and $assignedAccessPath) {
                $assignedPartition | Remove-PartitionAccessPath -AccessPath $assignedAccessPath -ErrorAction Stop | Out-Null
                $assignedPartition = $null; $assignedAccessPath = $null
            }
        }
        if (-not $windowsRoot) { throw "No Windows partition was found in '$VhdxPath'." }
        $items = @(& $ScriptBlock $windowsRoot @ArgumentList)
    }
    finally {
        if ($assignedPartition -and $assignedAccessPath) {
            try { $assignedPartition | Remove-PartitionAccessPath -AccessPath $assignedAccessPath -ErrorAction Stop | Out-Null }
            catch { $cleanupErrors += "Failed to remove owned access path '$assignedAccessPath': $($_.Exception.Message)" }
        }
        if ($diskImage) {
            try { Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null }
            catch { $cleanupErrors += "Failed to dismount owned image '$VhdxPath': $($_.Exception.Message)" }
        }
        if ($cleanupErrors.Count) { throw ($cleanupErrors -join '; ') }
    }
    return $items
}

function Set-BaseImageFirstBootAutoLogon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VhdxPath,
        [Parameter(Mandatory = $true)][string]$UserName
    )

    $info = Get-VHD -Path $VhdxPath -ErrorAction Stop
    if ($info.VhdFormat -ne 'VHDX' -or $info.ParentPath -or $info.Attached) {
        throw 'First-boot configuration requires an independent, unattached staging VHDX.'
    }
    return Invoke-BaseImageOfflineWindows -VhdxPath $VhdxPath -ReadWrite -ArgumentList @($UserName) -ScriptBlock {
        param($WindowsRoot, $UserName)
        . Import-BaseImageOfflineSetupHelpers
        if ((Get-BaseImageInstallationType -SoftwareHivePath (Join-Path $WindowsRoot 'Windows\System32\config\SOFTWARE')) -ne 'Client') {
            throw 'First-boot administrator sign-in is supported only for Windows client staging images.'
        }
        Initialize-MemLabsOfflineSetupHiveType
        foreach ($check in @(
                @{ Hive = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\Setup\State'; Name = 'ImageState'; Expected = @('IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE', 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE') },
                @{ Hive = 'SYSTEM'; Key = 'Setup'; Name = 'SetupType'; Expected = @(2) }
            )) {
            $hive = [MemLabs.OfflineSetupHiveReader]::OpenReadOnly((Join-Path $WindowsRoot "Windows\System32\config\$($check.Hive)"))
            $key = $null
            try {
                $key = $hive.OpenSubKey($check.Key, $false)
                if (-not $key -or $key.GetValue($check.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -notin $check.Expected) {
                    throw 'The staging image is not generalized and awaiting OOBE; refusing to change its sign-in configuration.'
                }
            }
            finally { if ($key) { $key.Dispose() }; $hive.Dispose() }
        }
        $documents = [Collections.Generic.List[object]]::new()
        foreach ($relative in @('Windows\Panther\unattend.xml', 'staging\Unattend.xml')) {
            $answer = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath $relative
            if (-not $answer) { continue }
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null; $settings.MaxCharactersInDocument = 1MB
            $stream = [IO.File]::OpenRead($answer); $reader = $null
            try {
                if ($stream.Length -gt 1MB) { throw 'The staging answer file exceeds the inspection limit.' }
                $reader = [Xml.XmlReader]::Create($stream, $settings)
                $document = [xml]::new(); $document.XmlResolver = $null; $document.Load($reader)
            }
            finally { if ($reader) { $reader.Dispose() }; $stream.Dispose() }
            if (@($document.SelectNodes('//*[local-name()="JoinDomain" and normalize-space(.)!=""]')).Count) {
                throw 'The staging answer file requests a domain join; isolated first-boot configuration is refused.'
            }
            $documents.Add([pscustomobject]@{ Document = $document; Path = $answer; RelativePath = $relative })
        }
        $plan = New-BaseImageAutoLogonPlan -AnswerDocuments $documents.ToArray() -UserName $UserName -AllowExisting -DisableAfterFirstLogon
        $configured = Write-BaseImageAutoLogonPlan -Plan $plan
        $staging = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath 'staging' -AllowDirectory
        if (-not $staging) { throw 'The owned staging directory is missing.' }
        $markerName = 'staging\MemLabs-BoundedFirstBootAutoLogon.txt'
        $existingMarker = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath $markerName
        $marker = if ($existingMarker) { $existingMarker } else { Join-Path $staging 'MemLabs-BoundedFirstBootAutoLogon.txt' }
        [IO.File]::WriteAllText($marker, '1', [Text.Encoding]::ASCII)
        return $configured
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
            InstallationType = $null
        }
    }

    $result = [pscustomobject]@{
        Success = $false
        Message = ""
        Warnings = @()
        InstallationType = $null
    }
    try {
        $null = Invoke-BaseImageOfflineWindows -VhdxPath $VhdxPath -ArgumentList @($result, $VhdxPath) -ScriptBlock {
        param($windowsRoot, $result, $VhdxPath)

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

        $result.InstallationType = Get-BaseImageInstallationType -SoftwareHivePath (Join-Path $windowsRoot "Windows\System32\config\SOFTWARE")
        $result.Success = $true
        $result.Message = "Offline Sysprep verification passed for '$VhdxPath'. Windows recorded $($terminalErrors.Count) non-fatal provider error(s) before creating its success tag."
        }
    }
    catch {
        $result.Success = $false
        $result.Message = $_.Exception.Message
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