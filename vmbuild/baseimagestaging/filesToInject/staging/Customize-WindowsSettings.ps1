#
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

    #Update-Log "Disable Windows Update"
    #New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | New-ItemProperty -Name NoAutoUpdate -Value 1 -Force | Out-Null
}

# Common Windows Settings
# ========================
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
(Get-WmiObject -class Win32_TSGeneralSetting -Namespace root\cimv2\terminalservices -Filter "TerminalName='RDP-tcp'").SetUserAuthenticationRequired(0) | Out-Null

Update-Log "Set Password Expiration Policy to Never (Max Password Age = 0)"
net accounts /MAXPWAGE:Unlimited

Update-Log "Disable Sign-in Background for All Users"
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name DisableLogonBackgroundImage -Value 1 -Force | Out-Null

Update-Log "Disable network location wizard"
New-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff' -Force -ErrorAction SilentlyContinue | Out-Null

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

Update-Log "Hide Search/Cortana/TaskView from Taskbar"
New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Force | New-ItemProperty -Name SearchboxTaskbarMode -Value 0 -Force | Out-Null # Hide Search icon
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name ShowTaskViewButton -Value 0 # Hide TaskView
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name ShowCortanaButton -Value 0 # Hide Cortana

if (-not $server) {
    # Dark Mode for Win 10/11
    New-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name AppsUseLightTheme -Value 0 -Type Dword -Force
    New-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name SystemUsesLightTheme -Value 0 -Type Dword -Force
}

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
