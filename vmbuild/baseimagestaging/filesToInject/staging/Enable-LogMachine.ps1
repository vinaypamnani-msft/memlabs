#Enable-LogMachine.ps1
$fixFlag = "EnableLogMachine.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag

if (-not (Test-Path $flagPath)) {
    $prg = "C:\tools\LogMachine\LogMachine.exe"
    $ext = '.log'
    & cmd /c "ftype LogMachine.LOG=`"$prg`" %1"
    & cmd /c "assoc $ext=LogMachine.LOG"
    $ext = '.lo_'
    & cmd /c "ftype LogMachine.LOG=`"$prg`" %1"
    & cmd /c "assoc $ext=LogMachine.LOG"
    $ext = '.errlog'
    & cmd /c "ftype LogMachine.LOG=`"$prg`" %1"
    & cmd /c "assoc $ext=LogMachine.LOG"
    "LogMachine Enabled" | Out-File $flagPath -Force
}


$desktopPath = [Environment]::GetFolderPath("CommonDesktop")

$fixFlag = "ClientShortcuts.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag
if (-not (Test-Path $flagPath)) {
    # Define the paths
    $ClientlogsPath = "c:\windows\ccm\logs"
    $sccmAppletPath = "C:\Windows\System32\control.exe"
    $iconPath = "C:\Windows\CCM\SMSCFGRC.cpl"
    $CMlogs = "E:\ConfigMgr\Logs"

    if ((Test-Path $ClientlogsPath)) {
    
        # Create the MECM Control Panel Applet shortcut
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$desktopPath\SCCM Control Panel Applet.lnk")
        $shortcut.TargetPath = $sccmAppletPath
        $shortcut.Arguments = "smscfgrc"
        $shortcut.IconLocation = $iconPath
        $shortcut.Save()

        # Create the Logs shortcut
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$desktopPath\Client Logs.lnk")
        $shortcut.TargetPath = $ClientlogsPath
        $shortcut.Save()
        "Shortcuts Enabled" | Out-File $flagPath -Force

    }
}

$fixFlag = "ServerShortcuts.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag
if (-not (Test-Path $flagPath)) {
    # Define the paths
    $CMlogs = "E:\ConfigMgr\Logs"
    # Check if the new path exists
    if (Test-Path $CMlogs) {
        # Create the new shortcut if the path exists
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$desktopPath\ConfigMgr Logs.lnk")
        $shortcut.TargetPath = $CMlogs
        $shortcut.Save()
        "Shortcuts Enabled" | Out-File $flagPath -Force
    }
}

$fixFlag = "MPShortcuts.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag
if (-not (Test-Path $flagPath)) {
    # Define the paths
    $CMlogs = "E:\SMS_CCM\Logs"
    # Check if the new path exists
    if (Test-Path $CMlogs) {
        # Create the new shortcut if the path exists
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$desktopPath\ConfigMgr MP Logs.lnk")
        $shortcut.TargetPath = $CMlogs
        $shortcut.Save()
        "Shortcuts Enabled" | Out-File $flagPath -Force
    }
}

$fixFlag = "MPShortcuts2.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag
if (-not (Test-Path $flagPath)) {
    # Define the paths
    $sccmAppletPath = "C:\Windows\System32\control.exe"
    $iconPath = "E:\SMS_CCM\SMSCFGRC.cpl"
    # Check if the new path exists
   
    # Create the MECM Control Panel Applet shortcut
    if (Test-Path $iconPath) {
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$desktopPath\SCCM Control Panel Applet.lnk")
        $shortcut.TargetPath = $sccmAppletPath
        $shortcut.Arguments = "smscfgrc"
        $shortcut.IconLocation = $iconPath
        $shortcut.Save()
        "Shortcuts Enabled" | Out-File $flagPath -Force
    }

}


$fixFlag = "IISShortcuts.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag
if (-not (Test-Path $flagPath)) {
    # Define the paths
    $IISLogs = "C:\inetpub\logs"
    # Check if the new path exists
    if (Test-Path $IISLogs) {
        # Create the new shortcut if the path exists

        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$desktopPath\IIS Logs.lnk")
        $shortcut.TargetPath = $IISLogs
        $shortcut.Save()
        "Shortcuts Enabled" | Out-File $flagPath -Force
    }
}

$fixFlag = "WSUSShortcuts.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag
if (-not (Test-Path $flagPath)) {
    # Define the paths
    $WSUSLogs = "C:\Program Files\Update Services\LogFiles"
    # Check if the new path exists
    if (Test-Path $WSUSLogs) {
        # Create the new shortcut if the path exists

        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$desktopPath\WSUS Logs.lnk")
        $shortcut.TargetPath = $WSUSLogs
        $shortcut.Save()
        "Shortcuts Enabled" | Out-File $flagPath -Force
    }
}

