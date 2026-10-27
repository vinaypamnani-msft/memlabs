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
if ($stateCalls.Count -lt 3) {
    throw "Expected boot-image, OSD convergence, and final OS-package classifier calls; found $($stateCalls.Count)."
}
function Get-EnclosingScriptBlockExpressions {
    param($Node)
    $scopes = [System.Collections.Generic.List[object]]::new()
    for ($ancestor = $Node.Parent; $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $scopes.Add($ancestor) }
    }
    return $scopes.ToArray()
}
$helperScope = @(Get-EnclosingScriptBlockExpressions $stateHelpers[0]) | Select-Object -First 1
foreach ($stateCall in $stateCalls) {
    $callScopes = @(Get-EnclosingScriptBlockExpressions $stateCall)
    if (-not $helperScope -or
        @($callScopes | Where-Object { $_.Extent.StartOffset -eq $helperScope.Extent.StartOffset }).Count -eq 0) {
        throw 'The content-state helper is not defined inside the same remoted guest scriptblock as every call site.'
    }
}

$expected = @{
    0 = 'Installed'
    1 = 'Pending'
    2 = 'Pending'
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
if ($validationText -notmatch '(?s)\$getRequiredPendingBootRows\s*=\s*\{.{0,500}State -notin 1, 2, 7') {
    throw 'The boot-image convergence wait does not include InstallRetrying state 2.'
}
if ($validationText -notmatch 'bootPendingWaitTimedOut[\s\S]{0,800}requiredOsdCoverageProblems \+= "\$pendingDetail still pending') {
    throw 'A required boot-image DP that remains pending after the wait does not fail coverage.'
}
if ($validationText -notmatch '\$osdContentWaitSeconds\s*=\s*900' -or
    $validationText -notmatch '\$osdContentWaitTimedOut' -or
    $validationText -notmatch 'after \$\{osdContentWaitElapsedSeconds\}s of convergence waiting') {
    throw 'Required OS image/upgrade content has no bounded convergence wait and timeout failure.'
}
if ($validationText -notmatch '\$osdRetryingSince' -or
    $validationText -notmatch 'TotalSeconds -lt 300' -or
    $validationText -notmatch 'remained InstallRetrying.+for 300s') {
    throw 'InstallRetrying OSD content is not observed for five minutes before its one-time re-arm.'
}
if ($validationText -notmatch 'TargetedNoStatus' -or
    $validationText -notmatch '\$getOsdContentTargetRows') {
    throw 'Targeted content with no summarizer row does not participate in convergence.'
}
if ($validationText -notmatch '\$osdContentWaitProbeFailed' -or
    $validationText -notmatch 'convergence probe failed after') {
    throw 'A failed OSD convergence probe does not fail closed with elapsed-time evidence.'
}
if ($validationText -notmatch 'SMS_DistributionDPStatus' -or
    $validationText -notmatch 'DP smsdpprov tail') {
    throw 'Persistent OSD content failures do not capture provider and DP-side diagnostics.'
}
if ($validationText -notmatch 'FAIL: \$\(\$pkgClass\.Class\) query failed, so required') {
    throw 'Required OS content query failures do not fail closed.'
}
if ($validationText -notmatch '\$siteTaskSequenceReferenceIds' -or
    $validationText -notmatch '\$taskSequence\.References' -or
    $validationText -notmatch '\$reference\.Package') {
    throw 'Phase 11 does not resolve hierarchy-owned OSD content through this site''s task-sequence references.'
}
if ($validationText -notmatch 'hierarchy-owned OSD content is valid when referenced') {
    throw 'Phase 11 does not explain hierarchy-owned OSD content acceptance.'
}
if ($validationText -notmatch '\$siteTaskSequenceReferenceErrors' -or
    $validationText -notmatch 'could not read package references') {
    throw 'Task-sequence reference read failures are silently treated as an empty reference set.'
}
if ($validationText -notmatch 'FAIL: SMS_TaskSequencePackage query failed, so required OSD task sequences and their content references were not measured') {
    throw 'A required task-sequence query failure does not fail closed.'
}
if (@([regex]::Matches($validationText, '& \$selectRelevantOsdContent')).Count -ne 2) {
    throw 'Pending and final OSD content checks do not share one task-sequence-reference selector.'
}
if ($validationText -notmatch 'FAIL: \$missingContentMessage') {
    throw 'A task sequence with no referenced OS image or upgrade package does not fail required OSD validation.'
}
if ($validationText -notmatch 'Phase11-CMSite-Test[\s\S]{0,200}-TimeoutSeconds 600 -PollProgress') {
    throw 'The site-wide validation call does not use progress-aware stall timeout semantics.'
}

Write-Host "PASS -- shared remoted classifier: Installed=0, pending=1/2/7, problems=3/4/5/6/8 with bounded OSD convergence."
