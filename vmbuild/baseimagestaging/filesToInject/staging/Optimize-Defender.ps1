<#
.SYNOPSIS
    Cuts MsMpEng.exe (Microsoft Defender Antivirus) CPU on MemLabs guests.

.DESCRIPTION
    Real-time scanning of the ConfigMgr content library, SQL data files, WSUS
    content and the C:\staging DSC tree is what makes MsMpEng the top CPU
    consumer on a lab VM. This applies the ConfigMgr/SQL/IIS exclusion set,
    throttles scheduled scanning, and disables the idle-time Defender tasks.

    The levers Tamper Protection owns (real-time protection, behavior
    monitoring, IOAV, archive scanning, cloud/MAPS) are attempted last and each
    one is re-read afterwards. Tamper Protection is on by default on Windows
    10/11 and Server 2019+, and it makes Set-MpPreference a silent no-op for
    those settings -- so they are reported as Blocked rather than Applied
    instead of being assumed to have worked.

.PARAMETER Remove
    Server SKUs only. Uninstalls the Windows-Defender feature, which is the
    only way to actually stop MsMpEng.exe from running. Requires a reboot, and
    leaves the VM unable to host ConfigMgr Endpoint Protection.
    On client SKUs there is no supported way to remove or permanently disable
    Defender; tuning is the ceiling.

.EXAMPLE
    C:\staging\Optimize-Defender.ps1

.EXAMPLE
    C:\staging\Optimize-Defender.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch] $Remove
)

$applied = New-Object System.Collections.Generic.List[string]
$blocked = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

function Write-Step {
    param([string] $Text)
    Write-Host "[Optimize-Defender] $Text"
}

