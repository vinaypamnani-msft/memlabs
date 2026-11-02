#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production branches read these fixture variables dynamically.')]
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

$tokens = $null
$errors = $null
$updateAst = [Management.Automation.Language.Parser]::ParseFile($updatePath, [ref]$tokens, [ref]$errors)
$primaryAst = [Management.Automation.Language.Parser]::ParseFile($primaryPath, [ref]$tokens, [ref]$errors)
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$timeoutGuards = @($updateAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$drsElapsed -ge $drsTimeoutSec'
        }, $true))
Assert-True ($timeoutGuards.Count -eq 1) 'Expected one production DRS deadline verdict.'
$timeoutVerdict = [scriptblock]::Create($timeoutGuards[0].Extent.Text)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-DrsReadiness-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testRoot
try {
    & {
        $state = [pscustomobject]@{
            Writes = 0; Failures = [System.Collections.Generic.List[string]]::new()
        }
        function Write-ScriptWorkFlowData {
            param($Configuration, $ConfigurationFile)
            $state.Writes++
        }
        function Write-DscStatus {
            param($Message, [switch]$Failure, [switch]$Warning, $MachineName)
            if ($Failure) { $state.Failures.Add($Message) }
        }
        $SiteCode = 'CAS'
        $PSSiteCode = 'PRI'
        $PSVM = [pscustomobject]@{ VmName = 'PRIMARY1' }
        $ConfigurationFile = 'fixture-workflow.json'
        $LogPath = $testRoot
        $Configuration = [pscustomobject]@{
            InstallSCCM = [pscustomobject]@{ Status = 'Completed'; EndTime = '' }
            PSReadyToUsePRIMARY1 = [pscustomobject]@{ Status = 'Running'; EndTime = ''; ReplicationVerified = $false }
        }
        $drsLastObservation = @{
            PRIMARY1 = [pscustomobject]@{ LinkStatus = 6; GlobalInitPercentage = 100; SqlHealth = @{ Healthy = $false; Error = 'fixture SQL evidence' } }
        }
        $drsTimeoutSec = 7200
        $drsElapsed = 7199
        $drsElapsedMin = 119
        & $timeoutVerdict
        Assert-True ($state.Writes -eq 0 -and $Configuration.PSReadyToUsePRIMARY1.Status -eq 'Running') 'DRS failed before its configured deadline.'
        $drsElapsed = 7200
        $drsElapsedMin = 120
        $caught = $null
        try { & $timeoutVerdict } catch { $caught = $_ }
        Assert-True ($caught -and $caught.Exception.Message -match 'Primary is NOT ready') 'A 120-minute DRS timeout did not terminate readiness.'
        Assert-True ($Configuration.PSReadyToUsePRIMARY1.Status -eq 'Error' -and
            -not $Configuration.PSReadyToUsePRIMARY1.ReplicationVerified -and
            $Configuration.InstallSCCM.Status -eq 'Error' -and $state.Writes -eq 1) 'Timeout still persisted a success-shaped CAS/Primary handoff.'
        Assert-True ($state.Failures.Count -eq 1) 'Timeout did not reach the host-visible failure channel.'
        $snapshot = Get-Content -LiteralPath (Join-Path $LogPath 'DRSReadinessFailure.json') -Raw | ConvertFrom-Json
        Assert-True ($snapshot.ElapsedSeconds -eq 7200 -and
            $snapshot.LastObservations.PRIMARY1.LinkStatus -eq 6 -and
            $snapshot.LastObservations.PRIMARY1.SqlHealth.Error -eq 'fixture SQL evidence') 'The failure snapshot lost the last measured provider/SQL facts.'
    }

    $readyLoops = @($primaryAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.WhileStatementAst] -and
                $node.Condition.Extent.Text.Contains('$casReady.ReplicationVerified')
            }, $true))
    Assert-True ($readyLoops.Count -eq 1) 'Expected one verified CAS handoff consumer.'
    $keepWaiting = [scriptblock]::Create($readyLoops[0].Condition.Extent.Text)
    & {
        foreach ($proof in @($null, $false, 'True', $true)) {
            $casReady = [pscustomobject]@{ Status = 'Completed' }
            if ($null -ne $proof) { $casReady | Add-Member -NotePropertyName ReplicationVerified -NotePropertyValue $proof }
            $waiting = [bool](& $keepWaiting)
            $expected = -not ($proof -is [bool] -and $proof)
            Assert-True ($waiting -eq $expected) 'The Primary accepted an unverified/legacy or string-valued Completed marker.'
        }
    }
    for ($parent = $readyLoops[0].Parent; $parent; $parent = $parent.Parent) {
        if ($parent -is [Management.Automation.Language.IfStatementAst]) {
            Assert-True (-not $parent.Clauses[0].Item1.Extent.Text.Contains('$Configuration.InstallSCCM.Status')) 'A resumed Primary skips the replication-readiness handshake.'
        }
    }
    $finalDependencyChecks = @($primaryAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Assert-CasWorkflowStepCanContinue' -and
                $node.Extent.StartOffset -gt $readyLoops[0].Extent.EndOffset
            }, $true))
    Assert-True ($finalDependencyChecks.Count -eq 1) 'A cached verified marker can bypass a newly failed CAS dependency.'
    $assertions = @($primaryAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Assert-CasWorkflowStepCanContinue'
            }, $true))
    . ([scriptblock]::Create($assertions[0].Extent.Text))
    $CSName = 'CAS1'
    $CSConfigurationFile = 'fixture-cas-workflow.json'
    $cas = [pscustomobject]@{
        InstallSCCM = [pscustomobject]@{ Status = 'Error' }
        UpgradeSCCM = [pscustomobject]@{ Status = 'Completed' }
        PSReadyToUsePRIMARY1 = [pscustomobject]@{ Status = 'Running' }
    }
    $caught = $null
    try { Assert-CasWorkflowStepCanContinue -CasConfiguration $cas -Step PSReadyToUsePRIMARY1 }
    catch { $caught = $_ }
    Assert-True ($caught -and $caught.Exception.Message -match 'InstallSCCM=Error') 'A CAS failure leaves other pending Primaries waiting for their individual deadline.'

    $proofAssignments = @($updateAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$Configuration.$propName.ReplicationVerified' -and
                $node.Right.Extent.Text -eq '$true'
            }, $true))
    Assert-True ($proofAssignments.Count -eq 2) 'Only the provider-active and independently SQL-healthy branches may publish verified readiness.'
    Assert-True (-not $updateText.Contains('Proceeding anyway.')) 'A success fallback remains in the DRS readiness producer.'

    $collectorPath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
    $collectorAst = [Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$errors)
    $snapshotCaptures = @($collectorAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.TryStatementAst] -and
                $node.Body.Extent.Text.Contains('$drsSnapshot.Length -gt 1MB')
            }, $true) | Sort-Object { $_.Extent.EndOffset - $_.Extent.StartOffset })
    Assert-True ($snapshotCaptures.Count -ge 1) 'The DRS snapshot is not in the host-bound failure artifact manifest.'
    $capture = [scriptblock]::Create($snapshotCaptures[0].Extent.Text)
    & {
        $drsSnapshotPath = Join-Path $testRoot 'snapshot.json'
        foreach ($size in @(1MB, (1MB + 1))) {
            [IO.File]::WriteAllText($drsSnapshotPath, ('"' + ('x' * ($size - 2)) + '"'), [Text.UTF8Encoding]::new($false))
            $cmArtifacts = [System.Collections.Generic.List[object]]::new()
            $productLogInventory = [System.Collections.Generic.List[object]]::new()
            . $capture
            if ($size -eq 1MB) {
                Assert-True ($cmArtifacts.Count -eq 1 -and $cmArtifacts[0].Content.Length -eq 1MB) 'The exact 1 MiB snapshot boundary was not retained intact.'
            }
            else {
                Assert-True ($cmArtifacts.Count -eq 0 -and
                    $productLogInventory[0].Error -match 'exceeds') 'Oversized snapshots are unbounded or silently discarded.'
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS -- ConfigMgr hierarchy failures are diagnosed, persisted, and stopped before dependent work.'
