<#
.SYNOPSIS
    Verifies remote SQL/SQLAO phases wait on the workflow completion file with explicit credentials.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

foreach ($relativePath in @('DSC\phases\Phase8.ps1', 'DSC\phases\Phase9.ps1')) {
    $path = Join-Path $RootPath $relativePath
    $text = Get-Content -LiteralPath $path -Raw

    if ($text -match 'WaitForAll\s+WaitSCCM') {
        throw "$relativePath still relies on cross-node WaitForAll for ScriptWorkflow completion."
    }
    if ($text -notmatch
        '(?s)WaitForEvent\s+WaitSCCM\s*\{.+?MachineName\s*=\s*@\(\$WaitFor\)\[0\].+?FileName\s*=\s*''ScriptWorkflow''.+?ReadNode\s*=\s*''ScriptWorkflow''.+?ReadNodeValue\s*=\s*''Completed''.+?PsDscRunAsCredential\s*=\s*\$CMAdmin') {
        throw "$relativePath does not read the owner workflow receipt under explicit domain credentials."
    }
    if ($text -notmatch
        '\$nextDepend\s*=\s*''\[WaitForEvent\]WaitSCCM''') {
        throw "$relativePath does not gate SQL Agent re-enable on the credentialed workflow receipt."
    }
}

Write-Host 'PASS -- remote SQL nodes use credentialed workflow-file completion instead of cross-node WaitForAll.'
