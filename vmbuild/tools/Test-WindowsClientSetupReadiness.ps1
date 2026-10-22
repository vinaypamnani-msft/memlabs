#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$helperPath = Join-Path $root 'DSC\phases\WindowsSetupReadiness.ps1'
. $helperPath

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$nativeResult = @(Get-MemLabsWindowsOobeCompletion)
Assert-True ($nativeResult.Count -eq 1 -and $nativeResult[0] -is [bool]) 'Native Windows Welcome API did not return one Boolean.'

function Reset-SetupFixture {
    $script:ProductType = 1
    $script:ImageState = 'IMAGE_STATE_COMPLETE'
    $script:SetupValues = [pscustomobject]@{ SetupType = 0; SystemSetupInProgress = 0; OOBEInProgress = 0 }
    $script:ActiveName = 'CST-W11CLIENT1'; $script:PendingName = 'CST-W11CLIENT1'
    $script:NativeValue = $true; $script:NativeThrows = $false; $script:CimThrows = $false
    $script:RegistryThrows = $false; $script:RegistryReads = 0; $script:NativeReads = 0
    $script:UserOobeValue = 'InProgress'; $script:UserOobeThrows = $false; $script:UserOobeReads = 0
    $script:CompletionValues = [pscustomobject]@{ 'setup.exe' = 3 }
    $script:OobeProcesses = @(); $script:ProcessThrows = $false; $script:ProcessReads = 0
    $script:AutoMarkerExists = $false; $script:AutoMarkerText = '1'; $script:AutoMarkerLength = 1
    $script:AutoMarkerAttributes = [IO.FileAttributes]::Archive; $script:AutoRegistryThrows = $false
    $script:AutoLogonValues = [pscustomobject]@{ AutoAdminLogon = '1'; AutoLogonCount = 1 }
}
function Test-Path {
    [CmdletBinding()]
    param($LiteralPath, $Path, $PathType)
    if ($LiteralPath -eq "$env:SystemDrive\staging\MemLabs-BoundedFirstBootAutoLogon.txt") { return $script:AutoMarkerExists }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-Item {
    [CmdletBinding()]
    param($LiteralPath, [switch]$Force)
    if ($LiteralPath -eq "$env:SystemDrive\staging\MemLabs-BoundedFirstBootAutoLogon.txt") {
        return [pscustomobject]@{ Length = $script:AutoMarkerLength; Attributes = $script:AutoMarkerAttributes }
    }
    Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function Get-Content {
    [CmdletBinding()]
    param($LiteralPath, $Path, [switch]$Raw)
    if ($LiteralPath -eq "$env:SystemDrive\staging\MemLabs-BoundedFirstBootAutoLogon.txt") { return $script:AutoMarkerText }
    Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
}
function Get-CimInstance {
    param($ClassName, $OperationTimeoutSec, $Filter, $ErrorAction)
    Assert-True ($OperationTimeoutSec -eq 5 -and $ErrorAction -eq 'Stop') 'Setup classification lost its bounded fail-closed local query.'
    if ($ClassName -eq 'Win32_OperatingSystem') {
        if ($script:CimThrows) { throw 'Synthetic CIM failure' }
        return [pscustomobject]@{ ProductType = $script:ProductType }
    }
    Assert-True ($ClassName -eq 'Win32_Process' -and $Filter -match 'UserOOBEBroker' -and
        $Filter -notmatch 'LogonUI') 'Setup process inspection queried a different class or treated the sign-in screen as active OOBE.'
    $script:ProcessReads++
    if ($script:ProcessThrows) { throw 'Synthetic OOBE process query failure' }
    return $script:OobeProcesses
}
function Get-ItemProperty {
    param($LiteralPath, $Name, $ErrorAction)
    $script:RegistryReads++
    if ($script:RegistryThrows) { throw 'Synthetic setup registry failure' }
    switch ($LiteralPath) {
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' { return [pscustomobject]@{ ImageState = $script:ImageState } }
        'HKLM:\SYSTEM\Setup' { return $script:SetupValues }
        'HKLM:\SYSTEM\Setup\Status\ChildCompletion' { return $script:CompletionValues }
        'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' { return [pscustomobject]@{ ComputerName = $script:ActiveName } }
        'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' { return [pscustomobject]@{ ComputerName = $script:PendingName } }
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' {
            Assert-True (($Name -join ',') -eq 'AutoAdminLogon,AutoLogonCount') 'Readiness inspected credential values instead of only autologon flags.'
            if ($script:AutoRegistryThrows) { throw 'Synthetic autologon registry failure' }
            return $script:AutoLogonValues
        }
        default { throw "Unexpected registry path: $LiteralPath" }
    }
}
function Get-MemLabsWindowsOobeCompletion {
    $script:NativeReads++
    if ($script:NativeThrows) { throw 'Synthetic native OOBE API failure' }
    return $script:NativeValue
}
function Get-MemLabsWindowsOobeLifecycleState {
    $script:UserOobeReads++
    if ($script:UserOobeThrows) { throw 'Synthetic user OOBE API failure' }
    return $script:UserOobeValue
}

Reset-SetupFixture
$readyState = Get-MemLabsWindowsClientSetupState
Assert-True ($readyState.Ready -and $readyState.Required -and $readyState.Version -eq 1) 'A fully completed client was rejected.'
Assert-True (-not $readyState.FirstBootAutoLogonRequired -and $null -eq $readyState.FirstBootAutoLogonDisabled) `
    'An unmarked legacy image was made dependent on first-boot autologon cleanup.'
Reset-SetupFixture
$script:AutoMarkerExists = $true
$cleanupPendingState = Get-MemLabsWindowsClientSetupState
Assert-True (-not $cleanupPendingState.Ready -and $cleanupPendingState.Reason -eq 'FirstBootAutoLogonCleanupPending' -and
    $cleanupPendingState.FirstBootAutoLogonRequired -and -not $cleanupPendingState.FirstBootAutoLogonDisabled) `
    'Native OOBE completion let deployment race the required first-logon autologon cleanup.'
$script:AutoLogonValues = [pscustomobject]@{ AutoAdminLogon = '0'; AutoLogonCount = 0 }
$boundedReadyState = Get-MemLabsWindowsClientSetupState
Assert-True ($boundedReadyState.Ready -and $boundedReadyState.FirstBootAutoLogonDisabled -and $boundedReadyState.NativeOobeComplete) `
    'A fully completed client with verified autologon cleanup was rejected.'
$script:AutoRegistryThrows = $true
$state = Get-MemLabsWindowsClientSetupState
Assert-True (-not $state.Ready -and $state.Reason -eq 'ProbeFailed' -and $state.Diagnostics.Count -gt 0) `
    'Failed cleanup verification retained an earlier Ready=true result.'
foreach ($invalidMarker in @('bad', 'large', 'reparse')) {
    Reset-SetupFixture
    $script:AutoMarkerExists = $true
    switch ($invalidMarker) {
        bad { $script:AutoMarkerText = 'bad' }
        large { $script:AutoMarkerLength = 17 }
        reparse { $script:AutoMarkerAttributes = [IO.FileAttributes]::ReparsePoint }
    }
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Reason -eq 'ProbeFailed') 'An invalid bounded-sign-in marker became ready.'
}
foreach ($serverType in @(2, 3)) {
    Reset-SetupFixture
    $script:ProductType = $serverType
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True ($state.Ready -and -not $state.Required -and $script:RegistryReads -eq 0 -and $script:NativeReads -eq 0 -and
        $script:UserOobeReads -eq 0 -and $script:ProcessReads -eq 0) `
        'Server setup behavior was changed by the client-only gate.'
}
foreach ($badProduct in @($null, 0, '1')) {
    Reset-SetupFixture
    $script:ProductType = $badProduct
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Diagnostics.Count -gt 0) 'Unknown or malformed product type skipped the client gate.'
}
foreach ($flag in @('SetupType', 'SystemSetupInProgress', 'OOBEInProgress')) {
    Reset-SetupFixture
    $script:SetupValues.$flag = 1
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Reason -eq 'MachineSetupIncomplete') "Active $flag became ready."
    $script:SetupValues.$flag = '0'
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Diagnostics.Count -gt 0) "String-valued $flag became ready."
    $script:SetupValues.PSObject.Properties.Remove($flag)
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Diagnostics.Count -gt 0) "Missing $flag became ready."
}
Reset-SetupFixture
$script:NativeValue = $false
$pendingState = Get-MemLabsWindowsClientSetupState
Assert-True (-not $pendingState.Ready -and $pendingState.Reason -eq 'WindowsWelcomeIncomplete' -and
    $pendingState.ImageState -eq 'IMAGE_STATE_COMPLETE') 'Machine ImageState completion bypassed unfinished Windows Welcome.'
Reset-SetupFixture
$script:NativeValue = $false; $script:UserOobeValue = 'NotStarted'
$firstLogonState = Get-MemLabsWindowsClientSetupState
Assert-True ($firstLogonState.Ready -and $firstLogonState.Required -and -not $firstLogonState.NativeOobeComplete -and
    $firstLogonState.Reason -eq 'MachineCompleteAwaitingFirstLogon' -and $firstLogonState.WinRtOobeState -eq 'NotStarted' -and
    $firstLogonState.SetupExeCompletion -eq 3 -and $firstLogonState.OobeProcessCount -eq 0 -and
    $firstLogonState.OobeProcesses.Count -eq 0 -and $firstLogonState.OobeBlockingProcessCount -eq 0 -and
    $script:UserOobeReads -eq 1 -and $script:ProcessReads -eq 1) `
    'The completed unattended machine at the sign-in screen was rejected or mislabeled as full native completion.'
Reset-SetupFixture
$script:NativeValue = $false; $script:UserOobeValue = 'NotStarted'
$script:OobeProcesses = @([pscustomobject]@{ Name = 'CloudExperienceHostBroker.exe' })
$brokerState = Get-MemLabsWindowsClientSetupState
Assert-True ($brokerState.Ready -and -not $brokerState.NativeOobeComplete -and
    $brokerState.Reason -eq 'MachineCompleteAwaitingFirstLogon' -and $brokerState.OobeProcessCount -eq 1 -and
    $brokerState.OobeBlockingProcessCount -eq 0 -and $brokerState.OobeProcesses[0] -eq 'CloudExperienceHostBroker.exe' -and
    $brokerState.Detail.Contains('CloudExperienceHostBroker.exe')) `
    'A resident broker was mistaken for active OOBE or removed from diagnostic evidence.'
foreach ($badUserState in @($null, '', 'Unknown', 'Completed', 0, @('NotStarted', 'InProgress'))) {
    Reset-SetupFixture
    $script:NativeValue = $false; $script:UserOobeValue = $badUserState
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Reason -eq 'ProbeFailed' -and $state.Diagnostics.Count -gt 0) `
        'Unknown/malformed/conflicting user OOBE state became deployment-ready.'
}
foreach ($badCompletion in @($null, '3', -1, @($true, $true))) {
    Reset-SetupFixture
    $script:NativeValue = $false; $script:UserOobeValue = 'NotStarted'
    $script:CompletionValues.'setup.exe' = $badCompletion
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Diagnostics.Count -gt 0) 'Malformed setup.exe completion became deployment-ready.'
}
Reset-SetupFixture
$script:NativeValue = $false; $script:UserOobeValue = 'NotStarted'
$script:CompletionValues.PSObject.Properties.Remove('setup.exe')
$state = Get-MemLabsWindowsClientSetupState
Assert-True (-not $state.Ready -and $state.Diagnostics.Count -gt 0) 'Missing setup.exe completion became deployment-ready.'
foreach ($completion in @(0, 1, 2)) {
    Reset-SetupFixture
    $script:NativeValue = $false; $script:UserOobeValue = 'NotStarted'
    $script:CompletionValues.'setup.exe' = $completion
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Reason -eq 'MachineSetupIncomplete' -and $script:ProcessReads -eq 0) `
        'Incomplete setup.exe child state reached deployment readiness or process inspection.'
}
foreach ($processName in @('setup.exe', 'setuphost.exe', 'msoobe.exe', 'oobeldr.exe', 'oobelauncher.exe',
        'UserOOBEBroker.exe', 'CloudExperienceHost.exe', 'WWAHost.exe', 'FirstLogonAnim.exe', 'UnexpectedBroker.exe')) {
    foreach ($withBroker in @($false, $true)) {
        Reset-SetupFixture
        $script:NativeValue = $false; $script:UserOobeValue = 'NotStarted'
        $script:OobeProcesses = @([pscustomobject]@{ Name = $processName })
        if ($withBroker) { $script:OobeProcesses += [pscustomobject]@{ Name = 'CloudExperienceHostBroker.exe' } }
        $state = Get-MemLabsWindowsClientSetupState
        Assert-True (-not $state.Ready -and $state.OobeBlockingProcessCount -eq 1 -and
            $state.OobeProcessCount -eq $script:OobeProcesses.Count -and $state.Detail.Contains($processName)) `
            "Active $processName was accepted or hidden by a support broker."
    }
}
foreach ($failure in @('UserApi', 'ProcessQuery', 'UnreadableProcess', 'MachineFlag', 'ImageState')) {
    Reset-SetupFixture
    $script:NativeValue = $false; $script:UserOobeValue = 'NotStarted'
    if ($failure -eq 'UserApi') { $script:UserOobeThrows = $true }
    if ($failure -eq 'ProcessQuery') { $script:ProcessThrows = $true }
    if ($failure -eq 'UnreadableProcess') { $script:OobeProcesses = @([pscustomobject]@{ Name = '' }) }
    if ($failure -eq 'MachineFlag') { $script:SetupValues.OOBEInProgress = 1 }
    if ($failure -eq 'ImageState') { $script:ImageState = 'IMAGE_STATE_UNDEPLOYABLE' }
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and -not [string]::IsNullOrWhiteSpace($state.Detail)) "$failure bypassed the unattended-machine guards."
    if ($failure -in @('MachineFlag', 'ImageState')) {
        Assert-True ($script:UserOobeReads -eq 0 -and $script:ProcessReads -eq 0) 'Incomplete machine setup queried a first-logon exception.'
    }
    else { Assert-True ($state.Diagnostics.Count -gt 0) "$failure lost its explicit error." }
}
foreach ($badNative in @($null, 'True', @($true, $true))) {
    Reset-SetupFixture
    $script:NativeValue = $badNative
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Diagnostics.Count -gt 0) 'Malformed native OOBE result became success.'
}
foreach ($failure in @('Cim', 'Registry', 'Native', 'Name', 'ImageState')) {
    Reset-SetupFixture
    if ($failure -eq 'Cim') { $script:CimThrows = $true }
    if ($failure -eq 'Registry') { $script:RegistryThrows = $true }
    if ($failure -eq 'Native') { $script:NativeThrows = $true }
    if ($failure -eq 'Name') { $script:ActiveName = '' }
    if ($failure -eq 'ImageState') { $script:ImageState = $null }
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True (-not $state.Ready -and $state.Diagnostics.Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($state.Detail)) "$failure failure lost its explicit diagnostic."
}

