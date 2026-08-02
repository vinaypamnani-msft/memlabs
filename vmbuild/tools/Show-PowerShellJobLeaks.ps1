<#
.SYNOPSIS
    Inventory PowerShell processes on a MemLabs host and identify leaked job workers.

.DESCRIPTION
    Every Start-Job spawns a `pwsh.exe -s -NoLogo -NoProfile` worker process, and
    MemLabs starts one per VM per phase (VM_Create / VM_Config / Proxy_Install /
    Linux_Configure) plus one per Copy-ItemSafe. A worker exits by itself as soon
    as its scriptblock finishes -- Remove-Job is not required for the process to
    go -- so any worker still alive belongs to a job that never finished.

    Each worker costs ~85MB idle and 300MB+ once it has dot-sourced Common.ps1,
    so a few dozen survivors are enough to fail the Phase 1 memory pre-flight of
    a later build.

    Read-only by default. -KillOrphans terminates only workers whose owning shell
    is gone.

.EXAMPLE
    .\Show-PowerShellJobLeaks.ps1

.EXAMPLE
    .\Show-PowerShellJobLeaks.ps1 -KillOrphans
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$KillOrphans
)

$procs = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { Write-Host "No PowerShell processes found."; return }

$live = @{}
foreach ($p in @(Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue)) { $live[[int]$p.Id] = $p }

$rows = foreach ($p in $procs) {
    $proc = $live[[int]$p.ProcessId]
    if (-not $proc) { continue }

    $parentAlive = $null -ne $live[[int]$p.ParentProcessId]
    $parentName = '<gone>'
    if ($parentAlive) { $parentName = $live[[int]$p.ParentProcessId].ProcessName }
    else {
        $anyParent = Get-Process -Id $p.ParentProcessId -ErrorAction SilentlyContinue
        if ($anyParent) { $parentName = $anyParent.ProcessName; $parentAlive = $true }
    }

    $ageMin = -1
    try { $ageMin = [Math]::Round(((Get-Date) - $proc.StartTime).TotalMinutes) } catch { }

    # A job worker is launched in server mode; that command line is the tell.
    $isWorker = ("$($p.CommandLine)" -match '-s\s+-NoLogo')

    [pscustomobject]@{
        Pid       = [int]$p.ProcessId
        WS_MB     = [Math]::Round($proc.WorkingSet64 / 1MB)
        AgeMin    = $ageMin
        JobWorker = $isWorker
        ParentPid = [int]$p.ParentProcessId
        Parent    = $parentName
        Orphan    = ($isWorker -and -not $parentAlive)
    }
}

$rows = @($rows)
$workers = @($rows | Where-Object { $_.JobWorker })
$orphans = @($rows | Where-Object { $_.Orphan })

# A worker much older than its siblings is a job that never finished. Everything
# else at the same age is just a phase legitimately in flight (one worker per VM,
# ~320MB each once it has dot-sourced Common.ps1), so compare against the median
# rather than an absolute age.
$stuck = @()
$workerAges = @($workers | Where-Object { $_.AgeMin -ge 0 } | Select-Object -ExpandProperty AgeMin | Sort-Object)
$medianAge = 0
if ($workerAges.Count -ge 3) {
    $medianAge = $workerAges[[int]($workerAges.Count / 2)]
    $stuck = @($workers | Where-Object { $_.AgeMin -gt 30 -and $_.AgeMin -gt ($medianAge * 3) })
}

Write-Host ""
Write-Host ("PowerShell processes : {0}   total {1} MB" -f $rows.Count, (($rows.WS_MB | Measure-Object -Sum).Sum)) -ForegroundColor Cyan
Write-Host ("  job workers        : {0}   holding {1} MB   (median age {2}m)" -f $workers.Count, (($workers.WS_MB | Measure-Object -Sum).Sum), $medianAge)
Write-Host ("  STUCK workers      : {0}   holding {1} MB  (far older than their siblings -- job never finished)" -f $stuck.Count, (($stuck.WS_MB | Measure-Object -Sum).Sum)) -ForegroundColor $(if ($stuck.Count) { 'Red' } else { 'Green' })
Write-Host ("  ORPHANED workers   : {0}   holding {1} MB  (owning shell is gone)" -f $orphans.Count, (($orphans.WS_MB | Measure-Object -Sum).Sum)) -ForegroundColor $(if ($orphans.Count) { 'Red' } else { 'Green' })
Write-Host ""

$rows | Sort-Object WS_MB -Descending | Select-Object -First 40 |
    Format-Table Pid, WS_MB, AgeMin, JobWorker, Orphan, ParentPid, Parent -AutoSize

if ($stuck.Count -gt 0) {
    Write-Host "STUCK workers (age outliers -- these belong to jobs that never finished):" -ForegroundColor Red
    $stuck | Sort-Object AgeMin -Descending | Format-Table Pid, WS_MB, AgeMin, ParentPid -AutoSize
    Write-Host "  The owning shell's build log names them: grep it for '[JobLeak]' to get the VM and phase." -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "Job workers grouped by owning shell:" -ForegroundColor Cyan
$workers | Group-Object ParentPid | Sort-Object { ($_.Group.WS_MB | Measure-Object -Sum).Sum } -Descending |
    ForEach-Object {
        $sum = ($_.Group.WS_MB | Measure-Object -Sum).Sum
        $owner = $_.Group[0].Parent
        Write-Host ("  shell pid {0,-8} ({1,-12}) {2,3} worker(s)  {3,6} MB" -f $_.Name, $owner, $_.Count, $sum)
    }

if ($orphans.Count -gt 0) {
    Write-Host ""
    Write-Host "Orphaned workers (safe to terminate -- nothing can ever collect them):" -ForegroundColor Yellow
    $orphans | Sort-Object WS_MB -Descending | Format-Table Pid, WS_MB, AgeMin, ParentPid -AutoSize

    if ($KillOrphans) {
        foreach ($o in $orphans) {
            if ($PSCmdlet.ShouldProcess("pwsh pid $($o.Pid) ($($o.WS_MB) MB)", "Stop-Process")) {
                Stop-Process -Id $o.Pid -Force -ErrorAction SilentlyContinue
                Write-Host "  terminated pid $($o.Pid)" -ForegroundColor DarkYellow
            }
        }
    }
    else {
        Write-Host "Re-run with -KillOrphans to terminate them." -ForegroundColor DarkGray
    }
}
