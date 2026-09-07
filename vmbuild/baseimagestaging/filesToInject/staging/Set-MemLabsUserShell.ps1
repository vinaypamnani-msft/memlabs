<#
.SYNOPSIS
    Applies MemLabs Explorer, Start, taskbar, and visual settings per user.
#>
[CmdletBinding()]
param(
    [switch]$Register,
    [switch]$Apply
)

$errors = [System.Collections.Generic.List[string]]::new()
$blocked = [System.Collections.Generic.List[string]]::new()
$activeSetupPath = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{9EA95B85-EEB7-4A88-AE03-1C377BBFD411}'
$version = '1,0,0,0'

if ($Register) {
    try {
        $installedScript = 'C:\staging\Set-MemLabsUserShell.ps1'
        if (-not (Test-Path -LiteralPath $installedScript -PathType Leaf)) {
            throw "$installedScript is missing."
        }
        New-Item -Path $activeSetupPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $activeSetupPath -Name 'Version' -PropertyType String -Value $version -Force -ErrorAction Stop | Out-Null
        $stubPath = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installedScript`" -Apply"
        New-ItemProperty -Path $activeSetupPath -Name 'StubPath' -PropertyType String -Value $stubPath -Force -ErrorAction Stop | Out-Null
    }
    catch { $errors.Add("Active Setup registration: $($_.Exception.Message)") }
}

if ($Apply) {
    function Set-UserDword {
        param([string]$Path, [string]$Name, [int]$Value, [switch]$AllowBlocked)
        try {
            if (-not (Test-Path -LiteralPath $Path)) {
                New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
            }
            New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        catch {
            $message = "$Path\$Name`: $($_.Exception.Message)"
            if ($AllowBlocked) { $blocked.Add($message) } else { $errors.Add($message) }
        }
    }

    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-UserDword $advanced 'LaunchTo' 1
    Set-UserDword $advanced 'Hidden' 1
    Set-UserDword $advanced 'HideFileExt' 0
    Set-UserDword $advanced 'TaskbarAnimations' 0
    Set-UserDword $advanced 'TaskbarDa' 0 -AllowBlocked
    Set-UserDword $advanced 'TaskbarMn' 0
    Set-UserDword $advanced 'ShowTaskViewButton' 0
    Set-UserDword $advanced 'ShowCortanaButton' 0
    Set-UserDword $advanced 'EnableSnapAssistFlyout' 0
    Set-UserDword $advanced 'SnapAssist' 0
    Set-UserDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
    Set-UserDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Set-UserDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Set-UserDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0

    $contentDelivery = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($name in @(
            'SubscribedContent-310093Enabled', 'SubscribedContent-338389Enabled',
            'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
            'SubscribedContent-353696Enabled', 'SystemPaneSuggestionsEnabled',
            'SilentInstalledAppsEnabled', 'SoftLandingEnabled',
            'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled'
        )) {
        Set-UserDword $contentDelivery $name 0
    }

    try {
        & reg.exe add 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' /f /ve | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg.exe exited $LASTEXITCODE" }
    }
    catch { $errors.Add("Classic context menu: $($_.Exception.Message)") }

    $suggestions = Get-ItemPropertyValue -Path $contentDelivery -Name 'SystemPaneSuggestionsEnabled' -ErrorAction SilentlyContinue
    $hideExtensions = Get-ItemPropertyValue -Path $advanced -Name 'HideFileExt' -ErrorAction SilentlyContinue
    if ($suggestions -ne 0) { $errors.Add('SystemPaneSuggestionsEnabled did not persist.') }
    if ($hideExtensions -ne 0) { $errors.Add('HideFileExt did not persist.') }
}

if (-not $Register -and -not $Apply) { $errors.Add('Specify -Register or -Apply.') }

[pscustomobject]@{
    Success = $errors.Count -eq 0
    Message = if ($errors.Count -eq 0) {
        "User shell settings applied or registered.$(if ($blocked.Count) { " Blocked by Windows: $($blocked -join '; ')." })"
    }
    else { 'User shell settings had failures.' }
    Errors  = @($errors)
    Blocked = @($blocked)
}