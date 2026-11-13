function Get-MemLabsFirstLogonDumpGuestBlock {
    $privateDirectory = (Get-Command New-MemLabsPrivateDiagnosticDirectory -CommandType Function -ErrorAction Stop).Definition
    $capture = {
        param([ValidatePattern('^[a-f0-9]{32}$')][string]$Token, [ValidateRange(1, 120)][int]$CaptureTimeoutSeconds = 120)
        $ErrorActionPreference = 'Stop'
        $report = [ordered]@{
            Version = 1; Scope = 'FirstLogonAnimHangDump'; Status = 'Failed'; Token = $Token
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o'); MachineGuid = $null
            ProcessId = 0; ProcessStartUtc = $null; GuestRelativePath = $null
            GuestRelativeDirectory = $null
            Bytes = 0L; Sha256 = $null; WriterExited = $true; Error = $null
            GuestArtifactRetained = $false; CleanupErrors = @()
        }
        $ownedFiles = [Collections.Generic.List[string]]::new()
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        $writer = $null; $directory = $null; $directoryCreated = $false; $dumpPath = $null
        try {
            if (-not [Environment]::Is64BitProcess) { throw 'FirstLogonAnim dump capture requires 64-bit guest PowerShell.' }
            $systems = @(Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop)
            if ($systems.Count -ne 1 -or $systems[0].ProductType -ne 1) { throw 'Hang capture supports Windows clients only.' }
            $report.MachineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
            $targets = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='FirstLogonAnim.exe'" -OperationTimeoutSec 10 -ErrorAction Stop)
            if ($targets.Count -eq 0) {
                $report.Status = 'Unavailable'; $report.Error = 'FirstLogonAnim.exe is not running; no replacement process will be dumped.'
                return [pscustomobject]$report
            }
            $expectedImage = Join-Path $env:SystemRoot 'System32\oobe\FirstLogonAnim.exe'
            if ($targets.Count -ne 1 -or $targets[0].Name -ine 'FirstLogonAnim.exe' -or
                $targets[0].ExecutablePath -ine $expectedImage -or $targets[0].SessionId -lt 1) {
                throw 'No unique interactive-session FirstLogonAnim process at the expected Windows path was verified.'
            }
            $target = Get-Process -Id $targets[0].ProcessId -ErrorAction Stop
            try {
                $report.ProcessId = $target.Id
                $start = $target.StartTime.ToUniversalTime()
                $report.ProcessStartUtc = $start.ToString('o')
                $startTicks = $start.Ticks
            }
            finally { $target.Dispose() }
            $programData = Join-Path $env:SystemDrive 'ProgramData'
            if ([IO.File]::GetAttributes($programData) -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing a redirected guest ProgramData directory.' }
            $relativeDirectory = "ProgramData\MemLabsSetupDiagnostics-$Token"
            $report.GuestRelativeDirectory = $relativeDirectory
            $directory = Join-Path $env:SystemDrive $relativeDirectory
            New-MemLabsPrivateDiagnosticDirectory -Path $directory
            $directoryCreated = $true
            $dumpPath = Join-Path $directory "FirstLogonAnim-$($report.ProcessId).dmp"
            $writerPath = Join-Path $directory 'Write-FirstLogonDump.ps1'
            $stdoutPath = Join-Path $directory 'writer.stdout'
            $stderrPath = Join-Path $directory 'writer.stderr'
            foreach ($file in @($writerPath, $stdoutPath, $stderrPath)) { $ownedFiles.Add($file) }
            $writerSource = @'
param([int]$ProcessId, [long]$StartTicks, [string]$DumpPath, [ValidateRange(1,120)][int]$CaptureSeconds)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;
namespace MemLabs {
    public static class FirstLogonDumpNative {
        [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] private struct Privilege { public uint Count; public Luid Luid; public uint Attributes; }
        [DllImport("kernel32.dll", ExactSpelling=true)] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", ExactSpelling=true)] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError=true, ExactSpelling=true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        private static extern bool LookupPrivilegeValueW(string system, string name, out Luid luid);
        [DllImport("advapi32.dll", SetLastError=true, ExactSpelling=true)]
        private static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref Privilege state, uint size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)]
        private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        private static extern bool QueryFullProcessImageNameW(SafeProcessHandle process, uint flags, StringBuilder name, ref uint size);
        [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)]
        private static extern bool GetProcessTimes(SafeProcessHandle process, out long created, out long exited, out long kernel, out long user);
        [DllImport("dbghelp.dll", SetLastError=true, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern bool MiniDumpWriteDump(SafeProcessHandle process, uint id, SafeFileHandle file, uint flags, IntPtr exception, IntPtr streams, IntPtr callback);
        public static void WriteWithTimeout(int id, long expectedStart, string path, int seconds) {
            if (seconds < 1 || seconds > 120) throw new ArgumentOutOfRangeException("seconds");
            using (Timer watchdog = new Timer(state => Environment.Exit(124), null, seconds * 1000, Timeout.Infinite)) {
                WriteCore(id, expectedStart, path);
            }
        }
        private static void WriteCore(int id, long expectedStart, string path) {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                Luid luid;
                if (!LookupPrivilegeValueW(null, "SeDebugPrivilege", out luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
                Privilege state = new Privilege { Count = 1, Luid = luid, Attributes = 2 };
                if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
                int error = Marshal.GetLastWin32Error();
                if (error != 0) throw new Win32Exception(error);
            }
            finally { CloseHandle(token); }
            using (SafeProcessHandle process = OpenProcess(0x450, false, id)) {
                if (process.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                StringBuilder image = new StringBuilder(32768); uint length = (uint)image.Capacity;
                if (!QueryFullProcessImageNameW(process, 0, image, ref length)) throw new Win32Exception(Marshal.GetLastWin32Error());
                string expectedImage = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\oobe\FirstLogonAnim.exe");
                if (!String.Equals(image.ToString(), expectedImage, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("The dump handle is not FirstLogonAnim at the expected Windows path.");
                long created, exited, kernel, user;
                if (!GetProcessTimes(process, out created, out exited, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (DateTime.FromFileTimeUtc(created).Ticks != expectedStart) throw new InvalidOperationException("FirstLogonAnim exited or its PID was reused before capture.");
                using (FileStream file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    // Full memory plus handles, unloaded modules, and thread metadata expose the wait context.
                    if (!MiniDumpWriteDump(process, (uint)id, file.SafeFileHandle, 0x1026, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
        }
    }
}
"@ -ErrorAction Stop
try { [MemLabs.FirstLogonDumpNative]::WriteWithTimeout($ProcessId, $StartTicks, $DumpPath, $CaptureSeconds); exit 0 }
catch { [Console]::Error.WriteLine($_.Exception.ToString()); exit 1 }
'@
            [IO.File]::WriteAllText($writerPath, $writerSource, [Text.UTF8Encoding]::new($true))
            $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$writerPath`" -ProcessId $($report.ProcessId) -StartTicks $startTicks -DumpPath `"$dumpPath`" -CaptureSeconds $CaptureTimeoutSeconds"
            Write-Host "Capturing only FirstLogonAnim PID $($report.ProcessId); ${CaptureTimeoutSeconds}s limit."
            $report.WriterExited = $false
            $writer = Start-Process -FilePath $executable -ArgumentList $arguments -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
            if (-not $writer.WaitForExit($CaptureTimeoutSeconds * 1000)) {
                if (-not $writer.HasExited) {
                    try { Stop-Process -Id $writer.Id -Force -ErrorAction Stop }
                    catch { if (-not $writer.HasExited) { throw } }
                }
                if (-not $writer.WaitForExit(5000)) { throw 'The owned dump writer could not be confirmed stopped.' }
                $report.WriterExited = $true
                throw "FirstLogon dump capture exceeded ${CaptureTimeoutSeconds}s; only the owned writer was stopped."
            }
            $report.WriterExited = $true
            if ($writer.ExitCode -ne 0) {
                $detail = if ([IO.File]::Exists($stderrPath)) { Get-Content -LiteralPath $stderrPath -TotalCount 12 -ErrorAction Stop | Out-String } else { '' }
                if ($detail.Length -gt 8192) { $detail = $detail.Substring(0, 8192) }
                throw "FirstLogon dump writer exited $($writer.ExitCode): $detail"
            }
            $stream = [IO.File]::OpenRead($dumpPath)
            try {
                if ($stream.Length -lt 32 -or $stream.Length -gt 512MB) { throw 'The captured dump is empty, incomplete, or exceeds 512 MiB.' }
                $header = [byte[]]::new(4)
                if ($stream.Read($header, 0, 4) -ne 4 -or [BitConverter]::ToUInt32($header, 0) -ne 0x504D444D) { throw 'The captured file has no MDMP header.' }
                $report.Bytes = $stream.Length
            }
            finally { $stream.Dispose() }
            $report.GuestRelativePath = "$relativeDirectory\FirstLogonAnim-$($report.ProcessId).dmp"
            $report.Sha256 = (Get-FileHash -LiteralPath $dumpPath -Algorithm SHA256 -ErrorAction Stop).Hash
            $report.GuestArtifactRetained = $true
            $report.Status = 'Captured'
        }
        catch {
            $report.Error = $_.Exception.Message
            $report.Status = if ($report.WriterExited) { 'Failed' } else { 'Indeterminate' }
        }
        finally {
            if ($report.WriterExited) {
                foreach ($file in $ownedFiles) {
                    try { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
                    catch { $cleanupErrors.Add("Owned writer-file cleanup '$file': $($_.Exception.Message)") }
                }
                if ($directoryCreated -and $report.Status -ne 'Captured') {
                    try {
                        if ($dumpPath -and [IO.File]::Exists($dumpPath)) { [IO.File]::Delete($dumpPath) }
                        if (@([IO.Directory]::EnumerateFileSystemEntries($directory)).Count -eq 0) { [IO.Directory]::Delete($directory) }
                    }
                    catch { $cleanupErrors.Add("Owned failed-capture cleanup '$directory': $($_.Exception.Message)") }
                }
            }
            if ($writer) { $writer.Dispose() }
            $report.CleanupErrors = $cleanupErrors.ToArray()
        }
        [pscustomobject]$report
    }
    return [scriptblock]::Create("param(`$Token)`nfunction New-MemLabsPrivateDiagnosticDirectory {$privateDirectory}`n& {$($capture.ToString())} -Token `$Token")
}

function Invoke-MemLabsFirstLogonHangDump {
    param($VM, [pscredential]$GuestCredential, [scriptblock]$GuestBlock, $Manifest,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 180)
    $live = Get-VM -Id $VM.Id -ErrorAction Stop
    if ($live.Name -ne $VM.Name -or "$($live.State)" -ne 'Running') { throw 'Hang-dump capture requires the exact selected VM to remain Running.' }
    $token = $Manifest.HangDump.Token
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $job = Invoke-Command -VMId $VM.Id -Credential $GuestCredential -AsJob -ScriptBlock $GuestBlock -ArgumentList @($token) -ErrorAction Stop
        $results = @(Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds $TimeoutSeconds -Operation 'FirstLogonAnim hang-dump capture')
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "FirstLogon dump result arrived after its ${TimeoutSeconds}s deadline." }
        if ($results.Count -ne 1 -or $results[0].Version -isnot [int] -or $results[0].Version -ne 1 -or
            $results[0].Scope -ne 'FirstLogonAnimHangDump' -or $results[0].Token -cne $token -or
            $results[0].WriterExited -isnot [bool] -or
            $results[0].Status -notin @('Captured', 'Unavailable', 'Failed', 'Indeterminate')) { throw 'Invalid FirstLogon dump result envelope.' }
        $result = $results[0]
        $machineGuid = [guid]::Empty
        if (-not [guid]::TryParse($result.MachineGuid, [ref]$machineGuid) -or $machineGuid -eq [guid]::Empty) {
            throw 'The dump receipt has no valid guest machine identity.'
        }
        if (-not $result.WriterExited -or $result.Status -eq 'Indeterminate') { throw 'The guest dump writer has an unverified outcome.' }
        if ($result.Status -eq 'Captured') {
            $expected = "ProgramData\MemLabsSetupDiagnostics-$token\FirstLogonAnim-$($result.ProcessId).dmp"
            if (($result.ProcessId -isnot [int] -and $result.ProcessId -isnot [uint32]) -or $result.ProcessId -le 0 -or
                $result.GuestRelativePath -cne $expected -or $result.Bytes -lt 32 -or $result.Bytes -gt 512MB -or
                $result.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid captured dump path, identity, length, or digest.' }
        }
        $Manifest.HangDump['Capture'] = $result
        $Manifest.HangDump.Status = $result.Status
        foreach ($message in $result.CleanupErrors) { $Manifest.Errors.Add($message) }
        if ($result.Status -ne 'Captured') { $Manifest.Errors.Add("Requested FirstLogon dump was not captured: $($result.Error)") }
    }
    catch {
        $Manifest.HangDump.Status = 'Indeterminate'; $Manifest.HangDump.Error = $_.Exception.Message
        $_.Exception.Data['FirstLogonDumpPreserveRunning'] = $true
        throw
    }
}

function Copy-MemLabsOfflineFirstLogonDump {
    param([string]$WindowsRoot, [string]$Bundle, $Manifest)
    if (-not $Manifest.HangDump -or $Manifest.HangDump.Status -ne 'Captured') { return }
    $capture = $Manifest.HangDump.Capture
    $volumeRoot = [IO.DirectoryInfo]::new($WindowsRoot).Parent.FullName
    $source = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $capture.GuestRelativePath
    if (-not $source) { throw 'The captured FirstLogon dump is absent from the selected Windows volume.' }
    $path = 'FirstLogonAnim.dmp'
    $destination = Join-Path $Bundle $path
    $copied = $false
    try {
        $bytes = Copy-MemLabsBoundedDiagnosticFile -Source $source -Destination $destination -MaxBytes 512MB `
            -MaxTotalBytes 512MB -Budget @{ Bytes = 0L }
        $copied = $true
        if ($bytes -ne $capture.Bytes -or
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash -ine $capture.Sha256) {
            throw 'The offline FirstLogon dump does not match the live capture length/digest.'
        }
        $Manifest.Files.Add([ordered]@{ Path = $path; Kind = 'FirstLogonHangDump'; SourceBytes = $bytes; Truncated = $false })
        $Manifest.HangDump.Status = 'CopiedAndVerified'; $Manifest.HangDump['Path'] = $path
    }
    catch { if ($copied) { [IO.File]::Delete($destination) }; throw }
}