if (-not (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
    Write-Step 'Defender cmdlets are not present on this OS. Nothing to do.'
    return [pscustomobject]@{ Success = $true; Message = 'Defender not present; skipped.'; Errors = @() }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$isServer = ($os -and $os.ProductType -ne 1)

# ---------------------------------------------------------------------------
# Optional: remove Defender outright (server only)
# ---------------------------------------------------------------------------
if ($Remove) {
    if (-not $isServer) {
        Write-Step 'Client SKU: Defender cannot be uninstalled. Falling back to tuning is not automatic; re-run without -Remove.'
        return [pscustomobject]@{ Success = $false; Message = 'Client SKU cannot uninstall Defender.'; Errors = @('Windows-Defender is not a removable feature on workstation SKUs.') }
    }

    Import-Module ServerManager -ErrorAction SilentlyContinue
    $installed = @(Get-WindowsFeature -Name 'Windows-Defender*' -ErrorAction SilentlyContinue | Where-Object { $_.Installed })
    if ($installed.Count -eq 0) {
        Write-Step 'Windows-Defender feature is already absent.'
        return [pscustomobject]@{ Success = $true; Message = 'Windows-Defender feature already removed.'; Errors = @() }
    }

    try {
        $uninstall = Uninstall-WindowsFeature -Name ($installed | ForEach-Object { $_.Name }) -ErrorAction Stop
        $needsReboot = ("$($uninstall.RestartNeeded)" -ne 'No')
        Write-Step "Uninstalled: $(($installed | ForEach-Object { $_.Name }) -join ', '). RestartNeeded=$($uninstall.RestartNeeded)"
        return [pscustomobject]@{
            Success        = [bool]$uninstall.Success
            Message        = "Removed Windows-Defender feature. Reboot required: $needsReboot"
            Errors         = @()
            RebootRequired = $needsReboot
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Message = 'Uninstall-WindowsFeature failed.'; Errors = @($_.Exception.Message) }
    }
}

$status = Get-MpComputerStatus -ErrorAction SilentlyContinue
$tamperProtected = $false
if ($status -and ($status.PSObject.Properties.Name -contains 'IsTamperProtected')) {
    $tamperProtected = [bool]$status.IsTamperProtected
}
Write-Step "TamperProtection=$tamperProtected RealTimeProtection=$($status.RealTimeProtectionEnabled) AMRunningMode=$($status.AMRunningMode)"

# ---------------------------------------------------------------------------
# Path exclusions
# ---------------------------------------------------------------------------
$paths = New-Object System.Collections.Generic.List[string]
foreach ($p in @(
        "$env:SystemDrive\staging"
        "$env:SystemDrive\temp"
        "$env:SystemDrive\tools"
        "$env:SystemDrive\CMCB"
        "$env:SystemDrive\inetpub"
        "$env:WinDir\System32\Configuration"
        "$env:WinDir\System32\inetsrv"
        "$env:WinDir\CCM"
        "$env:WinDir\ccmcache"
        "$env:WinDir\ccmsetup"
        "$env:WinDir\SoftwareDistribution\Download"
    )) {
    $paths.Add($p)
}

# ConfigMgr site install directory (site servers only)
$cmSetup = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction SilentlyContinue
if ($cmSetup -and $cmSetup.'Installation Directory') { $paths.Add([string]$cmSetup.'Installation Directory') }

# WSUS content directory
$wsusSetup = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup' -ErrorAction SilentlyContinue
if ($wsusSetup -and $wsusSetup.ContentDir) { $paths.Add([string]$wsusSetup.ContentDir) }

# SQL Server binaries and data root, per installed instance
$sqlInstanceKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
if (Test-Path -LiteralPath $sqlInstanceKey) {
    $instances = Get-ItemProperty -Path $sqlInstanceKey -ErrorAction SilentlyContinue
    foreach ($prop in $instances.PSObject.Properties) {
        if ($prop.Name -like 'PS*') { continue }
        $instSetup = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($prop.Value)\Setup" -ErrorAction SilentlyContinue
        foreach ($valueName in @('SQLDataRoot', 'SQLPath', 'SQLBinRoot')) {
            if ($instSetup -and $instSetup.$valueName) { $paths.Add([string]$instSetup.$valueName) }
        }
    }
}

# Content roots that live at the root of any fixed drive. Only add what exists
# so the exclusion list stays readable when someone audits it later.
$contentDirPattern = '^(SCCMContentLib|SMS_DP\$|SMSPKG.*|SMSSIG\$|SMS_CCM|RemoteInstall|WSUS|WSUSContent)$'
foreach ($disk in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
    $root = "$($disk.DeviceID)\"
    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $contentDirPattern } |
        ForEach-Object { $paths.Add($_.FullName) }
}

$preference = Get-MpPreference -ErrorAction SilentlyContinue
$existingPaths = @($preference.ExclusionPath)
$newPaths = @($paths | Where-Object { $_ } | Sort-Object -Unique | Where-Object { $existingPaths -notcontains $_ })
if ($newPaths.Count -gt 0) {
    try {
        Add-MpPreference -ExclusionPath $newPaths -ErrorAction Stop
        $applied.Add("$($newPaths.Count) path exclusion(s)")
        Write-Step "Added path exclusions: $($newPaths -join '; ')"
    }
    catch { $failures.Add("ExclusionPath: $($_.Exception.Message)") }
}
else {
    Write-Step 'Path exclusions already current.'
}

# ---------------------------------------------------------------------------
# Extension and process exclusions
# ---------------------------------------------------------------------------
$existingExtensions = @($preference.ExclusionExtension)
$newExtensions = @(@('mdf', 'ldf', 'ndf', 'bak', 'trn', 'vhd', 'vhdx') | Where-Object { $existingExtensions -notcontains $_ })
if ($newExtensions.Count -gt 0) {
    try {
        Add-MpPreference -ExclusionExtension $newExtensions -ErrorAction Stop
        $applied.Add("$($newExtensions.Count) extension exclusion(s)")
    }
    catch { $failures.Add("ExclusionExtension: $($_.Exception.Message)") }
}

$existingProcesses = @($preference.ExclusionProcess)
$newProcesses = @(@(
        'sqlservr.exe', 'sqlagent.exe', 'sqlwriter.exe', 'sqlceip.exe', 'fdhost.exe', 'fdlauncher.exe',
        'ReportingServicesService.exe',
        'smsexec.exe', 'sitecomp.exe', 'cmupdate.exe', 'smsdbmon.exe', 'smswriter.exe', 'smssqlbkup.exe',
        'smsdpmon.exe', 'CmRcService.exe',
        'CcmExec.exe', 'ccmsetup.exe', 'CcmRepair.exe', 'PolicyPv.exe',
        'w3wp.exe', 'WsusService.exe', 'wsusutil.exe'
    ) | Where-Object { $existingProcesses -notcontains $_ })
if ($newProcesses.Count -gt 0) {
    try {
        Add-MpPreference -ExclusionProcess $newProcesses -ErrorAction Stop
        $applied.Add("$($newProcesses.Count) process exclusion(s)")
    }
    catch { $failures.Add("ExclusionProcess: $($_.Exception.Message)") }
}

# ---------------------------------------------------------------------------
# Scan scheduling and throttling. Not owned by Tamper Protection.
# ScanScheduleDay / RemediationScheduleDay 8 = Never.
# ---------------------------------------------------------------------------
$scanSettings = [ordered]@{
    ScanAvgCPULoadFactor                = 10
    ScanOnlyIfIdleEnabled               = $true
    DisableCatchupFullScan              = $true
    DisableCatchupQuickScan             = $true
    ScanScheduleDay                     = 8
    RemediationScheduleDay              = 8
    DisableScanningNetworkFiles         = $true
    DisableRemovableDriveScanning       = $true
    CheckForSignaturesBeforeRunningScan = $false
}
foreach ($name in $scanSettings.Keys) {
    try {
        $splat = @{ $name = $scanSettings[$name] }
        Set-MpPreference @splat -ErrorAction Stop
        $applied.Add("$name=$($scanSettings[$name])")
    }
    catch { $failures.Add("$name : $($_.Exception.Message)") }
}

# ---------------------------------------------------------------------------
# Levers Tamper Protection owns WHEN IT IS ON. Set, then re-read: under Tamper
# Protection Set-MpPreference reports success and changes nothing, so the
# read-back is the only thing that distinguishes Applied from Blocked. Do not
# assume TP is the cause -- these were seen refused with IsTamperProtected=False,
# so keep whatever Set-MpPreference actually said and report policy overrides.
# ---------------------------------------------------------------------------
$protectedSettings = [ordered]@{
    DisableRealtimeMonitoring = $true
    DisableBehaviorMonitoring = $true
    DisableIOAVProtection     = $true
    DisableArchiveScanning    = $true
    MAPSReporting             = 0
    SubmitSamplesConsent      = 2
}
$setErrors = @{}
foreach ($name in $protectedSettings.Keys) {
    try {
        $splat = @{ $name = $protectedSettings[$name] }
        Set-MpPreference @splat -ErrorAction Stop
    }
    catch { $setErrors[$name] = ($_.Exception.Message -replace '\s+', ' ').Trim() }
}

# Group Policy beats the preference API and is the usual cause when TP is off.
$policyNames = @()
foreach ($polKey in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet') {
    try {
        if (Test-Path -LiteralPath $polKey) {
            $props = Get-ItemProperty -LiteralPath $polKey -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') {
                    $policyNames += "$(Split-Path $polKey -Leaf)\$($p.Name)=$($p.Value)"
                }
            }
        }
    }
    catch {}
}

