#requires -Version 5.1
<#
.SYNOPSIS
    Verifies existing PXE targets receive host-only preparation without Windows probes.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "VM worker parse errors: $($errors -join '; ')" }

$worker = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$global:VM_Create'
    }, $true)
if (-not $worker) { throw 'VM_Create was not found.' }
$workerTry = $worker.Right.Find({
        param($node)
        $node -is [Management.Automation.Language.TryStatementAst]
    }, $true)
$statements = @($workerTry.Body.Statements)
$selection = @($statements | Where-Object {
        ($_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -in @('$createVM', '$resumePreparation')) -or
        ($_ -is [Management.Automation.Language.IfStatementAst] -and
            ($_.Clauses[0].Item1.Extent.Text -eq '$currentItem.hidden -eq $true' -or
                $_.Clauses[0].Item1.Extent.Text -eq '$resumePreparation'))
    })
$hardware = @($statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq '-not $CreateVM'
    })
$createOrPrepare = @($statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq '$createVM' -and
        $_.ElseClause.Extent.Text -match 'Could not verify if VM is connectable'
    })
if ($selection.Count -ne 4 -or $hardware.Count -ne 1 -or $createOrPrepare.Count -ne 1) {
    throw 'Could not isolate existing-VM selection, hardware preparation, and readiness from VM_Create.'
}
$script:preparation = [scriptblock]::Create((@($selection.Extent.Text) +
        $hardware[0].Extent.Text +
        "if (-not `$createVM) $($createOrPrepare[0].ElseClause.Extent.Text)") -join "`n")
$newOsdCompletion = @($createOrPrepare[0].Clauses[0].Item2.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$currentItem.role -eq "OSDClient"' -and
            $node.Extent.Text -match 'New-VmNote.+[\s\S]+VM Creation completed successfully'
        }, $true))
if ($newOsdCompletion.Count -ne 1) { throw 'Expected one fresh OSD creation completion branch.' }
$script:newOsdCompletion = [scriptblock]::Create($newOsdCompletion[0].Extent.Text)

$hyperVAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'common\Common.HyperV.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Hyper-V source parse errors: $($errors -join '; ')" }
$initializer = @($hyperVAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Initialize-OsdClientHost'
        }, $true))
if ($initializer.Count -ne 1) { throw 'Expected one Initialize-OsdClientHost definition.' }
. ([scriptblock]::Create($initializer[0].Extent.Text))
$script:fixtureCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Log {
    param($Message, [switch]$Failure, [switch]$Success, [switch]$OutputStream, [switch]$LogOnly, [switch]$Warning)
    $script:messages.Add([pscustomobject]@{
            Message = "$Message"
            Failure = [bool]$Failure
            Success = [bool]$Success
        })
}

function Get-VM2 {
    [CmdletBinding()]
    param([string]$Name, [switch]$Fallback)
    $script:calls.LegacyLookup++
    Get-VM -Name $Name -ErrorAction Stop
}

