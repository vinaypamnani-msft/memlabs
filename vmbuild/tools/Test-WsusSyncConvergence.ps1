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
    $node = $perfAst.Find({
        param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$DomainFullName = 'lab.test'; $SiteCode = 'CAS'; $Tag = '[test]'
$Sups = @([pscustomobject]@{ vmName = 'REMOTE-SUP' })
$CMInstallDir = $env:TEMP
$script:ProbeSucceeded = $true; $script:NativeRunning = $false
$script:NativeResult = 'Succeeded'; $script:CmState = 6702
$script:RepairCalls = 0; $script:SyncDrops = 0; $script:SiteRestarts = 0
$script:ProbeTargets = @()
function Write-DscStatus { param($Message, [switch] $Warning, [switch] $Failure) }
function Start-Sleep { param($Seconds) }
function Write-WsusDiagnostics { param($Reason) }
function Get-CMSoftwareUpdateSyncStatus {
    [pscustomobject]@{ SiteCode = 'CAS'; LastSyncState = $script:CmState; LastSyncStateTime = Get-Date }
}
function Invoke-CMWsusReplicaHealthCheck {
    param($ServerFQDN)
    $script:ProbeTargets += $ServerFQDN
    $failedOtherSup = $ServerFQDN -eq 'FAILED-SUP.lab.test'
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
function Wait-WsusSyncCompletion {
    param($Label, $MaxAttempts, [switch] $TriggerFirst)
    $script:FinalWaitCalls++
    Assert-True ($MaxAttempts -eq 40 -and $TriggerFirst) 'Final recovery lost its bounded retry contract.'
    return $script:FinalRecovered
}
$script:FinalRecovered = $false
$finalError = $null
try { Confirm-MemLabsWsusSyncHealth } catch { $finalError = $_.Exception.Message }
Assert-True ($finalError -match 'did not recover') 'Exhausted final recovery did not fail Phase 8.'
$script:FinalRecovered = $true
Confirm-MemLabsWsusSyncHealth
Assert-True ($script:FinalWaitCalls -eq 2) 'Final recovery was not invoked for failed native sync.'
$script:NativeRunning = $true
Confirm-MemLabsWsusSyncHealth
Assert-True ($script:FinalWaitCalls -eq 2) 'Healthy background synchronization was unnecessarily awaited.'
$Sups += [pscustomobject]@{ vmName = 'FAILED-SUP' }
$mixed = Get-WsusSyncLiveness
Assert-True ($mixed.WsusRunning -and $mixed.HasFailedIdleSync) 'An active SUP masked another SUP with an idle failed synchronization.'
Confirm-MemLabsWsusSyncHealth
Assert-True ($script:FinalWaitCalls -eq 3) 'Mixed active/failed SUP health bypassed final recovery.'
$Sups = @()
$empty = Get-WsusSyncLiveness
Assert-True (-not $empty.ProbeSucceeded) 'An empty SUP scope was treated as measured success.'

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
}
'@
$supScript = [scriptblock]::Create($block.ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}').Replace(
    '[Microsoft.UpdateServices.Administration.AdminProxy]', '[MemLabs.WsusValidationTestProxy]'))
$subscription = [pscustomobject]@{ Result = 'Failed'; State = 'NotProcessing' }
$subscription | Add-Member ScriptMethod GetLastSynchronizationInfo {
    [pscustomobject]@{ Result = $this.Result; Error = 'Unknown'; StartTime = 'start'; EndTime = 'end'; ErrorText = 'fixture failure' }
}
$subscription | Add-Member ScriptMethod GetSynchronizationStatus { $this.State }
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
Write-Host 'PASS -- remote SUP recovery preserves active syncs and failed/canceled/unreadable sync health fails closed.'
