# Customize-WindowsSettings.ps1
# Customize Windows Settings optimal for the VM
#

param(
    [switch]$RunSysprep,
    [switch]$DisableFirewall,
    [switch]$InstallWindowsFeatures,
    [switch]$RunOptional
)

$sb = [System.Text.StringBuilder]::new()

function Update-Log {
    param(
        $Text
    )

    if ($null -eq $Text) {
        Write-Host
        return
    }

    $message = "$(Get-Date -Format G) $Text"
    Write-Host $message
    $sb.AppendLine($message) | Out-Null

}

$os = Get-WmiObject -Class Win32_OperatingSystem

if ($os.ProductType -eq 1) {
    $server = $false
}
else {
    $server = $true
}

Update-Log "Starting customization..."
Update-Log "Running as $env:USERNAME"
Write-Host

# Server Only
# ===========
if ($server) {
    Update-Log "Disable Server Manager at startup"
    Set-ItemProperty -Path HKCU:\Software\Microsoft\ServerManager -Name DoNotopenServerManagerAtLogon -Value 1

    Update-Log "Disable IE Enhanced Security"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name IsInstalled -Value 0 # Admins
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name IsInstalled -Value 0 # Users

    if ($InstallWindowsFeatures.IsPresent) {
        Update-Log "Installing Windows Features: .NET 3.5 & 4.5"
        Install-WindowsFeature Net-Framework-Core
        Install-WindowsFeature NET-Framework-45-Core

        Update-Log "Installing Windows Features: IIS"
        Install-WindowsFeature Web-Server -IncludeManagementTools
        Install-WindowsFeature Web-Basic-Auth, Web-IP-Security, Web-Url-Auth, Web-Windows-Auth, Web-ASP, Web-Asp-Net
        Install-WindowsFeature Web-Mgmt-Console, Web-Lgcy-Mgmt-Console, Web-Lgcy-Scripting, Web-WMI, Web-Mgmt-Service, Web-Mgmt-Tools, Web-Scripting-Tools
    }

    Update-Log "Disable Windows Ink Workspace button"
    New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace' -Force | New-ItemProperty -Name AllowWindowsInkWorkspace -Value 0 -Force | Out-Null

    Update-Log "Disable Windows Update"
    New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | New-ItemProperty -Name NoAutoUpdate -Value 1 -Force | Out-Null
}

# Disable Microsoft Edge Update — auto-updates leave PendingFileRenameOperations
# that trigger unnecessary reboots during lab builds.
Update-Log "Disable Microsoft Edge Update services and scheduled tasks"
foreach ($svc in @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-Service  $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
}
Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match 'MicrosoftEdgeUpdate' } |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

# Disable telemetry, diagnostics, and consumer experience
# These generate network traffic, disk I/O, and occasional PendingFileRename
# entries that interfere with deterministic lab builds.
Update-Log "Disable telemetry and diagnostics services"
foreach ($svc in @('DiagTrack', 'dmwappushservice')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-Service  $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
}

Update-Log "Disable telemetry via registry"
$dtPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
New-Item -Path $dtPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $dtPath -Name 'AllowTelemetry' -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $dtPath -Name 'AllowDeviceNameInTelemetry' -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $dtPath -Name 'DoNotShowFeedbackNotifications' -PropertyType DWord -Value 1 -Force | Out-Null

Update-Log "Disable Advertising ID, activity history, and tailored experiences"
# Advertising ID
$advIdPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'
New-Item -Path $advIdPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $advIdPath -Name 'DisabledByGroupPolicy' -PropertyType DWord -Value 1 -Force | Out-Null
# Activity History (timeline)
$actPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
New-Item -Path $actPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $actPath -Name 'PublishUserActivities' -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $actPath -Name 'UploadUserActivities' -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $actPath -Name 'EnableActivityFeed' -PropertyType DWord -Value 0 -Force | Out-Null
# Tailored experiences
$tailoredPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
New-Item -Path $tailoredPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $tailoredPath -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
# Feedback frequency — never
$siufPath = 'HKCU:\Software\Microsoft\Siuf\Rules'
New-Item -Path $siufPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $siufPath -Name 'NumberOfSIUFInPeriod' -PropertyType DWord -Value 0 -Force | Out-Null
# Online speech recognition
$speechPath = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'
New-Item -Path $speechPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $speechPath -Name 'AllowInputPersonalization' -PropertyType DWord -Value 0 -Force | Out-Null
# Inking & typing personalization
New-ItemProperty -Path $speechPath -Name 'RestrictImplicitInkCollection' -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $speechPath -Name 'RestrictImplicitTextCollection' -PropertyType DWord -Value 1 -Force | Out-Null
# App launch tracking
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackProgs' -Value 0 -Force -ErrorAction SilentlyContinue
# Location tracking
$locPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
New-Item -Path $locPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $locPath -Name 'DisableLocation' -PropertyType DWord -Value 1 -Force | Out-Null
# WiFi Sense (auto hotspot sharing) — Win10 only but harmless on Server
$wfPath = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config'
New-Item -Path $wfPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $wfPath -Name 'AutoConnectAllowedOEM' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null

