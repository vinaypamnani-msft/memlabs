#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$failures = [Collections.Generic.List[string]]::new()

function Assert-Diagnostic {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "PASS  $What" }
    else { Write-Host "FAIL  $What"; $failures.Add($What) }
}

function Get-AssignedScriptBlock {
    param([Management.Automation.Language.Ast]$Ast, [string]$VariableName)
    $assignment = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq $VariableName -and
                $node.Right.Extent.Text.TrimStart().StartsWith('{')
            }, $true))
    if ($assignment.Count -ne 1) { throw "Expected one '$VariableName' scriptblock, found $($assignment.Count)" }
    return [scriptblock]::Create($assignment[0].Right.Extent.Text).InvokeReturnAsIs()
}

$scriptPath = Join-Path $RootPath 'tools\Get-SqlaoDnsDiag.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-Diagnostic ($parseErrors.Count -eq 0) 'diagnostic script parses'

$source = Get-Content -LiteralPath $scriptPath -Raw
Assert-Diagnostic ($source -match '\$possible\s*=\s*\$resource\s*\|\s*Get-ClusterOwnerNode') 'collector records AG resource possible owners'
Assert-Diagnostic ($source -match '\$preferred\s*=\s*\$group\s*\|\s*Get-ClusterOwnerNode') 'collector records clustered-role preferred owners'
Assert-Diagnostic ($source -match '\$ownerOutcomeScript' -and
    -not ($source -match "cannot run on local node")) 'collector classifies SQL-managed owners by current primary and failover mode'
Assert-Diagnostic ($source -match "ResourceType -eq 'SQL Server Availability Group'") 'collector captures only SQL AG cluster resources for owner classification'
Assert-Diagnostic ($source -match 'Get-ClusterQuorum') 'collector records current quorum mode and witness'
Assert-Diagnostic ($source -match '(?s)foreach \(\$resource in \$allRes\).+?Get-ClusterParameter') 'collector records private parameters for every cluster resource'
Assert-Diagnostic ($source -match 'Get-ClusterLog -Node \$env:COMPUTERNAME') 'collector requests only the local node cluster log'
Assert-Diagnostic ($source -match '(?s)finally\s*\{.+?Remove-Item -LiteralPath \$clusterLogDir') 'collector always cleans its dedicated cluster-log directory'
Assert-Diagnostic ($source -match 'sys\.dm_hadr_availability_replica_states') 'collector queries replica runtime state'
Assert-Diagnostic ($source -match 'sys\.dm_hadr_database_replica_cluster_states') 'collector queries database failover readiness'
Assert-Diagnostic ($source -match 'sys\.database_mirroring_endpoints') 'collector queries HADR endpoint state'
Assert-Diagnostic ($source -match 'sys\.server_event_sessions' -and $source -match 'sys\.dm_xe_sessions') 'collector distinguishes configured and running AlwaysOn_health state'
Assert-Diagnostic ($source -match 'configured\.name = running\.name' -and
    $source -match 'running\.address = target\.event_session_address') 'AlwaysOn_health query uses configured-to-running-to-target joins'
Assert-Diagnostic ($source -match 'ErrorLogFileName' -and $source -match 'last_connect_error_number') 'collector captures SQL error and last-connect evidence'
Assert-Diagnostic ($source -match 'Test-TcpFast' -and $source -match '\$EndpointPort' -and $source -match '\$ListenerPort') 'collector probes endpoint and listener TCP paths'
Assert-Diagnostic ($source -match 'FINDINGS SUMMARY' -and $source -match 'Compress-Archive') 'collector emits a summary and shareable archive'
Assert-Diagnostic ($source -match "MANUAL failover; powering off the primary will not automatically promote") 'collector explains manual failover behavior'
Assert-Diagnostic ($source -match 'No SQL availability group is configured' -and
    $source -match 'No availability replicas are configured' -and
    $source -match 'No availability-group listener Network Name was discovered') 'collector reports missing AG, replicas, and listener'
Assert-Diagnostic ($source -match 'Listener TCP.+?is unreachable') 'collector promotes failed listener TCP to a finding'
Assert-Diagnostic ($source -match 'GetHostAddresses\(\$listener\)' -and $source -match 'foreach \(\$listenerAddress in \$listenerAddresses\)') 'collector probes every multi-subnet listener provider address'
Assert-Diagnostic ($source.Contains('SQL probe ''$Label'' failed')) 'collector isolates SQL probe failures'

