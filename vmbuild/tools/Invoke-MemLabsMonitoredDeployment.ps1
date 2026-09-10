<#
.SYNOPSIS
    Runs New-Lab under the Live Ops lease with semantic progress monitoring.

.DESCRIPTION
    New-Lab runs in a child process assigned to a Windows kill-on-close Job
    Object. The monitor polls the structured domain log and resets its clock
    only for a new phase, DSC status, completion, validation result, or error.
#>
#requires -Version 7.4
[CmdletBinding()]
param (
    [string] $Configuration,
    [int] $StartPhase = 0,
    [int[]] $Phase,
    [ValidateRange(2, 11)]
    [int] $StopPhase = 0,
    [ValidateRange(1, 1440)]
    [int] $NoProgressMinutes = 45,
    [ValidateRange(10, 3600)]
    [int] $PollSeconds = 60,
    [ValidateRange(1, 168)]
    [int] $MaxHours = 12,
    [ValidateRange(1, 11)]
    [int] $ExpectedCompletedPhase = 11,
    [switch] $KeepFailedVMs
)

$ErrorActionPreference = 'Stop'

if (-not ('MemLabsNativeJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class MemLabsNativeJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation {
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
    private struct IoCounters {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimitInformation info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateKillOnClose() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        ExtendedLimitInformation info = new ExtendedLimitInformation();
        info.BasicLimitInformation.LimitFlags = 0x00002000;
        if (!SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf(info))) {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error);
        }
        return job;
    }
    public static void Assign(IntPtr job, IntPtr process) {
        if (!AssignProcessToJobObject(job, process)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
}

function Get-MemLabsDeploymentProgressRecords {
    param (
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][datetime] $SinceUtc
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    $records = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        try { $record = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        try {
            if ($record.t -is [datetime]) { $time = ([datetime]$record.t).ToUniversalTime() }
            else { $time = [datetimeoffset]::Parse([string]$record.t).UtcDateTime }
        }
        catch { continue }
        if ($time -lt $SinceUtc.ToUniversalTime()) { continue }

        $message = [string]$record.msg
        $signature = $null
        if ($message -match '^### START DEPLOYMENT') { $signature = 'deployment-start' }
        elseif ($message -match '^Phase (?<Phase>\d+) - ') { $signature = "phase-start|$($Matches.Phase)" }
        elseif ($message -match '^\[Phase (?<Phase>\d+)\] Jobs completed;') { $signature = "phase-complete|$($Matches.Phase)|$message" }
        elseif ($message -match '^\[Phase (?<Phase>\d+)\]: (?<VM>[^:]+): DSC: Current Status for [^:]+: (?<Status>.+)$') {
            $signature = "dsc-status|$($Matches.Phase)|$($Matches.VM)|$($Matches.Status.Trim())"
        }
        elseif ($message -match 'Functional validation (?:PASSED|FAILED)') { $signature = "validation|$message" }
        elseif ($message -match '^### SCRIPT FINISHED') { $signature = 'deployment-finished' }
        elseif ($message -match 'JOBFAILURE:| Exception:|^ERROR:') { $signature = "terminal|$message" }
        if (-not $signature) { continue }

        $records.Add([pscustomobject]@{ TimeUtc = $time; Signature = $signature; Message = $message })
    }
    return @($records)
}

function New-MemLabsDeploymentProcess {
    param ([Parameter(Mandatory)][string] $LauncherPath, [Parameter(Mandatory)][hashtable] $Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.ArgumentList.Add('-NoProfile')
    $info.ArgumentList.Add('-File')
    $info.ArgumentList.Add($LauncherPath)
    foreach ($entry in $Arguments.GetEnumerator()) {
        if ($entry.Value -is [bool]) {
            if ($entry.Value) { $info.ArgumentList.Add("-$($entry.Key)") }
            continue
        }
        foreach ($value in @($entry.Value)) {
            $info.ArgumentList.Add("-$($entry.Key)")
            $info.ArgumentList.Add([string]$value)
        }
    }
    return [Diagnostics.Process]::Start($info)
}

function Add-MemLabsDeploymentProcessToJob {
    param (
        [Parameter(Mandatory)][IntPtr] $JobHandle,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [switch] $TestAssignmentFailure
    )

    try {
        if ($TestAssignmentFailure) { throw 'Injected job-assignment failure.' }
        [MemLabsNativeJob]::Assign($JobHandle, $Process.Handle)
    }
    catch {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            if (-not $Process.WaitForExit(30000)) {
                throw 'Deployment job assignment failed and the unowned child did not exit within 30 seconds.'
            }
        }
        throw
    }
}

function Resolve-MemLabsConfigurationPath {
    param (
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $BasePath
    )

    if ([IO.Path]::IsPathFullyQualified($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Resolve-MemLabsExpectedCompletedPhase {
    param(
        [int[]] $Phase,
        [int] $StopPhase,
        [int] $ExpectedCompletedPhase,
        [bool] $ExpectedPhaseWasBound
    )

    if ($ExpectedPhaseWasBound) { return $ExpectedCompletedPhase }
    if ($Phase) { return [int](($Phase | Measure-Object -Maximum).Maximum) }
    if ($StopPhase) { return $StopPhase }
    return $ExpectedCompletedPhase
}

function Save-MemLabsDeploymentFailure {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Stage,
        [AllowEmptyString()][string] $ErrorMessage = '',
        [AllowEmptyString()][string] $OperationId = '',
        [AllowEmptyString()][string] $JournalPath = '',
        [AllowNull()][object] $ActiveOwnerMetadata,
        [AllowNull()][object[]] $FailureDiagnostics,
        [AllowNull()][object] $Process,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $MonitorPath,
        [Parameter(Mandatory)][string] $DiagnosticsPath,
        [AllowEmptyString()][string] $CrashSourcePath = '',
        [AllowEmptyString()][string] $CrashExportPath = ''
    )

    $exitCode = $null
    if ($Process -and $Process.HasExited) { $exitCode = $Process.ExitCode }
    $outputTail = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        @(Get-Content -LiteralPath $OutputPath -Tail 120 -ErrorAction SilentlyContinue)
    }
    else { @() }
    $crashText = ''
    $crashCaptureError = ''
    $crashExportSucceeded = $false
    if ($CrashSourcePath -and (Test-Path -LiteralPath $CrashSourcePath -PathType Leaf)) {
        try {
            $crashItem = Get-Item -LiteralPath $CrashSourcePath -ErrorAction Stop
            $crashOutsideLifetime = $Process -and (
                $crashItem.LastWriteTimeUtc -lt $Process.StartTime.ToUniversalTime() -or
                ($Process.HasExited -and $crashItem.LastWriteTimeUtc -gt $Process.ExitTime.ToUniversalTime().AddSeconds(2))
            )
            if ($crashOutsideLifetime) {
                $crashCaptureError = "Ignored crash file outside child lifetime: $CrashSourcePath"
            }
            else {
                $crashText = Get-Content -LiteralPath $CrashSourcePath -Raw -ErrorAction Stop
                if ($CrashExportPath) {
                    $crashTempPath = "$CrashExportPath.$([guid]::NewGuid().ToString('N')).tmp"
                    try {
                        Set-Content -LiteralPath $crashTempPath -Value $crashText -Encoding UTF8 -ErrorAction Stop
                        Move-Item -LiteralPath $crashTempPath -Destination $CrashExportPath -Force -ErrorAction Stop
                        $crashExportSucceeded = $true
                    }
                    finally { Remove-Item -LiteralPath $crashTempPath -Force -ErrorAction SilentlyContinue }
                }
            }
        }
        catch { $crashCaptureError = $_.Exception.Message }
    }

    $failureRecord = [pscustomobject]@{
        CapturedUtc = [datetime]::UtcNow.ToString('o')
        Stage       = $Stage
        Error       = $ErrorMessage
        OperationId = $OperationId
        Journal     = $JournalPath
        ActiveOwner = $ActiveOwnerMetadata
        FailureDiagnostics = @($FailureDiagnostics)
        ProcessId   = if ($Process) { $Process.Id } else { $null }
        ExitCode    = $exitCode
        Output      = $OutputPath
        OutputTail  = @($outputTail)
        Monitor     = $MonitorPath
        Diagnostics = $DiagnosticsPath
        CrashSource = $CrashSourcePath
        CrashExport = if ($crashExportSucceeded) { $CrashExportPath } else { '' }
        Crash       = $crashText
        CrashCaptureError = $crashCaptureError
    }
    $failureTempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $failureRecord | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $failureTempPath -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $failureTempPath -Destination $Path -Force -ErrorAction Stop
    }
    finally { Remove-Item -LiteralPath $failureTempPath -Force -ErrorAction SilentlyContinue }
}

function New-MemLabsDeploymentStamp {
    return '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Save-MemLabsDeploymentDiagnostics {
    param (
        [Parameter(Mandatory)][string[]] $VMName,
        [Parameter(Mandatory)][string] $DomainName,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Reason
    )

    $guestDiagnostics = foreach ($name in $VMName) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { continue }
        $guest = $null
        try {
            $result = Invoke-VmCommand -VmName $name -VmDomainName $DomainName -AsJob -TimeoutSeconds 90 -SuppressLog -ScriptBlock {
                $latest = @(Get-ChildItem 'C:\Windows\System32\Configuration\ConfigurationStatus' -Filter '*.details.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
                        [pscustomobject]@{ Name = $_.Name; LastWriteTime = $_.LastWriteTime; Raw = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue }
                    })
                $lcm = Get-DscLocalConfigurationManager -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    LCMState       = [string]$lcm.LCMState
                    LCMStateDetail = [string]$lcm.LCMStateDetail
                    PendingMof     = Test-Path 'C:\Windows\System32\Configuration\pending.mof'
                    StatusText     = Get-Content 'C:\staging\DSC\DSC_Status.txt' -Raw -ErrorAction SilentlyContinue
                    Details        = $latest
                }
            }
            if ($result -and -not $result.ScriptBlockFailed) { $guest = $result.ScriptBlockOutput | Select-Object -First 1 }
            else { $guest = [pscustomobject]@{ Error = [string]$result.ScriptBlockOutput } }
        }
        catch { $guest = [pscustomobject]@{ Error = $_.Exception.Message } }

        [pscustomobject]@{
            VMName    = $name
            Id        = [string]$vm.Id
            State     = [string]$vm.State
            Status    = [string]$vm.Status
            Heartbeat = [string]$vm.Heartbeat
            Notes     = [string]$vm.Notes
            Guest     = $guest
        }
    }

    [pscustomobject]@{
        CapturedUtc = [datetime]::UtcNow.ToString('o')
        Reason      = $Reason
        Guests      = @($guestDiagnostics)
        FatalEvents = @(Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-Hyper-V-Worker-Admin'
                Id = 18560, 18590, 18602
                StartTime = (Get-Date).AddHours(-12)
            } -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, Message)
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ([string]::IsNullOrWhiteSpace($Configuration)) { throw '-Configuration is required.' }
if ($StartPhase -and $Phase) { throw 'Specify either -StartPhase or -Phase, not both.' }
if ($StopPhase -and ($StartPhase -or $Phase)) { throw 'Specify -StopPhase only for a fresh sequential deployment.' }
$ExpectedCompletedPhase = Resolve-MemLabsExpectedCompletedPhase -Phase $Phase -StopPhase $StopPhase `
    -ExpectedCompletedPhase $ExpectedCompletedPhase -ExpectedPhaseWasBound $PSBoundParameters.ContainsKey('ExpectedCompletedPhase')

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
$configurationPath = Resolve-MemLabsConfigurationPath -Path $Configuration -BasePath (Get-Location).ProviderPath
if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { throw "Configuration not found: $configurationPath" }
$config = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json -ErrorAction Stop
$domainName = [string]$config.vmOptions.domainName
$prefix = [string]$config.vmOptions.prefix
$vmNames = @($config.virtualMachines | Where-Object { -not $_.hidden } | ForEach-Object { "$prefix$($_.vmName)" })
$diagnosticVmNames = @($config.virtualMachines | ForEach-Object { "$prefix$($_.vmName)" } | Sort-Object -Unique)
if (-not $domainName -or $vmNames.Count -eq 0) { throw 'Configuration must define a domain and at least one visible VM.' }

$stamp = New-MemLabsDeploymentStamp
$domainLogPath = Join-Path $vmbuildRoot "logs\VMBuild.$domainName.jsonl"
$monitorLogPath = Join-Path $vmbuildRoot "logs\MonitoredDeployment-$stamp.jsonl"
$outputPath = Join-Path $vmbuildRoot "logs\MonitoredDeployment-$stamp.out.txt"
$diagnosticsPath = Join-Path $vmbuildRoot "logs\MonitoredDeployment-$stamp.diagnostics.json"
$failurePath = Join-Path $vmbuildRoot "logs\MonitoredDeployment-$stamp.failure.json"
$childCrashPath = Join-Path $vmbuildRoot "logs\MonitoredDeployment-$stamp.child-crash.log"
$crashExportPath = Join-Path $vmbuildRoot "logs\MonitoredDeployment-$stamp.crash.txt"
$launcherPath = Join-Path $PSScriptRoot 'Invoke-MemLabsDeploymentChild.ps1'
$liveOpsPath = Join-Path $PSScriptRoot 'Invoke-MemLabsLiveOperation.ps1'

Set-Location $vmbuildRoot
. (Join-Path $vmbuildRoot 'Common.ps1') -SkipMaintenanceRefresh -SkipVmCacheRefresh -SkipEnvironmentDetection -SkipHostPreparation
if (-not (Get-LocalAdminCredential)) { throw 'Local administrator credential initialization failed.' }

$operation = {
    $startedUtc = [datetime]::UtcNow
    $deadlineUtc = $startedUtc.AddHours($MaxHours)
    $lastProgressUtc = $startedUtc
    $lastSignature = ''
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $arguments = @{ Configuration = $configurationPath; OutputPath = $outputPath; CrashPath = $childCrashPath }
    if ($StartPhase) { $arguments.StartPhase = $StartPhase }
    if ($Phase) { $arguments.Phase = $Phase }
    if ($StopPhase) { $arguments.StopPhase = $StopPhase }
    if ($KeepFailedVMs) { $arguments.KeepFailedVMs = $true }
    $jobHandle = [MemLabsNativeJob]::CreateKillOnClose()
    $process = $null
    try {
        $gateName = 'Local\MemLabsDeployment-' + [guid]::NewGuid().ToString('N')
        $gateReadyName = $gateName + '-Ready'
        $startGate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $gateName)
        $gateReady = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $gateReadyName)
        try {
            $arguments.GateName = $gateName
            $arguments.GateReadyName = $gateReadyName
            $process = New-MemLabsDeploymentProcess -LauncherPath $launcherPath -Arguments $arguments
            if (-not $gateReady.WaitOne([TimeSpan]::FromSeconds(30))) {
                throw 'Deployment child did not acknowledge the start gate within 30 seconds.'
            }
            Add-MemLabsDeploymentProcessToJob -JobHandle $jobHandle -Process $process
            if (-not $startGate.Set()) { throw 'Could not release the deployment child start gate.' }
        }
        finally {
            $gateReady.Dispose()
            $startGate.Dispose()
        }
        while (-not $process.HasExited) {
            [Threading.Thread]::Sleep($PollSeconds * 1000)
            $progress = @(Get-MemLabsDeploymentProgressRecords -Path $domainLogPath -SinceUtc $startedUtc)
            foreach ($record in $progress) {
                if ($seen.Add($record.Signature)) {
                    $lastProgressUtc = [datetime]::UtcNow
                    $lastSignature = $record.Signature
                }
            }

            $nowUtc = [datetime]::UtcNow
            $noProgressSeconds = [math]::Round(($nowUtc - $lastProgressUtc).TotalSeconds, 1)
            [pscustomobject]@{
                TimeUtc = $nowUtc.ToString('o')
                ProcessId = $process.Id
                LastSignature = $lastSignature
                NoProgressSeconds = $noProgressSeconds
            } | ConvertTo-Json -Compress | Add-Content -LiteralPath $monitorLogPath -Encoding UTF8

            $reason = $null
            if ($nowUtc -ge $deadlineUtc) { $reason = "maximum runtime of $MaxHours hour(s) exceeded" }
            elseif ($noProgressSeconds -ge ($NoProgressMinutes * 60)) { $reason = "no new semantic progress for $NoProgressMinutes minute(s); last='$lastSignature'" }
            if ($reason) {
                if (-not [MemLabsNativeJob]::CloseHandle($jobHandle)) {
                    throw "Could not terminate the stalled deployment process tree: Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
                }
                $jobHandle = [IntPtr]::Zero
                if (-not $process.WaitForExit(30000)) {
                    throw 'The stalled deployment process tree did not exit within 30 seconds; diagnostics were not started while mutation could continue.'
                }
                Save-MemLabsDeploymentDiagnostics -VMName $diagnosticVmNames -DomainName $domainName -Path $diagnosticsPath -Reason $reason
                throw "Monitored deployment stopped: $reason. Diagnostics: $diagnosticsPath"
            }
        }
        if ($process.ExitCode -ne 0) { throw "New-Lab exited with code $($process.ExitCode). Output: $outputPath" }
    }
    catch {
        Save-MemLabsDeploymentFailure -Path $failurePath -Stage Operation -ErrorMessage $_.Exception.Message `
            -Process $process -OutputPath $outputPath -MonitorPath $monitorLogPath -DiagnosticsPath $diagnosticsPath `
            -CrashSourcePath $childCrashPath -CrashExportPath $crashExportPath
        throw
    }
    finally {
        if ($jobHandle -ne [IntPtr]::Zero) { [MemLabsNativeJob]::CloseHandle($jobHandle) | Out-Null }
        if ($process) {
            if (-not $process.HasExited) {
                try { $process.Kill($true) }
                catch [InvalidOperationException] { }
                if (-not $process.WaitForExit(30000)) {
                    throw 'Deployment process tree remained active after containment cleanup.'
                }
            }
            $process.Dispose()
        }
    }

    [pscustomobject]@{ MonitorLog = $monitorLogPath; Output = $outputPath; Diagnostics = $diagnosticsPath }
}

$postcondition = {
    param($OperationOutput)
    foreach ($name in $vmNames) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm -or $vm.State -ne 'Running') { return $false }
        try { $note = $vm.Notes | ConvertFrom-Json -ErrorAction Stop }
        catch { return $false }
        if ([bool]$note.inProgress -or [int]$note.lastPhaseComplete -lt $ExpectedCompletedPhase) { return $false }
    }
    return $true
}

try {
    & $liveOpsPath -Mode Mutate -Intent "Monitored deployment of $configurationPath" -Target $vmNames -TargetType HostResource `
        -Operation $operation -Postcondition $postcondition -FailureDiagnostics {
            Get-VM -Name $vmNames -ErrorAction SilentlyContinue | Select-Object Name, State, Status, Uptime, Notes
        } -IncludeOperationOutput
}
catch {
    $stage = [string]$_.Exception.Data['FailureStage']
    if ([string]::IsNullOrWhiteSpace($stage)) { $stage = 'Unhandled' }
    $operationId = [string]$_.Exception.Data['OperationId']
    if (-not (Test-Path -LiteralPath $failurePath -PathType Leaf)) {
        Save-MemLabsDeploymentFailure -Path $failurePath -Stage $stage -ErrorMessage $_.Exception.Message -OperationId $operationId `
            -JournalPath ([string]$_.Exception.Data['JournalPath']) -ActiveOwnerMetadata $_.Exception.Data['ActiveOwnerMetadata'] `
            -FailureDiagnostics @($_.Exception.Data['FailureDiagnostics']) `
            -OutputPath $outputPath -MonitorPath $monitorLogPath -DiagnosticsPath $diagnosticsPath -CrashExportPath $crashExportPath
    }
    $crashEvidence = if (Test-Path -LiteralPath $crashExportPath -PathType Leaf) { $crashExportPath } elseif (Test-Path -LiteralPath $childCrashPath -PathType Leaf) { $childCrashPath } else { '<none>' }
    throw "Monitored deployment failed during Live Ops stage '$stage'. OperationId=$operationId Failure=$failurePath Crash=$crashEvidence Output=$outputPath Monitor=$monitorLogPath Diagnostics=$diagnosticsPath"
}