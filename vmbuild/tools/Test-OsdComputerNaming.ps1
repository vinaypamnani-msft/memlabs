<#
.SYNOPSIS
    Focused dual-engine tests for MAC-matched OSDComputerName authoring.
#>
[CmdletBinding()]
param ([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Log = @()

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Assert-ThrowsLike {
    param ([scriptblock] $Action, [string] $Pattern, [string] $What)
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    $passed = $message -like $Pattern
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected pattern: $Pattern`n      actual:           $message" }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)
    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}

function Get-OsdEffectiveNetwork { param($VM, $Config); return $(if ($VM.network) { $VM.network } else { $Config.vmOptions.network }) }
function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param ([string] $VMName)
    return @($script:Adapters[$VMName])
}
function Write-Log { param($Message, [switch]$LogOnly, [switch]$Failure); $script:Log += "$Message" }
function Write-DscStatus { param($Message, [switch]$Failure); $script:Log += "$Message" }

$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
. (Import-TestFunction $phasesPath 'Set-OsdClientMacAddresses')
$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction $perfloadingPath 'Sync-MemLabsOsdComputerNameSteps')

Write-Host "engine : $($PSVersionTable.PSVersion)"

$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ network = '192.168.1.0' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'OSD1'; role = 'OSDClient'; network = '192.168.3.0' }
        [pscustomobject]@{ vmName = 'OSD2'; role = 'OSDClient'; network = '192.168.4.0' }
        [pscustomobject]@{ vmName = 'CLIENT1'; role = 'DomainMember'; network = '192.168.1.0' }
    )
}
$script:Adapters = @{
    OSD1 = [pscustomobject]@{ SwitchName = '192.168.3.0'; MacAddress = '00155D0004CD' }
    OSD2 = [pscustomobject]@{ SwitchName = '192.168.4.0'; MacAddress = '00-15-5d-00-04-ce' }
}
Set-OsdClientMacAddresses -DeployConfig $config
Assert-Equal '00:15:5D:00:04:CD' $config.virtualMachines[0].osdMacAddress 'Phase 8 stamps colon-delimited OSD1 MAC'
Assert-Equal '00:15:5D:00:04:CE' $config.virtualMachines[1].osdMacAddress 'Phase 8 normalizes OSD2 MAC'
Assert-Equal $false ($config.virtualMachines[2].PSObject.Properties.Name -contains 'osdMacAddress') 'non-OSD VM is not stamped'

$duplicateConfig = [pscustomobject]@{
    vmOptions = $config.vmOptions
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'OSD1'; role = 'OSDClient'; network = '192.168.3.0' }
        [pscustomobject]@{ vmName = 'OSD2'; role = 'OSDClient'; network = '192.168.4.0' }
    )
}
$script:Adapters.OSD2 = [pscustomobject]@{ SwitchName = '192.168.4.0'; MacAddress = '00155D0004CD' }
Assert-ThrowsLike { Set-OsdClientMacAddresses -DeployConfig $duplicateConfig } '*same MAC*ambiguous*' 'duplicate OSD MAC fails before task-sequence authoring'
$script:Adapters.OSD2 = [pscustomobject]@{ SwitchName = '192.168.4.0'; MacAddress = '00155D0004CE' }

function Get-CMTSStepSetVariable {
    [CmdletBinding()]
    param ([Parameter(ValueFromPipeline = $true)] $InputObject)
    process { return @($InputObject.Steps) }
}
function Remove-CMTSStepSetVariable {
    [CmdletBinding()]
    param ([Parameter(ValueFromPipeline = $true)] $InputObject, [string] $StepName, [switch] $Force)
    process { $InputObject.Steps = @($InputObject.Steps | Where-Object { $_.Name -ne $StepName }) }
}
function New-CMTSStepConditionVariable {
    [CmdletBinding()]
    param ([string] $ConditionVariableName, [string] $ConditionVariableValue, [string] $OperatorType)
    return [pscustomobject]@{ Variable = $ConditionVariableName; Value = $ConditionVariableValue; Operator = $OperatorType }
}
function New-CMTSStepSetVariable {
    [CmdletBinding()]
    param ([string] $Name, [string] $TaskSequenceVariable, [string] $TaskSequenceVariableValue, $Condition)
    return [pscustomobject]@{
        Name          = $Name
        VariableName  = $TaskSequenceVariable
        VariableValue = $TaskSequenceVariableValue
        Condition     = $Condition
    }
}
function Add-CMTaskSequenceStep {
    [CmdletBinding()]
    param ([Parameter(ValueFromPipeline = $true)] $InputObject, [object[]] $Step, [int] $InsertStepStartIndex)
    process { $InputObject.Steps = @($Step) + @($InputObject.Steps) }
}

$unmanaged = [pscustomobject]@{ Name = 'Keep me'; VariableName = 'Other'; VariableValue = 'value'; Condition = $null }
$stale = [pscustomobject]@{ Name = 'MEMLABS set OSDComputerName: OLD'; VariableName = 'OSDComputerName'; VariableValue = 'OLD'; Condition = $null }
$taskSequences = @(
    [pscustomobject]@{ Name = 'MEMLABS-w11-Install OS image'; Steps = @($unmanaged, $stale) }
    [pscustomobject]@{ Name = 'MEMLABS-Custom TS Example'; Steps = @() }
)
$osdClients = @($config.virtualMachines | Where-Object role -eq 'OSDClient')
Assert-Equal $true (Sync-MemLabsOsdComputerNameSteps -TaskSequences $taskSequences -OsdClients $osdClients -StatusTag '[test]') 'task-sequence naming reconciliation succeeds'
foreach ($taskSequence in $taskSequences) {
    $managed = @($taskSequence.Steps | Where-Object { $_.Name -like 'MEMLABS set OSDComputerName: *' })
    Assert-Equal 2 $managed.Count "$($taskSequence.Name) gets one naming step per OSD VM"
    Assert-Equal '*00:15:5D:00:04:CD*' (($managed | Where-Object VariableValue -eq 'OSD1').Condition.Value) "$($taskSequence.Name) matches OSD1 MAC with PathMatchSpec wildcard"
    Assert-Equal '*00:15:5D:00:04:CE*' (($managed | Where-Object VariableValue -eq 'OSD2').Condition.Value) "$($taskSequence.Name) matches OSD2 MAC with PathMatchSpec wildcard"
}
Assert-Equal 1 @($taskSequences[0].Steps | Where-Object Name -eq 'Keep me').Count 'reconciliation preserves unmanaged steps'

$config.virtualMachines[0].osdMacAddress = '00:15:5D:AA:BB:CC'
Assert-Equal $true (Sync-MemLabsOsdComputerNameSteps -TaskSequences $taskSequences -OsdClients $osdClients -StatusTag '[test]') 'rerun replaces stale MAC conditions'
$osd1Steps = @($taskSequences[0].Steps | Where-Object VariableValue -eq 'OSD1')
Assert-Equal 1 $osd1Steps.Count 'rerun does not duplicate the OSD1 naming step'
Assert-Equal '*00:15:5D:AA:BB:CC*' $osd1Steps[0].Condition.Value 'rerun writes the replacement OSD1 MAC condition'

$badClients = @([pscustomobject]@{ vmName = 'THIS-NAME-IS-WAY-TOO-LONG'; osdMacAddress = '00:15:5D:00:04:CD' })
Assert-Equal $false (Sync-MemLabsOsdComputerNameSteps -TaskSequences $taskSequences -OsdClients $badClients -StatusTag '[test]') 'invalid Windows computer name fails reconciliation'

$phasesSource = Get-Content $phasesPath -Raw
Assert-Equal $true ($phasesSource.Contains('$null = Set-OsdClientMacAddresses -DeployConfig $deployConfig')) 'Phase 8 invokes MAC capture before dispatch'
$perfloadingSource = Get-Content $perfloadingPath -Raw
Assert-Equal $true ($perfloadingSource.Contains('-InsertStepStartIndex 0')) 'naming steps are inserted before generated OS actions'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD computer naming checks passed.'
