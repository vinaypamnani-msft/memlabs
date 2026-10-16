# Upgrade-Console.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath,
    [switch]$CheckOnly
)
# dot source functions
. $PSScriptRoot\ScriptFunctions.ps1

function Get-ConsolePayloadState {
    param([Parameter(Mandatory)][string]$SiteInstallDirectory)

    $directory = Join-Path $SiteInstallDirectory 'Tools\ConsoleSetup'
    $requiredFiles = @('ConsoleSetup.exe', 'AdminConsole.msi', 'ConfigMgr.AC_Extension.i386.cab', 'ConfigMgr.AC_Extension.amd64.cab')
    $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $directory $_) -PathType Leaf) })
    if ($missing.Count) {
        throw "Upgrade-Console: site-maintained console source '$directory' is incomplete; missing: $($missing -join ', ')"
    }
    [string]$path = Join-Path $directory 'AdminConsole.msi'
    $installer = $null; $database = $null
    $versionText = ''
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($path, 0))
        foreach ($property in @('AdminConsoleVersion', 'ProductVersion')) {
            $view = $null; $record = $null
            try {
                $query = "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$property'"
                $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($query))
                $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                if ($record) {
                    $versionText = [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
                    if ($versionText) { break }
                }
            }
            finally {
                foreach ($item in @($record, $view)) { if ($item) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item) } }
            }
        }
    }
    finally {
        foreach ($item in @($database, $installer)) { if ($item) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item) } }
    }
    [version]$version = $null
    if (-not [version]::TryParse($versionText.Trim(), [ref]$version) -or $version.Minor -lt 1000 -or $version.Minor -gt 9999) {
        throw "Upgrade-Console: source '$path' does not expose a valid console release version ('$versionText')"
    }
    $setupPath = Join-Path $directory 'ConsoleSetup.exe'
    $setupVersionText = (Get-Item -LiteralPath $setupPath -ErrorAction Stop).VersionInfo.FileVersion
    $siteSetup = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction Stop
    [version]$siteVersion = $null
    [version]$setupVersion = $null
    $identification = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -ErrorAction Stop
    $siteCode = "$($identification.'Site Code')"
    if (-not $siteCode) { throw 'Upgrade-Console: installed site identification has no Site Code' }
    $liveSite = Get-CimInstance -Namespace "root\SMS\site_$siteCode" -ClassName SMS_Site `
        -Filter "SiteCode='$siteCode'" -OperationTimeoutSec 15 -ErrorAction Stop | Select-Object -First 1
    if (-not [version]::TryParse("$($liveSite.Version)".Trim(), [ref]$siteVersion)) {
        throw "Upgrade-Console: the SMS Provider returned no valid live site version for '$siteCode'"
    }
    if (-not [version]::TryParse("$setupVersionText".Trim(), [ref]$setupVersion)) {
        throw "Upgrade-Console: console setup exposes no valid site-build version ('$setupVersionText')"
    }
    [pscustomobject]@{
        SourceDirectory = $directory
        ConsoleUIExe = $setupPath
        ConsoleVersion = $version
        Release = "$($version.Minor)"
        SiteVersion = "$siteVersion"
        RegistrySiteVersion = "$($siteSetup.'Full Version')"
        SetupVersion = "$setupVersionText"
        LiveSiteBuild = $siteVersion.Build
        PayloadSiteBuild = $setupVersion.Build
        SourceMatchesSite = $siteVersion.Build -eq $setupVersion.Build
        VersionSource = 'live-site-console-payload'
    }
}

function Get-ConsoleSetupFailureDetail {
    $details = New-Object System.Collections.Generic.List[string]
    foreach ($setupLog in @('C:\ConfigMgrAdminUISetup.log', 'C:\ConfigMgrAdminUISetupVerbose.log')) {
        if (-not (Test-Path -LiteralPath $setupLog -PathType Leaf)) {
            $details.Add("$setupLog not found")
            continue
        }
        try {
            $tail = @(Get-Content -LiteralPath $setupLog -Tail 80 -ErrorAction Stop | Where-Object { $_ })
            $details.Add("$setupLog tail: $($tail -join ' | ')")
        }
        catch {
            $details.Add("$setupLog unreadable: $($_.Exception.Message)")
        }
    }
    $text = $details -join '; '
    if ($text.Length -gt 12000) { $text = $text.Substring(0, 12000) + ' [truncated]' }
    return $text
}

function Invoke-ConsoleSetupProcess {
    param(
        [Parameter(Mandatory)][string]$ConsoleUIExe,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$Operation
    )

    $consoleSetupDir = Split-Path -Parent $ConsoleUIExe
    $preExistingIds = @(Get-Process -Name ConsoleSetup -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    try {
        $process = Start-Process -FilePath $ConsoleUIExe -ArgumentList $Arguments `
            -WorkingDirectory $consoleSetupDir -PassThru -ErrorAction Stop
    }
    catch {
        throw "Console $Operation could not start '$ConsoleUIExe': $($_.Exception.Message). $(Get-ConsoleSetupFailureDetail)"
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process | Wait-Process -Timeout 900 -ErrorAction Stop
        Start-Sleep -Seconds 2
        $remainingProcesses = @(Get-Process -Name ConsoleSetup -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $process.Id -and $_.Id -notin $preExistingIds })
        if ($remainingProcesses.Count -gt 0) {
            $remainingSeconds = [math]::Max(1, 900 - [int][math]::Ceiling($stopwatch.Elapsed.TotalSeconds))
            $remainingProcesses | Wait-Process -Timeout $remainingSeconds -ErrorAction Stop
        }
    }
    catch {
        $waitError = $_.Exception.Message
        $ownedProcesses = @($process) + @(Get-Process -Name ConsoleSetup -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -notin $preExistingIds })
        foreach ($ownedProcess in @($ownedProcesses | Where-Object { $null -ne $_ } | Sort-Object Id -Unique)) {
            try { Stop-Process -Id $ownedProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
        throw "Console $Operation did not finish within 900 seconds: $waitError. $(Get-ConsoleSetupFailureDetail)"
    }
    finally {
        $stopwatch.Stop()
    }

    if ($null -eq $process.ExitCode) {
        throw "Console $Operation returned no process exit code from '$ConsoleUIExe'. $(Get-ConsoleSetupFailureDetail)"
    }
    if ($process.ExitCode -notin @(0, 3010) -and -not ($Operation -eq 'uninstall' -and $process.ExitCode -eq 1605)) {
        throw "Console $Operation failed with exit $($process.ExitCode) from '$ConsoleUIExe'. $(Get-ConsoleSetupFailureDetail)"
    }
    Write-DscStatus -NoStatus "Upgrade-Console: $Operation process $($process.Id) completed; exit=$($process.ExitCode) elapsed=$([math]::Round($stopwatch.Elapsed.TotalSeconds, 2))s rebootRequired=$($process.ExitCode -eq 3010)"
    return $process.ExitCode
}

