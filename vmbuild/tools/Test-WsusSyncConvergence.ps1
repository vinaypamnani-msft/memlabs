#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Read-TestAst {
    param([string] $Path)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    return $ast
}
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
$perfAst = Read-TestAst (Join-Path $root 'DSC\phases\perfloading.ps1')
foreach ($name in @('Get-WsusSyncLiveness', 'Wait-WsusSyncCompletion', 'Invoke-FullSync',
        'Repair-WsusSync', 'Confirm-MemLabsWsusSyncHealth')) {
    $node = $perfAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name
    }
    Assert-True ($null -ne $node) "$name must be defined at perfloading script scope, independently of downstream replica recovery."
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:DomainFullName = 'lab.test'; $script:SiteCode = 'CAS'; $script:Tag = '[test]'
$Sups = @([pscustomobject]@{ vmName = 'REMOTE-SUP' })
$script:CMInstallDir = $env:TEMP
$script:ProbeSucceeded = $true; $script:NativeRunning = $false
$script:NativeResult = 'Succeeded'; $script:CmState = 6702
$script:RepairCalls = 0; $script:SyncDrops = 0; $script:SiteRestarts = 0
$script:ProbeTargets = @()
$script:StatusMessages = @()
$script:OtherSupFailed = $true
function Write-DscStatus {
    param($Message, [switch] $Warning, [switch] $Failure)
    $script:StatusMessages += $Message
}
function Start-Sleep { param($Seconds) }
function Write-WsusDiagnostics { param($Reason) }
function Get-CMSoftwareUpdateSyncStatus {
    [pscustomobject]@{ SiteCode = 'CAS'; LastSyncState = $script:CmState; LastSyncStateTime = Get-Date }
}
function Invoke-CMWsusReplicaHealthCheck {
    param($ServerFQDN)
    $script:ProbeTargets += $ServerFQDN
    $failedOtherSup = $ServerFQDN -eq 'FAILED-SUP.lab.test' -and $script:OtherSupFailed
    [pscustomobject]@{
        Server = $ServerFQDN; ProbeSucceeded = $script:ProbeSucceeded
        WsusRunning = $script:NativeRunning -and -not $failedOtherSup
        LastResult = if ($failedOtherSup) { 'Failed' } else { $script:NativeResult }
        LastError = 'fixture'; LastErrorText = 'fixture'; PoolUp = $true
        Phase = 'Categories'; ProcessedItems = 0; TotalItems = 0; Detail = 'fixture'
    }
}
function Test-Path { param($Path) $true }
function New-Item { param($Path, $ItemType, [switch] $Force, $ErrorAction) $script:SyncDrops++ }
function Restart-Service { param($Name, [switch] $Force, $ErrorAction) $script:SiteRestarts++ }
function Invoke-CMRoleTargetCommand {
    param($ComputerName, $ScriptBlock)
    Assert-True ($ComputerName -eq 'REMOTE-SUP.lab.test') 'Recovery targeted the site server instead of its remote SUP.'
    $script:RepairCalls++
    [pscustomobject]@{ Skipped = $script:NativeRunning; Detail = 'fixture' }
}

$state = Get-WsusSyncLiveness
Assert-True ($state.ProbeSucceeded -and $state.LastResult -eq 'Succeeded') 'Successful native health was lost.'
Assert-True ($script:ProbeTargets[0] -eq 'REMOTE-SUP.lab.test') 'Native health did not target the configured SUP.'
Assert-True (Wait-WsusSyncCompletion -MaxAttempts 1) 'CM 6702 plus native success was rejected.'
Confirm-MemLabsWsusSyncHealth

$script:NativeResult = 'Unknown'
Assert-True (-not (Wait-WsusSyncCompletion -MaxAttempts 2)) 'Unknown native health was accepted as completed.'
$script:ProbeSucceeded = $false
Assert-True (-not (Wait-WsusSyncCompletion -MaxAttempts 2)) 'An unreadable native probe was accepted as completed.'
$triggerError = $null
try { Invoke-FullSync } catch { $triggerError = $_.Exception.Message }
Assert-True ($triggerError -match 'Cannot safely trigger') 'Unreadable native health allowed an unsafe sync trigger.'

