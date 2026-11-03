<#
.SYNOPSIS
    Replays formatted percentages and failed-link-only DRS recovery without a site.
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production recovery branches consume fixture variables dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Get-TestAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path parse errors: $($errors -join '; ')" }
    return $ast
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Import-TestFunction {
    param($Ast, [string]$Name)
    $definitions = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    Assert-True ($definitions.Count -eq 1) "Expected one $Name definition."
    [scriptblock]::Create($definitions[0].Extent.Text)
}

$ast = Get-TestAst (Join-Path $root 'DSC\phases\InstallAndUpdateSCCM.ps1')
. (Import-TestFunction $ast 'ConvertTo-MemLabsDrsInitializationPercent')
. (Import-TestFunction $ast 'Get-MemLabsFailedDrsLinkGroups')
. (Import-TestFunction $ast 'Invoke-MemLabsDrsGroupReinitialization')
foreach ($sample in @(
        @{ Value = '0%'; Expected = 0 },
        @{ Value = '50%'; Expected = 50 },
        @{ Value = '100%'; Expected = 100 },
        @{ Value = ' 50.5 % '; Expected = 50.5 },
        @{ Value = 50; Expected = 50 },
        @{ Value = 100.0; Expected = 100 }
    )) {
    $actual = ConvertTo-MemLabsDrsInitializationPercent -Value $sample.Value
    Assert-True ($actual -is [double] -and $actual -eq $sample.Expected) "Percentage '$($sample.Value)' was not normalized numerically."
}
foreach ($value in @($null, '', 'unknown', '-1%', '100.1%', 'NaN', '50%%')) {
    $caught = $null
    try { ConvertTo-MemLabsDrsInitializationPercent -Value $value } catch { $caught = $_ }
    Assert-True ([bool]$caught) 'An invalid percentage silently became zero/complete.'
}

& {
    $state = [pscustomobject]@{
        Table = [Data.DataTable]::new()
        ThrowQuery = $false; Disposals = 0; Commands = [Collections.Generic.List[object]]::new()
    }
    foreach ($column in @('ID', 'ReplicationGroup', 'SiteSending', 'SiteReceiving', 'LinkStatus')) {
        $type = if ($column -in 'ID', 'LinkStatus') { [int] } else { [string] }
        $null = $state.Table.Columns.Add($column, $type)
    }
    $null = $state.Table.Rows.Add([object[]]@(1, 'Replication Configuration', 'CS1', 'PS1', 6))
    $null = $state.Table.Rows.Add([object[]]@(1, 'Replication Configuration', 'PS1', 'CS1', 8))
    function New-Object {
        param($TypeName, $ArgumentList)
        Assert-True ($TypeName -eq 'System.Data.SqlClient.SqlConnection' -and
            "$ArgumentList" -match 'Connect Timeout=15') 'Failed-group selection has no bounded SQL connection.'
        $connection = [pscustomobject]@{}
        $connection | Add-Member ScriptMethod Open { }
        $connection | Add-Member ScriptMethod Dispose { $state.Disposals++ }
        $connection | Add-Member ScriptMethod CreateCommand {
            $command = [pscustomobject]@{
                CommandText = ''; CommandTimeout = 0
                Parameters = [Data.SqlClient.SqlCommand]::new().Parameters
            }
            $command | Add-Member ScriptMethod Dispose { }
            $command | Add-Member ScriptMethod ExecuteReader {
                $state.Commands.Add($this)
                if ($state.ThrowQuery) { throw 'fixture failed-link SQL query error' }
                return ,($state.Table.CreateDataReader())
            }
            return $command
        }
        return $connection
    }
    $arguments = @{ CasSqlDataSource = 'CAS_SQL'; CasDbName = 'CM_CS1'; CasSiteCode = 'CS1'; PriSiteCode = 'PS1' }
    $groups = @(Get-MemLabsFailedDrsLinkGroups @arguments)
    Assert-True ($groups.Count -eq 1 -and $groups[0].ID -eq 1 -and $groups[0].LinkStatus -eq 6) 'Failed directions were not deduplicated to one group.'
    $command = $state.Commands[0]
    Assert-True ($command.CommandTimeout -eq 30 -and
        $command.Parameters['@cas'].Value -eq 'CS1' -and $command.Parameters['@pri'].Value -eq 'PS1') 'Recovery selection lost its exact site-pair parameters or deadline.'
    Assert-True ($command.CommandText -match 'RCM_ReplicationLinkStatus' -and
        $command.CommandText -match 'links\.Status IN \(6, 8, 9\)' -and
        $command.CommandText -match 'links\.SiteSending = @cas AND links\.SiteReceiving = @pri' -and
        $command.CommandText -match 'links\.SiteSending = @pri AND links\.SiteReceiving = @cas' -and
        $command.CommandText -notmatch 'SMS_ReplicationGroup|SiteCode1|SiteCode2|\bUPDATE\b') 'Selection uses global group catalog state, unsupported WMI fields, or an unsafe query.'
    foreach ($row in @(
            @(2, 'Healthy peer', 'CS1', 'PS2', 6),
            @(2, 'Initializing', 'CS1', 'PS1', 4),
            @(2, 'Active', 'CS1', 'PS1', 2)
        )) {
        $state.Table.Rows.Clear()
        $null = $state.Table.Rows.Add([object[]]$row)
        $caught = $null
        try { Get-MemLabsFailedDrsLinkGroups @arguments } catch { $caught = $_ }
        Assert-True ($caught -and $caught.Exception.Message -match 'out-of-scope') 'Unverified/healthy peer rows were offered for reinitialization.'
    }
    $state.Table.Rows.Clear()
    Assert-True (@(Get-MemLabsFailedDrsLinkGroups @arguments).Count -eq 0) 'Empty failed-link selection became a successful recovery request.'
    $state.ThrowQuery = $true
    $caught = $null
    try { Get-MemLabsFailedDrsLinkGroups @arguments } catch { $caught = $_ }
    Assert-True ($caught -and $caught.Exception.Message -match 'fixture failed-link') 'A SQL failure became an empty-group success fallback.'
    Assert-True ($state.Disposals -eq 6) 'Failed-link SQL connections were not disposed.'
}