$afterPreference = Get-MpPreference -ErrorAction SilentlyContinue
foreach ($name in $protectedSettings.Keys) {
    $wanted = $protectedSettings[$name]
    $actual = if ($afterPreference) { $afterPreference.$name } else { $null }
    if ("$actual" -eq "$wanted") { $applied.Add("$name=$wanted") }
    else {
        $why = ''
        if ($setErrors.ContainsKey($name)) { $why = " [$($setErrors[$name])]" }
        $blocked.Add("$name (wanted $wanted, still $actual)$why")
    }
}

# ---------------------------------------------------------------------------
# Idle-time Defender maintenance tasks (scheduled scan, cache maintenance,
# cleanup, verification). These are Task Scheduler objects, not MpPreference,
# so Tamper Protection does not cover them.
# ---------------------------------------------------------------------------
try {
    $defenderTasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' })
    foreach ($task in $defenderTasks) {
        Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
    }
    if ($defenderTasks.Count -gt 0) { $applied.Add("$($defenderTasks.Count) Defender scheduled task(s) disabled") }
}
catch { $failures.Add("Defender scheduled tasks: $($_.Exception.Message)") }

# ---------------------------------------------------------------------------
$success = ($failures.Count -eq 0)
$message = "Applied $($applied.Count) setting(s)."
if ($blocked.Count -gt 0) {
    $cause = 'unknown cause (TamperProtection is OFF)'
    if ($tamperProtected) { $cause = 'Tamper Protection' }
    elseif ($policyNames.Count -gt 0) { $cause = 'Group Policy' }
    $message += " Refused by ${cause} ($($blocked.Count)): $($blocked -join '; ')."
    if ($policyNames.Count -gt 0) { $message += " Defender policy values present: $($policyNames -join ', ')." }
    if ($isServer) { $message += ' Use -Remove to uninstall Defender on this server.' }
}
if ($failures.Count -gt 0) { $message += " Failed: $($failures -join '; ')." }

Write-Step $message
[pscustomobject]@{
    Success = $success
    Message = $message
    Errors  = @($failures)
    Applied = @($applied)
    Blocked = @($blocked)
}
