#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installPath = Join-Path $root 'DSC\phases\InstallAndUpdateSCCM.ps1'
$phase4Path = Join-Path $root 'DSC\phases\Phase4.ps1'
$validationPath = Join-Path $root 'common\Common.Validation.Functional.ps1'
$hierarchyPath = Join-Path $root 'DSC\phases\InstallPSForHierarchy.ps1'

function Get-TestAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    return $ast
}
function Import-TestFunction {
    param($Ast, [string]$Name)
    $definitions = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$ast = Get-TestAst $installPath
$helperAst = Get-TestAst (Join-Path $root 'DSC\phases\ScriptFunctions.ps1')
foreach ($name in @('New-SqlAoNodeConnectionString', 'Invoke-SqlAoCommand', 'Set-SqlAoLabMaxDop')) {
    . (Import-TestFunction -Ast $helperAst -Name $name)
}
$script:Statuses = [Collections.Generic.List[object]]::new()
function Write-DscStatus {
    param($Status, [switch]$Failure)
    $script:Statuses.Add([pscustomobject]@{ Message = "$Status"; Failure = [bool]$Failure })
}
$script:Commands = [Collections.Generic.List[object]]::new()
$script:Node1Throws = $false
$script:Node2Value = 1
$commandHook = {
    param($ConnectionString, $CommandText, $TimeoutSeconds, $Scalar)
    $script:Commands.Add([pscustomobject]@{
            Connection = $ConnectionString; Query = $CommandText
            Timeout = $TimeoutSeconds; Scalar = $Scalar
        })
    if ($ConnectionString -match 'Server=NODE1(?:,|;)' -and $script:Node1Throws) {
        throw 'Synthetic NODE1 SQL failure'
    }
    if ($ConnectionString -match 'Server=NODE2(?:,|;)') { return $script:Node2Value }
    return 1
}
$parameters = @{
    Node1 = 'NODE1'; Node2 = 'NODE2'; Node1Port = '4890'; Node2Port = '4891'
    TestHooks = @{ Command = $commandHook }
}
Assert-True (Set-SqlAoLabMaxDop @parameters) 'Healthy SQLAO MAXDOP reconciliation failed.'
Assert-True ($script:Commands.Count -eq 2 -and
    $script:Commands[0].Connection -match 'Server=NODE1,4890;' -and
    $script:Commands[1].Connection -match 'Server=NODE2,4891;') `
    'MAXDOP was not applied directly to both physical replicas on their own SQL ports.'
Assert-True (@($script:Commands | Where-Object { $_.Timeout -ne 60 -or -not $_.Scalar }).Count -eq 0) `
    'MAXDOP reconciliation lost its query timeout or effective-value readback.'
Assert-True (@($script:Statuses | Where-Object Failure).Count -eq 0 -and $script:Statuses.Count -eq 2) `
    'Both replica successes were not reported.'
$query = $script:Commands[0].Query
Assert-True ($query -match "CONVERT\(int, value\) = 1 AND CONVERT\(int, value_in_use\) = 1" -and
    $query -match "EXEC sys\.sp_configure N'max degree of parallelism', 1" -and
    $query -match "SELECT CONVERT\(int, value_in_use\)") `
    'The SQL batch does not enforce and verify configured plus effective MAXDOP.'
Assert-True ($query -match '(?s)IF NOT EXISTS.+?BEGIN.+?BEGIN TRY.+?show advanced options.+?END TRY.+?BEGIN CATCH' -and
    ([regex]::Matches($query, "EXEC sys\.sp_configure N'show advanced options', 0")).Count -eq 2 -and
    $query.Contains('@originalError') -and $query.Contains('@combinedError')) `
    'Advanced-options visibility or an original SQL failure can be lost during cleanup.'
Assert-True ((New-SqlAoNodeConnectionString -Server NODE1 -Port 1433) -match 'Server=NODE1;') `
    'The existing physical-node default-port connection behavior changed.'

$script:Node1Throws = $true
$script:Commands.Clear()
$script:Statuses.Clear()
Assert-True (-not (Set-SqlAoLabMaxDop @parameters)) 'A failed replica was treated as configured.'
Assert-True ($script:Commands.Count -eq 2 -and @($script:Statuses | Where-Object Failure).Count -eq 1 -and
    @($script:Statuses | Where-Object { $_.Message -match 'Synthetic NODE1 SQL failure' }).Count -eq 1) `
    'One replica failure prevented verification of the other, or lost its original SQL error.'
$script:Node1Throws = $false
foreach ($value in @(8, $null)) {
    $script:Node2Value = $value
    $script:Statuses.Clear()
    Assert-True (-not (Set-SqlAoLabMaxDop @parameters)) 'A wrong or absent effective MAXDOP was accepted.'
    Assert-True (@($script:Statuses | Where-Object Failure).Count -eq 1) 'Verification failure was not surfaced explicitly.'
}
$script:Statuses.Clear()
$script:Commands.Clear()
Assert-True (Set-SqlAoLabMaxDop -Node1 NODE1 -Node1Port 1433 -TestHooks @{ Command = $commandHook }) `
    'A retained single-node SQLAO instance could not be reconciled.'
Assert-True ($script:Commands.Count -eq 1 -and @($script:Statuses | Where-Object Failure).Count -eq 0) `
    'Single-node SQLAO reconciliation attempted an absent partner or reported failure.'
Assert-True (-not (Set-SqlAoLabMaxDop -Node1 NODE1 -Node1Port 1433 -Node2 NODE2 -TestHooks @{ Command = $commandHook })) `
    'A configured partner without a physical SQL port was silently ignored.'

$phase4 = Get-Content -LiteralPath $phase4Path -Raw
$resource = [regex]::Match($phase4, '(?s)if \(\$ThisVM\.role -eq ''SQLAO''\)\s*\{\s*SqlMaxDop SetSqlAoMaxDop\s*\{(?<Body>.*?)\}')
Assert-True $resource.Success 'Initial MAXDOP configuration is not scoped exclusively to SQLAO nodes.'
foreach ($required in @('MaxDop\s*=\s*1', 'DynamicAlloc\s*=\s*\$false', 'ProcessOnlyOnActiveNode\s*=\s*\$false', 'InstanceName\s*=\s*\$SQLInstanceName')) {
    Assert-True ($resource.Groups['Body'].Value -match $required) "The SQLAO DSC resource is missing $required."
}
Assert-True ($phase4 -match '(?s)GrantSqlInstantFileInit\s*\{\s*DependsOn\s*=\s*\$sqlPostMemoryDependency') `
    'Later SQL work is not ordered after SQLAO MAXDOP configuration.'
$phase8 = Get-Content -LiteralPath (Join-Path $root 'DSC\phases\Phase8.ps1') -Raw
Assert-True ($phase8 -match '(?s)if \(\$ThisVM\.role -eq ''SQLAO''\).{0,200}SqlMaxDop SetSqlAoMaxDop' -and
    $phase8 -match '\$nextDepend = ''\[SqlMaxDop\]SetSqlAoMaxDop''') `
    'Phase 8 retained SQLAO nodes do not reconcile MAXDOP before completing.'
$policyCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-SqlAoLabMaxDop'
        }, $true))