function Uninstall-Console {
    param(
        [Parameter(Mandatory)][string]$ConsoleUIExe
    )
    Write-DscStatus -NoStatus "Upgrade-Console: Uninstalling the console"
    $null = Invoke-ConsoleSetupProcess -ConsoleUIExe $ConsoleUIExe -Arguments '/uninstall /q' -Operation 'uninstall'
    Write-DscStatus -NoStatus "Upgrade-Console: Uninstall Complete"
}

function Install-Console {
    param(
        [Parameter(Mandatory)][string]$ConsoleUIExe,
        [Parameter(Mandatory)][string]$LangPackDir,
        [Parameter(Mandatory)][string]$UIInstallDir,
        [Parameter(Mandatory)][string]$LocalSiteServer
    )
    Write-DscStatus -NoStatus "Upgrade-Console: Installing the console"
    $installArguments = "/q `"LangPackDir=$LangPackDir`" `"TargetDir=$UIInstallDir`" `"DEFAULTSITESERVERNAME=$LocalSiteServer`""
    Write-DscStatus -NoStatus "& $ConsoleUIExe $installArguments"
    $null = Invoke-ConsoleSetupProcess -ConsoleUIExe $ConsoleUIExe -Arguments $installArguments -Operation 'install'
    Write-DscStatus -NoStatus "Upgrade-Console: Install Complete"
}

