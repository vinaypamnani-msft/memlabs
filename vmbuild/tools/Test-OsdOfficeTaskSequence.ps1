# Focused dual-engine tests for MAC-conditioned Office installation during OSD.
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Applications = @{}
$script:AutoInstallNames = @()
$script:Log = @()
$script:OfficeQuery = $null
$script:SleepCalls = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}
function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}
function Write-DscStatus { param($Message, [switch] $Failure, [switch] $Warning); $script:Log += "$Message" }
function New-CMTSStepConditionQueryWmi {
    [CmdletBinding()]
    param([string] $Namespace, [string] $Query)
    [pscustomobject]@{ Namespace = $Namespace; Query = $Query }
}
function New-CMTSStepConditionIfStatement {
    [CmdletBinding()]
    param([string] $StatementType, [object[]] $Condition)
    [pscustomobject]@{ OperatorType = $(if ($StatementType -eq 'Any') { 'or' } else { 'and' }); Operands = @($Condition) }
}
function Get-CMApplication {
    [CmdletBinding()]
    param([string] $Name, [switch] $Fast)
    return $script:Applications[$Name]
}
function Set-CMApplication {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $InputObject, [bool] $AutoInstall)
    process {
        $InputObject.AutoInstall = $AutoInstall
        $script:AutoInstallNames += $InputObject.Name
    }
}
function Get-CMTSStepInstallApplication {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $InputObject, [string] $StepName)
    process {
        $steps = @($InputObject.Steps | Where-Object Type -eq 'InstallApplication')
        if ($StepName) { $steps = @($steps | Where-Object Name -eq $StepName) }
        return $steps
    }
}
function Remove-CMTSStepInstallApplication {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $InputObject, [string] $StepName, [switch] $Force)
    process { $InputObject.Steps = @($InputObject.Steps | Where-Object Name -ne $StepName) }
}
function New-CMTSStepInstallApplication {
    [CmdletBinding()]
    param([string] $Name, $Application, $Condition, [int] $RetryCount)
    [pscustomobject]@{
        Name = $Name
        Type = 'InstallApplication'
        Application = $Application.Name
        RetryCount = $RetryCount
        Condition = [pscustomobject]@{ Operands = @($Condition) }
    }
}
function Add-CMTaskSequenceStep {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $InputObject, [object[]] $Step, [uint32] $InsertStepStartIndex)
    process {
        if ($InsertStepStartIndex -gt $InputObject.Steps.Count) { $InputObject.Steps = @($InputObject.Steps) + @($Step) }
        else { throw 'Test double only supports append semantics' }
    }
}
function Get-CMDeviceCollection {
    [CmdletBinding()]
    param([string] $Name)
    [pscustomobject]@{ Name = $Name; CollectionID = 'PS100123' }
}
function Get-CMDeviceCollectionDirectMembershipRule { [CmdletBinding()] param($CollectionId); return @() }
function Get-CMDeviceCollectionQueryMembershipRule { [CmdletBinding()] param($CollectionId); return @() }
function Add-CMDeviceCollectionQueryMembershipRule {
    [CmdletBinding()]
    param($CollectionId, [string] $QueryExpression, [string] $RuleName)
    $script:OfficeQuery = $QueryExpression
}
function Invoke-CMCollectionUpdate { [CmdletBinding()] param($CollectionId) }
function Set-CMCollection { [CmdletBinding()] param($CollectionId, $RefreshType) }
function Start-Sleep { [CmdletBinding()] param([int] $Seconds); $script:SleepCalls++ }
function New-TestSequence {
    [pscustomobject]@{
        Name = 'MEMLABS-w11-Install OS image'
        Steps = @(
            [pscustomobject]@{ Name = 'Setup Windows and Configuration Manager'; Type = 'SetupWindows' }
            [pscustomobject]@{ Name = 'MEMLABS install Office: Stale'; Type = 'InstallApplication'; Application = 'Old'; Condition = $null }
        )
    }
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction -Path $perfloadingPath -Name 'Sync-MemLabsOsdOfficeSteps')
. (Import-TestFunction -Path $perfloadingPath -Name 'Set-OfficeInstallTargetsCollection')
Write-Host "engine : $($PSVersionTable.PSVersion)"

$script:Applications['MEMLABS-Microsoft365Apps'] = [pscustomobject]@{ Name = 'MEMLABS-Microsoft365Apps'; AutoInstall = $false }
$clients = @(
    [pscustomobject]@{ vmName = 'OSD2'; role = 'OSDClient'; installOffice = 'Current'; osdMacAddress = '00:15:5d:00:04:da' }
    [pscustomobject]@{ vmName = 'OSD3'; role = 'OSDClient'; installOffice = $false; osdMacAddress = '00:15:5D:00:04:DB' }
)
$sequence = New-TestSequence
Assert-Equal $true (Sync-MemLabsOsdOfficeSteps -TaskSequences @($sequence) -OfficeTargetVMs $clients -StatusTag '[test]') 'single-channel Office reconcile succeeds'
Assert-Equal 1 @($sequence.Steps | Where-Object Name -like 'MEMLABS install Office:*').Count 'stale step is replaced by one configured channel step'
Assert-Equal 'MEMLABS install Office: Current' $sequence.Steps[-1].Name 'Office step is appended after Setup Windows'
Assert-Equal 'MEMLABS-Microsoft365Apps' $sequence.Steps[-1].Application 'single deployment channel uses base application name'
Assert-Equal 2 $sequence.Steps[-1].RetryCount 'Office step retains task-sequence reboot retry allowance'
Assert-Equal "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE MACAddress='00:15:5D:00:04:DA'" $sequence.Steps[-1].Condition.Operands[0].Query 'Office step is conditioned on enabled OSD2 MAC'
Assert-Equal $true $script:Applications['MEMLABS-Microsoft365Apps'].AutoInstall 'Office application permits task-sequence installation without deployment'

