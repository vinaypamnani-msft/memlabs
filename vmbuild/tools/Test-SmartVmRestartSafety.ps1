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
    if ($script:VmScenario -eq 'StalledShutdown') {
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
