# Enable-LogMachine.ps1
# Idempotent: checks actual shortcut/assoc existence, not flag files.

function Add-Permissions {
    param(
        [string]$folderPath,
        [switch]$GrantAncestors
    )
    if (-not (Test-Path $folderPath)) { return }

    # The interactive lab user is always a local Administrator, so grant the
    # BUILTIN\Administrators group (covers whoever logs in) in addition to the
    # current account. Log folders under installer-created protected roots
    # (SMS_DP$, C:\PBIRS) break ACL inheritance and don't include the interactive
    # admin, which is why the shortcut/Explorer reported "cannot be accessed"
    # until the user manually clicked Continue.
    $identities = @('BUILTIN\Administrators')
    if ($env:UserName -and $env:UserName -ne 'SYSTEM') { $identities += $env:UserName }

    # Grant Read+Execute (with inheritance) on the target log folder itself.
    foreach ($id in $identities) {
        try {
            $acl = Get-Acl $folderPath
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $id, 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
            $acl.SetAccessRule($rule)
            Set-Acl -Path $folderPath -AclObject $acl -ErrorAction Stop
        }
        catch {
            # Fall back to icacls, which can lean on privileges Set-Acl can't.
            try { & icacls "$folderPath" /grant "${id}:(OI)(CI)RX" /T /C 2>$null | Out-Null } catch { }
        }
    }

    # For deep targets under a protected root, grant traverse/list on each
    # ancestor (up to, but not including, the drive root) so the shell can
    # resolve the path -- the shortcut resolver does not rely on the
    # BypassTraverseChecking privilege the way a plain file open does.
    if ($GrantAncestors) {
        $parent = Split-Path $folderPath -Parent
        while ($parent) {
            $grand = Split-Path $parent -Parent
            if (-not $grand) { break }   # reached the drive root (e.g. E:\)
            foreach ($id in $identities) {
                try {
                    $pacl = Get-Acl $parent
                    $prule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $id, 'ReadAndExecute', 'None', 'None', 'Allow')
                    $pacl.SetAccessRule($prule)
                    Set-Acl -Path $parent -AclObject $pacl -ErrorAction Stop
                }
                catch {
                    try { & icacls "$parent" /grant "${id}:(RX)" /C 2>$null | Out-Null } catch { }
                }
            }
            $parent = $grand
        }
    }
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

