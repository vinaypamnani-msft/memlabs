<#
.SYNOPSIS
    Verifies missing-VM preflight and phase-result failures stop deployment.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'common\Common.Phases.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Phase source parse errors: $($errors -join '; ')" }

function Get-TestFunction {
    param([string]$Name)
    $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Write-Log {
    param($Message, [switch]$Warning, [switch]$Failure, [switch]$LogOnly)
    $script:messages += [string]$Message
}
function Write-RedX {
    param($Message, [switch]$WriteLog)
    $script:messages += [string]$Message
}
function Write-Exception {
    param($ExceptionInfo)
    $script:messages += $ExceptionInfo.Exception.Message
}
$script:messages = @()
. ([scriptblock]::Create((Get-TestFunction 'Resolve-WaitPhaseResult').Extent.Text))

function New-TestTally {
    [pscustomobject]@{ Failed = 0; Success = 2; Warning = 0; Elapsed = [timespan]::FromSeconds(1); Crashed = @() }
}
$good = New-TestTally
Assert-True ((Resolve-WaitPhaseResult -Raw $good -Phase 8) -eq $good) 'Valid tally changed.'
Assert-True ((Resolve-WaitPhaseResult -Raw @('leaked output', $good) -Phase 8) -eq $good) 'Output leak obscured valid tally.'
$failed = New-TestTally
$failed.Failed = 1
Assert-True ((Resolve-WaitPhaseResult -Raw @($good, $failed) -Phase 8).Failed -eq 1) 'Last tally failure was lost.'
foreach ($raw in @($null, 'unexpected output', [pscustomobject]@{ Crashed = @() })) {
    $rejected = $false
    try { $null = Resolve-WaitPhaseResult -Raw $raw -Phase 8 }
    catch { $rejected = $true }
    Assert-True $rejected 'Missing or malformed tally was accepted.'
}
foreach ($field in @('Failed', 'Success', 'Warning', 'Elapsed', 'Crashed')) {
    $bad = New-TestTally
    $bad.$field = $null
    $rejected = $false
    try { $null = Resolve-WaitPhaseResult -Raw $bad -Phase 8 }
    catch { $rejected = $true }
    Assert-True $rejected "Null $field was accepted."
}
$bad = New-TestTally
$bad.Failed = -1
$rejected = $false
try { $null = Resolve-WaitPhaseResult -Raw $bad -Phase 8 }
catch { $rejected = $true }
Assert-True $rejected 'Negative failure count was accepted.'

$wait = Get-TestFunction 'Wait-Phase'
$tallyReturns = @($wait.Body.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ReturnStatementAst] -and
            $node.Pipeline.Extent.Text -eq '$return'
        }, $true))