$script:Applications.Clear()
$script:Applications['MEMLABS-Microsoft365Apps-Current'] = [pscustomobject]@{ Name = 'MEMLABS-Microsoft365Apps-Current'; AutoInstall = $false }
$script:Applications['MEMLABS-Microsoft365Apps-MonthlyEnterprise'] = [pscustomobject]@{ Name = 'MEMLABS-Microsoft365Apps-MonthlyEnterprise'; AutoInstall = $false }
$clients = @(
    [pscustomobject]@{ vmName = 'OSD1'; role = 'OSDClient'; installOffice = 'Current'; osdMacAddress = '00:15:5D:00:04:D9' }
    [pscustomobject]@{ vmName = 'OSD2'; role = 'OSDClient'; installOffice = 'Current'; osdMacAddress = '00:15:5D:00:04:DA' }
    [pscustomobject]@{ vmName = 'OSD3'; role = 'OSDClient'; installOffice = 'MonthlyEnterprise'; osdMacAddress = '00:15:5D:00:04:DB' }
    [pscustomobject]@{ vmName = 'CLIENT1'; role = 'DomainMember'; installOffice = 'MonthlyEnterprise'; osdMacAddress = $null }
)
$sequence = New-TestSequence
Assert-Equal $true (Sync-MemLabsOsdOfficeSteps -TaskSequences @($sequence) -OfficeTargetVMs $clients -StatusTag '[test]') 'multi-channel Office reconcile succeeds'
$officeSteps = @($sequence.Steps | Where-Object Name -like 'MEMLABS install Office:*')
Assert-Equal 2 $officeSteps.Count 'one managed task-sequence step is authored per OSD Office channel'
$currentStep = @($officeSteps | Where-Object Name -eq 'MEMLABS install Office: Current')[0]
Assert-Equal 'or' $currentStep.Condition.Operands[0].OperatorType 'same-channel OSD clients use an Any/OR condition'
Assert-Equal 2 @($currentStep.Condition.Operands[0].Operands).Count 'Current channel condition carries both configured OSD MACs'
Assert-Equal 'MEMLABS-Microsoft365Apps-MonthlyEnterprise' (@($officeSteps | Where-Object Name -like '*MonthlyEnterprise')[0]).Application 'multiple deployment channels use suffixed application names'

$clients | ForEach-Object { if ($_.role -eq 'OSDClient') { $_.installOffice = $false } }
Assert-Equal $true (Sync-MemLabsOsdOfficeSteps -TaskSequences @($sequence) -OfficeTargetVMs $clients -StatusTag '[test]') 'disabled OSD Office reconcile succeeds'
Assert-Equal 0 @($sequence.Steps | Where-Object Name -like 'MEMLABS install Office:*').Count 'disabling Office removes all managed OSD Office steps'

$script:Applications.Clear()
$clients[0].installOffice = 'Current'
$sequence = New-TestSequence
Assert-Equal $true (Sync-MemLabsOsdOfficeSteps -TaskSequences @($sequence) -OfficeTargetVMs $clients -StatusTag '[test]') 'missing Office application is nonfatal for this Phase 8 pass'
Assert-Equal 0 @($sequence.Steps | Where-Object Name -like 'MEMLABS install Office:*').Count 'missing application cannot leave a stale task-sequence reference'
Assert-Equal $true (($script:Log -join "`n").Contains('no OSD task-sequence step was authored')) 'missing application is reported explicitly'

$script:OfficeQuery = $null
$script:SleepCalls = 0
$null = Set-OfficeInstallTargetsCollection -OfficeTargetVMs @(
    [pscustomobject]@{ vmName = 'OSD2'; role = 'OSDClient'; installOffice = 'Current' }
)
Assert-Equal 0 $script:SleepCalls 'OSD-only Office collection reconciliation does not wait for an impossible Client=1'
Assert-Equal $true ($script:OfficeQuery.Contains("Name = '__MEMLABS_NO_OFFICE_POLICY_TARGET__'")) 'OSD-only Office collection has no required-policy members'

$source = Get-Content -LiteralPath $perfloadingPath -Raw
Assert-Equal $true ($source.Contains('-AutoInstall $true')) 'Office applications are marked usable without a deployment'
Assert-Equal $true ($source.Contains("`$policyTargetVMs = @(`$OfficeTargetVMs | Where-Object { `$_.role -ne 'OSDClient' })")) 'required-policy collection excludes OSD clients owned by the task sequence'
Assert-Equal $true ($source.Contains("__MEMLABS_NO_OFFICE_POLICY_TARGET__")) 'OSD-only configuration uses a valid deliberate no-match collection query'
Assert-Equal $true ($source.Contains('not waiting for Client=1 before PXE')) 'Phase 8 reports why it skips the impossible OSD membership wait'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD Office task-sequence checks passed.'
