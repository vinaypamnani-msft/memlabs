#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'AST-extracted production menu and worker scriptblocks consume fixture variables dynamically.')]
<#
.SYNOPSIS
    Verifies RAM-only existing VM edits apply immediately and never enter deployment.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath $Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse error(s): $($errors -join '; ')".Trim() }
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
    if (-not $definition) { throw "Missing $Name in $Path." }
    return [scriptblock]::Create($definition.Extent.Text)
}

foreach ($entry in @(
        @{ Path = 'common\Common.GenConfig.Validation.ps1'; Name = 'get-IsExistingVMModified' },
        @{ Path = 'common\Common.GenConfig.Validation.ps1'; Name = 'Get-AdditionalValidations' },
        @{ Path = 'genconfig.ps1'; Name = 'Get-ExistingVmQuickUpdatePlan' },
        @{ Path = 'genconfig.ps1'; Name = 'Invoke-ExistingVmQuickUpdates' },
        @{ Path = 'common\Common.HyperV.ps1'; Name = 'Set-MemLabsVmMemoryRestartPending' },
        @{ Path = 'common\Common.HyperV.ps1'; Name = 'Set-MemLabsVmMemoryConfiguration' },
        @{ Path = 'common\Common.HyperV.ps1'; Name = 'Restore-DynamicMemory' }
    )) {
    . (Import-TestFunction -Path $entry.Path -Name $entry.Name)
}

function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [switch]$Activity, [switch]$SubActivity, [switch]$LogOnly, [switch]$Failure, [switch]$Success, [switch]$Warning)
}
function Write-GreenCheck { param([string]$Message) }
function Write-OrangePoint { param([string]$Message) }
function Write-RedX { param([string]$Message) $script:VisibleErrors += $Message }
function Add-ErrorMessage {
    param([string]$Message, [string]$Property, [switch]$Warning)
    if (-not $Warning) { throw "Unexpected GenConfig error for $Property`: $Message" }
    $script:MemoryEditWarnings += $Message
}

$script:HyperV = @{
    Dynamic = $false; Minimum = 4GB; Maximum = 4GB; Startup = 4GB; State = 'Running'
}
$script:Calls = [Collections.Generic.List[object]]::new()
$script:NoteUpdates = [Collections.Generic.List[object]]::new()
$script:VisibleErrors = @()
$script:VmNote = [pscustomobject]@{ memory = '4GB'; dynamicMinRam = '4GB'; memoryRestartPending = $false; lastUpdate = 'fixture' }
$script:FailMemorySet = $false
$script:FailStart = $false
$script:FailFinalNote = $false
function Get-VMNote {
    param([string]$VMName)
    $script:VmNote | ConvertTo-Json -Depth 5 | ConvertFrom-Json
}
function Set-VMNote {
    param([string]$VmName, $VmNote)
    if ($script:FailFinalNote -and $VmNote.memory -eq $script:VmNoteTargetMemory -and
        $VmNote.dynamicMinRam -eq $script:VmNoteTargetDynamicMin) {
        throw 'Synthetic final VM-note write failure.'
    }
    foreach ($property in $VmNote.PSObject.Properties) {
        $script:VmNote | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
    }
}
function Get-VM2 {
    param([string]$Name, [switch]$Fallback)
    [pscustomobject]@{
        Name = $Name; State = $script:HyperV.State; DynamicMemoryEnabled = $script:HyperV.Dynamic
        MemoryMinimum = $script:HyperV.Minimum; MemoryMaximum = $script:HyperV.Maximum
        MemoryStartup = $script:HyperV.Startup
    }
}
function Stop-VM2 {
    param([string]$Name, [switch]$Passthru)
    $script:Calls.Add([pscustomobject]@{ Action = 'Stop'; Name = $Name })
    $script:HyperV.State = 'Off'
    if ($Passthru) { $true }
}
function Start-VM2 {
    param([string]$Name, [switch]$Passthru)
    $script:Calls.Add([pscustomobject]@{ Action = 'Start'; Name = $Name })
    if ($script:FailStart) {
        if ($Passthru) { return $false }
        throw 'Synthetic start failure.'
    }
    $script:HyperV.State = 'Running'
    if ($Passthru) { $true }
}
function Set-VMMemory {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]$VM,
        [bool]$DynamicMemoryEnabled,
        [long]$MinimumBytes,
        [long]$MaximumBytes,
        [long]$StartupBytes,
        [int]$Priority,
        [int]$Buffer
    )
    process {
        if ($script:FailMemorySet) { throw 'Synthetic Set-VMMemory failure.' }
        $script:Calls.Add([pscustomobject]@{
                Action = 'Memory'; Name = $VM.Name; Dynamic = $DynamicMemoryEnabled
                Minimum = $MinimumBytes; Maximum = $MaximumBytes; Startup = $StartupBytes
                Priority = $Priority; Buffer = $Buffer
            })
        $script:HyperV.Dynamic = $DynamicMemoryEnabled
        $script:HyperV.Startup = $StartupBytes
        if ($DynamicMemoryEnabled) {
            $script:HyperV.Minimum = $MinimumBytes
            $script:HyperV.Maximum = $MaximumBytes
        }
    }
}
function New-ExistingMemoryVm {
    param(
        [string]$Name = 'LAB-W11',
        [string]$Memory = '6GB',
        [string]$DynamicMinRam = '6GB',
        [string]$OriginalMemory = '4GB',
        [string]$OriginalMinimum = '4GB',
        [string]$Role = 'DomainMember'
    )
    [pscustomobject]@{
        vmName = $Name; ExistingVM = $true; role = $Role; sqlVersion = $null
        memory = $Memory; dynamicMinRam = $DynamicMinRam
        'memory-Original' = $OriginalMemory; 'dynamicMinRam-Original' = $OriginalMinimum
    }
}