function Get-VM {
    [CmdletBinding()]
    param([string]$Name)
    $script:calls.Lookup++
    if ($script:failureMode -eq 'ReadBusyAlways' -or
        ($script:failureMode -eq 'ReadTransient' -and $script:calls.Lookup -le 2)) {
        throw 'Synthetic RPC server is unavailable (0x800706BA).'
    }
    if ($script:failureMode -eq 'ReadLocalizedTransient' -and $script:calls.Lookup -le 2) {
        throw [Runtime.InteropServices.COMException]::new('Erreur distante.', -2147023174)
    }
    if ($script:failureMode -eq 'ReadLocalizedPermanent') {
        throw [Runtime.InteropServices.COMException]::new('Acces refuse.', -2147024891)
    }
    if ($script:failureMode -eq 'ReadPermanent') { throw 'Synthetic access denied reading VM.' }
    if ($script:failureMode -eq 'Missing' -or
        ($script:failureMode -eq 'Disappeared' -and $script:calls.Stop -gt 0)) {
        throw "Synthetic VM '$Name' was not found."
    }
    if ($script:failureMode -eq 'EmptyAlways' -or
        ($script:failureMode -eq 'EmptyTransient' -and $script:calls.Lookup -le 2)) {
        return $null
    }
    if ($script:pendingStates.Count -gt 0) {
        $script:fixtureVm.State = $script:pendingStates.Dequeue()
    }
    if (($script:failureMode -eq 'Replaced' -and $script:calls.Stop -gt 0) -or
        ($script:failureMode -eq 'InitialReplaced' -and $script:calls.Lookup -gt 1)) {
        $script:fixtureVm.Id = $script:replacementId
    }
    $snapshot = $script:fixtureVm | Select-Object *
    if ($script:failureMode -eq 'InvalidRecord') { $snapshot.Id = $null }
    if ($script:failureMode -eq 'WrongName') { $snapshot.Name = 'OTHER-OSD' }
    if ($script:failureMode -eq 'MultipleRecords') { return @($snapshot, $snapshot) }
    if ($script:failureMode -eq 'DelayedReadback' -and $script:calls.Memory -gt 0 -and
        $script:staleReadsRemaining -gt 0) {
        $script:staleReadsRemaining--
        $snapshot.MemoryStartup = 2GB
    }
    return $snapshot
}

function Test-VmIsLinux { param($Vm) return $false }
function Start-Sleep {
    param([int]$Seconds)
    $script:waitSeconds.Add($Seconds)
}

function Stop-VM2 {
    [CmdletBinding()]
    param([string]$Name, [switch]$Passthru, [int]$RetryCount, [int]$RetrySeconds, [int]$GracefulTimeoutSeconds)
    $script:calls.Stop++
    $script:stopArguments = $PSBoundParameters
    if ($script:failureMode -eq 'StopFalse') { return $false }
    if ($script:failureMode -eq 'StopThrows') { throw 'Synthetic stop failure.' }
    if ($script:failureMode -eq 'StopNoOp') { return $true }
    $script:fixtureVm.State = 'Off'
    if ($script:failureMode -eq 'StopFalseAfterOff') { return $false }
    if ($script:failureMode -eq 'StopWrongType') { return 'True' }
    if ($script:failureMode -eq 'StopTransition') {
        foreach ($state in @('Stopping', 'Stopping', 'Off')) { $script:pendingStates.Enqueue($state) }
    }
    if ($script:failureMode -eq 'UnexpectedSaved') { $script:fixtureVm.State = 'Saved' }
    if ($Passthru) { return $true }
}

function Start-VM2 {
    [CmdletBinding()]
    param([string]$Name, [switch]$Passthru, [int]$RetryCount, [int]$RetrySeconds)
    $script:calls.Start++
    $script:startArguments = $PSBoundParameters
    if ($script:failureMode -in @('StartFalse', 'ProcessorAndRestoreFailure')) { return $false }
    if ($script:failureMode -eq 'StartNoOp') { return $true }
    $script:fixtureVm.State = 'Running'
    if ($script:failureMode -eq 'StartWrongType') { return 'True' }
    if ($script:failureMode -eq 'StartTransition') {
        foreach ($state in @('Starting', 'Starting', 'Running')) { $script:pendingStates.Enqueue($state) }
    }
    if ($Passthru) { return $true }
}