Update-Log "Disable consumer experience and spotlight"
$cePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
New-Item -Path $cePath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $cePath -Name 'DisableWindowsConsumerFeatures' -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $cePath -Name 'DisableSoftLanding' -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $cePath -Name 'DisableCloudOptimizedContent' -PropertyType DWord -Value 1 -Force | Out-Null

Update-Log "Disable scheduled tasks: defrag, NGEN, CEIP, telemetry, Server Manager"
$disableTasks = @(
    '\Microsoft\Windows\Defrag\ScheduledDefrag'
    '\Microsoft\Windows\Server Manager\ServerManager'
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
    '\Microsoft\Windows\Autochk\Proxy'
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
)
foreach ($taskFullName in $disableTasks) {
    $taskName = Split-Path $taskFullName -Leaf
    $taskPath = (Split-Path $taskFullName -Parent) + '\'
    $t = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if ($t -and $t.State -ne 'Disabled') {
        Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue | Out-Null
    }
}
# NGEN tasks use version-specific paths — match by wildcard
Get-ScheduledTask -TaskPath '\Microsoft\Windows\.NET Framework\' -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match 'NGEN' } |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

# Common Windows Settings
# ========================
Update-Log "Prevent automatic device encryption (managed by ConfigMgr when needed)"
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker" -Name "PreventDeviceEncryption" -Value 1 -PropertyType DWORD -Force | Out-Null

Update-Log "Show 'My Computer' on desktop"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -Value 0

Update-Log "Set UAC behavior to Elevate withouot prompt for admins"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name ConsentPromptBehaviorAdmin -Value 0

Update-Log "Disable Shutdown Event Tracker"
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' -Force | New-ItemProperty -Name ShutdownReasonOn -Value 0 -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability" -Name ShutdownReasonUI -Value 0

Update-Log "Remove floppy disk, if present."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\flpydisk" -Name Start -Value 4 -ErrorAction SilentlyContinue

Update-Log "Enable RDP and disable NLA"
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server'-name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server'-name "updateRDStatus" -Value 1
(Get-WmiObject -class Win32_TSGeneralSetting -Namespace root\cimv2\terminalservices -Filter "TerminalName='RDP-tcp'").SetUserAuthenticationRequired(0) | Out-Null

Update-Log "     Update Win32_TerminalServiceSetting.AllowTSConnections"
(Get-WmiObject -class Win32_TerminalServiceSetting -Namespace root\cimv2\terminalservices).SetAllowTSConnections(1, 0) | Out-Null

Update-Log "     Update firewall rules for remote desktop"
netsh advfirewall firewall set rule group="remote desktop" new enable=yes

Update-Log "Set Password Expiration Policy to Never (Max Password Age = 0)"
net accounts /MAXPWAGE:Unlimited

Update-Log "Disable Sign-in Background for All Users"
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name DisableLogonBackgroundImage -Value 1 -Force | Out-Null

Update-Log "Disable network location wizard"
New-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff' -Force -ErrorAction SilentlyContinue | Out-Null