$vm = New-ExistingMemoryVm
$config = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'lab.test' }; virtualMachines = @() }
$configBaseline = $config | ConvertTo-Json -Depth 10 -Compress
$global:GenConfigQuickApplyBaselineJson = $configBaseline
$plan = Get-ExistingVmQuickUpdatePlan -Config $config -ExistingMachines @($vm) -ConfigBaselineJson $configBaseline
Assert-True ($plan.CanApplyQuickly -and $plan.VMs.Count -eq 1) 'A RAM-only existing VM edit was not eligible for the quick path.'

$unsupported = $vm.PSObject.Copy()
$unsupported | Add-Member -NotePropertyName 'installOffice-Original' -NotePropertyValue $false -Force
$unsupported | Add-Member -NotePropertyName installOffice -NotePropertyValue $true -Force
Assert-True (-not (Get-ExistingVmQuickUpdatePlan -Config $config -ExistingMachines @($unsupported) -ConfigBaselineJson $configBaseline).CanApplyQuickly) 'A non-memory edit was incorrectly routed around deployment.'
$newConfig = [pscustomobject]@{ vmOptions = $config.vmOptions; virtualMachines = @([pscustomobject]@{ vmName = 'LAB-NEW'; hidden = $false }) }
Assert-True (-not (Get-ExistingVmQuickUpdatePlan -Config $newConfig -ExistingMachines @($vm) -ConfigBaselineJson $configBaseline).CanApplyQuickly) 'A new VM was incorrectly included in the quick path.'
$globalEdit = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$globalEdit.vmOptions | Add-Member -NotePropertyName network -NotePropertyValue '192.0.3.0' -Force
Assert-True (-not (Get-ExistingVmQuickUpdatePlan -Config $globalEdit -ExistingMachines @($vm) -ConfigBaselineJson $configBaseline).CanApplyQuickly) 'A global config edit incorrectly used the existing-VM quick path.'

$quick = Invoke-ExistingVmQuickUpdates -Config $config -ExistingMachines @($vm)
Assert-True ($quick.Handled -and $quick.Applied -eq 1 -and $quick.Failed -eq 0) 'The RAM-only edit did not complete through the quick path.'
Assert-True (@($script:Calls | Where-Object Action -eq 'Stop').Count -eq 1 -and
    @($script:Calls | Where-Object Action -eq 'Start').Count -eq 1) 'A running RAM edit did not restart exactly once.'
$memoryCall = $script:Calls | Where-Object Action -eq 'Memory' | Select-Object -Last 1
Assert-True (-not $memoryCall.Dynamic -and $memoryCall.Startup -eq 6GB) 'Disabling dynamic memory did not apply 6GB static RAM.'
Assert-True ($script:VmNote.memory -eq '6GB' -and $script:VmNote.dynamicMinRam -eq '6GB' -and
    $vm.'memory-Original' -eq '6GB' -and
    $vm.'dynamicMinRam-Original' -eq '6GB') 'Successful RAM updates did not persist notes and clear pending edit markers.'
