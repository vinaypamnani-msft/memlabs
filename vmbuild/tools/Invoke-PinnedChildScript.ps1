[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ScriptPath,

    [Parameter(Mandatory = $true)]
    [string] $ParameterPath,

    [string] $PidPath,

    [string] $InvocationToken
)

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Child script not found: $ScriptPath"
}
if (-not (Test-Path -LiteralPath $ParameterPath -PathType Leaf)) {
    throw "Child parameter file not found: $ParameterPath"
}

$parameters = Import-Clixml -LiteralPath $ParameterPath -ErrorAction Stop
if ($parameters -isnot [Collections.IDictionary]) {
    throw "Child parameter payload must be a dictionary: $ParameterPath"
}

if (-not ('MemLabsCrossRevisionJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class MemLabsCrossRevisionJob
{
    private static ConsoleCancelEventHandler cancelHandler;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int infoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info,
        uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    public static IntPtr CreateKillOnCloseForCurrentProcess()
    {
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        const int JobObjectExtendedLimitInformation = 9;

        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");

        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, (uint)Marshal.SizeOf(info)))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject failed");
        if (!AssignProcessToJobObject(job, GetCurrentProcess()))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed");

        return job;
    }

    public static void InstallImmediateCancelExit()
    {
        if (cancelHandler != null)
            return;

        cancelHandler = delegate(object sender, ConsoleCancelEventArgs args)
        {
            args.Cancel = true;
            Environment.Exit(130);
        };
        Console.CancelKeyPress += cancelHandler;
    }
}
'@
}

$script:CrossRevisionJobHandle = [MemLabsCrossRevisionJob]::CreateKillOnCloseForCurrentProcess()
[MemLabsCrossRevisionJob]::InstallImmediateCancelExit()

if ($PidPath) {
    $identity = [ordered]@{
        ProcessId      = $PID
        StartTimeUtc   = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
        InvocationToken = $InvocationToken
    }
    [IO.File]::WriteAllText($PidPath, ($identity | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

$global:LASTEXITCODE = 0
& $ScriptPath @parameters
exit [int]$LASTEXITCODE