function Set-VMMemory {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]$InputObject,
        [bool]$DynamicMemoryEnabled,
        [long]$StartupBytes,
        [long]$MinimumBytes,
        [long]$MaximumBytes
    )
    process {
        $script:calls.Memory++
        if ($script:failureMode -eq 'MemoryBusyAlways' -or
            ($script:failureMode -eq 'MemoryTransient' -and $script:calls.Memory -le 2)) {
            throw 'Synthetic memory message filter failure (0x80010002).'
        }
        if ($script:failureMode -eq 'MemoryPermanent') { throw 'Synthetic memory access denied.' }
        if ($script:failureMode -eq 'MemoryNoOp') { return }
        if ($script:fixtureVm.State -ne 'Off' -and $StartupBytes -ne $script:fixtureVm.MemoryStartup) {
            throw 'Startup RAM was changed before confirming Off state.'
        }
        Assert-True ($InputObject.Id -eq $script:fixtureVm.Id) 'Memory update targeted a replacement VM.'
        $script:fixtureVm.MemoryStartup = $StartupBytes
        $script:fixtureVm.DynamicMemoryEnabled = $DynamicMemoryEnabled
        if ($PSBoundParameters.ContainsKey('MinimumBytes')) { $script:fixtureVm.MemoryMinimum = $MinimumBytes }
        if ($PSBoundParameters.ContainsKey('MaximumBytes')) { $script:fixtureVm.MemoryMaximum = $MaximumBytes }
        if ($script:failureMode -eq 'DynamicMemoryNoOp') { $script:fixtureVm.DynamicMemoryEnabled = $false }
    }
}

function Set-VM {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject, [int]$ProcessorCount)
    process {
        $script:calls.Processor++
        if ($script:failureMode -eq 'ProcessorBusyAlways' -or
            ($script:failureMode -eq 'ProcessorTransient' -and $script:calls.Processor -le 2)) {
            throw 'Synthetic processor server is too busy (0x800706BB).'
        }
        if ($script:failureMode -in @('ProcessorPermanent', 'ProcessorAndRestoreFailure')) {
            throw 'Synthetic processor access denied.'
        }
        if ($script:failureMode -eq 'ProcessorNonTerminating') {
            Write-Error 'Synthetic non-terminating processor failure.'
            return
        }
        if ($script:failureMode -eq 'ProcessorNoOp') { return }
        Assert-True ($script:fixtureVm.State -eq 'Off') 'Processor update ran before confirming Off state.'
        Assert-True ($InputObject.Id -eq $script:fixtureVm.Id) 'Processor update targeted a replacement VM.'
        $script:fixtureVm.ProcessorCount = $ProcessorCount
    }
}

function Wait-ForHeartbeat {
    param([string]$VmName)
    $script:calls.Heartbeat++
    return $true
}

function Wait-ForVM {
    param([string]$VmName, [string]$PathToVerify, [string]$VmDomainName)
    $script:calls.Readiness++
    return $false
}

function Invoke-VmCommand { $script:calls.Guest++; throw 'Unexpected guest command.' }
function Get-VmSession { $script:calls.Guest++; throw 'Unexpected guest session.' }
function New-VmNote {
    param([string]$VmName, $DeployConfig, [bool]$Successful, [int]$Phase)
    $script:calls.Note++
    Assert-True ($script:allowNewNote -and $Successful -and $Phase -eq 1) 'Existing PXE preparation rewrote the VM note.'
}
function New-VirtualMachine { $script:calls.Recreate++; throw 'Unexpected VM creation.' }
function Remove-VirtualMachine { $script:calls.Recreate++; throw 'Unexpected VM deletion.' }
function Remove-VMSavedState { $script:calls.DiscardState++; throw 'Unexpected saved-state removal.' }

