<#
.SYNOPSIS
    Verifies perfloading waits for SMS Provider recovery and fails closed.

.DESCRIPTION
    Extracts the production helpers and executes recovery, exhaustion, and
    consecutive-success scenarios. Run under PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ })
    if ($parseErrors.Count -ne 0) { throw "$Path has $($parseErrors.Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

$workflowPath = Join-Path $RootPath 'DSC\phases\ScriptWorkFlow.ps1'
$scriptFunctionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
. (Import-TestFunction -Path $workflowPath -Name 'Wait-PerfloadingSmsProviderReady')
. (Import-TestFunction -Path $workflowPath -Name 'Invoke-PerfloadingWithProviderRecovery')

$script:Statuses = New-Object System.Collections.Generic.List[object]
$script:ProbeOutcomes = @()
$script:GroupProbeOutcomes = @()
$script:ProbeIndex = 0
$script:SleepCount = 0
$script:PerfOutcomes = @()
$script:PerfIndex = 0
$script:RecoveryResult = $true
$script:RecoveryCalls = 0
$script:EmitBeforeThrow = $false

function Write-DscStatus {
    param ([Parameter(Position = 0)][string] $Message, [switch] $Warning, [switch] $Failure)

    $script:Statuses.Add([pscustomobject]@{ Message = $Message; Warning = [bool]$Warning; Failure = [bool]$Failure })
}
function Start-Sleep {
    param ([int] $Seconds)

    $script:SleepCount++
}
function Get-CimInstance {
    param ([string] $Namespace, [string] $ClassName, [int] $OperationTimeoutSec, $ErrorAction)

    if ($ClassName -eq 'SMS_Site') {
        $outcome = $script:ProbeOutcomes[$script:ProbeIndex]
        $script:ProbeIndex++
        if (-not $outcome) { throw 'WBEM_E_CRITICAL_ERROR' }
        return [pscustomobject]@{ SiteCode = 'ABC' }
    }
    if ($ClassName -eq 'SMS_DistributionPointGroup') {
        $outcome = $script:GroupProbeOutcomes[$script:ProbeIndex - 1]
        if (-not $outcome) { throw 'SMS_DistributionPointGroup WBEM_E_CRITICAL_ERROR' }
        return @()
    }
    throw "Unexpected class $ClassName"
}
function Invoke-DotSource {
    param ([string] $Script, [object[]] $Arguments, [switch] $Rethrow)

    $outcome = $script:PerfOutcomes[$script:PerfIndex]
    $script:PerfIndex++
    if (-not $outcome) {
        if ($script:EmitBeforeThrow) { Write-Output ([pscustomobject]@{ Partial = $true }) }
        throw 'perfloading provider failure'
    }
}
function Wait-PerfloadingSmsProviderReady {
    param ([string] $SiteCode)

    $script:RecoveryCalls++
    return $script:RecoveryResult
}

Write-Host "engine : $($PSVersionTable.PSVersion)"

# Re-import the real wait helper after defining its dependencies.
. (Import-TestFunction -Path $workflowPath -Name 'Wait-PerfloadingSmsProviderReady')
$script:ProbeOutcomes = @($false, $true, $true)
$script:GroupProbeOutcomes = @($true, $true, $true)
$recovered = Wait-PerfloadingSmsProviderReady -SiteCode ABC -MaxAttempts 3 -PollSeconds 0
Assert-Equal $true $recovered 'provider recovery requires and accepts two consecutive healthy samples'
Assert-Equal 3 $script:ProbeIndex 'provider recovery rejects the failed first sample'
Assert-Equal 2 $script:SleepCount 'provider recovery polls between samples'

$script:Statuses.Clear()
$script:ProbeOutcomes = @($true, $true, $true)
$script:GroupProbeOutcomes = @($false, $true, $true)
$script:ProbeIndex = 0
$script:SleepCount = 0
$recovered = Wait-PerfloadingSmsProviderReady -SiteCode ABC -MaxAttempts 3 -PollSeconds 0
Assert-Equal $true $recovered 'provider recovery resets when the second representative query fails'
Assert-Equal 3 $script:ProbeIndex 'both representative queries must survive consecutive samples'

$script:Statuses.Clear()
$script:ProbeOutcomes = @($false, $false, $false)
$script:GroupProbeOutcomes = @($true, $true, $true)
$script:ProbeIndex = 0
$script:SleepCount = 0
$recovered = Wait-PerfloadingSmsProviderReady -SiteCode ABC -MaxAttempts 3 -PollSeconds 0
Assert-Equal $false $recovered 'provider recovery is bounded'
Assert-Equal 1 @($script:Statuses | Where-Object Warning).Count 'provider recovery exhaustion records a warning'

# Restore the controlled wait stub and execute the production retry helper.
function Wait-PerfloadingSmsProviderReady {
    param ([string] $SiteCode)

    $script:RecoveryCalls++
    return $script:RecoveryResult
}
$script:Statuses.Clear()
$script:PerfOutcomes = @($false, $true)
$script:PerfIndex = 0
$script:RecoveryCalls = 0
$completed = Invoke-PerfloadingWithProviderRecovery -ScriptFile perfloading.ps1 -ConfigFilePath config.json -LogPath C:\logs -SiteCode ABC
Assert-Equal $true $completed 'perfloading retries after provider recovery'
Assert-Equal 2 $script:PerfIndex 'perfloading reruns after the first failure'
Assert-Equal 1 $script:RecoveryCalls 'perfloading waits for provider recovery before retrying'

$script:Statuses.Clear()
$script:PerfOutcomes = @($false, $true)
$script:PerfIndex = 0
$script:RecoveryCalls = 0
$script:RecoveryResult = $false
$completed = Invoke-PerfloadingWithProviderRecovery -ScriptFile perfloading.ps1 -ConfigFilePath config.json -LogPath C:\logs -SiteCode ABC
Assert-Equal $false $completed 'failed provider recovery prevents another perfloading attempt'
Assert-Equal 1 $script:PerfIndex 'perfloading does not run while the provider remains unhealthy'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'failed provider recovery records one phase failure'

$script:Statuses.Clear()
$script:PerfOutcomes = @($false, $false, $false)
$script:PerfIndex = 0
$script:RecoveryCalls = 0
$script:RecoveryResult = $true
$completed = Invoke-PerfloadingWithProviderRecovery -ScriptFile perfloading.ps1 -ConfigFilePath config.json -LogPath C:\logs -SiteCode ABC
Assert-Equal $false $completed 'perfloading fails after all attempts are exhausted'
Assert-Equal 3 $script:PerfIndex 'perfloading uses the bounded attempt count'
Assert-Equal 2 $script:RecoveryCalls 'perfloading waits only between attempts'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'retry exhaustion records one phase failure'
Assert-Equal 0 @($script:Statuses | Where-Object { $_.Message -match 'continuing' }).Count 'retry exhaustion never claims the workflow can continue'

$script:Statuses.Clear()
$script:PerfOutcomes = @($false, $false, $false)
$script:PerfIndex = 0
$script:RecoveryCalls = 0
$script:EmitBeforeThrow = $true
$completed = Invoke-PerfloadingWithProviderRecovery -ScriptFile perfloading.ps1 -ConfigFilePath config.json -LogPath C:\logs -SiteCode ABC
Assert-Equal $true ($completed -is [bool] -and -not $completed) 'partial script output cannot make retry exhaustion truthy'
$script:EmitBeforeThrow = $false

# Exercise Invoke-DotSource's real preflight contract with -Rethrow.
. (Import-TestFunction -Path $scriptFunctionsPath -Name 'Invoke-DotSource')
$missingThrew = $false
try { Invoke-DotSource -Script (Join-Path $env:TEMP 'memlabs-definitely-missing.ps1') -Rethrow } catch { $missingThrew = $true }
Assert-Equal $true $missingThrew 'Invoke-DotSource rethrows a missing script when requested'
$malformedPath = Join-Path $env:TEMP ("memlabs-malformed-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($malformedPath, 'function Broken {', [Text.Encoding]::ASCII)
    $parseThrew = $false
    try { Invoke-DotSource -Script $malformedPath -Rethrow } catch { $parseThrew = $true }
    Assert-Equal $true $parseThrew 'Invoke-DotSource rethrows a parse failure when requested'
}
finally {
    Remove-Item -LiteralPath $malformedPath -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All perfloading provider recovery checks passed.'