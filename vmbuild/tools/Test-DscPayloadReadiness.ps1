<#
.SYNOPSIS
    Verifies DSC staging distinguishes a missing payload from a broken PSDirect channel.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw
$start = $source.IndexOf('        $dscModuleProbe = {', [StringComparison]::Ordinal)
$end = $source.IndexOf('        $dscZipHash = ', [StringComparison]::Ordinal)
if ($start -lt 0 -or $end -le $start) { throw 'Could not isolate the shipped DSC staging inspection.' }
$probe = [scriptblock]::Create('param($currentItem, $domainName, $Activity, $Phase)' + [Environment]::NewLine + $source.Substring($start, $end - $start) + @'

$script:StagingContinued = $true
$script:ObservedState = [pscustomobject]@{
    Hash = $guestZipHash
    FlagExists = $guestFlagExists
    InstalledHash = $guestInstalledHash
    SourceSignature = $guestSourceSignature
}
'@)

$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

function New-ProbeResult {
    param(
        $State,
        [switch]$Failed,
        [switch]$ChannelBroken,
        [switch]$TimedOut,
        [string]$ErrorDetail
    )
    [pscustomobject]@{
        CommandResult = -not $Failed
        ScriptBlockFailed = $Failed.IsPresent
        ScriptBlockOutput = if ($Failed) { $ErrorDetail } else { $State }
        ChannelBroken = $ChannelBroken.IsPresent
        TimedOut = $TimedOut.IsPresent
        ErrorDetails = @($ErrorDetail)
    }
}

function Invoke-VmCommand {
    param(
        [string]$VmName,
        [string]$VmDomainName,
        [scriptblock]$ScriptBlock,
        [string]$DisplayName,
        [switch]$SuppressLog
    )
    $script:ProbeCalls.Add([pscustomobject]@{
            VmName = $VmName
            Domain = $VmDomainName
            Probe = $ScriptBlock.ToString()
            Quiet = $SuppressLog.IsPresent
        })
    if ($script:Responses.Count -eq 0) { throw 'Unexpected extra DSC staging inspection.' }
    $script:Responses.Dequeue()
}

function Wait-ForVM {
    param(
        [string]$VmName,
        [string]$PathToVerify,
        [string]$VmDomainName,
        [switch]$SkipDiskTest,
        [int]$TimeoutMinutes
    )
    $script:RecoveryCalls.Add([pscustomobject]@{
            VmName = $VmName
            Domain = $VmDomainName
            Path = $PathToVerify
            SkipDisk = $SkipDiskTest.IsPresent
            Timeout = $TimeoutMinutes
        })
    return $script:Ready
}

function Write-Log {
    param(
        [string]$Message,
        [switch]$LogOnly,
        [switch]$OutputStream,
        [switch]$Failure
    )
    $script:Logs.Add([pscustomobject]@{
            Message = $Message
            Failure = $Failure.IsPresent
            Output = $OutputStream.IsPresent
        })
}

function Write-Progress2 {
    param($Activity, $Status, $PercentComplete, [switch]$Force)
}

function Invoke-TestScenario {
    param([object[]]$Results, [bool]$Ready = $true, [int]$Phase = 2)
    $script:Responses = [System.Collections.Generic.Queue[object]]::new()
    foreach ($item in $Results) { $script:Responses.Enqueue($item) }
    $script:Ready = $Ready
    $script:ProbeCalls = [System.Collections.Generic.List[object]]::new()
    $script:RecoveryCalls = [System.Collections.Generic.List[object]]::new()
    $script:Logs = [System.Collections.Generic.List[object]]::new()
    $script:StagingContinued = $false
    $script:ObservedState = $null
    & $probe -currentItem ([pscustomobject]@{ vmName = 'CS2-FS1' }) -domainName 'cstest2.com' -Activity 'Configure VM' -Phase $Phase
}

$state = [pscustomobject]@{
    Hash = 'CURRENT-ZIP-HASH'
    FlagExists = $true
    InstalledHash = 'INSTALLED-ZIP-HASH'
    SourceSignature = 'CURRENT-SOURCE-SIGNATURE'
}
$healthy = New-ProbeResult -State $state
$broken = New-ProbeResult -Failed -ChannelBroken -ErrorDetail 'New-PSSession timed out'

Invoke-TestScenario -Results @($healthy)
Assert-True ($script:StagingContinued) 'Healthy staging inspection did not continue.'
Assert-True ($script:ProbeCalls.Count -eq 1 -and $script:RecoveryCalls.Count -eq 0) 'A healthy guest paid a retry or recovery cost.'
Assert-True ($script:ObservedState.Hash -eq $state.Hash -and
    $script:ObservedState.FlagExists -eq $state.FlagExists -and
    $script:ObservedState.InstalledHash -eq $state.InstalledHash -and
    $script:ObservedState.SourceSignature -eq $state.SourceSignature) 'Staging metadata changed.'
Assert-True ($script:Logs.Count -eq 0) 'Healthy staging inspection emitted a recovery or failure message.'

$empty = New-ProbeResult -State ([pscustomobject]@{
        Hash = $null
        FlagExists = $false
        InstalledHash = $null
        SourceSignature = $null
    })
Invoke-TestScenario -Results @($empty)
Assert-True ($script:StagingContinued -and $script:RecoveryCalls.Count -eq 0) 'An answered inspection with no payload was mistaken for a connection failure.'
Assert-True ($null -eq $script:ObservedState.Hash -and -not $script:ObservedState.FlagExists) 'A missing payload acquired invented metadata.'

Invoke-TestScenario -Results @($broken, $healthy)
Assert-True ($script:StagingContinued -and $script:ObservedState.Hash -eq $state.Hash) 'Recovered inspection did not use the fresh guest state.'
Assert-True ($script:ProbeCalls.Count -eq 2 -and $script:RecoveryCalls.Count -eq 1) 'Channel failure did not use exactly one guarded recovery and one retry.'
Assert-True ($script:RecoveryCalls[0].VmName -eq 'CS2-FS1' -and
    $script:RecoveryCalls[0].Domain -eq 'cstest2.com' -and
    $script:RecoveryCalls[0].Path -eq 'C:\Users' -and
    $script:RecoveryCalls[0].SkipDisk -and
    $script:RecoveryCalls[0].Timeout -eq 10) 'Recovery did not use the existing bounded readiness contract for the affected VM.'
Assert-True (@($script:ProbeCalls | Where-Object { $_.VmName -ne 'CS2-FS1' -or $_.Domain -ne 'cstest2.com' -or -not $_.Quiet }).Count -eq 0) 'Inspection targeted the wrong guest or classified retryable connection failures prematurely.'
Assert-True ($script:ProbeCalls[0].Probe -eq $script:ProbeCalls[1].Probe) 'Recovery retried a different inspection payload.'
Assert-True (@($script:Logs | Where-Object Failure).Count -eq 0 -and
    @($script:Logs | Where-Object { $_.Output -and $_.Message -like '*inspection recovered*' }).Count -eq 1) 'Recovered inspection was still classified as a failure or was not reported.'

$timedOut = New-ProbeResult -Failed -TimedOut -ErrorDetail 'Inspection timed out'
Invoke-TestScenario -Results @($timedOut, $healthy)
Assert-True ($script:StagingContinued -and $script:RecoveryCalls.Count -eq 1) 'An explicit timeout did not enter guarded readiness recovery.'

Invoke-TestScenario -Results @($broken, $healthy) -Ready $false
Assert-True (-not $script:StagingContinued -and $script:ProbeCalls.Count -eq 1 -and $script:RecoveryCalls.Count -eq 1) 'Failed readiness recovery allowed staging or another inspection.'
$failures = @($script:Logs | Where-Object Failure)
Assert-True ($failures.Count -eq 1 -and $failures[0].Output -and
    $failures[0].Message -like '*guarded 10-minute DSC staging recovery*New-PSSession timed out*') 'Recovery exhaustion did not retain the original transport error in the terminal phase failure.'

$stillBroken = New-ProbeResult -Failed -ChannelBroken -ErrorDetail 'Recovery inspection timed out'
Invoke-TestScenario -Results @($broken, $stillBroken)
Assert-True (-not $script:StagingContinued -and $script:ProbeCalls.Count -eq 2 -and $script:RecoveryCalls.Count -eq 1) 'A failed recovery inspection started an unbounded retry or continued staging.'
$failures = @($script:Logs | Where-Object Failure)
Assert-True ($failures.Count -eq 1 -and $failures[0].Message -like '*Failed to inspect*Recovery inspection timed out*') 'The final inspection failure lost its diagnostic.'

foreach ($detail in @('The credential is invalid.', 'Access to C:\staging\DSC is denied.')) {
    $failed = New-ProbeResult -Failed -ErrorDetail $detail
    Invoke-TestScenario -Results @($failed)
    Assert-True (-not $script:StagingContinued -and $script:ProbeCalls.Count -eq 1 -and $script:RecoveryCalls.Count -eq 0) 'An authentication or guest-script error triggered channel recovery or continued staging.'
    $failures = @($script:Logs | Where-Object Failure)
    Assert-True ($failures.Count -eq 1 -and $failures[0].Message.Contains($detail)) 'An ordinary inspection failure was hidden.'
}

foreach ($invalid in @(
        $null,
        (New-ProbeResult -State 'Unexpected output'),
        (New-ProbeResult -State ([pscustomobject]@{ Hash = 'INCOMPLETE' }))
    )) {
    Invoke-TestScenario -Results @($invalid)
    Assert-True (-not $script:StagingContinued -and $script:RecoveryCalls.Count -eq 0) 'Missing or malformed inspection output was accepted as guest state.'
    $failures = @($script:Logs | Where-Object Failure)
    Assert-True ($failures.Count -eq 1 -and $failures[0].Message -like '*No valid DSC module state*') 'Malformed inspection output did not fail explicitly.'
}

$unsuccessful = New-ProbeResult -State $state -ErrorDetail 'Inspection did not complete'
$unsuccessful.CommandResult = $false
Invoke-TestScenario -Results @($unsuccessful)
Assert-True (-not $script:StagingContinued -and @($script:Logs | Where-Object Failure).Count -eq 1) 'Valid-looking output bypassed the failed command result.'

Invoke-TestScenario -Results @($broken) -Phase 8
Assert-True (-not $script:StagingContinued -and $script:RecoveryCalls.Count -eq 0) 'DSC staging introduced automatic readiness reboots outside Phase 2.'

Write-Host "PASS -- DSC staging readiness and bounded Phase 2 recovery ($script:Assertions assertions)."