# --- LogMachine file associations (Windows 10/11 UserChoice hash method) ---
$prg = "C:\tools\LogMachine\LogMachine.exe"
if (-not (Test-Path $prg)) {
    Write-Status "FAIL: LogMachine.exe not found at '$prg'. Cannot register file associations."
}
else {
    # --- Helper functions for computing UserChoice hash (from PS-SFTA / MIT license) ---
    function Get-ShiftRight {
        param ([long]$iValue, [int]$iCount)
        if ($iValue -band 0x80000000) { ($iValue -shr $iCount) -bxor 0xFFFF0000 }
        else { $iValue -shr $iCount }
    }

    function Get-Long {
        param ([byte[]]$Bytes, [int]$Index = 0)
        [BitConverter]::ToInt32($Bytes, $Index)
    }

    function Convert-Int32 {
        param ([long]$Value)
        [BitConverter]::ToInt32([BitConverter]::GetBytes($Value), 0)
    }

    function Get-Hash {
        param ([string]$BaseInfo)
        [byte[]]$bytesBaseInfo = [System.Text.Encoding]::Unicode.GetBytes($BaseInfo)
        $bytesBaseInfo += 0x00, 0x00
        $MD5 = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
        [byte[]]$bytesMD5 = $MD5.ComputeHash($bytesBaseInfo)
        $lengthBase = ($BaseInfo.Length * 2) + 2
        $length = (($lengthBase -band 4) -le 1) + (Get-ShiftRight $lengthBase 2) - 1
        $base64Hash = ""
        if ($length -gt 1) {
            $map = @{PDATA = 0; CACHE = 0; COUNTER = 0; INDEX = 0; MD51 = 0; MD52 = 0; OUTHASH1 = 0; OUTHASH2 = 0;
                R0 = 0; R1 = @(0, 0); R2 = @(0, 0); R3 = 0; R4 = @(0, 0); R5 = @(0, 0); R6 = @(0, 0); R7 = @(0, 0)}
            $map.CACHE = 0; $map.OUTHASH1 = 0; $map.PDATA = 0
            $map.MD51 = (((Get-Long $bytesMD5) -bor 1) + 0x69FB0000L)
            $map.MD52 = ((Get-Long $bytesMD5 4) -bor 1) + 0x13DB0000L
            $map.INDEX = Get-ShiftRight ($length - 2) 1
            $map.COUNTER = $map.INDEX + 1
            while ($map.COUNTER) {
                $map.R0 = Convert-Int32 ((Get-Long $bytesBaseInfo $map.PDATA) + [long]$map.OUTHASH1)
                $map.R1[0] = Convert-Int32 (Get-Long $bytesBaseInfo ($map.PDATA + 4))
                $map.PDATA = $map.PDATA + 8
                $map.R2[0] = Convert-Int32 (($map.R0 * ([long]$map.MD51)) - (0x10FA9605L * ((Get-ShiftRight $map.R0 16))))
                $map.R2[1] = Convert-Int32 ((0x79F8A395L * ([long]$map.R2[0])) + (0x689B6B9FL * (Get-ShiftRight $map.R2[0] 16)))
                $map.R3 = Convert-Int32 ((0xEA970001L * $map.R2[1]) - (0x3C101569L * (Get-ShiftRight $map.R2[1] 16)))
                $map.R4[0] = Convert-Int32 ($map.R3 + $map.R1[0])
                $map.R5[0] = Convert-Int32 ($map.CACHE + $map.R3)
                $map.R6[0] = Convert-Int32 (($map.R4[0] * [long]$map.MD52) - (0x3CE8EC25L * (Get-ShiftRight $map.R4[0] 16)))
                $map.R6[1] = Convert-Int32 ((0x59C3AF2DL * $map.R6[0]) - (0x2232E0F1L * (Get-ShiftRight $map.R6[0] 16)))
                $map.OUTHASH1 = Convert-Int32 ((0x1EC90001L * $map.R6[1]) + (0x35BD1EC9L * (Get-ShiftRight $map.R6[1] 16)))
                $map.OUTHASH2 = Convert-Int32 ([long]$map.R5[0] + [long]$map.OUTHASH1)
                $map.CACHE = ([long]$map.OUTHASH2)
                $map.COUNTER = $map.COUNTER - 1
            }
            [byte[]]$outHash = @(0x00) * 16
            [BitConverter]::GetBytes($map.OUTHASH1).CopyTo($outHash, 0)
            [BitConverter]::GetBytes($map.OUTHASH2).CopyTo($outHash, 4)

            $map = @{PDATA = 0; CACHE = 0; COUNTER = 0; INDEX = 0; MD51 = 0; MD52 = 0; OUTHASH1 = 0; OUTHASH2 = 0;
                R0 = 0; R1 = @(0, 0); R2 = @(0, 0); R3 = 0; R4 = @(0, 0); R5 = @(0, 0); R6 = @(0, 0); R7 = @(0, 0)}
            $map.CACHE = 0; $map.OUTHASH1 = 0; $map.PDATA = 0
            $map.MD51 = ((Get-Long $bytesMD5) -bor 1)
            $map.MD52 = ((Get-Long $bytesMD5 4) -bor 1)
            $map.INDEX = Get-ShiftRight ($length - 2) 1
            $map.COUNTER = $map.INDEX + 1
            while ($map.COUNTER) {
                $map.R0 = Convert-Int32 ((Get-Long $bytesBaseInfo $map.PDATA) + ([long]$map.OUTHASH1))
                $map.PDATA = $map.PDATA + 8
                $map.R1[0] = Convert-Int32 ($map.R0 * [long]$map.MD51)
                $map.R1[1] = Convert-Int32 ((0xB1110000L * $map.R1[0]) - (0x30674EEFL * (Get-ShiftRight $map.R1[0] 16)))
                $map.R2[0] = Convert-Int32 ((0x5B9F0000L * $map.R1[1]) - (0x78F7A461L * (Get-ShiftRight $map.R1[1] 16)))
                $map.R2[1] = Convert-Int32 ((0x12CEB96DL * (Get-ShiftRight $map.R2[0] 16)) - (0x46930000L * $map.R2[0]))
                $map.R3 = Convert-Int32 ((0x1D830000L * $map.R2[1]) + (0x257E1D83L * (Get-ShiftRight $map.R2[1] 16)))
                $map.R4[0] = Convert-Int32 ([long]$map.MD52 * ([long]$map.R3 + (Get-Long $bytesBaseInfo ($map.PDATA - 4))))
                $map.R4[1] = Convert-Int32 ((0x16F50000L * $map.R4[0]) - (0x5D8BE90BL * (Get-ShiftRight $map.R4[0] 16)))
                $map.R5[0] = Convert-Int32 ((0x96FF0000L * $map.R4[1]) - (0x2C7C6901L * (Get-ShiftRight $map.R4[1] 16)))
                $map.R5[1] = Convert-Int32 ((0x2B890000L * $map.R5[0]) + (0x7C932B89L * (Get-ShiftRight $map.R5[0] 16)))
                $map.OUTHASH1 = Convert-Int32 ((0x9F690000L * $map.R5[1]) - (0x405B6097L * (Get-ShiftRight ($map.R5[1]) 16)))
                $map.OUTHASH2 = Convert-Int32 ([long]$map.OUTHASH1 + $map.CACHE + $map.R3)
                $map.CACHE = ([long]$map.OUTHASH2)
                $map.COUNTER = $map.COUNTER - 1
            }
            [BitConverter]::GetBytes($map.OUTHASH1).CopyTo($outHash, 8)
            [BitConverter]::GetBytes($map.OUTHASH2).CopyTo($outHash, 12)

            [byte[]]$outHashBase = @(0x00) * 8
            $hashValue1 = ((Get-Long $outHash 8) -bxor (Get-Long $outHash))
            $hashValue2 = ((Get-Long $outHash 12) -bxor (Get-Long $outHash 4))
            [BitConverter]::GetBytes($hashValue1).CopyTo($outHashBase, 0)
            [BitConverter]::GetBytes($hashValue2).CopyTo($outHashBase, 4)
            $base64Hash = [Convert]::ToBase64String($outHashBase)
        }
        Write-Output $base64Hash
    }

    # The "User Experience" string is embedded in Shell32.dll. It has been
    # identical across all Windows 10/11 builds (10240 through 26100+).
    # Hardcoding avoids the fragile 5MB binary scan of Shell32.dll.
    $script:UserExperience = "User Choice set via Windows User Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}"

    function Get-HexDateTime {
        $now = [DateTime]::Now
        $dateTime = [DateTime]::New($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, 0)
        $fileTime = $dateTime.ToFileTime()
        $hi = ($fileTime -shr 32)
        $low = ($fileTime -band 0xFFFFFFFFL)
        ($hi.ToString("X8") + $low.ToString("X8")).ToLower()
    }

    function Set-FileTypeAssociation {
        param ([string]$Extension, [string]$ProgId, [int]$MaxRetries = 2)

        # Get user SID (domain-aware)
        $userSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User).Value.ToLower()
        $userDateTime = Get-HexDateTime

        $baseInfo = "$Extension$userSid$ProgId$userDateTime$script:UserExperience".ToLower()
        $progHash = Get-Hash $baseInfo

        if (-not $progHash) {
            Write-Status "FAIL: Could not compute hash for $Extension"
            return $false
        }

        # Write ApplicationAssociationToasts to prevent "new app" notification
        $toastKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"
        if (-not (Test-Path $toastKey)) { New-Item -Path $toastKey -Force | Out-Null }
        Set-ItemProperty -Path $toastKey -Name "${ProgId}_$Extension" -Value 0 -Type DWord -ErrorAction SilentlyContinue

        # Delete existing UserChoice key using P/Invoke (ACL-protected)
        $deleteCode = @'
using System;
using System.Runtime.InteropServices;
namespace RegHelper {
    public class Utils {
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern int RegOpenKeyEx(UIntPtr hKey, string subKey, int ulOptions, int samDesired, out UIntPtr hkResult);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern uint RegDeleteKey(UIntPtr hKey, string subKey);
        public static void DeleteKey(string key) {
            UIntPtr hKey = UIntPtr.Zero;
            RegOpenKeyEx((UIntPtr)0x80000001u, key, 0, 0x20019, out hKey);
            RegDeleteKey((UIntPtr)0x80000001u, key);
        }
    }
}
'@
        try { Add-Type -TypeDefinition $deleteCode -ErrorAction SilentlyContinue } catch {}

        $ucKeyPath = "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Extension\UserChoice"
        try { [RegHelper.Utils]::DeleteKey($ucKeyPath) } catch {}

        # Write new UserChoice with ProgId and computed Hash
        # Retry loop: Explorer can race and reset UserChoice between delete and write
        $fullKeyPath = "HKEY_CURRENT_USER\$ucKeyPath"
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            if ($attempt -gt 1) {
                # Re-delete and recompute hash (timestamp may have rolled over to next minute)
                Start-Sleep -Milliseconds 200
                try { [RegHelper.Utils]::DeleteKey($ucKeyPath) } catch {}
                $userDateTime = Get-HexDateTime
                $baseInfo = "$Extension$userSid$ProgId$userDateTime$script:UserExperience".ToLower()
                $progHash = Get-Hash $baseInfo
                if (-not $progHash) { return $false }
            }

            try {
                [Microsoft.Win32.Registry]::SetValue($fullKeyPath, "Hash", $progHash)
                [Microsoft.Win32.Registry]::SetValue($fullKeyPath, "ProgId", $ProgId)
            }
            catch {
                Write-Status "FAIL: Could not write UserChoice for $Extension (attempt $attempt): $_"
                continue
            }

            # Verify the write stuck
            $verify = (Get-ItemProperty "HKCU:\$ucKeyPath" -ErrorAction SilentlyContinue).ProgId
            if ($verify -eq $ProgId) { return $true }
        }
        return $false
    }

    # --- End helper functions ---

    # 1) Register ProgId in HKLM + HKCU Classes (makes LogMachine visible to shell)
    foreach ($root in @("HKLM:\SOFTWARE\Classes\LogMachine.LOG", "HKCU:\SOFTWARE\Classes\LogMachine.LOG")) {
        if (-not (Test-Path "$root\shell\open\command")) {
            New-Item -Path "$root\shell\open\command" -Force | Out-Null
        }
        Set-ItemProperty -Path $root -Name "(Default)" -Value "LogMachine Log Viewer" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "$root\shell\open\command" -Name "(Default)" -Value "`"$prg`" `"%1`"" -ErrorAction SilentlyContinue
        if (-not (Test-Path "$root\DefaultIcon")) { New-Item -Path "$root\DefaultIcon" -Force | Out-Null }
        Set-ItemProperty -Path "$root\DefaultIcon" -Name "(Default)" -Value "`"$prg`",0" -ErrorAction SilentlyContinue
    }

    # 2) System-level assoc/ftype (legacy fallback)
    $currentAssoc = & cmd /c "assoc .log" 2>$null
    if ($currentAssoc -notlike "*LogMachine*") {
        Add-Permissions -folderPath "C:\Windows\System32\Configuration"
        Add-Permissions -folderPath "C:\Windows\System32\Configuration\ConfigurationStatus"
        & cmd /c "ftype LogMachine.LOG=`"$prg`" %1" 2>&1 | Out-Null
        & cmd /c "assoc .log=LogMachine.LOG" 2>&1 | Out-Null
        & cmd /c "assoc .lo_=LogMachine.LOG" 2>&1 | Out-Null
        & cmd /c "assoc .errlog=LogMachine.LOG" 2>&1 | Out-Null
    }

    # 3) Set per-user default via UserChoice with computed hash
    $extensions = @('.log', '.lo_', '.errlog')
    $allOk = $true
    foreach ($ext in $extensions) {
        # Add to OpenWithProgids
        $owPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\OpenWithProgids"
        if (-not (Test-Path $owPath)) { New-Item -Path $owPath -Force | Out-Null }
        New-ItemProperty -Path $owPath -Name "LogMachine.LOG" -PropertyType None -ErrorAction SilentlyContinue | Out-Null

        # Check if already set correctly
        $ucPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice"
        $currentProgId = (Get-ItemProperty $ucPath -ErrorAction SilentlyContinue).ProgId
        if ($currentProgId -eq "LogMachine.LOG") {
            Write-Status "OK: $ext already set to LogMachine.LOG"
            continue
        }

        # Set the association with proper hash
        $result = Set-FileTypeAssociation -Extension $ext -ProgId "LogMachine.LOG"
        if ($result) {
            Write-Status "OK: Set $ext -> LogMachine.LOG (UserChoice with hash)"
        }
        else {
            Write-Status "FAIL: Could not set UserChoice for $ext"
            $allOk = $false
        }
    }

    # 4) Notify shell of changes
    $notifyCode = @'
