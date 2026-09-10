#Upgrade-Console.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)
#"E:\ConfigMgr\bin\I386\ConsoleSetup.exe" LangPackDir="E:\ConfigMgr\bin\i386\LanguagePack" TargetDir="E:\ConfigMgr\AdminConsole" DEFAULTSITESERVERNAME="ADA-PS1SITE.adatum.com"
#SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup
# dot source functions
. $PSScriptRoot\ScriptFunctions.ps1


function Install-Console {
    param(
        [string]$ConsoleUIExe,
        [string]$LangPackDir,
        [string]$UIInstallDir,
        [string]$localsiteserver
    )
    Write-DscStatus -NoStatus "Upgrade-Console: Uninstalling the console"
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $uninstallOutput = @(& $ConsoleUIExe /uninstall /q 2>&1)
        $uninstallExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($uninstallExitCode -notin @(0, 3010)) {
        throw "Console uninstall failed with exit $uninstallExitCode`: $($uninstallOutput -join '; ')"
    }
    Start-Sleep -Seconds 5
    Wait-Process -Name ConsoleSetup -ErrorAction SilentlyContinue

    Write-DscStatus -NoStatus "Upgrade-Console: Uninstall Complete"

    Write-DscStatus -NoStatus "Upgrade-Console: Installing the console"
    Write-DscStatus -NoStatus "& $ConsoleUIExe /q LangPackDir=$LangPackDir TargetDir=$UIInstallDir DEFAULTSITESERVERNAME=$localsiteserver"
    try {
        $ErrorActionPreference = 'Continue'
        $installOutput = @(& $ConsoleUIExe /q "LangPackDir=$LangPackDir" "TargetDir=$UIInstallDir" "DEFAULTSITESERVERNAME=$localsiteserver" 2>&1)
        $installExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($installExitCode -notin @(0, 3010)) {
        throw "Console install failed with exit $installExitCode`: $($installOutput -join '; ')"
    }
    Start-Sleep -Seconds 5
    Wait-Process -Name ConsoleSetup -ErrorAction SilentlyContinue
    Write-DscStatus -NoStatus "Upgrade-Console: Install Complete"
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

$ConsoleUIExe = Join-Path $CMInstallDir 'bin\I386\Consolesetup.exe'
$LangPackDir = Join-Path $CMInstallDir 'bin\I386\LanguagePack'
$UIInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "UI Installation Directory"  -ErrorAction SilentlyContinue
if (-not $UIInstallDir) {
    $UIInstallDir = "E:\ConfigMgr\AdminConsole"
}

Write-DscStatus -NoStatus "Upgrade-Console: UIInstallDir: $UIInstallDir"
if (-not (Test-Path $UIInstallDir)) {
    throw "Upgrade-Console: UI install directory '$UIInstallDir' does not exist"
}   

Write-DscStatus -NoStatus "Upgrade-Console: ConsoleUIExe: $ConsoleUIExe"
if (-not (Test-Path $ConsoleUIExe)) {
    throw "Upgrade-Console: console setup '$ConsoleUIExe' does not exist"
}   

$localsiteServer = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\AdminUI\Connection"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "server"  -ErrorAction SilentlyContinue
if (-not $localSiteServer) {
    $localsiteserver = "$($env:Computername).$($env:UserDNSDomain)"
}


Install-Console -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir -localsiteserver $localsiteserver
Write-DscStatus -NoStatus "Upgrade-Console: Checking if the console installed successfully"
$state = Get-ConsoleVersionState -SiteCode $sitecode -ExpectedRelease $expectedRelease
if (-not $state.Current) {
    Write-DscStatus "Upgrade-Console: Console validation failed after first install; retrying"
    Start-Sleep -Seconds 60
    Install-Console -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir -localsiteserver $localsiteserver
    $state = Get-ConsoleVersionState -SiteCode $sitecode -ExpectedRelease $expectedRelease
}

if (-not $state.Current) {
    throw "Console upgrade did not converge: installed '$($state.AdminConsoleVersion)' release '$($state.ConsoleRelease)' expected '$expectedRelease'; extension '$($state.RequiredExtensionVersion)' expected '$($state.RequiredExtensionSiteVersion)'"
}

Write-DscStatus "Console installed successfully Console: $($state.AdminConsoleVersion) Extensions: $($state.RequiredExtensionVersion)"
[pscustomobject]@{ Success = $true; Message = "Console upgraded to $($state.AdminConsoleVersion)" }