function Invoke-PreparationFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Fixture variables are consumed by the extracted VM_Create script block.')]
    [CmdletBinding()]
    param(
        [string]$Role = 'OSDClient',
        [string]$Mode = 'Resume',
        [string]$State = 'Off',
        [string]$Change = 'None',
        [string]$FailureMode,
        [int]$Generation = 2,
        [switch]$DynamicMemory,
        [long]$MinimumBytes = 1GB,
        [long]$MemoryBytes,
        [int]$Processors,
        [long]$DynamicMinRam,
        [switch]$Direct,
        [switch]$StrictMode
    )

    $script:fixtureCount++
    $script:failureMode = $FailureMode
    $script:allowNewNote = ($Mode -eq 'New')
    $script:calls = [ordered]@{
        Lookup = 0; LegacyLookup = 0; Stop = 0; Start = 0; Memory = 0; Processor = 0
        Heartbeat = 0; Readiness = 0; Guest = 0; Note = 0; Recreate = 0; DiscardState = 0
    }
    $script:messages = [Collections.Generic.List[object]]::new()
    $script:waitSeconds = [Collections.Generic.List[int]]::new()
    $script:pendingStates = [Collections.Generic.Queue[string]]::new()
    $script:staleReadsRemaining = 2
    $script:replacementId = [guid]::NewGuid()
    $script:stopArguments = $null
    $script:startArguments = $null
    $script:fixtureVm = [pscustomobject]@{
        Name = 'TEST-OSD1'
        VmName = 'TEST-OSD1'
        Id = [guid]::NewGuid()
        Generation = $Generation
        State = $State
        Status = 'Operating normally'
        Heartbeat = 'NoContact'
        MemoryStartup = 2GB
        DynamicMemoryEnabled = [bool]$DynamicMemory
        MemoryMinimum = $MinimumBytes
        MemoryMaximum = 2GB
        ProcessorCount = 2
    }
    if ($FailureMode -in @('InitialTransition', 'InitialReplaced')) {
        foreach ($next in @('Starting', 'Starting', 'Off')) { $script:pendingStates.Enqueue($next) }
    }
    $currentItem = [pscustomobject]@{
        vmName = 'TEST-OSD1'
        role = $Role
        hidden = ($Mode -eq 'Hidden')
        memory = $(if ($Change -in @('Memory', 'Both')) { 4GB } else { 2GB })
        virtualProcs = $(if ($Change -in @('Processor', 'Both')) { 4 } else { 2 })
    }
    if ($PSBoundParameters.ContainsKey('MemoryBytes')) { $currentItem.memory = $MemoryBytes }
    if ($PSBoundParameters.ContainsKey('Processors')) { $currentItem.virtualProcs = $Processors }
    $deployConfig = [pscustomobject]@{
        parameters = [pscustomobject]@{ ResumePreparation = ($Mode -eq 'Resume') }
    }
    $Phase = if ($Mode -eq 'New') { 1 } else { 0 }
    if (-not $PSBoundParameters.ContainsKey('DynamicMinRam')) {
        $DynamicMinRam = if ($Change -eq 'DynamicMemory') { 1GB } else { 0 }
    }
    $domainName = 'resume.test'
    if ($StrictMode) { Set-StrictMode -Version Latest }
    if ($Direct) {
        $script:rawResult = @(Initialize-OsdClientHost -VmName $currentItem.vmName `
                -MemoryBytes $currentItem.memory -ProcessorCount $currentItem.virtualProcs `
                -DynamicMinRam $DynamicMinRam -Phase $Phase)
    }
    else {
        & $script:preparation
        if ($Mode -eq 'New') { & $script:newOsdCompletion }
    }
}

function Assert-NoGuestOrDestructiveOperations {
    param([string]$Label)
    Assert-True ($script:calls.Readiness -eq 0 -and $script:calls.Heartbeat -eq 0 -and
        $script:calls.Guest -eq 0) "$Label attempted Windows guest readiness."
    Assert-True ($script:calls.Note -eq 0 -and $script:calls.Recreate -eq 0 -and
        $script:calls.DiscardState -eq 0) "$Label rewrote notes, recreated a VM, or discarded saved state."
}

