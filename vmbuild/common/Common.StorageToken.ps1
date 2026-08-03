# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
#Common.StorageToken.ps1
# NOTE: This file is dot-sourced during DSC generation which runs under
# PowerShell 5.1. Do not use PS7+ syntax (e.g. ?? ?. ??= ternary).

# Returns the root used for host-local cached data files (productID.txt, SysCenterId.txt).
# Stored under %ProgramData%\memlabs (created on demand) instead of the drive root.
# Honors host override via $env:MEMLABS_DATA_ROOT for unusual setups.
function Get-MemlabsDataRoot {
    $root = $env:MEMLABS_DATA_ROOT
    if ([string]::IsNullOrWhiteSpace($root)) {
        $programData = $env:ProgramData
        if ([string]::IsNullOrWhiteSpace($programData)) { $programData = 'C:\ProgramData' }
        $root = Join-Path $programData 'memlabs'
    }
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -Path $root -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    return $root
}

# ---- Host settings (per-machine, persisted in %ProgramData%\memlabs\host-settings.json) ----

function Get-MemlabsHostSettingsPath {
    return (Join-Path (Get-MemlabsDataRoot) 'host-settings.json')
}

function Get-MemlabsHostSettings {
    $path = Get-MemlabsHostSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Write-Log "Get-MemlabsHostSettings: Failed to parse $path - $_" -Warning
        return $null
    }
}

function Set-MemlabsHostSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )
    $path = Get-MemlabsHostSettingsPath
    $settings = Get-MemlabsHostSettings
    if (-not $settings) { $settings = [PSCustomObject]@{} }
    if ($settings.PSObject.Properties[$Name]) {
        $settings.$Name = $Value
    }
    else {
        $settings | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
    try {
        $settings | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $path -Force -Encoding utf8 -ErrorAction Stop
        Write-Log "Set-MemlabsHostSetting: $Name=$Value -> $path" -LogOnly
    }
    catch {
        Write-Log "Set-MemlabsHostSetting: Failed to write $path - $_" -Warning
    }
}

# Returns the per-host root path under which memlabs creates per-domain VM folders.
# Resolution order:
#   1. $env:MEMLABS_VM_STORAGE_ROOT  (escape hatch for scripted setups)
#   2. host-settings.json -> vmStorageRoot   (sticky from a previous run)
#   3. E:\VirtualMachines                    (lab-host convention, when E: exists)
#   4. interactive picker over fixed drives (largest free space first), saved for next time
# Validator already rejects basePath drive letters C/D/Z, so those are excluded from the picker.
# -NoPrompt callers (cleanup, jobs) get $null instead of a prompt if nothing's been chosen.
function Get-MemlabsVmStorageRoot {
    [CmdletBinding()]
    param(
        [switch]$NoPrompt
    )

    $envOverride = $env:MEMLABS_VM_STORAGE_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envOverride)) {
        return $envOverride
    }

    $settings = Get-MemlabsHostSettings
    $saved = $null
    if ($settings -and $settings.PSObject.Properties['vmStorageRoot']) {
        $saved = $settings.vmStorageRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($saved)) {
        $savedRoot = [System.IO.Path]::GetPathRoot($saved)
        if ($savedRoot -and [System.IO.Directory]::Exists($savedRoot)) {
            return $saved
        }
        Write-Log "Get-MemlabsVmStorageRoot: Saved vmStorageRoot '$saved' is on a drive that no longer exists; re-resolving." -Warning
    }

    if ([System.IO.Directory]::Exists('E:\')) {
        $default = 'E:\VirtualMachines'
        Set-MemlabsHostSetting -Name 'vmStorageRoot' -Value $default
        return $default
    }

    $eligible = @(Get-MemlabsEligibleStorageDrives)
    if ($eligible.Count -eq 0) {
        Write-Log "Get-MemlabsVmStorageRoot: No eligible fixed drives found (need a fixed drive other than C/D/Z)." -Warning
        return $null
    }

    if ($NoPrompt -or $Common.InJob -or -not [Environment]::UserInteractive) {
        $pick = $eligible[0]
        $path = "$($pick.DriveLetter):\VirtualMachines"
        Set-MemlabsHostSetting -Name 'vmStorageRoot' -Value $path
        return $path
    }

    Write-Host ''
    Write-Host 'No E: drive found. Select a drive for VM storage (sorted by free space):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $eligible.Count; $i++) {
        $d = $eligible[$i]
        $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        $tag = if ($i -eq 0) { ' (largest free)' } else { '' }
        Write-Host ("  [{0}] {1}:\  {2} GB free of {3} GB{4}" -f ($i + 1), $d.DriveLetter, $freeGB, $sizeGB, $tag)
    }
    $picked = $null
    while ($null -eq $picked) {
        $resp = Read-Host "Enter selection 1-$($eligible.Count) [1]"
        if ([string]::IsNullOrWhiteSpace($resp)) { $resp = '1' }
        $n = 0
        if ([int]::TryParse($resp, [ref]$n) -and $n -ge 1 -and $n -le $eligible.Count) {
            $picked = $eligible[$n - 1]
        }
        else {
            Write-Host "Invalid selection." -ForegroundColor Yellow
        }
    }
    $path = "$($picked.DriveLetter):\VirtualMachines"
    Set-MemlabsHostSetting -Name 'vmStorageRoot' -Value $path
    Write-Host "Saved $path as the default VM storage root for this host." -ForegroundColor Green
    return $path
}