[System.Runtime.InteropServices.DllImport("Shell32.dll")]
private static extern int SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
public static void Refresh() { SHChangeNotify(0x8000000, 0, IntPtr.Zero, IntPtr.Zero); }
'@
    try { Add-Type -MemberDefinition $notifyCode -Namespace SHChange -Name Notify -ErrorAction SilentlyContinue } catch {}
    try { [SHChange.Notify]::Refresh() } catch {}

    if ($allOk) {
        Write-Status "OK: LogMachine set as default handler for .log, .lo_, .errlog"
    }
}

# --- Gather paths (single registry read for SMS\Setup) ---
$smsSetup = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue
$CMInstallDir = $smsSetup | Select-Object -ExpandProperty "Installation Directory" -ErrorAction SilentlyContinue
$uiInstallCandidates = @()
try {
    $consoleRegistry = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry32)
    $consoleSetup = $consoleRegistry.OpenSubKey('SOFTWARE\Microsoft\ConfigMgr10\Setup')
    if ($consoleSetup) {
        $uiInstallCandidates += [string]$consoleSetup.GetValue('UI Installation Directory')
    }
}
catch {}
finally {
    if ($consoleSetup) { $consoleSetup.Dispose() }
    if ($consoleRegistry) { $consoleRegistry.Dispose() }
}
$smsUIInstallDir = $smsSetup | Select-Object -ExpandProperty "UI Installation Directory" -ErrorAction SilentlyContinue
if ($smsUIInstallDir) { $uiInstallCandidates += [string]$smsUIInstallDir }