& {
    $state = [pscustomobject]@{ ReturnValue = 0; ExpectedTimeout = 60; Calls = [Collections.Generic.List[object]]::new() }
    function Invoke-CimMethod {
        param($Namespace, $ClassName, $MethodName, $Arguments, $OperationTimeoutSec, $ErrorAction)
        $state.Calls.Add([pscustomobject]@{ Namespace = $Namespace; Class = $ClassName; Method = $MethodName; Arguments = $Arguments })
        Assert-True ($OperationTimeoutSec -eq $state.ExpectedTimeout -and $ErrorAction -eq 'Stop') 'InitializeData has no explicit operation bound/failure semantics.'
        [pscustomobject]@{ ReturnValue = $state.ReturnValue }
    }
    $group = [pscustomobject]@{ ID = 1; ReplicationGroup = 'Replication Configuration'; SiteSending = 'CS1'; SiteReceiving = 'PS1'; LinkStatus = 6 }
    $arguments = @{ Group = $group; CasSiteCode = 'CS1'; PriSiteCode = 'PS1' }
    $request = Invoke-MemLabsDrsGroupReinitialization @arguments
    $call = $state.Calls[0]
    Assert-True ($call.Namespace -eq 'root\SMS\site_CS1' -and $call.Class -eq 'SMS_ReplicationGroup' -and
        $call.Method -eq 'InitializeData' -and $call.Arguments.ReplicationGroupID -eq 1 -and
        $call.Arguments.ReplicationGroupID -is [uint32] -and
        $call.Arguments.SiteCode1 -eq 'CS1' -and $call.Arguments.SiteCode2 -eq 'PS1' -and
        $request.ReturnValue -eq 0) 'The documented named InitializeData request or return-value contract is wrong.'
    foreach ($value in @(-1, $null, '0', $false)) {
        $state.ReturnValue = $value
        $caught = $null
        try { Invoke-MemLabsDrsGroupReinitialization @arguments } catch { $caught = $_ }
        Assert-True ([bool]$caught) 'A failed/invalid InitializeData result was treated as accepted.'
    }
    $before = $state.Calls.Count
    foreach ($candidate in @(
            [pscustomobject]@{ ID = 1; ReplicationGroup = 'Catalog-only'; Status = 6 },
            [pscustomobject]@{ ID = 1; SiteSending = 'CS1'; SiteReceiving = 'PS2'; LinkStatus = 6 },
            [pscustomobject]@{ ID = 1; SiteSending = 'CS1'; SiteReceiving = 'PS1'; LinkStatus = 2 },
            [pscustomobject]@{ ID = 1; SiteSending = 'CS1'; SiteReceiving = 'PS1'; LinkStatus = 4 }
        )) {
        $caught = $null
        try { Invoke-MemLabsDrsGroupReinitialization -Group $candidate -CasSiteCode CS1 -PriSiteCode PS1 } catch { $caught = $_ }
        Assert-True ([bool]$caught) 'Global catalog/healthy/other-peer state triggered a recovery mutation.'
    }
    Assert-True ($state.Calls.Count -eq $before) 'An unsafe group reached InitializeData.'
    $state.ReturnValue = 0
    $state.ExpectedTimeout = 5
    $null = Invoke-MemLabsDrsGroupReinitialization @arguments -OperationTimeoutSeconds 5
}

