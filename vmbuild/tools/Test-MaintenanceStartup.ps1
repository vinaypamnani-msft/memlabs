<#
.SYNOPSIS
    Verifies maintenance startup ordering and the existing PSDirect recovery gate.
.DESCRIPTION
    Executes the shipped readiness wait with a simulated clock and mocked Hyper-V
    commands. No VMs are started, stopped, or modified on the test host.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
. (Join-Path $RootPath 'common\Common.Maintenance.ps1')

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'Common.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Common.ps1 has parse errors.' }
$waitNode = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-ForVm'
    }, $true)
if (-not $waitNode) { throw 'Wait-ForVm was not found.' }
. ([scriptblock]::Create($waitNode.Extent.Text))

function Assert-Startup {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Reset-Fixture {
    param(
        [string]$Mode = 'Ready',
        [switch]$AlreadyRunning,
        [switch]$Unmanaged,
        [switch]$NoPending,
        [switch]$ProbeFailure,
        [switch]$CopyFailure,
        [switch]$ThrowOnCopy,
        [switch]$BatchFailure
    )
    $timer = [pscustomobject]@{ Elapsed = [TimeSpan]::Zero }
    $timer | Add-Member -MemberType ScriptMethod -Name Start -Value {}
    $script:Startup = @{
        Mode = $Mode
        State = $(if ($AlreadyRunning) { 'Running' } else { 'Off' })
        Ready = $AlreadyRunning.IsPresent
        Managed = -not $Unmanaged
        NoPending = $NoPending.IsPresent
        ProbeFailure = $ProbeFailure.IsPresent
        CopyFailure = $CopyFailure.IsPresent
        ThrowOnCopy = $ThrowOnCopy.IsPresent
        BatchFailure = $BatchFailure.IsPresent
        Timer = $timer
        StartCalls = 0
        RecoveryResets = 0
        Shutdowns = 0
        Probes = 0
        HeartbeatWaits = 0
        Events = [Collections.Generic.List[string]]::new()
        Logs = [Collections.Generic.List[string]]::new()
    }
}

function New-Object {
    param([string]$TypeName)
    if ($TypeName -ne 'System.Diagnostics.Stopwatch') { throw "Unexpected test allocation: $TypeName" }
    return $script:Startup.Timer
}
function Get-VM2 {
    [CmdletBinding()]
    param($Name, [switch]$Fallback)
    if ($script:Startup.Mode -eq 'MissingVM') { return $null }
    $heartbeat = if ($script:Startup.Timer.Elapsed.TotalSeconds -ge 90 -or $script:Startup.Mode -eq 'AuthFailure') {
        'OkApplicationsUnknown'
    }
    else { 'NoContact' }
    [pscustomobject]@{
        Name = $Name; State = $script:Startup.State; Heartbeat = $heartbeat
        Uptime = $script:Startup.Timer.Elapsed
    }
}
function Get-VMHardDiskDrive {
    [CmdletBinding()]
    param($VMName)
    [pscustomobject]@{ VMName = $VMName; Path = 'fixture.vhdx' }
}
function Start-VM2 {
    param($Name, [switch]$Passthru)
    $script:Startup.StartCalls++
    $script:Startup.Events.Add('start')
    if ($script:Startup.Mode -eq 'StartFailure') { return $false }
    $script:Startup.State = 'Running'
    if ($Passthru) { return $true }
}
function Stop-VM2 {
    param($Name, [switch]$TurnOff, $retryCount, $retrySeconds)
    if ($TurnOff) {
        $script:Startup.RecoveryResets++
        $script:Startup.Events.Add('reset')
    }
    else {
        $script:Startup.Shutdowns++
        $script:Startup.Events.Add('shutdown')
    }
    $script:Startup.State = 'Off'
    return $true
}
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    $script:Startup.Timer.Elapsed += [TimeSpan]::FromMilliseconds(1000 * $Seconds + $Milliseconds)
}
function Wait-ForHeartbeat {
    param($VmName, $Stopwatch, $Timespan)
    $script:Startup.HeartbeatWaits++
    return $true
}
function Write-Log {
    param($Message, [switch]$Verbose, [switch]$Warning, [switch]$Failure, [switch]$Success, [switch]$LogOnly)
    $script:Startup.Logs.Add("$Message")
}
function Write-Progress2 {
    param($Activity, $Status, $PercentComplete, [switch]$Log, [switch]$Force, [switch]$Completed)
}
function Write-ProgressElapsed {
    param([switch]$showTimeout, $stopwatch, $timespan, $text)
}
function Invoke-VmCommand {
    param($VmName, $VmDomainName, $ScriptBlock, $DisplayName, [switch]$AsJob,
        $SessionMaxRetries, [switch]$SuppressLog, [switch]$ShowVMSessionError, [switch]$CommandReturnsBool)
    if ($DisplayName -eq 'Testing for Memlabs files') {
        Assert-Startup ($script:Startup.State -eq 'Running' -and $script:Startup.Ready) `
            'Maintenance probed staging before the VM was started and connected.'
        $script:Startup.Events.Add('probe')
        if ($script:Startup.ProbeFailure) {
            return [pscustomobject]@{
                ScriptBlockFailed = $true; ScriptBlockOutput = $null; ErrorDetails = @('Fixture staging inspection failure')
            }
        }
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $script:Startup.Managed }
    }

    $script:Startup.Probes++
    $script:Startup.Timer.Elapsed += [TimeSpan]::FromSeconds(40)
    $ready = switch ($script:Startup.Mode) {
        'Ready' { $true }
        'SlowBoot' { $script:Startup.Timer.Elapsed.TotalSeconds -ge 180 }
        'BrokenUntilRestart' { $script:Startup.RecoveryResets -eq 1 }
        default { $false }
    }
    if ($ready) {
        $script:Startup.Ready = $true
        $script:Startup.Events.Add('ready')
    }
    [pscustomobject]@{
        ScriptBlockFailed = -not $ready
        ScriptBlockOutput = $(if ($ready) { [pscustomobject]@{ Path = $true; Root = $true } } else { $null })
        ChannelBroken = -not $ready -and $script:Startup.Mode -ne 'AuthFailure'
        TimedOut = $false
        ErrorDetails = $(if ($ready) { $null } else { 'Fixture PSDirect connection failure' })
    }
}
function Get-VMNote {
    param($VMName)
    $applied = @{}
    if ($script:Startup.NoPending) { $applied['Fix-UnitStartup'] = '1.0' }
    [pscustomobject]@{ domain = 'lab.test'; role = 'DomainMember'; appliedFixes = [pscustomobject]$applied }
}
function ConvertTo-MemLabsVersion {
    param($Version)
    return [version]$Version
}
function Copy-ItemSafe {
    param($VmName, $VMDomainName, $Path, $Destination, [switch]$Recurse, [switch]$Container, [switch]$Force)
    Assert-Startup ($script:Startup.Ready) 'DSC staging ran before maintenance readiness.'
    $script:Startup.Events.Add('copy')
    if ($script:Startup.ThrowOnCopy) { throw 'Fixture DSC staging failure' }
    return (-not $script:Startup.CopyFailure)
}
function Start-VMFixesBatched {
    param($VMName, $VMDomain, $VMFixes, [switch]$FreshDeployOnly)
    $script:Startup.Events.Add('batch')
    [pscustomobject]@{
        Success = -not $script:Startup.BatchFailure
        AppliedCount = 0; ApplicableCount = 0; VMsToStop = @()
    }
}

function Invoke-DependencyFixture {
    param([switch]$FailConnection, [switch]$MissingDomain)
    & {
        Reset-Fixture
        function Get-VMNote {
            param($VMName)
            [pscustomobject]@{
                domain = $(if ($MissingDomain -and $VMName -eq 'LAB-DEP') { '' } else { 'lab.test' })
                role = 'DomainMember'; appliedFixes = [pscustomobject]@{}
            }
        }
        function Start-VMIfNotRunning {
            param($VMName, $VMDomain, [switch]$WaitForConnect, [switch]$Quiet)
            $script:Startup.Events.Add("start:$VMName")
            if ($VMName -eq 'LAB-CLIENT') {
                $script:Startup.State = 'Running'
                $script:Startup.Ready = $true
            }
            [pscustomobject]@{
                StartedVM = $true; StartFailed = $false
                ConnectFailed = $FailConnection -and $VMName -eq 'LAB-DEP'
            }
        }
        function Start-VMFix {
            param($VMName, $VMFix, [switch]$FreshDeployOnly)
            $script:Startup.Events.Add('fix')
            [pscustomobject]@{ Success = $true; Applied = $true; VMsToStop = @() }
        }
        $fix = [pscustomobject]@{
            FixName = 'Fix-UnitStartup'; FixVersion = '1.0'; AppliesToThisVM = $true; DependentVMs = @('LAB-DEP')
        }
        $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
        [pscustomobject]@{ Result = $result; State = $script:Startup }
    }
}

$savedActivity = $global:MaintenanceActivity
$savedOrphans = $global:ps_orphanRunspaces
try {
    $global:MaintenanceActivity = 'startup test'
    $global:ps_orphanRunspaces = @()
    Reset-Fixture
    $result = Start-VMIfNotRunning -VMName 'LAB-CLIENT' -VMDomain 'lab.test'
    Assert-Startup ($result.StartedVM -and -not $result.ConnectFailed -and $script:Startup.Probes -eq 0) `
        'Starting without WaitForConnect acquired an unexpected readiness wait.'
    Reset-Fixture -AlreadyRunning
    $result = Start-VMIfNotRunning -VMName 'LAB-CLIENT' -VMDomain 'lab.test' -WaitForConnect -Quiet
    Assert-Startup (-not $result.StartedVM -and -not $result.ConnectFailed -and $script:Startup.Probes -eq 0) `
        'An already-running VM acquired an unexpected startup wait.'

    foreach ($mode in @('SlowBoot', 'BrokenUntilRestart', 'NeverReady', 'AuthFailure', 'StartFailure', 'MissingVM')) {
        Reset-Fixture -Mode $mode
        $result = Start-VMIfNotRunning -VMName 'LAB-CLIENT' -VMDomain 'lab.test' -WaitForConnect -Quiet
        $expectedReady = $mode -in @('SlowBoot', 'BrokenUntilRestart')
        Assert-Startup ($result.ConnectFailed -eq (-not $expectedReady)) `
            "Maintenance startup could not reach its existing recovery gate, or lost its failure verdict ($mode)."
        if ($expectedReady) {
            Assert-Startup ($result.StartedVM -and -not $result.StartFailed) "Successful startup lost its ownership ($mode)."
        }
        if ($mode -eq 'BrokenUntilRestart') {
            Assert-Startup ($script:Startup.RecoveryResets -eq 1 -and $script:Startup.HeartbeatWaits -eq 1) `
                'The three-failure/three-minute PSDirect recovery did not run exactly once.'
            Assert-Startup ($script:Startup.Timer.Elapsed.TotalSeconds -ge 180 -and
                $script:Startup.Timer.Elapsed.TotalSeconds -lt 600) 'PSDirect recovery did not fit inside the startup budget.'
        }
        if ($mode -eq 'SlowBoot' -or $mode -eq 'AuthFailure') {
            Assert-Startup ($script:Startup.RecoveryResets -eq 0) "Slow boot or authentication failure caused a reset ($mode)."
        }
        if ($mode -in @('NeverReady', 'AuthFailure')) {
            Assert-Startup ($script:Startup.Timer.Elapsed.TotalSeconds -ge 600 -and
                $script:Startup.Timer.Elapsed.TotalSeconds -lt 690) 'Readiness did not honor its bounded ten-minute wait.'
            Assert-Startup (($script:Startup.Logs -join "`n") -match 'WAIT FAILURE SUMMARY') 'Readiness failure lost its diagnostics.'
        }
        if ($mode -in @('StartFailure', 'MissingVM')) {
            Assert-Startup ($result.StartFailed -and -not $result.StartedVM -and $script:Startup.Probes -eq 0) `
                "A failed VM start reached the guest ($mode)."
        }
    }

    $fix = [pscustomobject]@{
        FixName = 'Fix-UnitStartup'; FixVersion = '1.0'; AppliesToThisVM = $true; DependentVMs = @()
    }
    Reset-Fixture
    $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
    Assert-Startup ($result -is [bool] -and $result -eq $true -and
        ($script:Startup.Events -join ',') -eq 'start,ready,probe,copy,batch,shutdown') `
        'Maintenance startup, staging, execution, or owned-VM cleanup was reordered.'

    Reset-Fixture -AlreadyRunning
    $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
    Assert-Startup ($result -eq $true -and $script:Startup.StartCalls -eq 0 -and $script:Startup.Shutdowns -eq 0) `
        'Maintenance changed the power state of an already-running VM.'

    Reset-Fixture -Unmanaged
    $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
    Assert-Startup ($result -eq $true -and ($script:Startup.Events -join ',') -eq 'start,ready,probe,shutdown') `
        'An unmanaged VM ran fixes or escaped owned-VM cleanup.'

    Reset-Fixture -NoPending
    $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
    Assert-Startup ($result -eq $true -and $script:Startup.StartCalls -eq 0 -and
        -not $script:Startup.Events.Contains('probe') -and -not $script:Startup.Events.Contains('copy')) `
        'Already-applied maintenance started or contacted the VM.'

    $dependency = Invoke-DependencyFixture
    Assert-Startup ($dependency.Result -is [bool] -and $dependency.Result -and
        ($dependency.State.Events -join ',') -eq 'start:LAB-DEP,start:LAB-CLIENT,probe,copy,fix,shutdown,shutdown') `
        'Dependency startup did not precede the target, or the sequential path lost owned-VM cleanup.'
    $dependency = Invoke-DependencyFixture -FailConnection
    Assert-Startup ($dependency.Result -is [bool] -and -not $dependency.Result -and
        ($dependency.State.Events -join ',') -eq 'start:LAB-DEP,shutdown') `
        'A failed dependency reached target startup, staging, or fixes.'
    $dependency = Invoke-DependencyFixture -MissingDomain
    Assert-Startup ($dependency.Result -eq $false -and $dependency.State.Events.Count -eq 0 -and
        ($dependency.State.Logs -join "`n") -match 'no resolvable domain') 'Invalid dependency metadata did not fail before startup.'

    foreach ($mode in @('NeverReady', 'StartFailure', 'MissingVM')) {
        Reset-Fixture -Mode $mode
        $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
        Assert-Startup ($result -is [bool] -and $result -eq $false -and -not $script:Startup.Events.Contains('probe') -and
            -not $script:Startup.Events.Contains('copy') -and -not $script:Startup.Events.Contains('batch')) `
            "Startup failure reached maintenance preflight or fix execution ($mode)."
        Assert-Startup ($script:Startup.Shutdowns -eq $(if ($mode -eq 'NeverReady') { 1 } else { 0 })) `
            "Startup failure lost owned-VM cleanup ($mode)."
    }

    Reset-Fixture -BatchFailure
    $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
    Assert-Startup ($result -eq $false -and $script:Startup.Shutdowns -eq 1) 'A failed batch lost its verdict or VM cleanup.'

    Reset-Fixture -ProbeFailure
    $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
    Assert-Startup ($result -eq $false -and -not $script:Startup.Events.Contains('copy') -and
        -not $script:Startup.Events.Contains('batch') -and $script:Startup.Shutdowns -eq 1 -and
        ($script:Startup.Logs -join "`n") -match 'Fixture staging inspection failure') `
        'A failed staging inspection ran fixes, lost its original error, or bypassed cleanup.'

    Reset-Fixture -CopyFailure
    $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix)
    Assert-Startup ($result -eq $false -and -not $script:Startup.Events.Contains('batch') -and
        $script:Startup.Shutdowns -eq 1 -and ($script:Startup.Logs -join "`n") -match 'DSC staging failed') `
        'A failed DSC copy ran fixes, escaped cleanup, or lacked an explicit failure.'

    Reset-Fixture -ThrowOnCopy
    $threw = $false
    try { $null = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix) }
    catch {
        if ($_.Exception.Message -ne 'Fixture DSC staging failure') { throw }
        $threw = $true
    }
    Assert-Startup ($threw -and $script:Startup.Shutdowns -eq 1) 'An exception bypassed owned-VM cleanup.'

    Reset-Fixture
    $result = Start-VMFixes -VMName 'LAB-CLIENT' -VMFixes @($fix) -SkipVMShutdown
    Assert-Startup ($result -eq $true -and $script:Startup.State -eq 'Running' -and $script:Startup.Shutdowns -eq 0) `
        'SkipVMShutdown no longer preserves a started VM.'
}
finally {
    $global:MaintenanceActivity = $savedActivity
    $global:ps_orphanRunspaces = $savedOrphans
}

Write-Host 'PASS -- Maintenance startup ordering, bounded PSDirect recovery, readiness failures, and owned-VM cleanup.'