function Invoke-ConsoleUpgrade {
    param(
        [Parameter(Mandatory)][string]$ConsoleUIExe,
        [Parameter(Mandatory)][string]$LangPackDir,
        [Parameter(Mandatory)][string]$UIInstallDir,
        [Parameter(Mandatory)][string]$LocalSiteServer,
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][string]$ExpectedRelease,
        [ValidateRange(1, 5)][int]$MaximumAttempts = 3,
        [ValidateRange(0, 600)][int]$RetrySeconds = 60,
        [version]$ExpectedConsoleVersion,
        [switch]$ConsoleMissing,
        [int]$LiveSiteBuild,
        [int]$PayloadSiteBuild
    )

    $lastState = $null
    $lastError = ''
    $uninstalled = $ConsoleMissing.IsPresent
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            Write-DscStatus -NoStatus "Upgrade-Console: attempt $attempt/$MaximumAttempts; expected console '$ExpectedConsoleVersion' release '$ExpectedRelease'; uninstall completed=$uninstalled"
            if ($ExpectedConsoleVersion) {
                $before = Get-ConsoleVersionState -SiteCode $SiteCode -ExpectedRelease $ExpectedRelease -ExpectedConsoleVersion $ExpectedConsoleVersion `
                    -LiveSiteBuild $LiveSiteBuild -PayloadSiteBuild $PayloadSiteBuild
                if ($before.Current -or $before.NewerThanSite) { return $before }
                if (-not $before.SourceMatchesSite) { throw 'Console source and live site builds disagree; no console was uninstalled.' }
                if ($before.ProviderError) { throw "SMS Provider unavailable before setup: $($before.ProviderError)" }
                if (-not $before.AdminConsoleVersion) { $uninstalled = $true }
            }
            if (-not $uninstalled) {
                Uninstall-Console -ConsoleUIExe $ConsoleUIExe
                $uninstalled = $true
            }
            Install-Console -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir -LocalSiteServer $LocalSiteServer
            Write-DscStatus -NoStatus "Upgrade-Console: Checking if the console installed successfully"
            for ($verification = 1; $verification -le 3; $verification++) {
                $lastState = Get-ConsoleVersionState -SiteCode $SiteCode -ExpectedRelease $ExpectedRelease -ExpectedConsoleVersion $ExpectedConsoleVersion `
                    -LiveSiteBuild $LiveSiteBuild -PayloadSiteBuild $PayloadSiteBuild
                Write-DscStatus -NoStatus "Upgrade-Console: verification $verification/3: $($lastState | ConvertTo-Json -Compress)"
                if ($lastState.Current -or $lastState.NewerThanSite) { return $lastState }
                if ($verification -lt 3) { Start-Sleep -Seconds 10 }
            }
            $lastError = "installed '$($lastState.AdminConsoleVersion)' release '$($lastState.ConsoleRelease)' expected release '$($lastState.ExpectedRelease)' (match=$($lastState.ReleaseMatches)); extension '$($lastState.RequiredExtensionVersion)' expected '$($lastState.RequiredExtensionSiteVersion)' (match=$($lastState.ExtensionMatches))"
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Write-DscStatus -NoStatus "Upgrade-Console: attempt $attempt/$MaximumAttempts failed: $lastError. $(Get-ConsoleSetupFailureDetail)"

        if ($attempt -lt $MaximumAttempts) {
            Write-DscStatus "Upgrade-Console: attempt $attempt/$MaximumAttempts failed: $lastError. Retrying in $RetrySeconds seconds."
            if ($RetrySeconds -gt 0) { Start-Sleep -Seconds $RetrySeconds }
        }
    }

    throw "Console upgrade did not converge after $MaximumAttempts attempts. Last failure: $lastError"
}

