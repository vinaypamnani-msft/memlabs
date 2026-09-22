# Upgrade-Console.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)
# dot source functions
. $PSScriptRoot\ScriptFunctions.ps1

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
    return ($details -join '; ')
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
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Console $Operation failed with exit $($process.ExitCode) from '$ConsoleUIExe'. $(Get-ConsoleSetupFailureDetail)"
    }
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
        [ValidateRange(1, 5)][int]$MaximumAttempts = 2,
        [ValidateRange(0, 600)][int]$RetrySeconds = 60
    )

    $lastState = $null
    $lastError = ''
    Uninstall-Console -ConsoleUIExe $ConsoleUIExe
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            Install-Console -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir -LocalSiteServer $LocalSiteServer
            Write-DscStatus -NoStatus "Upgrade-Console: Checking if the console installed successfully"
            $lastState = Get-ConsoleVersionState -SiteCode $SiteCode -ExpectedRelease $ExpectedRelease
            if ($lastState.Current) { return $lastState }
            $lastError = "installed '$($lastState.AdminConsoleVersion)' release '$($lastState.ConsoleRelease)'; extension '$($lastState.RequiredExtensionVersion)' expected '$($lastState.RequiredExtensionSiteVersion)'"
        }
        catch {
            $lastError = $_.Exception.Message
        }

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
        [string]$ExpectedRelease
    )

    $setup = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup' -ErrorAction SilentlyContinue
    $adminConsoleVersion = [string]$setup.AdminConsoleVersion
    $requiredExtensionVersion = [string]$setup.RequiredExtensionVersion
    $requiredExtensionSiteVersion = [string](Get-WmiObject -Namespace "root\sms\Site_$SiteCode" -Query 'SELECT FileVersion FROM SMS_ConsoleSetupInfo WHERE FileName = "ConfigMgr.AC_Extension.i386.cab"' -ErrorAction Stop).FileVersion
    if (-not $requiredExtensionSiteVersion) {
        throw "SMS_ConsoleSetupInfo returned no required extension version for site $SiteCode"
    }

    $consoleRelease = ''
    $parsedConsoleVersion = $null
    if ($adminConsoleVersion -and [version]::TryParse($adminConsoleVersion, [ref]$parsedConsoleVersion)) {
        $consoleRelease = "$($parsedConsoleVersion.Minor)"
    }

    [pscustomobject]@{
        AdminConsoleVersion          = $adminConsoleVersion
        ConsoleRelease               = $consoleRelease
        ExpectedRelease              = $ExpectedRelease
        RequiredExtensionVersion     = $requiredExtensionVersion
        RequiredExtensionSiteVersion = $requiredExtensionSiteVersion
        Current                      = $consoleRelease -eq $ExpectedRelease -and $requiredExtensionVersion -eq $requiredExtensionSiteVersion
    }
}

function Resolve-ExpectedConsoleRelease {
    param(
        [object]$CmOptions,
        [object]$VM
    )

    $configuredRelease = "$($CmOptions.Version)"
    if (-not $configuredRelease) { throw 'Upgrade-Console: cmOptions.Version is missing from deployConfig' }
    if ($configuredRelease -notin @('current-branch', 'tech-preview')) { return $configuredRelease }

    $deployedRelease = "$($VM.thisParams.cmDownloadVersion.baselineVersion)"
    if (-not $deployedRelease -or $deployedRelease -in @('current-branch', 'tech-preview')) {
        throw "Upgrade-Console: could not resolve symbolic cmOptions.Version '$configuredRelease' to the deployed media release"
    }
    return $deployedRelease
}


if ( -not $ConfigFilePath) {
    $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
}

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $deployconfig.Parameters.ThisMachineName }
$sitecode = $ThisVM.SiteCode
$cmOptions = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
if (-not $sitecode) { throw 'Upgrade-Console: this machine has no SiteCode in deployConfig' }
$expectedRelease = Resolve-ExpectedConsoleRelease -CmOptions $cmOptions -VM $ThisVM

$state = Get-ConsoleVersionState -SiteCode $sitecode -ExpectedRelease $expectedRelease
if ($state.Current) {
    Write-DscStatus "Upgrade-Console: Console is already current ($($state.AdminConsoleVersion)); extension $($state.RequiredExtensionVersion)"
    return [pscustomobject]@{ Success = $true; Message = "Console is current at $($state.AdminConsoleVersion)" }
}
Write-DscStatus "Upgrade-Console: Upgrading console release '$($state.ConsoleRelease)' to '$expectedRelease'; extension '$($state.RequiredExtensionVersion)' to '$($state.RequiredExtensionSiteVersion)'"

$CMInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "Installation Directory" -ErrorAction SilentlyContinue
if (-not $CMInstallDir) {
    $CMInstallDir = "E:\ConfigMgr"
}

Write-DscStatus -NoStatus "Upgrade-Console: CMInstallDir: $CMInstallDir"
if (-not (Test-Path $CMInstallDir)) {
    throw "Upgrade-Console: CM install directory '$CMInstallDir' does not exist"
}

$ConsoleSetupDir = Join-Path $CMInstallDir 'Tools\ConsoleSetup'
$ConsoleUIExe = Join-Path $ConsoleSetupDir 'ConsoleSetup.exe'
$LangPackDir = $ConsoleSetupDir
$UIInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "UI Installation Directory"  -ErrorAction SilentlyContinue
if (-not $UIInstallDir) {
    $UIInstallDir = "E:\ConfigMgr\AdminConsole"
}

Write-DscStatus -NoStatus "Upgrade-Console: UIInstallDir: $UIInstallDir"
if (-not (Test-Path $UIInstallDir)) {
    throw "Upgrade-Console: UI install directory '$UIInstallDir' does not exist"
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
    -LocalSiteServer $localsiteserver -SiteCode $sitecode -ExpectedRelease $expectedRelease

Write-DscStatus "Console installed successfully Console: $($state.AdminConsoleVersion) Extensions: $($state.RequiredExtensionVersion)"
[pscustomobject]@{ Success = $true; Message = "Console upgraded to $($state.AdminConsoleVersion)" }

