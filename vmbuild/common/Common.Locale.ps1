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

function Initialize-LocaleMedia {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Locale,
        [Parameter(Mandatory = $true)]
        [string] $OperatingSystem,
        [Parameter(Mandatory = $false)]
        [switch] $WhatIf
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

    $localeDefinition = $catalog.$Locale
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
    if ($Common.OfflineMode) {
        Write-Log "Locale '$Locale' for '$OperatingSystem' requires Microsoft media, but MemLabs is offline." -Warning
        return $false
    }

    $isoPath = Join-Path $Common.AzureFilesPath $source.IsoRelativePath
    $download = Get-FileWithHash -FileName $source.IsoRelativePath -FileDisplayName "$OperatingSystem Languages and Optional Features ISO" -FileUrl $source.Url -ExpectedHash $source.SHA256 -HashAlg 'SHA256' -UseBITS -WhatIf:$WhatIf
    if (-not $download.success) { return $false }
    if ($WhatIf) { return $true }

    $isoFile = Get-Item -LiteralPath $isoPath -ErrorAction SilentlyContinue
    if (-not $isoFile -or $isoFile.Length -ne [int64]$source.Size) {
        Write-Log "Locale media '$isoPath' has unexpected size. Expected $($source.Size), observed $($isoFile.Length)." -Failure
        return $false
    }

    $mount = $null
    $stagePath = Join-Path $Common.TempPath ("locale-$Locale-" + [guid]::NewGuid().ToString('N'))
    try {
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
        if ($mount) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
