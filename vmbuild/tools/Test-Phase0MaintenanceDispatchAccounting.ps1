<#
.SYNOPSIS
    Verifies the Phase 0 mandatory maintenance gate (Start-RequiredExistingVMMaintenance)
    fails closed on job-dispatch and Wait-Phase-accounting problems, instead of silently
    reporting success when a required target was never actually verified.
.DESCRIPTION
    Start-NormalJobs.Failed counts VMs whose job never got created at all -- those VMs
    are absent from its .Jobs list, so Wait-Phase never sees them and cannot report them
    as failed. The gate must therefore check three things before returning success:
      1. Start-NormalJobs reported zero dispatch failures.
      2. Wait-Phase reported zero failures.
      3. Wait-Phase's Success+Failed tally accounts for every dispatched job, and every
         dispatched job accounts for every required (pending) target.
    Any violation must return $false so the caller (New-Lab.ps1) aborts the deployment.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    if (-not $passed) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

$sourcePath = Join-Path $RootPath 'common\Common.Maintenance.ps1'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    Write-Host "SETUP FAIL: no Common.Maintenance.ps1 under $RootPath" -ForegroundColor Red
    exit 2
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $sourcePath).Path, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: Common.Maintenance.ps1 has $(@($parseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}
$definition = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-RequiredExistingVMMaintenance'
        }, $true))
if ($definition.Count -ne 1) {
    Write-Host "SETUP FAIL: expected one Start-RequiredExistingVMMaintenance definition, found $($definition.Count)" -ForegroundColor Red
    exit 2
}
. ([scriptblock]::Create($definition[0].Extent.Text))
$vmMaintenanceDefinition = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-VMMaintenance'
        }, $true))
if ($vmMaintenanceDefinition.Count -ne 1) {
    Write-Host "SETUP FAIL: expected one Start-VMMaintenance definition, found $($vmMaintenanceDefinition.Count)" -ForegroundColor Red
    exit 2
}
. ([scriptblock]::Create($vmMaintenanceDefinition[0].Extent.Text))

# --- Shared mocks / fixtures -------------------------------------------------

$global:Phase10Job = {}
$script:LogMessages = [System.Collections.Generic.List[object]]::new()
$script:LiveVms = @()
$script:GetVmShouldThrow = $false
$script:WaitPhaseCalled = $false
$script:DispatchFailedCount = 0
$script:DispatchJobsToReturn = @()
$script:WaitPhaseResult = $null
$script:LastArgument3 = $null

function Write-Log {
    param(
        [string] $Message,
        [switch] $Activity, [switch] $Failure, [switch] $Success,
        [switch] $SubActivity, [switch] $Warning, [switch] $Verbose, [switch] $LogOnly
    )
    $script:LogMessages.Add([pscustomobject]@{ Message = $Message; Failure = $Failure.IsPresent })
}

function Get-VM {
    param($ErrorAction)
    if ($script:GetVmShouldThrow) { throw 'synthetic Get-VM enumeration failure' }
    return @($script:LiveVms)
}

function Get-VMFixes {
    param([switch] $ReturnDummyList, [object] $VMName, [bool] $NewVM)
    return @([pscustomobject]@{ FixName = 'Fix-Test'; FixVersion = '1.0'; AppliesToExisting = $true })
}

function Test-VMFixApplied {
    param($VMNote, $FixName, $FixVersion)
    return $false
}

function Start-NormalJobs {
    param($machines, $ScriptBlock, $Phase, $argument1, $argument2, $argument3, [switch] $PreferThreadJob)
    $script:LastArgument3 = $argument3
    $requested = @($machines).Count
    $jobs = [System.Collections.ArrayList]::new()
    foreach ($job in @($script:DispatchJobsToReturn)) { $null = $jobs.Add($job) }
    return [pscustomobject]@{
        Failed         = $script:DispatchFailedCount
        Success        = ($requested - $script:DispatchFailedCount)
        Jobs           = $jobs
        Applicable     = $true
        AdditionalData = $null
    }
}

function Wait-Phase {
    param($Phase, $Jobs, $AdditionalData)
    $script:WaitPhaseCalled = $true
    if ($script:DrainJobsDuringWait) {
        while ($Jobs.Count -gt 0) { $Jobs.RemoveAt(0) }
    }
    $script:LastWaitJobsRemaining = $Jobs.Count
    return $script:WaitPhaseResult
}

function Write-Progress2 {}

$script:StartVmFixesCalls = 0
function Start-VMFixes {
    param($VMName, $VMFixes, [switch] $FreshDeployOnly)
    $script:StartVmFixesCalls++
    return $true
}