$CMexe = $null
foreach ($candidate in @($uiInstallCandidates | Where-Object { $_ } | Select-Object -Unique)) {
    $candidateExe = Join-Path $candidate "bin\Microsoft.ConfigurationManagement.exe"
    if (Test-Path $candidateExe) {
        $CMexe = $candidateExe
        break
    }
}
if ($CMInstallDir) { $CMlogs = Join-Path $CMInstallDir "Logs" }

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
        foreach ($tracingKey in @('SMS_MP_CONTROL_MANAGER', 'SMS_WSUS_CONTROL_MANAGER')) {
            try {
                $MPLogs = Split-Path ((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\SMS\Tracing\$tracingKey" -Name 'TraceFileName' -ErrorAction Stop).TraceFileName)
                if ($MPLogs) { break }
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

# --- BLM Helpdesk Portal shortcut (site server only -- registry key only exists
#     after MBAMWebSiteInstaller has run, which EnableBLM phase does on the Primary) ---
$blmPortalLink = "$desktopPath\BitLocker Helpdesk Portal.url"
if (-not (Test-Path $blmPortalLink)) {
    $hasPortal = $false
    try {
        $webKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\MBAM Server\Web' -ErrorAction SilentlyContinue
        if ($webKey -and $webKey.RecoveryDBConnectionString) { $hasPortal = $true }
    } catch {}
    if ($hasPortal) {
        try {
            $fqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Domain)"
            $portalUrl = "https://$fqdn/HelpDesk/"
            # .url files are plain INI -- write directly (WScript.Shell.CreateShortcut is for .lnk only)
            $iconDll = "$env:windir\System32\imageres.dll"
            $urlBody = @("[InternetShortcut]", "URL=$portalUrl")
            if (Test-Path $iconDll) { $urlBody += @("IconFile=$iconDll", "IconIndex=77") }
            $urlBody | Out-File -FilePath $blmPortalLink -Encoding ASCII -Force
            if (Test-Path $blmPortalLink) { $script:shortcutsCreated = $true }
        }
        catch {}
    }
}

# --- Report Server (PBIRS / SSRS) shortcut ---
$rpLink = "$desktopPath\Report Server.url"
if (-not (Test-Path $rpLink)) {
    $rpSvc = Get-Service -Name 'PowerBIReportServer','SQLServerReportingServices','ReportServer' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 1
    if ($rpSvc) {
        try {
            $rpFqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Domain)"
            # Detect HTTPS by checking for an HTTPS URL reservation in WMI
            $rpScheme = 'http'
            try {
                $rpWmiNs = Get-WmiObject -Namespace root\Microsoft\SqlServer\ReportServer -Class __Namespace -ErrorAction Stop
                $rpRsName = $rpWmiNs.Name
                $rpVer = (Get-WmiObject -Namespace "root\Microsoft\SqlServer\ReportServer\$rpRsName" -Class __Namespace -ErrorAction Stop).Name
                $rpCfg = Get-WmiObject -Namespace "root\Microsoft\SqlServer\ReportServer\$rpRsName\$rpVer\Admin" -Class MSReportServer_ConfigurationSetting -ErrorAction Stop
                $rpUrls = $rpCfg.ListReservedUrls()
                if ($rpUrls -and $rpUrls.UrlString) {
                    $rpHttps = $rpUrls.UrlString | Where-Object { $_ -like 'https:*' -and $_ -match 'Reports' }
                    if ($rpHttps) { $rpScheme = 'https' }
                }
            } catch {}
            $rpUrl = "$rpScheme`://$rpFqdn/Reports"
            $rpBody = @("[InternetShortcut]", "URL=$rpUrl")
            $rpIconDll = "$env:windir\System32\imageres.dll"
            if (Test-Path $rpIconDll) { $rpBody += @("IconFile=$rpIconDll", "IconIndex=77") }
            $rpBody | Out-File -FilePath $rpLink -Encoding ASCII -Force
            if (Test-Path $rpLink) { $script:shortcutsCreated = $true }
        } catch {}
    }
}

# --- Report Server Logs shortcut ---
if (-not (Test-Path "$desktopPath\Report Server Logs.lnk")) {
    $rpLogPath = $null
    # PBIRS default install path
    if (Test-Path "C:\PBIRS\PBIRS\LogFiles") { $rpLogPath = "C:\PBIRS\PBIRS\LogFiles" }
    # SSRS default install path
    if (-not $rpLogPath -and (Test-Path "C:\Program Files\Microsoft SQL Server Reporting Services\SSRS\LogFiles")) {
        $rpLogPath = "C:\Program Files\Microsoft SQL Server Reporting Services\SSRS\LogFiles"
    }
    if ($rpLogPath) {
        Add-Permissions -folderPath $rpLogPath -GrantAncestors
        New-Shortcut -LinkPath "$desktopPath\Report Server Logs.lnk" -TargetPath $rpLogPath | Out-Null
        $script:shortcutsCreated = $true
    }
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
            Add-Permissions -folderPath $DPLogs -GrantAncestors
            New-Shortcut -LinkPath "$desktopPath\DP Logs.lnk" -TargetPath $DPLogs | Out-Null
        }
    }
    catch {}
}