function Get-MemlabsEligibleStorageDrives {
    # Fixed disks (DriveType=3) only. C/D/Z are reserved (system/recovery/storage) per validator.
    $excluded = @('C', 'D', 'Z')
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $letter = $_.DeviceID.TrimEnd(':')
            if ($letter -and ($excluded -notcontains $letter.ToUpper())) {
                [PSCustomObject]@{
                    DriveLetter = $letter
                    FreeSpace   = [int64]$_.FreeSpace
                    Size        = [int64]$_.Size
                }
            }
        } | Sort-Object -Property FreeSpace -Descending
}

# Placeholder for future alternative auth methods (e.g. Managed Identity, certificate-based).
# Currently only SAS token auth is supported.
function Get-StorageToken {
    param(
        [int]$MinutesRemaining = 30
    )

    # No alternative auth methods are currently implemented.
    # SAS token auth is handled inline via StorageConfig.StorageToken.
    return $null
}

# ---- Helper: Build a URL, appending SAS token ----
function Get-StorageUrl {
    param(
        [string]$BaseUrl,
        [string]$FileName
    )

    $url = "$BaseUrl/$FileName"
    return "$url`?$($StorageConfig.StorageToken)"
}

# ---- Helper: Invoke-WebRequest with retry ----
function Invoke-StorageRequest {
    param(
        [string]$Url,
        [int]$RetrySeconds = 5
    )

    try {
        return Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Log "Invoke-StorageRequest: First attempt failed, retrying in $RetrySeconds seconds..."
        Write-Log "Invoke-StorageRequest: First attempt failed, $_" -logonly
        Start-Sleep -Seconds $RetrySeconds
        try {
            return Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Write-Exception -ExceptionInfo $_
            return $null
        }
    }
}
function Get-StorageConfig {

    # ---- Discover all _storageConfigXXXX.json files, try newest first ----
  
    $configFiles = Get-ChildItem -Path $Common.ConfigPath -Filter "_storageConfig*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^_storageConfig\d{4}(\.\d+)?\.json$" } |
    Sort-Object Name -Descending


    if (-not $configFiles) {
        $Common.FatalError = "Get-StorageConfig: No _storageConfigXXXX.json files found in '$($Common.ConfigPath)'. Refer to internal documentation."
        Write-Log $Common.FatalError
        return $false
    }

    Write-Log "Get-StorageConfig: Found $($configFiles.Count) config file(s): $($configFiles.Name -join ', ')" -LogOnly

    # ---- Try each config file in descending order (newest first) ----
    $authSet = $false

    foreach ($file in ($configFiles | Sort-Object @{
    Expression = {
        if ($_.Name -match '^_storageConfig(\d+)(?:\.(\d+))?\.json$') {
            [int]$matches[1] * 100000 + [int]$(if ($matches[2]) { $matches[2] } else { 0 })
        }
    }
} -Descending)) {
        Write-Log "Get-StorageConfig: Trying $($file.Name)..." -LogOnly

        try {
            $candidate = Get-Content -Path $file.FullName -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Log "Get-StorageConfig: Failed to parse $($file.Name), skipping." -Warning
            continue
        }

        # ---- Validate storage location fields ----
        $hasStorageAccount = -not [string]::IsNullOrWhiteSpace($candidate.storageAccount)
        $hasStorageLocation = -not [string]::IsNullOrWhiteSpace($candidate.storageLocation)

        if (-not $hasStorageAccount -and -not $hasStorageLocation) {
            Write-Log "Get-StorageConfig: $($file.Name) has no storageAccount or storageLocation, skipping." -LogOnly
            continue
        }

        if ($hasStorageAccount -and [string]::IsNullOrWhiteSpace($candidate.containerName)) {
            Write-Log "Get-StorageConfig: $($file.Name) has storageAccount but no containerName, skipping." -LogOnly
            continue
        }

        # ---- Validate SAS token ----
        $candidateSasAvailable = -not [string]::IsNullOrWhiteSpace($candidate.storageToken)

        if (-not $candidateSasAvailable) {
            Write-Log "Get-StorageConfig: $($file.Name) has no SAS token, skipping." -LogOnly
            continue
        }

        # ---- Derive StorageLocation for this candidate ----
        $candidateStorageLocation = if (-not [string]::IsNullOrWhiteSpace($candidate.storageAccount)) {
            "https://$($candidate.storageAccount).blob.core.windows.net/$($candidate.containerName)"
        }
        else {
            $candidate.storageLocation
        }

        # ---- Store script-scoped vars ----
        $script:storageConfigName = $file.Name
        $script:fileListName = if ($Common.DevBranch) { "_fileList_develop.json" } else { "_fileList.json" }
        $script:fileListPath = Join-Path $Common.AzureFilesPath $script:fileListName

        Write-Log "Get-StorageConfig: Testing SAS token for $($file.Name)..." -LogOnly

        $Common.StorageConfigLocation = $file.FullName
        $StorageConfig.StorageToken = $candidate.storageToken
        $StorageConfig.StorageLocation = $candidateStorageLocation

        $testUrl = Get-StorageUrl -BaseUrl $candidateStorageLocation -FileName $script:fileListName
        $testResponse = Invoke-StorageRequest -Url $testUrl
        if ($null -ne $testResponse) {
            $authSet = $true
            Write-Log "Get-StorageConfig: Storage auth mode: SAS Token via $($file.Name)" -LogOnly
            break
        }
        else {
            Write-Log "Get-StorageConfig: SAS token failed for $($file.Name)." -Warning
            $StorageConfig.StorageLocation = $null
            $StorageConfig.StorageToken = $null
        }
    }

    if (-not $authSet) {
        $Common.FatalError = "Get-StorageConfig: Could not authenticate using any available config file."
        Write-Log $Common.FatalError -Warning
        return $false
    }

    # ---- Finalize ----
    Write-Log "Get-StorageConfig: StorageLocation: $($StorageConfig.StorageLocation)" -LogOnly

    $newestConfigFile = $configFiles[0]
    $script:newStorageConfigName = $newestConfigFile.Name
    $script:newConfigPath = $newestConfigFile.FullName
    $script:GetNewStorageConfig = ($file.Name -ne $configFiles[0].Name)

    return $true
}

