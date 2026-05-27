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
    [switch]$NoLog
)

$pipeName = "memlabs-$VmName-com1"

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
while ($true) {
    $server = $null
    $reader = $null
    try {
        $server = New-Object System.IO.Pipes.NamedPipeServerStream(
            $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut,
            1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::Asynchronous)

        $server.WaitForConnection()
        Write-Host "[connected $(Get-Date -Format HH:mm:ss)]" -ForegroundColor Green
        if (-not $NoLog) {
            "`n=== connected $(Get-Date -Format o) ===" | Out-File -FilePath $LogFile -Append -Encoding utf8
        }

        $buffer = New-Object byte[] 4096
        while ($server.IsConnected) {
            $count = $server.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) { break }
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $count)
            [Console]::Write($text)
            if (-not $NoLog) {
                # Append-AllText keeps existing bytes verbatim; preserves \r\n etc.
                [System.IO.File]::AppendAllText($LogFile, $text, [System.Text.Encoding]::UTF8)
            }
        }
        Write-Host "`n[disconnected $(Get-Date -Format HH:mm:ss)]" -ForegroundColor Yellow
    }
    catch {
        Write-Host "tap error: $_" -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
    finally {
        if ($server) { try { $server.Dispose() } catch {} }
    }
}
