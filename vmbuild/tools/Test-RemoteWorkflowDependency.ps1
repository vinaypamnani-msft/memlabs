<#
.SYNOPSIS
    Verifies exact workflow receipts, terminal failures, and dependency liveness.
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

function Import-ReceiptTestFunction {
    param([string]$Path, [string]$Name)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Parse errors in ${Path}: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Path." }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-ReceiptTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ReceiptFailure {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.ToString() }
    Assert-ReceiptTest ($message -like $Pattern) "Expected '$Pattern', got '$message'."
}

$phasePath = Join-Path $RootPath 'common\Common.Phases.ps1'
foreach ($name in @('Get-JobWaitTargets', 'Get-WorkflowReceiptProgressKey')) {
    . (Import-ReceiptTestFunction -Path $phasePath -Name $name)
}
$firstStatus = "WaitForWorkflowReceipt: Waiting for ScriptWorkflow receipt on LAB-PRI (elapsed=0.5m, expected='current', completed='<missing>')."
$laterStatus = $firstStatus.Replace('elapsed=0.5m', 'elapsed=599.5m')
Assert-ReceiptTest ((Get-WorkflowReceiptProgressKey $firstStatus) -ceq
    (Get-WorkflowReceiptProgressKey $laterStatus)) 'Receipt elapsed time reset the meaningful-progress clock.'
Assert-ReceiptTest ((Get-WorkflowReceiptProgressKey $firstStatus) -ceq
    (Get-WorkflowReceiptProgressKey $firstStatus.Replace('elapsed=0.5m', 'elapsed=0,5m'))) `
    'Localized receipt elapsed time reset the meaningful-progress clock.'
Assert-ReceiptTest ((Get-WorkflowReceiptProgressKey $firstStatus.Replace('LAB-PRI', 'LAB-PRI.lab.test')) -ceq
    (Get-WorkflowReceiptProgressKey $laterStatus.Replace('LAB-PRI', 'LAB-PRI.lab.test'))) `
    'A fully qualified receipt owner reset the meaningful-progress clock.'
Assert-ReceiptTest ((Get-WorkflowReceiptProgressKey $firstStatus) -cne
    (Get-WorkflowReceiptProgressKey $firstStatus.Replace("expected='current'", "expected='new'"))) `
    'A new receipt RunId was hidden as unchanged progress.'
Assert-ReceiptTest ((@(Get-JobWaitTargets $firstStatus) -join ',') -eq 'LAB-PRI') `
    'Receipt dependents track ScriptWorkflow as a fake VM instead of their actual owner.'
Assert-ReceiptTest ((@(Get-JobWaitTargets $firstStatus.Replace('LAB-PRI', 'LAB-PRI.lab.test')) -join ',') -eq 'LAB-PRI') `
    'A fully qualified receipt owner was not matched to its Hyper-V VM name.'
Assert-ReceiptTest ((@(Get-JobWaitTargets 'Waiting on LAB-PRI,LAB-CAS to Complete') -join ',') -eq 'LAB-PRI,LAB-CAS') `
    'Legacy multi-node dependency tracking changed.'
