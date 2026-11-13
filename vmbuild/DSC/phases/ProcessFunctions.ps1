function Initialize-MemLabsJobObjectType {
    if ('MemLabs.NativeJob' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MemLabs {
    public static class NativeJob {
        public const UInt32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public Int64 PerProcessUserTimeLimit;
            public Int64 PerJobUserTimeLimit;
            public UInt32 LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public UInt32 ActiveProcessLimit;
            public IntPtr Affinity;
            public UInt32 PriorityClass;
            public UInt32 SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS {
            public UInt64 ReadOperationCount;
            public UInt64 WriteOperationCount;
            public UInt64 OtherOperationCount;
            public UInt64 ReadTransferCount;
            public UInt64 WriteTransferCount;
            public UInt64 OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(
            IntPtr job, int infoClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, UInt32 length);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

function Write-MemLabsProcessProgress {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Record
    )

    $temporaryPath = "$Path.$PID.tmp"
    try {
        $json = $Record | ConvertTo-Json -Depth 10 -Compress -ErrorAction Stop
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    [IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
                }
                else {
                    [IO.File]::Move($temporaryPath, $Path)
                }
                break
            }
            catch [IO.IOException] {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Invoke-MemLabsBoundedPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ProbeScript,
        [hashtable]$Variables = @{},
        [hashtable]$Parameters = @{},
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 60,
        [string]$ProgressPath,
        [string]$ProgressId,
        [ValidateRange(0, 7200)][int]$StallTimeoutSeconds = 0,
        [ValidateRange(1, 600)][int]$ProgressIntervalSeconds = 30,
        [scriptblock]$OnProgress
    )

    $result = [pscustomobject]@{
        Output = $null; Error = ''; TimedOut = $false; Stalled = $false
        ProcessId = $null; ElapsedSeconds = 0; Progress = $null
    }
    $probeRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-worker-$([guid]::NewGuid().ToString('N'))"
    $process = $null
    $jobHandle = [IntPtr]::Zero
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Initialize-MemLabsJobObjectType
        $jobHandle = [MemLabs.NativeJob]::CreateJobObject([IntPtr]::Zero, $null)
        if ($jobHandle -eq [IntPtr]::Zero) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $info = New-Object MemLabs.NativeJob+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        $limits = New-Object MemLabs.NativeJob+JOBOBJECT_BASIC_LIMIT_INFORMATION
        $limits.LimitFlags = [MemLabs.NativeJob]::JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        $info.BasicLimitInformation = $limits
        $size = [Runtime.InteropServices.Marshal]::SizeOf($info)
        if (-not [MemLabs.NativeJob]::SetInformationJobObject($jobHandle, 9, [ref]$info, $size)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $null = New-Item -Path $probeRoot -ItemType Directory -ErrorAction Stop
        $inputPath = Join-Path $probeRoot 'input.clixml'
        $outputPath = Join-Path $probeRoot 'output.clixml'
        $readyPath = Join-Path $probeRoot 'ready'
        $stdoutPath = Join-Path $probeRoot 'stdout.txt'
        $stderrPath = Join-Path $probeRoot 'stderr.txt'
        @{ Script = $ProbeScript.ToString(); Variables = $Variables; Parameters = $Parameters } |
            Export-Clixml -LiteralPath $inputPath -Depth 40 -ErrorAction Stop
        $childCommand = @"
`$ErrorActionPreference = 'Stop'
try {
    `$readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists('$($readyPath.Replace("'", "''"))')) {
        if ([DateTime]::UtcNow -ge `$readyDeadline) { throw 'Worker ownership handshake timed out.' }
        Start-Sleep -Milliseconds 50
    }
    `$payload = Import-Clixml -LiteralPath '$($inputPath.Replace("'", "''"))'
    foreach (`$entry in `$payload.Variables.GetEnumerator()) {
        Set-Variable -Name `$entry.Key -Value `$entry.Value
    }
    `$probe = [scriptblock]::Create(`$payload.Script)
    `$probeParameters = `$payload.Parameters
    `$value = & `$probe @probeParameters
    [pscustomobject]@{ Output = `$value; Error = '' } |
        Export-Clixml -LiteralPath '$($outputPath.Replace("'", "''"))' -Depth 40
}
catch {
    [pscustomobject]@{ Output = `$null; Error = "`$(`$_.Exception.Message); stack=`$(`$_.ScriptStackTrace)" } |
        Export-Clixml -LiteralPath '$($outputPath.Replace("'", "''"))' -Depth 40
    exit 1
}
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
        $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $process = Start-Process -FilePath (Join-Path $PSHOME $engineName) `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand) `
            -WorkingDirectory $probeRoot -WindowStyle Hidden -PassThru -ErrorAction Stop `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $null = $process.Handle
        $result.ProcessId = $process.Id
        if (-not [MemLabs.NativeJob]::AssignProcessToJobObject($jobHandle, $process.Handle)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        [IO.File]::WriteAllText($readyPath, 'owned')
        $lastReportSeconds = -$ProgressIntervalSeconds
        $lastHeartbeat = ''
        $lastHeartbeatSeconds = $clock.Elapsed.TotalSeconds
        $progressReadFailures = 0
        while (-not $process.WaitForExit(100)) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $result.TimedOut = $true
                $result.Error = "Worker exceeded the ${TimeoutSeconds}-second wall-clock limit (PID $($process.Id))."
                break
            }
            if ($ProgressPath -and [IO.File]::Exists($ProgressPath)) {
                try {
                    $record = [IO.File]::ReadAllText($ProgressPath) | ConvertFrom-Json -ErrorAction Stop
                    if ($record.Id -eq $ProgressId) {
                        $result.Progress = $record
                        $heartbeat = "$($record.UpdatedAtUtc)"
                        if ($heartbeat -ne $lastHeartbeat) {
                            $lastHeartbeat = $heartbeat
                            $lastHeartbeatSeconds = $clock.Elapsed.TotalSeconds
                        }
                        if ($record.DeadlineUtc -and
                            [DateTime]::UtcNow -ge ([datetime]$record.DeadlineUtc).ToUniversalTime()) {
                            $result.TimedOut = $true
                            $result.Error = "Coverage stage '$($record.Stage)' exceeded its wall-clock deadline; last checkpoint: $($record.Message)"
                            break
                        }
                    }
                    $progressReadFailures = 0
                }
                catch [IO.IOException] {
                    $progressReadFailures++
                    if ($progressReadFailures -ge 3) { throw }
                }
            }
            $idleSeconds = $clock.Elapsed.TotalSeconds - $lastHeartbeatSeconds
            if ($StallTimeoutSeconds -gt 0 -and $idleSeconds -ge $StallTimeoutSeconds) {
                $result.TimedOut = $true
                $result.Stalled = $true
                $result.Error = "Worker reported no checkpoint for ${StallTimeoutSeconds}s; last checkpoint: $($result.Progress.Message)"
                break
            }
            if ($OnProgress -and $clock.Elapsed.TotalSeconds - $lastReportSeconds -ge $ProgressIntervalSeconds) {
                $lastReportSeconds = $clock.Elapsed.TotalSeconds
                $null = & $OnProgress ([pscustomobject]@{
                    ProcessId = $process.Id
                    ElapsedSeconds = [math]::Round($clock.Elapsed.TotalSeconds)
                    IdleSeconds = [math]::Round($idleSeconds)
                    Progress = $result.Progress
                })
            }
        }
        if (-not $result.TimedOut) {
            $process.Refresh()
            if ($null -eq $process.ExitCode) { throw 'Worker did not report an exit code.' }
            if (-not [IO.File]::Exists($outputPath)) {
                $stderr = [IO.File]::ReadAllText($stderrPath).Trim()
                throw "Worker exited with code $($process.ExitCode) without a result: $stderr"
            }
            $probeResult = Import-Clixml -LiteralPath $outputPath -ErrorAction Stop
            if ($process.ExitCode -ne 0 -or $probeResult.Error) {
                throw "Worker exited with code $($process.ExitCode): $($probeResult.Error)"
            }
            $result.Output = $probeResult.Output
        }
    }
    catch { $result.Error = $_.Exception.Message }
    finally {
        if ($process -and -not $process.HasExited) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
            catch { $result.Error = "$($result.Error) Worker cancellation failed: $($_.Exception.Message)".Trim() }
        }
        if ($jobHandle -ne [IntPtr]::Zero) {
            if (-not [MemLabs.NativeJob]::CloseHandle($jobHandle)) {
                $result.Error = "$($result.Error) Worker Job Object cleanup failed.".Trim()
            }
        }
        if ($process) {
            if (-not $process.WaitForExit(2000)) {
                $result.Error = "$($result.Error) Worker did not terminate after cancellation.".Trim()
            }
            $process.Dispose()
        }
        try {
            if ([IO.Directory]::Exists($probeRoot)) {
                Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction Stop
            }
        }
        catch { $result.Error = "$($result.Error) Worker file cleanup failed: $($_.Exception.Message)".Trim() }
        if ($result.Error) { $result.Output = $null }
        $clock.Stop()
        $result.ElapsedSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 2)
    }
    return $result
}
