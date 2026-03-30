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
    #Uninstall the console
    Write-DscStatus -NoStatus "Upgrade-Console: Uninstalling the console"
    & $ConsoleUIExe  /uninstall /q
    Start-Sleep -Seconds 5
    Wait-Process -Name ConsoleSetup -ErrorAction SilentlyContinue

    Write-DscStatus -NoStatus "Upgrade-Console: Uninstall Complete"


    Write-DscStatus -NoStatus "Upgrade-Console: Installing the console"
    #Install the Console
    Write-DscStatus -NoStatus "& $ConsoleUIExe /q LangPackDir=$LangPackDir TargetDir=$UIInstallDir DEFAULTSITESERVERNAME=$localsiteserver"
    & $ConsoleUIExe /q LangPackDir=$LangPackDir TargetDir=$UIInstallDir DEFAULTSITESERVERNAME=$localsiteserver
    Start-Sleep -Seconds 5
    Wait-Process -Name ConsoleSetup -ErrorAction SilentlyContinue
    Write-DscStatus -NoStatus "Upgrade-Console: Install Complete"
}


if ( -not $ConfigFilePath) {
    $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
}

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $deployconfig.Parameters.ThisMachineName }
$sitecode = $ThisVM.SiteCode

$AdminConsoleVersion = Get-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "AdminConsoleVersion" -ErrorAction SilentlyContinue
$RequiredExtensionVersion = Get-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "RequiredExtensionVersion" -ErrorAction SilentlyContinue
$RequiredExtensionSiteVersion = (gwmi -namespace "root\sms\Site_$($sitecode)" -Query "SELECT FileVersion from SMS_ConsoleSetupInfo WHERE FileName = ""ConfigMgr.AC_Extension.i386.cab""").FileVersion




if ($RequiredExtensionVersion -ne $RequiredExtensionSiteVersion) {
    Write-DscStatus "Upgrade-Console: RequiredExtensionVersion is not the same as RequiredExtensionSiteVersion.  Upgrading to $RequiredExtensionSiteVersion"
}
else {    
    # Do Nothing
    Write-DScStatus "Upgrade-Console: Console is already at the correct version Console: $ConsoleShortVersion Extensions: $RequiredExtensionSiteVersion"
    return
}





$CMInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "Installation Directory" -ErrorAction SilentlyContinue
if (-not $CMInstallDir) {
    $CMInstallDir = "E:\ConfigMgr"
}

Write-DscStatus -NoStatus "Upgrade-Console: CMInstallDir: $CMInstallDir"
if (-not (Test-Path $CMInstallDir)) {
    Write-DscStatus -NoStatus "Upgrade-Console: $CMInstallDir does not exist"
    return
}

$ConsoleUIExe = (Join-Path $CMInstallDir "\bin\I386\Consolesetup.exe") 
$LangPackDir = (Join-Path $CMInstallDir "\bin\I386\LanguagePack")
$UIInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "UI Installation Directory"  -ErrorAction SilentlyContinue
if (-not $UIInstallDir) {
    $UIInstallDir = "E:\ConfigMgr\AdminConsole"
}

Write-DscStatus -NoStatus "Upgrade-Console: UIInstallDir: $UIInstallDir"
if (-not (Test-Path $UIInstallDir)) {
    Write-DscStatus -NoStatus "Upgrade-Console: $UIInstallDir does not exist"
    return
}   

Write-DscStatus -NoStatus "Upgrade-Console: ConsoleUIExe: $ConsoleUIExe"
if (-not (Test-Path $ConsoleUIExe)) {
    Write-DscStatus -NoStatus "Upgrade-Console: $ConsoleUIExe does not exist"
    return
}   

$localsiteServer = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\AdminUI\Connection"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "server"  -ErrorAction SilentlyContinue
if (-not $localSiteServer) {
    $localsiteserver = "$($env:Computername).$($env:UserDNSDomain)"
}


Install-Console -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir -localsiteserver $localsiteserver
start-sleep -Seconds 5

$AdminConsoleVersion = Get-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "AdminConsoleVersion" -ErrorAction SilentlyContinue
$RequiredExtensionVersion = Get-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "RequiredExtensionVersion" -ErrorAction SilentlyContinue
if ($AdminConsoleVersion) {
    $ConsoleShortVersion = ([System.Version]$AdminConsoleVersion).Minor
}

Write-DscStatus -NoStatus "Upgrade-Console: Checking if the console installed successfully"


if ($RequiredExtensionVersion -eq $RequiredExtensionSiteVersion) { 
    Write-DscStatus "Console installed successfully Console: $ConsoleShortVersion Extensions: $RequiredExtensionSiteVersion"
}
else {
    
    Write-DscStatus "Console failed to install.  Retrying."
    Start-Sleep -Seconds 60
    Install-Console -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir -localsiteserver $localsiteserver

}

