<#
.SYNOPSIS
    Verifies forced orphan cleanup never disposes in-flight PowerShell work.
#>
[CmdletBinding()]
param([string]$RootPath, [switch]$ChildExitProbe, [string]$ExitMarkerPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'Common.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "$sourcePath has parse errors: $($parseErrors -join '; ')" }
$definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Clear-OrphanRunspaces'
        }, $true))
if ($definition.Count -ne 1) { throw 'Expected one Clear-OrphanRunspaces definition.' }
. ([scriptblock]::Create($definition[0].Extent.Text))

$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

function Reset-TestState {
    $global:ps_orphanRunspaces = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new())
    $script:Messages = [Collections.Generic.List[object]]::new()
    $script:Stats = @{ byCaller = @{ fixture = 100 } }
}

function Write-Log {
    param([string]$Message, [switch]$Warning, [switch]$LogOnly)
    $script:Messages.Add([pscustomobject]@{ Text = $Message; Warning = $Warning.IsPresent })
}
function Get-VmSessionStats { return $script:Stats }
function Remove-PSSession {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Session)
    $Session.Trace.Add('session.Remove')
}
function Write-VmJobLedger {
    param($Op, $Job, $VmName, $DisplayName, $Detail)
    $Job.Trace.Add('job.reaped')
}
function Remove-Job {
    [CmdletBinding()]
    param($Job, [switch]$Force)
    $Job.Trace.Add('job.Remove')
}

function New-TestOrphan {
    param(
        [string]$InvocationState = 'Completed',
        [string]$JobState = 'Completed',
        [string]$Availability = 'Available',
        [int]$AgeSeconds = 180,
        [switch]$WithoutPowerShell
    )
    $trace = [Collections.Generic.List[string]]::new()
    $ps = [pscustomobject]@{
        InvocationStateInfo = [pscustomobject]@{ State = $InvocationState }
        Trace = $trace
    }
    $ps | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Trace.Add('ps.Dispose') }
    $rs = [pscustomobject]@{ RunspaceAvailability = $Availability; Trace = $trace }
    $rs | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Trace.Add('rs.Close') }
    $rs | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Trace.Add('rs.Dispose') }
    $job = if ($JobState) { [pscustomobject]@{ State = $JobState; Trace = $trace } } else { $null }
    $entry = [pscustomobject]@{
        Rs = $rs
        Ps = if ($WithoutPowerShell) { $null } else { $ps }
        Sess = [pscustomobject]@{ _CallerTag = 'fixture'; Trace = $trace }
        Job = $job
        At = (Get-Date).AddSeconds(-$AgeSeconds)
        VmName = 'LAB-FS1'
        Reason = 'fixture'
    }
    [void]$global:ps_orphanRunspaces.Add($entry)
    return [pscustomobject]@{ Entry = $entry; Trace = $trace }
}

function New-BlockedInvocation {
    param([int]$Milliseconds)
    $entered = [Threading.ManualResetEvent]::new($false)
    $rs = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
            param($signal, $delay)
            $null = $signal.Set()
            [Threading.Thread]::Sleep($delay)
        }).AddArgument($entered).AddArgument($Milliseconds)
    $pending = $ps.BeginInvoke()
    if (-not $entered.WaitOne(10000)) { throw 'Blocked-invocation fixture did not start.' }
    $null = $ps.BeginStop($null, $null)
    Assert-True ("$($ps.InvocationStateInfo.State)" -eq 'Stopping') 'Fixture did not reproduce an invocation stuck in Stopping.'
    $entry = [pscustomobject]@{
        Rs = $rs; Ps = $ps; Sess = $null; Job = $null
        At = (Get-Date).AddMinutes(-10); VmName = 'LAB-FS1'; Reason = 'blocked connect fixture'
    }
    [void]$global:ps_orphanRunspaces.Add($entry)
    return [pscustomobject]@{ Entry = $entry; Pending = $pending; Signal = $entered }
}

Reset-TestState
if ($ChildExitProbe) {
    $fixture = New-BlockedInvocation -Milliseconds 60000
    $reclaimed = Clear-OrphanRunspaces -Force
    Assert-True ($reclaimed -eq 0 -and $global:ps_orphanRunspaces.Count -eq 1 -and
        -not $fixture.Pending.IsCompleted) 'Pinned child did not leave its blocked invocation parked.'
    $global:OrphanExitMarkerPath = $ExitMarkerPath
    Register-EngineEvent -SourceIdentifier ([Management.Automation.PsEngineEvent]::Exiting) -Action {
        [IO.File]::AppendAllText($global:OrphanExitMarkerPath, "exit-flush`r`n")
    } | Out-Null
    $global:LASTEXITCODE = 23
    return
}

