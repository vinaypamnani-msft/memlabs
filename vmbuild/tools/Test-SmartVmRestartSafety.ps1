<#
.SYNOPSIS
    Verifies that guest-owned shutdown is never escalated to a hard power-off.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$hyperVPath = Join-Path $root 'common\Common.HyperV.ps1'
$scriptBlocksPath = Join-Path $root 'common\Common.ScriptBlocks.ps1'

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "$Path has parse errors: $($errors -join '; ')"
    }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) {
        throw "Expected one $Name definition, found $($functions.Count)."
    }
    [scriptblock]::Create($functions[0].Extent.Text)
}

. (Import-TestFunction -Path $hyperVPath -Name 'Restart-VM2Smart')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS  $Message"
}

$script:Logs = [System.Collections.Generic.List[object]]::new()
$script:GetVmCalls = 0
$script:StopVm2Calls = 0
$script:StartVm2Calls = 0
$script:HeartbeatCalls = 0
$script:VmScenario = 'StalledShutdown'
$global:ps_cache = @{}
$script:Evictions = 0
$script:ShutdownCalls = 0
function Remove-VmSessionFromCache {
    param([string]$VmName)
    $script:Evictions++
    foreach ($key in @($global:ps_cache.Keys | Where-Object { $_ -like "$VmName-*" })) {
        $global:ps_cache.Remove($key)
    }
}

function Write-Log {
    param(
        [Parameter(Position = 0)] $Message,
        [switch] $Warning,
        [switch] $Failure,
        [switch] $LogOnly,
        [switch] $OutputStream
    )
    $script:Logs.Add([pscustomobject]@{
            Message = "$Message"
            Warning = $Warning.IsPresent
            Failure = $Failure.IsPresent
        })
}

function Get-VM2 {
    param([string] $Name, [switch] $Fallback)
    $script:GetVmCalls++
    $uptime = [TimeSpan]::FromHours(2)
    $state = 'Running'
    if ($script:VmScenario -eq 'SelfRestarted' -and $script:GetVmCalls -ge 3) {
        $uptime = [TimeSpan]::FromMinutes(1)
    }
    elseif ($script:VmScenario -eq 'PoweredOff' -and $script:GetVmCalls -ge 2) {
        $state = 'Off'
    }
    [pscustomobject]@{
        Name      = $Name
        State     = $state
        Uptime    = $uptime
        Heartbeat = 'OkApplicationsUnknown'
        Status    = 'Operating normally'
    }
}

function Stop-VM {
    param(
        $VM,
        [switch] $Force,
        $WarningAction,
        [switch] $AsJob
    )
        $script:ShutdownCalls++
        if ($global:ps_cache.ContainsKey('LAB-VM-lab.test-admin')) {
            throw 'Idle PSDirect session was not closed before shutdown.'
        }
        $script:ShutdownJob
}

function Stop-VM2 {
    param([string] $Name, [switch] $TurnOff)
    $script:StopVm2Calls++
}

function Start-VM2 {
    param([string] $Name)
    $script:StartVm2Calls++
}

function Wait-ForHeartbeat {
    param($VmName, $Stopwatch, $Timespan)
    $script:HeartbeatCalls++
    return $true
}

function Remove-CompletedHyperVJob {
    param($Job, $Context)
}

function Write-VmJobLedgerCensus {
    param($VmName, $Context)
}

function Start-Sleep {
    param([int] $Seconds)
    if ($script:VmScenario -in @('StalledShutdown', 'RunningShutdownStalled')) {
        [Threading.Thread]::Sleep(1100)
    }
}

$script:ShutdownJob = Start-Job {
    throw "Failed to stop. A system shutdown is in progress. (0x8007045B)."
}
$null = $script:ShutdownJob | Wait-Job

