#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'common\Common.Phases.ps1'

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has $($errors.Count) parse error(s): $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Path; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-TestFunction -Path $sourcePath -Name 'Get-JobStreamSource')
. (Import-TestFunction -Path $sourcePath -Name 'Test-JobTransportCloseFalseFailure')

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

function New-TestOutput {
    param([int]$LogLevel, [string]$Text)

    [pscustomobject]@{
        LogLevel = $LogLevel
        Text     = $Text
    }
}

function New-TestJob {
    param(
        [object[]]$Output,
        [string]$ReasonMessage = 'The client did not receive a response for a Close operation in the specified time interval.',
        [string]$State = 'Failed'
    )

    $reason = [pscustomobject]@{ Message = $ReasonMessage }
    $streamSource = [pscustomobject]@{
        JobStateInfo = [pscustomobject]@{ Reason = $reason }
        Output       = @($Output)
    }
    [pscustomobject]@{
        State        = $State
        ChildJobs    = @($streamSource)
        JobStateInfo = [pscustomobject]@{ Reason = $reason }
    }
}

$phase8Success = New-TestJob -Output @(
    (New-TestOutput -LogLevel 2 -Text 'CMLog capture timed out; continuing.')
    (New-TestOutput -LogLevel 1 -Text '[Phase 8]: PT5-PS1SITE  [Primary] : Completed in 01:58:44')
)
Assert-Equal $true (Test-JobTransportCloseFalseFailure -Job $phase8Success) 'Phase 8 terminal completion survives transport-close teardown failure'

$phase1Success = New-TestJob -Output @(
    (New-TestOutput -LogLevel 1 -Text '[Phase 1]: LAB-VM: VM Creation completed successfully for DomainMember.')
)
Assert-Equal $true (Test-JobTransportCloseFalseFailure -Job $phase1Success) 'existing VM-create terminal completion remains recognized'

$noSentinel = New-TestJob -Output @(
    (New-TestOutput -LogLevel 2 -Text 'Work was still in progress.')
)
Assert-Equal $false (Test-JobTransportCloseFalseFailure -Job $noSentinel) 'transport close without terminal completion remains a failure'

$realFailure = New-TestJob -Output @(
    (New-TestOutput -LogLevel 3 -Text 'Configuration failed.')
    (New-TestOutput -LogLevel 1 -Text '[Phase 8]: LAB-PRI [Primary] : Completed in 01:58:44')
)
Assert-Equal $false (Test-JobTransportCloseFalseFailure -Job $realFailure) 'failure-level output overrides a terminal completion line'

$wrongReason = New-TestJob -ReasonMessage 'The configuration script threw an exception.' -Output @(
    (New-TestOutput -LogLevel 1 -Text '[Phase 8]: LAB-PRI [Primary] : Completed in 01:58:44')
)
Assert-Equal $false (Test-JobTransportCloseFalseFailure -Job $wrongReason) 'non-transport job failure is never reclassified'

$completedState = New-TestJob -State 'Completed' -Output @(
    (New-TestOutput -LogLevel 1 -Text '[Phase 8]: LAB-PRI [Primary] : Completed in 01:58:44')
)
Assert-Equal $false (Test-JobTransportCloseFalseFailure -Job $completedState) 'classifier only applies to failed jobs'

if ($script:Failures -gt 0) {
    throw "$script:Failures transport-close classifier test(s) failed."
}

Write-Host 'ALL TRANSPORT-CLOSE FALSE-FAILURE TESTS PASSED'
