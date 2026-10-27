<#
.SYNOPSIS
    Collect boot-time evidence from running memlabs Linux VMs over SSH.

.DESCRIPTION
    Runs scripts/linux/diag/boot-profile.sh in each guest and writes the raw
    output to vmbuild\logs\linux-boot\<VmName>-<timestamp>.txt, then prints a
    comparison table of the numbers that decide re-bake work:

        kernel seconds / userspace seconds  (systemd-analyze time)
        the slowest units                   (systemd-analyze blame)
        whether the serial console has a baud rate on the kernel cmdline
        whether a forced fsck runs on every boot
        failed units, and whether sshd is actually listening

    The VM must be booted and SSH-reachable -- this reads a boot that already
    happened, it does not reboot anything. Run it right after a deployment,
    while the evidence is still in the journal.

    Nothing here is inferred from absence: a VM that could not be reached is
    reported as NOT COLLECTED and is excluded from the summary, so an empty
    result can never read as a clean bill of health.

.PARAMETER VmName
    One or more Hyper-V VM names. Omit to profile every running Linux VM.

.PARAMETER Destination
    Folder for the raw profiles. Defaults to vmbuild\logs\linux-boot.

.PARAMETER TimeoutSeconds
    Per-VM SSH timeout. The profile does a fair amount of journal reading.

.EXAMPLE
    .\Get-LinuxBootProfile.ps1
    Profile every running Linux VM.

.EXAMPLE
    .\Get-LinuxBootProfile.ps1 -VmName ZZ-TOFU, ZZ-SQUID
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [string[]]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$Destination,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

$vmbuildRoot = Split-Path -Path $PSScriptRoot -Parent
. (Join-Path $vmbuildRoot 'Common.ps1')

if ($Common.FatalError) {
    Write-Log "Critical Failure! $($Common.FatalError)" -Failure
    return
}

if (-not $Destination) {
    $Destination = Join-Path $vmbuildRoot 'logs\linux-boot'
}
if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

function ConvertFrom-SystemdDuration {
    # systemd-analyze prints durations as "55.080s", "1min 46.128s", "2min",
    # "1h 3min 2s". Returns $null when nothing parsed, so a failed parse is
    # never rendered as 0 seconds.
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $total = 0.0
    $matched = $false
    foreach ($m in [regex]::Matches($Text, '(?<n>\d+(?:\.\d+)?)\s*(?<u>h|min|ms|s)\b')) {
        $n = [double]$m.Groups['n'].Value
        $total += switch ($m.Groups['u'].Value) {
            'h' { $n * 3600 }
            'min' { $n * 60 }
            'ms' { $n / 1000 }
            default { $n }
        }
        $matched = $true
    }
    if (-not $matched) { return $null }
    return [math]::Round($total, 2)
}

# Resolve the target set. Test-VmIsLinux takes a VM OBJECT (osFamily /
# operatingSystem), not a name, so pair Hyper-V state with the memlabs list.
if ($VmName) {
    $targets = @($VmName)
}
else {
    $running = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } | Select-Object -ExpandProperty Name)
    $targets = @(Get-List -Type VM | Where-Object { (Test-VmIsLinux -Vm $_) -and $_.vmName -in $running } |
            Select-Object -ExpandProperty vmName)
}

if ($targets.Count -eq 0) {
    Write-Log "No running Linux VMs found. Nothing was measured." -Warning
    return
}

Write-Log "Collecting boot profiles from $($targets.Count) VM(s): $($targets -join ', ')" -Activity

$script = Get-LinuxScript -Name 'diag/boot-profile'
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$summary = [System.Collections.Generic.List[object]]::new()
$notCollected = [System.Collections.Generic.List[string]]::new()

