<#
.SYNOPSIS
    Verifies long-running and OOM guest scripts release managed memory at their process boundary.
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

$script:Statuses = [System.Collections.Generic.List[string]]::new()
function Write-DscStatus {
    param($Status, [switch] $NoStatus)
    $script:Statuses.Add("$Status")
}

. (Import-TestFunction -Name 'Invoke-MemLabsGuestMemoryReclaim')
$reclaimResult = Invoke-MemLabsGuestMemoryReclaim -Context 'fixture'
if ($reclaimResult.Context -ne 'fixture' -or
    $reclaimResult.ManagedBeforeMb -lt 0 -or
    $reclaimResult.ManagedAfterMb -lt 0 -or
    -not ($script:Statuses -match '\[MemoryReclaim\] fixture')) {
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

    Invoke-DotSource -Script $oomScript
    if ($script:ReclaimCalls -ne 1) {
        throw 'Invoke-DotSource did not reclaim memory after a guest OutOfMemoryException.'
    }
    Invoke-DotSource -Script $healthyScript
    if ($script:ReclaimCalls -ne 1) {
        throw 'A short healthy guest script triggered unnecessary forced memory reclamation.'
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

$coverageText = Get-Content -LiteralPath (
    Join-Path $RootPath 'DSC\phases\InstallBoundaryGroups.ps1') -Raw
if ($coverageText -notmatch
    '(?s)Invoke-CMSystemDiscovery.+?Invoke-MemLabsGuestMemoryReclaim.+?InstallBoundaryGroups before client package coverage.+?& \$ensureClientPkgCoverage') {
    throw 'Client package coverage no longer reclaims earlier ConfigMgr provider graphs before its first query.'
}

Write-Host 'PASS -- guest script boundaries reclaim memory after OOM and long-running work.'