foreach ($force in @($false, $true)) {
    foreach ($state in @('Running', 'Stopping', 'Disconnected', 'Unknown', '')) {
        Reset-TestState
        $fixture = New-TestOrphan -InvocationState $state -JobState ''
        $reclaimed = Clear-OrphanRunspaces -Force:$force
        Assert-True ($reclaimed -eq 0 -and $fixture.Trace.Count -eq 0 -and
            $global:ps_orphanRunspaces.Count -eq 1) "Invocation state '$state' was disposed (force=$force), despite Available runspace."
        Assert-True (@($script:Messages | Where-Object { $_.Text -like 'Deferred 1 orphaned*' }).Count -eq 1) 'Deferred invocation was not reported.'
    }
    foreach ($state in @('Running', 'Stopping', 'Suspended', 'Disconnected', 'NotStarted', 'Unknown')) {
        Reset-TestState
        $fixture = New-TestOrphan -WithoutPowerShell -JobState $state
        $reclaimed = Clear-OrphanRunspaces -Force:$force
        Assert-True ($reclaimed -eq 0 -and $fixture.Trace.Count -eq 0 -and
            $global:ps_orphanRunspaces.Count -eq 1) "Nonterminal job '$state' was reaped (force=$force)."
    }
    Reset-TestState
    $fixture = New-TestOrphan -Availability 'Busy'
    $reclaimed = Clear-OrphanRunspaces -Force:$force
    Assert-True ($reclaimed -eq 0 -and $fixture.Trace.Count -eq 0) "Busy runspace was closed (force=$force)."
}

foreach ($state in @('NotStarted', 'Completed', 'Failed', 'Stopped')) {
    foreach ($jobState in @('Completed', 'Failed', 'Stopped')) {
        Reset-TestState
        $fixture = New-TestOrphan -InvocationState $state -JobState $jobState
        $reclaimed = Clear-OrphanRunspaces -Force
        Assert-True ($reclaimed -is [int] -and $reclaimed -eq 1 -and
            $global:ps_orphanRunspaces.Count -eq 0) "Terminal invocation/job '$state/$jobState' was not reclaimed."
        Assert-True (($fixture.Trace -join ',') -eq 'ps.Dispose,session.Remove,rs.Close,rs.Dispose,job.reaped,job.Remove') 'Terminal cleanup order changed.'
        Assert-True ($script:Stats.byCaller.fixture -eq 99) 'Reclaimed session did not update the caller ledger.'
    }
}

Reset-TestState
$fixture = New-TestOrphan -AgeSeconds 0
Assert-True ((Clear-OrphanRunspaces) -eq 0 -and $fixture.Trace.Count -eq 0) 'Normal cleanup bypassed the minimum age.'
Assert-True ((Clear-OrphanRunspaces -Force) -eq 1 -and
    $global:ps_orphanRunspaces.Count -eq 0) 'Force did not reclaim a young, terminal orphan.'

Reset-TestState
$fixture = New-TestOrphan -WithoutPowerShell -JobState ''
Assert-True ((Clear-OrphanRunspaces) -eq 1 -and
    $global:ps_orphanRunspaces.Count -eq 0) 'Normal cleanup did not reclaim an aged session-only orphan.'
Assert-True (($fixture.Trace -join ',') -eq 'session.Remove,rs.Close,rs.Dispose') 'Session-only cleanup attempted missing resources or changed disposal order.'

Reset-TestState
$active = New-TestOrphan -InvocationState 'Stopping'
$ready = New-TestOrphan
$reclaimed = Clear-OrphanRunspaces -Force
Assert-True ($reclaimed -eq 1 -and $active.Trace.Count -eq 0 -and
    $ready.Trace.Count -eq 6 -and $global:ps_orphanRunspaces.Count -eq 1 -and
    $global:ps_orphanRunspaces[0] -eq $active.Entry) 'An active entry prevented independent terminal reclamation or was removed.'

