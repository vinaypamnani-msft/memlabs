#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$updatePath = Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1'
$primaryPath = Join-Path $RootPath 'DSC\phases\InstallPSForHierarchy.ps1'
$rolesPath = Join-Path $RootPath 'DSC\phases\InstallRoles.ps1'

foreach ($path in @($updatePath, $primaryPath, $rolesPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
}

$updateText = Get-Content -LiteralPath $updatePath -Raw
$primaryText = Get-Content -LiteralPath $primaryPath -Raw
$rolesText = Get-Content -LiteralPath $rolesPath -Raw

if ($updateText -notmatch
    '(?s)terminal state \$terminalStateName.+?Capturing retry evidence.+?cmupdate\.log.+?hman\.log.+?dmpdownloader\.log') {
    throw 'Terminal ConfigMgr update retries no longer capture product-log evidence.'
}
if ($updateText -notmatch
    '(?s)\$Configuration\.UpgradeSCCM\.Status = ''Error''.+?Write-ScriptWorkFlowData.+?Write-DscStatus.+?-Failure.+?throw \$upgradeFailureReason') {
    throw 'A non-hotfix ConfigMgr update failure can still fall through into dependent hierarchy work.'
}
if ($updateText -match
    '(?s)if \(\$downloadretrycount -ge 2\).{0,300}\$Configuration\.UpgradeSCCM\.Status = ''Error''.{0,300}else\s*\{\s*\$Configuration\.UpgradeSCCM\.Status = ''Completed''') {
    throw 'A download failure can still be overwritten as UpgradeSCCM=Completed.'
}
foreach ($contract in @(
        'Read-ScriptWorkflowData -ConfigurationFile $CSConfigurationFile',
        "if (`$status -in @('Error', 'Failed', 'Failure'))",
        '$casDependencyWaitMaxMinutes = 240',
        'Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile'
    )) {
    if (-not $primaryText.Contains($contract)) {
        throw "Hierarchy primary is missing failure-propagation contract: $contract"
    }
}
foreach ($contract in @(
        'Read-ScriptWorkflowData -ConfigurationFile $CSConfigurationFile',
        "InstallSUP.Status)`" -in @('Error', 'Failed', 'Failure')",
        'Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile'
    )) {
    if (-not $rolesText.Contains($contract)) {
        throw "Hierarchy role wait is missing failure-propagation contract: $contract"
    }
}

Write-Host 'PASS -- ConfigMgr hierarchy failures are diagnosed, persisted, and stopped before dependent work.'