# Visual performance optimizations
# =================================
# Set "Adjust for best performance" (disables all animations, transparency,
# smooth scrolling, thumbnail caching, etc.) — dramatically reduces first-login
# time and memory footprint on Windows 11 VMs.
Update-Log "Set visual effects to 'Adjust for best performance'"
# UserPreferencesMask controls all visual effects. 90 12 03 80 10 00 00 00 = "Best performance"
$vfxPath = 'HKCU:\Control Panel\Desktop'
Set-ItemProperty -Path $vfxPath -Name 'UserPreferencesMask' -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary -Force
Set-ItemProperty -Path $vfxPath -Name 'MenuShowDelay' -Value '0' -Force  # No menu animation delay
$vfxWinPath = 'HKCU:\Control Panel\Desktop\WindowMetrics'
Set-ItemProperty -Path $vfxWinPath -Name 'MinAnimate' -Value '0' -Force  # No minimize/maximize animation
$vfxAdvPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty -Path $vfxAdvPath -Name 'TaskbarAnimations' -Value 0 -Force
Set-ItemProperty -Path $vfxAdvPath -Name 'ListviewAlphaSelect' -Value 0 -Force  # No translucent selection rectangle
Set-ItemProperty -Path $vfxAdvPath -Name 'ListviewShadow' -Value 0 -Force      # No drop shadows on icon labels
# VisualFX key tells System Properties to show "Custom" or "Best Performance"
$vfxSysPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
New-Item -Path $vfxSysPath -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $vfxSysPath -Name 'VisualFXSetting' -Value 2 -Force  # 2 = Best Performance

# Disable transparency effects (Win10/11 compositing overhead)
Update-Log "Disable transparency and animation effects"
$themePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
New-Item -Path $themePath -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $themePath -Name 'EnableTransparency' -Value 0 -Force
# SystemParametersInfo-equivalent: disable UI animations globally
$dwmPath = 'HKCU:\Software\Microsoft\Windows\DWM'
New-Item -Path $dwmPath -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $dwmPath -Name 'EnableAeroPeek' -Value 0 -Force
Set-ItemProperty -Path $dwmPath -Name 'AlwaysHibernateThumbnails' -Value 0 -Force

# Windows 11 specific: disable Widgets, Copilot, Chat, Snap layouts, and
# first-login "welcome" experience that installs suggested apps.
if (-not $server) {
    Update-Log "Disable Windows 11 Widgets, Copilot, Chat, and first-run bloat"
    if ([int]$os.BuildNumber -ge 22000) {
        Update-Log "Use the full Windows 11 context menu"
        $classicMenuCommand = 'reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve'
        $classicMenuActiveSetup = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{B6D0E53B-7A71-46A9-AF84-F2E596B8C671}'
        New-Item -Path $classicMenuActiveSetup -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $classicMenuActiveSetup -Name 'Version' -PropertyType String -Value '1,0,0,0' -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $classicMenuActiveSetup -Name 'StubPath' -PropertyType String -Value $classicMenuCommand -Force -ErrorAction Stop | Out-Null
        & reg.exe add 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' /f /ve | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to enable the full Windows 11 context menu (reg.exe exit $LASTEXITCODE)." }
    }
    # Widgets
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -PropertyType DWord -Value 0 -Force | Out-Null
    Set-ItemProperty -Path $vfxAdvPath -Name 'TaskbarDa' -Value 0 -Force -ErrorAction SilentlyContinue  # Hide Widgets button
    # Copilot
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -PropertyType DWord -Value 1 -Force | Out-Null
    # Chat (Teams consumer)
    Set-ItemProperty -Path $vfxAdvPath -Name 'TaskbarMn' -Value 0 -Force -ErrorAction SilentlyContinue
    # Snap assist overlay — distracting in RDP sessions
    Set-ItemProperty -Path $vfxAdvPath -Name 'EnableSnapAssistFlyout' -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $vfxAdvPath -Name 'SnapAssist' -Value 0 -Force -ErrorAction SilentlyContinue
}

# Disable "Welcome Experience" and "Get tips/suggestions" that trigger
# on first login and install promoted apps in the background.
Update-Log "Disable Welcome Experience, tips, and suggested content"
$cdmPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
New-Item -Path $cdmPath -Force -ErrorAction SilentlyContinue | Out-Null
# Disable all content delivery (suggested apps, Start menu suggestions, tips)
foreach ($cdmVal in @(
    'SubscribedContent-310093Enabled'    # Welcome Experience
    'SubscribedContent-338389Enabled'    # Tips/tricks
    'SubscribedContent-338393Enabled'    # Suggested content in Settings
    'SubscribedContent-353694Enabled'    # Suggested content in Settings
    'SubscribedContent-353696Enabled'    # Suggested content in Settings
    'SystemPaneSuggestionsEnabled'       # Start menu suggested apps
    'SilentInstalledAppsEnabled'         # Auto-install suggested apps
    'SoftLandingEnabled'                 # Tips about Windows
    'RotatingLockScreenEnabled'          # Lock screen spotlight
    'RotatingLockScreenOverlayEnabled'   # Lock screen fun facts
)) {
    New-ItemProperty -Path $cdmPath -Name $cdmVal -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
}

