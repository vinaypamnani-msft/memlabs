<#
.SYNOPSIS
    Verifies guest script boundaries reclaim memory and propagate critical failures.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'

function Import-TestFunction {
    param([string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $sourcePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) {
        throw "Expected one $Name definition, found $($definition.Count)."
    }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

$global:TestGuestBoundaryStatuses = [System.Collections.Generic.List[string]]::new()
$global:TestGuestBoundaryFailureStatuses = [System.Collections.Generic.List[string]]::new()
function Write-DscStatus {
    param($Status, [switch] $NoStatus, [switch] $Failure, [switch] $Warning)
    $global:TestGuestBoundaryStatuses.Add("$Status")
    if ($Failure) {
        $global:TestGuestBoundaryFailureStatuses.Add("$Status")
        $global:MemLabsFailureSequence = [int]$global:MemLabsFailureSequence + 1
        $global:MemLabsLastFailureStatus = "$Status"
    }
}

. (Import-TestFunction -Name 'Invoke-MemLabsGuestMemoryReclaim')
$reclaimResult = Invoke-MemLabsGuestMemoryReclaim -Context 'fixture'
if ($reclaimResult.Context -ne 'fixture' -or
    $reclaimResult.ManagedBeforeMb -lt 0 -or
    $reclaimResult.ManagedAfterMb -lt 0 -or
    -not ($global:TestGuestBoundaryStatuses -match '\[MemoryReclaim\] fixture')) {
    throw 'Guest managed-memory reclaim did not report its measured boundary.'
}

$script:ReclaimCalls = 0
function Invoke-MemLabsGuestMemoryReclaim {
    param([string] $Context)
    $script:ReclaimCalls++
    return [pscustomobject]@{ Context = $Context }
}
function Get-CmSslStateNote { return '' }
. (Import-TestFunction -Name 'Invoke-DotSource')
. (Import-TestFunction -Name 'Test-MemLabsOutOfMemoryError')
. (Import-TestFunction -Name 'Get-MemLabsExceptionSummary')
. (Import-TestFunction -Name 'Write-MemLabsExceptionDetails')
. (Import-TestFunction -Name 'Write-StatusLogEntry')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-guest-memory-$PID"
$oomScript = Join-Path $testRoot 'Oom.ps1'
$healthyScript = Join-Path $testRoot 'Healthy.ps1'
$fatalScript = Join-Path $testRoot 'Fatal.ps1'
$reportedFailureScript = Join-Path $testRoot 'ReportedFailure.ps1'
$nestedScript = Join-Path $testRoot 'Nested.ps1'
$previousStatusLog = $global:StatusLog
$global:StatusLog = Join-Path $testRoot 'InstallCMLog.log'
try {
    $null = New-Item -ItemType Directory -Path $testRoot -Force
    [IO.File]::WriteAllText(
        $oomScript,
        "throw [System.OutOfMemoryException]::new('synthetic guest OOM')",
        [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText(
        $healthyScript,
        "'healthy' | Out-Null",
        [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText(
        $fatalScript,
        "throw [System.InvalidOperationException]::new('synthetic critical failure')",
        [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText(
        $reportedFailureScript,
        "Write-DscStatus 'synthetic reported failure' -Failure",
        [Text.UTF8Encoding]::new($true))
    $nestedSource = @'
$identity = 'System.Text.Json, Version=8.0.0.6, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51'
$inner = [IO.FileNotFoundException]::new("Could not load file or assembly '$identity'.", $identity)
throw [InvalidOperationException]::new("Unable to build the 'Tables' collection.", $inner)
'@
    [IO.File]::WriteAllText($nestedScript, $nestedSource, [Text.Encoding]::ASCII)

    Invoke-DotSource -Script $oomScript
    if ($script:ReclaimCalls -ne 1) {
        throw 'Invoke-DotSource did not reclaim memory after a guest OutOfMemoryException.'
    }
    Invoke-DotSource -Script $healthyScript
    if ($script:ReclaimCalls -ne 1) {
        throw 'A short healthy guest script triggered unnecessary forced memory reclamation.'
    }

    $criticalFailurePropagated = $false
    try {
        Invoke-DotSource -Script $fatalScript -Rethrow
    }
    catch {
        $criticalFailurePropagated = $_.Exception.Message -eq 'synthetic critical failure'
    }
    if (-not $criticalFailurePropagated) {
        throw 'Invoke-DotSource -Rethrow swallowed a critical guest script failure.'
    }
    if ($global:TestGuestBoundaryFailureStatuses.Count -ne 1 -or
        $global:TestGuestBoundaryFailureStatuses[0] -notmatch 'FAILED: exception in Fatal\.ps1.+synthetic critical failure') {
        throw 'Invoke-DotSource -Rethrow did not publish the critical failure through Write-DscStatus -Failure.'
    }

    $callerOwnedFailurePropagated = $false
    try {
        Invoke-DotSource -Script $fatalScript -Rethrow -CallerOwnsRetry
    }
    catch {
        $callerOwnedFailurePropagated = $_.Exception.Message -eq 'synthetic critical failure'
    }
    if (-not $callerOwnedFailurePropagated) {
        throw 'Invoke-DotSource -CallerOwnsRetry swallowed a retryable guest script failure.'
    }
    if ($global:TestGuestBoundaryFailureStatuses.Count -ne 1) {
        throw 'A caller-owned retry published a premature JOBFAILURE.'
    }
    if (-not ($global:TestGuestBoundaryStatuses -match 'WARNING: exception in Fatal\.ps1.+synthetic critical failure')) {
        throw 'A caller-owned retry did not preserve the retryable exception as a warning.'
    }

    $reportedFailurePropagated = $false
    $reportedFailureError = ''
    try {
        Invoke-DotSource -Script $reportedFailureScript
    }
    catch {
        $reportedFailureError = $_.Exception.Message
        $reportedFailurePropagated = $reportedFailureError -match 'Critical guest script reported a failure without throwing'
    }
    if (-not $reportedFailurePropagated) {
        throw "Invoke-DotSource accepted a script that reported -Failure and returned. Error='$reportedFailureError'; sequence=$global:MemLabsFailureSequence; last='$global:MemLabsLastFailureStatus'."
    }
    if ($global:TestGuestBoundaryFailureStatuses.Count -ne 2 -or
        $global:TestGuestBoundaryFailureStatuses[1] -ne 'synthetic reported failure') {
        throw 'A reported guest failure was not preserved as the authoritative JOBFAILURE status.'
    }

    $nestedFailure = $null
    try { Invoke-DotSource -Script $nestedScript -Rethrow }
    catch { $nestedFailure = $_ }
    if (-not $nestedFailure -or $nestedFailure.Exception.GetBaseException() -isnot [IO.FileNotFoundException]) {
        throw 'The nested assembly failure was not preserved when rethrown.'
    }
    $identity = 'System.Text.Json, Version=8.0.0.6, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51'
    $summary = $global:TestGuestBoundaryFailureStatuses[$global:TestGuestBoundaryFailureStatuses.Count - 1]
    if (-not $summary.Contains($identity) -or $summary.IndexOf('System.IO.FileNotFoundException') -gt
        $summary.IndexOf('System.InvalidOperationException')) {
        throw 'The host-visible failure summary hid the nested assembly cause behind the generic wrapper.'
    }
    $log = [IO.File]::ReadAllText($global:StatusLog)
    foreach ($detail in @($identity, "Unable to build the 'Tables' collection.", 'End of inner exception stack trace',
            'Error ID:', 'Position:', 'PowerShell stack:', 'Nested.ps1')) {
        if (-not $log.Contains($detail)) { throw "The automatically collected guest log lost '$detail'." }
    }
    $longOuter = [InvalidOperationException]::new(('wrapper ' * 1000), $nestedFailure.Exception.GetBaseException())
    $boundedSummary = (Get-MemLabsExceptionSummary -Exception $longOuter).Substring(0, 4000)
    if (-not $boundedSummary.Contains($identity)) { throw 'A bounded failure receipt lost the root cause.' }

    $logLength = $log.Length
    $failureCount = $global:TestGuestBoundaryFailureStatuses.Count
    try { Invoke-DotSource -Script $nestedScript -Rethrow -CallerOwnsRetry }
    catch {
        if ($_.Exception.GetBaseException() -isnot [IO.FileNotFoundException]) { throw }
    }
    $retryLog = [IO.File]::ReadAllText($global:StatusLog).Substring($logLength)
    if (-not $retryLog.Contains($identity) -or $retryLog.Contains('type="3"') -or
        $global:TestGuestBoundaryFailureStatuses.Count -ne $failureCount) {
        throw 'Detailed retry diagnostics either lost the cause or published a premature error.'
    }

    $workflowPath = Join-Path $RootPath 'DSC\phases\ScriptWorkFlow.ps1'
    $tokens = $null
    $errors = $null
    $workflowAst = [Management.Automation.Language.Parser]::ParseFile(
        $workflowPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Workflow parse errors: $($errors -join '; ')" }
    $traps = @($workflowAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.TrapStatementAst]
            }, $true))
    if ($traps.Count -ne 1) { throw 'Expected one terminal workflow trap.' }
    $global:TestGuestBoundaryTrapReceipt = ''
    $global:TestGuestBoundaryTrapBreadcrumb = ''
    $trapScript = Join-Path $testRoot 'Trap.ps1'
    $trapFixture = @'
$ScriptWorkflowRunId = 'fixture-run'
function Out-File {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$FilePath, [switch]$Force)
    process { $global:TestGuestBoundaryTrapBreadcrumb = "$InputObject" }
}
function Write-ScriptWorkflowFailureReceipt {
    param([string]$RunId, [string]$Message)
    $global:TestGuestBoundaryTrapReceipt = $Message
}
__TRAP__
__NESTED__
'@
    [IO.File]::WriteAllText(
        $trapScript, $trapFixture.Replace('__TRAP__', $traps[0].Extent.Text).Replace('__NESTED__', $nestedSource),
        [Text.Encoding]::ASCII)
    $trapFailure = $null
    try { & $trapScript }
    catch { $trapFailure = $_ }
    if (-not $trapFailure -or $trapFailure.Exception.GetBaseException() -isnot [IO.FileNotFoundException]) {
        throw 'The workflow trap did not preserve the terminal assembly failure.'
    }
    if (-not $global:TestGuestBoundaryTrapReceipt.Contains($identity) -or
        -not $global:TestGuestBoundaryTrapBreadcrumb.Contains($identity)) {
        throw 'The terminal receipt or pre-state-file breadcrumb lost the nested assembly cause.'
    }
    $rootEntries = @(Get-Content -LiteralPath $global:StatusLog | Where-Object {
            $_.Contains($identity) -and $_.Contains('component="ScriptWorkflow"') -and $_.Contains('type="3"')
        })
    if ($rootEntries.Count -eq 0) { throw 'The workflow trap did not automatically log the full nested exception.' }
}
finally {
    $global:StatusLog = $previousStatusLog
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
if ($sourceText -notmatch
    '(?s)\$__idsStopwatch\.Elapsed\.TotalMinutes -ge 15.+?Invoke-MemLabsGuestMemoryReclaim') {
    throw 'Long-running guest scripts no longer reclaim their child-scope object graph.'
}
if ($sourceText -notmatch
    '(?s)\$__idsStack.+?ScriptStackTrace.+?Length -gt 1200.+?stack=\$__idsStack') {
    throw 'Guest script boundary failures no longer preserve a bounded producer stack.'
}

$workflowText = Get-Content -LiteralPath (
    Join-Path $RootPath 'DSC\phases\ScriptWorkFlow.ps1') -Raw
$criticalBoundaryPatterns = @{
    'InstallAndUpdateSCCM.ps1' = 2
    'InstallPSForHierarchy.ps1' = 1
    'InstallRoles.ps1' = 3
}
foreach ($entry in $criticalBoundaryPatterns.GetEnumerator()) {
    $scriptName = [regex]::Escape($entry.Key)
    $pattern = '(?s)\$ScriptFile\s*=\s*Join-Path.+?"' + $scriptName +
        '".{0,250}?Invoke-DotSource\s+-Script\s+\$ScriptFile\s+-Arguments\s+\$ConfigFilePath,\s*\$LogPath\s+-Rethrow'
    $boundaryMatches = [regex]::Matches($workflowText, $pattern)
    if ($boundaryMatches.Count -ne $entry.Value) {
        throw "$($entry.Key) has $($boundaryMatches.Count) fail-fast workflow boundary call(s); expected $($entry.Value)."
    }
}
if ($workflowText -notmatch
    '(?s)\$perfMaxAttempts\s*=\s*3.+?Invoke-DotSource\s+-Script\s+\$ScriptFile\s+-Arguments\s+\$ConfigFilePath,\s*\$LogPath\s+-Rethrow\s+-CallerOwnsRetry') {
    throw 'The perfloading retry loop can publish a premature JOBFAILURE before exhausting its retries.'
}
if ($workflowText -notmatch
    '(?s)Perfloading\.ps1 did not complete after \$perfMaxAttempts attempts.+?-Failure\s+return') {
    throw 'Perfloading retry exhaustion can report Phase 8 success with incomplete pre-population.'
}

$coverageText = Get-Content -LiteralPath (
    Join-Path $RootPath 'DSC\phases\InstallBoundaryGroups.ps1') -Raw
if ($coverageText -notmatch
    '(?s)Invoke-CMSystemDiscovery.+?Invoke-MemLabsGuestMemoryReclaim.+?InstallBoundaryGroups before client package coverage.+?& \$ensureClientPkgCoverage') {
    throw 'Client package coverage no longer reclaims earlier ConfigMgr provider graphs before its first query.'
}

Write-Host 'PASS -- guest script boundaries reclaim memory and propagate critical failures.'
