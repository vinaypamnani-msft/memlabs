# Keep ODBC Driver 18 aligned with the version declared in filelist UrlsMeta.

$odbcTargetVersion = "$($Common.AzureFileList.UrlsMeta.ODBC.version)".Trim()
$odbcCatalogFwlink = "$($Common.AzureFileList.UrlsMeta.ODBC.fwlink)".Trim()
[version]$parsedOdbcTarget = $null
[int]$parsedOdbcFwlink = 0

# Version and URL are one atomic catalog pair. Fall back together so an older
# main-branch file list cannot combine the 18.6 floor with the old 18.4 fwlink.
if (-not ([version]::TryParse($odbcTargetVersion, [ref]$parsedOdbcTarget) -and
        [int]::TryParse($odbcCatalogFwlink, [ref]$parsedOdbcFwlink) -and $parsedOdbcFwlink -gt 0)) {
    if ($null -ne $Common.AzureFileList.UrlsMeta.ODBC) {
        Write-Warning "ODBC UrlsMeta is incomplete or invalid; enforcing compatibility pair 18.6.2.1/linkid=2358430."
    }
    $odbcTargetVersion = '18.6.2.1'
    $parsedOdbcFwlink = 2358430
}
$odbcDownloadUrl = "https://go.microsoft.com/fwlink/?linkid=$parsedOdbcFwlink"
$vcRedistDownloadUrl = "$($Common.AzureFileList.Urls.VCredist)".Trim()
if ([string]::IsNullOrWhiteSpace($vcRedistDownloadUrl)) {
    $vcRedistDownloadUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
}