function Assert-PreparationPassed {
    param([string]$Label)
    Assert-NoGuestOrDestructiveOperations $Label
    Assert-True (@($script:messages | Where-Object Failure).Count -eq 0) "$Label reported a failure."
    Assert-True (@($script:messages | Where-Object {
                $_.Success -and $_.Message -match 'Existing VM Preparation completed successfully.+OSDClient.+PXE'
            }).Count -eq 1) "$Label did not report one host-only success."
    foreach ($diagnostic in @('preflight:', 'verified:', 'WindowsGuestChecks=Skipped', 'Id=', 'State=',
            'Generation=', 'Heartbeat=NoContact', 'MemoryStartup=', 'ProcessorCount=',
            'requestedStartupBytes=', 'requestedProcessors=', 'originalState=', 'elapsedSeconds=')) {
        Assert-True (@($script:messages | Where-Object { $_.Message.Contains($diagnostic) }).Count -gt 0) `
            "$Label omitted diagnostic '$diagnostic'."
    }
}

function Assert-PreparationFailed {
    param([string]$Label)
    Assert-NoGuestOrDestructiveOperations $Label
    Assert-True (@($script:messages | Where-Object Failure).Count -gt 0) "$Label was not reported explicitly."
    Assert-True (@($script:messages | Where-Object Success).Count -eq 0) "$Label was reported as success."
    Assert-True (@($script:messages | Where-Object {
                $_.Message -match "OSD host preparation failed at '.+errorId=.+lastHostState=.+elapsedSeconds="
            }).Count -eq 1) "$Label omitted the failed operation, error ID, host state, or elapsed time."
}

foreach ($generation in @(1, 2)) {
    foreach ($mode in @('Hidden', 'Resume')) {
        foreach ($state in @('Off', 'Running')) {
            foreach ($change in @('None', 'Memory', 'Processor', 'Both', 'DynamicMemory')) {
                Invoke-PreparationFixture -Mode $mode -State $state -Change $change -Generation $generation
                $label = "Gen$generation/$mode/$state/$change"
                Assert-PreparationPassed $label
                Assert-True ($script:fixtureVm.State -eq $state) "$label changed the target's power state."
                $expectedRestart = [int]($state -eq 'Running' -and $change -ne 'None')
                Assert-True ($script:calls.Start -eq $expectedRestart -and
                    $script:calls.Stop -eq $expectedRestart) "$label unnecessarily started or stopped the PXE target."
                $expectedMemory = if ($change -in @('Memory', 'Both')) { 4GB } else { 2GB }
                $expectedProcessors = if ($change -in @('Processor', 'Both')) { 4 } else { 2 }
                Assert-True ($script:fixtureVm.MemoryStartup -eq $expectedMemory) "$label did not apply requested RAM."
                Assert-True ($script:fixtureVm.ProcessorCount -eq $expectedProcessors) "$label did not apply requested processors."
                if ($change -eq 'DynamicMemory') {
                    Assert-True $script:fixtureVm.DynamicMemoryEnabled "$label did not apply requested dynamic memory."
                }
                if ($expectedRestart) {
                    Assert-True ($script:stopArguments.Passthru -and $script:stopArguments.RetryCount -eq 1 -and
                        $script:stopArguments.RetrySeconds -eq 5 -and $script:stopArguments.GracefulTimeoutSeconds -eq 30) `
                        "$label did not use bounded stop recovery."
                    Assert-True ($script:startArguments.Passthru -and $script:startArguments.RetryCount -eq 1 -and
                        $script:startArguments.RetrySeconds -eq 5) "$label did not use bounded start recovery."
                }
            }
        }
    }
}

foreach ($failure in @('ReadTransient', 'EmptyTransient', 'ReadLocalizedTransient')) {
    Invoke-PreparationFixture -FailureMode $failure
    Assert-PreparationPassed $failure
    Assert-True ($script:calls.Lookup -eq 4 -and $script:calls.LegacyLookup -eq 0) "$failure did not recover in exactly three live-read attempts."
    Assert-True ($script:waitSeconds.Count -eq 2 -and
        @($script:waitSeconds | Where-Object { $_ -ne 5 }).Count -eq 0) "$failure did not use two five-second retry delays."
}