try {
    $stalled = Restart-VM2Smart -Name 'LAB-VM' -AllowTurnOff `
        -GracefulTimeoutSeconds 1 -ShutdownNoProgressSeconds 1 `
        -ShutdownPollSeconds 1 -Reason 'test stalled guest shutdown'
    Assert-True (-not $stalled) 'stalled guest-owned shutdown fails closed'
    Assert-True ($script:StopVm2Calls -eq 0) 'stalled guest-owned shutdown never calls hard TurnOff'
    Assert-True ($script:StartVm2Calls -eq 0) 'stalled guest-owned shutdown is not started over its live disk'
    Assert-True ([bool]($script:Logs | Where-Object {
                $_.Warning -and $_.Message -like '*Refusing hard TurnOff while Windows owns shutdown*'
            })) 'no-progress watchdog reports the protected shutdown boundary'

    $script:VmScenario = 'SelfRestarted'
    $script:GetVmCalls = 0
    $script:StopVm2Calls = 0
    $script:StartVm2Calls = 0
    $script:HeartbeatCalls = 0
    $selfRestarted = Restart-VM2Smart -Name 'LAB-VM' -AllowTurnOff `
        -GracefulTimeoutSeconds 1 -ShutdownNoProgressSeconds 1 `
        -ShutdownPollSeconds 1 -Reason 'test guest restart'
    Assert-True $selfRestarted 'guest uptime reset proves self-restart completion'
    Assert-True ($script:StopVm2Calls -eq 0) 'self-restart does not call hard TurnOff'
    Assert-True ($script:StartVm2Calls -eq 0) 'self-restart is not started a second time'
    Assert-True ($script:HeartbeatCalls -eq 1) 'self-restart waits for heartbeat once'

    $script:VmScenario = 'PoweredOff'
    $script:GetVmCalls = 0
    $script:StopVm2Calls = 0
    $script:StartVm2Calls = 0
    $poweredOff = Restart-VM2Smart -Name 'LAB-VM' -AllowTurnOff `
        -GracefulTimeoutSeconds 1 -ShutdownNoProgressSeconds 1 `
        -ShutdownPollSeconds 1 -Reason 'test guest shutdown'
    Assert-True $poweredOff 'guest-owned shutdown reaching Off is restarted normally'
    Assert-True ($script:StopVm2Calls -eq 0) 'powered-off guest does not call hard TurnOff'
    Assert-True ($script:StartVm2Calls -eq 1) 'powered-off guest is started exactly once'

    $failedJob = $script:ShutdownJob
    $runningJob = Start-Job { Start-Sleep -Seconds 120 }
    try {
        $script:ShutdownJob = $runningJob
        $script:VmScenario = 'SelfRestarted'
        $script:GetVmCalls = 0
        $script:StopVm2Calls = 0
        $script:StartVm2Calls = 0
        $script:HeartbeatCalls = 0
        $global:ps_cache['LAB-VM-lab.test-admin'] = [pscustomobject]@{ Availability = 'Available' }
        $global:ps_cache['OTHER-VM-lab.test-admin'] = [pscustomobject]@{ Availability = 'Available' }
        $recovered = Restart-VM2Smart -Name 'LAB-VM' -AllowTurnOff `
            -GracefulTimeoutSeconds 1 -ShutdownNoProgressSeconds 1 -ShutdownPollSeconds 1
        Assert-True $recovered 'a still-running graceful shutdown job is observed until uptime proves reboot'
        Assert-True ($script:Evictions -eq 1 -and $global:ps_cache.ContainsKey('OTHER-VM-lab.test-admin')) 'only the target VM idle session is closed before shutdown'
        Assert-True ($script:StopVm2Calls -eq 0 -and $script:StartVm2Calls -eq 0) 'a running shutdown job cannot trigger hard power-off or duplicate start'
        Assert-True ($runningJob.State -eq 'Running') 'the live shutdown job is not cancelled or disposed during observation'

        $script:VmScenario = 'PoweredOff'
        $script:GetVmCalls = 0
        $poweredOff = Restart-VM2Smart -Name 'LAB-VM' -AllowTurnOff `
            -GracefulTimeoutSeconds 1 -ShutdownNoProgressSeconds 1 -ShutdownPollSeconds 1
        Assert-True ($poweredOff -and $script:StartVm2Calls -eq 1 -and $script:StopVm2Calls -eq 0) 'a running shutdown job reaching Off starts the guest once without hard power-off'
        $script:StartVm2Calls = 0
        $script:VmScenario = 'RunningShutdownStalled'
        $script:GetVmCalls = 0
        $stalled = Restart-VM2Smart -Name 'LAB-VM' -AllowTurnOff `
            -GracefulTimeoutSeconds 1 -ShutdownNoProgressSeconds 1 -ShutdownPollSeconds 1
        Assert-True (-not $stalled -and $script:StopVm2Calls -eq 0) 'a stalled Running shutdown job fails closed without hard TurnOff'
        Assert-True ([bool]($script:Logs | Where-Object {
                    $_.Message -like '*shutdownJob=Running*state=*' -or
                    $_.Message -like '*state=Running*shutdownJob=Running*'
                })) 'stalled shutdown diagnostics include VM state and live job state'

        $global:ps_cache['LAB-VM-lab.test-admin'] = [pscustomobject]@{ Availability = 'Busy' }
        $beforeShutdown = $script:ShutdownCalls
        $blocked = Restart-VM2Smart -Name 'LAB-VM' -GracefulTimeoutSeconds 1
        Assert-True (-not $blocked -and $script:ShutdownCalls -eq $beforeShutdown -and $script:Evictions -eq 1) 'busy cached PSDirect pipeline is neither disposed nor shut down underneath'
        $global:ps_cache.Remove('LAB-VM-lab.test-admin')
        $lateFailureJob = Start-Job { Start-Sleep -Seconds 2; throw 'FIXTURE_INTEGRATION_SHUTDOWN_FAILURE' }
        try {
            $script:ShutdownJob = $lateFailureJob
            $script:VmScenario = 'LateFailure'
            $script:GetVmCalls = 0
            $lateFailed = Restart-VM2Smart -Name 'LAB-VM' -AllowTurnOff `
                -GracefulTimeoutSeconds 1 -ShutdownNoProgressSeconds 10 -ShutdownPollSeconds 1
            Assert-True (-not $lateFailed -and $script:StopVm2Calls -eq 0) 'late integration-service failure fails closed without escalation'
            Assert-True ([bool]($script:Logs | Where-Object {
                        $_.Message -like '*shutdown job failed while being observed*FIXTURE_INTEGRATION_SHUTDOWN_FAILURE*'
                    })) 'late shutdown-job error is retained in diagnostics'
        }
        finally {
            Stop-Job -Job $lateFailureJob
            Remove-Job -Job $lateFailureJob -Force
        }
    }
    finally {
        Stop-Job -Job $runningJob
        Remove-Job -Job $runningJob -Force
        $script:ShutdownJob = $failedJob
        $global:ps_cache.Clear()
    }

    $scriptBlocks = Get-Content -LiteralPath $scriptBlocksPath -Raw
    foreach ($reason in @(
            'Phase 0 resume:',
            'DSC reboot-pending stuck',
            'DSC stranded PendingConfiguration',
            'stale LCM/status'
        )) {
        $call = [regex]::Match(
            $scriptBlocks,
            "Restart-VM2Smart[\s\S]{0,180}-Reason\s+`"$([regex]::Escape($reason))")
        Assert-True $call.Success "$reason recovery invokes Restart-VM2Smart"
        Assert-True ($call.Value -notmatch '-AllowTurnOff') "$reason recovery is graceful-only"
    }
}
finally {
    Remove-Job -Job $script:ShutdownJob -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: guest-owned and LCM restart paths cannot hard-power off Windows servicing.'