# --- DSC Logs shortcut ---
$dscLogs = "$env:windir\System32\Configuration\ConfigurationStatus"
if (Test-Path $dscLogs) {
    Add-Permissions -folderPath $dscLogs
    New-Shortcut -LinkPath "$desktopPath\DSC Logs.lnk" -TargetPath $dscLogs | Out-Null
    # Remove the redundant Phase-2 troubleshooting twin (created by
    # Common.ScriptBlocks.ps1) that targets the exact same folder, so the
    # desktop doesn't show two identical DSC-log shortcuts.
    $dscDupLink = "$desktopPath\DSC ConfigurationStatus.lnk"
    if (Test-Path $dscDupLink) { Remove-Item $dscDupLink -Force -ErrorAction SilentlyContinue }
}

# --- SSMS shortcut (discover any installed version via glob) ---
$ssmsExe = Get-ChildItem "C:\Program Files (x86)\Microsoft SQL Server Management Studio *\Common7\IDE\ssms.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [int]($_.Directory.Parent.Parent.Name -replace '\D') } -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if ($ssmsExe) {
    New-Shortcut -LinkPath "$desktopPath\SQL Server Management Studio.lnk" -TargetPath $ssmsExe | Out-Null
}

# --- SQL Server Logs shortcut (discover any installed instance via registry glob) ---
if (-not (Test-Path "$desktopPath\SQL Logs.lnk")) {
    $sqlLogPath = $null
    # Find default-instance parameter keys dynamically (no hardcoded version numbers)
    $sqlParamKeys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*\MSSQLServer\Parameters" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($paramKey in $sqlParamKeys) {
        try {
            $arg1 = (Get-ItemProperty -Path $paramKey.PSPath -Name 'SQLArg1' -ErrorAction Stop).SQLArg1
            if ($arg1 -match '^-e(.+)$') {
                $sqlLogPath = Split-Path $Matches[1] -Parent
                break
            }
        }
        catch {}
    }
    # Fallback: search filesystem
    if (-not $sqlLogPath) {
        $sqlLogPath = Get-ChildItem "C:\Program Files\Microsoft SQL Server\MSSQL*\MSSQL\Log" -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($sqlLogPath -and (Test-Path $sqlLogPath)) {
        Add-Permissions -folderPath $sqlLogPath
        New-Shortcut -LinkPath "$desktopPath\SQL Logs.lnk" -TargetPath $sqlLogPath | Out-Null
    }
}

