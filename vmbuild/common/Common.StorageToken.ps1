#Common.StorageToken.ps1
function Get-StorageToken {
    param(
        [int]$MinutesRemaining = 30
    )

    # ---- Check cache ----
    if ($global:TokenCache) {
        $minutesLeft = ($global:TokenCache.ExpiresAt - [System.DateTimeOffset]::UtcNow).TotalMinutes
        if ($minutesLeft -gt $MinutesRemaining) {
            Write-Host "✅ Using cached token ($([math]::Round($minutesLeft)) minutes remaining)"
            return $global:TokenCache
        }
        Write-Host "Cached token expiring soon ($([math]::Round($minutesLeft)) minutes left), refreshing..."
    }

    # ---- Load config ----
    if (-not $global:common.StorageConfigLocation ) {
        Write-Error "Get-StorageToken: `$global:common.ConfigPath is not set."
        return $null
    }

    if (-not (Test-Path $global:common.StorageConfigLocation )) {
        Write-Error "Get-StorageToken: Config file not found at '$($global:common.StorageConfigLocation )'."
        return $null
    }

    try {
        $config = Get-Content $global:common.StorageConfigLocation  -Raw | ConvertFrom-Json
    }
    catch {
        Write-Error "Get-StorageToken: Failed to parse config JSON at '$($global:common.StorageConfigLocation )'.`n$_"
        return $null
    }

    foreach ($field in @("tenantId", "clientId", "pBase64", "pword", "xKey")) {
        if (-not $config.$field) {
            Write-Error "Get-StorageToken: Config is missing required field '$field'. Regenerate your config file."
            return $null
        }
    }

    # ---- Decode certificate ----
    try {
        $keyBytes = [Convert]::FromBase64String($config.xKey)
        $pfxBytes = Unprotect-String $config.pBase64 $keyBytes
        $pfxPassword = [Text.Encoding]::UTF8.GetString($(Unprotect-String $config.pword $keyBytes))
    }
    catch {
        Write-Error "Get-StorageToken: Failed to decode certificate data from config.`n$_"
        return $null
    }

    try {
        $tempPfx = [System.IO.Path]::GetTempFileName() + ".pfx"
        [System.IO.File]::WriteAllBytes($tempPfx, $pfxBytes)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $tempPfx,
            $pfxPassword,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet -bor
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        )
    }
    catch {
        Write-Error "Get-StorageToken: Failed to load certificate.`n$_"
        return $null
    }
    finally {
        Remove-Item $tempPfx -ErrorAction SilentlyContinue
    }

    if (-not $cert.HasPrivateKey) {
        Write-Error "Get-StorageToken: Certificate has no private key. Re-export the PFX with 'Include private key' checked."
        return $null
    }

    # ---- Check expiry ----
    $now = [System.DateTimeOffset]::UtcNow
    if ($now.DateTime -gt $cert.NotAfter) {
        Write-Error @"
Get-StorageToken: Certificate has EXPIRED ($($cert.NotAfter.ToString('yyyy-MM-dd'))).
To fix:
  1. Generate a new certificate with New-SelfSignedCertificate
  2. Upload the new .cer to Azure Portal > Memlabs Data Downloader > Certificates & secrets
  3. Run Generate-Config.ps1 with the new .pfx
"@
        return $null
    }

    $daysUntilExpiry = ($cert.NotAfter - $now.DateTime).Days
    if ($daysUntilExpiry -le 30) {
        Write-Warning "Get-StorageToken: Certificate expires in $daysUntilExpiry day(s) ($($cert.NotAfter.ToString('yyyy-MM-dd'))). Plan to renew soon."
    }

    # ---- Build JWT ----
    try {
        $exp = $now.AddMinutes(60)

        $header = @{
            alg = "RS256"
            typ = "JWT"
            x5t = [Convert]::ToBase64String($cert.GetCertHash())
        } | ConvertTo-Json -Compress

        $claims = @{
            aud = "https://login.microsoftonline.com/$($config.tenantId)/oauth2/v2.0/token"
            iss = $config.clientId
            sub = $config.clientId
            jti = [guid]::NewGuid().ToString()
            nbf = $now.ToUnixTimeSeconds()
            exp = $exp.ToUnixTimeSeconds()
        } | ConvertTo-Json -Compress

        $headerB64 = ConvertTo-Base64Url([Text.Encoding]::UTF8.GetBytes($header))
        $claimsB64 = ConvertTo-Base64Url([Text.Encoding]::UTF8.GetBytes($claims))
        $toSign = "$headerB64.$claimsB64"
        $toSignBytes = [Text.Encoding]::UTF8.GetBytes($toSign)

        Add-Type -AssemblyName System.Security
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        $rsaCng = [System.Security.Cryptography.RSACng]$rsa

        $signature = ConvertTo-Base64Url($rsaCng.SignData(
                $toSignBytes,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
            ))

        $jwt = "$toSign.$signature"
    }
    catch {
        Write-Error "Get-StorageToken: Failed to build or sign JWT.`n$_"
        return $null
    }

   # ---- Acquire token ----
