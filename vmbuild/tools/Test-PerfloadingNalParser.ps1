<#
.SYNOPSIS
    Verifies that perfloading parses ConfigMgr DP NAL paths through a named function.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$perfloadingPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\perfloading.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($perfloadingPath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "perfloading.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$helperDefinitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MemLabsServerFromNalPath'
        }, $true))
if ($helperDefinitions.Count -ne 1) {
    throw "Expected one Get-MemLabsServerFromNalPath definition; found $($helperDefinitions.Count)."
}

$legacyVariableReferences = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.UserPath -eq 'serverFromNal'
        }, $true))
if ($legacyVariableReferences.Count -gt 0) {
    throw "Found $($legacyVariableReferences.Count) mutable `$serverFromNal reference(s)."
}

$helperCalls = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-MemLabsServerFromNalPath'
        }, $true))
if ($helperCalls.Count -ne 6) {
    throw "Expected six production NAL parser calls; found $($helperCalls.Count)."
}

Invoke-Expression $helperDefinitions[0].Extent.Text

$serverFromNal = 'deliberately not callable'
$cases = @(
    [pscustomobject]@{
        Name     = 'DP group member NAL'
        Input    = '["Display=\\BI-SOURCE.burnin.sandwich.lab\"]MSWNET:["SMS_SITE=PRI"]\\BI-SOURCE.burnin.sandwich.lab\'
        Expected = 'BI-SOURCE.burnin.sandwich.lab'
    }
    [pscustomobject]@{
        Name     = 'UNC-style server NAL'
        Input    = '\\BI-SOURCE.burnin.sandwich.lab\'
        Expected = 'BI-SOURCE.burnin.sandwich.lab'
    }
    [pscustomobject]@{
        Name     = 'empty NAL'
        Input    = ''
        Expected = $null
    }
)

foreach ($case in $cases) {
    $actual = Get-MemLabsServerFromNalPath $case.Input
    if ($actual -ne $case.Expected) {
        throw "$($case.Name): expected '$($case.Expected)', got '$actual'."
    }
}
if ($serverFromNal -ne 'deliberately not callable') {
    throw 'The legacy variable poison value changed during named-function calls.'
}

Write-Host "PASS -- helper definitions=1, production calls=$($helperCalls.Count), NAL cases=$($cases.Count), mutable helper references=0"