# ---- 6: Windows 2025 upgrade cleanup ----
function Remove-Windows2025UpgradeFiles {

    if ([Environment]::OSVersion.Version -lt [System.Version]"10.0.26100.0") {
        return
    }

    Write-Log "Remove-Windows2025UpgradeFiles: Starting upgrade-to-2025 cleanup" -LogOnly

    $upgradePath = "C:\temp\Upgrade2025"
    $supportFile = Join-Path $Common.AzureFilesPath "support\WindowsServer2025.zip"

    Write-Log "Remove-Windows2025UpgradeFiles: Testing path '$upgradePath'" -LogOnly
    $upgradePathExists = Test-Path $upgradePath
    Write-Log "Remove-Windows2025UpgradeFiles: Test-Path '$upgradePath' returned $upgradePathExists" -LogOnly

    if ($upgradePathExists) {
        Write-Host "Removing 2025 Upgrade Support files - $upgradePath"
        Write-Log "Remove-Windows2025UpgradeFiles: Removing '$upgradePath' (recursive)" -LogOnly
        try {
            Remove-Item -Path $upgradePath -Recurse -Force -ErrorAction Stop -ProgressAction SilentlyContinue
            Write-Log "Remove-Windows2025UpgradeFiles: Removed '$upgradePath'" -LogOnly
        }
        catch {
            Write-Log "Remove-Windows2025UpgradeFiles: Failed to remove '$upgradePath': $_" -Warning
        }
    }

    Write-Log "Remove-Windows2025UpgradeFiles: Testing path '$supportFile'" -LogOnly
    $supportFileExists = Test-Path $supportFile
    Write-Log "Remove-Windows2025UpgradeFiles: Test-Path '$supportFile' returned $supportFileExists" -LogOnly

    if ($supportFileExists) {
        Write-Host "Removing 2025 Upgrade Support files - $supportFile"
        Write-Log "Remove-Windows2025UpgradeFiles: Removing '$supportFile'" -LogOnly
        try {
            Remove-Item -Path $supportFile -Force -ErrorAction Stop -ProgressAction SilentlyContinue
            Write-Log "Remove-Windows2025UpgradeFiles: Removed '$supportFile'" -LogOnly
        }
        catch {
            Write-Log "Remove-Windows2025UpgradeFiles: Failed to remove '$supportFile': $_" -Warning
        }
    }

    Write-Log "Remove-Windows2025UpgradeFiles: Success cleaning upgrade to 2025" -LogOnly
}

