<#
.SYNOPSIS
    Rejects New-Lab parameter/global name collisions under pwsh -File.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$newLabPath = Join-Path $RootPath 'New-Lab.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($newLabPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "$newLabPath has parse errors: $($errors -join '; ')" }

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$collisions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -match '^global:(.+)$'
        }, $true) | Where-Object {
        $_.Left.VariablePath.UserPath -match '^global:(.+)$' -and
        $parameterNames -contains $Matches[1]
    })
if ($collisions.Count -gt 0) {
    throw "New-Lab reuses parameter names in global scope: $($collisions.Extent.Text -join '; ')"
}

$newLabText = Get-Content -LiteralPath $newLabPath -Raw
$phaseText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Phases.ps1') -Raw
$validationText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Validation.ps1') -Raw
if ($newLabText -notmatch '\$global:MemLabsNoSnapshot\s*=\s*\[bool\]\$NoSnapshot\.IsPresent') {
    throw 'New-Lab does not publish NoSnapshot under a non-parameter global name.'
}
if ($newLabText -notmatch '\$global:MemLabsSkipValidation\s*=\s*\[bool\]\$SkipValidation\.IsPresent') {
    throw 'New-Lab does not publish SkipValidation under a non-parameter global name.'
}
if ($phaseText -notmatch '\$global:MemLabsNoSnapshot' -or $phaseText -match '\$global:NoSnapshot') {
    throw 'Phase orchestration does not consume only the non-colliding snapshot global.'
}
if ($validationText -notmatch '\$global:MemLabsSkipValidation' -or $validationText -match '\$global:SkipValidation') {
    throw 'Configuration validation does not consume only the non-colliding validation global.'
}

Write-Host 'PASS -- New-Lab publishes parameter state without pwsh -File global-name collisions.'