$script:ProbeSucceeded = $true; $script:NativeRunning = $true
$script:NativeResult = 'Canceled'; $script:CmState = 6703
Assert-True (-not (Wait-WsusSyncCompletion -MaxAttempts 3)) 'An active native sync was falsely declared complete.'
Invoke-FullSync
Repair-WsusSync
Assert-True ($script:SyncDrops -eq 0 -and $script:SiteRestarts -eq 0) 'An active native sync was interrupted using a stale CM failure.'

$script:NativeRunning = $false; $script:NativeResult = 'Failed'; $script:CmState = 6702
Assert-True (-not (Wait-WsusSyncCompletion -MaxAttempts 2)) 'Native failure was accepted as CM success.'
Assert-True ($script:SyncDrops -eq 1) 'Confirmed false-positive completion did not request bounded recovery.'

$script:FinalWaitCalls = 0
$script:FinalWaitAction = {}
function Wait-WsusSyncCompletion {
    param($Label, $MaxAttempts, [switch] $TriggerFirst)
    $script:FinalWaitCalls++
    Assert-True ($MaxAttempts -eq 40 -and $TriggerFirst) 'Final recovery lost its bounded retry contract.'
    & $script:FinalWaitAction
    return $script:FinalRecovered
}
$script:FinalRecovered = $false
$finalError = $null
try { Confirm-MemLabsWsusSyncHealth } catch { $finalError = $_.Exception.Message }
Assert-True ($finalError -match 'did not recover') 'Exhausted final recovery did not fail Phase 8.'
$script:FinalRecovered = $true
$script:FinalWaitAction = { $script:NativeResult = 'Succeeded' }
Confirm-MemLabsWsusSyncHealth
Assert-True ($script:FinalWaitCalls -eq 2) 'Final recovery was not invoked for failed native sync.'
$script:NativeResult = 'Failed'; $script:FinalRecovered = $false
$script:FinalWaitAction = { $script:NativeRunning = $true }
Confirm-MemLabsWsusSyncHealth
Assert-True ($script:FinalWaitCalls -eq 3) 'An active replacement sync did not traverse the bounded recovery wait.'
Assert-True (($script:StatusMessages -join ' ') -match 'Completion is pending, not proven') 'An active replacement was falsely declared completed.'
Confirm-MemLabsWsusSyncHealth
Assert-True ($script:FinalWaitCalls -eq 3) 'Healthy background synchronization was unnecessarily awaited.'
$Sups += [pscustomobject]@{ vmName = 'FAILED-SUP' }
$mixed = Get-WsusSyncLiveness
Assert-True ($mixed.WsusRunning -and $mixed.HasFailedIdleSync) 'An active SUP masked another SUP with an idle failed synchronization.'
$finalError = $null
try { Confirm-MemLabsWsusSyncHealth } catch { $finalError = $_.Exception.Message }
Assert-True ($finalError -match 'did not recover') 'An active replacement masked another SUP that remained failed after recovery.'
$script:FinalRecovered = $true
$script:FinalWaitAction = {
    $script:OtherSupFailed = $false
    $script:NativeRunning = $false
    $script:NativeResult = 'Succeeded'
}
Confirm-MemLabsWsusSyncHealth
Assert-True ($script:FinalWaitCalls -eq 5) 'Mixed active/failed SUP health bypassed final recovery.'
$script:NativeResult = 'Failed'
$script:FinalWaitAction = { $script:ProbeSucceeded = $false }
$finalError = $null
try { Confirm-MemLabsWsusSyncHealth } catch { $finalError = $_.Exception.Message }
Assert-True ($finalError -match 'Cannot verify.*after final WSUS recovery') 'Unreadable post-recovery native health was accepted as success.'
$Sups = @()
$empty = Get-WsusSyncLiveness
Assert-True (-not $empty.ProbeSucceeded) 'An empty SUP scope was treated as measured success.'
$probeCount = $script:ProbeTargets.Count
Confirm-MemLabsWsusSyncHealth
Assert-True ($script:ProbeTargets.Count -eq $probeCount -and $script:FinalWaitCalls -eq 6) 'An unconfigured SUP triggered final WSUS health recovery.'

$validationPath = Join-Path $root 'common\Common.Validation.Functional.ps1'
$validationAst = Read-TestAst $validationPath
$assignment = $validationAst.Find({
    param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$supScript'
}, $true)
$block = $assignment.Right.Find({
    param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst]
}, $true)
Add-Type @'
namespace MemLabs {
    public static class WsusValidationTestProxy {
        public static object Server;
        public static object GetUpdateServer(string name, bool ssl, int port) { return Server; }
    }
    public class WsusValidationTestScope {}
}
'@
$supScript = [scriptblock]::Create($block.ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}').Replace(
    '[Microsoft.UpdateServices.Administration.AdminProxy]', '[MemLabs.WsusValidationTestProxy]'))