# Temporarily clear AAD-related environment variables to prevent
# ambient user credentials from being picked up by the token request
try {
    $savedVars = @{}
    $varsToSuppress = @(
        'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_TENANT_ID',
        'AZURE_USERNAME', 'AZURE_PASSWORD', 'MSI_ENDPOINT', 'MSI_SECRET',
        'IDENTITY_ENDPOINT', 'IDENTITY_HEADER', 'IMDS_ENDPOINT'
    )
    foreach ($var in $varsToSuppress) {
        $savedVars[$var] = [System.Environment]::GetEnvironmentVariable($var)
        [System.Environment]::SetEnvironmentVariable($var, $null)
    }

    $tokenResponse = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$($config.tenantId)/oauth2/v2.0/token" `
        -Method POST `
        -ContentType "application/x-www-form-urlencoded" `
        -UseBasicParsing `
        -UseDefaultCredentials:$false `
        -Body @{
            client_id             = $config.clientId
            client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
            client_assertion      = $jwt
            scope                 = "https://storage.azure.com/.default"
            grant_type            = "client_credentials"
        }
} catch {
    $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
    switch -Wildcard ($errorDetail.error_codes) {
        "*700027*"  { Write-Error "Get-StorageToken: JWT signature invalid. Certificate may not match Azure registration." }
        "*700016*"  { Write-Error "Get-StorageToken: Application '$($config.clientId)' not found in tenant '$($config.tenantId)'." }
        "*7000215*" { Write-Error "Get-StorageToken: Invalid certificate. It may have been deleted from the app registration." }
        "*53003*"   { Write-Error "Get-StorageToken: Blocked by Conditional Access policy. Ask your admin to exclude the 'Memlabs Data Downloader' service principal from CA policies." }
        default     { Write-Error "Get-StorageToken: Failed to acquire token: $($errorDetail.error_description)" }
    }
    Write-Error $_.ErrorDetails.Message
    return $null
} finally {
    # Restore suppressed environment variables
    foreach ($var in $varsToSuppress) {
        if ($null -ne $savedVars[$var]) {
            [System.Environment]::SetEnvironmentVariable($var, $savedVars[$var])
        }
    }
}

    # ---- Store in global cache and return ----
    $expiresAt = [System.DateTimeOffset]::UtcNow.AddSeconds($tokenResponse.expires_in)
    $global:TokenCache = [PSCustomObject]@{
        AccessToken = $tokenResponse.access_token
        ExpiresAt   = $expiresAt
        ExpiresIn   = $tokenResponse.expires_in
        AcquiredAt  = [System.DateTimeOffset]::UtcNow
    }

    Write-Host "✅ New token acquired (expires at $($expiresAt.ToString('HH:mm:ss')) UTC)"
    return $global:TokenCache
}

# ---- Helper: Build a URL, appending SAS token if not using bearer auth ----
function Get-StorageUrl {
    param(
        [string]$BaseUrl,
        [string]$FileName
    )

    $url = "$BaseUrl/$FileName"

    if ($StorageConfig.UseBearerAuth) {
        return $url
    }
    else {
        return "$url`?$($StorageConfig.StorageToken)"
    }
}