function Initialize-Storage {

    $pp = $ProgressPreference
    $vp = $VerbosePreference
    $ProgressPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'

    try {
        # Skip all network operations if running inside a job.
        # Jobs don't need to verify SAS tokens over the network - they
        # only need the local file list and admin credential.
        if ($InJob.IsPresent) {
            Write-Log "Skipped storage network operations, running inside a job." -Verbose
            $Common.OfflineMode = $true
            $script:fileListName = if ($Common.DevBranch) { "_fileList_develop.json" } else { "_fileList.json" }
            $script:fileListPath = Join-Path $Common.AzureFilesPath $script:fileListName
            if (-not (Update-FileList)) { return $false }
            if (-not (Get-LocalAdminCredential)) { return $false }
            return $true
        }

        # Load local config and determine auth mode
        $storageConfigLoaded = Get-StorageConfig
        if (-not $storageConfigLoaded) {
            Write-Log "Get-StorageConfig failed - attempting offline mode using local cached files." -Warning
            $Common.OfflineMode = $true

            # Clear FatalError so offline mode can continue
            # The warning has already been logged above
            $Common.FatalError = $null

            # Set script-scoped vars manually so offline functions can still run
            $script:fileListName = if ($Common.DevBranch) { "_fileList_develop.json" } else { "_fileList.json" }
            $script:fileListPath = Join-Path $Common.AzureFilesPath $script:fileListName
            $script:downloadConfigName = $Common.NewestStorageConfigFileName
            $script:downloadConfigPath = Join-Path $Common.ConfigPath $script:downloadConfigName
        }

        # Skip Update-StorageConfigFile entirely if storage config failed
        # We have no valid StorageLocation to build URLs with
        if ($storageConfigLoaded) {
            Update-StorageConfigFile | Out-Null
        }

        if (-not (Update-FileList)) { return $false }
        if (-not (Get-ProductID)) { return $false }
        if (-not (Get-LocalAdminCredential)) { return $false }

        if ($storageConfigLoaded) {
            Remove-Windows2025UpgradeFiles
        }

        return [string]::IsNullOrWhiteSpace($Common.FatalError)

    }
    catch {
        $Common.FatalError = "Storage Access failed. $_"
        Write-Exception -ExceptionInfo $_
        Write-Host $_.ScriptStackTrace | Out-Host
        return $false
    }
    finally {
        $ProgressPreference = $pp
        $VerbosePreference = $vp
    }
}

