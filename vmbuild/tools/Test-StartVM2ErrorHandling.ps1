<#
.SYNOPSIS
    Verifies Start-VM2 handles empty and multiple captured errors without live VMs.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'common\Common.HyperV.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Common.HyperV.ps1 has parse errors: $($parseErrors -join '; ')" }
$definitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Start-VM2'
        }, $true))
if ($definitions.Count -ne 1) { throw "Expected one Start-VM2 definition, found $($definitions.Count)." }
. ([scriptblock]::Create($definitions[0].Extent.Text))

$script:Assertions = 0
$script:VmName = 'MEMLABS-START-TEST-' + [guid]::NewGuid().ToString('N')
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Write-Log {
    param([string]$Message, [switch]$Warning, [switch]$LogOnly)
    $script:Logs.Add($Message)
}
function Write-Exception {
    param($ExceptionInfo)
    $script:Exceptions.Add([string]$ExceptionInfo)
}
function Write-Progress2 {
    param($Activity, [string]$Status, [switch]$Force, [switch]$Completed)
    $script:Progress.Add($Status)
}
function Get-VM2 {
    param([string]$Name, [switch]$Fallback)
    [pscustomobject]@{ Name = $Name; State = $script:VmState }
}
function Start-VM {
    [CmdletBinding()]
    param($VM)

    $script:StartCalls++
    $messages = @()
    switch ($script:Scenario) {
        'AuthenticationRetry' {
            if ($script:StartCalls -eq 1) {
                $messages = @('Hyper-V startup failed.', 'The computed authentication tag did not match the input authentication tag.')
            }
        }
        'FileInUseRetry' {
            if ($script:StartCalls -eq 1) {
                $messages = @("VM failed to start.`r`nThe file is being used by another process. (0x80070020)")
            }
        }
        'OutOfMemoryRetry' {
            if ($script:StartCalls -le 2) {
                $messages = @('Hyper-V startup failed.', "Not enough memory in the system.`r`n(0x8007000E)")
            }
        }
        'Failure' {
            $messages = @('Access denied. (0x80070005)', 'Hyper-V startup failed.')
        }
    }
    foreach ($message in $messages) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new($message),
                'SyntheticVmStart', [System.Management.Automation.ErrorCategory]::InvalidOperation, $VM))
    }
    if ($messages.Count -eq 0) {
        # A fresh Get-VM2 read must observe success even if the original object is stale.
        $script:VmState = 'Running'
    }
}
function Remove-VMSavedState {
    [CmdletBinding()]
    param($VM)
    $script:SavedStateRemovals++
}
function Stop-VM {
    [CmdletBinding()]
    param($VM, [switch]$TurnOff, [switch]$Force)
    throw 'Unexpected hard power-off in startup error handling.'
}
function Clear-StrayVhdMounts {
    param([string]$VMName)
    $script:MountSweeps++
    if ($script:Scenario -eq 'FileInUseRetry') { return 1 }
    return 0
}
function Start-Sleep {
    param([int]$Seconds)
    $script:Delays.Add($Seconds)
}
function Get-Counter {
    [CmdletBinding()]
    param([string]$Counter)
    [pscustomobject]@{ CounterSamples = @([pscustomobject]@{ CookedValue = 8192 }) }
}
function Get-Process {
    [CmdletBinding()]
    param()
}
function Invoke-HostMemoryReclaim { $script:Reclaims++ }
function Write-HostMemoryPressureDiag {
    param([string]$Context)
    $script:MemoryDiagnostics++
}

function Invoke-StartCase {
    param([string]$Scenario, [switch]$AlreadyRunning, [switch]$WithoutPassthru)

    $script:Scenario = $Scenario
    $script:VmState = if ($AlreadyRunning) { 'Running' } else { 'Off' }
    $script:StartCalls = 0
    $script:SavedStateRemovals = 0
    $script:MountSweeps = 0
    $script:Reclaims = 0
    $script:MemoryDiagnostics = 0
    $script:Logs = [System.Collections.Generic.List[string]]::new()
    $script:Exceptions = [System.Collections.Generic.List[string]]::new()
    $script:Progress = [System.Collections.Generic.List[string]]::new()
    $script:Delays = [System.Collections.Generic.List[int]]::new()
    $progressBefore = $global:ProgressPreference
    $output = @(Start-VM2 -Name $script:VmName -Passthru:(-not $WithoutPassthru) -RetryCount 0 -RetrySeconds 0)

    Assert-True ($script:Exceptions.Count -eq 0) "$Scenario raised an unexpected exception: $($script:Exceptions -join '; ')"
    Assert-True ($global:ProgressPreference -eq $progressBefore) "$Scenario did not restore ProgressPreference."
    Assert-True (@($script:Progress | Where-Object { $_ -match '[\r\n]' }).Count -eq 0) "$Scenario emitted multiline progress."
    if ($WithoutPassthru) {
        Assert-True ($output.Count -eq 0) "$Scenario emitted output without Passthru."
    }
    else {
        Assert-True ($output.Count -eq 1 -and $output[0] -is [bool]) "$Scenario did not return exactly one Boolean with Passthru."
    }
    [pscustomobject]@{ Output = $output }
}

$success = Invoke-StartCase -Scenario 'Success'
Assert-True $success.Output[0] 'A successful Start-VM with an empty ErrorVariable was reported as failure.'
Assert-True ($script:StartCalls -eq 1 -and $script:MountSweeps -eq 0 -and $script:SavedStateRemovals -eq 0) 'Successful startup triggered retries or recovery.'

$null = Invoke-StartCase -Scenario 'Success' -WithoutPassthru
Assert-True ($script:StartCalls -eq 1) 'Startup without Passthru did not start exactly once.'

$alreadyRunning = Invoke-StartCase -Scenario 'Success' -AlreadyRunning
Assert-True ($alreadyRunning.Output[0] -and $script:StartCalls -eq 0) 'An already running VM was started again.'

$authentication = Invoke-StartCase -Scenario 'AuthenticationRetry'
Assert-True ($authentication.Output[0] -and $script:StartCalls -eq 2 -and $script:SavedStateRemovals -eq 1) 'Authentication-tag errors among multiple records did not recover.'
Assert-True ($script:MountSweeps -eq 0) 'A successful authentication retry triggered a mount sweep.'

$fileInUse = Invoke-StartCase -Scenario 'FileInUseRetry'
Assert-True ($fileInUse.Output[0] -and $script:StartCalls -eq 2 -and $script:MountSweeps -eq 1) 'File-in-use recovery did not retry after clearing a mount.'

$outOfMemory = Invoke-StartCase -Scenario 'OutOfMemoryRetry'
Assert-True ($outOfMemory.Output[0] -and $script:StartCalls -eq 3 -and $script:Reclaims -eq 2) 'Multiple error records prematurely ended OOM recovery.'
Assert-True (($script:Delays -join ',') -eq '30,60') 'OOM recovery changed its bounded backoff.'

$failure = Invoke-StartCase -Scenario 'Failure'
Assert-True (-not $failure.Output[0] -and $script:StartCalls -eq 1 -and $script:MountSweeps -eq 1) 'A genuine startup failure was reported as success or retried without recovery.'
Assert-True ([bool]($script:Logs -match 'Failed to start the VM.*Access denied.*Hyper-V startup failed')) 'Terminal startup diagnostics lost captured errors.'

Write-Host "PASS: $script:Assertions Start-VM2 error-handling assertions (no live VMs)."
