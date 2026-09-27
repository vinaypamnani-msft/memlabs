<#
.SYNOPSIS
    Verifies that Phase 11 allows cross-forest client registration to converge.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.Validation.Functional.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$registrationBlocks = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$regCheckBlock'
        }, $true))
if ($registrationBlocks.Count -ne 1) {
    throw "Expected one cross-forest registration block; found $($registrationBlocks.Count)."
}
$text = $registrationBlocks[0].Right.Extent.Text
foreach ($required in @(
        '$registrationAttempts = 13',
        'Start-Sleep -Seconds 10',
        'while ($registrationAttempt -lt $registrationAttempts)',
        'after $([int](($registrationAttempt - 1) * 10))s of polling',
        'Client has no registration GUID after')) {
    if (-not $text.Contains($required)) {
        throw "Cross-forest registration polling is missing: $required"
    }
}

$sleepCommands = @($registrationBlocks[0].Right.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Start-Sleep'
        }, $true))
if ($sleepCommands.Count -ne 1) {
    throw "Expected one bounded registration-poll sleep; found $($sleepCommands.Count)."
}

Write-Host 'PASS -- Phase 11 polls cross-forest site assignment and registration for up to two minutes.'