$subscription = [pscustomobject]@{ Result = 'Failed'; State = 'NotProcessing'; ThrowInfo = $false }
$subscription | Add-Member ScriptMethod GetLastSynchronizationInfo {
    if ($this.ThrowInfo) { throw 'fixture native result unavailable' }
    [pscustomobject]@{ Result = $this.Result; Error = 'Unknown'; StartTime = 'start'; EndTime = 'end'; ErrorText = 'fixture failure' }
}
$subscription | Add-Member ScriptMethod GetSynchronizationStatus {
    if ($this.State -eq 'Unreadable') { throw 'fixture native state unavailable' }
    $this.State
}
$server = [pscustomobject]@{ Subscription = $subscription }
$server | Add-Member ScriptMethod GetSubscription { $this.Subscription }
[MemLabs.WsusValidationTestProxy]::Server = $server
function Get-Service { param($Name, $ErrorAction) [pscustomobject]@{ Status = 'Running' } }
function Import-Module { param($Name, $ErrorAction) }
function Get-WebAppPoolState { param($Name, $ErrorAction) [pscustomobject]@{ Value = 'Started' } }
function Get-NetTCPConnection { param($State, $LocalPort, $ErrorAction) [pscustomobject]@{ LocalPort = 8530 } }
function Test-Path { param($LiteralPath) $false }
foreach ($nativeResult in @('Failed', 'Canceled')) {
    $subscription.Result = $nativeResult
    $result = & $supScript
    Assert-True (-not $result.Passed -and ($result.Details -join ' ') -match 'No newer running sync') "Idle $nativeResult sync passed functional validation."
}
$subscription.State = 'Running'
$result = & $supScript
Assert-True ($result.Passed -and ($result.Details -join ' ') -match 'Completion is pending') 'A running replacement sync was misreported as failed or completed.'
$subscription.State = 'NotProcessing'; $subscription.Result = 'Succeeded'
Assert-True ((& $supScript).Passed) 'Successful native synchronization failed validation.'
[MemLabs.WsusValidationTestProxy]::Server = $null
Assert-True (-not (& $supScript).Passed) 'Unreachable WSUS API silently passed validation.'

$validationText = [IO.File]::ReadAllText($validationPath)
Assert-True ($validationText -notmatch 'Result=Canceled but catalog is populated - benign') 'Catalog presence still masks a canceled synchronization.'
Assert-True ($validationText -notmatch 'INFO: WSUS-native cross-check skipped') 'An unreadable WSUS cross-check still reports success-shaped output.'

$nativeCheck = @($validationAst.FindAll({
    param($n)
    $n -is [Management.Automation.Language.TryStatementAst] -and
        ($n.CatchClauses.Extent.Text -match 'FAIL: WSUS-native cross-check could not reach SUP')
}, $true))
Assert-True ($nativeCheck.Count -eq 1) 'Expected one site-wide WSUS-native cross-check.'
$wsusCheck = [scriptblock]::Create($nativeCheck[0].Extent.Text.Replace(
    '[Microsoft.UpdateServices.Administration.UpdateScope]', '[MemLabs.WsusValidationTestScope]'))

