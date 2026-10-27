<#
.SYNOPSIS
    Verifies deployment-only emergency mode without running a deployment or touching Hyper-V.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$runnerPath = Join-Path $PSScriptRoot 'Invoke-MainToDevelopExpansionTest.ps1'
$startPath = Join-Path $RootPath 'Start-Test.ps1'
$continuousPath = Join-Path $PSScriptRoot 'Invoke-MemLabsContinuousTests.ps1'
. (Join-Path $PSScriptRoot 'Common.TestHistory.ps1')

function Import-EmergencyFunction {
    param([string]$Path, [string]$Name)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors -join '; ') }
    $found = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($found.Count -ne 1) { throw "Expected one $Name definition." }
    $scriptRoot = (Split-Path $Path -Parent).Replace("'", "''")
    [scriptblock]::Create($found[0].Extent.Text.Replace('$PSScriptRoot', "'$scriptRoot'"))
}
function Assert-Emergency {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-EmergencyThrows {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Emergency ($message -like $Pattern) "Expected '$Pattern', got '$message'."
}
function New-EmergencyState {
    [ordered]@{
        DevelopRevision = ('a' * 40); QualificationMode = 'Pinned'; CurrentStep = $null
        CompletedSteps = @('demo|main|A')
        Baselines = @{ demo = @([pscustomobject]@{ Name = 'DEMO-DC1'; Id = "$script:VmId" }) }
        DomainIdentities = @{}; DevelopIdentities = @{}; DevelopDomainIdentities = @{}
    }
}

foreach ($name in @('Set-CrossRevisionEmergencyState', 'Register-CrossRevisionSkippedTest',
        'Initialize-CrossRevisionMaintenanceState', 'Invoke-CrossRevisionMaintenanceGate',
        'Invoke-CrossRevisionRecoveryGate', 'Resume-CrossRevisionMaintenanceGate',
        'Assert-CrossRevisionMaintenanceFamilyGate', 'Get-DomainIdentity', 'Assert-DomainIdentity',
        'Assert-DevelopStageComplete', 'Wait-CrossRevisionRetainedVmReady',
        'Save-CrossRevisionExpansionIdentity', 'Invoke-NewLabFixture',
        'Assert-CrossRevisionCheckpointCanAdvance', 'Get-OrderedCrossRevisionPlan', 'Start-Step')) {
    . (Import-EmergencyFunction $runnerPath $name)
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-emergency-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $tempRoot -ItemType Directory
$script:SkipTests = $true
$script:VmId = [guid]::NewGuid()
$developCommit = 'a' * 40
$script:State = New-EmergencyState
$script:SavedStates = 0
$script:AuxiliaryCalls = 0
function Save-State { $script:SavedStates++ }
function Get-CrossRevisionMaintenanceTargets {
    param($Identity)
    $script:AuxiliaryCalls++
    throw 'Auxiliary target inspection was reached.'
}
function Invoke-ChildScript { throw 'An auxiliary child was launched.' }
function Invoke-Command { throw 'A guest validation command was launched.' }
function New-DomainCredentials { throw 'Guest validation credentials were requested.' }

try {
    foreach ($path in @($startPath, $runnerPath, $continuousPath)) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-Emergency ('SkipTests' -in $parameters) "Missing -SkipTests on $path."
    }
    $startAst = [Management.Automation.Language.Parser]::ParseFile($startPath, [ref]$null, [ref]$null)
    Assert-Emergency ('SkipTest' -in @($startAst.ParamBlock.Parameters.Name.VariablePath.UserPath)) 'The existing singular family-selection option was lost.'

    $script:State.CurrentStep = "demo|maintenance|post|2|B.json|$developCommit"
    $pending = $script:State.CurrentStep
    Set-CrossRevisionEmergencyState $script:State
    Assert-Emergency ($script:State.TestsSkipped -and $script:State.QualificationMode -eq 'EmergencySkipTests') 'Emergency mode was not recorded.'
    Assert-Emergency (-not $script:State.CurrentStep -and $script:State.EmergencyResumeFamily -eq 'demo') 'Interrupted qualification was not abandoned with a family resume hint.'
    Assert-Emergency ($script:State.SkippedTestSteps[$pending].Status -eq 'Skipped' -and
        $script:State.CompletedSteps -notcontains $pending -and $script:State.MaintenanceReceipts.Count -eq 0) 'Skipped qualification was fabricated as passed coverage.'
    Assert-Emergency ($script:State.CompletedSteps -contains 'demo|develop|2|B.json') 'A deployment already completed before postconditions would be replayed unnecessarily.'
    Assert-Emergency ($script:State.Baselines.demo[0].Id -eq "$script:VmId") 'Emergency mode changed saved VM identity.'
    $ordered = @(Get-OrderedCrossRevisionPlan -Plan @(
            [pscustomobject]@{ Family = 'other' }, [pscustomobject]@{ Family = 'demo' }
        ) -CurrentStep "$($script:State.EmergencyResumeFamily)|resume")
    Assert-Emergency ($ordered[0].Family -eq 'demo') 'The interrupted family lost resume priority.'
    Start-Step 'demo|develop|2|B.json'
    Assert-Emergency (-not $script:State.Contains('EmergencyResumeFamily')) 'Actual deployment did not clear the temporary family hint.'

    $recoveryState = New-EmergencyState
    $recoveryState.CurrentStep = "demo|maintenance|recovery|$developCommit"
    Set-CrossRevisionEmergencyState $recoveryState
    Assert-Emergency ([bool]$recoveryState.EmergencyRecoveryInterrupted) 'Abandoned recovery faults were not flagged.'
    $legacy = [ordered]@{ CurrentStep = 'demo|develop|2|B.json'; CompletedSteps = @('demo|main|A', 'demo|develop|1|B.json') }
    Initialize-CrossRevisionMaintenanceState $legacy
    Assert-Emergency ($legacy.TestsSkipped -and -not $legacy.Contains('MaintenanceContractVersion')) 'Emergency mode incorrectly claimed the mandatory qualification contract.'

    foreach ($mode in @('Preflight', 'Baseline', 'Postconditions', 'Recovery')) {
        $result = @(Invoke-CrossRevisionMaintenanceGate -Key "demo|maintenance|$mode|$developCommit" -Mode $mode `
                -Family 'demo' -Identity @() -RequireCmCoverage -WorktreePath 'C:\unused')
        Assert-Emergency ($result.Count -eq 0) 'A skipped gate returned a passing receipt.'
    }
    $null = Invoke-CrossRevisionRecoveryGate -Family 'demo' -Identity @() -WorktreePath 'C:\unused'
    Assert-CrossRevisionMaintenanceFamilyGate -Family 'demo' -RequireCmCoverage
    $script:State.CurrentStep = "demo|maintenance|post|2|B.json|$developCommit"
    Resume-CrossRevisionMaintenanceGate -WorktreePath 'C:\unused'
    Assert-Emergency (-not $script:State.CurrentStep -and $script:State.MaintenanceReceipts.Count -eq 0 -and
        $script:AuxiliaryCalls -eq 0) 'Emergency qualification/resume performed auxiliary work or created receipts.'
    Get-DomainIdentity -Config ([pscustomobject]@{ vmOptions = @{ domainName = 'demo.test' } })
    Assert-DomainIdentity -Identity $null
    Assert-DevelopStageComplete -Config $null -FixtureName 'B.json'

    $script:PowerState = 'Off'
    $script:Starts = 0
    function Get-VM {
        param($Name, $ErrorAction)
        [pscustomobject]@{ Name = $Name; Id = $script:VmId; State = $script:PowerState; Notes = 'not valid guest metadata' }
    }
    function Start-VM { param($VM, $ErrorAction) $script:Starts++; $script:PowerState = 'Running' }
    $target = [pscustomobject]@{ Name = 'DEMO-DC1'; Id = "$script:VmId" }
    Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 2
    Assert-Emergency ($script:Starts -eq 1) 'Emergency power preparation did not start the verified Off VM once.'
    $target.Id = [guid]::NewGuid().ToString()
    Assert-EmergencyThrows { Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 1 } '*replaced*'
    Assert-Emergency ($script:Starts -eq 1) 'Emergency mode bypassed physical VM identity protection.'

    $script:SkipTests = $false
    Assert-EmergencyThrows {
        Invoke-CrossRevisionMaintenanceGate -Key 'normal' -Mode Baseline -Identity @()
    } '*Auxiliary target inspection*'
    Assert-Emergency ($script:AuxiliaryCalls -eq 1) 'Default mode stopped enforcing maintenance gates.'
    $script:SkipTests = $true
    & {
        function Test-GitCommitAncestor { param($Ancestor, $Descendant) return $true }
        $state = New-EmergencyState
        $state.CurrentStep = 'demo|develop|2|B.json'
        $plan = @([pscustomobject]@{ Family = 'demo'; FollowOns = @([pscustomobject]@{ Name = 'B.json' }) })
        Assert-CrossRevisionCheckpointCanAdvance -State $state -Plan $plan -NewDevelopCommit ('b' * 40) -SkipTests
        Assert-EmergencyThrows {
            Assert-CrossRevisionCheckpointCanAdvance -State $state -Plan $plan -NewDevelopCommit ('b' * 40)
        } '*no saved baseline domain identity*'
        $state.Baselines.Clear()
        Assert-EmergencyThrows {
            Assert-CrossRevisionCheckpointCanAdvance -State $state -Plan $plan -NewDevelopCommit ('b' * 40) -SkipTests
        } '*no saved baseline VM identity*'
    }

    & {
        $fixtureRoot = Join-Path $tempRoot 'pinned'
        $null = New-Item -Path (Join-Path $fixtureRoot 'vmbuild') -ItemType Directory -Force
        $fixtureScript = Join-Path $fixtureRoot 'vmbuild\New-Lab.ps1'
        [IO.File]::WriteAllText($fixtureScript, 'param($Configuration, [switch]$AutoSnapshot, [switch]$KeepFailedVMs, [switch]$SkipValidation, [int[]]$SkipPhase, [int]$StartPhase, [switch]$Restore)')
        $script:PinnedParameters = [Collections.Generic.List[object]]::new()
        $script:PinnedExits = [Collections.Generic.Queue[int]]::new()
        $script:PinnedExits.Enqueue(55)
        $script:PinnedExits.Enqueue(0)
        function Invoke-ChildScript {
            param($WorktreePath, $ScriptName, $Parameters, $Label)
            $copy = [ordered]@{}
            foreach ($key in $Parameters.Keys) { $copy[$key] = $Parameters[$key] }
            $script:PinnedParameters.Add($copy)
            $script:LastChildResult = $null
            if ($script:PinnedExits.Count) { return $script:PinnedExits.Dequeue() }
            return 0
        }
        Assert-Emergency ((Invoke-NewLabFixture -WorktreePath $fixtureRoot -FixturePath 'fixture.json' -Label 'demo') -eq 0) 'Pinned emergency deployment did not retain restart behavior.'
        foreach ($parameters in $script:PinnedParameters) {
            Assert-Emergency ($parameters.SkipValidation -and @($parameters.SkipPhase) -contains 11) 'Pinned restart lost configuration/Phase 11 skips.'
        }
        Assert-Emergency ($script:PinnedParameters.Count -eq 2) 'Pinned DSC-rebuild restart count changed.'
        $script:SkipTests = $false
        $null = Invoke-NewLabFixture -WorktreePath $fixtureRoot -FixturePath 'fixture.json' -Label 'normal'
        $normal = $script:PinnedParameters[$script:PinnedParameters.Count - 1]
        Assert-Emergency (-not $normal.Contains('SkipValidation') -and -not $normal.Contains('SkipPhase')) 'Default pinned deployment acquired emergency flags.'
        $script:SkipTests = $true
        $script:PinnedExits.Enqueue(9)
        Assert-Emergency ((Invoke-NewLabFixture -WorktreePath $fixtureRoot -FixturePath 'fixture.json' -Label 'failed-deploy') -eq 9) 'Emergency mode suppressed an actual deployment failure.'
        [IO.File]::WriteAllText($fixtureScript, 'param($Configuration)')
        Assert-EmergencyThrows {
            Invoke-NewLabFixture -WorktreePath $fixtureRoot -FixturePath 'fixture.json' -Label 'unsupported'
        } '*requires -SkipValidation and -SkipPhase support*'
    }

    & {
        . (Import-EmergencyFunction $startPath 'Invoke-NewLab')
        $script:StandardParameters = [Collections.Generic.List[object]]::new()
        $script:StandardExits = [Collections.Generic.Queue[int]]::new()
        $script:StandardExits.Enqueue(55)
        $script:StandardExits.Enqueue(0)
        function Resolve-Path { param($LiteralPath, $ErrorAction) [pscustomobject]@{ Path = (Join-Path $RootPath 'New-Lab.ps1') } }
        function Get-Command { param($Name, $ErrorAction) [pscustomobject]@{ Source = 'Invoke-EmergencyNewLabEngine' } }
        function Invoke-EmergencyNewLabEngine {
            $arguments = @($args)
            $parameterPath = $arguments[[array]::IndexOf($arguments, '-ParameterPath') + 1]
            $resultPath = $arguments[[array]::IndexOf($arguments, '-ResultPath') + 1]
            $token = $arguments[[array]::IndexOf($arguments, '-InvocationToken') + 1]
            $script:StandardParameters.Add((Import-Clixml -LiteralPath $parameterPath))
            $code = if ($script:StandardExits.Count) { $script:StandardExits.Dequeue() } else { 0 }
            [ordered]@{ InvocationToken = $token; ExitCode = $code; ResumeInfo = $null; ResumeCommand = $null } |
                ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
            $global:LASTEXITCODE = $code
        }
        Assert-Emergency ((Invoke-NewLab -ConfigFile 'fixture.json' -StartPhase 8 -Restore) -eq 0) 'Standard emergency deployment did not preserve restart semantics.'
        foreach ($parameters in $script:StandardParameters) {
            Assert-Emergency ($parameters.SkipValidation -and @($parameters.SkipPhase) -contains 11 -and
                $parameters.StartPhase -eq 8 -and $parameters.Restore) 'Standard restart/resume lost the emergency phase controls.'
        }
        $before = $script:StandardParameters.Count
        Assert-Emergency ((Invoke-NewLab -ConfigFile 'fixture.json' -StartPhase 11) -eq 0) 'A validation-only resume was not omitted.'
        Assert-Emergency ($script:StandardParameters.Count -eq $before) 'Phase 11-only resume relaunched deployment unnecessarily.'
        $script:SkipTests = $false
        $null = Invoke-NewLab -ConfigFile 'fixture.json'
        $normal = $script:StandardParameters[$script:StandardParameters.Count - 1]
        Assert-Emergency (-not $normal.Contains('SkipValidation') -and -not $normal.Contains('SkipPhase')) 'Default standard deployment acquired emergency flags.'
        $script:SkipTests = $true
    }

    & {
        . (Import-EmergencyFunction $startPath 'Invoke-MainToDevelopExpansionCycle')
        $script:CycleArguments = [Collections.Generic.List[object]]::new()
        $script:CycleExits = [Collections.Generic.Queue[int]]::new()
        $script:CycleExits.Enqueue(56)
        $script:CycleExits.Enqueue(0)
        function Join-Path {
            param($Path, $ChildPath)
            if ($ChildPath -eq 'pwsh.exe') { return 'Invoke-EmergencyCycleEngine' }
            Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
        }
        function Invoke-EmergencyCycleEngine {
            $script:CycleArguments.Add(@($args))
            $global:LASTEXITCODE = if ($script:CycleExits.Count) { $script:CycleExits.Dequeue() } else { 0 }
        }
        function Invoke-MixedRevisionGitRefresh { param($Context) return ('c' * 40) }
        $code = Invoke-MainToDevelopExpansionCycle -PinnedMainRevision ('b' * 40) -PinnedDevelopRevision ('a' * 40) `
            -RunAll -StateRoot 'C:\custom-state' -SkipTests
        Assert-Emergency ($code -eq 0 -and $script:CycleArguments.Count -eq 2) 'Mixed-revision family-boundary restart changed.'
        foreach ($arguments in $script:CycleArguments) {
            Assert-Emergency ('-SkipTests' -in $arguments -and 'C:\custom-state' -in $arguments) 'Family-boundary restart dropped SkipTests or state selection.'
        }
        $null = Invoke-MainToDevelopExpansionCycle -PinnedMainRevision ('b' * 40) -PinnedDevelopRevision ('a' * 40) -RunAll
        Assert-Emergency ('-SkipTests' -notin $script:CycleArguments[$script:CycleArguments.Count - 1]) 'Default mixed-revision launch acquired an emergency switch.'
    }

    & {
        param([switch]$SkipTests, [switch]$SkipVMNoteCompatibility, [string]$MainRevision)
        $guards = @($startAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -eq '$SkipTests.IsPresent' -and
                    $node.Extent.Text -like '*Invoke-VMNoteCompatibilityPreflight*'
                }, $true))
        Assert-Emergency ($guards.Count -eq 1) 'The VM-note preflight has no unambiguous emergency bypass.'
        $script:CompatibilityCalls = 0
        function Invoke-VMNoteCompatibilityPreflight { param($PinnedMainRevision) $script:CompatibilityCalls++; return $true }
        & ([scriptblock]::Create($guards[0].Extent.Text))
        Assert-Emergency ($script:CompatibilityCalls -eq 0) 'VM-note compatibility still ran in emergency mode.'
        $SkipTests = [switch]::new($false)
        & ([scriptblock]::Create($guards[0].Extent.Text))
        Assert-Emergency ($script:CompatibilityCalls -eq 1) 'Default VM-note compatibility stopped running.'
    } -SkipTests -MainRevision ('b' * 40)

    & {
        param([Collections.IDictionary]$checkpointState, [switch]$SkipTests)
        $runnerAst = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$null, [ref]$null)
        $guards = @($runnerAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -eq '$checkpointState.TestsSkipped -and -not $SkipTests'
                }, $true))
        Assert-Emergency ($guards.Count -eq 1) 'The emergency checkpoint has no explicit qualification guard.'
        Assert-EmergencyThrows { & ([scriptblock]::Create($guards[0].Extent.Text)) } '*unqualified*'
        $SkipTests = [switch]::new($true)
        & ([scriptblock]::Create($guards[0].Extent.Text))
    } -checkpointState ([ordered]@{ TestsSkipped = $true })

    & {
        $historyPath = Join-Path $tempRoot 'history.jsonl'
        $now = [DateTime]::UtcNow
        Write-MemLabsTestHistoryEvent -Path $historyPath -Event ([pscustomobject]@{
                EventType = 'RunCompleted'; CandidateKey = 'Standard|DEMO'; Family = 'DEMO'; Mode = 'Standard'
                StartedUtc = $now.AddMinutes(-10).ToString('o'); CompletedUtc = $now.AddMinutes(-5).ToString('o')
                Success = $true; TestsSkipped = $true; NeedsRerun = $false; DurationSeconds = 60; Commit = ('a' * 40)
            })
        $evidence = @(Get-MemLabsHistoryEvidence -Path $historyPath)
        Assert-Emergency ($evidence.Count -eq 1 -and -not $evidence[0].Success -and
            $evidence[0].DeploymentSucceeded -and $evidence[0].NeedsRerun) 'Skipped validation was credited as a qualified pass.'
        function Get-MemLabsCurrentCommit { param($RepositoryRoot) return ('a' * 40) }
        function Get-MemLabsTestCandidates {
            param($VmbuildRoot)
            foreach ($family in @('DEMO', 'OTHER')) {
                [pscustomobject]@{
                    CandidateKey = "Standard|$family"; Mode = 'Standard'; Family = $family; Suites = @('Core'); IsStress = $false
                    Metadata = [pscustomobject]@{ CoverageTags = @(); EstimatedRequiredGB = 1; VmCount = 1; ConfigNames = @('A.json') }
                }
            }
        }
        function Get-MemLabsBuildStatsEvidence {
            param($VmbuildRoot)
            [pscustomobject]@{
                CandidateKey = 'Standard|DEMO'; Family = 'DEMO'; Mode = 'Standard'; Success = $true
                CompletedUtc = $script:EmergencyStatsTime; DurationSeconds = 60; EvidenceType = 'BuildStats'; Commit = ('a' * 40)
            }
        }
        function git { $global:LASTEXITCODE = 0 }
        $script:EmergencyStatsTime = $now.AddMinutes(-7)
        $ranked = @(Select-MemLabsNextTest -VmbuildRoot $RootPath -HistoryPath $historyPath -AvailableMemoryGB 80)
        $demo = $ranked | Where-Object CandidateKey -eq 'Standard|DEMO'
        Assert-Emergency ($demo.Reasons -contains 'never passed' -and
            $demo.Reasons -contains 'tests skipped; qualification required') 'Raw deployment stats overrode emergency skipped-coverage history.'
        $deploymentRanked = @(Select-MemLabsNextTest -VmbuildRoot $RootPath -HistoryPath $historyPath -AvailableMemoryGB 80 -DeploymentOnly)
        Assert-Emergency ($deploymentRanked[0].CandidateKey -eq 'Standard|OTHER') 'Continuous emergency mode keeps repeating one unqualified deployment instead of continuing scenarios.'
        Write-MemLabsTestHistoryEvent -Path $historyPath -Event ([pscustomobject]@{
                EventType = 'RunStarted'; RunId = 'interrupted-emergency'; CandidateKey = 'Standard|DEMO'
                Family = 'DEMO'; Mode = 'Standard'; TestsSkipped = $true
                StartedUtc = $now.AddMinutes(-4).ToString('o'); Commit = ('a' * 40)
            })
        $script:EmergencyStatsTime = $now.AddMinutes(-3)
        $afterInterrupt = @(Select-MemLabsNextTest -VmbuildRoot $RootPath -HistoryPath $historyPath -AvailableMemoryGB 80)
        $interrupted = $afterInterrupt | Where-Object CandidateKey -eq 'Standard|DEMO'
        Assert-Emergency ($interrupted.Reasons -contains 'never passed' -and
            $interrupted.Reasons -contains 'rerun requested') 'An interrupted emergency run leaked raw deployment stats into qualified success.'
    }

    $continuousSource = Get-Content -LiteralPath $continuousPath -Raw
    Assert-Emergency ($continuousSource.Contains("if (`$SkipTests) { `$arguments += '-SkipTests' }") -and
        $continuousSource.Contains('-DeploymentOnly:$SkipTests')) 'Continuous mode does not forward the emergency option and scheduling scope.'
    Write-Host 'PASS -- Emergency deployment-only mode skips all auxiliary gates and Phase 11, preserves physical identity and actual failures, resumes safely, and records unqualified coverage.'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
}