# ---- Helper: Invoke-WebRequest with retry, getting token via Get-StorageToken if needed ----
function Invoke-StorageRequest {
    param(
        [string]$Url,
        [int]$RetrySeconds = 5
    )

    $headers = @{}
    if ($StorageConfig.UseBearerAuth) {
        $token = Get-StorageToken
        if ($null -eq $token) {
            Write-Log "Invoke-StorageRequest: Failed to get bearer token from Get-StorageToken."
            return $null
        }
        $headers["Authorization"] = "Bearer $($token.AccessToken)"
        $headers["x-ms-version"] = "2020-04-08"
    }

    try {
        return Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Log "Invoke-StorageRequest: First attempt failed, retrying in $RetrySeconds seconds..."
        Start-Sleep -Seconds $RetrySeconds
        try {
            return Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -ErrorAction Stop
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
        Where-Object { $_.Name -match "_storageConfig\d{4}\.json" } |
        Sort-Object Name -Descending

    if (-not $configFiles) {
        $Common.FatalError = "Get-StorageConfig: No _storageConfigXXXX.json files found in '$($Common.ConfigPath)'. Refer to internal documentation."
        Write-Log $Common.FatalError
        return $false
    }

    Write-Log "Get-StorageConfig: Found $($configFiles.Count) config file(s): $($configFiles.Name -join ', ')" -LogOnly

    # ---- Try each config file in descending order (newest first) ----
    $config     = $null
    $configPath = $null
    $authSet    = $false

    foreach ($file in $configFiles) {
        Write-Log "Get-StorageConfig: Trying $($file.Name)..." -LogOnly

        try {
            $candidate = Get-Content -Path $file.FullName -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log "Get-StorageConfig: Failed to parse $($file.Name), skipping." -Warning
            continue
        }

        # ---- Validate storage location fields ----
        $hasStorageAccount  = -not [string]::IsNullOrWhiteSpace($candidate.storageAccount)
        $hasStorageLocation = -not [string]::IsNullOrWhiteSpace($candidate.storageLocation)

        if (-not $hasStorageAccount -and -not $hasStorageLocation) {
            Write-Log "Get-StorageConfig: $($file.Name) has no storageAccount or storageLocation, skipping." -LogOnly
            continue
        }

        if ($hasStorageAccount -and [string]::IsNullOrWhiteSpace($candidate.containerName)) {
            Write-Log "Get-StorageConfig: $($file.Name) has storageAccount but no containerName, skipping." -LogOnly
            continue
        }

        # ---- Validate auth fields ----
        $candidateBearerAvailable = (-not [string]::IsNullOrWhiteSpace($candidate.pBase64))   -and
                                    (-not [string]::IsNullOrWhiteSpace($candidate.pword))     -and
                                    (-not [string]::IsNullOrWhiteSpace($candidate.xKey))      -and
                                    (-not [string]::IsNullOrWhiteSpace($candidate.tenantId))  -and
                                    (-not [string]::IsNullOrWhiteSpace($candidate.clientId))

        $candidateSasAvailable = -not [string]::IsNullOrWhiteSpace($candidate.storageToken)

        if (-not $candidateBearerAvailable -and -not $candidateSasAvailable) {
            Write-Log "Get-StorageConfig: $($file.Name) has no valid auth fields, skipping." -LogOnly
            continue
        }

        # ---- Derive StorageLocation for this candidate ----
        $candidateStorageLocation = if (-not [string]::IsNullOrWhiteSpace($candidate.storageAccount)) {
            "https://$($candidate.storageAccount).blob.core.windows.net/$($candidate.containerName)"
        } else {
            $candidate.storageLocation
        }

        # ---- Store script-scoped vars ----
        # Set these before auth attempts so URL builders work correctly
        $script:storageConfigName = $file.Name
        $script:fileListName      = if ($Common.DevBranch) { "_fileList_develop.json" } else { "_fileList.json" }
        $script:fileListPath      = Join-Path $Common.AzureFilesPath $script:fileListName

        Write-Log "Get-StorageConfig: Trying auth for $($file.Name) (Bearer: $candidateBearerAvailable, SAS: $candidateSasAvailable)..." -LogOnly

        # ---- Try bearer first ----
        if ($candidateBearerAvailable) {
            $Common.StorageConfigLocation = $file.FullName
            $StorageConfig.StorageLocation = $candidateStorageLocation
            $token = Get-StorageToken
            if ($null -ne $token) {
                $StorageConfig.UseBearerAuth = $true
                $StorageConfig.StorageToken  = $null
                $config     = $candidate
                $configPath = $file.FullName
                $authSet    = $true
                Write-Log "Get-StorageConfig: Storage auth mode: Bearer (Service Principal) via $($file.Name)" -LogOnly
                break
            } else {
                $Common.StorageConfigLocation = $null
                Write-Log "Get-StorageConfig: Bearer auth failed for $($file.Name)." -Warning
            }
        }

        # ---- Try SAS ----
        if (-not $authSet -and $candidateSasAvailable) {
            $StorageConfig.UseBearerAuth = $false
            $StorageConfig.StorageToken  = $candidate.storageToken
            $StorageConfig.StorageLocation = $candidateStorageLocation

            Write-Log "Get-StorageConfig: Testing SAS token for $($file.Name)..." -LogOnly
            $testUrl      = Get-StorageUrl -BaseUrl $candidateStorageLocation -FileName $script:fileListName
            $testResponse = Invoke-StorageRequest -Url $testUrl
            if ($null -ne $testResponse) {
                $StorageConfig.UseBearerAuth = $false
                $config     = $candidate
                $configPath = $file.FullName
                $authSet    = $true
                Write-Log "Get-StorageConfig: Storage auth mode: SAS Token via $($file.Name)" -LogOnly
                break
            } else {
                Write-Log "Get-StorageConfig: SAS token failed for $($file.Name)." -Warning
                # Reset storage location so next iteration starts clean
                $StorageConfig.StorageLocation = $null
                $StorageConfig.StorageToken    = $null
            }
        }

        Write-Log "Get-StorageConfig: Both auth methods failed for $($file.Name), trying next config file..." -Warning
    }

    if (-not $authSet) {
        $Common.FatalError = "Get-StorageConfig: Could not authenticate using any available config file."
        Write-Log $Common.FatalError -Warning
        return $false
    }

    # ---- Finalize ----
    Write-Log "Get-StorageConfig: StorageLocation: $($StorageConfig.StorageLocation)" -LogOnly

    $newestConfigFile            = $configFiles[0]
    $script:newStorageConfigName = $newestConfigFile.Name
    $script:newConfigPath        = $newestConfigFile.FullName
    $script:GetNewStorageConfig  = ($file.Name -ne $configFiles[0].Name)

    return $true
}

# ---- 6: Windows 2025 upgrade cleanup ----
function Remove-Windows2025UpgradeFiles {

    if ([Environment]::OSVersion.Version -lt [System.Version]"10.0.26100.0") {
        return
    }

    Write-Log "Testing upgrade to 2025 cleanup" -LogOnly

    $upgradePath = "C:\temp\Upgrade2025"
    $supportFile = Join-Path $Common.AzureFilesPath "support\WindowsServer2025.zip"

    if (Test-Path $upgradePath) {
        Write-Host "Removing 2025 Upgrade Support files - $upgradePath"
        Remove-Item -Path $upgradePath -Recurse -Force -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue
    }

    if (Test-Path $supportFile) {
        Write-Host "Removing 2025 Upgrade Support files - $supportFile"
        Remove-Item -Path $supportFile -Force -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue
    }
}

function Initialize-Storage {

    $pp = $ProgressPreference
    $vp = $VerbosePreference
    $ProgressPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'

    try {
        # Load local config and determine auth mode
        $storageConfigLoaded = Get-StorageConfig
        if (-not $storageConfigLoaded) {
            Write-Log "Get-StorageConfig failed — attempting offline mode using local cached files." -Warning
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

        # Skip all network operations if running inside a job
        if ($InJob.IsPresent) {
            Write-Log "Skipped updating from azure storage, running inside a job." -Verbose
            if (-not (Update-FileList)) { return $false }
            if (-not (Get-LocalAdminCredential)) { return $false }
            return $true
        }

        # Skip Update-StorageConfigFile entirely if storage config failed
        # — we have no valid StorageLocation to build URLs with
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

    # Nothing to do if we're already using the newest config with bearer auth
    if ($StorageConfig.UseBearerAuth -and ($script:storageConfigName -eq $script:downloadConfigName)) {
        Write-Log "Update-StorageConfigFile: Already using $($script:downloadConfigName) with bearer auth, nothing to do." -LogOnly
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
            Write-Log "Update-StorageConfigFile: Could not download $($script:downloadConfigName) — continuing with existing config." -LogOnly
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

    Write-Log "Update-StorageConfigFile: Re-initialized successfully. Auth mode: $(if ($StorageConfig.UseBearerAuth) { 'Bearer' } else { 'SAS' })" -LogOnly
    return $true
}

# ---- 3: Download updated file list from Azure ----
function Update-FileList {

    # In offline mode, try to load from local cache only
    if ($Common.OfflineMode) {
        if (Test-Path $script:fileListPath) {
            Write-Log "Update-FileList: Offline mode, loading from local cache at $($script:fileListPath)." -Warning
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
        # Download failed — fall back to local cache before giving up
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
    $productIdPath = "E:\$productIDName"

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
function Unprotect-String($obfuscatedBase64, $keyBytes) {
    $bytes = [Convert]::FromBase64String($obfuscatedBase64)
    $result = New-Object byte[] $bytes.Length
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $result[$i] = $bytes[$i] -bxor $keyBytes[$i % $keyBytes.Length]
    }
    return $result
}
function ConvertTo-Base64Url($bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}