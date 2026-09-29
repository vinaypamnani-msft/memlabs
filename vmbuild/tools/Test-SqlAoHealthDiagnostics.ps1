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

$scriptPath = Join-Path $RootPath 'tools\Get-SqlaoDnsDiag.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-Diagnostic ($parseErrors.Count -eq 0) 'diagnostic script parses'

$source = Get-Content -LiteralPath $scriptPath -Raw
Assert-Diagnostic ($source -match '\$possible\s*=\s*\$resource\s*\|\s*Get-ClusterOwnerNode') 'collector records AG resource possible owners'
Assert-Diagnostic ($source -match '\$preferred\s*=\s*\$group\s*\|\s*Get-ClusterOwnerNode') 'collector records clustered-role preferred owners'
Assert-Diagnostic ($source -match 'Get-ClusterQuorum') 'collector records current quorum mode and witness'
Assert-Diagnostic ($source -match '(?s)foreach \(\$resource in \$allRes\).+?Get-ClusterParameter') 'collector records private parameters for every cluster resource'
Assert-Diagnostic ($source -match 'Get-ClusterLog -Node \$env:COMPUTERNAME') 'collector requests only the local node cluster log'
Assert-Diagnostic ($source -match '(?s)finally\s*\{.+?Remove-Item -LiteralPath \$clusterLogDir') 'collector always cleans its dedicated cluster-log directory'
Assert-Diagnostic ($source -match 'sys\.dm_hadr_availability_replica_states') 'collector queries replica runtime state'
Assert-Diagnostic ($source -match 'sys\.dm_hadr_database_replica_cluster_states') 'collector queries database failover readiness'
Assert-Diagnostic ($source -match 'sys\.database_mirroring_endpoints') 'collector queries HADR endpoint state'
Assert-Diagnostic ($source -match 'AlwaysOn_health') 'collector records the AlwaysOn_health event target'
Assert-Diagnostic ($source -match 'ErrorLogFileName' -and $source -match 'last_connect_error_number') 'collector captures SQL error and last-connect evidence'
Assert-Diagnostic ($source -match 'Test-TcpFast' -and $source -match '\$EndpointPort' -and $source -match '\$ListenerPort') 'collector probes endpoint and listener TCP paths'
Assert-Diagnostic ($source -match 'FINDINGS SUMMARY' -and $source -match 'Compress-Archive') 'collector emits a summary and shareable archive'
Assert-Diagnostic ($source -match "MANUAL failover; powering off the primary will not automatically promote") 'collector explains manual failover behavior'
Assert-Diagnostic ($source -match 'No SQL availability group is configured' -and
    $source -match 'No availability replicas are configured' -and
    $source -match 'No availability-group listener Network Name was discovered') 'collector reports missing AG, replicas, and listener'
Assert-Diagnostic ($source -match 'Listener TCP.+?is unreachable') 'collector promotes failed listener TCP to a finding'
Assert-Diagnostic ($source.Contains('SQL probe ''$Label'' failed')) 'collector isolates SQL probe failures'

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

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO health diagnostic assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO health diagnostic tests passed.'