$subscription | Add-Member ScriptMethod GetUpdateCategories { return ,@(1) }
$subscription | Add-Member ScriptMethod GetUpdateClassifications { return ,@(1, 2, 3) }
$script:NativeStarts = 0
$subscription | Add-Member ScriptMethod StartSynchronization { $script:NativeStarts++ }
$server | Add-Member NoteProperty UpdateCount 2879
$server | Add-Member NoteProperty CountUnavailable $false
$server | Add-Member NoteProperty Configuration ([pscustomobject]@{
    SyncFromMicrosoftUpdate = $true; UpstreamWsusServerName = ''
})
$server | Add-Member ScriptMethod GetStatus { throw 'fixture aggregate status timed out' }
$server | Add-Member ScriptMethod GetUpdateCount {
    param($Scope)
    if ($this.CountUnavailable) { throw 'fixture count timed out' }
    return $this.UpdateCount
}
$server | Add-Member ScriptMethod GetConfiguration { return $this.Configuration }
$server | Add-Member ScriptMethod GetUpdateCategories { return ,@(1..435) }
$server | Add-Member ScriptMethod GetUpdateClassifications { return ,@(1..12) }
function Get-WsusServer {
    [CmdletBinding()]
    param($Name, $PortNumber, [switch] $UseSsl)
    if ($script:ServerUnavailable) { throw 'fixture SUP connection timed out' }
    return $server
}
function Get-CMSoftwareUpdateCategory {
    [CmdletBinding()]
    param([switch] $Fast, $TypeName)
    throw 'fixture CM subscription cmdlets unavailable'
}
function Get-ItemPropertyValue {
    [CmdletBinding()]
    param($Path, $Name)
    throw 'fixture WCM state unavailable'
}
function Invoke-WsusValidationFixture {
    $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
    & $wsusCheck
    return $results
}
$script:supServer = 'REMOTE-SUP.lab.test'; $script:wsusPort = 8530; $script:wsusUseSsl = $false
$script:offlineSup = $false; $script:ServerUnavailable = $false
$subscription.Result = 'Succeeded'; $subscription.State = 'NotProcessing'
$result = Invoke-WsusValidationFixture
Assert-True ($result.Passed -and ($result.Details -join ' ') -match 'last sync Succeeded.*UpdateCount=2879') 'Aggregate GetStatus failure prevented readable native health from passing.'
Assert-True (-not $result.WsusDiagnosticsRequired -and $script:NativeStarts -eq 0) 'Healthy native health requested unnecessary diagnostics or synchronization.'

$server.CountUnavailable = $true
$result = Invoke-WsusValidationFixture
Assert-True ($result.Passed -and ($result.Details -join ' ') -match 'WARN: WSUS update count could not be measured') 'An optional count failure masked readable native sync health.'
Assert-True (($result.Details -join ' ') -match 'UpdateCount=<unavailable>' -and $script:NativeStarts -eq 0) 'An unreadable count was treated as an empty catalog or triggered a sync.'
Assert-True $result.WsusDiagnosticsRequired 'An unavailable count did not request server-side diagnostics.'

$server.Configuration.SyncFromMicrosoftUpdate = $false
$server.Configuration.UpstreamWsusServerName = 'CAS-SUP.lab.test'
foreach ($nativeResult in @('Failed', 'Canceled')) {
    $subscription.Result = $nativeResult
    $result = Invoke-WsusValidationFixture
    Assert-True (-not $result.Passed -and ($result.Details -join ' ') -match "Result=$nativeResult with no running replacement") "Optional statistics masked idle $nativeResult native health."
    Assert-True (($result.Details -join ' ') -match 'ErrorText=fixture failure') 'Site-wide native failure lost its actual WSUS error.'
    Assert-True ($result.WsusDiagnosticsRequired -and $result.WsusUpstreamServer -eq 'CAS-SUP.lab.test') 'Failed downstream health lost its diagnostic flag or upstream target.'
}
Assert-True ($script:NativeStarts -eq 0) 'Validation forced a failed downstream sync while its upstream might still be running.'
$failedNativeResult = $result
$subscription.State = 'Running'
$result = Invoke-WsusValidationFixture
Assert-True ($result.Passed -and ($result.Details -join ' ') -match 'WSUS sync running') 'A running replacement was rejected because its previous sync failed.'

$subscription.State = 'NotProcessing'; $subscription.Result = 'Succeeded'
$subscription.ThrowInfo = $true
$result = Invoke-WsusValidationFixture
Assert-True (-not $result.Passed -and $result.WsusDiagnosticsRequired -and ($result.Details -join ' ') -match 'fixture native result unavailable') 'Unreadable native result was hidden by taxonomy or catalog statistics.'
$subscription.ThrowInfo = $false; $subscription.State = 'Unreadable'
$result = Invoke-WsusValidationFixture
Assert-True (-not $result.Passed -and ($result.Details -join ' ') -match 'fixture native state unavailable') 'Unreadable native state passed site-wide validation.'
$subscription.State = 'NotProcessing'; $subscription.Result = ''
Assert-True (-not (Invoke-WsusValidationFixture).Passed) 'An empty native result passed site-wide validation.'
$subscription.Result = 'Succeeded'
$script:ServerUnavailable = $true
$result = Invoke-WsusValidationFixture
Assert-True (-not $result.Passed -and $result.WsusDiagnosticsRequired -and ($result.Details -join ' ') -match 'fixture SUP connection timed out') 'An unreachable SUP was downgraded to an optional statistics warning.'
$script:ServerUnavailable = $false
$server.CountUnavailable = $false; $server.UpdateCount = $null
$result = Invoke-WsusValidationFixture
Assert-True ($result.Passed -and $script:NativeStarts -eq 0 -and ($result.Details -join ' ') -match 'UpdateCount=<unavailable>') 'An invalid count became a success-shaped zero.'
$server.UpdateCount = 0; $server.Configuration.SyncFromMicrosoftUpdate = $true
$server.Configuration.UpstreamWsusServerName = ''
$result = Invoke-WsusValidationFixture
Assert-True ($result.Passed -and $script:NativeStarts -eq 1) 'A measured empty, subscribed top-level catalog no longer starts its first update sync.'

