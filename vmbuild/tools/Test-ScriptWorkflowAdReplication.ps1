#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'DSC\phases\ScriptWorkFlow.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }

$statements = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq '$firstRun' -and
        $_.Extent.Text -match '\bGet-ADDomainController\b'
    })
if ($statements.Count -ne 1) {
    throw "Expected one first-run AD replication block, found $($statements.Count)."
}
$replicationBlock = [scriptblock]::Create(
    "param([bool]`$firstRun)`n" + $statements[0].Extent.Text + "`nreturn 'WorkflowContinued'")

function Get-ADDomainController {
    param([string]$Filter, [System.Management.Automation.ActionPreference]$ErrorAction = 'Continue')
    $script:DiscoveryCalls++
    if ($script:Scenario -eq 'DiscoveryThrows') { throw 'A local error has occurred' }
    if ($script:Scenario -eq 'DiscoveryError') {
        Write-Error 'A local error has occurred' -ErrorAction $ErrorAction
        return
    }
    foreach ($name in $script:ControllerNames) { [pscustomobject]@{ Name = $name } }
}
function Get-ADDomain {
    param([System.Management.Automation.ActionPreference]$ErrorAction = 'Continue')
    $script:DomainCalls++
    if ($script:Scenario -eq 'DomainThrows') { throw 'Domain discovery failed' }
    if ($script:Scenario -eq 'DomainError') {
        Write-Error 'Domain discovery failed' -ErrorAction $ErrorAction
        return
    }
    [pscustomobject]@{ DistinguishedName = 'DC=contoso,DC=com' }
}
function Start-Job {
    [CmdletBinding()]
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList)
    $script:JobsStarted++
    if ($script:Scenario -eq 'JobThrows') { throw 'Replication job could not start' }
    $script:JobArguments = $ArgumentList
    [pscustomobject]@{ State = $script:JobState }
}
function Wait-Job {
    param($Job, [int]$Timeout)
    $script:WaitTimeout = $Timeout
    $Job
}
function Stop-Job {
    [CmdletBinding()]
    param($Job)
    $script:JobsStopped++
}
function Remove-Job {
    [CmdletBinding()]
    param($Job, [switch]$Force)
    $script:JobsRemoved++
}
function Start-Sleep {
    param([int]$Seconds)
    $script:SleepSeconds += $Seconds
}
function Write-DscStatus {
    param($Status, [switch]$Warning, [switch]$NoStatus)
    $script:Statuses.Add([pscustomobject]@{
            Text = "$Status"
            Warning = [bool]$Warning
            NoStatus = [bool]$NoStatus
        })
}

function Invoke-ReplicationCase {
    param(
        [string]$Scenario = 'Success',
        [string[]]$Controllers = @('DC1', 'BDC1'),
        [bool]$FirstRun = $true,
        [string]$JobState = 'Completed'
    )
    $script:Scenario = $Scenario
    $script:ControllerNames = $Controllers
    $script:JobState = $JobState
    $script:DiscoveryCalls = 0
    $script:DomainCalls = 0
    $script:JobsStarted = 0
    $script:JobsStopped = 0
    $script:JobsRemoved = 0
    $script:JobArguments = @()
    $script:WaitTimeout = 0
    $script:SleepSeconds = 0
    $script:Statuses = [System.Collections.Generic.List[object]]::new()

    $ErrorActionPreference = if ($Scenario -like '*Error') { 'Continue' } else { 'Stop' }
    $result = & $replicationBlock -firstRun $FirstRun
    if ($result -ne 'WorkflowContinued') { throw "$Scenario did not continue the workflow." }
}

foreach ($scenario in @('DiscoveryThrows', 'DiscoveryError', 'DomainThrows', 'DomainError')) {
    Invoke-ReplicationCase -Scenario $scenario
    if ($script:JobsStarted -ne 0 -or $script:JobsRemoved -ne 0 -or $script:SleepSeconds -ne 0) {
        throw "$scenario attempted replication after failed directory discovery."
    }
    if ($script:Statuses.Count -ne 1 -or -not $script:Statuses[0].Warning -or
        -not $script:Statuses[0].NoStatus -or
        $script:Statuses[0].Text -notmatch 'Skipping optional first-run AD replication') {
        throw "$scenario did not publish a non-fatal directory discovery warning."
    }
    $expectedError = if ($scenario -like 'Discovery*') { 'A local error has occurred' } else { 'Domain discovery failed' }
    if (-not $script:Statuses[0].Text.Contains($expectedError)) {
        throw "$scenario lost the directory discovery error."
    }
}

Invoke-ReplicationCase -FirstRun $false
if ($script:DiscoveryCalls -ne 0 -or $script:DomainCalls -ne 0 -or $script:JobsStarted -ne 0) {
    throw 'A resumed workflow attempted first-run replication.'
}
foreach ($controllers in @(@(), @('DC1'))) {
    Invoke-ReplicationCase -Controllers $controllers
    if ($script:DiscoveryCalls -ne 1 -or $script:DomainCalls -ne 0 -or
        $script:JobsStarted -ne 0 -or $script:Statuses.Count -ne 0) {
        throw 'Zero or one domain controller should not trigger replication.'
    }
}

Invoke-ReplicationCase
if ($script:DiscoveryCalls -ne 1 -or $script:DomainCalls -ne 1 -or
    $script:JobsStarted -ne 1 -or $script:JobsRemoved -ne 1 -or
    $script:JobsStopped -ne 0 -or $script:WaitTimeout -ne 60 -or $script:SleepSeconds -ne 3) {
    throw 'Successful multi-DC replication changed its execution or timeout contract.'
}
if (($script:JobArguments[0] -join ',') -ne 'DC1,BDC1' -or
    $script:JobArguments[1] -ne 'DC=contoso,DC=com') {
    throw 'Replication did not receive all controller names and the domain distinguished name.'
}

Invoke-ReplicationCase -JobState 'Running'
if ($script:JobsStopped -ne 1 -or $script:JobsRemoved -ne 1 -or $script:WaitTimeout -ne 60) {
    throw 'A timed-out replication job was not stopped and removed.'
}

$jobFailurePropagated = $false
try { Invoke-ReplicationCase -Scenario 'JobThrows' }
catch { $jobFailurePropagated = $_.Exception.Message -eq 'Replication job could not start' }
if (-not $jobFailurePropagated) {
    throw 'The optional directory discovery catch swallowed a failure outside its scope.'
}

Write-Host 'PASS -- optional AD discovery warns without aborting; first-run replication and timeout behavior are preserved.'