$ownerOutcome = Get-AssignedScriptBlock -Ast $ast -VariableName 'ownerOutcomeScript'
$script:OwnerFindings = [Collections.Generic.List[string]]::new()
$script:OwnerMessages = [Collections.Generic.List[string]]::new()
function W { param($t); $script:OwnerMessages.Add([string]$t) }
function F { param($t); $script:OwnerFindings.Add([string]$t) }
$manualReplicas = @(
    [pscustomobject]@{ GroupName = 'AG'; replica_server_name = 'SQL1'; failover_mode_desc = 'MANUAL' },
    [pscustomobject]@{ GroupName = 'AG'; replica_server_name = 'SQL2'; failover_mode_desc = 'MANUAL' }
)
$manualPolicy = [pscustomobject]@{
    GroupName = 'AG'
    GroupOwner = 'SQL1'
    ResourceName = 'AG'
    ResourceState = 'Online'
    PossibleOwners = @('SQL1')
}
& $ownerOutcome -Policies @($manualPolicy) -ReplicaRows $manualReplicas
Assert-Diagnostic ($script:OwnerFindings.Count -eq 0 -and
    ($script:OwnerMessages -join ' ') -match 'MANUAL secondary') 'collector accepts SQL-managed singleton owner for MANUAL secondary'

$script:OwnerFindings.Clear(); $script:OwnerMessages.Clear()
$missingCurrent = $manualPolicy.PSObject.Copy()
$missingCurrent.PossibleOwners = @('SQL2')
& $ownerOutcome -Policies @($missingCurrent) -ReplicaRows $manualReplicas
Assert-Diagnostic ($script:OwnerFindings.Count -eq 1 -and
    $script:OwnerFindings[0] -match 'current group owner') 'collector rejects current primary missing from possible owners'

$script:OwnerFindings.Clear(); $script:OwnerMessages.Clear()
$automaticReplicas = @(
    [pscustomobject]@{ GroupName = 'AG'; replica_server_name = 'SQL1'; failover_mode_desc = 'AUTOMATIC' },
    [pscustomobject]@{ GroupName = 'AG'; replica_server_name = 'SQL2'; failover_mode_desc = 'AUTOMATIC' }
)
& $ownerOutcome -Policies @($manualPolicy) -ReplicaRows $automaticReplicas
Assert-Diagnostic ($script:OwnerFindings.Count -eq 1 -and
    $script:OwnerFindings[0] -match 'AUTOMATIC replica') 'collector reports missing automatic-failover owner'

$script:OwnerFindings.Clear(); $script:OwnerMessages.Clear()
$automaticPolicy = $manualPolicy.PSObject.Copy()
$automaticPolicy.PossibleOwners = @('SQL1', 'SQL2')
& $ownerOutcome -Policies @($automaticPolicy) -ReplicaRows $automaticReplicas
Assert-Diagnostic ($script:OwnerFindings.Count -eq 0) 'collector accepts both automatic-failover owners'

$script:OwnerFindings.Clear(); $script:OwnerMessages.Clear()
$unrelatedPolicy = [pscustomobject]@{
    GroupName = 'User Manager Group'
    GroupOwner = 'SQL2'
    ResourceName = 'User Manager Group'
    ResourceState = 'Offline'
    PossibleOwners = @()
}
& $ownerOutcome -Policies @($manualPolicy, $unrelatedPolicy) -ReplicaRows $manualReplicas
Assert-Diagnostic ($script:OwnerFindings.Count -eq 0) 'collector ignores unrelated clustered-role policies'

$script:OwnerFindings.Clear(); $script:OwnerMessages.Clear()
& $ownerOutcome -Policies @() -ReplicaRows $manualReplicas
Assert-Diagnostic ($script:OwnerFindings.Count -eq 1 -and
    $script:OwnerFindings[0] -match 'no matching WSFC') 'collector fails when SQL AG has no matching WSFC AG resource'

$script:OwnerFindings.Clear(); $script:OwnerMessages.Clear()
& $ownerOutcome -Policies @($manualPolicy, $manualPolicy.PSObject.Copy()) -ReplicaRows $manualReplicas
Assert-Diagnostic ($script:OwnerFindings.Count -eq 1 -and
    $script:OwnerFindings[0] -match 'expected exactly one') 'collector rejects ambiguous SQL-to-WSFC AG correlation'

foreach ($unsafePattern in @(
        'Set-ClusterOwnerNode',
        'Move-ClusterGroup',
        'Start-ClusterGroup',
        'Stop-ClusterGroup',
        'ALTER\s+AVAILABILITY\s+GROUP',
        'FORCE_FAILOVER',
        'Restart-Service'
    )) {
    Assert-Diagnostic (-not ($source -match $unsafePattern)) "collector remains read-only: no $unsafePattern"
}

$probeFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SqlProbe'
        }, $true))
Assert-Diagnostic ($probeFunction.Count -eq 1) 'collector defines one isolated SQL probe helper'
if ($probeFunction.Count -eq 1) {
    $probeScript = $probeFunction[0].Body.GetScriptBlock()
    $script:ProbeCalls = [Collections.Generic.List[string]]::new()
    $script:ProbeFindings = [Collections.Generic.List[string]]::new()
    function Invoke-Q {
        param($Query)
        $script:ProbeCalls.Add([string]$Query)
        if ($Query -eq 'FAIL') { throw 'injected query failure' }
        $table = New-Object Data.DataTable
        $null = $table.Columns.Add('Value', [string])
        $row = $table.NewRow()
        $row.Value = 'ok'
        $table.Rows.Add($row)
        return , $table
    }
    function F { param($t); $script:ProbeFindings.Add([string]$t) }
    $failedProbe = & $probeScript -Label 'middle' -Query 'FAIL'
    $laterProbe = & $probeScript -Label 'later' -Query 'PASS'
    Assert-Diagnostic ($null -eq $failedProbe -and $script:ProbeFindings.Count -eq 1) 'failed SQL probe records a finding without throwing'
    Assert-Diagnostic ($laterProbe.Rows.Count -eq 1 -and ($script:ProbeCalls -join ',') -eq 'FAIL,PASS') 'later SQL probe still runs after an earlier failure'
}

