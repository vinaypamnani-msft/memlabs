function Get-LocaleMediaSource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [object] $LocaleDefinition,
        [Parameter(Mandatory = $true)]
        [string] $OperatingSystem
    )

    foreach ($source in @($LocaleDefinition.MediaSources | Where-Object { $null -ne $_ })) {
        if ($OperatingSystem -like $source.OperatingSystemPattern) { return $source }
    }
    return $null
}

function Get-LocaleDefinitionForOperatingSystem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [object] $LocaleDefinition,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $OperatingSystem
    )

    if (-not $LocaleDefinition) { return $null }
    $resolved = $LocaleDefinition | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json
    foreach ($property in @($resolved.LanguageCapabilitiesByOperatingSystem.PSObject.Properties)) {
        if ($OperatingSystem -like $property.Name) {
            $resolved | Add-Member -MemberType NoteProperty -Name 'LanguageCapabilities' -Value @($property.Value) -Force
            break
        }
    }
    return $resolved
}

function Update-CatalogLocaleSettings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $Config,
        [Parameter(Mandatory = $false)]
        [string] $CatalogPath = (Join-Path $PSScriptRoot 'LocaleCatalog.json')
    )

    if (-not (Test-Path -LiteralPath $CatalogPath)) { return }
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $targets = @($Config.vmOptions | Where-Object { $null -ne $_ })
    $targets += @($Config.virtualMachines | Where-Object { $null -ne $_ })
    foreach ($target in $targets) {
        $locale = [string]$target.locale
        if ([string]::IsNullOrWhiteSpace($locale)) { continue }
        $catalogEntry = $catalog.PSObject.Properties[$locale]
        if (-not $catalogEntry) { continue }
        $localeDefinition = Get-LocaleDefinitionForOperatingSystem -LocaleDefinition $catalogEntry.Value -OperatingSystem "$($target.operatingSystem)"
        $target | Add-Member -MemberType NoteProperty -Name 'localeSettings' -Value $localeDefinition -Force
    }
}

function Get-LocaleMediaFiles {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [object] $LocaleDefinition
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $languageTag = "$($LocaleDefinition.LanguageTag)".ToLowerInvariant()
    $files = @(Get-ChildItem -LiteralPath $Path -File -Filter '*.cab' -ErrorAction SilentlyContinue)
    $selected = @($files | Where-Object { $_.Name -ieq "Microsoft-Windows-Server-Language-Pack_x64_$languageTag.cab" })
    foreach ($capability in @($LocaleDefinition.LanguageCapabilities | Where-Object { $_ })) {
        $pattern = "^Microsoft-Windows-LanguageFeatures-$([regex]::Escape($capability))-$([regex]::Escape($languageTag))-Package~31bf3856ad364e35~amd64~~\.cab$"
        $selected += @($files | Where-Object { $_.Name -match $pattern })
    }
    return @($selected | Sort-Object FullName -Unique)
}

function Test-LocaleMediaFiles {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Files,
        [Parameter(Mandatory = $true)]
        [object] $LocaleDefinition,
        [Parameter(Mandatory = $false)]
        [switch] $VerifySignature
    )

    $expectedCount = 1 + @($LocaleDefinition.LanguageCapabilities | Where-Object { $_ }).Count
    if (@($Files | Where-Object { $null -ne $_ }).Count -ne $expectedCount) { return $false }

    if ($VerifySignature) {
        foreach ($file in $Files) {
            $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
                return $false
            }
        }
    }
    return $true
}

