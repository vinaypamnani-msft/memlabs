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
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll")]
        public static extern bool SetInformationJobObject(
            IntPtr job, int infoClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, UInt32 length);
        [DllImport("kernel32.dll")]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

function Invoke-MemLabsAttachedPowerShell {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    if ($env:OS -ne 'Windows_NT') {
        $global:LASTEXITCODE = 0
        & (Join-Path $PSHOME 'pwsh.exe') @Arguments | Out-Host
        return [int]$LASTEXITCODE
    }
    Initialize-MemLabsJobObjectType
    $jobHandle = [MemLabs.NativeJob]::CreateJobObject([IntPtr]::Zero, $null)
    if ($jobHandle -eq [IntPtr]::Zero) { throw 'CreateJobObject failed for attached PowerShell child.' }
    $process = $null
    try {
        $info = New-Object MemLabs.NativeJob+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        $info.BasicLimitInformation.LimitFlags = [MemLabs.NativeJob]::JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        $size = [Runtime.InteropServices.Marshal]::SizeOf($info)
        if (-not [MemLabs.NativeJob]::SetInformationJobObject($jobHandle, 9, [ref]$info, $size)) {
            throw 'SetInformationJobObject failed for attached PowerShell child.'
        }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
        $startInfo.UseShellExecute = $false
        foreach ($argument in $Arguments) { $null = $startInfo.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($startInfo)
        if (-not $process) { throw 'Could not start attached PowerShell child.' }
        $null = $process.Handle
        if (-not [MemLabs.NativeJob]::AssignProcessToJobObject($jobHandle, $process.Handle)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "AssignProcessToJobObject failed for attached PowerShell PID $($process.Id)."
        }
        while (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
        return [int]$process.ExitCode
    }
    finally {
        if ($process) {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            $process.Dispose()
        }
        $null = [MemLabs.NativeJob]::CloseHandle($jobHandle)
    }
}