Assert-True ($tallyReturns.Count -eq 3) 'Wait-Phase tally return count changed unexpectedly.'
foreach ($tallyReturn in $tallyReturns) {
    $siblings = @($tallyReturn.Parent.Statements)
    $returnIndex = [array]::IndexOf($siblings, $tallyReturn)
    $previous = if ($returnIndex -gt 0) { $siblings[$returnIndex - 1] } else { $null }
    Assert-True ($previous -is [Management.Automation.Language.AssignmentStatementAst] -and
        $previous.Left.Extent.Text -eq '$return.Elapsed') `
        "Wait-Phase returns a tally at line $($tallyReturn.Extent.StartLineNumber) before finalizing Elapsed."
}

$start = Get-TestFunction 'Start-Phase'
$phase0Statement = $start.Body.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -eq '$Phase -eq 0'
} | Select-Object -First 1
$phase0 = [scriptblock]::Create($phase0Statement.Extent.Text + "`nreturn `$true")
function Get-VM {
    param($ErrorAction)
    if ($script:inventoryThrows) { throw 'Inventory unavailable' }
    foreach ($name in $script:registeredNames) { [pscustomobject]@{ Name = $name } }
}
$Phase = 0
$script:inventoryThrows = $false
$script:registeredNames = @('DC1')
$deployConfig = [pscustomobject]@{
    parameters = [pscustomobject]@{ RequireExistingVMs = $true; AllowAADClientRecovery = $false }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'DC1'; role = 'DC'; hidden = $false }
        [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; hidden = $false }
    )
}
Assert-True ((& $phase0) -eq $false) 'Resume with one missing VM passed Phase 0.'
Assert-True ($script:messages[-1] -match 'PRI1') 'Missing VM was not named.'
$script:registeredNames = @()
Assert-True ((& $phase0) -eq $false) 'Resume with no VMs passed Phase 0.'
$deployConfig.parameters.RequireExistingVMs = $false
Assert-True ((& $phase0) -eq $true) 'New deployment cannot create ordinary missing VMs.'
$deployConfig.virtualMachines[1].hidden = $true
Assert-True ((& $phase0) -eq $false) 'Missing hidden dependency passed Phase 0.'
$deployConfig.virtualMachines[1].hidden = $false
$deployConfig.virtualMachines[1].role = 'AADClient'
$deployConfig.parameters.RequireExistingVMs = $true
$script:registeredNames = @('DC1')
Assert-True ((& $phase0) -eq $false) 'Missing AADClient passed with Phase 1 explicitly excluded.'
$deployConfig.parameters.AllowAADClientRecovery = $true
Assert-True ((& $phase0) -eq $true) 'AADClient automatic Phase 1 recovery was blocked.'
$script:inventoryThrows = $true
Assert-True ((& $phase0) -eq $false) 'Inventory query failure passed Phase 0.'

$cmStatement = $start.Body.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -eq '$Phase -eq 8 -or $Phase -eq 9'
} | Select-Object -First 1
$cmPreflight = [scriptblock]::Create($cmStatement.Extent.Text + "`nreturn `$true")
function Get-Phase8ConfigurationData { param($deployConfig) $script:cmConfig }
function Get-Phase9ConfigurationData { param($deployConfig) $script:cmConfig }
function Get-MissingHyperVNodes {
    param($ConfigurationData)
    if ($script:cmProbeThrows) { throw 'CM inventory unavailable' }
    if ($ConfigurationData) { $script:missingNodes }
}
function Invoke-Phase8PreInstallSnapshot {
    param($deployConfig)
    $script:cmCalls += 'snapshot'
    return $script:snapshotReady
}
function Mount-CmIsoForPhase { param($deployConfig, $Phase) $script:cmCalls += 'mount' }
$script:cmConfig = [pscustomobject]@{ AllNodes = @([pscustomobject]@{ NodeName = 'PRI1' }) }
$script:cmProbeThrows = $false
$script:snapshotReady = $true
foreach ($Phase in @(8, 9)) {
    $script:cmCalls = @()
    $script:missingNodes = @('PRI1')
    Assert-True ((& $cmPreflight) -eq $false) "Phase $Phase missing target was accepted."
    Assert-True ($script:cmCalls.Count -eq 0) "Phase $Phase touched snapshots/media before inventory failure."
    $script:missingNodes = @()
    Assert-True ((& $cmPreflight) -eq $true) "Phase $Phase valid targets failed."
    $expected = if ($Phase -eq 8) { 'snapshot,mount' } else { 'mount' }
    Assert-True (($script:cmCalls -join ',') -eq $expected) "Phase $Phase snapshot/media ordering changed."
    if ($Phase -eq 8) {
        $script:cmCalls = @()
        $script:snapshotReady = $false
        Assert-True ((& $cmPreflight) -eq $false) 'Phase 8 accepted an incomplete rollback snapshot.'
        Assert-True (($script:cmCalls -join ',') -eq 'snapshot') 'Phase 8 mounted media after snapshot failure.'
        $script:snapshotReady = $true
    }
    $script:cmCalls = @()
    $script:cmProbeThrows = $true
    Assert-True ((& $cmPreflight) -eq $false) "Phase $Phase inventory exception passed."
    Assert-True ($script:cmCalls.Count -eq 0) 'Inventory exception allowed media preparation.'
    $script:cmProbeThrows = $false
}
$script:cmConfig = $null
$script:cmCalls = @()
Assert-True ((& $cmPreflight) -eq $true) 'No-op CM phase failed.'
Assert-True ($script:cmCalls.Count -eq 0) 'No-op CM phase mounted media.'

$text = $start.Extent.Text
$gateStart = $text.IndexOf('    # Start Phase')
$gateEnd = $text.IndexOf('    # Phase 2 builds tool zips', $gateStart)
$dispatchGate = [scriptblock]::Create($text.Substring($gateStart, $gateEnd - $gateStart) + "`nreturn (`$result.Failed -eq 0)")
function Start-PhaseJobs { param($Phase, $deployConfig) $script:dispatchResult }
function Wait-Phase {
    param($Phase, $Jobs, $AdditionalData, $DeployConfig)
    $script:waitCalls++
    if ($script:waitThrows) { throw 'Job wait failed' }
    $script:waitResult
}
function Write-OrangePoint { param($Message, $ForegroundColor) }
$Phase = 8
$script:waitCalls = 0
foreach ($preflight in @(
        $null,
        [pscustomobject]@{ Failed = 0; Jobs = 0; Applicable = $true },
        [pscustomobject]@{ Failed = 1; Jobs = 0; Applicable = $false },
        [pscustomobject]@{ Failed = 8; Jobs = 0; Applicable = $true },
        [pscustomobject]@{ Failed = 1; Jobs = 0; Applicable = $true; PreflightFailed = $true }
    )) {
    $script:dispatchResult = $preflight
    Assert-True ((& $dispatchGate) -eq $false) 'Preflight failure advanced to job waiting.'
}
Assert-True ($script:waitCalls -eq 0) 'Job waiter received failed preflight.'
$script:dispatchResult = [pscustomobject]@{ Failed = 0; Jobs = @([pscustomobject]@{ Id = 1 }); Applicable = $true }
$script:waitResult = $null
$script:waitThrows = $false
Assert-True ((& $dispatchGate) -eq $false) 'Null wait result advanced deployment.'
$script:waitThrows = $true
Assert-True ((& $dispatchGate) -eq $false) 'Wait exception advanced deployment.'
$script:waitThrows = $false
$script:waitResult = New-TestTally
Assert-True ((& $dispatchGate) -eq $true) 'Successful wait result failed deployment.'
$script:waitResult.Failed = 1
Assert-True ((& $dispatchGate) -eq $false) 'Failed wait result advanced deployment.'
$script:waitResult = New-TestTally
$script:dispatchResult.Failed = 1
Assert-True ((& $dispatchGate) -eq $false) 'Partial dispatch failure was lost after successful jobs.'
$script:dispatchResult = [pscustomobject]@{ Failed = 0; Jobs = 0; Applicable = $false }
Assert-True ((& $dispatchGate) -eq $true) 'Valid no-op phase failed.'

$jobsText = (Get-TestFunction 'Start-PhaseJobs').Extent.Text
foreach ($marker in @('$missingDispatchNodes.Count -gt 0', '$missingHyperVNodes.Count -gt 0')) {
    $offset = $jobsText.IndexOf($marker)
    $nextReturnEnd = $jobsText.IndexOf("`n            }", $offset)
    Assert-True ($jobsText.Substring($offset, $nextReturnEnd - $offset) -match 'PreflightFailed\s*=\s*\$true') 'Missing-node return lacks preflight failure flag.'
}
$wait = Get-TestFunction 'Wait-Phase'
$waitTry = $wait.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
Assert-True ($waitTry.CatchClauses[-1].Body.Extent.Text -match '\bthrow\b') 'Wait-Phase swallows exceptions.'