# Disable first-logon animation ("Hi, we're getting things ready for you")
Update-Log "Disable first-logon animation"
New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableFirstLogonAnimation' -Value 0 -Force

# Disable Search highlights (Bing images in search bar)
Update-Log "Disable search highlights"
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'EnableDynamicContentInWSB' -PropertyType DWord -Value 0 -Force | Out-Null

# Reduce Superfetch/SysMain memory pressure on VMs with limited RAM
Update-Log "Disable SysMain (Superfetch) — counterproductive on dynamic-memory VMs"
$s = Get-Service -Name 'SysMain' -ErrorAction SilentlyContinue
if ($s) {
    Stop-Service 'SysMain' -Force -ErrorAction SilentlyContinue
    Set-Service  'SysMain' -StartupType Disabled -ErrorAction SilentlyContinue
}

# Microsoft Defender: MsMpEng.exe real-time scanning of the ConfigMgr content
# library, SQL data files and the C:\staging DSC tree is the top CPU consumer
# on a lab VM. Fix-DefenderTuning re-applies this on existing VMs.
Update-Log "Apply Defender exclusions and scan throttling"
$defenderScript = "C:\staging\Optimize-Defender.ps1"
if (Test-Path $defenderScript) {
    $defenderResult = & $defenderScript
    Update-Log "     $($defenderResult.Message)"
}
else {
    Update-Log "     $defenderScript not found; skipped."
}

Update-Log "Add tools paths to PATH variable"
$toolsPath = "C:\tools"
$oldpath = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).path
$newpath = $oldpath
if (Test-Path $toolsPath) {
    $newpath = "$newpath;$toolsPath"
    foreach ($item in Get-ChildItem -Path $toolsPath -Directory) {
        $newpath = "$newpath;$($item.FullName)"
    }
}
if ($newpath -ne $oldpath) {
    Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH -Value $newPath
}

if ($DisableFirewall.IsPresent) {
    Update-Log "Disable Domain/Private Profile for Windows Firewall"
    Set-NetFirewallProfile -Profile Private -Enabled false
    Set-NetFirewallProfile -Profile Domain -Enabled false
}

# User Preferences
# ================

Update-Log "Set File Explorer preferences"
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name LaunchTo -Value 1 # File Explorer to This PC
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name Hidden -Value 1 # Show Hidden Files
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name HideFileExt -Value 0 # Show File Extensions
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name TaskbarGlomLevel -Value 1 # Combine taskbar when full
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name TaskbarMn -Value 0 -ErrorAction SilentlyContinue # Hide Teams Chat app from taskbar

#Disable Sticky Keys
Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Type String -Value "506"
Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name "Flags" -Type String -Value "58"
Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "Flags" -Type String -Value "122"

Update-Log "Hide Search/Cortana/TaskView from Taskbar"
New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Force | New-ItemProperty -Name SearchboxTaskbarMode -Value 0 -Force | Out-Null # Hide Search icon
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name ShowTaskViewButton -Value 0 # Hide TaskView
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name ShowCortanaButton -Value 0 # Hide Cortana

# if (-not $server) {
#     # Dark Mode for Win 10/11 - Does NOT work after OOBE :(
#     Update-Log "Enable Dark Mode"
#     New-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name AppsUseLightTheme -Value 0 -Type Dword -Force
#     New-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name SystemUsesLightTheme -Value 0 -Type Dword -Force
# }

# Create directories, if not present
# ===================================
if (-not (Test-Path "C:\temp")) {
    New-Item -Path "C:\temp" -ItemType Directory -Force | Out-Null
}

# Create C:\staging, if not present
if (-not (Test-Path "C:\staging")) {
    New-Item -Path "C:\staging" -ItemType Directory -Force | Out-Null
}

# Optional Preferences
# =====================

