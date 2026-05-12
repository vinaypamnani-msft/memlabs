# Common.Health.ps1
# Overall-health dashboard widget shown on the Main Menu.
# Self-contained: queries Get-List, formats a compact status block, and
# caches results in $Global:HealthStatsCache for ~20s so per-keystroke menu
# redraws stay snappy.

function Get-PendingVMs {

    $pending = get-list -type VM | Where-Object { $_.InProgress -eq "True" }
    $actualPending = @()
    foreach ($vm in $pending) {
        $mtx = New-Object System.Threading.Mutex($false, $vm.vmName)
        if ($mtx.WaitOne(1)) {
            try {
                [void]$mtx.ReleaseMutex()
            }
            catch {}
            try {
                [void]$mtx.Dispose()
            }
            catch {}            
            write-log -Verbose "Acquired Mutex $($vm.vmName)"
            $actualPending += $vm
        }               
    }
    return $actualPending
}

# Cache for Quick Stats / Check-OverallHealth and related per-menu-redraw queries.
# These values are queried on every menu redraw (every keystroke), so caching them
# for a short TTL eliminates the visible lag on the Main Menu.
$Global:HealthStatsCache = $null
$Global:HealthStatsCacheTTLSeconds = 20

function Clear-HealthStatsCache {
    $Global:HealthStatsCache = $null
}

function Get-HealthStats {
    [CmdletBinding()]
    param(
        [switch] $Force
    )

    if (-not $Force -and $Global:HealthStatsCache) {
        $age = (Get-Date) - $Global:HealthStatsCache.Timestamp
        if ($age.TotalSeconds -lt $Global:HealthStatsCacheTTLSeconds) {
            return $Global:HealthStatsCache
        }
    }

    $disk = Get-Volume -DriveLetter E -ErrorAction SilentlyContinue
    $os = Get-Ciminstance Win32_OperatingSystem |
        Select-Object @{Name = "FreeGB"; Expression = { [math]::Round($_.FreePhysicalMemory / 1mb, 0) } },
                      @{Name = "TotalGB"; Expression = { [int]($_.TotalVisibleMemorySize / 1mb) } }
    $uptimeHours = $null
    try { $uptimeHours = [math]::Round((Get-Uptime).TotalHours, 1) } catch {}

    $vmList = Get-List -Type VM
    $pendingCount = (Get-PendingVMs | Measure-Object).Count

    $Global:HealthStatsCache = [PSCustomObject]@{
        Timestamp    = Get-Date
        DiskTotalGB  = if ($disk) { [math]::Round($disk.Size / 1GB, 0) } else { 0 }
        DiskFreeGB   = if ($disk) { [math]::Round($disk.SizeRemaining / 1GB, 0) } else { 0 }
        FreeMemGB    = $os.FreeGB
        TotalMemGB   = $os.TotalGB
        UptimeHours  = $uptimeHours
        VmsRunning   = ($vmList | Where-Object { $_.State -eq "Running" } | Measure-Object).Count
        VmsTotal     = ($vmList | Measure-Object).Count
        PendingCount = $pendingCount
    }

    return $Global:HealthStatsCache
}

# Return a color name for a "free" percentage (higher = better).
function Get-HealthThresholdColor {
    param(
        [double] $Percent,
        [double] $GreenAt = 30,
        [double] $YellowAt = 15
    )
    if ($Percent -ge $GreenAt)  { return 'LimeGreen' }
    if ($Percent -ge $YellowAt) { return 'Gold' }
    return 'Red'
}

# Draw a fixed-width proportional bar: [████░░░░░░░░░░░░░░░░]
# Filled portion is colored by free-percentage threshold (green/yellow/red).
function Write-HealthBar {
    [CmdletBinding()]
    param(
        [double] $Percent,
        [int]    $Width = 20,
        [double] $GreenAt = 30,
        [double] $YellowAt = 15
    )
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $filled = [int][math]::Round(($Percent / 100) * $Width)
    if ($filled -lt 0) { $filled = 0 } elseif ($filled -gt $Width) { $filled = $Width }
    $empty = $Width - $filled
    $color = Get-HealthThresholdColor -Percent $Percent -GreenAt $GreenAt -YellowAt $YellowAt

    Write-Host '[' -NoNewline
    if ($filled -gt 0) {
        Write-Host2 -ForegroundColor $color ('█' * $filled) -NoNewline
    }
    if ($empty -gt 0) {
        Write-Host2 -ForegroundColor DarkGray ('░' * $empty) -NoNewline
    }
    Write-Host ']' -NoNewline
}

