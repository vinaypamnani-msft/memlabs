<#
.SYNOPSIS
    Verifies Start-Test family history and cross-revision history wiring.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$startTestPath = Join-Path $RootPath 'Start-Test.ps1'
$runnerPath = Join-Path $RootPath 'tools\Invoke-MainToDevelopExpansionTest.ps1'
$continuousPath = Join-Path $RootPath 'tools\Invoke-MemLabsContinuousTests.ps1'
$attachedPath = Join-Path $RootPath 'tools\Common.AttachedProcess.ps1'
. (Join-Path $RootPath 'tools\Common.TestHistory.ps1')

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) { throw "Expected one $Name definition, found $($functions.Count)." }
    [scriptblock]::Create($functions[0].Extent.Text)
}
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") { throw "$Message`nExpected: $Expected`nActual:   $Actual" }
}

. (Import-TestFunction -Path $startTestPath -Name 'Invoke-RecordedTestFamily')
. (Import-TestFunction -Path $attachedPath -Name 'Initialize-MemLabsJobObjectType')
. (Import-TestFunction -Path $attachedPath -Name 'Invoke-MemLabsAttachedPowerShell')
$script:StartTestVmbuildRoot = $RootPath
$script:MockRunResult = $true
function Run-Test { param([string] $Test) return [bool]$script:MockRunResult }

$testRoot = Join-Path $env:TEMP "memlabs-history-test-$PID"
$historyPath = Join-Path $testRoot 'history.jsonl'
$null = New-Item -ItemType Directory -Path $testRoot -Force
$oldHistoryPath = $env:MEMLABS_TEST_HISTORY_PATH
try {
    $env:MEMLABS_TEST_HISTORY_PATH = $historyPath
    Assert-True (Invoke-RecordedTestFamily -Family 'NOCM' -SuiteName 'Core') 'Successful family wrapper returned failure.'
    $events = @(Read-MemLabsTestHistory -Path $historyPath)
    Assert-Equal 2 $events.Count 'Successful family did not write start and completion events.'
    Assert-Equal 'RunStarted' $events[0].EventType 'First history event is not RunStarted.'
    Assert-Equal 'RunCompleted' $events[1].EventType 'Second history event is not RunCompleted.'
    Assert-Equal 'Standard|NOCM' $events[1].CandidateKey 'History candidate key changed unexpectedly.'
    Assert-True ([bool]$events[1].Success) 'Successful family history was recorded as failed.'
    Assert-True ("$($events[1].Commit)" -match '^[0-9a-f]{40}$') 'History did not record a commit ID.'

    $script:MockRunResult = $false
    Assert-True (-not (Invoke-RecordedTestFamily -Family 'NOCM')) 'Failed family wrapper returned success.'
    $events = @(Read-MemLabsTestHistory -Path $historyPath)
    $failure = $events | Where-Object EventType -eq 'RunCompleted' | Select-Object -Last 1
    Assert-True (-not [bool]$failure.Success) 'Failed family history was recorded as successful.'
    Assert-True ([bool]$failure.NeedsRerun) 'Failed family did not request rerun priority.'

    $runnerSource = Get-Content -LiteralPath $runnerPath -Raw
    Assert-True ($runnerSource.Contains('CandidateKey = "CrossRevision|$family"')) `
        'Cross-revision runner does not record family history.'
    Assert-True ($runnerSource.Contains("EventType = 'RunCompleted'")) `
        'Cross-revision runner does not record completion events.'

    $continuousSource = Get-Content -LiteralPath $continuousPath -Raw
    $attachedSource = Get-Content -LiteralPath $attachedPath -Raw
    Assert-True (-not ($continuousSource -match 'Start-Process|nohup|disown|detach\s*=')) `
        'Continuous scheduler contains detached-process behavior.'
    Assert-True ($attachedSource.Contains('JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE')) `
        'Continuous scheduler does not bind children to a kill-on-close Job Object.'
    Assert-True ($continuousSource.Contains('Invoke-MemLabsAttachedPowerShell -Arguments $arguments')) `
        'Continuous scheduler does not use its attached child launcher.'
    Assert-True ($continuousSource.Contains("@('-DevelopRevision', `$candidate.CurrentCommit)")) `
        'Continuous scheduler does not pin the selected develop commit.'
    Assert-True ($continuousSource.Contains('exit 57')) `
        'Continuous scheduler does not request a foreground reload after source advances.'
    $startTestSource = Get-Content -LiteralPath $startTestPath -Raw
    Assert-True ($startTestSource.Contains('while ($continuousExit -eq 57)')) `
        'Start-Test does not reload continuous mode after source advances.'
    if ($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSEdition -eq 'Core') {
        $attachedExit = Invoke-MemLabsAttachedPowerShell -Arguments @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 7'
        )
        Assert-Equal 7 $attachedExit 'Attached child launcher did not return the child exit code.'
        $nestedCommand = ". '$attachedPath'; exit (Invoke-MemLabsAttachedPowerShell -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-Command','exit 9'))"
        $nestedExit = Invoke-MemLabsAttachedPowerShell -Arguments @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $nestedCommand
        )
        Assert-Equal 9 $nestedExit 'Nested attached launchers did not preserve child exit semantics.'
    }

    Write-Host 'PASS -- Start-Test records commit-aware family history and continuous children remain attached.'
}
finally {
    if ($oldHistoryPath) { $env:MEMLABS_TEST_HISTORY_PATH = $oldHistoryPath }
    else { Remove-Item Env:MEMLABS_TEST_HISTORY_PATH -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
