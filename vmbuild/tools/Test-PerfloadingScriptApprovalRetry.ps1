<#
.SYNOPSIS
    Verifies that a transient ConfigMgr provider deadlock does not leave a script unapproved.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$perfloadingPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\perfloading.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($perfloadingPath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "perfloading.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$approvalFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Approve-MemLabsScriptQueue'
        }, $true))
if ($approvalFunctions.Count -ne 1) {
    throw "Expected one Approve-MemLabsScriptQueue function; found $($approvalFunctions.Count)."
}
Invoke-Expression $approvalFunctions[0].Extent.Text

$script:ApprovalCalls = 0
$script:Approved = $false
$script:CommitOnFailure = $false
$script:Sleeps = 0
$script:StatusMessages = [System.Collections.Generic.List[object]]::new()
$Tag = '[perfloading]'

function Approve-CMScript {
    param([string] $ScriptGuid, [string] $Comment, $ErrorAction)
    $script:ApprovalCalls++
    if ($script:ApprovalCalls -eq 1) {
        if ($script:CommitOnFailure) { $script:Approved = $true }
        throw 'SQLStatus 1205: transaction was deadlocked on lock resources'
    }
    $script:Approved = $true
}

function Get-CMScript {
    param([string] $ScriptName, [switch] $Fast, $ErrorAction)
    [pscustomobject]@{ ApprovalState = if ($script:Approved) { 3 } else { 0 } }
}

function Get-CmProviderError {
    param($ErrorRecord)
    return $ErrorRecord.Exception.Message
}

function Write-DscStatus {
    param([Parameter(Position = 0)] [string] $Message, [switch] $Warning)
    $script:StatusMessages.Add([pscustomobject]@{ Message = $Message; Warning = $Warning.IsPresent })
}

function Start-Sleep {
    param([int] $Seconds)
    $script:Sleeps++
}

$result = Approve-MemLabsScriptQueue -Queue @([pscustomobject]@{ Guid = 'test-guid'; Name = 'MEMLABS-Test' })

if ($result.Approved -ne 1 -or $result.Failed -ne 0 -or $result.PolicyBlocked -ne 0) {
    throw "Unexpected reconcile result: $($result | ConvertTo-Json -Compress)"
}
if ($script:ApprovalCalls -ne 2 -or $script:Sleeps -ne 1) {
    throw "Expected one deadlock retry; approval calls=$script:ApprovalCalls sleeps=$script:Sleeps."
}
if (@($script:StatusMessages | Where-Object Warning).Count -ne 0) {
    throw 'A recovered transient approval failure was logged as a warning.'
}
if (@($script:StatusMessages | Where-Object Message -like '*Transient provider failure*').Count -ne 1) {
    throw 'The transient approval retry was not logged.'
}

$script:ApprovalCalls = 0
$script:Approved = $false
$script:CommitOnFailure = $true
$script:Sleeps = 0
$script:StatusMessages.Clear()
$result = Approve-MemLabsScriptQueue -Queue @([pscustomobject]@{ Guid = 'test-guid'; Name = 'MEMLABS-Test' })

if ($result.Approved -ne 1 -or $result.Failed -ne 0 -or $script:ApprovalCalls -ne 1 -or $script:Sleeps -ne 1) {
    throw "Commit-on-error readback did not prevent a duplicate approval: result=$($result | ConvertTo-Json -Compress) calls=$script:ApprovalCalls sleeps=$script:Sleeps."
}

Write-Host 'PASS -- transient script-approval deadlocks are retried and recovered.'