$Fix_ODBC18 = {
    param([string]$TargetVersion, [string]$DownloadUrl, [string]$VcRedistUrl)

    function Get-InstalledOdbc18Version {
        param([scriptblock]$RegistryValueReader)

        $values = [System.Collections.Generic.List[string]]::new()
        $driverRegistered = $false
        if ($RegistryValueReader) {
            foreach ($value in @(& $RegistryValueReader)) {
                if (-not [string]::IsNullOrWhiteSpace("$value")) { $values.Add("$value") }
            }
            $driverRegistered = $true
        }
        else {
            try {
                $state = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\MSODBCSQL18' -ErrorAction Stop
                $versionProperty = $state.PSObject.Properties['InstalledVersion']
                if ($versionProperty -and -not [string]::IsNullOrWhiteSpace("$($versionProperty.Value)")) {
                    $values.Add("$($versionProperty.Value)")
                }
            }
            catch { }
            foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
                $baseKey = $null
                $subKey = $null
                $odbcKey = $null
                $uninstallKey = $null
                try {
                    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                        [Microsoft.Win32.RegistryHive]::LocalMachine,
                        $view
                    )
                    $subKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\MSODBCSQL18')
                    $value = if ($subKey) { $subKey.GetValue('InstalledVersion', $null) } else { $null }
                    if (-not [string]::IsNullOrWhiteSpace("$value")) {
                        $values.Add("$value")
                    }

                    $odbcKey = $baseKey.OpenSubKey('SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server')
                    $value = if ($odbcKey) { $odbcKey.GetValue('Version', $null) } else { $null }
                    if (-not [string]::IsNullOrWhiteSpace("$value")) { $values.Add("$value") }
                    $driverPath = if ($odbcKey) { "$($odbcKey.GetValue('Driver', ''))".Trim() } else { '' }
                    if ($driverPath -and (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
                        $driverRegistered = $true
                    }

                    $uninstallKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
                    if ($uninstallKey) {
                        foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                            $productKey = $null
                            try {
                                $productKey = $uninstallKey.OpenSubKey($subKeyName)
                                if ($productKey -and
                                    "$($productKey.GetValue('DisplayName', ''))" -eq 'Microsoft ODBC Driver 18 for SQL Server') {
                                    $value = $productKey.GetValue('DisplayVersion', $null)
                                    if (-not [string]::IsNullOrWhiteSpace("$value")) { $values.Add("$value") }
                                }
                            }
                            catch { }
                            finally {
                                if ($productKey) { $productKey.Dispose() }
                            }
                        }
                    }
                }
                catch { }
                finally {
                    if ($uninstallKey) { $uninstallKey.Dispose() }
                    if ($odbcKey) { $odbcKey.Dispose() }
                    if ($subKey) { $subKey.Dispose() }
                    if ($baseKey) { $baseKey.Dispose() }
                }
            }
        }

        if (-not $driverRegistered) { return $null }
        $versions = foreach ($value in $values) {
            [version]$parsed = $null
            if ([version]::TryParse($value.Trim(), [ref]$parsed)) { $parsed }
        }
        return @($versions | Sort-Object -Descending | Select-Object -First 1)[0]
    }
    function Get-MsiVersion {
        param([string]$Path, [hashtable]$InstallerState)
        $installer = $null
        $database = $null
        $view = $null
        $record = $null
        $codeView = $null
        $codeRecord = $null
        $upgradeView = $null
        $upgradeRecord = $null
        $relatedCodes = $null
        $summaryInfo = $null
        try {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
            $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @('SELECT `Value` FROM `Property` WHERE `Property`=''ProductVersion'''))
            $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if (-not $record) { throw 'MSI Property table has no ProductVersion row' }
            $versionText = [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
            if ($null -ne $InstallerState) {
                $InstallerState.Clear()
                $codeView = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @('SELECT `Value` FROM `Property` WHERE `Property`=''ProductCode'''))
                $null = $codeView.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $codeView, $null)
                $codeRecord = $codeView.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $codeView, $null)
                if (-not $codeRecord) { throw 'MSI Property table has no ProductCode row' }
                $productCode = [string]$codeRecord.GetType().InvokeMember('StringData', 'GetProperty', $null, $codeRecord, @(1))
                $summaryInfo = $database.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $database, @(0))
                $InstallerState.ProductCode = ([guid]$productCode).ToString('B')
                $InstallerState.PackageCode = ([guid]$summaryInfo.GetType().InvokeMember('Property', 'GetProperty', $null, $summaryInfo, @(9))).ToString('B')
                $productState = $installer.GetType().InvokeMember('ProductState', 'GetProperty', $null, $installer, @($productCode))
                $InstallerState.State = [int]$productState
                $InstallerState.Installed = $productState -eq 5
                $InstallerState.CoreState = -1
                $InstallerState.PackageName = 'msodbcsql.msi'
                if ($InstallerState.Installed) {
                    $InstallerState.CoreState = $installer.GetType().InvokeMember('FeatureState', 'GetProperty', $null, $installer, @($productCode, 'SQL_SQLODBC_CORE'))
                }
                if ($productState -in @(1, 5)) {
                    $InstallerState.PackageName = [string]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($productCode, 'PackageName'))
                }
                $packageName = "$($InstallerState.PackageName)"
                if ([string]::IsNullOrWhiteSpace($packageName) -or
                    $packageName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                    [IO.Path]::GetExtension($packageName) -ine '.msi') {
                    throw "ODBC MSI reports an invalid source package name '$packageName'"
                }
                $upgradeView = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @('SELECT `Value` FROM `Property` WHERE `Property`=''UpgradeCode'''))
                $null = $upgradeView.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $upgradeView, $null)
                $upgradeRecord = $upgradeView.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $upgradeView, $null)
                if (-not $upgradeRecord) { throw 'MSI Property table has no UpgradeCode row' }
                $upgradeCode = [string]$upgradeRecord.GetType().InvokeMember('StringData', 'GetProperty', $null, $upgradeRecord, @(1))
                $InstallerState.UpgradeCode = ([guid]$upgradeCode).ToString('B')
                $relatedCodes = $installer.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @($upgradeCode))
                $relatedProducts = [System.Collections.Generic.List[object]]::new()
                foreach ($relatedCode in $relatedCodes) {
                    if ($relatedCode -ieq $productCode) { continue }
                    $relatedState = $installer.GetType().InvokeMember('ProductState', 'GetProperty', $null, $installer, @($relatedCode))
                    # VersionString is unavailable for advertised products.
                    [uint32]$packedVersion = $installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($relatedCode, 'Version'))
                    $relatedVersion = [version]::new(
                        [int]($packedVersion -shr 24), [int](($packedVersion -shr 16) -band 255), [int]($packedVersion -band 65535))
                    $cachedPackage = if ($relatedState -eq 5) {
                        [string]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($relatedCode, 'LocalPackage'))
                    } else { '' }
                    $relatedProducts.Add([pscustomobject]@{
                            ProductCode = ([guid]$relatedCode).ToString('B')
                            Version = $relatedVersion
                            State = [int]$relatedState
                            PackageCode = ([guid]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($relatedCode, 'PackageCode'))).ToString('B')
                            UpgradeCode = $InstallerState.UpgradeCode
                            PackageName = [string]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($relatedCode, 'PackageName'))
                            Language = [int]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($relatedCode, 'Language'))
                            CachedPackagePresent = [bool]($cachedPackage -and (Test-Path -LiteralPath $cachedPackage -PathType Leaf))
                        })
                }
                $InstallerState.RelatedProducts = $relatedProducts.ToArray()
            }
            return $versionText
        }
        finally {
            foreach ($comObject in @($summaryInfo, $relatedCodes, $upgradeRecord, $upgradeView, $codeRecord, $codeView, $record, $view, $database, $installer)) {
                if ($comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
                    catch { Write-Verbose "Could not release Windows Installer COM object: $($_.Exception.Message)" }
                }
            }
        }
    }
    function Save-OdbcRecoveryInstaller {
        param([Parameter(Mandatory)]$Product)

        $releaseLinks = @{
            '18.0.1' = 2186919; '18.1.1' = 2202930; '18.1.2' = 2214634
            '18.2.1' = 2223270; '18.2.2' = 2239549; '18.3.1' = 2242886
            '18.3.2' = 2249006; '18.3.3' = 2266640; '18.4.1' = 2280794
            '18.5.1' = 2307162; '18.5.2' = 2335671; '18.6.1' = 2345415
            '18.6.2' = 2358430
        }
        $release = $Product.Version.ToString(3)
        if (-not $releaseLinks.ContainsKey($release)) {
            throw "No verified Microsoft recovery source is known for legacy ODBC $release ($($Product.ProductCode))"
        }
        $packageName = "$($Product.PackageName)"
        if ([string]::IsNullOrWhiteSpace($packageName) -or
            $packageName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            [IO.Path]::GetExtension($packageName) -ine '.msi') {
            throw "Legacy ODBC reports an invalid source package name '$packageName'"
        }
        $directory = Join-Path $env:ProgramData "MemLabs\Installers\ODBC18\$release\$($Product.ProductCode.Trim('{}'))"
        $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
        $path = Join-Path $directory $packageName
        $language = '0x{0:X}' -f $Product.Language
        $url = "https://go.microsoft.com/fwlink/?linkid=$($releaseLinks[$release])&clcid=$language"
        $null = Save-OdbcInstaller -Url $url -Path $path -BypassCache -Label 'Legacy ODBC recovery MSI'
        $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
            throw "Legacy ODBC recovery MSI has no valid Microsoft signature: $path; status=$($signature.Status); signer='$($signature.SignerCertificate.Subject)'; guestUtc=$([datetime]::UtcNow.ToString('o'))"
        }
        $identity = @{}
        $null = Get-MsiVersion -Path $path -InstallerState $identity
        if ($identity.ProductCode -ine $Product.ProductCode -or
            $identity.PackageCode -ine $Product.PackageCode -or
            $identity.UpgradeCode -ine $Product.UpgradeCode) {
            throw "Legacy ODBC recovery MSI identity mismatch; expected product/package/family '$($Product.ProductCode)'/'$($Product.PackageCode)'/'$($Product.UpgradeCode)', downloaded '$($identity.ProductCode)'/'$($identity.PackageCode)'/'$($identity.UpgradeCode)'. The package was not installed. Download: $path"
        }
        return $path
    }
    function Get-OdbcVcRuntimeState {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64'
        $runtime = if (Test-Path -LiteralPath $regPath) {
            try { Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop } catch { $null }
        }
        $major = [int]$runtime.Major
        $minor = [int]$runtime.Minor
        $build = [int]$runtime.Bld
        $filesReady = (Test-Path -LiteralPath "$env:windir\System32\vcruntime140.dll" -PathType Leaf) -and
            (Test-Path -LiteralPath "$env:windir\System32\msvcp140.dll" -PathType Leaf)
        $versionReady = $major -gt 14 -or
            ($major -eq 14 -and $minor -gt 34) -or
            ($major -eq 14 -and $minor -eq 34 -and $build -ge 33135)
        return [pscustomobject]@{
            Ready        = [bool]($versionReady -and $filesReady)
            Major        = $major
            Minor        = $minor
            Build        = $build
            Version      = "$($runtime.Version)"
            FilesReady   = [bool]$filesReady
            RegistryPath = $regPath
        }
    }
    function Get-OdbcMsiFailureDetails {
        param([string]$LogPath)

        if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return 'MSI log not found' }
        $logLines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
        $allMarkers = @($logLines | Where-Object {
                $_ -match '(?i)Command Line:|Feature:\s*SQL_SQLODBC_CORE|Return value 3|error 25003|previous installation required a reboot|CA_ErrorPendingReboot|IsPendingRebootKey|error 1723|error 2896|returned actual error code|installation success or error status:\s*1603|required IACCEPTMSODBCSQLLICENSETERMS|parameter is missing|error 29003|SECREPAIR:|SECUREREPAIR:'
            })
        $failureMarkers = @(
            @($allMarkers | Select-Object -First 6)
            @($allMarkers | Select-Object -Last 6)
        ) | Select-Object -Unique
        $tail = @($logLines | Select-Object -Last 20)
        $parts = @()
        if ($failureMarkers.Count -gt 0) { $parts += "Failure markers: $($failureMarkers -join ' | ')" }
        $parts += "Log tail: $($tail -join ' | ')"
        $details = $parts -join ' | '
        if ($details.Length -gt 4000) { $details = $details.Substring(0, 4000) + ' [truncated]' }
        return $details
    }
    function Save-OdbcInstaller {
        param(
            [string]$Url,
            [string]$Path,
            [switch]$BypassCache,
            [string]$Label = 'ODBC MSI'
        )

        $cacheFailure = $null
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        if (-not $BypassCache) {
            try {
                Import-Module TemplateHelpDSC -Force -ErrorAction Stop
                $downloadCommand = Get-Command Invoke-DownloadFile -ErrorAction SilentlyContinue
                if (-not $downloadCommand) { throw 'Installed TemplateHelpDSC does not expose Invoke-DownloadFile' }
                $null = & $downloadCommand -url $Url -dest $Path
                if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 0) { return }
            }
            catch {
                $cacheFailure = $_.Exception.Message
                Write-Warning "$Label cache download unavailable; trying the source URL directly. $cacheFailure"
                if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
            }
        }

        $downloadErrors = [System.Collections.Generic.List[string]]::new()
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $webClient = $null
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $webClient = New-Object Net.WebClient
                $webClient.DownloadFile($Url, $Path)
                if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -le 0) {
                    throw 'downloaded MSI is empty'
                }
                return
            }
            catch {
                $downloadErrors.Add("attempt $attempt`: $($_.Exception.Message)")
                if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
                if ($attempt -lt 3) { Start-Sleep -Seconds 5 }
            }
            finally {
                if ($webClient) { $webClient.Dispose() }
            }
        }
        $failureDetails = @()
        if ($cacheFailure) { $failureDetails += "cache path: $cacheFailure" }
        $failureDetails += $downloadErrors
        throw "$Label download failed: $($failureDetails -join '; ')"
    }
    function Install-OdbcVcRuntimePrerequisite {
        param([string]$Url)

        $state = Get-OdbcVcRuntimeState
        if ($state.Ready) {
            return [pscustomobject]@{
                Installed = $false
                ExitCode  = 0
                Message   = "VC++ x64 runtime is already ready ($($state.Major).$($state.Minor).$($state.Build); filesReady=$($state.FilesReady))"
            }
        }
        if ([string]::IsNullOrWhiteSpace($Url)) {
            throw 'VC++ x64 runtime is missing or stale and its download URL is empty'
        }

        $vcPath = Join-Path ([IO.Path]::GetTempPath()) 'memlabs-vc_redist.x64.exe'
        $vcLogPath = Join-Path ([IO.Path]::GetTempPath()) 'memlabs-vc_redist.x64.log'
        try {
            $null = Save-OdbcInstaller -Url $Url -Path $vcPath -Label 'VC++ x64 runtime'
            $vcFile = Get-Item -LiteralPath $vcPath -ErrorAction Stop
            if ($vcFile.Length -lt 20MB) {
                $null = Save-OdbcInstaller -Url $Url -Path $vcPath -BypassCache -Label 'VC++ x64 runtime'
                $vcFile = Get-Item -LiteralPath $vcPath -ErrorAction Stop
                if ($vcFile.Length -lt 20MB) {
                    throw "VC++ x64 runtime payload is only $($vcFile.Length) bytes after direct retry (need at least 20MB)"
                }
            }

            $vcArguments = @('/install', '/quiet', '/norestart', '/log', "`"$vcLogPath`"")
            $vcProcess = $null
            for ($vcAttempt = 1; $vcAttempt -le 3; $vcAttempt++) {
                $vcProcess = Start-Process -FilePath $vcPath -ArgumentList $vcArguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
                if ($vcProcess.ExitCode -ne 1618 -or $vcAttempt -ge 3) { break }
                Start-Sleep -Seconds 30
            }
            if ($vcProcess.ExitCode -notin @(0, 1638, 3010)) {
                $vcTail = if (Test-Path -LiteralPath $vcLogPath -PathType Leaf) {
                    @(Get-Content -LiteralPath $vcLogPath -Tail 30 -ErrorAction SilentlyContinue) -join ' | '
                }
                else { 'VC++ runtime log not found' }
                throw "VC++ x64 runtime installer exited $($vcProcess.ExitCode). Log tail: $vcTail"
            }

            $deadline = (Get-Date).AddSeconds(120)
            do {
                $state = Get-OdbcVcRuntimeState
                if ($state.Ready) { break }
                Start-Sleep -Seconds 2
            } while ((Get-Date) -lt $deadline)
            if (-not $state.Ready) {
                throw "VC++ x64 runtime installer exited $($vcProcess.ExitCode), but $($state.RegistryPath) is $($state.Major).$($state.Minor).$($state.Build) and filesReady=$($state.FilesReady) after 120 seconds"
            }

            return [pscustomobject]@{
                Installed = $true
                ExitCode  = [int]$vcProcess.ExitCode
                Message   = "VC++ x64 runtime converged to $($state.Major).$($state.Minor).$($state.Build) before ODBC installation"
            }
        }
        finally {
            Remove-Item -LiteralPath $vcPath -Force -ErrorAction SilentlyContinue
        }
    }

    [version]$required = $null
    if (-not [version]::TryParse("$TargetVersion".Trim(), [ref]$required)) {
        throw "ODBC catalog version '$TargetVersion' is invalid"
    }
    if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
        throw 'ODBC catalog URL is empty'
    }

    $installedBefore = Get-InstalledOdbc18Version
    if ($installedBefore -and $installedBefore -ge $required) {
        return [pscustomobject]@{
            Success = $true
            Message = "Microsoft ODBC Driver 18 is already $installedBefore (required $required)"
            Errors  = @()
        }
    }

    $installerPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-msodbcsql-$TargetVersion.msi"
    $downloadPath = $installerPath
    $logPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-msodbcsql-$TargetVersion.log"
    $repairLogPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-msodbcsql-$TargetVersion.repair.log"
    try {
        $vcResult = Install-OdbcVcRuntimePrerequisite -Url $VcRedistUrl
        $null = Save-OdbcInstaller -Url $DownloadUrl -Path $installerPath

        $msiState = @{}
        $payloadVersionText = Get-MsiVersion -Path $installerPath -InstallerState $msiState
        [version]$payloadVersion = $null
        if (-not [version]::TryParse($payloadVersionText, [ref]$payloadVersion)) {
            throw "Downloaded ODBC MSI has invalid ProductVersion '$payloadVersionText'"
        }
        if ($payloadVersion -lt $required) {
            $null = Save-OdbcInstaller -Url $DownloadUrl -Path $installerPath -BypassCache
            $payloadVersionText = Get-MsiVersion -Path $installerPath -InstallerState $msiState
            $payloadVersion = $null
            if (-not [version]::TryParse($payloadVersionText, [ref]$payloadVersion) -or $payloadVersion -lt $required) {
                throw "Downloaded ODBC MSI is stale after direct retry: payload '$payloadVersionText' is below required $required"
            }
        }

        # Windows Installer validates the original package filename during
        # maintenance. Keep the validated payload under that name for repair.
        $sourceDirectory = Join-Path $env:ProgramData "MemLabs\Installers\ODBC18\$payloadVersion"
        $null = New-Item -Path $sourceDirectory -ItemType Directory -Force -ErrorAction Stop
        $installerPath = Join-Path $sourceDirectory $msiState.PackageName
        Copy-Item -LiteralPath $downloadPath -Destination $installerPath -Force -ErrorAction Stop
        Write-Host "[Fix-ODBC18] Before install: required=$required detected=$installedBefore payload=$payloadVersion SHA256=$((Get-FileHash -LiteralPath $installerPath -Algorithm SHA256 -ErrorAction Stop).Hash); MSI state=$($msiState | ConvertTo-Json -Depth 6 -Compress)"

        $odbcRebootRequired = $false
        $payloadMsiVersion = [version]::new($payloadVersion.Major, $payloadVersion.Minor, $payloadVersion.Build)
        # An advertised/orphaned old MSI sees NOT Installed during nested
        # removal and rejects the license property, which is not inherited.
        # Restore its registration with an explicit, non-uninstall operation.
        foreach ($legacyProduct in @($msiState.RelatedProducts | Where-Object {
                    $_.State -in @(1, 5) -and ($_.State -eq 1 -or -not $_.CachedPackagePresent) -and
                        $_.Version -lt $payloadMsiVersion
                })) {
            $legacyLogPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-msodbcsql-$TargetVersion.legacy-$($legacyProduct.ProductCode.Trim('{}')).log"
            Write-Warning "Restoring ODBC Driver 18 $($legacyProduct.Version) registration/cache ($($legacyProduct.ProductCode)) before upgrade. Log: $legacyLogPath"
            $legacyArguments = "/i $($legacyProduct.ProductCode) /qn /norestart IACCEPTMSODBCSQLLICENSETERMS=YES SKIPPENDINGREBOOTCHECK=1 ADDLOCAL=ALL /l*v `"$legacyLogPath`""
            for ($legacyAttempt = 1; $legacyAttempt -le 3; $legacyAttempt++) {
                $legacyProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $legacyArguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
                if ($legacyProcess.ExitCode -ne 1618 -or $legacyAttempt -ge 3) { break }
                Start-Sleep -Seconds 30
            }
            if ($legacyProcess.ExitCode -notin @(0, 3010)) {
                $details = Get-OdbcMsiFailureDetails -LogPath $legacyLogPath
                Write-Warning "Legacy registration recovery exited $($legacyProcess.ExitCode); obtaining the exact original Microsoft MSI before retrying. Log: $legacyLogPath. $details"
                $sourceLogPath = "$legacyLogPath.source.log"
                try {
                    $legacySource = Save-OdbcRecoveryInstaller -Product $legacyProduct
                    $sourceArguments = "/i `"$legacySource`" /qn /norestart IACCEPTMSODBCSQLLICENSETERMS=YES SKIPPENDINGREBOOTCHECK=1 ADDLOCAL=ALL REINSTALLMODE=vomus /l*v `"$sourceLogPath`""
                    for ($sourceAttempt = 1; $sourceAttempt -le 3; $sourceAttempt++) {
                        $legacyProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $sourceArguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
                        if ($legacyProcess.ExitCode -ne 1618 -or $sourceAttempt -ge 3) { break }
                        Start-Sleep -Seconds 30
                    }
                    if ($legacyProcess.ExitCode -notin @(0, 3010)) {
                        $sourceDetails = Get-OdbcMsiFailureDetails -LogPath $sourceLogPath
                        throw "Exact-source recovery exited $($legacyProcess.ExitCode). $sourceDetails"
                    }
                }
                catch {
                    throw "Legacy ODBC registration/source recovery failed; upgrade was not started and no driver was explicitly uninstalled. Initial log: $legacyLogPath; source recovery log: $sourceLogPath. $($_.Exception.Message)"
                }
            }
            $recoveredState = @{}
            $null = Get-MsiVersion -Path $installerPath -InstallerState $recoveredState
            if (-not @($recoveredState.RelatedProducts | Where-Object {
                        $_.ProductCode -eq $legacyProduct.ProductCode -and $_.State -eq 5 -and $_.CachedPackagePresent
                    }).Count) {
                throw "Legacy ODBC product $($legacyProduct.ProductCode) registration/cache did not recover; upgrade was not started. Log: $legacyLogPath"
            }
            $odbcRebootRequired = $odbcRebootRequired -or $legacyProcess.ExitCode -eq 3010
        }

        $arguments = @(
            '/i', "`"$installerPath`"", '/qn', '/norestart',
            'IACCEPTMSODBCSQLLICENSETERMS=YES',
            # The ODBC MSI otherwise hard-fails with error 25003/1603 whenever
            # PendingFileRenameOperations is non-empty. Phase 10 commonly runs
            # after other maintenance has queued unrelated renames; MSI still
            # handles real file-in-use failures, and we verify InstalledVersion.
            'SKIPPENDINGREBOOTCHECK=1',
            # REINSTALL=ALL does not select absent features. Explicitly add them
            # so an SDK-only product cannot return success without the driver.
            'ADDLOCAL=ALL',
            $(if ($msiState.State -in @(1, 5)) { 'REINSTALLMODE=vomus' }),
            '/l*v', "`"$logPath`""
        )
        $argumentLine = $arguments -join ' '
        Write-Host "[Fix-ODBC18] Installing driver features: msiexec.exe $argumentLine"
        $process = $null
        for ($msiAttempt = 1; $msiAttempt -le 3; $msiAttempt++) {
            $attemptClock = [Diagnostics.Stopwatch]::StartNew()
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $argumentLine -Wait -PassThru -NoNewWindow -ErrorAction Stop
            $attemptClock.Stop()
            Write-Host "[Fix-ODBC18] Install attempt $msiAttempt/3 exit=$($process.ExitCode) elapsed=$([math]::Round($attemptClock.Elapsed.TotalSeconds,2))s log=$logPath"
            if ($process.ExitCode -ne 1618 -or $msiAttempt -ge 3) { break }
            Start-Sleep -Seconds 30
        }
        $installFailed = $process.ExitCode -notin @(0, 3010)
        if ($installFailed) {
            $details = Get-OdbcMsiFailureDetails -LogPath $logPath
            Write-Warning "ODBC MSI exited $($process.ExitCode); attempting feature repair from the validated payload. Log: $logPath. $details"
        }
        $odbcRebootRequired = $odbcRebootRequired -or $process.ExitCode -eq 3010

        $verificationDeadline = (Get-Date).AddSeconds(60)
        do {
            $installedAfter = Get-InstalledOdbc18Version
            if ($installFailed) { break }
            if ($installedAfter -and $installedAfter -ge $required) { break }
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $verificationDeadline)
        if ($installFailed -or -not $installedAfter -or $installedAfter -lt $required) {
            $null = Get-MsiVersion -Path $installerPath -InstallerState $msiState
            Write-Warning "ODBC Driver 18 is unavailable after install; explicitly selecting all features and repairing. Install log: $logPath; repair log: $repairLogPath"
            $repairArguments = @(
                '/i', "`"$installerPath`"", '/qn', '/norestart',
                'IACCEPTMSODBCSQLLICENSETERMS=YES',
                'SKIPPENDINGREBOOTCHECK=1',
                'ADDLOCAL=ALL',
                # REINSTALL overrides ADDLOCAL for absent features. Only use it
                # when the core is already local and needs its files repaired.
                $(if ($msiState.CoreState -eq 3) { 'REINSTALL=ALL' }),
                $(if ($msiState.State -in @(1, 5) -or $msiState.Installed) { 'REINSTALLMODE=vomus' }),
                '/l*v', "`"$repairLogPath`""
            )
            $repairArgumentLine = $repairArguments -join ' '
            Write-Host "[Fix-ODBC18] Repairing driver features: msiexec.exe $repairArgumentLine"
            for ($repairAttempt = 1; $repairAttempt -le 3; $repairAttempt++) {
                $repairProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $repairArgumentLine -Wait -PassThru -NoNewWindow -ErrorAction Stop
                Write-Host "[Fix-ODBC18] Repair attempt $repairAttempt/3 exit=$($repairProcess.ExitCode) log=$repairLogPath"
                if ($repairProcess.ExitCode -ne 1618 -or $repairAttempt -ge 3) { break }
                Start-Sleep -Seconds 30
            }
            if ($repairProcess.ExitCode -notin @(0, 3010)) {
                $details = Get-OdbcMsiFailureDetails -LogPath $repairLogPath
                throw "ODBC Driver 18 remained unregistered after install, and forced repair exited $($repairProcess.ExitCode). Install log: $logPath; repair log: $repairLogPath. $details"
            }
            $odbcRebootRequired = $odbcRebootRequired -or $repairProcess.ExitCode -eq 3010

            $repairDeadline = (Get-Date).AddSeconds(60)
            do {
                $installedAfter = Get-InstalledOdbc18Version
                if ($installedAfter -and $installedAfter -ge $required) { break }
                Start-Sleep -Seconds 2
            } while ((Get-Date) -lt $repairDeadline)
            if (-not $installedAfter -or $installedAfter -lt $required) {
                $details = Get-OdbcMsiFailureDetails -LogPath $repairLogPath
                throw "ODBC Driver 18 remained unavailable after a successful forced repair; detected version '$installedAfter', required $required. Install log: $logPath; repair log: $repairLogPath. $details"
            }
        }
        return [pscustomobject]@{
            Success = $true
            Message = "$($vcResult.Message); Microsoft ODBC Driver 18 upgraded from '$installedBefore' to $installedAfter using payload $payloadVersion$(if ($odbcRebootRequired) { '; reboot required' })"
            Errors  = @(
                if ($vcResult.ExitCode -eq 3010) { 'VC++ runtime installer requested a reboot (exit 3010)' }
                if ($odbcRebootRequired) { 'ODBC MSI requested a reboot (exit 3010); restart the VM before relying on already-loaded ODBC DLLs.' }
            )
        }
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$odbcApplicableRoles = @('CAS', 'Primary', 'Secondary', 'SiteSystem', 'PassiveSite', 'DPMP', 'WSUS')
if ($vmNote -and $vmNote.sqlVersion -and $vmNote.role -notin $odbcApplicableRoles) {
    # Fix descriptors are built separately for each VM, so adding the current
    # role here targets this SQL host without broadening every VM of that role.
    $odbcApplicableRoles += "$($vmNote.role)"
}

$fixesToPerform += [pscustomobject]@{
    FixName             = 'Fix-ODBC18'
    FixVersion          = $odbcTargetVersion
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles      = @($odbcApplicableRoles)
    NotAppliesToRoles   = @()
    DoNotSeedFromWatermark = $true
    DependentVMs        = @()
    ScriptBlock         = $Fix_ODBC18
    ArgumentList        = @($odbcTargetVersion, $odbcDownloadUrl, $vcRedistDownloadUrl)
}
