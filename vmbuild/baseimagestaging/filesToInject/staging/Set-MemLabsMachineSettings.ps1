<#
.SYNOPSIS
    Applies machine-wide Windows settings shared by Phase 10 and OSD clients.
#>
[CmdletBinding()]
param()

$errors = [System.Collections.Generic.List[string]]::new()

function Set-MemLabsDword {
    param([string]$Path, [string]$Name, [int]$Value)
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
    }
    catch { $errors.Add("$Path\$Name`: $($_.Exception.Message)") }
}

Set-MemLabsDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
Set-MemLabsDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
Set-MemLabsDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Set-MemLabsDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
Set-MemLabsDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 1
Set-MemLabsDword 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
Set-MemLabsDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
Set-MemLabsDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0
Set-MemLabsDword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableFirstLogonAnimation' 0

foreach ($serviceName in @('DiagTrack', 'dmwappushservice', 'SysMain')) {
    try {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
        }
    }
    catch { $errors.Add("Service $serviceName`: $($_.Exception.Message)") }
}

$consumerFeatures = $null
$firstLogon = $null
try { $consumerFeatures = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -ErrorAction Stop).DisableWindowsConsumerFeatures }
catch { }
try { $firstLogon = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).EnableFirstLogonAnimation }
catch { }
if ($consumerFeatures -ne 1) { $errors.Add('DisableWindowsConsumerFeatures did not persist.') }
if ($firstLogon -ne 0) { $errors.Add('EnableFirstLogonAnimation did not persist.') }

[pscustomobject]@{
    Success = $errors.Count -eq 0
    Message = if ($errors.Count -eq 0) { 'Machine settings applied and verified.' } else { 'Machine settings had failures.' }
    Errors  = @($errors)
}