Assert-True (-not (get-IsExistingVMModified -virtualMachine $vm)) 'An applied quick update remained queued as a deployment.'
Assert-True (@($script:Calls | Where-Object Action -in @('Stop', 'Start', 'Memory')).Count -eq 3) 'Quick application performed unexpected extra Hyper-V work.'

$quickAgain = Invoke-ExistingVmQuickUpdates -Config $config -ExistingMachines @($vm)
Assert-True (-not $quickAgain.Handled) 'An unchanged VM incorrectly ran another quick update.'
$callCount = $script:Calls.Count
$noOp = Set-MemLabsVmMemoryConfiguration -VmName 'LAB-W11' -Memory '6GB' -DynamicMinRam '6GB'
Assert-True (-not $noOp.Changed -and -not $noOp.Restarted -and $script:Calls.Count -eq $callCount) 'A correctly configured VM was not a host-side no-op.'

$script:Calls.Clear()
$script:HyperV = @{ Dynamic = $false; Minimum = 8GB; Maximum = 8GB; Startup = 8GB; State = 'Running' }
$dynamic = Set-MemLabsVmMemoryConfiguration -VmName 'LAB-PRI' -Memory '8GB' -DynamicMinRam '2GB' -Role 'Primary'
$memoryCall = $script:Calls | Where-Object Action -eq 'Memory' | Select-Object -Last 1
Assert-True ($dynamic.Changed -and $dynamic.Restarted -and $memoryCall.Dynamic -and
    $memoryCall.Minimum -eq 2GB -and $memoryCall.Maximum -eq 8GB -and
    $memoryCall.Priority -eq 50 -and $memoryCall.Buffer -eq 20) 'Dynamic-memory reconfiguration lost desired bounds or role priority.'

$script:Calls.Clear()
$originalStop = ${function:Stop-VM2}
function Stop-VM2 { param([string]$Name, [switch]$Passthru) if ($Passthru) { $false } }
$failed = New-ExistingMemoryVm -Name 'LAB-FAIL' -Memory '8GB' -DynamicMinRam '8GB'
$failure = Invoke-ExistingVmQuickUpdates -Config $config -ExistingMachines @($failed)
Assert-True ($failure.Handled -and $failure.Applied -eq 0 -and $failure.Failed -eq 1) 'A failed Hyper-V update was reported as successful.'
Assert-True ((get-IsExistingVMModified -virtualMachine $failed) -and $script:VisibleErrors.Count -eq 1) 'A failed quick update was removed from the retry queue or not surfaced.'
${function:Stop-VM2} = $originalStop

$script:HyperV = @{ Dynamic = $false; Minimum = 4GB; Maximum = 4GB; Startup = 4GB; State = 'Running' }
$script:VmNote.memoryRestartPending = $false
$script:FailMemorySet = $true
$setFailureVm = New-ExistingMemoryVm -Name 'LAB-SET-FAIL' -Memory '8GB' -DynamicMinRam '8GB'
$caught = $null
try { Set-MemLabsVmMemoryConfiguration -VmName $setFailureVm.vmName -Memory $setFailureVm.memory -DynamicMinRam $setFailureVm.dynamicMinRam }
catch { $caught = $_ }
$script:FailMemorySet = $false
Assert-True ($null -ne $caught -and $script:HyperV.State -eq 'Running' -and -not $script:VmNote.memoryRestartPending) 'A Set-VMMemory failure left the originally running VM down or journaling pending recovery.'