# Run optional preferences that rely on data in staging directory
if ($RunOptional.IsPresent) {
    Update-Log "Update Powershell/CMD shortcut to use 170x40 layout"
    Copy-Item -Path "C:\staging\LNK\Windows PowerShell.lnk" -Destination "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Windows PowerShell\Windows PowerShell.lnk" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path "C:\staging\LNK\Command Prompt.lnk" -Destination "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\System Tools\Command Prompt.lnk" -Force -ErrorAction SilentlyContinue

    Update-Log "Removing .LNK files for Taskbar pinned items"
    Get-ChildItem -Path "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar" | Remove-Item -Force -ErrorAction SilentlyContinue

    if ($server) {
        Update-Log "Add BGInfo startup shortcut for SERVER"
        Copy-Item -Path "C:\staging\bginfo\bginfo_SERVER.lnk" -Destination "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -Force -ErrorAction SilentlyContinue
    }
    else {
        Update-Log "Add BGInfo startup shortcut for CLIENT"
        Copy-Item -Path "C:\staging\bginfo\bginfo_CLIENT.lnk" -Destination "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -Force -ErrorAction SilentlyContinue
    }
}

# download and install .NET 4.8
# ==============================
$url = 'https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe'
$filename = "ndp48-x86-x64-allos-enu.exe"
$dest = "C:\temp\$($filename)"

# download
Update-Log "Downloading .NET 4.8 from $($url) to $($dest)..."

try {
    $response = Invoke-WebRequest -Uri $url -OutFile $dest -ErrorAction Stop
    if ($response) {
        $response.Content.Trim()
        Update-Log "     Download result:"
        Update-Log "     Status Code: $($response.StatusCode)"
        Update-Log "     Status Description: $($response.Content)"
    }
    else {
        Update-Log "     response is false."
    }
}
catch {
    $errorRecord = $_
    $statusCode = $errorRecord.Exception.Response.StatusCode.Value__
    Update-Log "Download error: Status Code: $statusCode"
}

# check if file exists
if (Test-Path $dest) {
    Update-Log "     Succesfully downloaded .NET 4.8 $($dest)"

    # install .NET 4.8
    $cmd = $dest
    $arg1 = "/q"
    $arg2 = "/norestart"

    Update-Log "Installing .NET $($filename)..."

    & $cmd $arg1 $arg2 | Out-Null

    $processName = ($filename -split ".exe")[0]

    Update-Log "     processName: $($processName)"

    while ($ture) {
        Start-Sleep -Seconds 15

        Update-Log "     Checking .NET installation process"
        $process = GetProcess $processName -ErrorAction SlientlyContinue
        if ($null -eq $process) {
            break
        }
    }

    Start-Sleep -Seconds 120 ## Buffer Wait
    Update-Log ".NET $($filename) Installed Successrfully!"
}
else {
    Update-Log "     Failed to download .NET 4.8."
}



# Completion
# ============

# Move uanttend file to avoid future use, since C:\unattend.xml is one of the defautl locations windows looks for
Move-Item -Path "C:\Unattend.xml" -Destination "C:\staging\Unattend.xml" -Force -ErrorAction SilentlyContinue

Write-Host
Update-Log "Done! A reboot is required for settings to take effect. "

# Write log to disk to signal "completion"
$sb.ToString() | Out-File "C:\staging\Customization.txt" -Force

# Generalize OS
# =====================

if ($RunSysprep.IsPresent) {
    # Run Sysprep to generalize the OS
    Write-Host
    Write-Host "Waiting for 30 seconds before starting sysprep..."
    Start-Sleep -Seconds 30 # Buffer to make sure sysprep GUI has appeared

    & taskkill /im sysprep.exe /f | Out-Null # kill sysprep UI pop-up
    if (Test-Path -Path "C:\staging\Unattend.xml") {
        & $env:windir\system32\sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:"C:\staging\Unattend.xml"
    }
    else {
        # File move must have failed, fallback to the default location
        & $env:windir\system32\sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:"C:\Unattend.xml"
    }
}

# CopyProfile Changes?
# ====================
# Remove the reg keys specified here: https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/customize-the-default-user-profile-by-using-copyprofile
# Update-Log "Remove recommednded registry keys for CopyProfile"
# Remove-Item -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\FileAssociationsUpdateVersion" -Recurse -Force -ErrorAction SilentlyContinue
# Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts" -Recurse -Force -ErrorAction SilentlyContinue
# Remove-Item -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations" -Recurse -Force -ErrorAction SilentlyContinue