# Write a status icon ([√] / [!] / [x]) chosen from a free-percentage value.
function Write-HealthStatusIcon {
    param(
        [double] $Percent,
        [double] $GreenAt = 30,
        [double] $YellowAt = 15
    )
    $CHECKMARK = ([char]8730)
    Write-Host '[' -NoNewline
    if ($Percent -ge $GreenAt) {
        Write-Host2 -ForegroundColor LimeGreen $CHECKMARK -NoNewline
    }
    elseif ($Percent -ge $YellowAt) {
        Write-Host2 -ForegroundColor Gold '!' -NoNewline
    }
    else {
        Write-Host2 -ForegroundColor Red 'x' -NoNewline
    }
    Write-Host ']' -NoNewline
}

function Check-OverallHealth {

    param (
        [Parameter(Mandatory = $false)]
        [switch] $LineCount
    )

    if ($LineCount) {
        return 5
    }
    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'Continue'

    $Indent = 3
    $pad = ' ' * $Indent
    $stats = Get-HealthStats

    # ---- Percent helpers (all "free / good" percentages: higher = better) ---
    $vmsPct  = if ($stats.VmsTotal   -gt 0) { ($stats.VmsRunning / $stats.VmsTotal)   * 100 } else { 0 }
    $diskPct = if ($stats.DiskTotalGB -gt 0) { ($stats.DiskFreeGB / $stats.DiskTotalGB) * 100 } else { 0 }
    $memPct  = if ($stats.TotalMemGB  -gt 0) { ($stats.FreeMemGB  / $stats.TotalMemGB)  * 100 } else { 0 }

    # Thresholds: green at >=, yellow at >=, else red
    $vmThresh   = @{ GreenAt = 100; YellowAt = 50 }
    $diskThresh = @{ GreenAt = 20;  YellowAt = 10 }
    $memThresh  = @{ GreenAt = 30;  YellowAt = 15 }

    # Column widths
    $labelWidth = 8
    $valueWidth = 14
    $barWidth   = 20

    $rows = @(
        [PSCustomObject]@{
            Label   = 'VMs'
            Value   = if ($stats.VmsTotal -eq 0) { 'none deployed' } else { "$($stats.VmsRunning)/$($stats.VmsTotal) running" }
            Percent = $vmsPct
            Thresh  = $vmThresh
        }
        [PSCustomObject]@{
            Label   = 'Disk E:'
            Value   = "$($stats.DiskFreeGB)/$($stats.DiskTotalGB)GB"
            Percent = $diskPct
            Thresh  = $diskThresh
        }
        [PSCustomObject]@{
            Label   = 'Memory'
            Value   = "$($stats.FreeMemGB)/$($stats.TotalMemGB)GB"
            Percent = $memPct
            Thresh  = $memThresh
        }
    )

    foreach ($r in $rows) {
        Write-Host $pad -NoNewline
        Write-Host ($r.Label.PadRight($labelWidth)) -NoNewline -ForegroundColor White
        Write-HealthBar -Percent $r.Percent -Width $barWidth -GreenAt $r.Thresh.GreenAt -YellowAt $r.Thresh.YellowAt
        Write-Host ' ' -NoNewline
        Write-Host ($r.Value.PadRight($valueWidth)) -NoNewline
        Write-HealthStatusIcon -Percent $r.Percent -GreenAt $r.Thresh.GreenAt -YellowAt $r.Thresh.YellowAt
        Write-Host
    }

    # ---- Patch Tuesday footer ---------------------------------------------
    $today = Get-Date
    $firstDayOfMonth = Get-Date -Year $today.Year -Month $today.Month -Day 1
    $secondTuesday = $firstDayOfMonth.AddDays((([int][DayOfWeek]::Tuesday - [int]$firstDayOfMonth.DayOfWeek + 7) % 7) + 7)

    if ($today.Date -eq $secondTuesday.Date) {
        $hoursSinceReboot = $stats.UptimeHours
        if ($null -ne $hoursSinceReboot -and $hoursSinceReboot -le 12) {
            Write-GreenCheck -indent $Indent "Patch Tuesday: machine was rebooted $hoursSinceReboot hours ago."
        }
        else {
            Write-RedX -indent $Indent "Patch Tuesday: your machine will likely reboot today at 2-3 PM EST."
        }
    }

    Write-Host
    $Global:ProgressPreference = $OriginalProgressPreference

}