$script:HyperV = @{ Dynamic = $false; Minimum = 4GB; Maximum = 4GB; Startup = 4GB; State = 'Running' }
$script:VmNote.memoryRestartPending = $false
$script:FailStart = $true
$restartFailureVm = New-ExistingMemoryVm -Name 'LAB-START-FAIL' -Memory '8GB' -DynamicMinRam '8GB'
$caught = $null
try { Set-MemLabsVmMemoryConfiguration -VmName $restartFailureVm.vmName -Memory $restartFailureVm.memory -DynamicMinRam $restartFailureVm.dynamicMinRam }
catch { $caught = $_ }
Assert-True ($null -ne $caught -and $script:HyperV.State -eq 'Off' -and $script:VmNote.memoryRestartPending) 'A restart failure discarded the durable recovery state.'
$script:FailStart = $false
$script:Calls.Clear()
$recovered = Set-MemLabsVmMemoryConfiguration -VmName $restartFailureVm.vmName -Memory '8GB' -DynamicMinRam '8GB'
Assert-True ($recovered.Restarted -and $script:HyperV.State -eq 'Running' -and -not $script:VmNote.memoryRestartPending -and
    @($script:Calls | Where-Object Action -eq 'Memory').Count -eq 0) 'Retry after a restart failure did not recover the VM without reapplying memory.'

$script:HyperV = @{ Dynamic = $false; Minimum = 4GB; Maximum = 4GB; Startup = 4GB; State = 'Running' }
$script:VmNote = [pscustomobject]@{ memory = '4GB'; dynamicMinRam = '4GB'; memoryRestartPending = $false }
$noteFailureVm = New-ExistingMemoryVm -Name 'LAB-NOTE-FAIL' -Memory '8GB' -DynamicMinRam '8GB'
$script:FailFinalNote = $true
$script:VmNoteTargetMemory = '8GB'
$script:VmNoteTargetDynamicMin = '8GB'
$noteFailure = Invoke-ExistingVmQuickUpdates -Config $config -ExistingMachines @($noteFailureVm)
$script:FailFinalNote = $false
Assert-True ($noteFailure.Failed -eq 1 -and (get-IsExistingVMModified -virtualMachine $noteFailureVm)) 'A final note write failure cleared the only queued retry marker.'
$noteRetry = Invoke-ExistingVmQuickUpdates -Config $config -ExistingMachines @($noteFailureVm)
Assert-True ($noteRetry.Applied -eq 1 -and -not (get-IsExistingVMModified -virtualMachine $noteFailureVm) -and
    $script:VmNote.memory -eq '8GB' -and $script:VmNote.dynamicMinRam -eq '8GB') 'Retry after the atomic note failure did not complete metadata acceptance.'

$tokens = $null; $errors = $null
$genAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath 'genconfig.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "genconfig.ps1 parse errors: $($errors -join '; ')" }
$quickClause = $genAst.Find({
        param($node)
        $node -is [Management.Automation.Language.SwitchStatementAst] -and
        ($node.Clauses | Where-Object {
                $_.Item1.Extent.Text -eq '"d"' -and
                $_.Item2.Extent.Text -match 'Invoke-ExistingVmQuickUpdates' -and
                $_.Item2.Extent.Text -match 'continue'
            }).Count -gt 0
    }, $true)
Assert-True ($null -ne $quickClause) 'The Deploy menu action does not return to the domain menu after quick updates.'

# Exercise the post-deployment restore for a user-requested static value.
$script:RestoreStops = 0
$script:RestoreStarts = 0
$restoreVm = [pscustomobject]@{
    Name = 'LAB-STATIC'; DynamicMemoryEnabled = $true; State = 'Running'
    MemoryMinimum = 2GB; MemoryMaximum = 8GB; MemoryStartup = 8GB
}
function Get-List { param($Type) @([pscustomobject]@{ vmName = 'LAB-STATIC' }) }
function Test-VmIsLinux { param($Vm) $false }
function Get-Command {
    param([string]$Name)
    if ($Name -eq 'Start-ThreadJob') { return $null }
    Microsoft.PowerShell.Core\Get-Command -Name $Name
}
function Get-VM { param([string]$Name) $restoreVm }
function Stop-VM { param([Parameter(ValueFromPipeline = $true)]$VM, [switch]$Force) $script:RestoreStops++; $VM.State = 'Off' }
function Start-VM { param([Parameter(ValueFromPipeline = $true)]$VM) $script:RestoreStarts++; $VM.State = 'Running' }
$restoreConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'lab.test' }
    virtualMachines = @([pscustomobject]@{ vmName = 'LAB-STATIC'; memory = '8GB'; dynamicMinRam = '8GB'; role = 'DomainMember' })
}
$restoreLogs = [Collections.Generic.List[string]]::new()
Restore-DynamicMemory -DeployConfig $restoreConfig
$staticRestoreCall = $script:Calls | Where-Object Action -eq 'Memory' | Select-Object -Last 1
Assert-True ($script:RestoreStops -eq 1 -and $script:RestoreStarts -eq 1 -and
    -not $staticRestoreCall.Dynamic -and $staticRestoreCall.Startup -eq 8GB) 'Post-deployment restoration re-enabled dynamic memory for a static-memory VM.'