foreach ($failure in @('ReadPermanent', 'ReadLocalizedPermanent', 'Missing', 'InvalidRecord', 'WrongName', 'MultipleRecords', 'EmptyAlways', 'ReadBusyAlways')) {
    Invoke-PreparationFixture -FailureMode $failure
    Assert-PreparationFailed $failure
    $expectedReads = if ($failure -in @('EmptyAlways', 'ReadBusyAlways')) { 3 } else { 1 }
    Assert-True ($script:calls.Lookup -eq $expectedReads) "$failure was retried incorrectly."
    Assert-True ($script:calls.Start -eq 0 -and $script:calls.Stop -eq 0) "$failure changed power."
}

foreach ($kind in @('Memory', 'Processor')) {
    Invoke-PreparationFixture -State Running -Change $kind -FailureMode "${kind}Transient"
    Assert-PreparationPassed "${kind}Transient"
    Assert-True ($script:calls[$kind] -eq 3) "$kind transient update did not retry exactly three times."
    Assert-True ($script:calls.Stop -eq 1 -and $script:calls.Start -eq 1) "$kind retry repeated the power cycle."

    foreach ($suffix in @('Permanent', 'NoOp', 'BusyAlways')) {
        Invoke-PreparationFixture -State Running -Change $kind -FailureMode "$kind$suffix"
        Assert-PreparationFailed "$kind$suffix"
        $expectedAttempts = if ($suffix -eq 'BusyAlways') { 3 } else { 1 }
        Assert-True ($script:calls[$kind] -eq $expectedAttempts) "$kind$suffix used the wrong update retry count."
        Assert-True ($script:fixtureVm.State -eq 'Running' -and $script:calls.Start -eq 1) "$kind$suffix did not restore original power."
        if ($suffix -eq 'NoOp') {
            Assert-True (@($script:messages | Where-Object { $_.Message -match 'verification mismatch' }).Count -eq 2) `
                "$kind readback did not use exactly three observations."
        }
    }
}

Invoke-PreparationFixture -State Running -Change Both -FailureMode ProcessorPermanent
Assert-PreparationFailed 'Partially applied hardware'
Assert-True ($script:fixtureVm.MemoryStartup -eq 4GB -and $script:fixtureVm.ProcessorCount -eq 2 -and
    $script:fixtureVm.State -eq 'Running') 'Partial update failure lost the actual hardware/power state.'

$script:fixtureCount++
$script:failureMode = ''
$script:messages.Clear()
$retried = @(Initialize-OsdClientHost -VmName TEST-OSD1 -MemoryBytes 4GB -ProcessorCount 4)
Assert-True ($retried.Count -eq 1 -and $retried[0] -is [bool] -and $retried[0]) 'Partial update could not be retried safely.'
Assert-True ($script:calls.Memory -eq 1 -and $script:calls.Processor -eq 2 -and
    $script:fixtureVm.State -eq 'Running') 'Retry reapplied completed RAM changes or lost original power.'
$script:fixtureCount++
$idempotent = @(Initialize-OsdClientHost -VmName TEST-OSD1 -MemoryBytes 4GB -ProcessorCount 4)
Assert-True ($idempotent.Count -eq 1 -and $idempotent[0] -is [bool] -and $idempotent[0]) 'Already reconciled hardware failed an idempotent retry.'
Assert-True ($script:calls.Memory -eq 1 -and $script:calls.Processor -eq 2 -and
    $script:calls.Stop -eq 2 -and $script:calls.Start -eq 2) 'Idempotent retry performed another mutation or power cycle.'
Assert-NoGuestOrDestructiveOperations 'Idempotent retry'

Invoke-PreparationFixture -State Running -Change Both -FailureMode ProcessorAndRestoreFailure -StrictMode
Assert-PreparationFailed 'Combined update and power recovery failure'
Assert-True (@($script:messages | Where-Object {
            $_.Message -match 'power recovery failed:.+Start-VM2.+updateError=Synthetic processor access denied'
        }).Count -eq 1) 'Power recovery masked the original hardware failure.'
Assert-True (@($script:messages | Where-Object {
            $_.Message -match "failed at 'update processors'.+Synthetic processor access denied"
        }).Count -eq 1) 'Combined failure lost the original operation.'

foreach ($failure in @('ProcessorNonTerminating', 'DynamicMemoryNoOp')) {
    $change = if ($failure -eq 'DynamicMemoryNoOp') { 'Memory' } else { 'Processor' }
    Invoke-PreparationFixture -State Running -Change $change -FailureMode $failure
    Assert-PreparationFailed $failure
    Assert-True ($script:fixtureVm.State -eq 'Running') "$failure did not restore original power."
}

Invoke-PreparationFixture -State Off -Change Memory -FailureMode DelayedReadback
Assert-PreparationPassed 'Delayed hardware readback'
Assert-True (@($script:messages | Where-Object { $_.Message -match 'verification mismatch' }).Count -eq 2) `
    'Delayed hardware readback was not observed exactly three times.'

foreach ($failure in @('StopFalse', 'StopThrows', 'StopNoOp', 'StopFalseAfterOff', 'StopWrongType', 'UnexpectedSaved', 'Disappeared', 'Replaced')) {
    Invoke-PreparationFixture -State Running -Change Both -FailureMode $failure
    Assert-PreparationFailed $failure
    Assert-True ($script:calls.Memory -eq 0 -and $script:calls.Processor -eq 0) "$failure allowed hardware changes without confirming Off state."
    if ($failure -in @('Disappeared', 'Replaced', 'UnexpectedSaved')) {
        Assert-True ($script:calls.Start -eq 0) "$failure started an absent, replaced, or saved VM."
    }
    elseif ($failure -in @('StopFalseAfterOff', 'StopWrongType')) {
        Assert-True ($script:calls.Start -eq 1 -and $script:fixtureVm.State -eq 'Running') "$failure failed to recover a partial stop."
    }
}

foreach ($failure in @('StartFalse', 'StartNoOp', 'StartWrongType')) {
    Invoke-PreparationFixture -State Running -Change Processor -FailureMode $failure -StrictMode
    Assert-PreparationFailed $failure
    Assert-True ($script:calls.Start -eq 1) "$failure added an extra power-recovery loop."
    Assert-True (@($script:messages | Where-Object { $_.Message -match 'power recovery failed' }).Count -eq 1) `
        "$failure omitted the power-recovery diagnostic."
}

foreach ($failure in @('StopTransition', 'StartTransition')) {
    Invoke-PreparationFixture -State Running -Change Both -FailureMode $failure
    Assert-PreparationPassed $failure
    Assert-True ($script:calls.Stop -eq 1 -and $script:calls.Start -eq 1) "$failure reset a VM instead of observing its transition."
}

Invoke-PreparationFixture -State Starting -FailureMode InitialTransition
Assert-PreparationPassed 'Initial power transition'
Assert-True ($script:fixtureVm.State -eq 'Off' -and $script:calls.Start -eq 0) 'Initial transition booted a powered-off target.'
Invoke-PreparationFixture -State Starting -FailureMode InitialReplaced
Assert-PreparationFailed 'Replacement during initial transition'
Assert-True ($script:calls.Lookup -eq 2 -and $script:calls.Stop -eq 0 -and
    $script:calls.Start -eq 0) 'Initial transition followed a replacement VM.'
Invoke-PreparationFixture -State Starting
Assert-PreparationFailed 'Stuck power transition'
Assert-True ($script:calls.Lookup -eq 6 -and $script:waitSeconds.Count -eq 5 -and
    $script:calls.Stop -eq 0 -and $script:calls.Start -eq 0) 'Stuck transition was unbounded or reset the VM.'
Invoke-PreparationFixture -State OffCritical
Assert-PreparationFailed 'Critical Hyper-V state'
Assert-True ($script:calls.Lookup -eq 1 -and $script:calls.Start -eq 0) 'Critical state entered a boot loop.'

foreach ($state in @('Saved', 'Paused')) {
    Invoke-PreparationFixture -State $state
    Assert-PreparationPassed $state
    Assert-True ($script:fixtureVm.State -eq $state -and $script:calls.Start -eq 0) "$state was not preserved."
    foreach ($change in @('Memory', 'Processor', 'DynamicMemory')) {
        Invoke-PreparationFixture -State $state -Change $change
        Assert-PreparationFailed "$state/$change"
        Assert-True ($script:calls.Stop -eq 0 -and $script:calls.Start -eq 0 -and
            $script:calls.Memory -eq 0 -and $script:calls.Processor -eq 0) "$state/$change discarded state or altered hardware."
    }
}

Invoke-PreparationFixture -State Running -Change DynamicMemory -DynamicMemory
Assert-PreparationPassed 'Live deployment pin'
Assert-True ($script:calls.Stop -eq 0 -and $script:calls.Memory -eq 0 -and
    $script:fixtureVm.MemoryMinimum -eq 1GB) 'Raising the deployment pin interrupted a running PXE target.'
Invoke-PreparationFixture -State Running -Change DynamicMemory -DynamicMemory -MinimumBytes 2GB
Assert-PreparationPassed 'Deferring lower live deployment pin'
Assert-True ($script:calls.Stop -eq 0 -and $script:calls.Memory -eq 0 -and
    $script:fixtureVm.MemoryMinimum -eq 2GB) 'Live pin adjustment entered a potentially blocking memory call.'

foreach ($request in @(
        @{ MemoryBytes = 0 },
        @{ Processors = 0 },
        @{ DynamicMinRam = -1 },
        @{ DynamicMinRam = 4GB }
    )) {
    Invoke-PreparationFixture @request
    Assert-PreparationFailed 'Invalid hardware request'
    Assert-True ($script:calls.Lookup -eq 0 -and $script:calls.Start -eq 0 -and
        $script:calls.Stop -eq 0) 'Invalid request reached Hyper-V operations.'
}

foreach ($failure in @('', 'ProcessorNoOp')) {
    Invoke-PreparationFixture -Direct -Change Processor -FailureMode $failure
    Assert-True ($script:rawResult.Count -eq 1 -and $script:rawResult[0] -is [bool]) 'Host initializer leaked output instead of one Boolean.'
    Assert-True ($script:rawResult[0] -eq ($failure -eq '')) 'Host initializer returned the wrong success value.'
}

foreach ($generation in @(1, 2)) {
    Invoke-PreparationFixture -Mode New -Generation $generation
    Assert-True ($script:calls.Note -eq 1 -and $script:calls.Lookup -eq 0 -and
        $script:calls.Memory -eq 0 -and $script:calls.Processor -eq 0) "Gen$generation fresh OSD completion entered existing-host preparation."
    Assert-True ($script:calls.Readiness -eq 0 -and $script:calls.Heartbeat -eq 0 -and
        $script:calls.Guest -eq 0 -and $script:calls.Start -eq 0) "Gen$generation fresh OSD completion required Windows readiness."
    Assert-True (@($script:messages | Where-Object {
                $_.Success -and $_.Message -match 'VM Creation completed successfully'
            }).Count -eq 1) "Gen$generation fresh OSD completion did not retain its success note/receipt."
}

foreach ($state in @('Off', 'Running')) {
    foreach ($change in @('None', 'Processor')) {
        Invoke-PreparationFixture -Role WorkgroupMember -State $state -Change $change
        Assert-True ($script:calls.Readiness -eq 1) "Windows/$state/$change no longer requires guest readiness."
        Assert-True (@($script:messages | Where-Object Failure).Count -eq 1) "Windows/$state/$change hid a guest readiness failure."
        $expectedHeartbeat = [int]($state -eq 'Running' -and $change -eq 'Processor')
        Assert-True ($script:calls.Heartbeat -eq $expectedHeartbeat) "Windows/$state/$change changed restart heartbeat checks."
    }
}

Write-Host "PASS: $script:fixtureCount OSD/Windows fixtures cover live validation, bounded retries, state preservation, recovery diagnostics, and zero PXE guest probes." -ForegroundColor Green
