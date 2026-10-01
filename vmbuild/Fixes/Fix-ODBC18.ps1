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
        $value = [string](Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\MSODBCSQL18' -Name 'InstalledVersion' -ErrorAction SilentlyContinue)
        [version]$parsed = $null
        if ($value -and [version]::TryParse($value.Trim(), [ref]$parsed)) { return $parsed }
        return $null
    }
    function Get-MsiVersion {
        param([string]$Path)
        $installer = $null
        $database = $null
        $view = $null
        $record = $null
        try {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
            $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @('SELECT `Value` FROM `Property` WHERE `Property`=''ProductVersion'''))
            $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if (-not $record) { throw 'MSI Property table has no ProductVersion row' }
            return [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
        }
        finally {
            foreach ($comObject in @($record, $view, $database, $installer)) {
                if ($comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
                    catch { Write-Verbose "Could not release Windows Installer COM object: $($_.Exception.Message)" }
                }
            }
        }
    }
    function Get-OdbcVcRuntimeState {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64'
        $runtime = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
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
                $_ -match '(?i)Return value 3|error 25003|previous installation required a reboot|CA_ErrorPendingReboot|IsPendingRebootKey|error 1723|error 2896|returned actual error code|installation success or error status:\s*1603'
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
                $downloadCommand = Get-Command Invoke-DownloadFile -ErrorAction Stop
                $null = & $downloadCommand -url $Url -dest $Path
                if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 0) { return }
            }
            catch {
                $cacheFailure = $_.Exception.Message
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
    $logPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-msodbcsql-$TargetVersion.log"
    try {
        $vcResult = Install-OdbcVcRuntimePrerequisite -Url $VcRedistUrl
        $null = Save-OdbcInstaller -Url $DownloadUrl -Path $installerPath

        $payloadVersionText = Get-MsiVersion -Path $installerPath
        [version]$payloadVersion = $null
        if (-not [version]::TryParse($payloadVersionText, [ref]$payloadVersion)) {
            throw "Downloaded ODBC MSI has invalid ProductVersion '$payloadVersionText'"
        }
        if ($payloadVersion -lt $required) {
            $null = Save-OdbcInstaller -Url $DownloadUrl -Path $installerPath -BypassCache
            $payloadVersionText = Get-MsiVersion -Path $installerPath
            $payloadVersion = $null
            if (-not [version]::TryParse($payloadVersionText, [ref]$payloadVersion) -or $payloadVersion -lt $required) {
                throw "Downloaded ODBC MSI is stale after direct retry: payload '$payloadVersionText' is below required $required"
            }
        }

        $arguments = @(
            '/i', "`"$installerPath`"", '/qn', '/norestart',
            'IACCEPTMSODBCSQLLICENSETERMS=YES',
            # The ODBC MSI otherwise hard-fails with error 25003/1603 whenever
            # PendingFileRenameOperations is non-empty. Phase 10 commonly runs
            # after other maintenance has queued unrelated renames; MSI still
            # handles real file-in-use failures, and we verify InstalledVersion.
            'SKIPPENDINGREBOOTCHECK=1',
            '/l*v', "`"$logPath`""
        )
        $process = $null
        for ($msiAttempt = 1; $msiAttempt -le 3; $msiAttempt++) {
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($process.ExitCode -ne 1618 -or $msiAttempt -ge 3) { break }
            Start-Sleep -Seconds 30
        }
        if ($process.ExitCode -notin @(0, 3010)) {
            $details = Get-OdbcMsiFailureDetails -LogPath $logPath
            throw "ODBC MSI exited $($process.ExitCode). $details"
        }

        $installedAfter = Get-InstalledOdbc18Version
        if (-not $installedAfter -or $installedAfter -lt $required) {
            throw "ODBC install returned success but InstalledVersion '$installedAfter' is below required $required"
        }
        return [pscustomobject]@{
            Success = $true
            Message = "$($vcResult.Message); Microsoft ODBC Driver 18 upgraded from '$installedBefore' to $installedAfter using payload $payloadVersion$(if ($process.ExitCode -eq 3010) { '; reboot required' })"
            Errors  = @(
                if ($vcResult.ExitCode -eq 3010) { 'VC++ runtime installer requested a reboot (exit 3010)' }
                if ($process.ExitCode -eq 3010) { 'ODBC MSI requested a reboot (exit 3010); restart the VM before relying on already-loaded ODBC DLLs.' }
            )
        }
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
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