$recoveryGuards = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text.Contains('$failedMin -ge $reinitCooldownMin')
        }, $true))
Assert-True ($recoveryGuards.Count -eq 1) 'Expected one production bounded reinit gate.'
$recover = [scriptblock]::Create($recoveryGuards[0].Extent.Text)
& {
    $state = [pscustomobject]@{ QueryCalls = 0; Requests = 0; QueryFails = $false }
    function Write-DscStatus { param($Message, [switch]$Warning, $MachineName) }
    function Get-MemLabsFailedDrsLinkGroups {
        param($CasSqlDataSource, $CasDbName, $CasSiteCode, $PriSiteCode)
        $state.QueryCalls++
        if ($state.QueryFails) { throw 'fixture scoped query failure' }
        [pscustomobject]@{ ID = 1; ReplicationGroup = 'Replication Configuration'; SiteSending = 'CS1'; SiteReceiving = 'PS1'; LinkStatus = 6 }
    }
    function Invoke-MemLabsDrsGroupReinitialization {
        param($Group, $CasSiteCode, $PriSiteCode, $OperationTimeoutSeconds)
        $state.Requests++
        [pscustomobject]@{ ID = $Group.ID; SiteCode1 = $CasSiteCode; SiteCode2 = $PriSiteCode; ReturnValue = 0 }
    }
    $PSVM = [pscustomobject]@{ VmName = 'PRI1' }
    $SiteCode = 'CS1'
    $PSSiteCode = 'PS1'
    $casSqlDataSource = 'CAS_SQL'
    $casDbName = 'CM_CS1'
    $failedMin = 9
    $reinitCooldownMin = 10
    $drsStartTime = (Get-Date).AddMinutes(-10)
    $drsTimeoutSec = 7200
    $reinitAttempted = @{}
    $drsReinitHistory = @{}
    $drsLastObservation = @{ PRI1 = @{ Reinitialization = $null } }
    & $recover
    Assert-True ($state.QueryCalls -eq 0) 'Recovery fired before ten failed minutes.'
    $failedMin = 10
    & $recover
    & $recover
    Assert-True ($state.QueryCalls -eq 1 -and $state.Requests -eq 1 -and
        $drsReinitHistory.PRI1.Requests.Count -eq 1) 'Recovery was skipped, repeated every poll, or not retained in failure evidence.'
    $reinitAttempted.Clear()
    $state.QueryFails = $true
    & $recover
    Assert-True ($state.Requests -eq 1 -and $drsReinitHistory.PRI1.Error -match 'fixture scoped query failure') 'A failed query submitted a mutation or lost its diagnostic evidence.'
    $reinitAttempted.Clear()
    $state.QueryFails = $false
    $drsStartTime = (Get-Date).AddSeconds(-7201)
    & $recover
    Assert-True ($state.Requests -eq 1 -and $drsReinitHistory.PRI1.Error -match 'deadline reached') 'Recovery submitted another mutation beyond the DRS stage deadline.'
}

$gates = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text.Contains('$initializationPercent -ge 100')
        }, $true))
$complete = [scriptblock]::Create($gates[0].Clauses[0].Item1.Extent.Text)
& {
    $initializationPercent = ConvertTo-MemLabsDrsInitializationPercent -Value '50%'
    Assert-True (-not (& $complete)) '50% still takes the 100-percent recovery branch.'
    $initializationPercent = $null
    Assert-True (-not (& $complete)) 'An unmeasured percentage takes the complete branch.'
    $initializationPercent = ConvertTo-MemLabsDrsInitializationPercent -Value '100%'
    Assert-True ([bool](& $complete)) 'A measured 100% no longer enters the intended gate.'
}

Write-Host 'PASS -- DRS percentages are numeric; InitializeData is scoped to current failed groups of one site pair.'
