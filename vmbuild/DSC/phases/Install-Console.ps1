#Install-Console.ps1
param(
    [string]$SiteServer
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
    Write-DscStatus -NoStatus "Install-Console: Uninstalling the console"
    & $ConsoleUIExe  /uninstall /q
    Start-Sleep -Seconds 5
    Wait-Process -Name ConsoleSetup -ErrorAction SilentlyContinue

    Write-DscStatus -NoStatus "Install-Console: Uninstall Complete"


    Write-DscStatus -NoStatus "Install-Console: Installing the console"
    #Install the Console
    Write-DscStatus -NoStatus "& $ConsoleUIExe /q LangPackDir=$LangPackDir TargetDir=$UIInstallDir DEFAULTSITESERVERNAME=$localsiteserver"
    & $ConsoleUIExe /q LangPackDir=$LangPackDir TargetDir=$UIInstallDir DEFAULTSITESERVERNAME=$localsiteserver
    Start-Sleep -Seconds 5
    Wait-Process -Name ConsoleSetup -ErrorAction SilentlyContinue
    Write-DscStatus -NoStatus "Install-Console: Install Complete"
}

$ConsoleUIExe = "\\$($SiteServer)\e$\ConfigMgr\tools\consoleSetup\consoleSetup.exe"


#$ConsoleUIExe = (Join-Path $CMInstallDir "\bin\I386\Consolesetup.exe") 

$UIInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "UI Installation Directory"  -ErrorAction SilentlyContinue
if (-not $UIInstallDir) {
    $UIInstallDir = "C:\AdminConsole"
}
$LangPackDir = (Join-Path $UIInstallDir "\bin\I386\LanguagePack")

Write-DscStatus -NoStatus "Install-Console: UIInstallDir: $UIInstallDir"
if (-not (Test-Path $UIInstallDir)) {
    Write-DscStatus -NoStatus "Install-Console: $UIInstallDir does not exist"
    New-Item $UIInstallDir -ItemType "directory" -force
}   

Write-DscStatus -NoStatus "Install-Console: ConsoleUIExe: $ConsoleUIExe"
if (-not (Test-Path $ConsoleUIExe)) {
    Write-DscStatus -NoStatus "Install-Console: $ConsoleUIExe does not exist"
    return
}   

$localSiteServer = $SiteServer
#$localsiteServer = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\AdminUI\Connection"  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "server"  -ErrorAction SilentlyContinue
#if (-not $localSiteServer) {
#    $localsiteserver = "$($env:Computername).$($env:UserDNSDomain)"
#}


Install-Console -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir -localsiteserver $localsiteserver
start-sleep -Seconds 5

