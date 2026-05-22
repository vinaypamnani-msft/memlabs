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

# --- LogMachine file associations ---
$prg = "C:\tools\LogMachine\LogMachine.exe"
if (Test-Path $prg) {
    $currentAssoc = & cmd /c "assoc .log" 2>$null
    if ($currentAssoc -notlike "*LogMachine*") {
        Add-Permissions -folderPath "C:\Windows\System32\Configuration"
        Add-Permissions -folderPath "C:\Windows\System32\Configuration\ConfigurationStatus"
        & cmd /c "ftype LogMachine.LOG=`"$prg`" %1"
        & cmd /c "assoc .log=LogMachine.LOG"
        & cmd /c "assoc .lo_=LogMachine.LOG"
        & cmd /c "assoc .errlog=LogMachine.LOG"
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
        -Arguments "smscfgrc" -IconLocation $ControlPanel
}

if ($ClientlogsPath -and (Test-Path $ClientlogsPath)) {
    Add-Permissions -folderPath $ClientlogsPath
    New-Shortcut -LinkPath "$desktopPath\Client Logs.lnk" -TargetPath $ClientlogsPath
}

# --- ConfigMgr Logs shortcut (server or MP/WSUS role) ---
if (-not (Test-Path "$desktopPath\ConfigMgr Logs.lnk")) {
    if ($CMlogs -and (Test-Path $CMlogs)) {
        Add-Permissions -folderPath $CMlogs
        New-Shortcut -LinkPath "$desktopPath\ConfigMgr Logs.lnk" -TargetPath $CMlogs
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
            New-Shortcut -LinkPath "$desktopPath\ConfigMgr Logs.lnk" -TargetPath $MPLogs
        }
    }
}

# --- ConfigMgr Console + PowerShell shortcuts ---
if ($CMexe -and (Test-Path $CMexe)) {
    New-Shortcut -LinkPath "$desktopPath\ConfigMgr Console.lnk" `
        -TargetPath $CMexe -Arguments "sms:debugview"

    $psLink = "$desktopPath\ConfigMgr Powershell.lnk"
    if (-not (Test-Path $psLink)) {
        New-Shortcut -LinkPath $psLink `
            -TargetPath "powershell" `
            -Arguments "-NoExit -ExecutionPolicy Bypass C:\staging\DSC\Phases\Start-CMPS.ps1"
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
    New-Shortcut -LinkPath "$desktopPath\IIS Logs.lnk" -TargetPath $IISLogs
}

$inetMgr = "$env:windir\system32\inetsrv\InetMgr.exe"
if (Test-Path $inetMgr) {
    New-Shortcut -LinkPath "$desktopPath\IIS InetMgr.lnk" -TargetPath $inetMgr
}

# --- WSUS shortcuts ---
$wsus = "$env:ProgramFiles\Update Services\AdministrationSnapin\wsus.msc"
if (Test-Path $wsus) {
    New-Shortcut -LinkPath "$desktopPath\WSUS Console.lnk" -TargetPath $wsus
}

$WSUSLogs = "C:\Program Files\Update Services\LogFiles"
if (Test-Path $WSUSLogs) {
    Add-Permissions -folderPath $WSUSLogs
    New-Shortcut -LinkPath "$desktopPath\WSUS Logs.lnk" -TargetPath $WSUSLogs
}

# --- DP Logs shortcut ---
if (-not (Test-Path "$desktopPath\DP Logs.lnk")) {
    try {
        $val = (Get-ItemProperty 'HKLM:\SOFTWARE\Classes\CLSID\{1798F365-5C8D-47e7-80E3-EAF234320077}\InprocServer32' -Name '(default)' -ErrorAction Stop).'(default)'
        $DPLogs = Join-Path (Split-Path (Split-Path $val -Parent) -Parent) 'logs'
        if (Test-Path $DPLogs) {
            Add-Permissions -folderPath $DPLogs
            New-Shortcut -LinkPath "$desktopPath\DP Logs.lnk" -TargetPath $DPLogs
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