function Update-StorageConfigFile {

    $script:downloadConfigName = $Common.NewestStorageConfigFileName
    $script:downloadConfigPath = Join-Path $Common.ConfigPath $script:downloadConfigName

    # Nothing to do if we're already using the newest config
    if ($script:storageConfigName -eq $script:downloadConfigName) {
        Write-Log "Update-StorageConfigFile: Already using $($script:downloadConfigName), nothing to do." -LogOnly
        return $true
    }

    # Check if the newest config file already exists locally
    if (Test-Path $script:downloadConfigPath) {
        Write-Log "Update-StorageConfigFile: $($script:downloadConfigName) found locally, re-initializing..." -LogOnly
    }
    else {
        # Try to download it using current auth
        Write-Log "Update-StorageConfigFile: Attempting to download $($script:downloadConfigName) from azure storage" -LogOnly

        $url = Get-StorageUrl -BaseUrl $StorageConfig.StorageLocation -FileName $script:downloadConfigName
        $response = Invoke-StorageRequest -Url $url

        if (-not $response) {
            Write-Log "Update-StorageConfigFile: Could not download $($script:downloadConfigName) - continuing with existing config." -LogOnly
            return $true  # Non-fatal
        }

        try {
            $response.Content.Trim() | Out-File -FilePath $script:downloadConfigPath -Force -ErrorAction Stop
            Write-Log "Update-StorageConfigFile: Downloaded and saved $($script:downloadConfigName)." -LogOnly
        }
        catch {
            Write-Log "Update-StorageConfigFile: Failed to save $($script:downloadConfigName) to disk.`n$_" -Warning
            return $true  # Non-fatal
        }
    }

    # ---- Re-init with new config ----
    Write-Log "Update-StorageConfigFile: Re-initializing storage config with $($script:downloadConfigName)..." -LogOnly

    if (-not (Get-StorageConfig)) {
        Write-Log "Update-StorageConfigFile: Re-init failed, reverting to previous config." -Warning
        Remove-Item -Path $script:downloadConfigPath -Force -ErrorAction SilentlyContinue
        return $true  # Non-fatal
    }

    Write-Log "Update-StorageConfigFile: Re-initialized successfully." -LogOnly
    return $true
}

# ---- 3: Download updated file list from Azure ----
function Update-FileList {

    # In offline mode, try to load from local cache only
    if ($Common.OfflineMode) {
        if (Test-Path $script:fileListPath) {
            # -LogOnly: offline mode is a normal configured state, not a problem, and
            # every job worker re-inits Common.ps1 -- 906 of one run's 1,648 warnings
            # were this single line, which buries the warnings that matter.
            Write-Log "Update-FileList: Offline mode, loading from local cache at $($script:fileListPath)." -LogOnly
            try {
                $Common.AzureFileList = Get-Content -Path $script:fileListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                return $true
            }
            catch {
                Write-Log "Update-FileList: Failed to read local file list cache." -Warning
                return $false
            }
        }
        Write-Log "Update-FileList: Offline mode and no local cache found at $($script:fileListPath)." -Warning
        return $false
    }

    $updateList = $true

    if (Test-Path $script:fileListPath) {
        Write-Log "Reading file list from $($script:fileListPath)" -Verbose
        try {
            $Common.AzureFileList = Get-Content -Path $script:fileListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $updateList = $Common.AzureFileList.UpdateFromStorage
        }
        catch {
            Write-Log "Failed to read local file list, will re-download." -Warning
            $updateList = $true
        }
    }

    if (-not $updateList -and (Test-Path $script:fileListPath)) {
        Write-Log "File list is up to date, skipping download." -LogOnly
        return $true
    }

    Write-Log "Updating fileList from azure storage" -LogOnly
    $url = Get-StorageUrl -BaseUrl $StorageConfig.StorageLocation -FileName $script:fileListName
    $response = Invoke-StorageRequest -Url $url

    if (-not $response) {
        # Download failed - fall back to local cache before giving up
        if (Test-Path $script:fileListPath) {
            Write-Log "Failed to download file list, falling back to local cache." -Warning
            $Common.OfflineMode = $true
            return $true
        }
        Write-Log "Failed to download file list and no local cache found. Enabling Offline Mode." -Warning
        $Common.OfflineMode = $true
        return $false
    }

    $response.Content.Trim() | Out-File -FilePath $script:fileListPath -Force -ErrorAction SilentlyContinue
    $Common.AzureFileList = $response.Content.Trim() | ConvertFrom-Json -ErrorAction Stop
    Write-Log "File list updated successfully." -LogOnly
    return $true
}

