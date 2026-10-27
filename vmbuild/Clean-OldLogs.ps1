<#
.SYNOPSIS
    Delete vmbuild log/temp clutter older than N days.

.DESCRIPTION
    Cleans:
      - vmbuild\logs\*.log         (rotated deploy logs)
      - vmbuild\logs\crashlogs\*   (crash dumps)
      - vmbuild\temp\*             (per-deploy scratch dirs)
      - vmbuild\cache\*.json       (stale Hyper-V / hotfix / etc. JSON)
      - %TEMP%\cloudinit\*         (per-VM cloud-init seed staging dirs)

    Skips the currently-open VMBuild.log (in-use file).
    Use -WhatIf for a dry run.

.PARAMETER Days
    Files older than this many days are deleted. Default 7.

.EXAMPLE
    .\Clean-OldLogs.ps1
    .\Clean-OldLogs.ps1 -Days 14 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$Days = 7
)

$cutoff = (Get-Date).AddDays(-$Days)
$root = $PSScriptRoot
$total = 0
$bytes = 0L

function Remove-OldItems {
    param(
        [string]$Path,
        [string]$Filter = '*',
        [switch]$Recurse,
        [switch]$Directory
    )
    if (-not (Test-Path $Path)) { return }
    $items = if ($Directory) {
        Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue
    }
    else {
        Get-ChildItem -Path $Path -File -Filter $Filter -Recurse:$Recurse -ErrorAction SilentlyContinue
    }
    foreach ($i in $items) {
        if ($i.LastWriteTime -ge $cutoff) { continue }
        $sz = if ($Directory) {
            (Get-ChildItem $i.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        }
        else { $i.Length }
        if ($PSCmdlet.ShouldProcess($i.FullName, "Remove ($([Math]::Round($sz/1MB,2)) MB)")) {
            try {
                Remove-Item -Path $i.FullName -Recurse:$Directory -Force -ErrorAction Stop
                $script:total++
                $script:bytes += [long]$sz
            }
            catch {
                Write-Warning "$($i.FullName): $($_.Exception.Message)"
            }
        }
    }
}

Write-Host "Cleaning items older than $cutoff" -ForegroundColor Cyan

# Logs
Remove-OldItems -Path (Join-Path $root 'logs') -Filter '*.log'
Remove-OldItems -Path (Join-Path $root 'logs\crashlogs')

# Temp scratch dirs (per-deploy)
Remove-OldItems -Path (Join-Path $root 'temp') -Directory

# Stale JSON cache (Common.ps1:5560 already does this for >threshold days, but
# threshold may be longer than what we want; force the user's preference here)
Remove-OldItems -Path (Join-Path $root 'cache') -Filter '*.json'

# cloud-init staging under $env:TEMP
$ciStage = Join-Path $env:TEMP 'cloudinit'
Remove-OldItems -Path $ciStage -Directory

Write-Host ("Done. Removed {0} items ({1:N1} MB)." -f $total, ($bytes / 1MB)) -ForegroundColor Green