function New-TestDeployConfig {
    [pscustomobject]@{
        virtualMachines = @(
            [pscustomobject]@{ vmName = 'DISPATCH-A'; hidden = $false },
            [pscustomobject]@{ vmName = 'DISPATCH-B'; hidden = $true }
        )
    }
}

function Reset-TestState {
    $script:LogMessages.Clear()
    $script:WaitPhaseCalled = $false
    $script:GetVmShouldThrow = $false
    $script:LiveVms = @(
        [pscustomobject]@{ Name = 'DISPATCH-A'; Notes = '' }
        [pscustomobject]@{ Name = 'DISPATCH-B'; Notes = '' }
    )
    $script:DispatchFailedCount = 0
    $script:DispatchJobsToReturn = @()
    $script:WaitPhaseResult = $null
    $script:LastArgument3 = $null
    $script:DrainJobsDuringWait = $false
    $script:LastWaitJobsRemaining = $null
}

# --- Scenario A: a dispatch failure must fail the gate, but any job that was
#     created must drain before target ownership is released. ----------------
Reset-TestState
$script:DispatchFailedCount = 1
$script:DispatchJobsToReturn = @([pscustomobject]@{ Id = 1 })
$script:WaitPhaseResult = [pscustomobject]@{ Success = 1; Failed = 0 }
$script:DrainJobsDuringWait = $true
$resultA = Start-RequiredExistingVMMaintenance -DeployConfig (New-TestDeployConfig) -OwnedMutexVmNames @('DISPATCH-A', 'DISPATCH-B')
Assert-Equal $false $resultA 'a Start-NormalJobs dispatch failure fails the gate'
Assert-Equal $true $script:WaitPhaseCalled 'a dispatch failure drains jobs that were created'
Assert-Equal 0 $script:LastWaitJobsRemaining 'dispatch failure leaves no created maintenance job active'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -match 'failed to dispatch' })) 'the dispatch failure is logged as a failure'

# --- Scenario A2: the dispatcher can under-return Jobs while reporting
#     Failed=0. The immutable count must independently fail closed. ----------
Reset-TestState
$script:DispatchFailedCount = 0
$script:DispatchJobsToReturn = @([pscustomobject]@{ Id = 1 })
$script:WaitPhaseResult = [pscustomobject]@{ Success = 1; Failed = 0 }
$script:DrainJobsDuringWait = $true
$resultA2 = Start-RequiredExistingVMMaintenance -DeployConfig (New-TestDeployConfig) -OwnedMutexVmNames @('DISPATCH-A', 'DISPATCH-B')
Assert-Equal $false $resultA2 'too few created jobs fails dispatch even when dispatcher Failed is zero'
Assert-Equal $true $script:WaitPhaseCalled 'created-job count mismatch drains returned jobs'
Assert-Equal 0 $script:LastWaitJobsRemaining 'created-job count mismatch leaves no returned maintenance job active'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -match 'created 1 of 2' })) 'created-job count mismatch logs exact cardinality'

# --- Scenario B: Wait-Phase accounting for fewer jobs than were dispatched
#     (e.g. a lost/unaccounted job) must fail the gate even though Wait-Phase
#     itself reported zero failures. -----------------------------------------
Reset-TestState
$script:DispatchFailedCount = 0
$script:DispatchJobsToReturn = @([pscustomobject]@{ Id = 1 }, [pscustomobject]@{ Id = 2 })
$script:WaitPhaseResult = [pscustomobject]@{ Success = 1; Failed = 0 }
$resultB = Start-RequiredExistingVMMaintenance -DeployConfig (New-TestDeployConfig) -OwnedMutexVmNames @('DISPATCH-A', 'DISPATCH-B')
Assert-Equal $false $resultB 'Wait-Phase accounting for fewer jobs than dispatched fails the gate'
Assert-Equal $true $script:WaitPhaseCalled 'Wait-Phase is called once dispatch succeeded for every target'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -match 'never verified' })) 'the accounting mismatch is logged as a failure'

# --- Scenario C: Wait-Phase reporting an outright failure still fails the
#     gate (regression guard for the pre-existing behavior). ----------------
Reset-TestState
$script:DispatchFailedCount = 0
$script:DispatchJobsToReturn = @([pscustomobject]@{ Id = 1 }, [pscustomobject]@{ Id = 2 })
$script:WaitPhaseResult = [pscustomobject]@{ Success = 1; Failed = 1 }
$resultC = Start-RequiredExistingVMMaintenance -DeployConfig (New-TestDeployConfig) -OwnedMutexVmNames @('DISPATCH-A', 'DISPATCH-B')
Assert-Equal $false $resultC 'a Wait-Phase-reported failure still fails the gate'

