<#
.SYNOPSIS
    Attach to a memlabs Linux VM's COM1 named pipe and stream output to the
    console (and optionally a file).

.DESCRIPTION
    New-LinuxVirtualMachine wires every Linux VM's COM1 to
    \\.\pipe\memlabs-<VmName>-com1. This script implements the pipe SERVER
    end: it creates the named pipe and waits for Hyper-V (the client) to
    connect when the VM boots, then streams everything the guest writes to
    ttyS0 -- GRUB, kernel messages, cloud-init logs, login prompts -- to
    stdout and optionally tees it to a file.

    Start this BEFORE Start-VM (or before redeploying) to capture the full
    boot sequence. Ctrl-C to detach; the VM keeps running, the pipe just
    closes on its end.

.PARAMETER VmName
    The Hyper-V VM name (matches what New-LinuxVirtualMachine produced).

.PARAMETER LogFile
    Optional. If set, output is also appended to this file (UTF-8). Defaults
    to vmbuild\logs\linux-serial\<VmName>.log inside the repo.

.PARAMETER NoLog
    Don't write to a log file, console only.

.EXAMPLE
    .\Get-LinuxSerialTap.ps1 -VmName ADA-PROXY1

.EXAMPLE
    .\Get-LinuxSerialTap.ps1 -VmName ADA-PROXY1 -NoLog
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$LogFile,

    [Parameter(Mandatory = $false)]
    [switch]$NoLog,

    # Exit on its own after N minutes. 0 = run forever (interactive use).
    # The build starts this unattended, so it must not outlive the VM wait.
    [Parameter(Mandatory = $false)]
    [int]$ExitAfterMinutes = 0,

    # Skip the console echo. A hidden/unattended recorder has no console reader,
    # so [Console]::Write blocks once the output buffer fills (~3KB in practice)
    # and the capture silently stops seconds into the boot.
    [Parameter(Mandatory = $false)]
    [switch]$NoConsoleEcho
)

$pipeName = "memlabs-$VmName-com1"
$deadline = if ($ExitAfterMinutes -gt 0) { (Get-Date).AddMinutes($ExitAfterMinutes) } else { [datetime]::MaxValue }

if (-not $NoLog) {
    if (-not $LogFile) {
        $logDir = Join-Path $PSScriptRoot 'logs\linux-serial'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $LogFile = Join-Path $logDir "$VmName.log"
    }
    Write-Host "Logging to: $LogFile" -ForegroundColor DarkGray
}

Write-Host "Listening on \\.\pipe\$pipeName ..." -ForegroundColor Cyan
Write-Host "Start (or restart) the VM now. Ctrl-C to detach." -ForegroundColor DarkGray

# Loop so the tap keeps running across VM reboots (cloud-init reboots after
# first-boot config; we want to capture both boots without restarting this).
while ((Get-Date) -lt $deadline) {
    $server = $null
    try {
        $server = New-Object System.IO.Pipes.NamedPipeServerStream(
            $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut,
            1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::Asynchronous)

        # Bounded wait so an unattended tap with no VM attached still exits.
        $connectTask = $server.BeginWaitForConnection($null, $null)
        while (-not $connectTask.AsyncWaitHandle.WaitOne(2000)) {
            if ((Get-Date) -ge $deadline) { break }
        }
        if (-not $connectTask.IsCompleted) { break }
        $server.EndWaitForConnection($connectTask)
        Write-Host "[connected $(Get-Date -Format HH:mm:ss)]" -ForegroundColor Green
        if (-not $NoLog) {
            "`n=== connected $(Get-Date -Format o) ===" | Out-File -FilePath $LogFile -Append -Encoding utf8
        }

        $buffer = New-Object byte[] 4096
        $readTask = $null
        $bytesThisConnection = 0
        $why = 'deadline'
        while ($server.IsConnected) {
            if (-not $readTask) { $readTask = $server.ReadAsync($buffer, 0, $buffer.Length) }
            if ($readTask.Wait(2000)) {
                $count = $readTask.Result
                $readTask = $null
                if ($count -le 0) { $why = 'read returned 0 (writer closed)'; break }
                $bytesThisConnection += $count
                $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $count)
                if (-not $NoConsoleEcho) { [Console]::Write($text) }
                if (-not $NoLog) {
                    # Append-AllText keeps existing bytes verbatim; preserves \r\n etc.
                    [System.IO.File]::AppendAllText($LogFile, $text, [System.Text.Encoding]::UTF8)
                }
            }
            if ((Get-Date) -ge $deadline) { $why = 'ExitAfterMinutes reached'; break }
        }
        if (-not $server.IsConnected) { $why = 'pipe disconnected (guest reset the COM port)' }
        Write-Host "`n[disconnected $(Get-Date -Format HH:mm:ss)]" -ForegroundColor Yellow
        # A capture that stops early is otherwise indistinguishable from a guest that
        # went quiet, so record which one it was.
        if (-not $NoLog) {
            "`n=== capture ended $(Get-Date -Format o): $why ($bytesThisConnection bytes this connection) ===" |
                Out-File -FilePath $LogFile -Append -Encoding utf8
        }
    }
    catch {
        Write-Host "tap error: $_" -ForegroundColor Red
        if (-not $NoLog) {
            "`n=== tap error $(Get-Date -Format o): $_ ===" | Out-File -FilePath $LogFile -Append -Encoding utf8
        }
        Start-Sleep -Seconds 1
    }
    finally {
        if ($server) { try { $server.Dispose() } catch {} }
    }
}