function Test-LocaleMediaIso {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [object] $Source
    )

    $isoFile = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $isoFile -or $isoFile.Length -ne [int64]$Source.Size) { return $false }

    if (-not $script:LocaleMediaIsoValidationCache) { $script:LocaleMediaIsoValidationCache = @{} }
    $cacheKey = '{0}|{1}|{2}|{3}' -f $isoFile.FullName.ToLowerInvariant(), $isoFile.Length, $isoFile.LastWriteTimeUtc.Ticks, $Source.SHA256
    if ($script:LocaleMediaIsoValidationCache.ContainsKey($cacheKey)) {
        return $true
    }

    $stream = $null
    try {
        $stream = [IO.File]::Open($isoFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $actualHash = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }
        $valid = $actualHash -eq $Source.SHA256
        if ($valid) {
            $script:LocaleMediaIsoValidationCache[$cacheKey] = $stream
            $stream = $null
        }
        return $valid
    }
    catch {
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Clear-LocaleMediaIsoValidationCache {
    foreach ($entry in @($script:LocaleMediaIsoValidationCache.Values | Where-Object { $null -ne $_ })) {
        $entry.Dispose()
    }
    $script:LocaleMediaIsoValidationCache = @{}
}

function Get-LocaleMediaMutexName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $normalizedPath = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $pathHash = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedPath)))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
    return "Global\MemLabsLocaleMedia-$($pathHash.Substring(0, 16))"
}

function Initialize-LocaleMedia {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Locale,
        [Parameter(Mandatory = $true)]
        [string] $OperatingSystem,
        [Parameter(Mandatory = $false)]
        [switch] $WhatIf,
        [Parameter(Mandatory = $false)]
        [switch] $RetainIsoValidation
    )

    if ($Locale -eq 'en-US') { return $true }

    $catalogPath = Join-Path $PSScriptRoot 'LocaleCatalog.json'
    try {
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "Could not load locale catalog '$catalogPath': $($_.Exception.Message)" -Failure
        return $false
    }

    $localeDefinition = Get-LocaleDefinitionForOperatingSystem -LocaleDefinition $catalog.$Locale -OperatingSystem $OperatingSystem
    if (-not $localeDefinition) {
        # Legacy custom locales continue to use manually supplied CABs.
        $legacyPath = Join-Path (Join-Path $Common.ConfigPath 'locales') $OperatingSystem
        return [bool](Get-ChildItem -LiteralPath $legacyPath -File -Filter '*.cab' -ErrorAction SilentlyContinue | Select-Object -First 1)
    }

    $destination = Join-Path (Join-Path $Common.ConfigPath 'locales') $OperatingSystem
    $cachedFiles = @(Get-LocaleMediaFiles -Path $destination -LocaleDefinition $localeDefinition)
    if (Test-LocaleMediaFiles -Files $cachedFiles -LocaleDefinition $localeDefinition -VerifySignature) { return $true }

    $source = Get-LocaleMediaSource -LocaleDefinition $localeDefinition -OperatingSystem $OperatingSystem
    if (-not $source) {
        return [bool](Get-ChildItem -LiteralPath $destination -File -Filter '*.cab' -ErrorAction SilentlyContinue | Select-Object -First 1)
    }

    $isoPath = Join-Path $Common.AzureFilesPath $source.IsoRelativePath
    if ($WhatIf -and -not $Common.OfflineMode) { return $true }

    $mutexName = Get-LocaleMediaMutexName -Path $isoPath
    $mediaMutex = [Threading.Mutex]::new($false, $mutexName)
    $lockTaken = $false
    $mount = $null
    $stagePath = Join-Path $Common.TempPath ("locale-$Locale-" + [guid]::NewGuid().ToString('N'))
    try {
        try {
            $lockTaken = $mediaMutex.WaitOne([TimeSpan]::FromMinutes(30))
        }
        catch [Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            throw "Timed out waiting for shared locale media '$isoPath'."
        }

        $cachedFiles = @(Get-LocaleMediaFiles -Path $destination -LocaleDefinition $localeDefinition)
        if (Test-LocaleMediaFiles -Files $cachedFiles -LocaleDefinition $localeDefinition -VerifySignature) { return $true }

        $cachedIsoValid = Test-LocaleMediaIso -Path $isoPath -Source $source
        if ($Common.OfflineMode -and -not $cachedIsoValid) {
            Write-Log "Locale '$Locale' for '$OperatingSystem' requires Microsoft media, but MemLabs is offline." -Warning
            return $false
        }

        if (-not $cachedIsoValid) {
            $replaceInvalidCache = Test-Path -LiteralPath $isoPath
            $download = Get-FileWithHash -FileName $source.IsoRelativePath -FileDisplayName "$OperatingSystem Languages and Optional Features ISO" -FileUrl $source.Url -ExpectedHash $source.SHA256 -HashAlg 'SHA256' -UseBITS -ForceDownload:$replaceInvalidCache
            if (-not $download.success) { return $false }
            if (-not (Test-LocaleMediaIso -Path $isoPath -Source $source)) {
                throw "Locale media '$isoPath' failed direct validation after download."
            }
        }
        if ($WhatIf) { return $true }

        $mount = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
        $volume = $mount | Get-Volume
        if ($volume.FileSystemLabel -ne $source.VolumeLabel) {
            throw "Unexpected ISO volume label '$($volume.FileSystemLabel)' (expected '$($source.VolumeLabel)')."
        }

        $repositoryPath = Join-Path "$($volume.DriveLetter):\" $source.RepositoryPath
        $sourceFiles = @(Get-LocaleMediaFiles -Path $repositoryPath -LocaleDefinition $localeDefinition)
        if (-not (Test-LocaleMediaFiles -Files $sourceFiles -LocaleDefinition $localeDefinition -VerifySignature)) {
            throw "The ISO does not contain the complete Microsoft-signed $Locale package set."
        }

        $null = New-Item -Path $stagePath -ItemType Directory -Force
        foreach ($file in $sourceFiles) {
            Copy-Item -LiteralPath $file.FullName -Destination $stagePath -Force -ErrorAction Stop
        }
        $stagedFiles = @(Get-LocaleMediaFiles -Path $stagePath -LocaleDefinition $localeDefinition)
        if (-not (Test-LocaleMediaFiles -Files $stagedFiles -LocaleDefinition $localeDefinition -VerifySignature)) {
            throw 'The staged locale package set failed validation.'
        }

        $null = New-Item -Path $destination -ItemType Directory -Force
        foreach ($file in $stagedFiles) {
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $file.Name) -Force -ErrorAction Stop
        }
        $manifest = [pscustomobject]@{
            Locale          = $Locale
            OperatingSystem = $OperatingSystem
            Source          = $source.Url
            IsoSHA256       = $source.SHA256
            Packages        = @($stagedFiles.Name)
        }
        $manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $destination "_$Locale.media.json") -Encoding UTF8 -Force
        Write-Log "Prepared $($stagedFiles.Count) Microsoft-signed $Locale packages for $OperatingSystem." -Success
        return $true
    }
    catch {
        Write-Log "Could not prepare $Locale media for $OperatingSystem`: $($_.Exception.Message)" -Failure
        return $false
    }
    finally {
        try {
            try {
                if ($mount) { $null = Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue }
            }
            finally {
                Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            try {
                if ($lockTaken) { $mediaMutex.ReleaseMutex() }
            }
            finally {
                $mediaMutex.Dispose()
                if (-not $RetainIsoValidation) { Clear-LocaleMediaIsoValidationCache }
            }
        }
    }
}