Reset-TestState
$fixture = New-TestOrphan
$fixture.Entry.Ps.PSObject.Properties.Remove('InvocationStateInfo')
$fixture.Entry.Ps | Add-Member -MemberType ScriptProperty -Name InvocationStateInfo -Value { throw 'Synthetic state-read failure' }
Assert-True ((Clear-OrphanRunspaces -Force) -eq 0 -and $fixture.Trace.Count -eq 0) 'Unreadable invocation state was treated as safe.'
Assert-True (@($script:Messages | Where-Object { $_.Warning -and $_.Text -like '*leaving it parked*' }).Count -eq 1) 'State-read failure was hidden.'

Reset-TestState
$blocked = New-BlockedInvocation -Milliseconds 5000
$realReclaimed = $false
try {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $reclaimed = Clear-OrphanRunspaces -Force
    $timer.Stop()
    Assert-True ($reclaimed -eq 0 -and -not $blocked.Pending.IsCompleted -and
        $global:ps_orphanRunspaces.Count -eq 1) 'Forced cleanup waited for or disposed the real Stopping invocation.'
    Assert-True ($timer.Elapsed.TotalSeconds -lt 2) 'Forced cleanup did not return within two seconds while native work remained blocked.'
    Assert-True ($blocked.Pending.AsyncWaitHandle.WaitOne(10000)) 'Blocked fixture did not reach a terminal state.'
    $reclaimed = Clear-OrphanRunspaces -Force
    $realReclaimed = $reclaimed -eq 1
    Assert-True ($realReclaimed -and $global:ps_orphanRunspaces.Count -eq 0) 'A previously deferred real invocation was not reclaimed once terminal.'
}
finally {
    if (-not $realReclaimed) {
        if (-not $blocked.Pending.AsyncWaitHandle.WaitOne(10000)) {
            throw 'Blocked fixture did not finish; refusing unsafe synchronous disposal.'
        }
        $blocked.Entry.Ps.Dispose()
        $blocked.Entry.Rs.Close()
        $blocked.Entry.Rs.Dispose()
    }
    $blocked.Signal.Dispose()
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-orphan-exit-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot
$parameterPath = Join-Path $tempRoot 'parameters.clixml'
$resultPath = Join-Path $tempRoot 'result.json'
$stdoutPath = Join-Path $tempRoot 'stdout.txt'
$stderrPath = Join-Path $tempRoot 'stderr.txt'
$exitMarkerPath = Join-Path $tempRoot 'exit-flush.txt'
$child = $null
try {
    @{ RootPath = $RootPath; ChildExitProbe = $true; ExitMarkerPath = $exitMarkerPath } | Export-Clixml -LiteralPath $parameterPath
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
        ('"{0}"' -f (Join-Path $RootPath 'tools\Invoke-PinnedChildScript.ps1')),
        '-ScriptPath', ('"{0}"' -f $PSCommandPath),
        '-ParameterPath', ('"{0}"' -f $parameterPath),
        '-InvocationToken', 'orphan-cleanup-exit-probe',
        '-ResultPath', ('"{0}"' -f $resultPath)
    )
    $child = Start-Process -FilePath (Get-Command pwsh.exe -ErrorAction Stop).Source -ArgumentList $arguments `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    # Windows PowerShell 5.1 needs the handle retained to read ExitCode after exit.
    $null = $child.Handle
    Assert-True ($child.WaitForExit(15000)) 'Pinned child remained alive for 15 seconds with a blocked orphan connection.'
    if ($child.ExitCode -ne 23) {
        throw "Pinned child returned $($child.ExitCode): $(Get-Content -LiteralPath $stderrPath -Raw)"
    }
    Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) 'Pinned child did not publish its structured result.'
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert-True ($result.ExitCode -eq 23 -and $result.InvocationToken -eq 'orphan-cleanup-exit-probe') 'Orphan cleanup lost the original child exit code or invocation identity.'
    Assert-True ((Get-Content -LiteralPath $exitMarkerPath -Raw) -eq "exit-flush`r`n") 'Pinned child skipped or duplicated its normal exit/log-flush actions.'
}
finally {
    if ($child) {
        if (-not $child.HasExited) {
            Stop-Process -Id $child.Id -Force -ErrorAction Stop
            if (-not $child.WaitForExit(5000)) { throw 'Exit-probe child did not terminate.' }
        }
        $child.Dispose()
    }
    foreach ($path in @($parameterPath, $resultPath, $stdoutPath, $stderrPath, $exitMarkerPath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Remove-Item -LiteralPath $tempRoot
}

Write-Host "PASS -- Orphan cleanup preserves active work, reclaims terminal resources, and permits pinned-child exit ($script:Assertions assertions)."