# --- Proxy logon task: stamp HKLM proxy settings into HKCU on every logon ---
# Edge/Chrome (Chromium) reads proxy from HKCU, not HKLM. Set-WindowsClientProxy
# seeds HKCU for the admin + any loaded HKU hives at deploy time, but that misses
# users who log in later. This scheduled task reads the machine-level proxy from
# HKLM and mirrors it into HKCU at every interactive logon so Edge just works.
$taskName = 'MemLabs-SetUserProxy'
$hklmIeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$hklmProxy = Get-ItemProperty -Path $hklmIeKey -Name 'ProxyEnable' -ErrorAction SilentlyContinue
$proxyConfigured = $hklmProxy -and $hklmProxy.ProxyEnable -eq 1
$taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($proxyConfigured) {
    # Inline PowerShell that copies HKLM proxy values into HKCU at logon
    $taskScript = @'
$hklm = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$hkcu = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$p = Get-ItemProperty $hklm -ErrorAction SilentlyContinue
if ($p -and $p.ProxyEnable -eq 1 -and $p.ProxyServer) {
    Set-ItemProperty $hkcu -Name ProxyEnable   -Value $p.ProxyEnable   -Type DWord  -Force
    Set-ItemProperty $hkcu -Name ProxyServer    -Value $p.ProxyServer   -Type String -Force
    Set-ItemProperty $hkcu -Name ProxyOverride  -Value $p.ProxyOverride -Type String -Force
    $en = $true; $pS = $p.ProxyServer; $bL = $p.ProxyOverride
} else {
    Set-ItemProperty $hkcu -Name ProxyEnable -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty $hkcu -Name ProxyServer   -ErrorAction SilentlyContinue
    Remove-ItemProperty $hkcu -Name ProxyOverride  -ErrorAction SilentlyContinue
    $en = $false; $pS = ''; $bL = ''
}
# Write DefaultConnectionSettings blob — this is what Edge/Chrome actually reads
$conn = "$hkcu\Connections"
if (-not (Test-Path $conn)) { New-Item $conn -Force | Out-Null }
$old = (Get-ItemProperty $conn -Name DefaultConnectionSettings -EA SilentlyContinue).DefaultConnectionSettings
$ctr = $(if ($old -and $old.Length -ge 8 -and [BitConverter]::ToUInt32($old,0) -eq 0x46) { [BitConverter]::ToUInt32($old,4)+1 } else { 1 })
if ($en) { $pB=[Text.Encoding]::ASCII.GetBytes($pS); $bB=[Text.Encoding]::ASCII.GetBytes($bL); $fl=[uint32]3 }
else      { $pB=[byte[]]@(); $bB=[byte[]]@(); $fl=[uint32]9 }
$blob = New-Object byte[] (4+4+4+4+$pB.Length+4+$bB.Length+4+32); $o=0
[Array]::Copy([BitConverter]::GetBytes([uint32]0x46),0,$blob,$o,4); $o+=4
[Array]::Copy([BitConverter]::GetBytes([uint32]$ctr),0,$blob,$o,4); $o+=4
[Array]::Copy([BitConverter]::GetBytes($fl),0,$blob,$o,4); $o+=4
[Array]::Copy([BitConverter]::GetBytes([uint32]$pB.Length),0,$blob,$o,4); $o+=4
if ($pB.Length) { [Array]::Copy($pB,0,$blob,$o,$pB.Length); $o+=$pB.Length }
[Array]::Copy([BitConverter]::GetBytes([uint32]$bB.Length),0,$blob,$o,4); $o+=4
if ($bB.Length) { [Array]::Copy($bB,0,$blob,$o,$bB.Length); $o+=$bB.Length }
Set-ItemProperty $conn -Name DefaultConnectionSettings -Value $blob -Type Binary -Force
'@
    try {
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$($taskScript -replace '"','\"')`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'Mirror HKLM proxy settings into HKCU for Edge/Chrome' `
            -RunLevel Limited -Force | Out-Null
        Write-Status "Registered logon task '$taskName' to set per-user proxy"
    }
    catch {
        Write-Status "Failed to register proxy logon task: $_"
    }
}
elseif (-not $proxyConfigured -and $taskExists) {
    # Proxy was removed; clean up the task
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Status "Removed logon task '$taskName' (proxy no longer configured)"
}