$listenerProbe = Get-AssignedScriptBlock -Ast $ast -VariableName 'listenerProbeScript'
$script:TcpResults = @{}
$script:TcpCalls = [Collections.Generic.List[string]]::new()
$script:ProbeFindings = [Collections.Generic.List[string]]::new()
function Test-TcpFast {
    param($ComputerName, $Port)
    $script:TcpCalls.Add([string]$ComputerName)
    return [bool]$script:TcpResults[[string]$ComputerName]
}
function W {}
function F { param($t); $script:ProbeFindings.Add([string]$t) }

$script:TcpResults = @{ '10.0.1.202' = $false; '10.0.2.202' = $true }
$script:TcpCalls.Clear(); $script:ProbeFindings.Clear()
& $listenerProbe -Listener 'LISTENER' -Port 1500 -ResolvedAddresses @('10.0.1.202', '10.0.2.202')
Assert-Diagnostic (($script:TcpCalls -join ',') -eq '10.0.1.202,10.0.2.202' -and $script:ProbeFindings.Count -eq 0) 'listener probe accepts a reachable second provider after the first fails'

$script:TcpResults = @{ '10.0.1.202' = $false; '10.0.2.202' = $false }
$script:TcpCalls.Clear(); $script:ProbeFindings.Clear()
& $listenerProbe -Listener 'LISTENER' -Port 1500 -ResolvedAddresses @('10.0.1.202', '10.0.2.202')
Assert-Diagnostic ($script:TcpCalls.Count -eq 2 -and $script:ProbeFindings.Count -eq 1 -and
    $script:ProbeFindings[0] -match 'every provider') 'listener probe fails only after every provider is unreachable'

$script:TcpCalls.Clear(); $script:ProbeFindings.Clear()
& $listenerProbe -Listener 'LISTENER' -Port 1500 -ResolvedAddresses @()
Assert-Diagnostic ($script:TcpCalls.Count -eq 0 -and $script:ProbeFindings.Count -eq 1 -and
    $script:ProbeFindings[0] -match 'no IPv4') 'listener probe reports zero IPv4 providers distinctly'

$xeOutcome = Get-AssignedScriptBlock -Ast $ast -VariableName 'xeOutcomeScript'
$script:ProbeFindings.Clear()
& $xeOutcome -Rows @() -SqlTarget 'localhost'
Assert-Diagnostic ($script:ProbeFindings.Count -eq 1 -and $script:ProbeFindings[0] -match 'not defined') 'XE classifier distinguishes absent session'
$script:ProbeFindings.Clear()
& $xeOutcome -Rows @([pscustomobject]@{ SessionState = 'STOPPED'; target_name = $null }) -SqlTarget 'localhost'
Assert-Diagnostic ($script:ProbeFindings.Count -eq 1 -and $script:ProbeFindings[0] -match 'stopped') 'XE classifier distinguishes stopped session'
$script:ProbeFindings.Clear()
& $xeOutcome -Rows @([pscustomobject]@{ SessionState = 'STARTED'; target_name = $null }) -SqlTarget 'localhost'
Assert-Diagnostic ($script:ProbeFindings.Count -eq 1 -and $script:ProbeFindings[0] -match 'without an active target') 'XE classifier distinguishes missing target'
$xeDataTable = [Data.DataTable]::new()
$null = $xeDataTable.Columns.Add('SessionState', [string])
$null = $xeDataTable.Columns.Add('target_name', [string])
$xeDataRow = $xeDataTable.NewRow()
$xeDataRow.SessionState = 'STARTED'
$xeDataTable.Rows.Add($xeDataRow)
$script:ProbeFindings.Clear()
& $xeOutcome -Rows $xeDataTable.Rows -SqlTarget 'localhost'
Assert-Diagnostic ($script:ProbeFindings.Count -eq 1 -and $script:ProbeFindings[0] -match 'without an active target') 'XE classifier treats DataTable DBNull target as missing'
$script:ProbeFindings.Clear()
& $xeOutcome -Rows @([pscustomobject]@{ SessionState = 'STARTED'; target_name = 'event_file' }) -SqlTarget 'localhost'
Assert-Diagnostic ($script:ProbeFindings.Count -eq 0) 'XE classifier accepts started session with target'

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO health diagnostic assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO health diagnostic tests passed.'