function Get-ConsoleVersionState {
    param(
        [string]$SiteCode,
        [string]$ExpectedRelease,
        [version]$ExpectedConsoleVersion,
        [int]$LiveSiteBuild,
        [int]$PayloadSiteBuild
    )

    $setup = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup' -ErrorAction SilentlyContinue
    $adminConsoleVersion = ([string]$setup.AdminConsoleVersion).Trim()
    $requiredExtensionVersion = ([string]$setup.RequiredExtensionVersion).Trim()
    $requiredExtensionSiteVersion = ''
    $providerError = ''
    try {
        $consoleSetupInfo = Get-CimInstance -Namespace "root\sms\Site_$SiteCode" -Query 'SELECT FileVersion FROM SMS_ConsoleSetupInfo WHERE FileName = "ConfigMgr.AC_Extension.i386.cab"' -OperationTimeoutSec 15 -ErrorAction Stop |
            Select-Object -First 1
        $requiredExtensionSiteVersion = ([string]$consoleSetupInfo.FileVersion).Trim()
        if (-not $requiredExtensionSiteVersion) { throw "SMS_ConsoleSetupInfo returned no required extension version for site $SiteCode" }
    }
    catch { $providerError = $_.Exception.Message }
    $expectedReleaseNormalized = ([string]$ExpectedRelease).Trim()

    $consoleRelease = ''
    $parsedConsoleVersion = $null
    if ($adminConsoleVersion -and [version]::TryParse($adminConsoleVersion, [ref]$parsedConsoleVersion)) {
        $consoleRelease = "$($parsedConsoleVersion.Minor)"
    }

    $releaseMatches = $consoleRelease -eq $expectedReleaseNormalized
    $extensionMatches = $requiredExtensionVersion -eq $requiredExtensionSiteVersion
    $newerThanSite = if ($ExpectedConsoleVersion -and $parsedConsoleVersion) {
        $parsedConsoleVersion -gt $ExpectedConsoleVersion -or
            ($LiveSiteBuild -gt 0 -and $PayloadSiteBuild -gt $LiveSiteBuild -and $parsedConsoleVersion -ge $ExpectedConsoleVersion)
    } else { $false }
    $versionMatches = if ($ExpectedConsoleVersion) { $parsedConsoleVersion -eq $ExpectedConsoleVersion } else { $releaseMatches }
    $sourceMatchesSite = $LiveSiteBuild -le 0 -or $PayloadSiteBuild -le 0 -or $LiveSiteBuild -eq $PayloadSiteBuild
    $preservationReason = if ($newerThanSite) {
        if ($parsedConsoleVersion -gt $ExpectedConsoleVersion) { 'installed-console-newer-than-available-payload' }
        else { 'installed-console-matches-payload-ahead-of-live-site' }
    } else { '' }
    [pscustomobject]@{
        AdminConsoleVersion          = $adminConsoleVersion
        ConsoleRelease               = $consoleRelease
        ExpectedRelease              = $expectedReleaseNormalized
        RequiredExtensionVersion     = $requiredExtensionVersion
        RequiredExtensionSiteVersion = $requiredExtensionSiteVersion
        ReleaseMatches               = $releaseMatches
        ExtensionMatches             = $extensionMatches
        ExpectedConsoleVersion       = "$ExpectedConsoleVersion"
        NewerThanSite                 = $newerThanSite
        PreservationReason           = $preservationReason
        ProviderError                = $providerError
        LiveSiteBuild                = $LiveSiteBuild
        PayloadSiteBuild             = $PayloadSiteBuild
        SourceMatchesSite            = $sourceMatchesSite
        Current                      = $versionMatches -and $extensionMatches -and -not $providerError -and $sourceMatchesSite
    }
}

function Resolve-ExpectedConsoleRelease {
    param(
        [object]$CmOptions,
        [object]$VM,
        [object]$DeployConfig,
        [string]$LiveRelease
    )

    if ($LiveRelease) {
        if ($LiveRelease -notmatch '^\d{4}$') { throw "Upgrade-Console: invalid live console release '$LiveRelease'" }
        return $LiveRelease
    }
    $releaseOptions = $CmOptions
    $releaseVm = $VM
    if ($VM.parentSiteCode) {
        $currentDomain = if ($VM.domain) { "$($VM.domain)" } else { "$($DeployConfig.vmOptions.domainName)" }
        $parentSites = @($DeployConfig.virtualMachines | Where-Object {
                $_.role -eq 'CAS' -and
                "$($_.siteCode)" -ieq "$($VM.parentSiteCode)" -and
                (-not $_.domain -or "$($_.domain)" -ieq $currentDomain)
            })
        if ($parentSites.Count -ne 1) {
            throw "Upgrade-Console: expected exactly one parent CAS '$($VM.parentSiteCode)' in domain '$currentDomain' in deployConfig, found $($parentSites.Count)"
        }
        $releaseVm = $parentSites[0]
        $releaseOptions = if ($releaseVm.cmOptions) { $releaseVm.cmOptions } else { $DeployConfig.cmOptions }
    }

    $configuredRelease = "$($releaseOptions.Version)".Trim()
    if (-not $configuredRelease) { $configuredRelease = "$($DeployConfig.cmOptions.Version)".Trim() }

    $deployedRelease = "$($releaseVm.thisParams.cmDownloadVersion.baselineVersion)".Trim()
    if ([bool]$releaseOptions.OfflineSCP -and $deployedRelease -and
        $deployedRelease -notin @('current-branch', 'tech-preview')) {
        return $deployedRelease
    }

    if ($configuredRelease -and $configuredRelease -notin @('current-branch', 'tech-preview')) { return $configuredRelease }

    $deployedVersions = @($releaseVm.thisParams.cmDownloadVersion.versions |
            ForEach-Object { "$_".Trim() } |
            Where-Object { $_ -and $_ -notin @('current-branch', 'tech-preview') })
    if ($deployedVersions.Count -gt 0) { return $deployedVersions[-1] }

    if (-not $deployedRelease -or $deployedRelease -in @('current-branch', 'tech-preview')) {
        throw "Upgrade-Console: no live payload release, configured cmOptions.Version, or deployed media release could resolve '$configuredRelease'"
    }
    return $deployedRelease
}