# --- Machine proxy re-stamp task: HKLM IE proxy values get blanked by Windows
#     on first interactive logon in machine-wide mode (ProxySettingsPerUser=0)
#     even though the per-user mirror task isn't touching HKLM. This SYSTEM
#     task re-writes the canonical machine-wide HKLM values at every boot and
#     at every user logon, so the values self-heal within seconds.
$systemTaskName = 'MemLabs-SetMachineProxy'
$hklmProxyServer = (Get-ItemProperty -Path $hklmIeKey -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
$systemTaskExists = Get-ScheduledTask -TaskName $systemTaskName -ErrorAction SilentlyContinue

if ($proxyConfigured -and $hklmProxyServer) {
    $machineTaskScript = @'
$srv = '__PROXY_SERVER__'
$ie  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty $ie -Name ProxyEnable           -Value 1    -Type DWord  -Force -ErrorAction SilentlyContinue
Set-ItemProperty $ie -Name ProxyServer           -Value $srv -Type String -Force -ErrorAction SilentlyContinue
Set-ItemProperty $ie -Name ProxySettingsPerUser  -Value 0    -Type DWord  -Force -ErrorAction SilentlyContinue
$conn = ($ie + '\Connections')
if (-not (Test-Path $conn)) { New-Item $conn -Force | Out-Null }
$old = (Get-ItemProperty $conn -Name DefaultConnectionSettings -EA SilentlyContinue).DefaultConnectionSettings
$ctr = $(if ($old -and $old.Length -ge 8 -and [BitConverter]::ToUInt32($old,0) -eq 0x46) { [BitConverter]::ToUInt32($old,4)+1 } else { 1 })
$pB = [Text.Encoding]::ASCII.GetBytes($srv)
$blob = New-Object byte[] (4+4+4+4+$pB.Length+4+0+4+32); $o=0
[Array]::Copy([BitConverter]::GetBytes([uint32]0x46),0,$blob,$o,4); $o+=4
[Array]::Copy([BitConverter]::GetBytes([uint32]$ctr),0,$blob,$o,4); $o+=4
[Array]::Copy([BitConverter]::GetBytes([uint32]3),0,$blob,$o,4); $o+=4
[Array]::Copy([BitConverter]::GetBytes([uint32]$pB.Length),0,$blob,$o,4); $o+=4
if ($pB.Length) { [Array]::Copy($pB,0,$blob,$o,$pB.Length); $o+=$pB.Length }
[Array]::Copy([BitConverter]::GetBytes([uint32]0),0,$blob,$o,4); $o+=4
Set-ItemProperty $conn -Name DefaultConnectionSettings -Value $blob -Type Binary -Force -ErrorAction SilentlyContinue
'@ -replace '__PROXY_SERVER__', $hklmProxyServer

    try {
        $sysAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$($machineTaskScript -replace '"', '\"')`""
        $sysTriggers = @(
            New-ScheduledTaskTrigger -AtStartup
            New-ScheduledTaskTrigger -AtLogOn
        )
        $sysSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        $sysPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $systemTaskName -Action $sysAction -Trigger $sysTriggers `
            -Settings $sysSettings -Principal $sysPrincipal `
            -Description 'Re-stamp HKLM IE proxy values (Windows blanks them on first logon in machine-wide mode)' `
            -Force | Out-Null
        # Fire it once now so the current state self-heals immediately.
        Start-ScheduledTask -TaskName $systemTaskName -ErrorAction SilentlyContinue
        Write-Status "Registered SYSTEM task '$systemTaskName' (re-stamp HKLM proxy at boot + logon)"
    }
    catch {
        Write-Status "Failed to register machine proxy re-stamp task: $_"
    }
}
elseif (-not $proxyConfigured -and $systemTaskExists) {
    Unregister-ScheduledTask -TaskName $systemTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Status "Removed SYSTEM task '$systemTaskName' (proxy no longer configured)"
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
    # Enable auto-arrange via registry so future icons also align left
    $bagsPath = "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Bags\1\Desktop"
    if (Test-Path $bagsPath) {
        $fflags = Get-ItemProperty -Path $bagsPath -Name "FFlags" -ErrorAction SilentlyContinue
        if ($fflags) {
            # Set auto-arrange (bit 0) and snap-to-grid (bit 2)
            $newFlags = $fflags.FFlags -bor 0x5
            Set-ItemProperty -Path $bagsPath -Name "FFlags" -Value $newFlags -ErrorAction SilentlyContinue
        }
    }

    # Send LVM_ARRANGE to the desktop ListView to immediately align icons left
    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class DesktopRefresh {
            [DllImport("user32.dll", SetLastError = true)]
            public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
            [DllImport("user32.dll", SetLastError = true)]
            public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
            [DllImport("user32.dll")]
            public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
        }
"@ -ErrorAction SilentlyContinue
    try {
        $defView = [IntPtr]::Zero
        # Desktop ListView is under Progman > SHELLDLL_DefView > SysListView32
        $progman = [DesktopRefresh]::FindWindow("Progman", "Program Manager")
        if ($progman -ne [IntPtr]::Zero) {
            $defView = [DesktopRefresh]::FindWindowEx($progman, [IntPtr]::Zero, "SHELLDLL_DefView", $null)
        }
        # Fallback: on some configurations it's under a WorkerW window
        if ($defView -eq [IntPtr]::Zero) {
            $workerW = [IntPtr]::Zero
            do {
                $workerW = [DesktopRefresh]::FindWindowEx([IntPtr]::Zero, $workerW, "WorkerW", $null)
                if ($workerW -ne [IntPtr]::Zero) {
                    $dv = [DesktopRefresh]::FindWindowEx($workerW, [IntPtr]::Zero, "SHELLDLL_DefView", $null)
                    if ($dv -ne [IntPtr]::Zero) {
                        $defView = $dv
                        break
                    }
                }
            } while ($workerW -ne [IntPtr]::Zero)
        }
        if ($defView -ne [IntPtr]::Zero) {
            $listView = [DesktopRefresh]::FindWindowEx($defView, [IntPtr]::Zero, "SysListView32", $null)
            if ($listView -ne [IntPtr]::Zero) {
                # LVM_ARRANGE (0x1016) with LVA_ALIGNLEFT (1)
                [DesktopRefresh]::SendMessage($listView, 0x1016, [IntPtr]1, [IntPtr]::Zero) | Out-Null
            }
        }
    }
    catch {}
}