# --- Scenario D: fully accounted-for success dispatches and completes for
#     every required target -- the gate must return $true. ------------------
Reset-TestState
$script:DispatchFailedCount = 0
$script:DispatchJobsToReturn = @([pscustomobject]@{ Id = 1 }, [pscustomobject]@{ Id = 2 })
$script:WaitPhaseResult = [pscustomobject]@{ Success = 2; Failed = 0 }
$resultD = Start-RequiredExistingVMMaintenance -DeployConfig (New-TestDeployConfig) -OwnedMutexVmNames @('DISPATCH-A', 'DISPATCH-B')
Assert-Equal $true $resultD 'fully dispatched and fully accounted-for success returns $true'
Assert-Equal $true $script:LastArgument3 'the mandatory gate passes the in-progress override to its dispatcher'

# --- Scenario D2: the real Wait-Phase drains the mutable collection while
#     accounting completed jobs. The gate must use the pre-wait dispatch count,
#     not the now-empty collection. ------------------------------------------
Reset-TestState
$script:DispatchJobsToReturn = @([pscustomobject]@{ Id = 1 }, [pscustomobject]@{ Id = 2 })
$script:WaitPhaseResult = [pscustomobject]@{ Success = 2; Failed = 0 }
$script:DrainJobsDuringWait = $true
$resultD2 = Start-RequiredExistingVMMaintenance -DeployConfig (New-TestDeployConfig) -OwnedMutexVmNames @('DISPATCH-A', 'DISPATCH-B')
Assert-Equal $true $resultD2 'fully accounted success remains successful when Wait-Phase drains the job collection'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Message -match 'Dispatched: 2 of 2; Success: 2; Failures: 0' })) 'maintenance summary retains the immutable pre-wait dispatch count'

# --- Scenario E: live Hyper-V inventory cannot be enumerated at all -- must
#     fail closed (regression guard), never silently read as zero targets. --
Reset-TestState
$script:GetVmShouldThrow = $true
$resultE = Start-RequiredExistingVMMaintenance -DeployConfig (New-TestDeployConfig) -OwnedMutexVmNames @('DISPATCH-A', 'DISPATCH-B')
Assert-Equal $false $resultE 'an inventory enumeration failure fails the gate (fail closed)'
Assert-Equal $false $script:WaitPhaseCalled 'an inventory enumeration failure never reaches dispatch/Wait-Phase at all'

# --- Scenario F: an interrupted deployment leaves inProgress=true. Ordinary
#     maintenance retains its safety guard, while the mutex-owned Phase 0 path
#     still applies required fixes instead of making maintenance skippable. ---
function Get-VMNote {
    param($VMName)
    return [pscustomobject]@{
        vmName     = $VMName
        role       = 'DomainMember'
        domain     = 'example.test'
        inProgress = $true
    }
}
$script:StartVmFixesCalls = 0
$blockedResult = Start-VMMaintenance -VMName 'DISPATCH-A'
Assert-Equal $false $blockedResult 'ordinary maintenance still rejects an in-progress VM'
Assert-Equal 0 $script:StartVmFixesCalls 'ordinary maintenance does not run fixes on an in-progress VM'
$allowedResult = Start-VMMaintenance -VMName 'DISPATCH-A' -AllowInProgress
Assert-Equal $true $allowedResult 'the mutex-owned Phase 0 override maintains an interrupted VM'
Assert-Equal 1 $script:StartVmFixesCalls 'the Phase 0 override runs required fixes exactly once'

$phase0FunctionText = $definition[0].Extent.Text
Assert-Equal $true ($phase0FunctionText -match '(?i)-argument3\s+\$true') 'the mandatory Phase 0 dispatcher enables the in-progress override'
$scriptBlocksText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1') -Raw
Assert-Equal $true ($scriptBlocksText -match '(?s)\$global:Phase10Job\s*=\s*\{.*?\[boolean\]\s*\$AllowInProgress.*?Start-VMMaintenance.+?-AllowInProgress:\$AllowInProgress') 'Phase10Job forwards the override explicitly'
$phasesText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Phases.ps1') -Raw
Assert-Equal $true ($phasesText -match '(?s)\$hasArgumentList\s*=.+?\$argument3.+?if\s*\(\$hasArgumentList\).+?-ArgumentList\s+\$currentItem') 'Start-NormalJobs forwards a true third argument even when the first argument is empty'

if ($script:Failures -gt 0) { throw "$script:Failures Phase 0 maintenance dispatch-accounting assertion(s) failed." }
Write-Host 'ALL PHASE 0 MAINTENANCE DISPATCH-ACCOUNTING TESTS PASSED'
