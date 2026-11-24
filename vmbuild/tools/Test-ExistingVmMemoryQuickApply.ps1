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
    param([string]$Message, [switch]$Activity, [switch]$SubActivity, [switch]$LogOnly, [switch]$Failure, [switch]$Success, [switch]$Warning, [switch]$NoNewLine)
}
function Write-GreenCheck { param([string]$Message) }
function Write-OrangePoint { param([string]$Message) }
function Write-RedX { param([string]$Message) $script:VisibleErrors += $Message }
function Add-ErrorMessage {
    param([string]$Message, [string]$Property, [switch]$Warning, [switch]$Persist)
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

foreach ($shape in 'missing', 'null', 'empty', 'null-entry', 'new-with-null') {
    $shapeConfig = [pscustomobject]@{ vmOptions = $config.vmOptions }
    if ($shape -ne 'missing') {
        $authoringVms = $null
        if ($shape -eq 'empty') { $authoringVms = @() }
        if ($shape -eq 'null-entry') { $authoringVms = @($null) }
        if ($shape -eq 'new-with-null') { $authoringVms = @($null, [pscustomobject]@{ vmName = 'NEW'; hidden = $false }) }
        $shapeConfig | Add-Member -NotePropertyName virtualMachines -NotePropertyValue $authoringVms
    }
    $shapePlan = Get-ExistingVmQuickUpdatePlan -Config $shapeConfig -ExistingMachines @($vm) `
        -ConfigBaselineJson ($shapeConfig | ConvertTo-Json -Depth 10 -Compress)
    $expectedNew = [int]($shape -eq 'new-with-null')
    Assert-True ($shapePlan.NewVmCount -eq $expectedNew -and
        $shapePlan.CanApplyQuickly -eq ($expectedNew -eq 0)) "Authoring VM shape '$shape' counted a null placeholder as a new VM or ignored a real VM."
}

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

& {
    foreach ($entry in @(
            @{ Path = 'genconfig.ps1'; Name = 'Get-ExistingVMs' },
            @{ Path = 'genconfig.ps1'; Name = 'Select-MainMenu' },
            @{ Path = 'genconfig.ps1'; Name = 'Build-MainMenuOptions' },
            @{ Path = 'common\Common.GenConfig.Existing.ps1'; Name = 'New-UserConfig' },
            @{ Path = 'common\Common.GenConfig.VMList.ps1'; Name = 'Select-VirtualMachines' },
            @{ Path = 'common\Common.GenConfig.VMList.ps1'; Name = 'Select-Options' },
            @{ Path = 'common\Common.GenConfig.Summary.ps1'; Name = 'Get-SortedProperties' },
            @{ Path = 'common\Common.GenConfig.Summary.ps1'; Name = 'get-VMOptionsSummary' },
            @{ Path = 'common\Common.GenConfig.Summary.ps1'; Name = 'get-CMOptionsSummary' },
            @{ Path = 'common\Common.GenConfig.NewDomain.ps1'; Name = 'Initialize-PerVmLocales' },
            @{ Path = 'common\Common.GenConfig.NewDomain.ps1'; Name = 'Set-DefaultLocaleForVM' }
        )) {
        . (Import-TestFunction -Path $entry.Path -Name $entry.Name)
    }

    $script:LegacyCatalogPath = Join-Path $RootPath 'common\LocaleCatalog.json'
    $script:LegacyLocaleInitializer = ${function:Initialize-PerVmLocales}
    $script:LegacyLocaleSetter = ${function:Set-DefaultLocaleForVM}
    $script:LegacyPropertyEditor = ${function:Select-Options}
    function Initialize-PerVmLocales {
        param($ConfigToCheck)
        & $script:LegacyLocaleInitializer -ConfigToCheck $ConfigToCheck -CatalogPath $script:LegacyCatalogPath
    }
    function Set-DefaultLocaleForVM {
        param($ConfigToCheck, $VirtualMachine)
        & $script:LegacyLocaleSetter -ConfigToCheck $ConfigToCheck -VirtualMachine $VirtualMachine -CatalogPath $script:LegacyCatalogPath
    }

    function Add-OfflineRootCAVMIfMissing { param($ConfigToModify) }
    function Remove-OfflineRootCAVMIfAutoAdded { param($ConfigToModify) }
    function Add-ProxyVMIfMissing { param($ConfigToModify) }
    function Remove-ProxyVMIfAutoAdded { param($ConfigToModify) }
    function Test-Configuration { param($InputObject, [switch]$Fast) [pscustomobject]@{ Valid = $true } }
    function Convert-ValidationMessages { param($TestObject) }
    function Get-PKIOptionsSummary { '' }
    function Get-VMString { param($Config, $VirtualMachine, [switch]$Colors) $VirtualMachine.vmName }
    function Get-TimeZone { [pscustomobject]@{ Id = 'UTC' } }
    function Format-OptionToken { param($Color, $Text) $Text }
    function Limit-AnsiString { param($Text, $MaxVisible) $Text }
    function Get-LocaleProfiles { param($Path) @{ 'en-US' = [pscustomobject]@{ LanguageTag = 'en-US' } } }
    function Get-LocaleDefinitionForOperatingSystem { param($LocaleDefinition, $OperatingSystem) $LocaleDefinition }
    function Get-LocaleAcquisitionMethod { param([Alias('Profile')]$LocaleDefinition, $OperatingSystem, $ConfigPath) 'Included' }
    function get-PrefixForDomain { param($Domain) 'LAB-' }
    function Get-MemlabsVmStorageRoot { 'C:\fixture-vms' }
    function Get-DomainNetbiosName { param($DomainName) 'LEGACY' }
    function Get-AdditionalInformation { param($Item, $Data) "$Data" }
    function Get-AdditionalInformationColor { param($Item, $Data) 'Gray' }
    function Get-MenuItems { param($MenuName, $ExistingMenuItems, $AdditionalOptions) }
    function Add-MenuItem {
        param($MenuName, [ref]$MenuItems, $ItemName, $ItemText, $Selectable, $Selected, $Color1, $Color2, $HelpFunction)
        $item = [pscustomobject]@{ ItemName = "$ItemName"; ItemText = $ItemText }
        $null = $MenuItems.Value.Add($item)
        $item
    }
    function Read-Host2 {
        param($Prompt, $CurrentValue, [switch]$HideHelp)
        if ($Prompt -eq 'Press Enter to return to the menu') {
            Assert-True ($HideHelp -and $script:LegacyMemoryRequests.Count -eq 2 -and
                $script:LegacyUiResults.Count -eq 3) 'The menu paused before all per-VM results and the batch summary were visible.'
            $script:LegacyUiEvents.Add('pause')
            $script:LegacyPauses++
            return 'acknowledged'
        }
        if ($Prompt -notlike '*Memory*') { throw "Unexpected property edit: $Prompt" }
        '4GB'
    }
    function Write-GreenCheck { param($Message); $script:LegacyUiResults.Add("$Message") }
    function Write-RedX { param($Message); $script:LegacyUiResults.Add("$Message") }
    function Write-OrangePoint {
        param($Message)
        if ($Message -like '*update(s) applied;*') { $script:LegacyUiResults.Add("$Message") }
    }
    function Read-YesOrNoWithTimeout {
        param($Prompt, $Default, [switch]$HideHelp, $Timeout)
        $script:LegacyScopePrompts++
        if ($Default -ne 'n') { throw 'Scope expansion must default to no.' }
        if ($script:LegacyApproveScope) { 'y' } else { 'n' }
    }
    function Get-List {
        param($Type, $Domain)
        $script:LegacyNotes.Values | Sort-Object @{
            Expression = {
                if ($_.vmName -like 'LAB-OLD*') { [int]$script:LegacyServersFirst }
                else { [int](-not $script:LegacyServersFirst) }
            }
        }, vmName | ForEach-Object { $_ | ConvertTo-Json -Depth 5 | ConvertFrom-Json }
    }
    function Get-Menu2 {
        param($MenuName, $Prompt, $OptionArray, $AdditionalOptions, $PreOptions, $MenuItems, $Test, [switch]$AcceptsDelete, $HideHelp, $DroppableItemPattern)
        if ($MenuName -like 'VM Deployment Menu -*') { $script:LegacyUiEvents.Add('menu') }
        if ($MenuName -like 'Modify Properties for LAB-OLD*') {
            $visits = [int]$script:LegacyEditorVisits[$MenuName]
            $script:LegacyEditorVisits[$MenuName] = $visits + 1
            if ($visits -eq 0) { return '1' }
            return '!'
        }
        if ($script:LegacyResponses.Count -eq 0) { throw 'Legacy RAM fixture exhausted its menu responses.' }
        $script:LegacyResponses.Dequeue()
    }
    function Select-Options {
        param($MenuName, $Rootproperty, $PropertyName, $Prompt, $HelpFunction, $PropertyEnum, $PropertyNum, $AdditionalOptions, $Test)
        if ($PropertyName -eq 'vmOptions') {
            $Rootproperty.vmOptions.network = '192.168.3.0'
            return
        }
        & $script:LegacyPropertyEditor @PSBoundParameters
    }
    function Set-MemLabsVmMemoryConfiguration {
        param($VmName, $Memory, $DynamicMinRam, $Role, $SqlVersion)
        if ($VmName -notin @('LAB-OLD1', 'LAB-OLD2')) { throw "Unrelated VM memory mutation: $VmName" }
        $script:LegacyMemoryRequests.Add($VmName)
        if ($VmName -in $script:LegacyFailMemoryVMs) { throw "Synthetic memory update failure for $VmName." }
        [pscustomobject]@{ Changed = $true; Restarted = $true }
    }
    function Set-VMNote {
        param($VmName, $VmNote)
        $script:LegacyNoteWrites.Add($VmName)
        if ($VmName -notin @('LAB-OLD1', 'LAB-OLD2')) { throw "Unrelated VM note mutation: $VmName" }
        foreach ($property in $VmNote.PSObject.Properties) {
            $script:LegacyNotes[$VmName] | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    function Add-ModifiedExistingVMsToConfig { $script:LegacyDeploymentRequests++ }

    $InternalUseOnly = [switch]$true
    $enableDebug = $false
    $global:Common = [pscustomobject]@{
        ConfigPath = Join-Path $RootPath 'config'
        Colors = [pscustomobject]@{}
        Supported = [pscustomobject]@{ UpdatablePropList = @('memory', 'dynamicMinRam', 'useProxy', 'locale', 'installOffice') }
    }
    foreach ($mode in 'ram-server-first', 'ram-client-first', 'ram-partial-failure', 'ram-all-failure', 'global-approved', 'global-declined') {
        $editGlobalOptions = $mode -like 'global-*'
        $script:LegacyServersFirst = $mode -ne 'ram-client-first'
        $global:existingMachines = $null
        $global:GenConfigQuickApplyBaselineJson = $null
        $global:PendingValidationErrors = $null
        $script:LegacyNotes = @{}
        foreach ($vmName in 'LAB-OLD1', 'LAB-OLD2') {
            $script:LegacyNotes[$vmName] = [pscustomobject]@{
                vmName = $vmName; role = 'DomainMember'; domain = 'legacy.test'
                operatingSystem = 'Windows 10 Latest'; memory = '2GB'; dynamicMinRam = '2GB'
            }
            $script:LegacyNotes['ZZ-DC'] = [pscustomobject]@{ vmName = 'ZZ-DC'; role = 'DC'; domain = 'legacy.test' }
            $script:LegacyNotes['ZZ-PRI'] = [pscustomobject]@{
                vmName = 'ZZ-PRI'; role = 'Primary'; siteCode = 'PS1'; domain = 'legacy.test'
                cmOptions = [pscustomobject]@{ version = '2203'; install = $true; PrePopulateObjects = $true }
            }
            $script:LegacyNotes['ZZ-SQL'] = [pscustomobject]@{ vmName = 'ZZ-SQL'; role = 'DomainMember'; domain = 'legacy.test'; sqlVersion = 'SQL Server 2019' }
            $serverBaseline = @{}
            foreach ($name in 'ZZ-DC', 'ZZ-PRI', 'ZZ-SQL') { $serverBaseline[$name] = $script:LegacyNotes[$name] | ConvertTo-Json -Depth 5 -Compress }
            $global:Config = New-UserConfig -Domain 'legacy.test' -Subnet '192.168.2.0'
            Assert-True ($null -eq $global:Config.virtualMachines) 'The real existing-domain template no longer exercises its null authoring list.'
            $script:LegacyEditorVisits = @{}
            $script:LegacyScopePrompts = 0
            $script:LegacyApproveScope = $mode -eq 'global-approved'
            $script:LegacyNoteWrites = [Collections.Generic.List[string]]::new()
        }
        $script:LegacyMemoryRequests = [Collections.Generic.List[string]]::new()
        $script:LegacyUiResults = [Collections.Generic.List[string]]::new()
        $script:LegacyUiEvents = [Collections.Generic.List[string]]::new()
        $script:LegacyPauses = 0
        $script:LegacyFailMemoryVMs = switch ($mode) {
            'ram-partial-failure' { @('LAB-OLD1') }
            'ram-all-failure' { @('LAB-OLD1', 'LAB-OLD2') }
            default { @() }
        }
        $script:LegacyDeploymentRequests = 0
        $script:LegacyResponses = [Collections.Generic.Queue[string]]::new()
        foreach ($response in '1', '2') { $script:LegacyResponses.Enqueue($response) }
        if ($editGlobalOptions) { $script:LegacyResponses.Enqueue('V') }
        foreach ($response in 'D', 'S') { $script:LegacyResponses.Enqueue($response) }

        $deploy = Select-MainMenu
        Assert-True ($deploy -is [bool] -and $script:LegacyPauses -eq [int](-not $editGlobalOptions)) `
            'The quick-update acknowledgement leaked into the menu result or paused an unhandled deployment path.'
        if (-not $editGlobalOptions) {
            $pauseIndex = $script:LegacyUiEvents.IndexOf('pause')
            Assert-True ($pauseIndex -ge 0 -and $script:LegacyUiEvents[$pauseIndex + 1] -eq 'menu' -and
                $script:LegacyUiEvents.IndexOf('menu', $pauseIndex + 1) -eq $script:LegacyUiEvents.Count - 1) `
                'The domain menu did not wait for acknowledgement before its next redraw.'
        }
        $expectedFirst = if ($script:LegacyServersFirst) { 'ZZ-*' } else { 'LAB-OLD*' }
        Assert-True ($global:existingMachines[0].vmName -like $expectedFirst) 'The RAM fixture did not exercise its selected inventory ordering.'
        foreach ($name in 'ZZ-DC', 'ZZ-PRI', 'ZZ-SQL') {
            Assert-True (($script:LegacyNotes[$name] | ConvertTo-Json -Depth 5 -Compress) -eq $serverBaseline[$name]) 'RAM authoring changed an unrelated server note.'
        }
        if ($editGlobalOptions) {
            Assert-True ($deploy -eq $script:LegacyApproveScope -and
                $script:LegacyDeploymentRequests -eq [int]$script:LegacyApproveScope -and
                $script:LegacyMemoryRequests.Count -eq 0 -and $script:LegacyScopePrompts -eq 1) 'Global plus RAM edits bypassed the explicit broader-scope decision.'
            continue
        }
        if ($mode -in @('ram-partial-failure', 'ram-all-failure')) {
            $pending = @($global:existingMachines | Where-Object { get-IsExistingVMModified -virtualMachine $_ })
            $failedCount = @($script:LegacyFailMemoryVMs).Count
            Assert-True (-not $deploy -and $script:LegacyDeploymentRequests -eq 0 -and
                $pending.Count -eq $failedCount -and $script:LegacyNoteWrites.Count -eq 2 - $failedCount) `
                'Acknowledging failed quick updates changed the retry queue or entered deployment.'
            Assert-True ($script:LegacyUiResults[-1] -eq "$(2 - $failedCount) update(s) applied; $failedCount update(s) remain queued for retry.") `
                'The failure acknowledgement did not preserve the actual batch outcome.'
            continue
        }
        Assert-True ($deploy -eq $false -and $script:LegacyDeploymentRequests -eq 0 -and
            $script:LegacyMemoryRequests.Count -eq 2 -and $script:LegacyScopePrompts -eq 0 -and
            (($script:LegacyNoteWrites | Sort-Object) -join ',') -eq 'LAB-OLD1,LAB-OLD2') 'Real legacy RAM editor flow entered deployment or wrote unrelated VM notes.'
        Assert-True ($global:Config.domainDefaults.DefaultLocale -eq 'en-US' -and
            $global:Config.vmOptions.timeZone -eq 'UTC') 'The legacy menu fixture did not exercise initial locale/time-zone normalization.'
        foreach ($vmName in 'LAB-OLD1', 'LAB-OLD2') {
            $note = $script:LegacyNotes[$vmName]
            Assert-True ($note.memory -eq '4GB' -and $note.dynamicMinRam -eq '2GB' -and
                -not $note.PSObject.Properties['locale'] -and
                -not $note.PSObject.Properties['useProxy']) 'A quick RAM update backfilled unrelated locale/proxy properties into a legacy VM note.'
        }
        Assert-True (-not @($global:existingMachines | Where-Object {
                    get-IsExistingVMModified -virtualMachine $_
                }).Count) 'Successfully applied legacy RAM edits remained queued for deployment.'
        foreach ($propertyName in 'locale', 'useProxy') {
            $explicitEdit = ($global:existingMachines | Where-Object { $_.vmName -eq 'LAB-OLD1' }).PSObject.Copy()
            $explicitEdit.memory = '6GB'
            $explicitEdit | Add-Member -NotePropertyName "$propertyName-Original" -NotePropertyValue $explicitEdit.$propertyName -Force
            if ($propertyName -eq 'locale') { $explicitEdit.locale = 'fr-FR' }
            else { $explicitEdit.useProxy = $true }
            $explicitPlan = Get-ExistingVmQuickUpdatePlan -Config $global:Config -ExistingMachines @($explicitEdit) `
                -ConfigBaselineJson $global:GenConfigQuickApplyBaselineJson
            Assert-True (-not $explicitPlan.CanApplyQuickly -and
                $explicitPlan.UnsupportedChanges -contains "$($explicitEdit.vmName):$propertyName") 'An intentional locale/proxy edit was mistaken for a legacy editor default.'
        }
    }
}

Write-Host "PASS -- $script:Assertions existing-VM RAM quick-apply assertions."