$cmFailureBranch = @($validationAst.FindAll({
    param($n)
    $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -match '\$supErrHex -in \$transientSyncErrors'
}, $true))
Assert-True ($cmFailureBranch.Count -eq 1) 'Expected one CM sync error classification branch.'
$cmFailureCheck = [scriptblock]::Create('param($supErr, $supErrHex, $syncStatus)' + "`n" +
    ($cmFailureBranch[0].ElseClause.Statements.Extent.Text -join "`n"))
$updateErrors = @(
    foreach ($revision in 1..9) {
        $updateError = [pscustomobject]@{
            UpdateId = [pscustomobject]@{
                UpdateId = [guid]'fcd98fa1-a6b0-4613-8efd-ea8019bdd6e3'; RevisionNumber = $revision
            }
            Error = 'InvalidUpdate'
            ErrorText = "Cannot insert the value NULL into column 'RevisionID', table '@BundleAll'; fixture revision $revision."
        }
        if ($revision -eq 1) { $updateError.ErrorText += 'x' * 2000 }
        $updateError | Add-Member ScriptMethod ToString { 'Microsoft.UpdateServices.Administration.SynchronizationUpdateErrorInfo' } -Force
        $updateError
    }
)
$history = [pscustomobject]@{
    StartTime = [datetime]::UtcNow.AddMinutes(-7); EndTime = [datetime]::UtcNow.AddMinutes(-1)
    Result = 'Canceled'; Error = 'UserCanceled'; ErrorText = ''; UpdateErrors = $updateErrors
}
$subscription | Add-Member NoteProperty History @($history)
$subscription | Add-Member NoteProperty ThrowHistory $false
$subscription | Add-Member ScriptMethod GetSynchronizationHistory {
    if ($this.ThrowHistory) { throw 'fixture history unavailable' }
    return $this.History
}
function Invoke-WsusCmFailureFixture {
    $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
    $syncStatus = [pscustomobject]@{
        LastSyncStateTime = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddMinutes(-1))
    }
    & $cmFailureCheck -supErr 2148735236L -supErrHex '0x80131904' -syncStatus $syncStatus
    return $results
}
$subscription.State = 'NotProcessing'
$result = Invoke-WsusCmFailureFixture
$historyDetail = $result.Details -join ' '
Assert-True (-not $result.Passed -and $historyDetail -match 'updateErrors=9 shown=3') 'Canceled history lost the bounded per-update failure evidence.'
Assert-True ($historyDetail -match 'RevisionID.*BundleAll' -and
    $historyDetail -match 'fcd98fa1-a6b0-4613-8efd-ea8019bdd6e3') 'WSUS update errors printed a type name instead of the update identity and SQL error.'
Assert-True ($historyDetail -match '\[truncated\]' -and $historyDetail.Length -lt 5000 -and
    $historyDetail -notmatch 'fixture revision 4') 'WSUS update-error diagnostics exceeded their sample or text bounds.'
