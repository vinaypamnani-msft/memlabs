<#
.SYNOPSIS
    Focused tests for OSD BitLocker and post-PXE policy signals.
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

function Write-DscStatus { param($Message, [switch]$Failure); $script:Log += "$Message" }
function New-CMTSStepConditionQueryWmi {
    [CmdletBinding()]
    param([string[]]$Namespace, [string]$Query)
    [pscustomobject]@{ Namespace = "$Namespace"; Query = $Query }
}
function New-CMTSStepConditionIfStatement {
    [CmdletBinding()]
    param([string]$StatementType, [object[]]$Condition)
    [pscustomobject]@{ OperatorType = $(if ($StatementType -eq 'Any') { 'or' } else { 'and' }); Operands = @($Condition) }
}
function New-CMTSStepConditionVariable {
    [CmdletBinding()]
    param([string]$OperatorType, [string]$ConditionVariableName, [string]$ConditionVariableValue)
    [pscustomobject]@{ Operator = $OperatorType; Variable = $ConditionVariableName; Value = $ConditionVariableValue }
}
function Get-CMTSStepOfflineEnableBitLocker {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName)
    process { @($InputObject.Steps | Where-Object { $_.Type -eq 'OfflineBitLocker' -and $_.Name -eq $StepName }) }
}
function Get-CMTSStepEnableBitLocker {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName)
    process { @($InputObject.Steps | Where-Object { $_.Type -eq 'EnableBitLocker' -and $_.Name -eq $StepName }) }
}
function Set-TestBitLockerStep {
    param($InputObject, [string]$StepName, [switch]$ClearCondition, $AddCondition)
    $step = $InputObject.Steps | Where-Object Name -eq $StepName | Select-Object -First 1
    if ($ClearCondition) { $step.Condition = $null }
    if ($AddCondition) { $step.Condition = [pscustomobject]@{ Operands = @($AddCondition) } }
}
function Set-CMTSStepOfflineEnableBitLocker {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName, [switch]$ClearCondition, $AddCondition)
    process { Set-TestBitLockerStep -InputObject $InputObject -StepName $StepName -ClearCondition:$ClearCondition -AddCondition $AddCondition }
}
function Set-CMTSStepEnableBitLocker {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName, [switch]$ClearCondition, $AddCondition)
    process { Set-TestBitLockerStep -InputObject $InputObject -StepName $StepName -ClearCondition:$ClearCondition -AddCondition $AddCondition }
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction $perfloadingPath 'Sync-MemLabsOsdBitLockerSteps')
Write-Host "engine : $($PSVersionTable.PSVersion)"

$newSequence = {
    [pscustomobject]@{ Name = 'MEMLABS-w11-Install OS image'; Steps = @(
            [pscustomobject]@{ Name = 'Pre-provision BitLocker'; Type = 'OfflineBitLocker'; Condition = $null }
            [pscustomobject]@{ Name = 'Enable BitLocker'; Type = 'EnableBitLocker'; Condition = $null }
        ) }
}
$clients = @(
    [pscustomobject]@{ vmName = 'OSD1'; osdMacAddress = '00:15:5D:00:04:D9'; BitLocker = $true }
    [pscustomobject]@{ vmName = 'OSD2'; osdMacAddress = '00:15:5D:00:04:DA'; BitLocker = $false }
)
$sequence = & $newSequence
Assert-Equal $true (Sync-MemLabsOsdBitLockerSteps -TaskSequences @($sequence) -OsdClients $clients -StatusTag '[test]') 'one-client BitLocker reconcile succeeds'
Assert-Equal "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE MACAddress='00:15:5D:00:04:D9'" $sequence.Steps[0].Condition.Operands[0].Query 'Pre-provision BitLocker matches only enabled OSD1'
Assert-Equal 'and' $sequence.Steps[1].Condition.Operands[0].OperatorType 'Enable BitLocker combines native and managed conditions'
Assert-Equal '_SMSTSWTG' $sequence.Steps[1].Condition.Operands[0].Operands[0].Variable 'Enable BitLocker preserves native Windows To Go guard'
Assert-Equal "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE MACAddress='00:15:5D:00:04:D9'" $sequence.Steps[1].Condition.Operands[0].Operands[1].Query 'Enable BitLocker matches only enabled OSD1'

$clients[1].BitLocker = $true
$sequence = & $newSequence
Assert-Equal $true (Sync-MemLabsOsdBitLockerSteps -TaskSequences @($sequence) -OsdClients $clients -StatusTag '[test]') 'multi-client BitLocker reconcile succeeds'
Assert-Equal 'or' $sequence.Steps[0].Condition.Operands[0].OperatorType 'Pre-provision BitLocker uses Any/OR for multiple enabled clients'
Assert-Equal 2 @($sequence.Steps[0].Condition.Operands[0].Operands).Count 'Pre-provision BitLocker carries both enabled MAC conditions'
Assert-Equal 'or' $sequence.Steps[1].Condition.Operands[0].Operands[1].OperatorType 'Enable BitLocker uses Any/OR inside native guard'
Assert-Equal 2 @($sequence.Steps[1].Condition.Operands[0].Operands[1].Operands).Count 'Enable BitLocker carries both enabled MAC conditions'

$clients | ForEach-Object { $_.BitLocker = $false }
$sequence = & $newSequence
Assert-Equal $true (Sync-MemLabsOsdBitLockerSteps -TaskSequences @($sequence) -OsdClients $clients -StatusTag '[test]') 'disabled BitLocker reconcile succeeds'
Assert-Equal $true ($sequence.Steps[0].Condition.Operands[0].Query -like "*MEMLABS-BITLOCKER-DISABLED*") 'Pre-provision BitLocker receives deliberate no-match condition'
Assert-Equal $true ($sequence.Steps[1].Condition.Operands[0].Operands[1].Query -like "*MEMLABS-BITLOCKER-DISABLED*") 'Enable BitLocker receives deliberate no-match condition'

$configSource = Get-Content (Join-Path $RootPath 'common\Common.Config.ps1') -Raw
$addVmSource = Get-Content (Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1') -Raw
$validationSource = Get-Content (Join-Path $RootPath 'common\Common.Validation.ps1') -Raw
Assert-Equal $true ($configSource.Contains('$vm.role -eq ''OSDClient'' -or')) 'normalization treats OSDClient as client OS for BitLocker'
Assert-Equal $true ($configSource.Contains('or $vm.role -eq ''OSDClient''')) 'normalization preserves installOffice on OSDClient'
Assert-Equal $true ($configSource.Contains("$" + "vm.PsObject.Members.Remove('useProxy')")) 'normalization removes dead OSD proxy signal'
Assert-Equal $true ($addVmSource.Contains('-Name ''installOffice'' -Value $false')) 'new OSDClient exposes existing installOffice signal defaulted off'
Assert-Equal $true ($validationSource.Contains('$_.role -ne ''OSDClient'' -and $_.pushClient -eq $false')) 'Office validation recognizes task-sequence-installed CM client'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD post-PXE policy checks passed.'