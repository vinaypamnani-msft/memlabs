#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'AST-extracted production gates consume fixture variables dynamically.')]
[CmdletBinding()]
param([string]$RootPath, [switch]$CompilerOnly, [switch]$GuestOnly)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Get-TestAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $ast
}

$phaseAst = Get-TestAst (Join-Path $RootPath 'common\Common.Phases.ps1')
$blocksAst = Get-TestAst (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1')
$resumeAssignment = $blocksAst.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$phase8ResumeExisting'
    }, $true)
$resumeArgument = $resumeAssignment.Right.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
$resumeExisting = $resumeArgument.ScriptBlock.GetScriptBlock()
$probeAssignment = $blocksAst.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$phase8RecoveryProbe'
    }, $true)
$probeArgument = $probeAssignment.Right.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
$recoveryProbe = $probeArgument.ScriptBlock.GetScriptBlock()
$definition = $phaseAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Phase8DscRecovery'
    }, $true)
if (-not $definition) { throw 'Missing Phase 8 automatic recovery helper.' }
. ([scriptblock]::Create($definition.Extent.Text))

$script:Messages = [Collections.Generic.List[object]]::new()
function Write-Log {
    param($Message, [switch]$Warning, [switch]$Failure, [switch]$OutputStream, [switch]$LogOnly)
    $script:Messages.Add([pscustomobject]@{ Text = $Message; Failure = [bool]$Failure; OutputStream = [bool]$OutputStream })
}
function Start-Sleep { param($Seconds) }
function Invoke-VmCommand {
    param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries)
    if ($DisplayName -eq 'DSC: Phase 8 recovery safety probe') {
        $script:ProbeCalls.Add($VmName)
        $reply = if ($script:ProbeReplies.Count -gt 0) { $script:ProbeReplies.Dequeue() } else { 'READY' }
    }
    else {
        $script:Calls.Add($VmName)
        if ($script:Replies.Count -eq 0) { throw 'The offline fixture exhausted its recovery replies.' }
        $reply = $script:Replies.Dequeue()
    }
    if ($reply -eq 'TIMEOUT') { throw [TimeoutException]::new('Synthetic transport timeout.') }
    if ($reply -eq 'BUG') { throw [InvalidOperationException]::new('Synthetic non-transport defect.') }
    if ($reply -eq 'TRANSPORT') {
        return [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = @(); ErrorDetails = @('Socket closed') }
    }
    if ($reply -eq 'INVALID') {
        return [pscustomobject]@{ ScriptBlockFailed = 'false'; ScriptBlockOutput = @('STARTED'); ErrorDetails = @() }
    }
    [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @($reply); ErrorDetails = @() }
}
function Copy-ItemSafe {
    param($VmName, $VmDomainName, $Path, $Destination, [switch]$Force, [switch]$RequireDomainIdentity)
    Assert-True ($VmName -eq 'SQL1' -and $RequireDomainIdentity) 'DSC source repair targeted another VM or relaxed identity.'
    $script:SourceCopies++
    $true
}
function Reset-RecoveryFixture {
    param([string[]]$Replies, [string[]]$ProbeReplies)
    $script:Replies = [Collections.Generic.Queue[string]]::new()
    foreach ($reply in $Replies) { $script:Replies.Enqueue($reply) }
    $script:ProbeReplies = [Collections.Generic.Queue[string]]::new()
    foreach ($reply in $ProbeReplies) { $script:ProbeReplies.Enqueue($reply) }
    $script:ProbeCalls = [Collections.Generic.List[string]]::new()
    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:SourceCopies = 0
    $script:Messages.Clear()
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-phase8-recovery-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $tempRoot -ItemType Directory
$sourcePath = Join-Path $tempRoot 'Phase8.ps1'
Set-Content -LiteralPath $sourcePath -Value '# fixture' -Encoding ASCII
try {
    if (-not $CompilerOnly -and -not $GuestOnly) {
        foreach ($case in @(
                @{ Replies = @('TRANSPORT', 'STARTED'); Success = $true; Attempts = 2; Calls = 2 },
                @{ Replies = @('TIMEOUT', 'STARTED'); Success = $true; Attempts = 2; Calls = 2 },
                @{ Replies = @('TRANSPORT', 'TRANSPORT'); Exhausted = $true; Attempts = 2; Calls = 2 },
                @{ Replies = @('SCRIPT_NOT_FOUND', 'STARTED'); Success = $true; Attempts = 2; Calls = 2; Copies = 1 },
                @{ Replies = @('MOF_NOT_FOUND', 'STARTED'); Success = $true; Attempts = 2; Calls = 2; Copies = 1 },
                @{ Replies = @('SCRIPT_NOT_FOUND'); MissingSource = $true; Permanent = $true; Attempts = 1; Calls = 1 },
                @{ Replies = @('COMPILE_FAILED'); Permanent = $true; Attempts = 1; Calls = 1 },
                @{ Replies = @('NODE_ROLE_UNRESOLVED'); Permanent = $true; Attempts = 1; Calls = 1 },
                @{ Replies = @('LCM_Busy'); Deferred = $true; Attempts = 0; Calls = 1 },
                @{ Replies = @('WORKFLOW_RUNNING'); Deferred = $true; Attempts = 0; Calls = 1 },
                @{ Replies = @('MOF_NOT_READY'); Deferred = $true; Attempts = 0; Calls = 1 },
                @{ Replies = @('ALREADY_COMPLETE'); Success = $true; Attempts = 0; Calls = 1 },
                @{ Replies = @('INVALID'); Permanent = $true; Attempts = 1; Calls = 1 },
                @{ Replies = @('unexpected'); Permanent = $true; Attempts = 1; Calls = 1 },
                @{ Replies = @(); FailureText = 'Compilation errors occurred'; Permanent = $true; Attempts = 0; Calls = 0 },
                @{ Replies = @(); Initial = 2; Exhausted = $true; Attempts = 2; Calls = 0 },
                @{ Replies = @('TRANSPORT'); Initial = 1; Exhausted = $true; Attempts = 2; Calls = 1 },
                @{ Replies = @(); ProbeReplies = @('ALREADY_COMPLETE'); Initial = 2; Success = $true; Attempts = 2; Calls = 0 },
                @{ Replies = @(); ProbeReplies = @('LCM_Busy'); Initial = 2; Deferred = $true; Attempts = 2; Calls = 0 },
                @{ Replies = @(); ProbeReplies = @('WORKFLOW_RUNNING'); Initial = 2; Deferred = $true; Attempts = 2; Calls = 0 },
                @{ Replies = @(); ProbeReplies = @('MOF_NOT_READY'); Initial = 2; Deferred = $true; Attempts = 2; Calls = 0 },
                @{ Replies = @(); ProbeReplies = @('LCM_Busy'); FailureText = 'Compilation errors occurred'; Deferred = $true; Attempts = 0; Calls = 0 },
                @{ Replies = @(); ProbeReplies = @('TRANSPORT', 'TRANSPORT'); Exhausted = $true; Attempts = 0; Calls = 0 },
                @{ Replies = @(); ProbeReplies = @('INVALID'); Permanent = $true; Attempts = 0; Calls = 0 },
                @{ Replies = @(); ProbeOnly = $true; Ready = $true; Initial = 2; Attempts = 2; Calls = 0 }
            )) {
            Reset-RecoveryFixture -Replies $case.Replies -ProbeReplies $case.ProbeReplies
            $state = @{ Attempts = [int]$case.Initial }
            $caseSource = if ($case.MissingSource) { Join-Path $tempRoot 'missing.ps1' } else { $sourcePath }
            $items = @(Invoke-Phase8DscRecovery -VmName 'SQL1' -VmDomainName 'example.test' `
                    -ScriptBlock { 'STARTED' } -ProbeScriptBlock { 'READY' } -RecoveryState $state -FailureText $case.FailureText `
                    -DscSourcePath $caseSource -ProbeOnly:([bool]$case.ProbeOnly))
            Assert-True ($items.Count -eq 1) 'Recovery leaked log records into its result stream.'
            $result = $items[0]
            Assert-True ($result.Succeeded -eq [bool]$case.Success -and $result.Deferred -eq [bool]$case.Deferred -and
                $result.Permanent -eq [bool]$case.Permanent -and $result.Exhausted -eq [bool]$case.Exhausted -and
                $result.Ready -eq [bool]$case.Ready) 'Recovery returned an incorrect success/failure category.'
            Assert-True ($state.Attempts -eq $case.Attempts -and $script:Calls.Count -eq $case.Calls -and
                $script:SourceCopies -eq [int]$case.Copies) 'Recovery exceeded its action budget, repeated completed work, or repaired an unrelated source.'
            Assert-True (-not @($script:Calls | Where-Object { $_ -ne 'SQL1' }).Count) 'Recovery touched a healthy peer.'
            Assert-True ($script:ProbeCalls.Count -gt 0 -and
                -not @($script:ProbeCalls | Where-Object { $_ -ne 'SQL1' }).Count) 'Recovery skipped its fresh safety probe or probed another VM.'
        }
        Reset-RecoveryFixture -Replies @('STARTED', 'STARTED')
        $state = @{ Attempts = 0 }
        $null = Invoke-Phase8DscRecovery -VmName 'SQL1' -VmDomainName 'example.test' -ScriptBlock { 'STARTED' } -ProbeScriptBlock { 'READY' } -RecoveryState $state
        $null = Invoke-Phase8DscRecovery -VmName 'SQL1' -VmDomainName 'example.test' -ScriptBlock { 'STARTED' } -ProbeScriptBlock { 'READY' } -RecoveryState $state
        $exhausted = Invoke-Phase8DscRecovery -VmName 'SQL1' -VmDomainName 'example.test' -ScriptBlock { 'STARTED' } -ProbeScriptBlock { 'READY' } -RecoveryState $state
        Assert-True ($exhausted.Exhausted -and $state.Attempts -eq 2 -and $script:Calls.Count -eq 2) 'The node recovery budget reset between compile and resume.'
        Reset-RecoveryFixture -Replies @('BUG')
        $threw = $false
        try { $null = Invoke-Phase8DscRecovery -VmName 'SQL1' -VmDomainName 'example.test' -ScriptBlock { 'STARTED' } -ProbeScriptBlock { 'READY' } -RecoveryState @{ Attempts = 0 } }
        catch { $threw = $_.Exception.Message -like '*non-transport defect*' }
        Assert-True ($threw -and $script:Calls.Count -eq 1) 'An unexpected programming failure was retried as a transport failure.'

        $classifyFailure = $blocksAst.Find({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$phase8DscFailure'
            }, $true)
        $classify = [scriptblock]::Create($classifyFailure.Extent.Text + "`nreturn `$phase8DscFailure")
        $Phase = 8
        $dscStatus = [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = [pscustomobject]@{ Status = 'Failure'; Error = 'resource failed' } }
        Assert-True ((& $classify) -eq $true) 'A structured DSC resource failure was mistaken for a status transport failure.'
        $Phase = 7
        Assert-True ((& $classify) -eq $false) 'Phase 8 error handling changed an earlier phase.'

        $failureDispatch = @($blocksAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -match '^\$Phase -eq 8 -and -not \$noStatus'
                }, $true))
        Assert-True ($failureDispatch.Count -eq 1) 'Expected one current-run Phase 8 failure recovery gate.'
        $dispatch = [scriptblock]::Create("foreach (`$tick in @(1)) {`n" + $failureDispatch[0].Extent.Text + "`n}`nreturn 'continued'")
        $currentItem = [pscustomobject]@{ vmName = 'SQL1' }
        $domainName = 'example.test'
        $expectedRunId = 'RUN42'
        $phaseRunGuid = 'GUID42'
        $phase8ResumeExisting = $resumeExisting
        $phase8RecoveryProbe = $recoveryProbe
        foreach ($case in @(
                @{ Phase = 8; NoStatus = $false; Reply = 'STARTED'; Continued = $true; Calls = 1 },
                @{ Phase = 8; NoStatus = $true; Reply = 'STARTED'; Continued = $true; Calls = 0 },
                @{ Phase = 7; NoStatus = $false; Reply = 'STARTED'; Continued = $true; Calls = 0 },
                @{ Phase = 8; NoStatus = $false; Reply = 'COMPILE_FAILED'; Continued = $false; Calls = 1 }
            )) {
            Reset-RecoveryFixture -Replies @($case.Reply)
            $Phase = $case.Phase
            $noStatus = $case.NoStatus
            $phase8RecoveryState = @{ Attempts = 0 }
            $FailStopWatch = $null
            $dscStatus = [pscustomobject]@{ ScriptBlockOutput = [pscustomobject]@{ Status = 'Failure'; Error = 'transient resource failure'; ResourcesNotInDesiredState = @() } }
            $dispatched = & $dispatch
            Assert-True (($dispatched -eq 'continued') -eq $case.Continued -and $script:Calls.Count -eq $case.Calls) 'The failed-node controller retried stale/earlier-phase state or failed to resume its own node.'
            Assert-True ((@($script:Messages | Where-Object { $_.Failure -and $_.OutputStream }).Count -gt 0) -eq (-not $case.Continued)) 'A recovered node leaked a terminal failure, or a permanent failure was hidden.'
        }

        & {
            $statusAssignment = $blocksAst.Find({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$dscStatus' -and $node.Right.Extent.Text.Contains('[bool]$ReturnStatus')
                }, $true)
            if (-not $statusAssignment) { throw 'Missing phase-scoped DSC status producer.' }
            $statusArgument = $statusAssignment.Right.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
            $statusProbe = $statusArgument.ScriptBlock.GetScriptBlock()
            $historyGates = @($blocksAst.FindAll({
                        param($node)
                        $node -is [Management.Automation.Language.IfStatementAst] -and
                        $node.Clauses[0].Item1.Extent.Text -eq '$dscStatus.ScriptBlockFailed' -and
                        $node.Extent.Text.Contains('$phase8FailureText')
                    }, $true))
            Assert-True ($historyGates.Count -eq 1) 'Expected one complete DSC history consumer.'
            $consumeHistory = [scriptblock]::Create("foreach (`$tick in @(1)) {`n" + $historyGates[0].Extent.Text + "`n}`nreturn 'continued'")
            function Get-DscConfigurationStatus {
                [CmdletBinding()]
                param()
                $script:StatusProbeCalls++
                $script:ProducedStatus
            }
            function Write-ProgressElapsed { param($Stopwatch, $Timespan, $Text) }
            function Restart-VM2Smart {
                param($Name, [switch]$AllowTurnOff, $Reason, $Stopwatch, $Timespan)
                $script:UnexpectedReboots++
                $true
            }
            $resourceError = [pscustomobject]@{
                FullyQualifiedErrorId = 'ADServerDownException'
                Exception = [pscustomobject]@{ Message = 'ADServerDownException' }
            } | ConvertTo-Json -Depth 4 -Compress
            $historyCases = @(
                @{ Status = 'Failure'; Error = 'transient resource failure'; Continued = $true; Calls = 1 },
                @{ Status = 'Success'; Continued = $true; Calls = 0 },
                @{ Status = 'Failure'; Error = 'Compilation errors occurred'; Continued = $false; Calls = 0 },
                @{ Status = 'Failure'; Error = 'Could not find mandatory property'; NoStatus = $true; Continued = $true; Calls = 0 },
                @{ Status = 'Failure'; Error = 'Compilation errors occurred'; NoStatus = $true; Continued = $true; Calls = 0 },
                @{ Status = 'Failure'; ResourceError = $resourceError; NoStatus = $true; Continued = $true; Calls = 0 },
                @{ Phase = 7; Status = 'Failure'; Error = 'Compilation errors occurred'; Continued = $true; Calls = 0 }
            )
            foreach ($guard in 'ALREADY_COMPLETE', 'LCM_Busy', 'WORKFLOW_RUNNING', 'MOF_NOT_READY', 'LCM_PendingReboot', 'REBOOT_STATE_UNKNOWN') {
                foreach ($budget in 0, 2) {
                    foreach ($errorKind in 'transient', 'mandatory', 'compile', 'ad-resource', 'ad-message') {
                        $message = switch ($errorKind) {
                            'mandatory' { 'Could not find mandatory property' }
                            'compile' { 'Compilation errors occurred' }
                            'ad-message' { 'ADServerDownException' }
                            default { 'transient resource failure' }
                        }
                        $row = @{ Status = 'Failure'; Error = $message; Probe = $guard; Initial = $budget; Continued = $true; Calls = 0 }
                        if ($errorKind -eq 'ad-resource') { $row.ResourceError = $resourceError }
                        $historyCases += $row
                    }
                }
            }
            foreach ($budget in 0, 2) {
                foreach ($restartCount in 0, 2) {
                    $historyCases += @{
                        Status = 'Failure'; ResourceError = $resourceError; Initial = $budget
                        RestartCount = $restartCount; Continued = ($restartCount -eq 0)
                        Calls = 0; Reboots = [int]($restartCount -eq 0)
                    }
                }
            }
            foreach ($case in $historyCases) {
                Reset-RecoveryFixture -Replies @('STARTED') -ProbeReplies @($case.Probe | Where-Object { $_ })
                $Phase = if ($case.Phase) { $case.Phase } else { 8 }
                $noStatus = [bool]$case.NoStatus
                $phase8RecoveryState = @{ Attempts = [int]$case.Initial }
                $script:UnexpectedReboots = 0
                $script:StatusProbeCalls = 0
                $script:ProducedStatus = [pscustomobject]@{
                    Status = $case.Status
                    Error = $case.Error
                    ResourcesNotInDesiredState = @()
                }
                if ($case.ResourceError) {
                    $script:ProducedStatus.ResourcesNotInDesiredState = @(
                        [pscustomobject]@{ ResourceId = 'fixture'; Error = $case.ResourceError }
                    )
                }
                $probeOutput = @(& $statusProbe ($Phase -eq 8))
                $dscStatus = [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $probeOutput }
                $FailStopWatch = $null
                $staleRestartCount = [int]$case.RestartCount
                $staleRestartMax = 2
                $continued = & $consumeHistory
                Assert-True ($script:StatusProbeCalls -eq 1 -and ($continued -eq 'continued') -eq $case.Continued -and
                    $script:Calls.Count -eq $case.Calls) 'The real DSC producer/consumer did not recover its current failure or ignored provenance.'
                Assert-True ($script:UnexpectedReboots -eq [int]$case.Reboots -and
                    ((@($script:Messages | Where-Object { $_.Failure -and $_.OutputStream }).Count -gt 0) -eq (-not $case.Continued))) `
                    'Stale/active/completed work produced a terminal failure or reboot, or a permanent failure was hidden.'
                if ($Phase -eq 8) { Assert-True ($probeOutput.Count -eq 1) 'Phase 8 discarded its DSC status record.' }
                else { Assert-True ($probeOutput.Count -eq 0) 'The status producer changed earlier-phase output.' }
            }
        }

        & {
            $contractGuards = @($blocksAst.FindAll({
                        param($node)
                        $node -is [Management.Automation.Language.IfStatementAst] -and
                        $node.Clauses[0].Item1.Extent.Text -eq '$Phase -eq 8' -and
                        $node.Extent.Text.Contains('$phase8CurrentNodes =')
                    }, $true))
            Assert-True ($contractGuards.Count -eq 1) 'Expected one authoritative completion-contract selector.'
            $selectContract = [scriptblock]::Create($contractGuards[0].Extent.Text + "`nreturn `$phase8RequiresWorkflowReceipt")
            $producerAssignment = $blocksAst.Find({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$dscStatus' -and $node.Right.Extent.Text.Contains('[bool]$ReturnStatus')
                }, $true)
            $producerArgument = $producerAssignment.Right.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
            $produceStatus = $producerArgument.ScriptBlock.GetScriptBlock()
            $consumerAst = $blocksAst.Find({
                    param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -eq '$dscStatus.ScriptBlockFailed' -and
                    $node.Extent.Text.Contains('$phase8FailureText')
                }, $true)
            $consumeStatus = [scriptblock]::Create("foreach (`$tick in @(1)) {`n" + $consumerAst.Extent.Text + "`n}`nreturn 'continued'")
            function Test-Path {
                param($LiteralPath)
                if ($LiteralPath -like '*completed.runid') { return $script:HasReceipt }
                if ($LiteralPath -like '*DSC_Status.txt' -or $LiteralPath -like '*.mof') { return $true }
                throw "Unexpected completion-contract path: $LiteralPath"
            }
            function Get-Content {
                [CmdletBinding()]
                param($LiteralPath, [switch]$Raw)
                if ($LiteralPath -like '*completed.runid') { return 'RUN42' }
                if ($LiteralPath -like '*RunGuid.txt') { return $script:ContractReadyGuid }
                if ($LiteralPath -like '*DSC_Status.txt') { return $script:ContractStatus }
                throw "Unexpected completion-contract read: $LiteralPath"
            }
            function Get-DscLocalConfigurationManager {
                [CmdletBinding()]
                param()
                [pscustomobject]@{ LCMState = 'Idle' }
            }
            function Get-ScheduledTask {
                [CmdletBinding()]
                param()
                [pscustomobject]@{ TaskName = 'ScriptWorkflow'; State = 'Ready' }
            }
            function Get-DscConfigurationStatus {
                [CmdletBinding()]
                param()
                if ($script:ContractUseAd) {
                    $adError = [pscustomobject]@{
                        FullyQualifiedErrorId = 'ADServerDownException'
                        Exception = [pscustomobject]@{ Message = 'ADServerDownException' }
                    } | ConvertTo-Json -Depth 4 -Compress
                    return [pscustomobject]@{
                        Status = 'Failure'; Error = $null
                        ResourcesNotInDesiredState = @([pscustomobject]@{ ResourceId = 'fixture'; Error = $adError })
                    }
                }
                [pscustomobject]@{ Status = 'Failure'; Error = 'transient resource failure'; ResourcesNotInDesiredState = @() }
            }
            function Write-ProgressElapsed { param($Stopwatch, $Timespan, $Text) }
            function Restart-VM2Smart { throw 'Completed status-only recovery attempted a reboot.' }
            function Start-DscConfiguration {
                [CmdletBinding()]
                param([switch]$UseExisting, [switch]$Force)
                Assert-True ($UseExisting -and -not $Force) 'Completion recovery did not retain the current configuration safely.'
                $script:ContractStarts++
            }
            function Invoke-VmCommand {
                param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries)
                if ($DisplayName -eq 'DSC: Phase 8 recovery safety probe') { $script:ProbeCalls.Add($VmName) }
                else { $script:Calls.Add($VmName) }
                try {
                    $output = @(& $ScriptBlock @ArgumentList)
                    [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $output; ErrorDetails = @() }
                }
                catch {
                    [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = @(); ErrorDetails = @($_.Exception.Message) }
                }
            }
            $Phase = 8
            $noStatus = $false
            $script:ContractUseAd = $false
            foreach ($role in 'FileServer', 'SiteSystem', 'WSUS', 'SqlServer', 'DC', 'Secondary', 'PassiveSite', 'CAS', 'Primary') {
                foreach ($budget in 0, 2) {
                    foreach ($completionText in 'Complete!', 'Setting up ConfigMgr. Status: Complete!') {
                        Reset-RecoveryFixture -Replies @()
                        $currentItem = [pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember' }
                        $ConfigurationData = [pscustomobject]@{
                            AllNodes = @([pscustomobject]@{ NodeName = 'SQL1'; Role = $role })
                        }
                        $phase8RequiresWorkflowReceipt = & $selectContract
                        $requiresReceipt = $role -in @('CAS', 'Primary')
                        Assert-True ($phase8RequiresWorkflowReceipt -eq $requiresReceipt) 'The completion contract used configured rather than authoritative phase role.'
                        $script:ContractStarts = 0
                        $script:HasReceipt = $false
                        $script:ContractReadyGuid = 'GUID42'
                        $script:ContractStatus = $completionText
                        $phase8RecoveryState = @{ Attempts = $budget }
                        $dscStatus = [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @(& $produceStatus $true) }
                        $continued = & $consumeStatus
                        $shouldStart = $requiresReceipt -and $budget -eq 0
                        $shouldFail = $requiresReceipt -and $budget -eq 2
                        Assert-True ($script:ContractStarts -eq [int]$shouldStart -and
                            $script:Calls.Count -eq [int]$shouldStart -and
                            ($continued -eq 'continued') -eq (-not $shouldFail)) 'A completed status-only node replayed or failed with a nonempty RunId.'
                        Assert-True ((@($script:Messages | Where-Object { $_.Failure -and $_.OutputStream }).Count -gt 0) -eq $shouldFail) `
                            'Completion-contract recovery produced an incorrect terminal failure.'
                    }
                }
            }
            foreach ($budget in 0, 2) {
                Reset-RecoveryFixture -Replies @()
                $currentItem = [pscustomobject]@{ vmName = 'SQL1'; role = 'FileServer' }
                $ConfigurationData = [pscustomobject]@{ AllNodes = @([pscustomobject]@{ NodeName = 'SQL1'; Role = 'FileServer' }) }
                $phase8RequiresWorkflowReceipt = & $selectContract
                $script:ContractStarts = 0
                $script:HasReceipt = $false
                $script:ContractReadyGuid = 'OTHER-RUN'
                $script:ContractStatus = 'Complete!'
                $phase8RecoveryState = @{ Attempts = $budget }
                $dscStatus = [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @(& $produceStatus $true) }
                $continued = & $consumeStatus
                Assert-True ($null -eq $continued -and $script:ContractStarts -eq 0 -and
                    @($script:Messages | Where-Object { $_.Failure -and $_.OutputStream }).Count -eq 1) `
                    'Status-only completion accepted another phase run or started recovery against its owner.'
            }
            foreach ($budget in 0, 2) {
                Reset-RecoveryFixture -Replies @()
                $currentItem = [pscustomobject]@{ vmName = 'SQL1'; role = 'FileServer' }
                $ConfigurationData = [pscustomobject]@{ AllNodes = @([pscustomobject]@{ NodeName = 'SQL1'; Role = 'FileServer' }) }
                $phase8RequiresWorkflowReceipt = & $selectContract
                $script:ContractStarts = 0
                $script:HasReceipt = $false
                $script:ContractReadyGuid = 'GUID42'
                $script:ContractStatus = 'Complete!'
                $script:ContractUseAd = $true
                $phase8RecoveryState = @{ Attempts = $budget }
                $dscStatus = [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @(& $produceStatus $true) }
                $continued = & $consumeStatus
                Assert-True ($continued -eq 'continued' -and $script:ContractStarts -eq 0 -and
                    $script:Calls.Count -eq 0 -and
                    @($script:Messages | Where-Object { $_.Failure -and $_.OutputStream }).Count -eq 0) `
                    'AD history bypassed the actual status-only completion contract.'
            }
        }

    }

    if (-not $CompilerOnly) {
        & {
            function Test-Path {
                param($LiteralPath)
                if ($LiteralPath -like '*completed.runid') { return $script:CompletedExists }
                if ($LiteralPath -like '*.mof') { return -not $script:MissingMof }
                if ($LiteralPath -like '*DSC_Status.txt') { return $script:HasLegacyStatus }
                throw "Unexpected guest path: $LiteralPath"
            }
            function Get-Content {
                [CmdletBinding()]
                param($LiteralPath, [switch]$Raw)
                if ($LiteralPath -like '*completed.runid') { return $script:CompletedId }
                if ($LiteralPath -like '*RunGuid.txt') { return $script:ReadyGuid }
                if ($LiteralPath -like '*DSC_Status.txt') { return $script:LegacyStatus }
                throw "Unexpected guest read: $LiteralPath"
            }
            function Get-DscLocalConfigurationManager {
                [CmdletBinding()]
                param()
                [pscustomobject]@{ LCMState = $script:LcmState }
            }
            function Get-ScheduledTask {
                [CmdletBinding()]
                param()
                [pscustomobject]@{ TaskName = 'ScriptWorkflow'; State = $script:WorkflowState }
            }
            function Get-DscConfigurationStatus {
                [CmdletBinding()]
                param()
                if ($script:RebootUnknown) { return [pscustomobject]@{} }
                [pscustomobject]@{ RebootRequested = $script:RebootOwed }
            }
            function Start-DscConfiguration {
                [CmdletBinding()]
                param([switch]$UseExisting, [switch]$Force)
                Assert-True ($UseExisting -and -not $Force) 'Failed-node recovery did not retain the current MOF or could override an active apply.'
                if ($script:ResumeRaced) {
                    $script:LcmState = 'Busy'
                    throw [InvalidOperationException]::new('Another apply started after the readiness probe.')
                }
                $script:DscStarts++
            }
            foreach ($case in @(
                    @{ Completed = 'RUN42'; Lcm = 'Idle'; Workflow = 'Ready'; Expected = 'ALREADY_COMPLETE'; Starts = 0 },
                    @{ Completed = 'OLD'; Lcm = 'Idle'; Workflow = 'Ready'; Expected = 'STARTED'; Starts = 1 },
                    @{ Lcm = 'Busy'; Workflow = 'Ready'; Expected = 'LCM_Busy'; Starts = 0 },
                    @{ Lcm = 'Idle'; Workflow = 'Running'; Expected = 'WORKFLOW_RUNNING'; Starts = 0 },
                    @{ Lcm = 'Idle'; Workflow = 'Ready'; MissingMof = $true; Expected = 'MOF_NOT_READY'; Starts = 0 },
                    @{ Lcm = 'PendingConfiguration'; Workflow = 'Ready'; Expected = 'STARTED'; Starts = 1 },
                    @{ Lcm = 'PendingConfiguration'; Workflow = 'Ready'; RebootOwed = $true; Expected = 'LCM_PendingReboot'; Starts = 0 },
                    @{ Lcm = 'PendingConfiguration'; Workflow = 'Ready'; RebootUnknown = $true; Expected = 'REBOOT_STATE_UNKNOWN'; Starts = 0 },
                    @{ Lcm = 'Idle'; Workflow = 'Ready'; ResumeRaced = $true; Expected = 'LCM_Busy'; ProbeExpected = 'READY'; Starts = 0 },
                    @{ Lcm = 'Idle'; Workflow = 'Ready'; WrongGuid = $true; Throws = $true; Starts = 0 }
                )) {
                $script:CompletedExists = [bool]$case.Completed
                $script:CompletedId = $case.Completed
                $script:ReadyGuid = if ($case.WrongGuid) { 'OTHER' } else { 'GUID42' }
                $script:LcmState = $case.Lcm
                $script:WorkflowState = $case.Workflow
                $script:MissingMof = [bool]$case.MissingMof
                $script:ResumeRaced = [bool]$case.ResumeRaced
                $script:RebootOwed = [bool]$case.RebootOwed
                $script:RebootUnknown = [bool]$case.RebootUnknown
                $script:DscStarts = 0
                $threw = $false
                $result = $null
                $probeResult = & $recoveryProbe 'RUN42' 'GUID42' $true
                $expectedProbe = if ($case.Throws) { 'RUN_GUID_MISMATCH' }
                elseif ($case.ProbeExpected) { $case.ProbeExpected }
                elseif ($case.Expected -eq 'STARTED') { 'READY' }
                else { $case.Expected }
                Assert-True ($probeResult -eq $expectedProbe -and $script:DscStarts -eq 0) 'The read-only recovery probe mutated work or misclassified pending state.'
                try { $result = & $resumeExisting 'RUN42' 'GUID42' }
                catch { $threw = $_.Exception.Message -like '*RUN_GUID_MISMATCH*' }
                Assert-True ($threw -eq [bool]$case.Throws -and $result -eq $case.Expected -and
                    $script:DscStarts -eq $case.Starts) 'Guest recovery changed completed/active work or resumed another run.'
            }
            $script:CompletedExists = $false
            $script:HasLegacyStatus = $true
            $script:LegacyStatus = 'Complete!'
            $script:ReadyGuid = 'GUID42'
            $legacyComplete = & $recoveryProbe 'RUN42' 'GUID42' $true $false
            Assert-True ($legacyComplete -eq 'ALREADY_COMPLETE') 'A current-run non-workflow node completion was ignored.'
            $legacyResume = & $resumeExisting 'RUN42' 'GUID42' $false
            Assert-True ($legacyResume -eq 'ALREADY_COMPLETE' -and $script:DscStarts -eq 0) 'A status-only completed node was resumed despite its nonempty RunId.'
        }

    }

    & {
        $compilerAssignment = $blocksAst.Find({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$DSC_RecoverLocal'
            }, $true)
        $compilerArgument = $compilerAssignment.Right.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
        $compilerRoot = Join-Path $tempRoot 'compiler'
        $null = New-Item -Path (Join-Path $compilerRoot 'phases') -ItemType Directory -Force
        $compilerText = $compilerArgument.ScriptBlock.GetScriptBlock().ToString().Replace('$using:', '$').Replace('C:\staging\DSC', $compilerRoot)
        $compileLocally = [scriptblock]::Create($compilerText)
        $fixtureCompiler = @'
function Phase8 {
    [CmdletBinding()]
    param($DeployConfigPath, $AdminCreds, $ConfigurationData, $OutputPath)
    $null = New-Item -Path $OutputPath -ItemType Directory -Force
    Add-Content -LiteralPath (Join-Path $OutputPath 'compile-count.txt') -Value 'compile'
    $fixture = Get-Content -LiteralPath $DeployConfigPath -Raw | ConvertFrom-Json
    if ($fixture.TestCompileFailure) { throw 'Synthetic compilation failure.' }
    New-Item -Path (Join-Path $OutputPath "$env:COMPUTERNAME.mof") -ItemType File -Force
}
'@
        Set-Content -LiteralPath (Join-Path $compilerRoot 'phases\Phase8.ps1') -Value $fixtureCompiler -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $compilerRoot 'RunGuid.txt') -Value 'GUID42' -Encoding ASCII
        $compilerConfig = [pscustomobject]@{
            vmOptions = [pscustomobject]@{ domainNetBiosName = 'LAB' }
            virtualMachines = @([pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember' })
            TestCompileFailure = $false
        }
        $Phase = 8
        $mofFolderName = 'DSCConfiguration_GUID42'
        $Common = [pscustomobject]@{ LocalAdmin = [pscredential]::new('fixture', [Security.SecureString]::new()) }
        $ConfigurationData = [pscustomobject]@{
            AllNodes = @([pscustomobject]@{ NodeName = 'SQL1'; Role = 'SqlServer' })
        }
        function Get-DscLocalConfigurationManager {
            [CmdletBinding()]
            param()
            $script:CompilerLcmCalls++
            $state = if ($script:CompilerRaceBusy -and $script:CompilerLcmCalls -gt 1) { 'Busy' } else { $script:CompilerLcmState }
            [pscustomobject]@{ LCMState = $state }
        }
        function Get-ScheduledTask {
            [CmdletBinding()]
            param()
            $script:CompilerWorkflowCalls++
            $state = if ($script:CompilerRaceWorkflow -and $script:CompilerWorkflowCalls -gt 1) { 'Running' } else { $script:CompilerWorkflowState }
            [pscustomobject]@{ TaskName = 'ScriptWorkflow'; State = $state }
        }
        function Get-DscConfigurationStatus {
            [CmdletBinding()]
            param()
            if ($script:CompilerRebootUnknown) { return [pscustomobject]@{} }
            [pscustomobject]@{ RebootRequested = $script:CompilerRebootOwed }
        }
        function Start-DscConfiguration {
            [CmdletBinding()]
            param($Path, [switch]$Force)
            Assert-True (-not $Force) 'Phase 8 local compilation could replace a concurrent active apply.'
            if ($script:CompilerStartFails) { throw [IO.IOException]::new('Synthetic start failure.') }
            $script:CompilerStarts++
        }
        function Remove-DscConfigurationDocument { $script:CompilerDeletions++ }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries)
            if ($DisplayName -eq 'DSC: Phase 8 recovery safety probe') {
                return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @('READY'); ErrorDetails = @() }
            }
            try {
                $output = @(& $ScriptBlock @ArgumentList)
                [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $output; ErrorDetails = @() }
            }
            catch {
                [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = @(); ErrorDetails = @($_.Exception.Message) }
            }
        }
        $oldComputerName = $env:COMPUTERNAME
        $oldModulePath = $env:PSModulePath
        try {
            $env:COMPUTERNAME = 'SQL1'
            $caseIndex = 0
            foreach ($case in @(
                    @{ Lcm = 'Idle'; Expected = 'started'; Starts = 1; Compiles = 1 },
                    @{ Lcm = 'PendingConfiguration'; Expected = 'started'; Starts = 1; Compiles = 1 },
                    @{ Lcm = 'PendingConfiguration'; RebootOwed = $true; Expected = 'deferred'; Starts = 0; Compiles = 0 },
                    @{ Lcm = 'PendingConfiguration'; RebootUnknown = $true; Expected = 'deferred'; Starts = 0; Compiles = 0 },
                    @{ Lcm = 'Idle'; Workflow = 'Running'; Expected = 'deferred'; Starts = 0; Compiles = 0 },
                    @{ Lcm = 'Idle'; RaceBusy = $true; Expected = 'deferred'; Starts = 0; Compiles = 1 },
                    @{ Lcm = 'Idle'; RaceWorkflow = $true; Expected = 'deferred'; Starts = 0; Compiles = 1 },
                    @{ Lcm = 'Idle'; CompileFailure = $true; Expected = 'permanent'; Starts = 0; Compiles = 1 },
                    @{ Lcm = 'Idle'; StartFailure = $true; Expected = 'exhausted'; Starts = 0; Compiles = 2 },
                    @{ Lcm = 'Idle'; Complete = $true; Expected = 'complete'; Starts = 0; Compiles = 0 }
                )) {
                $caseIndex++
                $mofFolderName = "DSCConfiguration_GUID42_$caseIndex"
                $compilerConfig.TestCompileFailure = [bool]$case.CompileFailure
                $compilerConfig | ConvertTo-Json -Depth 5 |
                    Set-Content -LiteralPath (Join-Path $compilerRoot 'deployConfig.json') -Encoding ASCII
                $statusPath = Join-Path $compilerRoot 'DSC_Status.txt'
                if ($case.Complete) { Set-Content -LiteralPath $statusPath -Value 'Complete!' -Encoding ASCII }
                elseif (Test-Path -LiteralPath $statusPath) { Remove-Item -LiteralPath $statusPath -Force }
                $existingMof = Join-Path $compilerRoot 'existing-current.mof'
                Set-Content -LiteralPath $existingMof -Value 'retained current configuration' -Encoding ASCII
                $script:CompilerStarts = 0
                $script:CompilerDeletions = 0
                $script:CompilerLcmCalls = 0
                $script:CompilerWorkflowCalls = 0
                $script:CompilerLcmState = $case.Lcm
                $script:CompilerWorkflowState = if ($case.Workflow) { $case.Workflow } else { 'Ready' }
                $script:CompilerRaceBusy = [bool]$case.RaceBusy
                $script:CompilerRaceWorkflow = [bool]$case.RaceWorkflow
                $script:CompilerRebootOwed = [bool]$case.RebootOwed
                $script:CompilerRebootUnknown = [bool]$case.RebootUnknown
                $script:CompilerStartFails = [bool]$case.StartFailure
                $state = @{ Attempts = 0 }
                $compiled = Invoke-Phase8DscRecovery -VmName 'SQL1' -VmDomainName 'example.test' `
                    -ScriptBlock $compileLocally -ProbeScriptBlock { 'READY' } -ArgumentList @('phases', 'RUN42', $false, 'GUID42') -RecoveryState $state
                $countPath = Join-Path (Join-Path $compilerRoot "phases\$mofFolderName") 'compile-count.txt'
                $compileCount = 0
                if (Test-Path -LiteralPath $countPath) { $compileCount = @(Get-Content -LiteralPath $countPath).Count }
                Assert-True ($script:CompilerStarts -eq $case.Starts -and $compileCount -eq $case.Compiles -and
                    $script:CompilerDeletions -eq 0 -and
                    (Get-Content -LiteralPath $existingMof -Raw).Trim() -eq 'retained current configuration') `
                    'Compiler recovery repeated active work or deleted an existing configuration.'
                if ($case.Expected -eq 'started') {
                    Assert-True ($compiled.Succeeded -and -not $compiled.Permanent -and
                        @($compiled.Result.ScriptBlockOutput).Count -eq 1 -and $compiled.Result.ScriptBlockOutput -contains 'STARTED') `
                        "The shipped compiler leaked FileInfo output or failed to start safely: $($compiled.Reason)"
                }
                elseif ($case.Expected -eq 'deferred') {
                    Assert-True ($compiled.Deferred -and $state.Attempts -eq 0) 'Compiler recovery consumed an action while legitimate work or reboot was pending.'
                }
                elseif ($case.Expected -eq 'permanent') {
                    Assert-True ($compiled.Permanent -and $state.Attempts -eq 1) 'Compilation failure did not stop safely.'
                }
                elseif ($case.Expected -eq 'complete') {
                    Assert-True ($compiled.Succeeded -and $state.Attempts -eq 0) 'A completed status-only node consumed a compiler recovery action.'
                }
                else {
                    Assert-True ($compiled.Exhausted -and $state.Attempts -eq 2) 'Failed compiler submission exceeded the two-action budget.'
                }
                $env:PSModulePath = $oldModulePath
            }
        }
        finally {
            $env:COMPUTERNAME = $oldComputerName
            $env:PSModulePath = $oldModulePath
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
}
[Console]::WriteLine("PASS -- $script:Assertions bounded Phase 8 recovery assertions on PowerShell $($PSVersionTable.PSVersion).")
