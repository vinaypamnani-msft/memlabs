<#
.SYNOPSIS
    Verifies cross-node phases wait on the exact workflow RunId receipt.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$modulePath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$manifestPath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psd1'
$moduleText = Get-Content -LiteralPath $modulePath -Raw
$manifestText = Get-Content -LiteralPath $manifestPath -Raw
if ($manifestText -notmatch "'WaitForWorkflowReceipt'" -or
    $moduleText -notmatch '(?s)class\s+WaitForWorkflowReceipt.+?ScriptWorkflow\.expected\.runid.+?ScriptWorkflow\.completed\.runid.+?expected\.Equals\(\$completed') {
    throw 'TemplateHelpDSC does not export an exact RunId workflow-receipt resource.'
}
if ($moduleText -notmatch
    '(?s)class\s+WaitForWorkflowReceipt.+?while\s*\(-not\s+\$this\.ReceiptMatches\(\)\).+?elapsed=.+?expected=.+?completed=') {
    throw 'Workflow receipt waits do not surface live expected/completed RunId diagnostics.'
}

foreach ($relativePath in @('DSC\phases\Phase8.ps1', 'DSC\phases\Phase9.ps1')) {
    $path = Join-Path $RootPath $relativePath
    $text = Get-Content -LiteralPath $path -Raw

    if ($text -match 'WaitForAll\s+(WaitSCCM|ActiveNode)' -or
        $text -match 'WaitForEvent\s+(WaitSCCM|WaitPrimary|WorkflowComplete)') {
        throw "$relativePath still relies on mutable JSON or cross-node DSC state for workflow completion."
    }
    if ($text -notmatch
        '(?s)WaitForWorkflowReceipt\s+WaitSCCM\s*\{.+?MachineName\s*=\s*@\(\$WaitFor\)\[0\].+?PsDscRunAsCredential\s*=\s*\$CMAdmin') {
        throw "$relativePath does not read the owner RunId receipt under explicit domain credentials."
    }
    if ($text -notmatch
        '\$nextDepend\s*=\s*''\[WaitForWorkflowReceipt\]WaitSCCM''') {
        throw "$relativePath does not gate SQL Agent re-enable on the credentialed workflow receipt."
    }
    if ($text -notmatch
        '(?s)WaitForWorkflowReceipt\s+ActiveNode\s*\{.+?MachineName\s*=\s*\$ThisVM\.thisParams\.ActiveNode.+?PsDscRunAsCredential\s*=\s*\$CMAdmin') {
        throw "$relativePath does not gate Passive completion on the active workflow receipt."
    }
    if ($text -notmatch 'WaitForWorkflowReceipt\s+WorkflowComplete') {
        throw "$relativePath local site workflow still depends on mutable ScriptWorkflow.json."
    }
}

Write-Host 'PASS -- Phase 8/9 dependencies use exact credentialed workflow RunId receipts.'