Assert-True ($policyCalls.Count -eq 3) 'Expected one re-entry policy gate plus a recheck after each setup attempt.'
$runningGuard = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$Configuration.InstallSCCM.Status -eq ''Running'''
    }, $true)
Assert-True ($runningGuard -and $policyCalls[0].Extent.StartOffset -lt $runningGuard.Extent.StartOffset) `
    'Checkpoint/re-entry guards can return before reconciling both SQLAO replicas.'
$installText = Get-Content -LiteralPath $installPath -Raw
Assert-True ($policyCalls[0].Extent.StartOffset -lt $installText.IndexOf('Invoke-SqlSetupCanary -ConnectionString')) `
    'The storage-engine canary can run before SQLAO serial execution is enforced.'
foreach ($call in $policyCalls) {
    $parent = $call.Parent
    $sqlAoGuarded = $false
    while ($parent) {
        if ($parent -is [Management.Automation.Language.IfStatementAst] -and
            $parent.Clauses[0].Item1.Extent.Text -match '\$installToAO\b') {
            $sqlAoGuarded = $true
            break
        }
        $parent = $parent.Parent
    }
    Assert-True $sqlAoGuarded `
        'A MAXDOP policy call can alter standalone SQL instances.'
}
Assert-True ($installText -match '\$installToAO\s*=\s*\$false') 'A reused workflow scope can retain a stale SQLAO target flag.'
$hierarchyAst = Get-TestAst $hierarchyPath
$hierarchyCalls = @($hierarchyAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-SqlAoLabMaxDop'
        }, $true))
Assert-True ($hierarchyCalls.Count -eq 2) 'Hierarchy-primary setup is not covered before and after setup.exe.'
$hierarchyText = Get-Content -LiteralPath $hierarchyPath -Raw
Assert-True ($hierarchyCalls[0].Extent.StartOffset -lt $hierarchyText.IndexOf('# Set Install action as Running') -and
    $hierarchyText -match '(?s)Start-Process.+?-wait\s+if \(\$installToAO -and -not \(Set-SqlAoLabMaxDop' -and
    $hierarchyText -match 'Node2Port = \$\(if \(\$sqlNode2Vm.sqlPort\)') `
    'Hierarchy re-entry/setup ordering or physical partner-port selection is not preserved.'

$validationAst = Get-TestAst $validationPath
$branches = @($validationAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$checkAgent -eq ''1'' -and $results.Passed' -and
            $node.Extent.Text.Contains('ConfiguredMaxDop')
        }, $true))
Assert-True ($branches.Count -eq 1) 'The SQLAO-only validation gate was not found.'
$validate = [scriptblock]::Create(
    'param($checkAgent, $results, $connStr, $sqlParams)' + [Environment]::NewLine +
    $branches[0].Extent.Text + [Environment]::NewLine + 'return $results')
$script:ReadFails = $false
$script:ReadCalls = 0
$script:ReadRows = @([pscustomobject]@{ ConfiguredMaxDop = 1; EffectiveMaxDop = 1 })
function Invoke-Sqlcmd {
    param($ServerInstance, $Query, $QueryTimeout, $ErrorAction)
    $script:ReadCalls++
    if ($script:ReadFails) { throw 'Synthetic MAXDOP read failure' }
    Assert-True ($ServerInstance -eq 'localhost,4891' -and $QueryTimeout -eq 30) `
        'Validation did not use the local physical instance and a bounded query.'
    return $script:ReadRows
}
function Invoke-FixtureValidation {
    param([string]$SqlAo = '1')
    & $validate $SqlAo @{ Passed = $true; Details = [Collections.Generic.List[string]]::new() } 'localhost,4891' @{}
}
Assert-True (Invoke-FixtureValidation).Passed 'Correct SQLAO MAXDOP failed validation.'
foreach ($rows in @(
        @([pscustomobject]@{ ConfiguredMaxDop = 8; EffectiveMaxDop = 1 }),
        @([pscustomobject]@{ ConfiguredMaxDop = 1; EffectiveMaxDop = 8 })
    )) {
    $script:ReadRows = $rows
    Assert-True (-not (Invoke-FixtureValidation).Passed) 'MAXDOP drift passed final validation.'
}
$script:ReadRows = @()
Assert-True (-not (Invoke-FixtureValidation).Passed) 'Missing MAXDOP state passed final validation.'
$script:ReadFails = $true
Assert-True (-not (Invoke-FixtureValidation).Passed) 'Unreadable MAXDOP state passed final validation.'
$script:ReadCalls = 0
Assert-True (Invoke-FixtureValidation -SqlAo '0').Passed 'Standalone SQL validation was changed.'
Assert-True ($script:ReadCalls -eq 0) 'Standalone SQL was subjected to the SQLAO MAXDOP policy.'

Write-Host 'PASS -- MAXDOP=1 is enforced and verified on both SQLAO instances, re-entry/setup paths, and final validation only.'
