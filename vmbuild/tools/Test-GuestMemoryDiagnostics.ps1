#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'common\Common.ScriptBlocks.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "$path has parse errors: $($parseErrors -join '; ')" }
foreach ($name in @('Get-MemLabsMemoryDiagnosticProbe', 'Save-MemLabsGuestMemoryDiagnostics')) {
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $name definition." }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$script:CimFails = $false
$script:CountersFail = $false
$script:PageFileCounterFails = $false
$script:GuestFails = $false
$script:GuestTimeout = 0
$script:Warnings = [Collections.Generic.List[string]]::new()
function Write-Log {
    param($Message, [switch] $OutputStream, [switch] $Warning, [switch] $LogOnly)
    if ($Warning) { $script:Warnings.Add("$Message") }
    if ($OutputStream) { [pscustomobject]@{ Text = "$Message"; LogLevel = 2 } }
}
function Get-Counter {
    param($Counter, $MaxSamples, $ErrorAction)
    if ($script:CountersFail) { throw 'fixture counters unavailable' }
    if ($Counter -eq '\Paging File(_Total)\% Usage') {
        if ($script:PageFileCounterFails) { throw 'fixture pagefile counter has no instance' }
        return [pscustomobject]@{ CounterSamples = @([pscustomobject]@{ CookedValue = 90; Status = 0 }) }
    }
    $values = @(256, 9500MB, 10000MB, 100MB, 80MB)
    [pscustomobject]@{ CounterSamples = @(for ($i = 0; $i -lt $Counter.Count; $i++) {
                [pscustomobject]@{ Path = "\\fixture$($Counter[$i])"; CookedValue = $values[$i]; Status = 0 }
            }) }
}
function Get-Process {
    param($ErrorAction)
    foreach ($i in 1..30) {
        [pscustomobject]@{
            ProcessName = if ($i -eq 1) { 'WmiPrvSE' } elseif ($i -eq 2) { 'sqlservr' } else { "fixture$i" }
            Id = $i
            PrivateMemorySize64 = $i * 100MB
            WorkingSet64 = $i * 50MB
            VirtualMemorySize64 = 4GB
            HandleCount = 100
        }
    }
}
function Get-ItemProperty {
    param($LiteralPath, $ErrorAction)
    [pscustomobject]@{ PagingFiles = @('C:\pagefile.sys 0 0'); ExistingPageFiles = @('\??\C:\pagefile.sys') }
}
function Get-CimInstance {
    param($Namespace, $ClassName, $Property, $OperationTimeoutSec, $ErrorAction)
    Assert-True ($OperationTimeoutSec -eq 10) 'Diagnostic CIM query is not bounded.'
    if ($script:CimFails) { throw 'fixture WMI out of memory' }
    if ($ClassName -eq '__ProviderHostQuotaConfiguration') {
        Assert-True ($Namespace -eq 'root') 'Provider quota query used the wrong namespace.'
        return [pscustomobject]@{ MemoryPerHost = 512MB; MemoryAllHosts = 2GB; HandlesPerHost = 4096; ThreadsPerHost = 512 }
    }
    return [pscustomobject]@{ Name = 'C:\pagefile.sys'; AllocatedBaseSize = 2048; CurrentUsage = 1800; PeakUsage = 1900 }
}
function Get-WinEvent {
    param($FilterHashtable, $MaxEvents, $ErrorAction)
    $message = if ($FilterHashtable.Id -eq 5858) { 'WMI error 0x80041006' } else { 'System low virtual memory. Top consumer: sqlservr.' }
    [pscustomobject]@{ TimeCreated = [DateTime]::UtcNow; Id = $FilterHashtable.Id; Message = $message }
}
function Get-VM {
    param($Name, $ErrorAction)
    [pscustomobject]@{
        State = 'Running'; MemoryAssigned = 4GB; MemoryDemand = 5GB
        MemoryStatus = 'Low'; DynamicMemoryEnabled = $true; MemoryMinimum = 2GB; MemoryMaximum = 8GB
    }
}
function Invoke-VmCommand {
    param($VmName, $VmDomainName, [switch] $AsJob, $TimeoutSeconds, [switch] $SuppressLog, [scriptblock] $ScriptBlock)
    $script:GuestTimeout = $TimeoutSeconds
    if ($script:GuestFails) {
        return [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = $null; ErrorDetails = @('fixture transport unavailable') }
    }
    return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = (& $ScriptBlock) }
}

$probe = Get-MemLabsMemoryDiagnosticProbe
$snapshot = & $probe
Assert-True ($snapshot.Memory.AvailableMB -eq 256 -and $snapshot.Memory.CommittedMB -eq 9500 -and
    $snapshot.Memory.CommitLimitMB -eq 10000 -and $snapshot.Memory.PageFileUsagePercent -eq 90) 'Memory counters lost their units or values.'
