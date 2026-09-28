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

$Fix_ODBC18 = {
    param([string]$TargetVersion, [string]$DownloadUrl)

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
    function Save-OdbcInstaller {
        param(
            [string]$Url,
            [string]$Path,
            [switch]$BypassCache
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
        throw "ODBC MSI download failed: $($failureDetails -join '; ')"
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
            '/l*v', "`"$logPath`""
        )
        $process = $null
        for ($msiAttempt = 1; $msiAttempt -le 3; $msiAttempt++) {
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($process.ExitCode -ne 1618 -or $msiAttempt -ge 3) { break }
            Start-Sleep -Seconds 30
        }
        if ($process.ExitCode -notin @(0, 3010)) {
            $tail = if (Test-Path -LiteralPath $logPath) {
                @(Get-Content -LiteralPath $logPath -Tail 20 -ErrorAction SilentlyContinue) -join ' | '
            }
            else { 'log not found' }
            throw "ODBC MSI exited $($process.ExitCode). Log tail: $tail"
        }

        $installedAfter = Get-InstalledOdbc18Version
        if (-not $installedAfter -or $installedAfter -lt $required) {
            throw "ODBC install returned success but InstalledVersion '$installedAfter' is below required $required"
        }
        return [pscustomobject]@{
            Success = $true
            Message = "Microsoft ODBC Driver 18 upgraded from '$installedBefore' to $installedAfter using payload $payloadVersion$(if ($process.ExitCode -eq 3010) { '; reboot required' })"
            Errors  = $(if ($process.ExitCode -eq 3010) { @('ODBC MSI requested a reboot (exit 3010); restart the VM before relying on already-loaded ODBC DLLs.') } else { @() })
        }
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$fixesToPerform += [pscustomobject]@{
    FixName             = 'Fix-ODBC18'
    FixVersion          = $odbcTargetVersion
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles      = @()
    NotAppliesToRoles   = @('OSDClient', 'AADClient', 'StandaloneRootCA', 'Proxy', 'LinuxServer', 'LinuxClient')
    DoNotSeedFromWatermark = $true
    DependentVMs        = @()
    ScriptBlock         = $Fix_ODBC18
    ArgumentList        = @($odbcTargetVersion, $odbcDownloadUrl)
}
