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
. (Import-TestFunction -Path $functionsPath -Name 'Invoke-CMRoleTargetCommand')
. (Import-TestFunction -Path $functionsPath -Name 'Test-CMWsusReplicaContractMismatch')
. (Import-TestFunction -Path $functionsPath -Name 'Get-CMWsusPostinstallArguments')
. (Import-TestFunction -Path $functionsPath -Name 'Wait-CMWsusPostinstallProgress')
. (Import-TestFunction -Path $functionsPath -Name 'Invoke-CMWsusReplicaHealthCheck')
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

$script:TransportOpenTimeout = 0
$script:TransportOperationTimeout = 0
$script:TransportCancelTimeout = 0
function Write-DscStatus {
    param([string] $Message, [switch] $Warning, [switch] $Failure)
}
function New-PSSessionOption {
    [CmdletBinding()]
    param(
        [int] $OpenTimeout,
        [int] $OperationTimeout,
        [int] $CancelTimeout
    )
    $script:TransportOpenTimeout = $OpenTimeout
    $script:TransportOperationTimeout = $OperationTimeout
    $script:TransportCancelTimeout = $CancelTimeout
    return [pscustomobject]@{
        OpenTimeout = $OpenTimeout
        OperationTimeout = $OperationTimeout
        CancelTimeout = $CancelTimeout
    }
}
function Invoke-Command {
    [CmdletBinding()]
    param(
        [string] $ComputerName,
        [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList,
        [object] $SessionOption
    )
    return [pscustomobject]@{
        Server = $ComputerName; ProbeSucceeded = $true; WsusRunning = $false
        LastResult = 'Succeeded'; LastError = ''; LastErrorText = ''
        ContractMismatch = $false; RepairAttempted = $false
        RepairSucceeded = $true; PostinstallExitCode = $null
        Detail = 'transport fixture'
    }
}

$transportState = Invoke-CMWsusReplicaHealthCheck -ServerFQDN 'SUP-REMOTE.lab.test'
Assert-True ([bool]$transportState.ProbeSucceeded) `
    'The real WSUS health wrapper did not traverse the remote transport helper.'
Assert-Equal 10000 $script:TransportOpenTimeout `
    'WSUS health check changed the bounded remote open timeout.'
Assert-Equal 300000 $script:TransportOperationTimeout `
    'WSUS health check changed the bounded live-connection test timeout.'
Assert-Equal 5000 $script:TransportCancelTimeout `
    'WSUS health check changed the bounded remote cancellation timeout.'

$overBudgetFailure = $null
try {
    $null = Invoke-CMRoleTargetCommand -ComputerName 'SUP-REMOTE.lab.test' `
        -ScriptBlock { $true } -OperationTimeoutMs 300001
}
catch { $overBudgetFailure = $_.Exception.Message }
Assert-True ($overBudgetFailure -match 'greater than the maximum allowed range of 300000') `
    'Remote role operations no longer reject a dead-connection test above five minutes.'

$monitorRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-wsus-monitor-$PID"
$progressPath = Join-Path $monitorRoot 'progress.log'
$stdoutPath = Join-Path $monitorRoot 'stdout.log'
$stderrPath = Join-Path $monitorRoot 'stderr.log'
$progressProcess = $null
$stalledProcess = $null
try {
    $null = New-Item -ItemType Directory -Path $monitorRoot -Force
    $enginePath = (Get-Process -Id $PID -ErrorAction Stop).Path
    $escapedProgressPath = $progressPath.Replace("'", "''")
    $progressCommand = "& { 1..5 | ForEach-Object { Add-Content -LiteralPath '$escapedProgressPath' -Value `$_; Start-Sleep -Milliseconds 500 } }"
    $progressEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($progressCommand))
    $progressProcess = Start-Process -FilePath $enginePath `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $progressEncoded) `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
        -WindowStyle Hidden -PassThru
    $progressResult = Wait-CMWsusPostinstallProgress -Process $progressProcess `
        -OutputPaths @($stdoutPath, $stderrPath, $progressPath) `
        -PollMilliseconds 250 -StallMilliseconds 1000
    Assert-True ($progressResult.ElapsedSeconds -ge 2 -and $progressResult.ProgressEvents -ge 2) `
        'A long-running process with continuing file progress was not allowed to finish.'

    $stallCommand = '& { Start-Sleep -Seconds 30 }'
    $stallEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stallCommand))
    $stalledProcess = Start-Process -FilePath $enginePath `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $stallEncoded) `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
        -WindowStyle Hidden -PassThru
    $stallFailure = $null
    try {
        $null = Wait-CMWsusPostinstallProgress -Process $stalledProcess `
            -OutputPaths @($stdoutPath, $stderrPath) `
            -PollMilliseconds 250 -StallMilliseconds 1000
    }
    catch { $stallFailure = $_.Exception.Message }
    Assert-True ($stallFailure -match 'made no observable progress') `
        'A process with no output, log, or I/O progress was not stopped by the stall watchdog.'
}
finally {
    foreach ($process in @($progressProcess, $stalledProcess)) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        if ($process) { $process.Dispose() }
    }
    Remove-Item -LiteralPath $monitorRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$perfloading = Get-Content -LiteralPath $perfloadingPath -Raw
$functionsText = Get-Content -LiteralPath $functionsPath -Raw
Assert-True ($functionsText -match
    '\$\{function:Get-CMWsusPostinstallArguments\}\.ToString\(\)') `
    'Remote WSUS repair does not execute the tested postinstall argument builder.'
Assert-True ($functionsText -match
    '\$\{function:Wait-CMWsusPostinstallProgress\}\.ToString\(\)') `
    'Remote WSUS repair does not execute the tested progress/stall monitor.'
Assert-True ($functionsText -notmatch 'WaitForExit\(900000\)') `
    'WSUS postinstall still has a fixed total-duration deadline.'
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