function Initialize-LocaleMediaForPhase2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $DeployConfig
    )

    $requests = @($DeployConfig.virtualMachines | Where-Object {
            -not $_.Hidden -and $_.operatingSystem
        } | ForEach-Object {
            $vm = $_
            $locale = if ($vm.locale) {
                [string]$vm.locale
            }
            elseif ($DeployConfig.domainDefaults.DefaultLocale) {
                [string]$DeployConfig.domainDefaults.DefaultLocale
            }
            elseif ($DeployConfig.vmOptions.locale) {
                [string]$DeployConfig.vmOptions.locale
            }
            else {
                'en-US'
            }
            $acquisition = if ($vm.localeAcquisition) { [string]$vm.localeAcquisition } else { 'Media' }
            if ($locale -ne 'en-US' -and $acquisition -ne 'WindowsUpdate') {
                [pscustomobject]@{ Locale = $locale; OperatingSystem = [string]$vm.operatingSystem }
            }
        } | Sort-Object Locale, OperatingSystem -Unique)

    try {
        foreach ($request in $requests) {
            if (-not (Initialize-LocaleMedia -Locale $request.Locale -OperatingSystem $request.OperatingSystem -RetainIsoValidation)) {
                Write-Log "Could not prepare $($request.Locale) language media for $($request.OperatingSystem) before Phase 2 worker dispatch." -Failure
                return $false
            }
        }
        return $true
    }
    finally {
        Clear-LocaleMediaIsoValidationCache
    }
}
