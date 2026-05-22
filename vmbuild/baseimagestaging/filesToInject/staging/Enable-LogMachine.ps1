# Enable-LogMachine.ps1
# Idempotent: checks actual shortcut/assoc existence, not flag files.

function Add-Permissions {
    param([string]$folderPath)
    if (-not (Test-Path $folderPath)) { return }
    $acl = Get-Acl $folderPath
    $permission = "Read"
    $inheritance = "ContainerInherit, ObjectInherit"
    $propagation = "None"
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:UserName, $permission, $inheritance, $propagation, "Allow")
    $acl.SetAccessRule($accessRule)
    Set-Acl $folderPath $acl
}

function New-Shortcut {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$Arguments,
        [string]$IconLocation
    )
    if (Test-Path $LinkPath) { return $false }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LinkPath)
    $shortcut.TargetPath = $TargetPath
    if ($Arguments) { $shortcut.Arguments = $Arguments }
    if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
    $shortcut.Save()
    if (Test-Path $LinkPath) {
        $script:shortcutsCreated = $true
        return $true
    }
    return $false
}

$script:shortcutsCreated = $false
$logFile = "$env:systemdrive\staging\Enable-LogMachine.log"

function Write-Status {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Force -ErrorAction SilentlyContinue
}

# --- LogMachine file associations ---
$prg = "C:\tools\LogMachine\LogMachine.exe"
if (-not (Test-Path $prg)) {
    Write-Status "FAIL: LogMachine.exe not found at '$prg'. Cannot register file associations."
}
else {
    $currentAssoc = & cmd /c "assoc .log" 2>$null
    if ($currentAssoc -like "*LogMachine*") {
        Write-Status "OK: LogMachine already registered (.log -> $currentAssoc)"
    }
    else {
        Write-Status "Registering LogMachine file associations..."
        Add-Permissions -folderPath "C:\Windows\System32\Configuration"
        Add-Permissions -folderPath "C:\Windows\System32\Configuration\ConfigurationStatus"
        & cmd /c "ftype LogMachine.LOG=`"$prg`" %1" 2>&1 | Out-Null
        & cmd /c "assoc .log=LogMachine.LOG" 2>&1 | Out-Null
        & cmd /c "assoc .lo_=LogMachine.LOG" 2>&1 | Out-Null
        & cmd /c "assoc .errlog=LogMachine.LOG" 2>&1 | Out-Null

        # Verify registration succeeded
        $verifyAssoc = & cmd /c "assoc .log" 2>$null
        $verifyFtype = & cmd /c "ftype LogMachine.LOG" 2>$null
        if ($verifyAssoc -like "*LogMachine*" -and $verifyFtype -like "*LogMachine.exe*") {
            Write-Status "OK: LogMachine registered successfully. assoc=$verifyAssoc ftype=$verifyFtype"
        }
        else {
            Write-Status "FAIL: Registration commands ran but verification failed. assoc='$verifyAssoc' ftype='$verifyFtype'"
        }
    }
}

# --- Gather paths ---
$CMInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty "Installation Directory" -ErrorAction SilentlyContinue
if ($CMInstallDir) {
    $CMlogs = Join-Path $CMInstallDir "Logs"
}

$UIInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty "UI Installation Directory" -ErrorAction SilentlyContinue
if (-not $UIInstallDir) {
    $UIInstallDir = Get-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\Setup" -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty "UI Installation Directory" -ErrorAction SilentlyContinue
}
if ($UIInstallDir) {
    $CMexe = Join-Path $UIInstallDir "bin\Microsoft.ConfigurationManagement.exe"
}

$ControlPanel = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\Cpls" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty "SMSCFGRC" -ErrorAction SilentlyContinue

$ClientPath = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Services\CcmExec" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty "ImagePath" -ErrorAction SilentlyContinue | Split-Path -Parent -ErrorAction SilentlyContinue
if ($ClientPath) {
    $ClientlogsPath = Join-Path $ClientPath "Logs"
}

$desktopPath = [Environment]::GetFolderPath("CommonDesktop")

# --- Client shortcuts ---
if ($ControlPanel) {
    New-Shortcut -LinkPath "$desktopPath\SCCM Control Panel Applet.lnk" `
        -TargetPath "C:\Windows\System32\control.exe" `
        -Arguments "smscfgrc" -IconLocation $ControlPanel | Out-Null
}

if ($ClientlogsPath -and (Test-Path $ClientlogsPath)) {
    Add-Permissions -folderPath $ClientlogsPath
    New-Shortcut -LinkPath "$desktopPath\Client Logs.lnk" -TargetPath $ClientlogsPath | Out-Null
}

# --- ConfigMgr Logs shortcut (server or MP/WSUS role) ---
if (-not (Test-Path "$desktopPath\ConfigMgr Logs.lnk")) {
    if ($CMlogs -and (Test-Path $CMlogs)) {
        Add-Permissions -folderPath $CMlogs
        New-Shortcut -LinkPath "$desktopPath\ConfigMgr Logs.lnk" -TargetPath $CMlogs | Out-Null
    }
    else {
        # Try MP or WSUS tracing path
        $MPLogs = $null
        try {
            $MPLogs = Split-Path ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Tracing\SMS_MP_CONTROL_MANAGER' -Name 'TraceFileName' -ErrorAction Stop).TraceFileName)
        }
        catch {}
        if (-not $MPLogs) {
            try {
                $MPLogs = Split-Path ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Tracing\SMS_WSUS_CONTROL_MANAGER' -Name 'TraceFileName' -ErrorAction Stop).TraceFileName)
            }
            catch {}
        }
        if ($MPLogs -and (Test-Path $MPLogs)) {
            Add-Permissions -folderPath $MPLogs
            New-Shortcut -LinkPath "$desktopPath\ConfigMgr Logs.lnk" -TargetPath $MPLogs | Out-Null
        }
    }
}

# --- ConfigMgr Console + PowerShell shortcuts ---
if ($CMexe -and (Test-Path $CMexe)) {
    New-Shortcut -LinkPath "$desktopPath\ConfigMgr Console.lnk" `
        -TargetPath $CMexe -Arguments "sms:debugview" | Out-Null

    $psLink = "$desktopPath\ConfigMgr Powershell.lnk"
    if (-not (Test-Path $psLink)) {
        New-Shortcut -LinkPath $psLink `
            -TargetPath "powershell" `
            -Arguments "-NoExit -ExecutionPolicy Bypass C:\staging\DSC\Phases\Start-CMPS.ps1" | Out-Null
        if (Test-Path $psLink) {
            # Set RunAsAdmin flag in .lnk header
            $bytes = [System.IO.File]::ReadAllBytes($psLink)
            $bytes[0x15] = $bytes[0x15] -bor 0x20
            [System.IO.File]::WriteAllBytes($psLink, $bytes)
        }
    }
}

# --- IIS shortcuts ---
$IISLogs = "C:\inetpub\logs"
if (Test-Path $IISLogs) {
    Add-Permissions -folderPath $IISLogs
    New-Shortcut -LinkPath "$desktopPath\IIS Logs.lnk" -TargetPath $IISLogs | Out-Null
}

$inetMgr = "$env:windir\system32\inetsrv\InetMgr.exe"
if (Test-Path $inetMgr) {
    New-Shortcut -LinkPath "$desktopPath\IIS InetMgr.lnk" -TargetPath $inetMgr | Out-Null
}

# --- WSUS shortcuts ---
$wsus = "$env:ProgramFiles\Update Services\AdministrationSnapin\wsus.msc"
if (Test-Path $wsus) {
    New-Shortcut -LinkPath "$desktopPath\WSUS Console.lnk" -TargetPath $wsus | Out-Null
}

$WSUSLogs = "C:\Program Files\Update Services\LogFiles"
if (Test-Path $WSUSLogs) {
    Add-Permissions -folderPath $WSUSLogs
    New-Shortcut -LinkPath "$desktopPath\WSUS Logs.lnk" -TargetPath $WSUSLogs | Out-Null
}

# --- DP Logs shortcut ---
if (-not (Test-Path "$desktopPath\DP Logs.lnk")) {
    try {
        $val = (Get-ItemProperty 'HKLM:\SOFTWARE\Classes\CLSID\{1798F365-5C8D-47e7-80E3-EAF234320077}\InprocServer32' -Name '(default)' -ErrorAction Stop).'(default)'
        $DPLogs = Join-Path (Split-Path (Split-Path $val -Parent) -Parent) 'logs'
        if (Test-Path $DPLogs) {
            Add-Permissions -folderPath $DPLogs
            New-Shortcut -LinkPath "$desktopPath\DP Logs.lnk" -TargetPath $DPLogs | Out-Null
        }
    }
    catch {}
}

# --- Clean up legacy flag files ---
$legacyFlags = @(
    "EnableLogMachine.done", "ClientShortcuts.done", "ServerShortcuts2.done",
    "MPLogshortcuts.done", "ServerShortcuts3.done", "IISShortcuts.done",
    "IISShortcuts2.done", "WSUSShortcuts2.done", "WSUSShortcuts.done", "DPLogshortcuts.done"
)
foreach ($flag in $legacyFlags) {
    $fp = Join-Path $env:USERPROFILE $flag
    if (Test-Path $fp) { Remove-Item $fp -Force }
}

# --- Refresh desktop icon layout if any shortcuts were created ---
if ($script:shortcutsCreated) {
    # Notify Explorer so it auto-arranges new icons into the grid
    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class DesktopRefresh {
            [DllImport("user32.dll", SetLastError = true)]
            public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
            [DllImport("user32.dll", SetLastError = true)]
            public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
            [DllImport("user32.dll")]
            public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
        }
"@ -ErrorAction SilentlyContinue
    try {
        $progman = [DesktopRefresh]::FindWindow("Progman", "Program Manager")
        if ($progman -ne [IntPtr]::Zero) {
            # WM_COMMAND with sort-by-name (0x7041)
            [DesktopRefresh]::SendMessage($progman, 0x111, [IntPtr]0x7041, [IntPtr]::Zero) | Out-Null
        }
    }
    catch {}
}



