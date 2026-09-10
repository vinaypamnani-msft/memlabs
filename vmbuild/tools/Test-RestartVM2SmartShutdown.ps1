<#
.SYNOPSIS
    Regresses graceful restart handling when Windows is already shutting down.
#>
[CmdletBinding()]
param(
    [string]$RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-RestartEqual {
    param($Expected, $Actual, [string]$What)

    $passed = ("$Expected" -eq "$Actual")
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

function Get-RestartFunctionText {
    $path = Join-Path $RootPath 'common\Common.HyperV.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $path).Path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) { throw "Common.HyperV.ps1 has parse errors: $($parseErrors -join '; ')" }

    $functionAst = $ast.Find({
            param($candidate)
            $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq 'Restart-VM2Smart'
        }, $true)
    if (-not $functionAst) { throw 'Restart-VM2Smart was not found.' }
    return $functionAst.Extent.Text
}

function Invoke-RestartCase {
    param(
        [string]$FunctionText,
        [string]$StopError,
        [bool]$GuestRestarts
    )

    $script:RestartLogs = @()
    $script:RestartTurnOffCalls = 0
    $script:RestartStartCalls = 0
    $script:RestartVmReads = 0
    $script:RestartStopError = $StopError
    $script:RestartGuestRestarts = $GuestRestarts

    function Write-Log {
        param($Message, [switch]$Warning, [switch]$LogOnly)
        $script:RestartLogs += [string]$Message
    }
    function Get-VM2 {
        param($Name, [switch]$Fallback)
        $script:RestartVmReads++
        $uptime = if ($script:RestartGuestRestarts -and $script:RestartVmReads -ge 3) {
            [TimeSpan]::FromSeconds(30)
        }
        else {
            [TimeSpan]::FromHours(1)
        }
        return [pscustomobject]@{ State = 'Running'; Uptime = $uptime }
    }
    function Stop-VM {
        [CmdletBinding()]
        param($VM, [switch]$Force, [switch]$AsJob)
        return [pscustomobject]@{
            State        = 'Completed'
            ChildJobs    = @()
            JobStateInfo = [pscustomobject]@{ Reason = $null }
            Error        = @($script:RestartStopError)
        }
    }
    function Wait-Job { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$Job, $Timeout) }
    function Stop-Job { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$Job) }
    function Remove-CompletedHyperVJob { param($Job, $Context) }
    function Stop-VM2 { param($Name, [switch]$TurnOff) $script:RestartTurnOffCalls++ }
    function Start-VM2 { param($Name) $script:RestartStartCalls++ }
    function Wait-ForHeartbeat { param($VmName, $Stopwatch, $Timespan) return $true }
    function Start-Sleep { param($Seconds) }

    . ([scriptblock]::Create($FunctionText))
    $result = Restart-VM2Smart -Name 'TEST-VM' -AllowTurnOff -Reason 'test' -GracefulTimeoutSeconds 1
    return [pscustomobject]@{
        Result       = $result
        TurnOffCalls = $script:RestartTurnOffCalls
        StartCalls   = $script:RestartStartCalls
        Logs         = @($script:RestartLogs)
    }
}

$functionText = Get-RestartFunctionText
$inProgress = Invoke-RestartCase -FunctionText $functionText `
    -StopError 'A system shutdown is in progress. (0x8007045B).' -GuestRestarts $true
$scheduled = Invoke-RestartCase -FunctionText $functionText `
    -StopError 'A system shutdown has already been scheduled. (0x800704A6).' -GuestRestarts $true
$scheduledStuck = Invoke-RestartCase -FunctionText $functionText `
    -StopError 'A system shutdown has already been scheduled. (0x800704A6).' -GuestRestarts $false
$prefixCollision = Invoke-RestartCase -FunctionText $functionText `
    -StopError 'The operation failed. (0x800704A60).' -GuestRestarts $false
$unrelated = Invoke-RestartCase -FunctionText $functionText `
    -StopError 'The operation failed. (0x80070005).' -GuestRestarts $false

Assert-RestartEqual 0 $inProgress.TurnOffCalls '0x8007045B waits without hard TurnOff'
Assert-RestartEqual 0 $scheduled.TurnOffCalls '0x800704A6 waits without hard TurnOff'
Assert-RestartEqual 1 $scheduledStuck.TurnOffCalls 'Scheduled shutdown escalates only after bounded wait expires'
Assert-RestartEqual 1 $prefixCollision.TurnOffCalls 'HRESULT prefix collision still escalates'
Assert-RestartEqual 1 $unrelated.TurnOffCalls 'Unrelated graceful-stop failure still escalates'
Assert-RestartEqual $true ([bool]($scheduled.Logs -match 'already shutting down')) 'Scheduled shutdown takes the wait branch'
Assert-RestartEqual $true ([bool]($unrelated.Logs -match 'hard TurnOff')) 'Unrelated failure takes the escalation branch'

if ($script:Failures -ne 0) { exit 1 }
exit 0