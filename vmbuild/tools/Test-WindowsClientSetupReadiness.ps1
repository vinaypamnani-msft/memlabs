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
}
function Get-CimInstance {
    param($ClassName, $OperationTimeoutSec, $ErrorAction)
    Assert-True ($ClassName -eq 'Win32_OperatingSystem' -and $OperationTimeoutSec -eq 5) 'OS classification lost its bounded local query.'
    if ($script:CimThrows) { throw 'Synthetic CIM failure' }
    [pscustomobject]@{ ProductType = $script:ProductType }
}
function Get-ItemProperty {
    param($LiteralPath, $Name, $ErrorAction)
    $script:RegistryReads++
    if ($script:RegistryThrows) { throw 'Synthetic setup registry failure' }
    switch ($LiteralPath) {
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' { return [pscustomobject]@{ ImageState = $script:ImageState } }
        'HKLM:\SYSTEM\Setup' { return $script:SetupValues }
        'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' { return [pscustomobject]@{ ComputerName = $script:ActiveName } }
        'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' { return [pscustomobject]@{ ComputerName = $script:PendingName } }
        default { throw "Unexpected registry path: $LiteralPath" }
    }
}
function Get-MemLabsWindowsOobeCompletion {
    $script:NativeReads++
    if ($script:NativeThrows) { throw 'Synthetic native OOBE API failure' }
    return $script:NativeValue
}

Reset-SetupFixture
$readyState = Get-MemLabsWindowsClientSetupState
Assert-True ($readyState.Ready -and $readyState.Required -and $readyState.Version -eq 1) 'A fully completed client was rejected.'
foreach ($serverType in @(2, 3)) {
    Reset-SetupFixture
    $script:ProductType = $serverType
    $state = Get-MemLabsWindowsClientSetupState
    Assert-True ($state.Ready -and -not $state.Required -and $script:RegistryReads -eq 0 -and $script:NativeReads -eq 0) `
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
Reset-HostFixture -Response (New-Reply $readyState)
$script:Replies.Enqueue((New-Reply $pendingState))
$script:Replies.Enqueue((New-Reply $readyState))
Assert-True (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 5) 'An incomplete-to-complete transition was not retried.'
Assert-True ($script:RpcCalls -eq 2 -and ($script:Messages -join ' ') -match 'WindowsWelcomeIncomplete') 'Pending user OOBE was not logged before retry.'
Reset-HostFixture -Response (New-Reply $readyState)
$script:ReplyDelayMilliseconds = 1100
Assert-True (-not (Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 1)) 'A late completed response passed after the readiness deadline.'
Assert-True (($script:Messages -join ' ') -match 'late reply') 'The readiness deadline rejected a late response without explanation.'

foreach ($variant in @('Pending', 'StringReady', 'MissingFlag', 'StringFlag', 'InconsistentNative',
        'InvalidServer', 'MissingVersion', 'MissingPendingName', 'BlankPendingName', 'ArrayImageState',
        'InconsistentReason', 'Multiple', 'Transport', 'NoResponse')) {
    $badState = $readyState | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    if ($variant -eq 'Pending') { $badState = $pendingState }
    if ($variant -eq 'StringReady') { $badState.Ready = 'True' }
    if ($variant -eq 'MissingFlag') { $badState.PSObject.Properties.Remove('OOBEInProgress') }
    if ($variant -eq 'StringFlag') { $badState.OOBEInProgress = '0' }
    if ($variant -eq 'InconsistentNative') { $badState.NativeOobeComplete = $false }
    if ($variant -eq 'InvalidServer') { $badState.Required = $false }
    if ($variant -eq 'MissingVersion') { $badState.PSObject.Properties.Remove('Version') }
    if ($variant -eq 'MissingPendingName') { $badState.PSObject.Properties.Remove('PendingName') }
    if ($variant -eq 'BlankPendingName') { $badState.PendingName = '' }
    if ($variant -eq 'ArrayImageState') { $badState.ImageState = @('IMAGE_STATE_COMPLETE', 'INVALID') }
    if ($variant -eq 'InconsistentReason') { $badState.Reason = 'ProbeFailed' }
    $reply = New-Reply $badState
    if ($variant -eq 'Multiple') { $reply.ScriptBlockOutput = @($readyState, $readyState) }
    if ($variant -eq 'Transport') { $reply.ScriptBlockFailed = $true; $reply.ErrorDetails = @('Synthetic transport failure') }
    if ($variant -eq 'NoResponse') { $reply = $null }
    Reset-HostFixture -Response $reply -AdvanceClock
    Set-StrictMode -Version Latest
    try {
        $passed = Wait-MemLabsWindowsClientSetup -VmName TEST-W11 -TimeoutSeconds 1
        Assert-True (-not $passed -and $script:RpcCalls -eq 1 -and $script:RpcBudgets[0] -eq 1 -and
            ($script:Messages -join ' ') -match 'did not become ready') "$variant became ready or escaped its deadline/diagnostics."
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
        foreach ($scenario in @('Client', 'DomainController', 'MemberServer', 'GuestFailure')) {
            Reset-SetupFixture
            $script:ProductType = switch ($scenario) {
                'DomainController' { 2 }
                'MemberServer' { 3 }
                default { 1 }
            }
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

Write-Host 'PASS -- native/registry client readiness, real asynchronous command results, fail-closed protocol, bounded retries, server exclusions, and fresh/resume/DSC wiring.'
