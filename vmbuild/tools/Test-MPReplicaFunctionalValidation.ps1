<#
.SYNOPSIS
    Verifies MP replica Phase 11 checks do not depend on optional SQL modules.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }
$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-MPReplicaFunctionality'
        }, $true))
if ($definitions.Count -ne 1) {
    throw "Expected one Test-MPReplicaFunctionality definition, found $($definitions.Count)."
}
$text = $definitions[0].Extent.Text

if ($text -match 'Invoke-Sqlcmd|Import-Module\s+(SqlServer|SQLPS)') {
    throw 'MP replica Phase 11 validation still depends on an optional SQL PowerShell module.'
}
foreach ($required in @(
        'System.Data.SqlClient.SqlConnection',
        'Integrated Security=SSPI',
        'TrustServerCertificate=True',
        'Connect Timeout=20',
        'CommandTimeout = 60',
        '$reader.Dispose()',
        '$command.Dispose()',
        '$connection.Dispose()',
        'SELECT ServerName, DBID FROM v_BgbMP',
        "publication ConfigMgr_MPReplica",
        "ConfigMgrBGBQueue"
    )) {
    if ($text -notmatch [regex]::Escape($required)) {
        throw "MP replica Phase 11 validation lost required SQL surface '$required'."
    }
}
if ($text -match 'WARN: could not (read MP role SQL/DB properties|verify replication publication/subscriptions|check BGB queue)') {
    throw 'An unreadable required MP replica SQL surface can still return a warning-shaped success.'
}
foreach ($failure in @(
        'FAIL: could not read MP role SQL/DB properties',
        'FAIL: could not verify replication publication/subscriptions',
        'FAIL: could not check BGB queue on replica'
    )) {
    if ($text -notmatch [regex]::Escape($failure)) {
        throw "MP replica Phase 11 validation no longer fails closed for '$failure'."
    }
}

Write-Host 'PASS -- MP replica Phase 11 validation uses built-in SqlClient and fails closed on unreadable routes.'