Assert-True ($snapshot.TopProcesses.Count -eq 25 -and $snapshot.TopProcesses[0].Id -eq 30) 'Largest private-memory consumers were not bounded or sorted.'
Assert-True ($snapshot.RelevantProcesses.Count -eq 2 -and $snapshot.RelevantProcesses.Name -contains 'WmiPrvSE') 'WMI/SQL processes outside the top 25 were lost.'
Assert-True ($snapshot.PageFiles[0].CurrentUsage -eq 1800 -and $snapshot.ProviderHostQuotas[0].MemoryPerHost -eq 512MB) 'Pagefile usage or provider quota evidence was lost.'
Assert-True ($snapshot.Indicators.Count -eq 2 -and $snapshot.ResourceExhaustionEvents.Count -eq 1 -and
    $snapshot.WmiMemoryEvents[0].Message -match '80041006' -and $snapshot.Errors.Count -eq 0) 'Pressure indicators or memory event evidence is incomplete.'

$script:PageFileCounterFails = $true
$snapshot = & $probe
Assert-True ($snapshot.Memory.CommittedMB -eq 9500 -and $null -eq $snapshot.Memory.PageFileUsagePercent -and
    $snapshot.Errors.PageFileCounter -match 'no instance') 'A missing pagefile counter discarded core commit evidence.'
$script:PageFileCounterFails = $false
$script:CimFails = $true
$snapshot = & $probe
Assert-True ($snapshot.Memory -and $snapshot.TopProcesses.Count -eq 25 -and
    $snapshot.Errors.PageFiles -eq 'fixture WMI out of memory' -and
    $snapshot.Errors.ProviderHostQuotas -eq 'fixture WMI out of memory') 'WMI failure prevented native diagnostics or was hidden.'
$script:CountersFail = $true
$snapshot = & $probe
Assert-True ($null -eq $snapshot.Memory -and $snapshot.Errors.MemoryCounters -match 'unavailable' -and
    $snapshot.TopProcesses.Count -eq 25) 'Counter failure prevented process capture or produced fake memory values.'
$script:CountersFail = $false
$script:CimFails = $false

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-memory-diag-$PID"
$Common = [pscustomobject]@{ LogPath = (Join-Path $tempRoot 'VMBuild.fixture.log') }
$request = [pscustomobject]@{
    RunId = 'fixture-run'; Reason = 'OutOfMemory'; Context = 'root\SMS\site_PRI/SMS_DistributionPoint'
    Origin = [pscustomobject]@{ ProcessId = 42; ManagedMB = 900; PrivateMB = 1400; Is64BitProcess = $false }
}
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    $output = @(Save-MemLabsGuestMemoryDiagnostics -VmName fixture -DomainName fixture.test -Request $request -Trigger BeforeRecovery)
    Assert-True ($output.Count -eq 0) 'Memory diagnostics leaked logging objects into the caller return stream.'
    $file = @(Get-ChildItem -LiteralPath $tempRoot -Filter '*-BeforeRecovery-MemoryDiagnostics.json')
    Assert-True ($file.Count -eq 1 -and $script:GuestTimeout -eq 60) 'Host report was not persisted before recovery with a bounded guest capture.'
    $report = Get-Content -LiteralPath $file[0].FullName -Raw | ConvertFrom-Json
    Assert-True ($report.Request.Origin.ProcessId -eq 42 -and $report.Guest.Memory.CommittedMB -eq 9500 -and
        $report.Host.Memory.CommittedMB -eq 9500 -and $report.HyperV.MemoryAssignedMB -eq 4096 -and
        $report.HyperV.MemoryDemandMB -eq 5120) 'Persisted report lost origin, guest, host or Hyper-V evidence.'
    $script:GuestFails = $true
    $output = @(Save-MemLabsGuestMemoryDiagnostics -VmName fixture -DomainName fixture.test -Request $request -Trigger RecoveryExhausted)
    Assert-True ($output.Count -eq 0) 'Incomplete memory diagnostics leaked logging objects into the caller return stream.'
    $file = @(Get-ChildItem -LiteralPath $tempRoot -Filter '*-RecoveryExhausted-MemoryDiagnostics.json')
    $report = Get-Content -LiteralPath $file[0].FullName -Raw | ConvertFrom-Json
    Assert-True ($null -eq $report.Guest -and $report.Errors.GuestCapture -match 'transport unavailable' -and
        $report.Host -and $report.HyperV -and $report.Request.Origin.ProcessId -eq 42) 'Guest transport failure prevented the host report or lost origin evidence.'
    $Common.LogPath = Join-Path $tempRoot 'missing\VMBuild.log'
    $output = @(Save-MemLabsGuestMemoryDiagnostics -VmName fixture -DomainName fixture.test -Request $request -Trigger BeforeRecovery)
    Assert-True ($output.Count -eq 0) 'Memory-report failure leaked logging objects into the caller return stream.'
    Assert-True (@($script:Warnings | Where-Object { $_ -match 'capture failed; recovery/failure handling will continue' }).Count -gt 0) 'Report write failure did not warn and leave recovery in control.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host 'PASS -- persistent OOM memory evidence survives WMI, counter, transport and report-write failures.'