$script:FailMemorySet = $true
$restoreThrew = $false
try { Restore-DynamicMemory -DeployConfig $restoreConfig } catch { $restoreThrew = $true }
$script:FailMemorySet = $false
Assert-True ($restoreThrew -and $restoreVm.State -eq 'Running') 'A post-deployment restore failure was reported as success or left the VM stopped.'

foreach ($case in @(
        @{ Memory = '4GB'; Minimum = '4GB'; OriginalMinimum = $null; ExpectedMinimum = '2GB'; Warnings = 1 },
        @{ Memory = '4GB'; Minimum = '4GB'; OriginalMinimum = '3GB'; ExpectedMinimum = '2GB'; Warnings = 1 },
        @{ Memory = '8GB'; Minimum = '6GB'; OriginalMinimum = $null; ExpectedMinimum = '4GB'; Warnings = 2; OperatingSystem = 'Windows 11 Latest' }
    )) {
    $script:MemoryEditWarnings = @()
    $edited = New-ExistingMemoryVm -Memory '2GB' -DynamicMinRam $case.Minimum -OriginalMemory $case.Memory
    $edited | Add-Member -NotePropertyName 'operatingSystem' -NotePropertyValue $case.OperatingSystem
    $expectedOriginal = $case.OriginalMinimum
    if ($null -eq $expectedOriginal) {
        $edited.PSObject.Properties.Remove('dynamicMinRam-Original')
        $expectedOriginal = $case.Minimum
    }
    else {
        $edited.'dynamicMinRam-Original' = $expectedOriginal
    }
    Get-AdditionalValidations -property $edited -name 'memory' -CurrentValue $case.Memory
    Assert-True ($edited.dynamicMinRam -eq $case.ExpectedMinimum -and
        $edited.'dynamicMinRam-Original' -eq $expectedOriginal) 'Automatic minimum clamping lost or replaced the first existing-VM minimum comparison value.'
    $currentMemory = $edited.memory
    $edited.memory = $case.Memory
    Get-AdditionalValidations -property $edited -name 'memory' -CurrentValue $currentMemory
    Assert-True ($edited.dynamicMinRam -eq $case.ExpectedMinimum -and
        $edited.'dynamicMinRam-Original' -eq $expectedOriginal -and
        (get-IsExistingVMModified -virtualMachine $edited)) 'Restoring the original maximum hid the remaining minimum-memory edit.'
    Assert-True ($script:MemoryEditWarnings.Count -eq $case.Warnings) 'Restoring the maximum emitted an unexpected warning.'
    $editPlan = Get-ExistingVmQuickUpdatePlan -Config $config -ExistingMachines @($edited) -ConfigBaselineJson $configBaseline
    Assert-True ($editPlan.CanApplyQuickly -and $editPlan.VMs.Count -eq 1) 'The remaining automatic minimum-memory edit was omitted from quick application.'

    $memoryBytes = $case.Memory / 1
    $script:HyperV = @{ Dynamic = $false; Minimum = $memoryBytes; Maximum = $memoryBytes; Startup = $memoryBytes; State = 'Running' }
    $script:VmNote = [pscustomobject]@{ memory = $case.Memory; dynamicMinRam = $expectedOriginal; memoryRestartPending = $false }
    $editResult = Invoke-ExistingVmQuickUpdates -Config $config -ExistingMachines @($edited)
    Assert-True ($editResult.Handled -and $editResult.Applied -eq 1 -and $editResult.Failed -eq 0 -and
        $script:VmNote.memory -eq $case.Memory -and $script:VmNote.dynamicMinRam -eq $case.ExpectedMinimum -and
        -not (get-IsExistingVMModified -virtualMachine $edited)) 'The automatic minimum-memory edit was not applied and persisted after restoring the maximum.'
}

Write-Host "PASS -- $script:Assertions existing-VM RAM quick-apply assertions."
