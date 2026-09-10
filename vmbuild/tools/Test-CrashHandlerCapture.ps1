# Positive control for the unhandled-exception crash handler in Common.ps1.
# The disposed-PSJob death leaves NO stack on the host side -- the parent only receives the
# child's one stderr line as ErrorCode 2100 -- so Register-VmCrashHandler is the only thing
# that can ever name the object. This proves it actually fires in a worker-shaped process
# before we spend another lab run finding out it does not.
[CmdletBinding()]
param(
    # Defaults to the vmbuild folder this script lives under, so it works from any clone.
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [int]$TimeoutSeconds = 300,
    [switch]$KeepArtifact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $RootPath 'Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    Write-Host "SETUP FAIL: no Common.ps1 at $commonPath" -ForegroundColor Red
    exit 2
}
Write-Host "Common.ps1: $commonPath"

$requestedCrashPath = Join-Path $RootPath 'logs\MonitoredDeployment-crash-handler-test.child-crash.log'
$handoffJob = Start-Job -ArgumentList $commonPath, $requestedCrashPath -ScriptBlock {
    param($commonPath, $requestedCrashPath)
    [Environment]::SetEnvironmentVariable('MEMLABS_CRASH_LOG_PATH', $requestedCrashPath, [EnvironmentVariableTarget]::Process)
    . $commonPath -InJob
    "HANDOFF_LOGPATH=$([MemLabsCrash]::LogPath)"
    "HANDOFF_ENV_CLEARED=$([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('MEMLABS_CRASH_LOG_PATH', [EnvironmentVariableTarget]::Process)))"
    . $commonPath -InJob
    "HANDOFF_LOGPATH2=$([MemLabsCrash]::LogPath)"
}
$null = Wait-Job -Job $handoffJob -Timeout $TimeoutSeconds
$handoffOutput = @(Receive-Job -Job $handoffJob -ErrorAction SilentlyContinue 2>&1 | ForEach-Object { "$_" })
$handoffState = $handoffJob.State
Remove-Job -Job $handoffJob -Force -ErrorAction SilentlyContinue
if ($handoffState -ne 'Completed' -or
    -not ($handoffOutput -contains "HANDOFF_LOGPATH=$requestedCrashPath") -or
    -not ($handoffOutput -contains 'HANDOFF_ENV_CLEARED=True') -or
    -not ($handoffOutput -contains "HANDOFF_LOGPATH2=$requestedCrashPath")) {
    Write-Host 'RESULT: FAIL -- monitored crash target was not consumed once and preserved across a same-process rerun.' -ForegroundColor Red
    $handoffOutput | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Remove-Item -LiteralPath $requestedCrashPath -Force -ErrorAction SilentlyContinue

$job = Start-Job -ArgumentList $commonPath -ScriptBlock {
    param($commonPath)
    . $commonPath -InJob
    # Emitted BEFORE the throw so the parent still has it after the process dies.
    "PID=$PID"
    "TYPE_PRESENT=$([bool]('MemLabsCrash' -as [type]))"
    "REGISTERED=$($global:ps_crashHandlerRegistered)"
    try { "LOGPATH=$([MemLabsCrash]::LogPath)" } catch { "LOGPATH=<threw> $($_.Exception.Message)" }
    $firstLogPath = [MemLabsCrash]::LogPath
    . $commonPath -InJob
    "LOGPATH2=$([MemLabsCrash]::LogPath)"
    "SECOND_TARGET_PRESERVED=$([MemLabsCrash]::LogPath -eq $firstLogPath)"

    $blockedPath = Join-Path (Split-Path -Parent $firstLogPath) "VMBuild.unhandled.blocked.$PID.log"
    Set-Content -LiteralPath $blockedPath -Value stale
    $blockedStream = [IO.File]::Open($blockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        try { Set-VmCrashHandlerTarget -Path $blockedPath; 'BLOCKED_TARGET_REJECTED=False' }
        catch { 'BLOCKED_TARGET_REJECTED=True' }
    }
    finally {
        $blockedStream.Dispose()
        Remove-Item -LiteralPath $blockedPath -Force -ErrorAction SilentlyContinue
        Set-VmCrashHandlerTarget -Path $firstLogPath
    }

    Add-Type -TypeDefinition @'
using System;
public static class MemLabsThrower {
    public static void Boom() {
        System.Threading.ThreadPool.QueueUserWorkItem(delegate(object s) {
            throw new ObjectDisposedException("PROBE-PSJob", "synthetic threadpool crash");
        });
    }
}
'@ -ReferencedAssemblies 'System.Threading.ThreadPool', 'System.Runtime' -ErrorAction Stop
    [MemLabsThrower]::Boom()
    Start-Sleep -Seconds 6
    'CHILD_SURVIVED'
}

$null = Wait-Job -Job $job -Timeout $TimeoutSeconds
$out = @(Receive-Job -Job $job -ErrorAction SilentlyContinue 2>&1 | ForEach-Object { "$_" })
$state = $job.State
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'child reported:'
foreach ($line in $out) { Write-Host "  $line" }
Write-Host "job state: $state"

$logPath = ($out | Where-Object { $_ -like 'LOGPATH=*' } | Select-Object -First 1) -replace '^LOGPATH=', ''
Write-Host ''
if (-not $logPath -or $logPath -like '<threw>*') {
    Write-Host 'RESULT: the child never reported a crash-log target -- the handler is not armed at all.' -ForegroundColor Red
    exit 1
}
Write-Host "handler target: $logPath"
if (-not ($out -contains "LOGPATH2=$logPath") -or -not ($out -contains 'SECOND_TARGET_PRESERVED=True')) {
    Write-Host 'RESULT: FAIL -- same-process Common.ps1 rerun changed the durable crash target.' -ForegroundColor Red
    exit 1
}
if (-not ($out -contains 'BLOCKED_TARGET_REJECTED=True')) {
    Write-Host 'RESULT: FAIL -- crash target registration did not fail closed when stale cleanup was blocked.' -ForegroundColor Red
    exit 1
}
$expectedCrashRoot = [IO.Path]::GetFullPath((Join-Path $RootPath 'logs'))
$actualCrashRoot = if ($logPath) { Split-Path -Parent ([IO.Path]::GetFullPath($logPath)) } else { '' }
if ($actualCrashRoot -ne $expectedCrashRoot -or (Split-Path -Leaf $logPath) -ne "VMBuild.unhandled.$(($out | Where-Object { $_ -like 'PID=*' } | Select-Object -First 1) -replace '^PID=', '').log") {
    Write-Host "RESULT: FAIL -- crash handler target is not a top-level per-PID log under $expectedCrashRoot." -ForegroundColor Red
    exit 1
}

if (Test-Path -LiteralPath $logPath) {
    Write-Host 'RESULT: PASS -- the shipped handler captured a threadpool crash.' -ForegroundColor Green
    Get-Content -LiteralPath $logPath | Select-Object -Last 20 | ForEach-Object { "  $_" }
    # A synthetic crash log left in the crashlogs folder is indistinguishable from a real
    # one at a glance, and this file exists only to prove the plumbing.
    if (-not $KeepArtifact) {
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        Write-Host "removed probe artifact: $logPath"
    }
    exit 0
}

# A silent miss here is the whole point of the test: it means the next real crash is blind.
Write-Host 'RESULT: FAIL -- handler armed, but nothing was written. A real crash will leave no stack.' -ForegroundColor Red
exit 1
