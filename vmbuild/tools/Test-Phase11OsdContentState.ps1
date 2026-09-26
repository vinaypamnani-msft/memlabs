<#
.SYNOPSIS
    Verifies which OSD content states may pass final functional validation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$validationPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($validationPath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.Validation.Functional.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$validationText = Get-Content -LiteralPath $validationPath -Raw
if ($validationText -match "Name='OSD DPS'[^\r\n]*Select-Object -First 1") {
    throw "Phase 11 validates only the first same-name 'OSD DPS' object."
}
if (-not $validationText.Contains('Get-MemLabsDistributionPointGroupValidationState -Namespace $ns -SiteCode $sc -GroupName ''OSD DPS''')) {
    throw "Phase 11 does not use the duplicate-safe DP-group validation helper."
}

$stateHelpers = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MemLabsContentDistributionStateKind'
        }, $true))
if ($stateHelpers.Count -ne 1) {
    throw "Expected one Get-MemLabsContentDistributionStateKind definition; found $($stateHelpers.Count)."
}
Invoke-Expression $stateHelpers[0].Extent.Text

$stateCalls = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-MemLabsContentDistributionStateKind'
        }, $true))
if ($stateCalls.Count -ne 2) {
    throw "Expected boot-image and OS-package state classifier calls; found $($stateCalls.Count)."
}
function Get-EnclosingScriptBlockExpression {
    param($Node)
    for ($ancestor = $Node.Parent; $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $ancestor }
    }
}
$helperScope = Get-EnclosingScriptBlockExpression $stateHelpers[0]
foreach ($stateCall in $stateCalls) {
    $callScope = Get-EnclosingScriptBlockExpression $stateCall
    if (-not $helperScope -or -not $callScope -or $helperScope.Extent.StartOffset -ne $callScope.Extent.StartOffset) {
        throw 'The content-state helper is not defined inside the same remoted guest scriptblock as every call site.'
    }
}

$expected = @{
    0 = 'Installed'
    1 = 'Pending'
    2 = 'Problem'
    3 = 'Problem'
    4 = 'Problem'
    5 = 'Problem'
    6 = 'Problem'
    7 = 'Pending'
    8 = 'Problem'
}
foreach ($state in 0..8) {
    $actual = Get-MemLabsContentDistributionStateKind -State $state
    if ($actual -ne $expected[$state]) {
        throw "State $state classified as '$actual'; expected '$($expected[$state])'."
    }
}

if (-not $validationText.Contains('for ($pendingTry = 1; $pendingTry -le 10')) {
    throw 'Required boot-image pending states have no bounded convergence wait.'
}
if ($validationText -notmatch 'bootPendingWaitTimedOut[\s\S]{0,800}requiredOsdCoverageProblems \+= "\$pendingDetail still pending') {
    throw 'A required boot-image DP that remains pending after the wait does not fail coverage.'
}

Write-Host "PASS -- shared remoted classifier: Installed=0, pending=1/7, problems=2/3/4/5/6/8"
