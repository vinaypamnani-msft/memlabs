#Upgrade-Console.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)
#"E:\ConfigMgr\bin\I386\ConsoleSetup.exe" LangPackDir="E:\ConfigMgr\bin\i386\LanguagePack" TargetDir="E:\ConfigMgr\AdminConsole" DEFAULTSITESERVERNAME="ADA-PS1SITE.adatum.com"
#SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup

$CMInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "Installation Directory" -ErrorAction SilentlyContinue
if (-not $CMInstallDir) {
$CMInstallDir = "E:\ConfigMgr"
}

Write-Host "CMInstallDir: $CMInstallDir"
if (-not (Test-Path $CMInstallDir)) {
Write-Host "$CMInstallDir does not exist"
return
}

$ConsoleUIExe = (Join-Path $CMInstallDir "\bin\I386\Consolesetup.exe") 
$LangPackDir = (Join-Path $CMInstallDir "\bin\I386\LanguagePack")
$UIInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "UI Installation Directory"  -ErrorAction SilentlyContinue
if (-not $UIInstallDir) {
$UIInstallDir = "E:\ConfigMgr\AdminConsole"
}

Write-Host "UIInstallDir: $UIInstallDir"
if (-not (Test-Path $UIInstallDir)) {
Write-Host "$UIInstallDir does not exist"
return
}   

Write-Host "ConsoleUIExe: $ConsoleUIExe"
if (-not (Test-Path $ConsoleUIExe)) {
Write-Host "$ConsoleUIExe does not exist"
return
}   

$localsiteServer = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\AdminUI\Connection"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "server"  -ErrorAction SilentlyContinue
if (-not $localSiteServer) {
$localsiteserver = "$($env:Computername).$($env:UserDNSDomain)"
}

#Uninstall the console
Write-Host "Uninstalling the console"
& $ConsoleUIExe  /uninstall /q
Wait-Process -Name ConsoleSetup

Write-Host "Installing the console"
#Install the Console
& $ConsoleUIExe /q LangPackDir=$LangPackDir TargetDir=$UIInstallDir DEFAULTSITESERVERNAME=$localsiteserver
Wait-Process -Name ConsoleSetup