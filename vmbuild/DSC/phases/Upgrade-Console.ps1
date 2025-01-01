#Upgrade-Console.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)
#"E:\ConfigMgr\bin\I386\ConsoleSetup.exe" LangPackDir="E:\ConfigMgr\bin\i386\LanguagePack" TargetDir="E:\ConfigMgr\AdminConsole" DEFAULTSITESERVERNAME="ADA-PS1SITE.adatum.com"
#SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup

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

$content = Get-Content "C:\ConfigMgrAdminUISetup.log" -tail 1 -ErrorAction SilentlyContinue
if (-not $content -like "*Starting to execute install extensions command line*") {
    Write-DscStatus "Console failed to install.  Retrying."
    Start-Sleep -Seconds 60
    Install-Console -ConsoleUIExe $ConsoleUIExe -LangPackDir $LangPackDir -UIInstallDir $UIInstallDir -localsiteserver $localsiteserver

}
else {
    Write-DscStatus "Console installed successfully"
}