if ( -not $ConfigFilePath) {
    $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
}

# Read config json
$deployConfig = $null
try { $deployConfig = Get-Content -LiteralPath $ConfigFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
catch { Write-DscStatus -NoStatus "Upgrade-Console: deployment metadata unavailable; using the live site's console source. $($_.Exception.Message)" }
$machineName = if ($deployConfig.Parameters.ThisMachineName) { $deployConfig.Parameters.ThisMachineName } else { $env:COMPUTERNAME }
$matches = @($deployConfig.virtualMachines | Where-Object { $_.vmName -ieq $machineName })
if ($matches.Count -gt 1) { throw "Upgrade-Console: deployment metadata has multiple entries for '$machineName'" }
$ThisVM = $matches | Select-Object -First 1
$identification = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -ErrorAction Stop
$sitecode = if ($identification.'Site Code') { $identification.'Site Code' } else { $ThisVM.SiteCode }
$cmOptions = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
if (-not $sitecode) { throw 'Upgrade-Console: this machine has no live or configured SiteCode' }

$CMInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "Installation Directory" -ErrorAction SilentlyContinue
if (-not $CMInstallDir) {
    $CMInstallDir = "E:\ConfigMgr"
}

Write-DscStatus -NoStatus "Upgrade-Console: CMInstallDir: $CMInstallDir"
if (-not (Test-Path $CMInstallDir)) {
    throw "Upgrade-Console: CM install directory '$CMInstallDir' does not exist"
}
$payload = $null
for ($sourceAttempt = 1; $sourceAttempt -le 3; $sourceAttempt++) {
    try { $payload = Get-ConsolePayloadState -SiteInstallDirectory $CMInstallDir; break }
    catch {
        Write-DscStatus -NoStatus "Upgrade-Console: live console source probe $sourceAttempt/3 failed: $($_.Exception.Message)"
        if ($sourceAttempt -ge 3) { throw }
        Start-Sleep -Seconds 15
    }
}
$expectedRelease = Resolve-ExpectedConsoleRelease -CmOptions $cmOptions -VM $ThisVM -DeployConfig $deployConfig -LiveRelease $payload.Release
Write-DscStatus -NoStatus "Upgrade-Console: authoritative target: $($payload | ConvertTo-Json -Compress); configured version='$($cmOptions.Version)'"
$state = $null
for ($probeAttempt = 1; $probeAttempt -le 3; $probeAttempt++) {
    $state = Get-ConsoleVersionState -SiteCode $sitecode -ExpectedRelease $expectedRelease -ExpectedConsoleVersion $payload.ConsoleVersion `
        -LiveSiteBuild $payload.LiveSiteBuild -PayloadSiteBuild $payload.PayloadSiteBuild
    Write-DscStatus -NoStatus "Upgrade-Console: readiness probe $probeAttempt/3: $($state | ConvertTo-Json -Compress)"
    if (-not $state.ProviderError -or $state.NewerThanSite) { break }
    if ($probeAttempt -lt 3) { Start-Sleep -Seconds 10 }
}
if ($state.Current -or $state.NewerThanSite) {
    $message = if ($state.NewerThanSite) {
        "Console $($state.AdminConsoleVersion) preserved without downgrade: $($state.PreservationReason) (live site build $($payload.LiveSiteBuild), payload $($payload.ConsoleVersion)/build $($payload.PayloadSiteBuild)); exact compatibility not asserted."
    } else { "Console is current at $($state.AdminConsoleVersion); verified against the live site payload." }
    Write-DscStatus -NoStatus "Upgrade-Console: $message"
    return [pscustomobject]@{ Success = $true; Message = $message; PreservedNewer = [bool]$state.NewerThanSite; State = $state }
}
if ($CheckOnly) {
    return [pscustomobject]@{ Success = $false; Message = 'Console does not match the live site payload'; State = $state }
}
if (-not $state.SourceMatchesSite) {
    throw "Upgrade-Console: live site build $($payload.LiveSiteBuild) and console payload build $($payload.PayloadSiteBuild) disagree; no console was uninstalled."
}
if ($state.ProviderError) { throw "Upgrade-Console: SMS Provider readiness failed; no console was uninstalled. $($state.ProviderError)" }
Write-DscStatus -NoStatus "Upgrade-Console: installed '$($state.AdminConsoleVersion)' will be upgraded to live payload '$($payload.ConsoleVersion)'"

$ConsoleSetupDir = Join-Path $CMInstallDir 'Tools\ConsoleSetup'
$ConsoleUIExe = Join-Path $ConsoleSetupDir 'ConsoleSetup.exe'
$LangPackDir = $ConsoleSetupDir
$UIInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "UI Installation Directory"  -ErrorAction SilentlyContinue
if (-not $UIInstallDir) {
    $UIInstallDir = "E:\ConfigMgr\AdminConsole"
}

Write-DscStatus -NoStatus "Upgrade-Console: UIInstallDir: $UIInstallDir"
if (-not (Test-Path $UIInstallDir)) {
    Write-DscStatus -NoStatus "Upgrade-Console: UI install directory '$UIInstallDir' is absent; setup will restore it."
}   

Write-DscStatus -NoStatus "Upgrade-Console: ConsoleUIExe: $ConsoleUIExe"
$requiredConsoleSetupFiles = @('ConsoleSetup.exe', 'AdminConsole.msi', 'ConfigMgr.AC_Extension.i386.cab', 'ConfigMgr.AC_Extension.amd64.cab')
$missingConsoleSetupFiles = @($requiredConsoleSetupFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ConsoleSetupDir $_) -PathType Leaf) })
if ($missingConsoleSetupFiles.Count -gt 0) {
    throw "Upgrade-Console: site-maintained console source '$ConsoleSetupDir' is incomplete; missing: $($missingConsoleSetupFiles -join ', ')"
}

$localsiteServer = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\AdminUI\Connection"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "server"  -ErrorAction SilentlyContinue
if (-not $localSiteServer) {
    $localsiteserver = "$($env:Computername).$($env:UserDNSDomain)"
}


$state = Invoke-ConsoleUpgrade -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir `
    -LocalSiteServer $localsiteserver -SiteCode $sitecode -ExpectedRelease $expectedRelease `
    -ExpectedConsoleVersion $payload.ConsoleVersion -ConsoleMissing:([string]::IsNullOrWhiteSpace($state.AdminConsoleVersion)) `
    -LiveSiteBuild $payload.LiveSiteBuild -PayloadSiteBuild $payload.PayloadSiteBuild

if ($state.NewerThanSite) {
    $message = "Console $($state.AdminConsoleVersion) preserved without downgrade: $($state.PreservationReason) (live site build $($payload.LiveSiteBuild), payload $($payload.ConsoleVersion)/build $($payload.PayloadSiteBuild)); exact compatibility not asserted."
    Write-DscStatus -NoStatus "Upgrade-Console: $message"
    return [pscustomobject]@{ Success = $true; Message = $message; PreservedNewer = $true; State = $state }
}
Write-DscStatus "Console installed successfully Console: $($state.AdminConsoleVersion) Extensions: $($state.RequiredExtensionVersion)"
[pscustomobject]@{ Success = $true; Message = "Console upgraded to $($state.AdminConsoleVersion) from the live site payload"; State = $state }