# ---- 4: Download productID.txt from Azure ----
function Get-ProductID {

    $productIDName = "productID.txt"
    $productIdPath = Join-Path (Get-MemlabsDataRoot) $productIDName

    if (Test-Path $productIdPath) {
        Write-Log "ProductID already exists at $productIdPath, skipping." -LogOnly
        return $true
    }

    # In offline mode, no local copy means we can't continue
    if ($Common.OfflineMode) {
        Write-Log "Get-ProductID: Offline mode and no local productID found at $productIdPath." -Warning
        return $false
    }

    Write-Log "Updating $productIDName from azure storage" -LogOnly
    $url = Get-StorageUrl -BaseUrl $StorageConfig.StorageLocation -FileName $productIDName
    $response = Invoke-StorageRequest -Url $url

    if (-not $response) {
        Write-Log "Failed to download Product ID. Enabling Offline Mode." -Warning
        $Common.OfflineMode = $true
        return $false
    }

    $response.Content.Trim() | Out-File -FilePath $productIdPath -Force -ErrorAction SilentlyContinue
    Write-Log "ProductID downloaded successfully." -LogOnly
    return $true
}

# ---- 5: Download local admin credentials from Azure ----
function Get-LocalAdminCredential {

    $username = "vmbuildadmin"
    $filePath = Join-Path $Common.CachePath "$username.txt"

    # Always try local cache first
    if (Test-Path $filePath -PathType Leaf) {
        Write-Log "Reading cached credentials from $filePath" -LogOnly
        $response = (Get-Content $filePath).Trim()
    }
    else {

        # In offline mode, no cached copy means we can't continue
        if ($Common.OfflineMode) {
            $Common.FatalError = "Get-LocalAdminCredential: Offline mode and no cached credentials found at $filePath."
            Write-Log $Common.FatalError -Warning
            return $false
        }

        Write-Log "Downloading credentials for $username from azure storage" -LogOnly
        $item = $Common.AzureFileList.OS | Where-Object { $_.id -eq $username }
        $url = Get-StorageUrl -BaseUrl $StorageConfig.StorageLocation -FileName $item.filename
        $result = Invoke-StorageRequest -Url $url

        if (-not $result) {
            Write-Log "Retrying credential download after 60 seconds..." -LogOnly
            Start-Sleep -Seconds 60
            $result = Invoke-StorageRequest -Url $url
        }

        if (-not $result) {
            $Common.FatalError = "Could not download default credentials from azure. Please check your token."
            return $false
        }

        $response = $result.Content.Trim()
        $response | Out-File $filePath -Force
    }

    if ([string]::IsNullOrWhiteSpace($response)) {
        $Common.FatalError = "Admin file from azure is empty."
        return $false
    }

    $s = ConvertTo-SecureString $response -AsPlainText -Force
    $Common.LocalAdmin = New-Object System.Management.Automation.PSCredential($username, $s)
    return $true
}