$newLabPath = Join-Path $root 'New-Lab.ps1'
$newLabAst = [Management.Automation.Language.Parser]::ParseFile($newLabPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "New-Lab parse errors: $($errors -join '; ')" }
$requireAssignment = $newLabAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$requireExistingVMs'
    }, $true) | Select-Object -First 1
foreach ($case in @(
        @{ Start = 0; Selected = $null; Skipped = $null; Required = $false },
        @{ Start = 1; Selected = $null; Skipped = $null; Required = $false },
        @{ Start = 8; Selected = $null; Skipped = $null; Required = $true },
        @{ Start = 0; Selected = 10; Skipped = $null; Required = $true },
        @{ Start = 0; Selected = @(1, 2); Skipped = $null; Required = $false },
        @{ Start = 0; Selected = $null; Skipped = @(1); Required = $true }
    )) {
    $StartPhase = $case.Start; $Phase = $case.Selected; $SkipPhase = $case.Skipped
    . ([scriptblock]::Create($requireAssignment.Extent.Text))
    Assert-True ($requireExistingVMs -eq $case.Required) 'Phase 1 selection was classified incorrectly.'
}
$cleanupGuard = $newLabAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$prepared' -and
        $node.Extent.Text -match 'Remove-VirtualMachine'
    }, $true)
