<#
.SYNOPSIS
    Verifies downstream WSUS replica contract repair and bounded convergence.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) {
        throw "Expected one $Name definition, found $($functions.Count)."
    }
    return [scriptblock]::Create($functions[0].Extent.Text)
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

$functionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction -Path $functionsPath -Name 'Test-CMWsusReplicaContractMismatch')
. (Import-TestFunction -Path $functionsPath -Name 'Get-CMWsusPostinstallArguments')
. (Import-TestFunction -Path $perfloadingPath -Name 'Repair-DownstreamWsusReplicaSync')

$exactFailure = @"
SqlException: Procedure or function 'spGetUpdatesForBulkHideInReplicaSync'
expects parameter '@xmlAllUpdateIds', which was not supplied.
"@
Assert-True (Test-CMWsusReplicaContractMismatch -ErrorText $exactFailure) `
    'The live WSUS replica API/SUSDB contract failure was not recognized.'
Assert-True (-not (Test-CMWsusReplicaContractMismatch `
        -ErrorText 'SqlException: deadlock victim')) `
    'An unrelated WSUS SQL failure was misclassified as a contract mismatch.'
Assert-True (-not (Test-CMWsusReplicaContractMismatch -ErrorText '')) `
    'An empty WSUS error was misclassified as a contract mismatch.'

$widArgs = @(Get-CMWsusPostinstallArguments -SqlServerName 'MICROSOFT##WID' `
        -ContentPath 'E:\WSUS')
Assert-Equal 'postinstall,CONTENT_DIR=E:\WSUS' ($widArgs -join ',') `
    'WID postinstall arguments incorrectly included SQL_INSTANCE_NAME.'

$sqlArgs = @(Get-CMWsusPostinstallArguments -SqlServerName 'SQL1,5422' `
        -ContentPath 'E:\WSUS')
Assert-Equal 'postinstall,SQL_INSTANCE_NAME=SQL1,5422,CONTENT_DIR=E:\WSUS' `
    ($sqlArgs -join ',') `
    'SQL-backed WSUS postinstall arguments lost the SQL target or content path.'

$perfloading = Get-Content -LiteralPath $perfloadingPath -Raw
$functionsText = Get-Content -LiteralPath $functionsPath -Raw
Assert-True ($functionsText -match
    '\$\{function:Get-CMWsusPostinstallArguments\}\.ToString\(\)') `
    'Remote WSUS repair does not execute the tested postinstall argument builder.'
Assert-True ($perfloading -match
    'Repair-DownstreamWsusReplicaSync -SoftwareUpdatePoints @\(\$Sups\)') `
    'Downstream replica recovery is not wired independently of product changes.'
Assert-True ($perfloading -match
    "(?s)Repair-DownstreamWsusReplicaSync.+?Invoke-CMWsusReplicaHealthCheck.+?-RepairContractMismatch") `
    'Downstream recovery does not repair the exact WSUS database contract mismatch.'
Assert-True ($perfloading -match
    "(?s)Repair-DownstreamWsusReplicaSync.+?Wait-WsusSyncCompletion.+?-TriggerFirst") `
    'Downstream recovery does not trigger and await a bounded retry.'
Assert-True ($perfloading -match
    '(?s)Repair-DownstreamWsusReplicaSync.+?\$HierarchySiteCode.+?LastSyncState.+?6702.+?Downstream replica recovery') `
    'Downstream recovery does not wait for the upstream SUP sync to complete.'
Assert-True ($perfloading -match
    'downstream WSUS replicas remained unhealthy.+?-Failure') `
    'Downstream recovery can still return success while a replica remains unhealthy.'

$script:HealthCalls = [System.Collections.Generic.List[object]]::new()
$script:SyncCalls = [System.Collections.Generic.List[object]]::new()
$script:HealthPhase = 'failed'
$isTopLevel = $false
$DomainFullName = 'lab.test'
$HierarchySiteCode = 'CAS'
$Tag = '[test]'

function Write-DscStatus {
    param([string] $Message, [switch] $Warning, [switch] $Failure)
}
function Invoke-CMWsusReplicaHealthCheck {
    param([string] $ServerFQDN, [switch] $RepairContractMismatch)

    $script:HealthCalls.Add([pscustomobject]@{
            Server = $ServerFQDN
            Repair = [bool]$RepairContractMismatch
        })
    if ($script:HealthPhase -eq 'failed') {
        $script:HealthPhase = 'recovered'
        return [pscustomobject]@{
            Server = $ServerFQDN; ProbeSucceeded = $true; WsusRunning = $false
            LastResult = 'Failed'; ContractMismatch = $true
            RepairSucceeded = $true; Detail = 'repaired'
        }
    }
    return [pscustomobject]@{
        Server = $ServerFQDN; ProbeSucceeded = $true; WsusRunning = $false
        LastResult = 'Succeeded'; ContractMismatch = $false
        RepairSucceeded = $true; Detail = 'healthy'
    }
}
function Wait-WsusSyncCompletion {
    param([string] $Label, [int] $MaxAttempts, [switch] $TriggerFirst)
    $script:SyncCalls.Add([pscustomobject]@{
            Label = $Label
            MaxAttempts = $MaxAttempts
            TriggerFirst = [bool]$TriggerFirst
        })
    return $true
}
function Get-CMSoftwareUpdateSyncStatus {
    return [pscustomobject]@{
        SiteCode = 'CAS'
        LastSyncState = 6702
        LastSyncErrorCode = 0
    }
}

$recovered = Repair-DownstreamWsusReplicaSync -SoftwareUpdatePoints @(
    [pscustomobject]@{ vmName = 'SUP1' }
)
Assert-True $recovered 'A repaired downstream replica did not converge.'
Assert-Equal 2 $script:HealthCalls.Count `
    'Downstream recovery did not perform initial and post-sync health checks.'
Assert-Equal $true $script:HealthCalls[0].Repair `
    'Initial downstream health check did not enable contract repair.'
Assert-Equal $false $script:HealthCalls[1].Repair `
    'Post-sync health verification attempted another destructive repair.'
Assert-Equal 'SUP1.lab.test' $script:HealthCalls[0].Server `
    'Downstream recovery did not use the SUP FQDN.'
Assert-Equal 1 $script:SyncCalls.Count `
    'Downstream recovery did not trigger exactly one bounded sync wait.'
Assert-Equal $true $script:SyncCalls[0].TriggerFirst `
    'Downstream recovery did not trigger a fresh sync before waiting.'
Assert-Equal 40 $script:SyncCalls[0].MaxAttempts `
    'Downstream recovery lost its bounded 20-minute retry budget.'

Write-Host 'PASS -- downstream WSUS replicas repair schema drift and converge before Phase 8 succeeds.'