Assert-True ($historyDetail -match 'cancellation alone does not identify' -and $historyDetail -notmatch 'cause=the sync was CANCELLED') `
    'UserCanceled was attributed to a restart without evidence of the initiating fault.'

$subscription.State = 'Running'
$result = Invoke-WsusCmFailureFixture
Assert-True ($result.Passed -and ($result.Details -join ' ') -match 'already stale.*running a new sync') 'A running replacement stopped superseding the older CM failure.'
$subscription.State = 'NotProcessing'
$history.Result = 'Succeeded'; $history.Error = 'NotApplicable'; $history.UpdateErrors = @()
$history.EndTime = [datetime]::UtcNow
$result = Invoke-WsusCmFailureFixture
Assert-True ($result.Passed -and ($result.Details -join ' ') -match 'already stale.*completed a successful sync') 'A newer successful WSUS cycle stopped superseding the older CM failure.'
$subscription.ThrowHistory = $true
$result = Invoke-WsusCmFailureFixture
Assert-True (-not $result.Passed -and ($result.Details -join ' ') -match 'history not collected.*fixture history unavailable') 'Unreadable history masked the CM failure or lost its diagnostic error.'
$subscription.ThrowHistory = $false

$siteFunction = $validationAst.Find({
    param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-CMSiteWideFunctionality'
}, $true)
$captureTry = $siteFunction.Body.Find({
    param($n)
    $n -is [Management.Automation.Language.TryStatementAst] -and
        ($n.CatchClauses.Extent.Text -match 'WSUS diagnostic capture failed')
}, $true)
Assert-True ($null -ne $captureTry) 'Site-wide WSUS evidence capture is missing.'
$capture = [scriptblock]::Create($captureTry.Extent.Text)
$script:Captures = @(); $script:CaptureWarnings = @()
function Add-Phase11Output { param($Message) }
function Write-Log {
    param($Message, [switch] $Warning, [switch] $LogOnly)
    if ($Warning) { $script:CaptureWarnings += $Message }
}
function Save-Phase11GuestLogs {
    param($VMName, $DomainName, $RoleLabel, $Collector, $TimeoutSeconds)
    $script:Captures += [pscustomobject]@{
        VMName = $VMName; Domain = $DomainName; Role = $RoleLabel; Timeout = $TimeoutSeconds
    }
}
$script:Phase = 11; $VMName = 'PS2-SITE'; $script:siteRoleLabel = 'Primary (PS2)'
$script:domain = 'lab.test'; $script:siteCode = 'PS2'; $script:hierarchySiteCode = 'CAS'; $script:hasSUP = $true
$supVmObj = [pscustomobject]@{ vmName = 'REMOTE-SUP'; siteCode = 'PS2'; installSUP = $true }
$script:DeployConfig = [pscustomobject]@{ virtualMachines = @(
    $supVmObj
    [pscustomobject]@{ vmName = 'CAS-SUP'; siteCode = 'CAS'; installSUP = $true }
    [pscustomobject]@{ vmName = 'OTHER-SUP'; siteCode = 'OTHER'; installSUP = $true }
) }
$script:Phase11CmWsusSyncCollector = {}; $script:Phase11WsusStallCollector = {}
$result = [pscustomobject]@{ ScriptBlockOutput = $failedNativeResult; ScriptBlockFailed = $false }
& $capture
Assert-True ($script:Captures.Count -eq 3) 'Failed native health did not capture the site server, actual SUP, and upstream SUP.'
Assert-True (@($script:Captures | Where-Object VMName -eq 'CAS-SUP').Count -eq 1) 'Downstream SOAP failure did not capture upstream server evidence exactly once.'
Assert-True (@($script:Captures | Where-Object VMName -eq 'OTHER-SUP').Count -eq 0) 'WSUS diagnostic capture escaped the affected topology.'
Assert-True (@($script:Captures | Where-Object Timeout -ne 240).Count -eq 0) 'WSUS diagnostic collection lost its bounded timeout.'
Assert-True (-not $result.ScriptBlockOutput.Passed) 'Diagnostic collection changed a failed validation result.'

$script:Captures = @()
$DeployConfig.virtualMachines += [pscustomobject]@{
    vmName = 'FOREST-SUP'; siteCode = 'CAS'; installSUP = $true; domain = 'branch.test'
}
$result.ScriptBlockOutput.WsusUpstreamServer = 'FOREST-SUP.branch.test'
& $capture
$forestCapture = @($script:Captures | Where-Object VMName -eq 'FOREST-SUP')
Assert-True ($script:Captures.Count -eq 3 -and $forestCapture.Count -eq 1 -and $forestCapture[0].Domain -eq 'branch.test') 'An explicitly configured upstream in another domain was resolved or accessed in the wrong domain.'
$DeployConfig.virtualMachines = @($DeployConfig.virtualMachines | Where-Object vmName -ne 'FOREST-SUP')

$script:Captures = @()
$result = [pscustomobject]@{ ScriptBlockOutput = 'fixture transport timeout'; ScriptBlockFailed = $true }
& $capture
Assert-True ($script:Captures.Count -eq 3) 'A timed-out probe did not collect local and parent-site SUP evidence.'

$script:Captures = @()
$result = [pscustomobject]@{ ScriptBlockOutput = @{
    Passed = $true; Details = @('OK: native sync succeeded'); WsusDiagnosticsRequired = $false
}; ScriptBlockFailed = $false }
& $capture
Assert-True ($script:Captures.Count -eq 0) 'Healthy native sync collected failure diagnostics.'
$result.ScriptBlockOutput.Details = @('WARN: CM/WSUS desync: fixture')
& $capture
Assert-True ($script:Captures.Count -eq 3) 'Legacy uncorroborated CM/WSUS state stopped collecting both sides.'
$script:Captures = @()
$result.ScriptBlockOutput.Details = @('OK: native sync succeeded')
$result.ScriptBlockOutput.WsusDiagnosticsRequired = $true
$result.ScriptBlockOutput.WsusUpstreamServer = 'EXTERNAL-SUP.lab.test'
& $capture
Assert-True ($script:Captures.Count -eq 2 -and ($script:CaptureWarnings -join ' ') -match 'outside the deployment config') 'An unconfigured upstream was silently ignored or probed.'
Assert-True $result.ScriptBlockOutput.Passed 'Optional-count diagnostics converted native success into failure.'

$supCaptureIf = $validationAst.Find({
    param($n)
    $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -match "Format-TestResult.+RoleLabel 'SUP'" -and
        $n.Extent.Text -match 'SUP-SyncFailure'
}, $true)
Assert-True ($null -ne $supCaptureIf) 'The per-machine SUP failure path does not collect WSUS evidence.'
function Format-TestResult { param($VMName, $RoleLabel, $Result) return $false }
$script:Captures = @(); $allPassed = $true
. ([scriptblock]::Create($supCaptureIf.Extent.Text))
Assert-True (-not $allPassed -and $script:Captures.Count -eq 1 -and $script:Captures[0].VMName -eq $VMName) 'A per-machine SUP failure did not preserve failure and capture its own server evidence.'
function Save-Phase11GuestLogs {
    param($VMName, $DomainName, $RoleLabel, $Collector, $TimeoutSeconds)
    throw 'fixture collector failure'
}
. ([scriptblock]::Create($supCaptureIf.Extent.Text))
Assert-True (($script:CaptureWarnings -join ' ') -match 'WSUS diagnostic capture failed: fixture collector failure') 'Diagnostic capture errors were swallowed.'

$collectorAssignment = $validationAst.Find({
    param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$Phase11WsusStallCollector'
}, $true)
Assert-True ($null -ne $collectorAssignment) 'The actual WSUS log collector is missing.'
. ([scriptblock]::Create($collectorAssignment.Extent.Text))
$saveDefinition = $validationAst.Find({
    param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Save-Phase11GuestLogs'
}, $true)
Assert-True ($null -ne $saveDefinition) 'The guest-to-host diagnostic writer is missing.'
. ([scriptblock]::Create($saveDefinition.Extent.Text))
Remove-Item -LiteralPath 'Function:\Test-Path', 'Function:\New-Item'
function Get-Item {
    [CmdletBinding()]
    param($Path)
    return $null
}
function Get-WinEvent {
    [CmdletBinding()]
    param($FilterHashtable)
}
function Get-Volume {
    [CmdletBinding()]
    param()
}
function Get-ItemProperty {
    [CmdletBinding()]
    param($Path, $Name)
    return [pscustomobject]@{ TargetDir = $script:WsusFixtureDirectory }
}
function Invoke-VmCommand {
    [CmdletBinding()]
    param($VmName, $VmDomainName, $ScriptBlock, [switch] $SuppressLog,
        [switch] $AsJob, $TimeoutSeconds, $DisplayName)
    Assert-True ($TimeoutSeconds -eq 240 -and $AsJob) 'Raw WSUS capture lost its bounded guest invocation.'
    return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = (& $ScriptBlock) }
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('wsus-failure-diag-' + [guid]::NewGuid().ToString('N'))
try {
    $script:WsusFixtureDirectory = Join-Path $fixtureRoot 'WSUS'
    $sourceLogs = Join-Path $WsusFixtureDirectory 'LogFiles'
    $hostLogs = Join-Path $fixtureRoot 'host'
    $null = New-Item -Path $sourceLogs, $hostLogs -ItemType Directory -Force
    $script:Common = @{ LogPath = (Join-Path $hostLogs 'VMBuild.log') }
    $currentLog = Join-Path $sourceLogs 'SoftwareDistribution.log'
    Set-Content -LiteralPath $currentLog -Value @(1..3002 | ForEach-Object { "current-$_" })
    [IO.File]::SetLastWriteTimeUtc($currentLog, [DateTime]::UtcNow.AddDays(-10))
    $rolledLog = Join-Path $sourceLogs 'SoftwareDistribution.log.old'
    Set-Content -LiteralPath $rolledLog -Value 'fixture upstream SOAP fault in rolled log'
    $otherRoll = Join-Path $sourceLogs 'SoftwareDistribution.log.1'
    Set-Content -LiteralPath $otherRoll -Value 'fixture older sync context'
    [IO.File]::SetLastWriteTimeUtc($otherRoll, [DateTime]::UtcNow.AddDays(-1))
    $omittedRoll = Join-Path $sourceLogs 'SoftwareDistribution.log.2'
    Set-Content -LiteralPath $omittedRoll -Value 'fixture outside retained capture window'
    [IO.File]::SetLastWriteTimeUtc($omittedRoll, [DateTime]::UtcNow.AddDays(-2))

    $saved = @(Save-Phase11GuestLogs -VMName 'FIXTURE-SUP' -DomainName 'lab.test' `
        -RoleLabel 'SUP-SyncHealth' -Collector $Phase11WsusStallCollector -TimeoutSeconds 240)
    $savedCurrent = @($saved | Where-Object { $_ -like '*-SoftwareDistribution.log' })
    $savedRolled = @($saved | Where-Object { $_ -like '*-SoftwareDistribution.log.old' })
    $savedDiag = @($saved | Where-Object { $_ -like '*-_collector-diag.txt' })
    Assert-True ($savedCurrent.Count -eq 1 -and $savedRolled.Count -eq 1 -and $savedDiag.Count -eq 1) 'Actual collector-to-host transport lost current/rolled WSUS logs or capture diagnostics.'
    $currentLines = @(Get-Content -LiteralPath $savedCurrent[0])
    Assert-True ($currentLines.Count -eq 3000 -and $currentLines[0] -eq 'current-3' -and $currentLines[-1] -eq 'current-3002') 'Current WSUS log capture lost its exact 3000-line tail bound.'
    Assert-True ((Get-Content -LiteralPath $savedRolled[0] -Raw) -match 'fixture upstream SOAP fault in rolled log') 'The upstream SOAP fault did not survive rolled-log collection and host persistence.'
    Assert-True (@($saved | Where-Object { $_ -like '*SoftwareDistribution.log*' }).Count -eq 3) 'WSUS log transfer did not retain the current log plus the two newest rolled logs.'
    Assert-True (@($saved | Where-Object { $_ -like '*-SoftwareDistribution.log.2' }).Count -eq 0) 'WSUS log transfer exceeded its file-count bound.'
    $diag = Get-Content -LiteralPath $savedDiag[0] -Raw
    Assert-True ($diag -match 'capturedLines=3000' -and $diag -match 'omitted 1 older file') 'Capture truncation was not reported explicitly.'

    function Get-Content {
        [CmdletBinding()]
        param($LiteralPath, $Tail)
        if ($LiteralPath -like '*SoftwareDistribution.log.old') { throw 'fixture rolled log read denied' }
        Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
    }
    $collected = & $Phase11WsusStallCollector
    Assert-True ($collected.ContainsKey('SoftwareDistribution.log') -and
        -not $collected.ContainsKey('SoftwareDistribution.log.old') -and
        $collected['_collector-diag.txt'] -match 'fixture rolled log read denied') 'An unreadable rolled log was hidden or prevented other evidence from being collected.'
    $script:WsusFixtureDirectory = Join-Path $fixtureRoot 'missing'
    $collected = & $Phase11WsusStallCollector
    Assert-True ($collected['_collector-diag.txt'] -match 'WSUS log enumeration failed') 'A missing WSUS log directory was silently ignored.'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
    }
}

Write-Host 'PASS -- WSUS recovery preserves active replacements; native failures collect current/rolled logs from site/SUP/upstream paths with verified host persistence and bounded transfer.'