$tokens = $null; $parseErrors = $null
$commonAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Common.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Common.ps1 parse errors: $($parseErrors -join '; ')" }
foreach ($name in @('Get-MemLabsWindowsClientSetupStateBlock', 'Wait-MemLabsWindowsClientSetup')) {
    $definition = @($commonAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true))[0]
    $text = $definition.Extent.Text
    if ($name -eq 'Get-MemLabsWindowsClientSetupStateBlock') {
        $text = $text.Replace('$PSScriptRoot', "'$($root.Replace("'", "''"))'")
    }
    . ([scriptblock]::Create($text))
}
$probeText = (Get-MemLabsWindowsClientSetupStateBlock).ToString()
Assert-True ($probeText.Contains('function Get-MemLabsWindowsClientSetupState') -and
    $probeText.TrimEnd().EndsWith('Get-MemLabsWindowsClientSetupState')) 'The host did not package the shared guest probe.'

function Reset-HostFixture {
    param($Response, [switch]$AdvanceClock)
    $script:Replies = [Collections.Generic.Queue[object]]::new()
    $script:LastReply = $Response
    $script:RpcCalls = 0
    $script:RpcBudgets = [Collections.Generic.List[int]]::new()
    $script:Messages = [Collections.Generic.List[string]]::new()
    $script:SleepAdvancesClock = [bool]$AdvanceClock
    $script:ProgressCalls = 0
    $script:ReplyDelayMilliseconds = 0
}
function Invoke-VmCommand {
    param($VmName, $VmDomainName, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries, [switch]$SuppressLog, $ScriptBlock)
    Assert-True ($VmName -eq 'TEST-W11' -and $AsJob -and $SuppressLog -and $SessionMaxRetries -eq 1 -and
        $TimeoutSeconds -ge 1 -and $TimeoutSeconds -le 30) 'Client gate lost exact VM targeting or its per-probe deadline.'
    Assert-True ($ScriptBlock.ToString().Contains('Get-MemLabsWindowsClientSetupState')) 'Client gate used a different guest probe.'
    $script:RpcCalls++
    $script:RpcBudgets.Add($TimeoutSeconds)
    if ($script:ReplyDelayMilliseconds) { [Threading.Thread]::Sleep($script:ReplyDelayMilliseconds) }
    if ($script:Replies.Count) { $script:LastReply = $script:Replies.Dequeue() }
    if ($null -eq $script:LastReply) { return }
    return $script:LastReply
}
function Write-Log {
    param($Message, [switch]$Warning)
    $script:Messages.Add($Message)
}
function Write-ProgressElapsed { $script:ProgressCalls++ }
function Start-Sleep {
    param($Seconds)
    Assert-True ($Seconds -ge 1 -and $Seconds -le 5) 'Client gate exceeded its bounded polling delay.'
    if ($script:SleepAdvancesClock) { [Threading.Thread]::Sleep(1100) }
}
function New-Reply {
    param($State)
    [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $State; ErrorDetails = @() }
}
Reset-HostFixture -Response (New-Reply $readyState)
Assert-True (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 5) 'Completed host client gate failed.'
Assert-True ($script:RpcCalls -eq 1 -and $script:ProgressCalls -eq 1) 'A completed client did not pass immediately.'
$legacyReadyState = $readyState.PSObject.Copy()
$legacyReadyState.PSObject.Properties.Remove('FirstBootAutoLogonRequired')
$legacyReadyState.PSObject.Properties.Remove('FirstBootAutoLogonDisabled')
Reset-HostFixture -Response (New-Reply $legacyReadyState)
Assert-True (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 5) `
    'Legacy readiness replies without the new optional fields were rejected.'
Reset-HostFixture -Response (New-Reply $boundedReadyState)
$script:Replies.Enqueue((New-Reply $cleanupPendingState))
$script:Replies.Enqueue((New-Reply $boundedReadyState))
Assert-True (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 5) 'The host did not wait for bounded first-sign-in cleanup.'
Assert-True ($script:RpcCalls -eq 2 -and ($script:Messages -join ' ') -match 'FirstBootAutoLogonCleanupPending') `
    'The host advanced past required autologon cleanup without recording its pending state.'
