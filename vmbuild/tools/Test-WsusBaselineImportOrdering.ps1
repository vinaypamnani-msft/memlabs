<#
.SYNOPSIS
    Verifies WSUS baseline import cannot invalidate SUP prerequisite checks.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'DSC\phases\InstallRoles.ps1'
$text = Get-Content -LiteralPath $sourcePath -Raw

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }
$helper = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-VerifiedWsusBaselineImport'
        }, $true))
if ($helper.Count -ne 1) {
    throw "Expected one Invoke-VerifiedWsusBaselineImport definition, found $($helper.Count)."
}
$helperText = $helper[0].Extent.Text
if ($helperText -notmatch
    '(?s)Start-WsusBaselineImportBackground.+?Wait-WsusBaselineImport') {
    throw 'WSUS baseline import launch and verification are no longer one ordered operation.'
}
if ($helperText -notmatch
    '(?s)parentSiteCode.+?skipping WSUS cab import.+?return') {
    throw 'Downstream sites can import the Microsoft Update baseline into a replica WSUS.'
}

if (([regex]::Matches($text, 'Start-WsusBaselineImportBackground')).Count -ne 1 -or
    ([regex]::Matches($text, 'Wait-WsusBaselineImport')).Count -ne 1) {
    throw 'InstallRoles bypasses the verified baseline-import helper.'
}
if ($text -notmatch
    '(?s)if \(\$allRolesInstalled\).+?Invoke-VerifiedWsusBaselineImport -SupVms @\(\$supVMs\).+?return') {
    throw 'The all-roles-ready fast path skips verified WSUS baseline import.'
}
if ($text -notmatch
    '(?s)if \(\$allSUPsInstalled -and \$SUPs\.Count -gt 0\).+?Invoke-VerifiedWsusBaselineImport -SupVms @\(\$SUPs\).+?return') {
    throw 'The all-SUPs-ready fast path skips verified WSUS baseline import.'
}
if ($text -notmatch
    '(?s)# Install SUP.+?foreach \(\$SUP in \$SUPs\).+?if \(-not \$supFailed\).+?Invoke-VerifiedWsusBaselineImport -SupVms @\(\$SUPs\).+?# Configure SUP') {
    throw 'A new SUP can start baseline import before role installation converges.'
}

Write-Host 'PASS -- WSUS baseline import starts only after SUP readiness and finishes before synchronization.'