foreach ($vm in $targets) {
    Write-Log "$vm`: collecting boot profile..." -Activity
    $result = Invoke-LinuxVmCommand -VmName $vm -BashCommand $script -Sudo `
        -DisplayName 'boot profile' -TimeoutSeconds $TimeoutSeconds

    if (-not $result.CommandResult -or [string]::IsNullOrWhiteSpace($result.ScriptBlockOutput)) {
        Write-Log "$vm`: boot profile NOT COLLECTED (exit=$($result.ExitCode)). This VM is excluded from the summary." -Warning
        $notCollected.Add("$vm (exit=$($result.ExitCode))")
        continue
    }

    $outFile = Join-Path $Destination "$vm-$stamp.txt"
    [System.IO.File]::WriteAllText($outFile, $result.ScriptBlockOutput, [System.Text.UTF8Encoding]::new($false))
    Write-Log "$vm`: wrote $outFile" -Success

    $text = $result.ScriptBlockOutput
    $lines = $text -split "`r?`n"

    # systemd-analyze time -> "Startup finished in 55.080s (kernel) + 1min 46.128s (userspace) = 2min 41.209s"
    $kernelSec = $null
    $userSec = $null
    $totalSec = $null
    $timeLine = @($lines | Where-Object { $_ -match 'Startup finished in .*\(kernel\)' }) | Select-Object -First 1
    if ($timeLine) {
        $kernelSec = ConvertFrom-SystemdDuration -Text ([regex]::Match($timeLine, '(?<v>[^n]+?)\s*\(kernel\)').Groups['v'].Value)
        $userSec = ConvertFrom-SystemdDuration -Text ([regex]::Match($timeLine, '\+\s*(?<v>.+?)\s*\(userspace\)').Groups['v'].Value)
        $totalSec = ConvertFrom-SystemdDuration -Text ([regex]::Match($timeLine, '=\s*(?<v>.+?)\s*$').Groups['v'].Value)
    }

    $slowest = @($lines |
            Where-Object { $_ -match '^\s*(?<d>\d[\d.]*(?:min)?\s*\S*)\s+(?<u>\S+\.(?:service|mount|target|socket))\s*$' } |
            Select-Object -First 5) -join '; '

    $failedLine = @($lines | Where-Object { $_ -match '^failed unit count:\s*(\d+)' }) | Select-Object -First 1
    $failedCount = if ($failedLine -match '(\d+)') { [int]$Matches[1] } else { $null }

    $summary.Add([pscustomobject]@{
            VM          = $vm
            KernelSec   = $kernelSec
            UserSec     = $userSec
            TotalSec    = $totalSec
            FailedUnits = $failedCount
            SerialBaud  = if ($text -match 'WARNING: serial console has NO baud') { 'MISSING (9600)' }
            elseif ($text -match 'OK: serial console baud is set') { 'set' }
            else { 'no serial console' }
            ForcedFsck  = ($text -match 'WARNING: fsck.mode=force')
            DataJournal = ($text -match 'WARNING: rootflags=data=journal')
            Sshd22      = if ($text -match 'NOTHING LISTENING ON TCP/22') { 'DOWN' } else { 'listening' }
            Slowest     = $slowest
        })
}

Write-Host ''
Write-Host '=== Boot profile summary ===' -ForegroundColor Cyan
if ($summary.Count -eq 0) {
    Write-Host 'NOTHING WAS MEASURED - no VM returned a profile.' -ForegroundColor Red
}
else {
    $summary | Select-Object VM, KernelSec, UserSec, TotalSec, FailedUnits, SerialBaud, ForcedFsck, DataJournal, Sshd22 |
        Format-Table -AutoSize
    Write-Host 'Slowest units per VM:' -ForegroundColor Cyan
    $summary | ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.VM, $_.Slowest) }
}

if ($notCollected.Count -gt 0) {
    Write-Host ''
    Write-Host "NOT COLLECTED from $($notCollected.Count) of $($targets.Count) VM(s): $($notCollected -join ', ')" -ForegroundColor Yellow
    Write-Host 'Those VMs are absent from the table above - that is a gap in the data, not a pass.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Raw profiles: $Destination" -ForegroundColor Gray