Assert-ReceiptTest ((@(Get-JobWaitTargets 'Setting up ConfigMgr. [LAB-PRI]: Installing secondary') -join ',') -eq 'LAB-PRI') `
    'Mirrored workflow owner tracking changed.'

$errors = $null
$moduleAst = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$errors)
if ($errors.Count) { throw "DSC module parse errors: $($errors -join '; ')" }
$definition = $moduleAst.Find({
        param($node)
        $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq 'WaitForWorkflowReceipt'
    }, $true)
if (-not $definition) { throw 'Workflow receipt DSC class is missing.' }
$receiptType = . ([scriptblock]::Create("enum Ensure { Absent; Present }`n$($definition.Extent.Text)`n[WaitForWorkflowReceipt]"))

$script:ReceiptTestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-receipt-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $script:ReceiptTestRoot -ItemType Directory
$script:ReceiptStatuses = [Collections.Generic.List[string]]::new()
$script:ReceiptSleeps = 0
$script:CompleteOnSleep = $false
$currentId = [guid]::NewGuid().ToString()
$script:ReceiptCurrentId = $currentId
$oldId = [guid]::NewGuid().ToString()
$expectedPath = Join-Path $script:ReceiptTestRoot 'ScriptWorkflow.expected.runid'
$completedPath = Join-Path $script:ReceiptTestRoot 'ScriptWorkflow.completed.runid'
$failedPath = Join-Path $script:ReceiptTestRoot 'ScriptWorkflow.failed.json'

function Resolve-ReceiptTestPath {
    param([string]$Path)
    if ($Path.StartsWith($script:ReceiptTestRoot, [StringComparison]::OrdinalIgnoreCase)) { return $Path }
    foreach ($prefix in @("\\LAB-OWNER\DSC\", "$env:SystemDrive\staging\DSC\")) {
        if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return Join-Path $script:ReceiptTestRoot $Path.Substring($prefix.Length)
        }
    }
    throw "Unexpected receipt filesystem access: $Path"
}
function Test-Path {
    param([string]$LiteralPath, [string]$PathType)
    $resolved = Resolve-ReceiptTestPath $LiteralPath
    return Microsoft.PowerShell.Management\Test-Path -LiteralPath $resolved
}
function Get-Content {
    param([string]$LiteralPath, [switch]$Raw, $ErrorAction)
    $resolved = Resolve-ReceiptTestPath $LiteralPath
    return Microsoft.PowerShell.Management\Get-Content -LiteralPath $resolved -Raw:$Raw -ErrorAction $ErrorAction
}
function Write-Status {
    param([string]$Status)
    $script:ReceiptStatuses.Add($Status)
}
function Start-Sleep {
    param($Seconds, $Milliseconds)
    $script:ReceiptSleeps++
    if ($script:CompleteOnSleep -and $script:ReceiptSleeps -eq 1) {
        [IO.File]::WriteAllText((Join-Path $script:ReceiptTestRoot 'ScriptWorkflow.completed.runid'), $script:ReceiptCurrentId)
        return
    }
    throw 'Receipt wait exceeded its deterministic test budget.'
}

try {
    $functionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
    foreach ($name in @('Write-ScriptWorkflowJsonAtomic', 'Write-ScriptWorkflowFailureReceipt')) {
        . (Import-ReceiptTestFunction -Path $functionsPath -Name $name)
    }
    [IO.File]::WriteAllText($expectedPath, $currentId)
    Write-ScriptWorkflowFailureReceipt -Root $script:ReceiptTestRoot -RunId $currentId `
        -Message 'Secondary was not verified ready; a system shutdown is in progress.'
    $published = [IO.File]::ReadAllText($failedPath) | ConvertFrom-Json
    Assert-ReceiptTest ($published.SchemaVersion -eq 1 -and $published.RunId -eq $currentId -and
        $published.Status -eq 'Failed' -and $published.FailedAtUtc) 'Terminal failure did not preserve its exact invocation identity.'
    $beforeSuperseded = [IO.File]::ReadAllText($failedPath)
    Assert-ReceiptFailure {
        Write-ScriptWorkflowFailureReceipt -Root $script:ReceiptTestRoot -RunId $oldId -Message 'Old invocation'
    } '*superseded ScriptWorkflow RunId*'
    Assert-ReceiptTest ([IO.File]::ReadAllText($failedPath) -ceq $beforeSuperseded) `
        'A superseded invocation overwrote current failure evidence.'

    foreach ($owner in @($env:COMPUTERNAME, 'LAB-OWNER')) {
        $wait = [Activator]::CreateInstance($receiptType)
        $wait.MachineName = $owner
        $wait.LogFolder = 'DSC'
        $script:ReceiptSleeps = 0
        $script:ReceiptStatuses.Clear()
        Assert-ReceiptTest (-not $wait.Test()) 'Failed workflow was accepted as a completed receipt.'
        Assert-ReceiptFailure { $wait.Set() } '*JOBFAILURE*Secondary was not verified ready*'
        Assert-ReceiptTest ($script:ReceiptSleeps -eq 0 -and
            @($script:ReceiptStatuses | Where-Object { $_ -like 'JOBFAILURE*' }).Count -eq 1) `
            'A known local/remote workflow failure slept instead of failing immediately.'
    }

    [IO.File]::WriteAllText($completedPath, $currentId)
    Assert-ReceiptTest (-not $wait.Test()) 'A completion marker concealed the same invocation''s failure receipt.'
    Assert-ReceiptFailure { $wait.Set() } '*JOBFAILURE*'
    [IO.File]::Delete($completedPath)

    $published.RunId = $oldId
    [IO.File]::WriteAllText($failedPath, ($published | ConvertTo-Json))
    $script:CompleteOnSleep = $true
    $script:ReceiptSleeps = 0
    $wait.Set()
    Assert-ReceiptTest ($script:ReceiptSleeps -eq 1 -and $wait.Test()) `
        'A stale failure blocked a healthy running replacement or exact completion.'
    $script:CompleteOnSleep = $false
    [IO.File]::WriteAllText($completedPath, $oldId)
    Assert-ReceiptTest (-not $wait.Test()) 'A stale completion released a new workflow.'

    $published.RunId = $currentId
    $published.SchemaVersion = 2
    [IO.File]::WriteAllText($failedPath, ($published | ConvertTo-Json))
    Assert-ReceiptFailure { $wait.Set() } '*Invalid ScriptWorkflow failure receipt*'
    $published.SchemaVersion = 1
    [IO.File]::WriteAllText($failedPath, ($published | ConvertTo-Json))
    $lock = [IO.File]::Open($failedPath, 'Open', 'ReadWrite', 'None')
    try {
        $failure = $null
        $sleepsBeforeRead = $script:ReceiptSleeps
        try { $wait.Set() } catch { $failure = $_ }
        Assert-ReceiptTest ($null -ne $failure -and $failure.Exception.GetBaseException() -is [IO.IOException] -and
            $script:ReceiptSleeps -eq $sleepsBeforeRead) 'An unreadable failure receipt was silently ignored or replaced by a polling timeout.'
    }
    finally { $lock.Dispose() }

    $scriptBlocksPath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
    $scriptAst = [Management.Automation.Language.Parser]::ParseFile($scriptBlocksPath, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Host scriptblock parse errors: $($errors -join '; ')" }
    $stamps = @($scriptAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ScriptBlockAst] -and
                $node.ParamBlock -and $node.ParamBlock.Parameters.Count -eq 2 -and
                $node.ParamBlock.Parameters[0].Name.VariablePath.UserPath -eq 'runId' -and
                $node.ParamBlock.Parameters[1].Name.VariablePath.UserPath -eq 'workflowRoot'
            }, $true))
    $starts = @($scriptAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-VmCommand' -and $node.Extent.Text.Contains('@dscStartArgs')
            }, $true))
    Assert-ReceiptTest ($stamps.Count -eq 1 -and $starts.Count -ge 1 -and
        $stamps[0].Extent.StartOffset -lt $starts[0].Extent.StartOffset) `
        'The workflow RunId is still published after DSC can launch or finish the workflow.'
    $stamp = $stamps[0].GetScriptBlock()
    $stampedId = & $stamp $currentId $script:ReceiptTestRoot
    Assert-ReceiptTest ($stampedId -eq $currentId -and
        [IO.File]::ReadAllText($expectedPath).Trim() -eq $currentId -and
        -not [IO.File]::Exists($completedPath) -and -not [IO.File]::Exists($failedPath)) `
        'The actual pre-launch stamp did not verify its RunId or clear stale completion/failure receipts.'
    $stampGuards = @($scriptAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text.Contains('Cannot start workflow without a verified RunId.') -and
                $node.Clauses[0].Item1.Extent.Text.Contains('$stampResult')
            }, $true))
    Assert-ReceiptTest ($stampGuards.Count -eq 1) 'The actual pre-launch invocation guard is not unambiguous.'
    $stampGuard = [scriptblock]::Create(
        'param($Phase, $stampResult, $expectedRunId, $currentItem)' + "`n" +
        $stampGuards[0].Extent.Text + "`n'launch-allowed'")
    & {
        $script:StampFailures = [Collections.Generic.List[string]]::new()
        function Write-Log {
            param($Message, [switch]$Failure, [switch]$Warning, [switch]$OutputStream)
            if ($Failure) { $script:StampFailures.Add("$Message") }
        }
        foreach ($phase in @(8, 9)) {
            foreach ($outcome in @($null,
                    [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = 'Write denied' },
                    [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $oldId })) {
                $script:StampFailures.Clear()
                $allowed = @(& $stampGuard $phase $outcome $currentId ([pscustomobject]@{ vmName = 'LAB-OWNER' }))
                Assert-ReceiptTest ($allowed.Count -eq 0 -and $script:StampFailures.Count -eq 1) `
                    'Phase 8/9 launched after a missing, failed, or unverifiable invocation stamp.'
            }
        }
        $valid = [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $currentId }
        Assert-ReceiptTest ((& $stampGuard 8 $valid $currentId ([pscustomobject]@{ vmName = 'LAB-OWNER' })) -eq 'launch-allowed') `
            'The invocation guard rejected its verified current RunId.'
    }
    Write-ScriptWorkflowFailureReceipt -Root $script:ReceiptTestRoot -RunId $currentId `
        -Message 'Secondary was not verified ready; a system shutdown is in progress.'
    $probes = @($scriptAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ScriptBlockAst] -and
                $node.ParamBlock -and $node.ParamBlock.Parameters.Count -eq 2 -and
                $node.ParamBlock.Parameters[0].Name.VariablePath.UserPath -eq 'workflowRunId' -and
                $node.ParamBlock.Parameters[1].Name.VariablePath.UserPath -eq 'workflowRoot'
            }, $true))
    Assert-ReceiptTest ($probes.Count -eq 1) 'The actual host workflow-status probe is not unambiguous.'
    $probe = $probes[0].GetScriptBlock()
    [IO.File]::WriteAllText((Join-Path $script:ReceiptTestRoot 'DSC_Status.txt'), 'Complete!')
    [IO.File]::WriteAllText($completedPath, $currentId)
    [IO.File]::WriteAllText((Join-Path $script:ReceiptTestRoot 'ClientPackageCoverage.progress.json'),
        (@{ WorkflowRunId = $currentId; Status = 'Running'; Stage = 'coverage'; UpdatedAtUtc = [DateTime]::UtcNow.ToString('o'); Message = 'Still working' } | ConvertTo-Json))
    $snapshot = & $probe $currentId $script:ReceiptTestRoot
    Assert-ReceiptTest ($snapshot.StatusText -like 'JOBFAILURE*Secondary was not verified ready*') `
        'Completion or package-progress text concealed a terminal failure from the host.'
    $published.RunId = $oldId
    [IO.File]::WriteAllText($failedPath, ($published | ConvertTo-Json))
    $snapshot = & $probe $currentId $script:ReceiptTestRoot
    Assert-ReceiptTest ($snapshot.StatusText -notlike 'JOBFAILURE*' -and $snapshot.CompletedRunId -eq $currentId) `
        'A stale failure poisoned the host''s current-invocation status.'

    $workflowPath = Join-Path $RootPath 'DSC\phases\ScriptWorkFlow.ps1'
    $workflowAst = [Management.Automation.Language.Parser]::ParseFile($workflowPath, [ref]$null, [ref]$errors)
    $trapPublishers = @($workflowAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.TrapStatementAst] -and
                $node.Extent.Text -match 'Write-ScriptWorkflowFailureReceipt -RunId \$ScriptWorkflowRunId'
            }, $true))
    Assert-ReceiptTest ($errors.Count -eq 0 -and $trapPublishers.Count -eq 1) `
        'The terminating workflow trap does not publish its captured RunId.'
    $hostText = [IO.File]::ReadAllText($scriptBlocksPath)
    Assert-ReceiptTest ($hostText.Contains('$currentStatusKey = Get-WorkflowReceiptProgressKey') -and
        $hostText.Contains('if ($currentStatusKey -ne $previousStatus)') -and
        $hostText.Contains('Get-JobWaitTargets -StatusText $currentStatus')) `
        'Host stall/dependency monitoring is not wired to the tested receipt progress semantics.'

    $snapshotStart = $scriptAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$completedRunIdSnapshot' -and
            $node.Right.Extent.Text -eq '$null'
        }, $true)
    Assert-ReceiptTest ($null -ne $snapshotStart) 'Host status snapshot initialization was not found.'
    $monitorStatements = @($snapshotStart.Parent.Statements)
    $snapshotIndex = [array]::IndexOf($monitorStatements, $snapshotStart)
    $memoryAssignment = @($monitorStatements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$memoryRequest'
        })
    Assert-ReceiptTest ($memoryAssignment.Count -eq 1) 'Host memory-request consumption was not found.'
    $memoryIndex = [array]::IndexOf($monitorStatements, $memoryAssignment[0])
    $snapshotBlock = [scriptblock]::Create(($monitorStatements[$snapshotIndex..$memoryIndex].Extent.Text) -join "`n")
    $heartbeat = @($monitorStatements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and $_.ElseClause -and
            $_.ElseClause.Extent.Text -match '\$staticSeconds ='
        })
    $progress = @($monitorStatements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and
            $_.Clauses[0].Item1.Extent.Text -eq '$statusTextSnapshot -and $statusTextSnapshot -is [string]'
        })
    $threshold = @($monitorStatements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$effectiveThreshold'
        })
    Assert-ReceiptTest ($heartbeat.Count -eq 1 -and $progress.Count -eq 1 -and $threshold.Count -eq 1) `
        'Host heartbeat/progress handling was not unambiguous.'
    $heartbeatBlock = [scriptblock]::Create($heartbeat[0].Extent.Text)
    $progressBlock = [scriptblock]::Create($progress[0].Extent.Text)
    $thresholdIndex = [array]::IndexOf($monitorStatements, $threshold[0])
    $thresholdBlock = [scriptblock]::Create(($monitorStatements[$thresholdIndex..($thresholdIndex + 1)].Extent.Text) -join "`n")

    function Invoke-HostStatusFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Fixture variables are consumed by the AST-imported monitoring blocks.')]
        [CmdletBinding()]
        param(
            [AllowNull()][object[]]$Results,
            [switch]$HadStatus,
            [switch]$RenewWarningWindow,
            [int]$ProbeSeconds = 0
        )

        $fixtureState = @{
            Logs = [Collections.Generic.List[object]]::new()
            ProgressTimes = [Collections.Generic.List[datetime]]::new()
            SupplementalReads = 0
        }
        function Write-Log {
            param($Text, [switch]$Warning, [switch]$Failure, [switch]$Success, [switch]$LogOnly, [switch]$OutputStream)
            $fixtureState.Logs.Add([pscustomobject]@{ Text = "$Text"; Warning = $Warning.IsPresent; Failure = $Failure.IsPresent })
        }
        function Write-ProgressElapsed { param($stopwatch, $timespan, $text, $failcount, $failcountMax) }
        function Start-Sleep { param($Seconds) }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, $ScriptBlock, [switch]$SuppressLog)
            $fixtureState.SupplementalReads++
            [pscustomobject]@{ ScriptBlockOutput = [pscustomobject]@{ Line = $null; Stuck = $false } }
        }
        function Restart-VM2Smart { throw 'A status fixture attempted to restart a VM.' }

        $Phase = 2
        $currentItem = [pscustomobject]@{ vmName = 'LAB-CLIENT'; role = 'InternetClient' }
        $domainName = 'example.test'
        $expectedRunId = 'current-audit-run'
        $baselineTime = [DateTime]::UtcNow.AddMinutes(-5)
        $noStatus = -not $HadStatus.IsPresent
        $failedHeartbeats = if ($HadStatus) { 7 } else { 99 }
        $failedHeartbeatThreshold = 100
        $firstRestartHeartbeatThreshold = 300
        $forcedRestartCount = 2
        $previousStatus = 'Earlier stage'
        $lastStatusChangeTime = $baselineTime
        $lastStaleWarningTime = $baselineTime
        $lastStatusReadWarningTime = [DateTime]::MinValue
        $deadWorkflowConfirmations = 2
        $staleNoticeCount = 3
        $lcmIdleSince = $baselineTime
        $lcmRebootPendingSince = $baselineTime
        $lcmPendingNoRebootSince = $baselineTime
        $dscResumeCount = 1
        $dscResumeAwaitingProgress = $false
        $dscSeenStatuses = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $complete = $false
        $pollIndex = 0
        foreach ($status in $Results) {
            if ($RenewWarningWindow -and $pollIndex -gt 0) {
                $lastStatusReadWarningTime = [DateTime]::UtcNow.AddSeconds(-61)
            }
            $stopwatch2 = [pscustomobject]@{ Elapsed = [TimeSpan]::FromSeconds($ProbeSeconds) }
            $stopwatch2 | Add-Member -MemberType ScriptMethod -Name Stop -Value {}
            . $snapshotBlock
            . $heartbeatBlock
            . $thresholdBlock
            do { . $progressBlock } while ($false)
            $fixtureState.ProgressTimes.Add($lastStatusChangeTime)
            $pollIndex++
        }
        [pscustomobject]@{
            NoStatus = $noStatus
            FailedHeartbeats = $failedHeartbeats
            EffectiveThreshold = $effectiveThreshold
            ForcedRestarts = $forcedRestartCount
            ProgressTime = $lastStatusChangeTime
            BaselineTime = $baselineTime
            PreviousStatus = $previousStatus
            DeadConfirmations = $deadWorkflowConfirmations
            IdleSince = $lcmIdleSince
            Complete = $complete
            StatusText = $statusTextSnapshot
            CompletedRunId = $completedRunIdSnapshot
            MemoryRequest = $memoryRequest
            SupplementalReads = $fixtureState.SupplementalReads
            ProgressTimes = $fixtureState.ProgressTimes.ToArray()
            Logs = $fixtureState.Logs.ToArray()
        }
    }

    $transportFailure = [pscustomobject]@{
        ScriptBlockFailed = $true
        ScriptBlockOutput = 'System.Management.Automation.Remoting.PSRemotingTransportException: Hyper-V socket target process has ended.'
        ErrorDetails = @('Fixture transport failure')
    }
    $failedReceipt = [pscustomobject]@{
        ScriptBlockFailed = $true
        ScriptBlockOutput = [pscustomobject]@{
            StatusText = 'Complete!'
            CompletedRunId = 'current-audit-run'
            MemoryRecovery = [pscustomobject]@{ RunId = 'current-audit-run'; Reason = 'OutOfMemory' }
        }
    }
    $readOnlyFailure = [pscustomobject]@{ ScriptBlockFailed = $true }
    $readOnlyFailure | Add-Member -MemberType ScriptProperty -Name ScriptBlockOutput -Value { 'Complete!' }
    foreach ($failedResult in @(
            $transportFailure, $failedReceipt, $readOnlyFailure, $null, $false,
            [pscustomobject]@{ ScriptBlockOutput = 'Complete!' },
            [pscustomobject]@{ ScriptBlockFailed = 'False'; ScriptBlockOutput = 'Complete!' },
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = [pscustomobject]@{ StatusText = 'Complete!' } },
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = [pscustomobject]@{ StatusText = 123; CompletedRunId = 'current-audit-run' } },
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = [pscustomobject]@{ StatusText = 'Complete!'; CompletedRunId = 123 } },
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @('Complete!') },
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $null }
        )) {
        $result = Invoke-HostStatusFixture -Results @($failedResult)
        Assert-ReceiptTest ($result.NoStatus -and $result.FailedHeartbeats -eq 100 -and $result.EffectiveThreshold -eq 300) `
            'A failed/malformed status read weakened the first-status heartbeat safeguard.'
        Assert-ReceiptTest ($result.ForcedRestarts -eq 2 -and $result.ProgressTime -eq $result.BaselineTime -and
            $result.DeadConfirmations -eq 2 -and $result.IdleSince -eq $result.BaselineTime -and
            $result.PreviousStatus -eq 'Earlier stage') 'A failed status read reset stall or recovery state.'
        Assert-ReceiptTest (-not $result.Complete -and $null -eq $result.StatusText -and
            $null -eq $result.CompletedRunId -and $null -eq $result.MemoryRequest -and $result.SupplementalReads -eq 0) `
            'A failed status read became progress, completion, memory recovery, or an extra guest probe.'
        Assert-ReceiptTest (@($result.Logs | Where-Object Warning).Count -eq 1 -and
            ($result.Logs.Text -join ' ') -match 'DSC status read failed') 'A failed status read had no visible warning diagnostic.'
    }
    Assert-ReceiptTest ($readOnlyFailure.ScriptBlockOutput -eq 'Complete!') 'Snapshot handling mutated the command result.'
    $result = Invoke-HostStatusFixture -Results @($transportFailure) -HadStatus
    Assert-ReceiptTest (-not $result.NoStatus -and $result.FailedHeartbeats -eq 8 -and $result.EffectiveThreshold -eq 100 -and
        $result.ProgressTime -eq $result.BaselineTime) 'A read failure changed the established-status recovery policy.'
    $result = Invoke-HostStatusFixture -Results @($transportFailure) -ProbeSeconds 25
    Assert-ReceiptTest ($result.FailedHeartbeats -eq 104 -and $result.EffectiveThreshold -eq 300) `
        'Slow failed probes lost the existing elapsed-time heartbeat accounting.'
    $result = Invoke-HostStatusFixture -Results @($transportFailure, $transportFailure, $transportFailure)
    Assert-ReceiptTest ($result.FailedHeartbeats -eq 102 -and @($result.Logs | Where-Object Warning).Count -eq 1) `
        'Repeated failures lost heartbeat accounting or flooded warnings inside one minute.'
    $result = Invoke-HostStatusFixture -Results @($transportFailure, $transportFailure) -RenewWarningWindow
    Assert-ReceiptTest (@($result.Logs | Where-Object Warning).Count -eq 2) 'Persistent failed reads stopped logging after the first warning.'
    $result = Invoke-HostStatusFixture -Results @([pscustomobject]@{
            ScriptBlockFailed = $true; ScriptBlockOutput = $null; ErrorDetails = @('X' * 3000)
        })
    $warning = @($result.Logs | Where-Object Warning)[0].Text
    Assert-ReceiptTest ($warning.Contains('X' * 2000) -and -not $warning.Contains('X' * 2001) -and $warning.EndsWith('...')) `
        'Status-read warning details did not honor their 2000-character bound.'
    $warningInitializers = @($scriptAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$lastStatusReadWarningTime' -and
            $node.Right.Extent.Text -eq '[DateTime]::MinValue'
        }, $true))
    Assert-ReceiptTest ($warningInitializers.Count -eq 1) 'The monitor did not initialize its failed-read warning cadence.'

    $healthyStatus = [pscustomobject]@{
        ScriptBlockFailed = $false
        ScriptBlockOutput = [pscustomobject]@{ StatusText = 'Configuring fixture'; CompletedRunId = $null }
    }
    $result = Invoke-HostStatusFixture -Results @($transportFailure, $healthyStatus)
    Assert-ReceiptTest (-not $result.NoStatus -and $result.FailedHeartbeats -eq 0 -and $result.ForcedRestarts -eq 0 -and
        $result.ProgressTime -gt $result.BaselineTime -and -not $result.Complete) 'A healthy status after a failed read did not restore real progress.'
    $result = Invoke-HostStatusFixture -Results @($healthyStatus, $failedReceipt)
    Assert-ReceiptTest (-not $result.NoStatus -and $result.FailedHeartbeats -eq 1 -and -not $result.Complete -and
        $null -eq $result.StatusText -and $null -eq $result.CompletedRunId -and
        $result.ProgressTimes[0] -eq $result.ProgressTimes[1]) 'A later failed read reused successful snapshots or advanced their progress clock.'
    $result = Invoke-HostStatusFixture -Results @([pscustomobject]@{
            ScriptBlockFailed = $false
            ScriptBlockOutput = [pscustomobject]@{
                StatusText = $null
                CompletedRunId = $null
                MemoryRecovery = [pscustomobject]@{ RunId = 'current-audit-run'; Reason = 'OutOfMemory' }
            }
        })
    Assert-ReceiptTest ($result.MemoryRequest.RunId -eq 'current-audit-run' -and
        $result.MemoryRequest.Reason -eq 'OutOfMemory' -and $result.NoStatus -and $result.FailedHeartbeats -eq 0) `
        'A valid structured probe lost its memory-recovery request or invented workflow progress.'
    foreach ($payload in @(
            'Complete!',
            "Complete!`r`n",
            [pscustomobject]@{ StatusText = 'Complete!'; CompletedRunId = $null },
            [pscustomobject]@{ StatusText = "Complete!`r`n"; CompletedRunId = $null },
            [pscustomobject]@{ StatusText = 'Post-install work complete'; CompletedRunId = 'current-audit-run' }
        )) {
        $result = Invoke-HostStatusFixture -Results @([pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $payload })
        Assert-ReceiptTest ($result.Complete -and -not $result.NoStatus -and $result.FailedHeartbeats -eq 0) `
            'Successful legacy text or current structured completion stopped completing the workflow.'
    }
    $readOnlySuccess = [pscustomobject]@{ ScriptBlockFailed = $false }
    $readOnlySuccess | Add-Member -MemberType ScriptProperty -Name ScriptBlockOutput -Value {
        [pscustomobject]@{ StatusText = "Complete!`r`n"; CompletedRunId = $null }
    }
    $result = Invoke-HostStatusFixture -Results @($readOnlySuccess)
    Assert-ReceiptTest ($result.Complete -and $result.StatusText -ceq 'Complete!' -and
        $readOnlySuccess.ScriptBlockOutput.StatusText -ceq "Complete!`r`n") 'Status normalization mutated a read-only successful result.'
    $result = Invoke-HostStatusFixture -Results @([pscustomobject]@{
            ScriptBlockFailed = $false
            ScriptBlockOutput = [pscustomobject]@{ StatusText = $null; CompletedRunId = $null }
        })
    Assert-ReceiptTest ($result.NoStatus -and $result.FailedHeartbeats -eq 0 -and -not $result.Complete -and
        $result.ProgressTime -eq $result.BaselineTime -and $result.Logs.Count -eq 0) `
        'A responsive guest before its first status file was mistaken for a failed probe or real progress.'
    Remove-Item -LiteralPath (Join-Path $script:ReceiptTestRoot 'ClientPackageCoverage.progress.json') -ErrorAction Stop
    $multilineStatus = "First status line`r`nSecond status line"
    [IO.File]::WriteAllText((Join-Path $script:ReceiptTestRoot 'DSC_Status.txt'), $multilineStatus)
    $snapshot = & $probe $currentId $script:ReceiptTestRoot
    Assert-ReceiptTest ($snapshot.StatusText -is [string] -and $snapshot.StatusText -ceq $multilineStatus) `
        'The guest status probe did not preserve multiline status as one string.'
}
finally {
    Remove-Item -LiteralPath $script:ReceiptTestRoot -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS -- exact local/cross-node receipts fail promptly, ignore stale failures, and preserve meaningful progress.'
