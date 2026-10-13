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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-guest-memory-$PID"
$oomScript = Join-Path $testRoot 'Oom.ps1'
$healthyScript = Join-Path $testRoot 'Healthy.ps1'
$fatalScript = Join-Path $testRoot 'Fatal.ps1'
$reportedFailureScript = Join-Path $testRoot 'ReportedFailure.ps1'
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
}
finally {
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
    $matches = [regex]::Matches($workflowText, $pattern)
    if ($matches.Count -ne $entry.Value) {
        throw "$($entry.Key) has $($matches.Count) fail-fast workflow boundary call(s); expected $($entry.Value)."
    }
}

$coverageText = Get-Content -LiteralPath (
    Join-Path $RootPath 'DSC\phases\InstallBoundaryGroups.ps1') -Raw
if ($coverageText -notmatch
    '(?s)Invoke-CMSystemDiscovery.+?Invoke-MemLabsGuestMemoryReclaim.+?InstallBoundaryGroups before client package coverage.+?& \$ensureClientPkgCoverage') {
    throw 'Client package coverage no longer reclaims earlier ConfigMgr provider graphs before its first query.'
}

Write-Host 'PASS -- guest script boundaries reclaim memory and propagate critical failures.'
