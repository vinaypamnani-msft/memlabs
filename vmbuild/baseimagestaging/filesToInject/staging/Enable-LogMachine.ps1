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
    # 1) System-level: assoc/ftype (legacy fallback)
    $currentAssoc = & cmd /c "assoc .log" 2>$null
    if ($currentAssoc -notlike "*LogMachine*") {
        Write-Status "Registering LogMachine file associations (assoc/ftype)..."
        Add-Permissions -folderPath "C:\Windows\System32\Configuration"
        Add-Permissions -folderPath "C:\Windows\System32\Configuration\ConfigurationStatus"
        & cmd /c "ftype LogMachine.LOG=`"$prg`" %1" 2>&1 | Out-Null
        & cmd /c "assoc .log=LogMachine.LOG" 2>&1 | Out-Null
        & cmd /c "assoc .lo_=LogMachine.LOG" 2>&1 | Out-Null
        & cmd /c "assoc .errlog=LogMachine.LOG" 2>&1 | Out-Null
    }

    # 2) Register ProgId properly in registry (enables Windows app picker to find it)
    $progIdPath = "HKLM:\SOFTWARE\Classes\LogMachine.LOG"
    if (-not (Test-Path "$progIdPath\shell\open\command")) {
        New-Item -Path "$progIdPath\shell\open\command" -Force | Out-Null
    }
    Set-ItemProperty -Path $progIdPath -Name "(Default)" -Value "LogMachine Log Viewer" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "$progIdPath\shell\open\command" -Name "(Default)" -Value "`"$prg`" `"%1`"" -ErrorAction SilentlyContinue
    # Set icon
    if (-not (Test-Path "$progIdPath\DefaultIcon")) {
        New-Item -Path "$progIdPath\DefaultIcon" -Force | Out-Null
    }
    Set-ItemProperty -Path "$progIdPath\DefaultIcon" -Name "(Default)" -Value "`"$prg`",0" -ErrorAction SilentlyContinue

    # 3) Per-user: remove any existing UserChoice so Windows uses system default
    #    UserChoice keys are ACL-protected; take ownership first
    $extensions = @('.log', '.lo_', '.errlog')
    foreach ($ext in $extensions) {
        $ucPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice"
        if (Test-Path $ucPath) {
            try {
                $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
                    "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice",
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                    [System.Security.AccessControl.RegistryRights]::TakeOwnership)
                if ($key) {
                    $acl = $key.GetAccessControl()
                    $acl.SetOwner([System.Security.Principal.NTAccount]$env:USERNAME)
                    $key.SetAccessControl($acl)
                    $key.Close()

                    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice",
                        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                        [System.Security.AccessControl.RegistryRights]::ChangePermissions)
                    $acl = $key.GetAccessControl()
                    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                        $env:USERNAME, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
                    $acl.SetAccessRule($rule)
                    $key.SetAccessControl($acl)
                    $key.Close()

                    # Now delete it
                    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
                        "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice", $false)
                    Write-Status "Removed UserChoice for $ext"
                }
            }
            catch {
                Write-Status "Could not remove UserChoice for $ext`: $_"
            }
        }

        # Set OpenWithProgids to only LogMachine.LOG
        $owPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\OpenWithProgids"
        if (-not (Test-Path $owPath)) { New-Item -Path $owPath -Force | Out-Null }
        # Remove any existing values (e.g. txtfile, Notepad)
        $existing = Get-Item -Path $owPath -ErrorAction SilentlyContinue
        if ($existing) {
            foreach ($val in $existing.GetValueNames()) {
                if ($val -and $val -ne "LogMachine.LOG") {
                    Remove-ItemProperty -Path $owPath -Name $val -ErrorAction SilentlyContinue
                }
            }
        }
        New-ItemProperty -Path $owPath -Name "LogMachine.LOG" -PropertyType None -ErrorAction SilentlyContinue | Out-Null
    }

    # 4) GPO: Set default associations XML (applies to new user profiles on this machine)
    $xmlPath = "C:\tools\LogMachine\DefaultAssociations.xml"
    $xmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier=".log" ProgId="LogMachine.LOG" ApplicationName="LogMachine" />
  <Association Identifier=".lo_" ProgId="LogMachine.LOG" ApplicationName="LogMachine" />
  <Association Identifier=".errlog" ProgId="LogMachine.LOG" ApplicationName="LogMachine" />
</DefaultAssociations>
"@
    $xmlContent | Out-File -FilePath $xmlPath -Encoding UTF8 -Force -ErrorAction SilentlyContinue
    $gpoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    if (-not (Test-Path $gpoPath)) { New-Item -Path $gpoPath -Force | Out-Null }
    Set-ItemProperty -Path $gpoPath -Name "DefaultAssociationsConfiguration" -Value $xmlPath -Type String -ErrorAction SilentlyContinue

    # Verify
    $verifyAssoc = & cmd /c "assoc .log" 2>$null
    $verifyFtype = & cmd /c "ftype LogMachine.LOG" 2>$null
    if ($verifyAssoc -like "*LogMachine*" -and $verifyFtype -like "*LogMachine.exe*") {
        Write-Status "OK: LogMachine registered. assoc=$verifyAssoc ftype=$verifyFtype (UserChoice cleared, GPO set)"
    }
    else {
        Write-Status "FAIL: Verification failed. assoc='$verifyAssoc' ftype='$verifyFtype'"
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