Reset-HostFixture -Response (New-Reply $firstLogonState)
Assert-True (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 5) 'The host rejected a fully verified pre-first-logon machine.'
Assert-True ($script:RpcCalls -eq 1 -and ($script:Messages -join ' ') -match 'MachineCompleteAwaitingFirstLogon') `
    'Unattended machine readiness required a timer or lost its distinct diagnostic.'
Reset-HostFixture -Response (New-Reply $brokerState)
Assert-True (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 5) 'The host rejected machine-ready evidence with only the recorded support broker.'
Reset-HostFixture -Response (New-Reply $readyState)
$script:Replies.Enqueue((New-Reply $pendingState))
$script:Replies.Enqueue((New-Reply $readyState))
Assert-True (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 5) 'An incomplete-to-complete transition was not retried.'
Assert-True ($script:RpcCalls -eq 2 -and ($script:Messages -join ' ') -match 'WindowsWelcomeIncomplete') 'Pending user OOBE was not logged before retry.'
foreach ($lateState in @($readyState, $firstLogonState, $brokerState)) {
    Reset-HostFixture -Response (New-Reply $lateState)
    $script:ReplyDelayMilliseconds = 1100
    Assert-True (-not (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 1)) 'A late native/first-logon ready response passed after the readiness deadline.'
    Assert-True (($script:Messages -join ' ') -match 'late reply') 'The readiness deadline rejected a late response without explanation.'
}

$invalidReplies = [ordered]@{
    Pending = 'WindowsWelcomeIncomplete'
    StringReady = 'Invalid setup fields=\[Ready\]'
    MissingFlag = 'Missing setup fields=\[OOBEInProgress\]'
    StringFlag = 'Invalid setup fields=\[OOBEInProgress\]'
    InconsistentNative = 'Invalid setup fields=\[NativeOobeComplete\]'
    InvalidServer = 'Invalid setup fields=\[Reason, ProductType\]'
    MissingVersion = 'Missing setup fields=\[Version\]'
    StringVersion = 'Invalid setup fields=\[Version\]'
    MissingPendingName = 'Missing setup fields=\[PendingName\]'
    BlankPendingName = 'Invalid setup fields=\[PendingName\]'
    ArrayImageState = 'Invalid setup fields=\[ImageState\]'
    InconsistentReason = 'Invalid setup fields=\[Reason\]'
    BlankDetail = 'Invalid setup fields=\[Detail\]'
    Multiple = 'stateCount=2 stateTypes=\[System.Management.Automation.PSCustomObject, System.Management.Automation.PSCustomObject\]'
    Transport = 'Synthetic transport failure'
    NoResponse = 'envelopeCount=0 envelopeTypes=\[\]'
    MissingEnvelopeFlag = "Missing envelope field 'ScriptBlockFailed'"
    StringEnvelopeFlag = "Invalid envelope field 'ScriptBlockFailed'"
    MissingEnvelopeOutput = "Missing envelope field 'ScriptBlockOutput'"
    NullState = 'stateCount=1 stateTypes=\[<null>\]'
    ScalarEnvelope = 'envelopeCount=1 envelopeTypes=\[System.Boolean\]'
    MultipleEnvelopes = 'envelopeCount=2 envelopeTypes=\[System.String, System.Management.Automation.PSCustomObject\]'
}
foreach ($variant in $invalidReplies.Keys) {
    $badState = $readyState | Select-Object *
    if ($variant -eq 'Pending') { $badState = $pendingState }
    if ($variant -eq 'StringReady') { $badState.Ready = 'True' }
    if ($variant -eq 'MissingFlag') { $badState.PSObject.Properties.Remove('OOBEInProgress') }
    if ($variant -eq 'StringFlag') { $badState.OOBEInProgress = '0' }
    if ($variant -eq 'InconsistentNative') { $badState.NativeOobeComplete = $false }
    if ($variant -eq 'InvalidServer') { $badState.Required = $false }
    if ($variant -eq 'MissingVersion') { $badState.PSObject.Properties.Remove('Version') }
    if ($variant -eq 'StringVersion') { $badState.Version = '1' }
    if ($variant -eq 'MissingPendingName') { $badState.PSObject.Properties.Remove('PendingName') }
    if ($variant -eq 'BlankPendingName') { $badState.PendingName = '' }
    if ($variant -eq 'ArrayImageState') { $badState.ImageState = @('IMAGE_STATE_COMPLETE', 'INVALID') }
    if ($variant -eq 'InconsistentReason') { $badState.Reason = 'ProbeFailed' }
    if ($variant -eq 'BlankDetail') { $badState.Detail = '' }
    $reply = New-Reply $badState
    if ($variant -eq 'Multiple') { $reply.ScriptBlockOutput = @($readyState, $readyState) }
    if ($variant -eq 'Transport') { $reply.ScriptBlockFailed = $true; $reply.ErrorDetails = @('Synthetic transport failure') }
    if ($variant -eq 'NoResponse') { $reply = $null }
    if ($variant -eq 'MissingEnvelopeFlag') { $reply.PSObject.Properties.Remove('ScriptBlockFailed') }
    if ($variant -eq 'StringEnvelopeFlag') { $reply.ScriptBlockFailed = 'False' }
    if ($variant -eq 'MissingEnvelopeOutput') { $reply.PSObject.Properties.Remove('ScriptBlockOutput') }
    if ($variant -eq 'NullState') { $reply.ScriptBlockOutput = $null }
    if ($variant -eq 'ScalarEnvelope') { $reply = $false }
    if ($variant -eq 'MultipleEnvelopes') { $reply = @('Synthetic leaked job output', $reply) }
    Reset-HostFixture -Response $reply -AdvanceClock
    Set-StrictMode -Version Latest
    try {
        $passed = Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 1
        Assert-True (-not $passed -and $script:RpcCalls -eq 1 -and $script:RpcBudgets[0] -eq 1 -and
            ($script:Messages -join ' ') -match 'did not become ready') "$variant became ready or escaped its deadline/diagnostics."
        $diagnostic = $script:Messages -join ' '
        Assert-True ($diagnostic -match $invalidReplies[$variant]) "$variant lost its specific diagnostic: $diagnostic"
        if ($variant -eq 'Pending') {
            Assert-True ($diagnostic -notmatch 'unreadable or malformed') 'A valid pending setup state was mislabeled as a protocol error.'
        }
        else {
            Assert-True ($diagnostic -match 'envelopeCount=\d+ envelopeTypes=\[' -and
                $diagnostic -match 'stateCount=\d+ stateTypes=\[') "$variant omitted response counts or types."
        }
        Assert-True ($diagnostic -notmatch 'Synthetic leaked job output') 'Readiness diagnostics dumped an unexpected response payload.'
    }
    finally { Set-StrictMode -Off }
}

$invalidFirstLogon = [ordered]@{
    MissingUserState = 'Missing setup fields=\[WinRtOobeState\]'
    MissingCompletion = 'Missing setup fields=\[SetupExeCompletion\]'
    MissingProcessCount = 'Missing setup fields=\[OobeProcessCount\]'
    MissingBlockingCount = 'Missing setup fields=\[OobeBlockingProcessCount\]'
    MissingProcesses = 'Missing setup fields=\[OobeProcesses\]'
    MissingDiagnostics = 'Missing setup fields=\[Diagnostics\]'
    InProgress = 'Invalid setup fields=\[WinRtOobeState\]'
    StringCompletion = 'Invalid setup fields=\[SetupExeCompletion\]'
    ActiveProcess = 'Invalid setup fields=\[OobeBlockingProcessCount, OobeProcesses\]'
    ForgedBlockingCount = 'Invalid setup fields=\[OobeProcesses\]'
    UnknownSupport = 'Invalid setup fields=\[OobeProcesses\]'
    MismatchedCount = 'Invalid setup fields=\[OobeProcesses\]'
    StringBlockingCount = 'Invalid setup fields=\[OobeBlockingProcessCount\]'
    NullProcesses = 'Invalid setup fields=\[OobeProcesses\]'
    ReportedError = 'Invalid setup fields=\[Diagnostics\]'
    InconsistentNative = 'Invalid setup fields=\[NativeOobeComplete\]'
}
foreach ($variant in $invalidFirstLogon.Keys) {
    $badState = $firstLogonState | Select-Object *
    if ($variant -eq 'MissingUserState') { $badState.PSObject.Properties.Remove('WinRtOobeState') }
    if ($variant -eq 'MissingCompletion') { $badState.PSObject.Properties.Remove('SetupExeCompletion') }
    if ($variant -eq 'MissingProcessCount') { $badState.PSObject.Properties.Remove('OobeProcessCount') }
    if ($variant -eq 'MissingBlockingCount') { $badState.PSObject.Properties.Remove('OobeBlockingProcessCount') }
    if ($variant -eq 'MissingProcesses') { $badState.PSObject.Properties.Remove('OobeProcesses') }
    if ($variant -eq 'MissingDiagnostics') { $badState.PSObject.Properties.Remove('Diagnostics') }
    if ($variant -eq 'InProgress') { $badState.WinRtOobeState = 'InProgress' }
    if ($variant -eq 'StringCompletion') { $badState.SetupExeCompletion = '3' }
    if ($variant -eq 'ActiveProcess') { $badState.OobeProcessCount = 1; $badState.OobeProcesses = @('msoobe.exe'); $badState.OobeBlockingProcessCount = 1 }
    if ($variant -eq 'ForgedBlockingCount') { $badState.OobeProcessCount = 1; $badState.OobeProcesses = @('msoobe.exe') }
    if ($variant -eq 'UnknownSupport') { $badState.OobeProcessCount = 1; $badState.OobeProcesses = @('UnexpectedBroker.exe') }
    if ($variant -eq 'MismatchedCount') { $badState.OobeProcessCount = 2; $badState.OobeProcesses = @('CloudExperienceHostBroker.exe') }
    if ($variant -eq 'StringBlockingCount') { $badState.OobeBlockingProcessCount = '0' }
    if ($variant -eq 'NullProcesses') { $badState.OobeProcesses = $null }
    if ($variant -eq 'ReportedError') { $badState.Diagnostics = @('Synthetic query failure') }
    if ($variant -eq 'InconsistentNative') { $badState.NativeOobeComplete = $true }
    Reset-HostFixture -Response (New-Reply $badState) -AdvanceClock
    Set-StrictMode -Version Latest
    try {
        Assert-True (-not (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 1) -and
            ($script:Messages -join ' ') -match $invalidFirstLogon[$variant]) "$variant bypassed host first-logon protocol validation."
    }
    finally { Set-StrictMode -Off }
}

& {
    $invokeDefinition = $commonAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-VmCommand'
        }, $true)
    . ([scriptblock]::Create($invokeDefinition.Extent.Text))
    Set-Variable -Name Common -Value @{ LocalAdmin = [pscredential]::Empty }
    $jobIds = [Collections.Generic.List[guid]]::new()
    function Get-VmSession { [pscustomobject]@{ Runspace = $null } }
    function Enter-VmSessionInflight {}
    function Exit-VmSessionInflight {}
    function Write-VmJobLedger {}
    function Remove-VmSessionFromCache {}
    function Invoke-Command {
        [CmdletBinding()]
        param($Session, [scriptblock]$ScriptBlock, [switch]$AsJob)
        Assert-True ($Session -and $AsJob -and $ScriptBlock.ToString().Contains('Get-MemLabsWindowsClientSetupState')) `
            'The real command wrapper did not dispatch the asynchronous setup probe.'
        $job = Start-Job -ScriptBlock {
            param($State, $Fail)
            if ($Fail) { throw 'Synthetic setup probe failure' }
            $State
        } -ArgumentList $guestState, $guestFailure
        $jobIds.Add($job.InstanceId)
        return $job
    }

    try {
        foreach ($scenario in @('Client', 'AwaitingFirstLogon', 'ResidentBroker', 'DomainController', 'MemberServer', 'GuestFailure')) {
            Reset-SetupFixture
            $script:ProductType = switch ($scenario) {
                'DomainController' { 2 }
                'MemberServer' { 3 }
                default { 1 }
            }
            if ($scenario -in @('AwaitingFirstLogon', 'ResidentBroker')) { $script:NativeValue = $false; $script:UserOobeValue = 'NotStarted' }
            if ($scenario -eq 'ResidentBroker') { $script:OobeProcesses = @([pscustomobject]@{ Name = 'CloudExperienceHostBroker.exe' }) }
            $guestState = Get-MemLabsWindowsClientSetupState
            $guestFailure = $scenario -eq 'GuestFailure'
            $script:Messages.Clear()
            $results = @(Invoke-VmCommand -VmName TEST-W11 -VmDomainName WORKGROUP -AsJob -SuppressLog `
                    -TimeoutSeconds 30 -ScriptBlock (Get-MemLabsWindowsClientSetupStateBlock))
            Assert-True ($results.Count -eq 1 -and $results[0].ScriptBlockFailed -is [bool]) `
                "$scenario asynchronous command returned $($results.Count) output objects instead of one result envelope."
            if ($guestFailure) {
                Assert-True ($results[0].ScriptBlockFailed -and -not $results[0].CommandResult -and
                    ($results[0].ErrorDetails -join ' ') -match 'Synthetic setup probe failure') `
                    "The asynchronous command wrapper lost the guest failure or its diagnostic: $($results[0] | ConvertTo-Json -Compress)."
            }
            else {
                Assert-True ($results[0].CommandResult -and -not $results[0].ScriptBlockFailed -and
                    $results[0].ScriptBlockOutput.ProductType -eq $script:ProductType) `
                    "$scenario asynchronous command lost its serialized setup state."
                Assert-True (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 30) `
                    "$scenario was rejected when the readiness gate used the real asynchronous command wrapper."
                Assert-True (($script:Messages -join ' ') -match 'gate passed') "$scenario passed without a readiness diagnostic."
            }
        }
    }
    finally {
        foreach ($jobId in $jobIds) {
            Get-Job -InstanceId $jobId -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
}

$blocksText = Get-Content -LiteralPath (Join-Path $root 'common\Common.ScriptBlocks.ps1') -Raw
Assert-True (-not $blocksText.Contains('retaining the VM for diagnostics') -and
    $blocksText.Contains('use -KeepFailedVMs to prevent failed-build cleanup')) `
    'Fresh setup failure falsely promises retention despite normal Phase 1 cleanup.'
Assert-True ([regex]::Matches($blocksText, 'Wait-MemLabsWindowsClientSetup -VmName \$currentItem\.vmName').Count -eq 3) `
    'Fresh, retained, and post-resume-reboot paths do not all enforce client setup readiness.'
Assert-True ($blocksText -match '(?s)Windows client setup is not ready; resume preparation.+?if \(\$resumePreparation\)') `
    'The retained gate runs after the resume reboot probe instead of before it.'
$phase2 = Get-Content -LiteralPath (Join-Path $root 'DSC\phases\Phase2DomainMember.ps1') -Raw
Assert-True ($phase2 -match "(?s)WriteStatus Rename\s*\{\s*DependsOn = '\[Script\]ClientSetupBeforeRename'" -and
    $phase2 -match "(?s)JoinDomain JoinDomain.+?DependsOn\s*=\s*'\[Script\]ClientSetupBeforeJoin'") `
    'Phase 2 rename/domain join can bypass the shared read-only setup guards.'
$workgroup = Get-Content -LiteralPath (Join-Path $root 'DSC\phases\Phase2WorkgroupMember.ps1') -Raw
Assert-True ($workgroup -match "(?s)WriteStatus Rename\s*\{\s*DependsOn = '\[Script\]ClientSetupBeforeRename'" -and
    $workgroup -match "(?s)Computer NewName.+?DependsOn = '\[WriteStatus\]Rename'" -and
    $workgroup -match "if \(\`$ThisVM\.role -eq 'AADClient'\)") 'Workgroup rename bypasses its guard or changed the AAD OOBE exemption.'

& {
    function Get-MemLabsWindowsClientSetupState { return $script:GuardState }
    $malformedReady = $readyState | Select-Object *
    $malformedReady.Ready = 'True'
    foreach ($phaseText in @($phase2, $workgroup)) {
        $guards = @{}
        foreach ($name in @('clientSetupTest', 'clientSetupSet')) {
            $match = [regex]::Match($phaseText, ('(?ms)^    \$' + $name + ' = (?<body>\{.*?^    \})'))
            Assert-True $match.Success "The actual DSC $name guard could not be extracted."
            $body = $match.Groups['body'].Value
            $body = $body.Substring(1, $body.Length - 2).Replace(
                ". 'C:\staging\DSC\phases\WindowsSetupReadiness.ps1'", '')
            $guards[$name] = [scriptblock]::Create($body)
        }
        foreach ($fixture in @($readyState, $firstLogonState, $brokerState, $pendingState, $malformedReady)) {
            $script:GuardState = $fixture
            $expected = $fixture.Ready -is [bool] -and $fixture.Ready
            Assert-True ((& $guards.clientSetupTest) -eq $expected) 'A DSC test guard changed deployment-readiness classification.'
            $failure = $null
            try { & $guards.clientSetupSet } catch { $failure = $_.Exception.Message }
            Assert-True (($null -eq $failure) -eq $expected) 'A DSC set guard bypassed a blocked state or rejected machine-ready first logon.'
        }
    }
}

$confirmStart = $phase2.IndexOf('Script ConfirmComputerName {')
$confirmEnd = $phase2.IndexOf('WriteStatus WaitDomain', $confirmStart)
$confirm = $phase2.Substring($confirmStart, $confirmEnd - $confirmStart)
$renameBlocks = @{}
foreach ($property in @('TestScript', 'SetScript')) {
    $expression = [regex]::Match($confirm, "(?s)$property\s*=\s*(\[string\]`".*?`")")
    Assert-True $expression.Success "The compiled $property rename guard could not be extracted."
    $evaluate = [scriptblock]::Create("param(`$ThisMachineName)`n$($expression.Groups[1].Value)")
    $renameBlocks[$property] = [scriptblock]::Create((& $evaluate 'CST-W11CLIENT1'))
}
function Rename-Computer {
    param($NewName, [switch]$Force, $ErrorAction)
    $script:RenameCalls++
    Assert-True ($NewName -eq 'CST-W11CLIENT1' -and $Force) 'Rename guard targeted an unexpected name.'
    if ($script:RenameThrows) { throw 'Synthetic rename failure' }
    if (-not $script:IgnoreRename) { $script:PendingName = $NewName }
}
$previousDscStatus = Get-Variable -Name DSCMachineStatus -Scope Global -ErrorAction SilentlyContinue
try {
    foreach ($scenario in @('AlreadyActive', 'AlreadyPending', 'NeedsRename', 'RenameFailure', 'IgnoredRename', 'Unreadable')) {
        Reset-SetupFixture
        $global:DSCMachineStatus = 0
        $script:RenameCalls = 0; $script:RenameThrows = $false; $script:IgnoreRename = $false
        if ($scenario -ne 'AlreadyActive') { $script:ActiveName = 'OLDNAME' }
        if ($scenario -notin @('AlreadyActive', 'AlreadyPending')) { $script:PendingName = 'OLDNAME' }
        if ($scenario -eq 'RenameFailure') { $script:RenameThrows = $true }
        if ($scenario -eq 'IgnoredRename') { $script:IgnoreRename = $true }
        if ($scenario -eq 'Unreadable') { $script:RegistryThrows = $true }
        $failure = $null
        try {
            if ($scenario -eq 'AlreadyActive') { Assert-True (& $renameBlocks.TestScript) 'A correct active registry name was rejected because of the process environment.' }
            & $renameBlocks.SetScript
        }
        catch { $failure = $_.Exception.Message }
        if ($scenario -in @('RenameFailure', 'IgnoredRename', 'Unreadable')) {
            Assert-True ([bool]$failure -and $global:DSCMachineStatus -eq 0) "$scenario silently requested a reboot instead of failing."
        }
        elseif ($scenario -eq 'AlreadyActive') {
            Assert-True (-not $failure -and $script:RenameCalls -eq 0 -and $global:DSCMachineStatus -eq 0) 'An already-correct active name was renamed or rebooted.'
        }
        else {
            $expectedCalls = if ($scenario -eq 'AlreadyPending') { 0 } else { 1 }
            Assert-True (-not $failure -and $script:RenameCalls -eq $expectedCalls -and $global:DSCMachineStatus -eq 1) `
                "$scenario failed to verify the staged rename before requesting its reboot."
        }
    }
}
finally {
    if ($previousDscStatus) { Set-Variable -Name DSCMachineStatus -Scope Global -Value $previousDscStatus.Value }
    else { Remove-Variable -Name DSCMachineStatus -Scope Global -ErrorAction SilentlyContinue }
}
$helperAst = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$parseErrors)
$commands = @($helperAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() })
Assert-True (@($commands | Where-Object { $_ -match '^(Set-|New-Item|Restart-|Stop-|Rename-|Add-Computer|Reset-)' }).Count -eq 0) `
    'The shared setup probe can mutate guest state.'

Write-Host 'PASS -- full-native and guarded first-logon deployment readiness, real asynchronous results, fail-closed protocol, bounded retries, server exclusions, and actual DSC guards.'
