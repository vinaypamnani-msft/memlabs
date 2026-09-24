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

$installedConditions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            @($node.Clauses | Where-Object { $_.Item1.Extent.Text -match '^\s*\$osState\s+-eq\s+0\s*$' }).Count -eq 1
        }, $true))
$pendingConditions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            @($node.Clauses | Where-Object { $_.Item1.Extent.Text -match '^\s*\$osState\s+-in\s+' }).Count -eq 1 -and
            $node.Extent.Text -match '\$osPkgPending' -and
            $node.Extent.Text -match '\$osPkgProblems'
        }, $true))
if ($installedConditions.Count -ne 1 -or $pendingConditions.Count -ne 1) {
    throw "Expected one installed and one pending OSD state condition; found installed=$($installedConditions.Count), pending=$($pendingConditions.Count)."
}

$installedExpression = $installedConditions[0].Clauses[0].Item1.Extent.Text
$pendingExpression = $pendingConditions[0].Clauses[0].Item1.Extent.Text
$classify = [scriptblock]::Create(@"
param([int]`$osState)
if ($installedExpression) { return 'installed' }
if ($pendingExpression) { return 'pending' }
return 'problem'
"@)

$expected = @{
    0 = 'installed'
    1 = 'pending'
    2 = 'problem'
    3 = 'problem'
    4 = 'problem'
    5 = 'problem'
    6 = 'problem'
    7 = 'pending'
    8 = 'problem'
}
foreach ($state in 0..8) {
    $actual = & $classify $state
    if ($actual -ne $expected[$state]) {
        throw "State $state classified as '$actual'; expected '$($expected[$state])'."
    }
}

Write-Host "PASS -- Installed=0, transient=1/7, problems=2/3/4/5/6/8"