Assert-True (@($cleanupGuard).Count -eq 1) 'Failed Phase 0 can still run incomplete-VM removal.'
Write-Host 'PASS -- resume inventory, CM preflight, and phase-result failures stop deployment.'

& {
    foreach ($name in @('Get-JobWaitTargets','Test-JobTransportCloseFalseFailure','Wait-Phase')) {
        . ([scriptblock]::Create((Get-TestFunction $name).Extent.Text))
    }
    function Invoke-DependencyFailureFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'The extracted production waiter reads the fixture logging context dynamically.')]
        [CmdletBinding()]
        param([string]$Mode)
        $state = @{
            Polls=0; Stops=[Collections.Generic.List[string]]::new(); Logs=[Collections.Generic.List[string]]::new()
        }
        function New-FixtureJob {
            param($Id,$Name,$State,$Status,$Output)
            $job = [pscustomobject]@{
                Id=$Id; Name=$Name; State=$State; Status=$Status; Output=@($Output); Progress=@(); Error=@()
                PSBeginTime=Get-Date; PSEndTime=Get-Date
                JobStateInfo=[pscustomobject]@{ Reason=[InvalidOperationException]::new('fixture transport close failure') }
            }
            $job | Add-Member ScriptMethod StopJobAsync {
                $state.Stops.Add($this.Name)
                $this.State = if ($Mode -eq 'RunningFailurePendingStop') { 'Stopping' } else { 'Stopped' }
            }
            $job
        }
        $failure = [pscustomobject]@{ Text='Primary setup reported a terminal failure; collecting diagnostics'; LogLevel=3; ForegroundColor='Red' }
        $sourceState = if ($Mode -eq 'FailedJob') { 'Failed' } else { 'Running' }
        $sourceOutput = if ($Mode -eq 'FailedJob') { @() } else { @($failure) }
        $source = New-FixtureJob 3 'FAB-PS1SITE [Primary]' $sourceState '' $sourceOutput
        $cas = New-FixtureJob 1 'FAB-CS1SITE [CAS]' 'Running' `
            'Setting up ConfigMgr. Status: Waiting for Primary site PS1 (FAB-PS1SITE) to show up via Get-CMSiteSystemServer (26m elapsed)' @()
        $sql = New-FixtureJob 2 'FAB-CS1SQLAO1 [SQLAO]' 'Running' `
            "WaitForWorkflowReceipt: Waiting for ScriptWorkflow receipt on FAB-CS1SITE (elapsed=131.7m, expected='current', completed='<missing>')" @()
        $independent = New-FixtureJob 4 'FAB-OTHER [DomainMember]' 'Completed' '' @(
            [pscustomobject]@{ Text='Independent work completed'; LogLevel=1; ForegroundColor='Green' }
        )
        $jobs = [Collections.ArrayList]@($cas,$sql,$source,$independent)
        function Get-JobStreamSource { param($Job) $Job }
        function Set-PS7ProgressWidth {}
        function Write-Host { param($Object,[switch]$NoNewline) }
        function Write-JobProgress {
            param($Job,$AdditionalData)
            $global:JobProgressHistory[$Job.Id]=@{ Status=$Job.Status }
        }
        function Write-JobProgressDiag { param($Job) }
        function Write-Progress2 { param($Activity,$Id,$Status,$PercentComplete,[switch]$Completed,[switch]$Force) }
        function Write-Log {
            param($Message,[switch]$Failure,[switch]$Warning,[switch]$LogOnly,[switch]$Verbose)
            $state.Logs.Add("$Message")
        }
        function Write-RedX { param($Message,$ForegroundColor) $state.Logs.Add("$Message") }
        function Write-GreenCheck { param($Message,$ForegroundColor) }
        function Write-OrangePoint { param($Message,$ForegroundColor) }
        function Stop-Job { throw 'Dependent cancellation called synchronous Stop-Job and could block in remoting teardown.' }
        function Remove-Job { param($Job,[switch]$Force,$ErrorAction) }
        function Get-Job { param($ErrorAction) }
        function Get-PSSession { param($ErrorAction) }
        function Write-Phase8DiagnosticSnapshot { param($Path,$Jobs,$PhaseStart,$Trigger,$DeployConfig,[switch]$IncludeHostMetrics) }
        function Start-Sleep {
            param($Milliseconds)
            $state.Polls++
            if ($state.Polls -gt 35) { throw 'A known failed dependency left the phase waiting past its test budget.' }
            if ($Mode -like 'RunningFailure*' -and $state.Polls -eq 3) { $source.State='Completed' }
        }
        $Common=[pscustomobject]@{ LogPath='C:\fixture\VMBuild.log'; PS7=$false }
        $global:BuildStats=$null
        $result = @(Wait-Phase -Phase 8 -Jobs $jobs)
        Assert-True ($result.Count -eq 1 -and $result[0].Failed -eq 3 -and $result[0].Success -eq 1 -and
            $result[0].Crashed.Count -eq 0 -and $jobs.Count -eq 0) "$Mode lost failure accounting, independent work, or phase completion."
        Assert-True (($state.Stops -join ',') -eq 'FAB-CS1SITE [CAS],FAB-CS1SQLAO1 [SQLAO]') `
            "$Mode did not stop the actual dependent chain, or stopped source diagnostic collection."
        if ($Mode -like 'RunningFailure*') {
            Assert-True ($state.Polls -le 4) 'Terminal source output was not propagated while its diagnostics were still collecting.'
        }
    }
    Invoke-DependencyFailureFixture RunningFailure
    Invoke-DependencyFailureFixture RunningFailurePendingStop
    Invoke-DependencyFailureFixture FailedJob
}
& {
    $cleanupSelection = @($newLabAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$runningJobs' -and
                $node.Right.Extent.Text.Contains('PSEventJob')
            }, $true))
    Assert-True ($cleanupSelection.Count -eq 1) 'End-of-run job cleanup selection was not found.'
    function Get-Job {
        [pscustomobject]@{ Name='active'; State='Running' }
        [pscustomobject]@{ Name='cancelling'; State='Stopping' }
        [pscustomobject]@{ Name='finished'; State='Completed' }
    }
    $selection = [scriptblock]::Create($cleanupSelection[0].Extent.Text + "`n`$runningJobs.Name")
    Assert-True ((@(& $selection) -join ',') -eq 'active,cancelling') 'Asynchronously stopping workers bypassed bounded end-of-run child-process cleanup.'
}
Write-Host 'PASS -- terminal Primary failures release CAS/SQL wait chains without blocking cancellation or stopping independent work.'
