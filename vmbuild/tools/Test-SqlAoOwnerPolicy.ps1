#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$failures = [Collections.Generic.List[string]]::new()

function Assert-OwnerPolicy {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "PASS  $What" }
    else { Write-Host "FAIL  $What"; $failures.Add($What) }
}

function Get-DscScriptProperty {
    param([string]$Path, [string]$ResourceName, [string]$PropertyName)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object {
            $_.ErrorId -notin 'ModuleNotFoundDuringParse', 'MultipleModuleEntriesFoundDuringParse'
        })
    if ($parseErrors.Count -ne 0) { throw "$Path has parse errors: $($parseErrors.Message -join '; ')" }
    $resource = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.DynamicKeywordStatementAst] -and
                $node.Extent.Text -match "^\s*Script\s+$ResourceName\s*\{"
            }, $true))
    if ($resource.Count -ne 1) { throw "Expected one Script $ResourceName resource, found $($resource.Count)" }
    $hashtable = @($resource[0].FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true))[0]
    $pair = @($hashtable.KeyValuePairs | Where-Object { $_.Item1.Value -eq $PropertyName })
    if ($pair.Count -ne 1) { throw "Expected one $PropertyName property, found $($pair.Count)" }
    $expression = @($pair[0].Item2.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
            }, $true) | Sort-Object { $_.Extent.Text.Length } -Descending)
    if ($expression.Count -lt 1) { throw "Expected a $PropertyName scriptblock, found none" }
    $text = $expression[0].ScriptBlock.Extent.Text.Trim()
    $body = $text.Substring(1, $text.Length - 2)
    $body = $body.Replace('$using:_agOwnerNodes', '$script:ExpectedOwners')
    $body = $body.Replace('$using:_agOwnerCluster', '$script:ClusterName')
    $body = $body.Replace('$using:_agOwnerResource', '$script:AgName')
    return [scriptblock]::Create($body)
}

$phase5Path = Join-Path $RootPath 'DSC\phases\Phase5.ps1'
$testScript = Get-DscScriptProperty -Path $phase5Path -ResourceName 'EnsureAgPossibleOwners' -PropertyName 'TestScript'
$setScript = Get-DscScriptProperty -Path $phase5Path -ResourceName 'EnsureAgPossibleOwners' -PropertyName 'SetScript'

$script:ExpectedOwners = @('SQLAO1', 'SQLAO2')
$script:ClusterName = 'SQLCLUSTER'
$script:AgName = 'CM Availability Group'
$script:PossibleOwners = @()
$script:PreferredOwners = @()
$script:OwnerQueryThrows = $false
$script:SetCalls = [Collections.Generic.List[object]]::new()

function Import-Module {}
function Get-ClusterOwnerNode {
    param($Cluster, $Resource, $Group, $ErrorAction)
    if ($script:OwnerQueryThrows) { throw 'injected owner query failure' }
    $owners = if ($PSBoundParameters.ContainsKey('Resource')) { $script:PossibleOwners } else { $script:PreferredOwners }
    [pscustomobject]@{
        OwnerNodes = @($owners | ForEach-Object { [pscustomobject]@{ Name = $_ } })
    }
}
function Set-ClusterOwnerNode {
    param($Cluster, $Resource, $Group, $Owners, $ErrorAction)
    $script:SetCalls.Add([pscustomobject]@{
            Cluster = $Cluster
            Resource = $Resource
            Group = $Group
            Owners = @($Owners)
        })
}

$script:PossibleOwners = @('SQLAO1', 'SQLAO2')
$script:PreferredOwners = @('SQLAO1', 'SQLAO2')
Assert-OwnerPolicy (& $testScript) 'exact possible/preferred owner sets pass'

$script:PossibleOwners = @('SQLAO2', 'SQLAO1')
$script:PreferredOwners = @('SQLAO1', 'SQLAO2')
Assert-OwnerPolicy (& $testScript) 'possible-owner order does not affect exact membership'

$script:PossibleOwners = @('SQLAO1', 'SQLAO2')
$script:PreferredOwners = @('SQLAO2', 'SQLAO1')
Assert-OwnerPolicy (-not (& $testScript)) 'reversed preferred-owner priority fails'

$script:PossibleOwners = @('SQLAO1')
$script:PreferredOwners = @('SQLAO1', 'SQLAO2')
Assert-OwnerPolicy (-not (& $testScript)) 'missing resource possible owner fails'

$script:PossibleOwners = @('SQLAO1', 'SQLAO2', 'SQLAO3')
Assert-OwnerPolicy (-not (& $testScript)) 'extra resource possible owner fails'

$script:PossibleOwners = @('SQLAO1', 'SQLAO2')
$script:PreferredOwners = @()
Assert-OwnerPolicy (-not (& $testScript)) 'zero preferred owners fails'

$script:OwnerQueryThrows = $true
Assert-OwnerPolicy (-not (& $testScript)) 'owner query failure fails closed'
$script:OwnerQueryThrows = $false

$script:SetCalls.Clear()
& $setScript
Assert-OwnerPolicy ($script:SetCalls.Count -eq 2) 'SetScript performs resource and group owner convergence'
$resourceCall = $script:SetCalls | Where-Object { $_.Resource -eq $script:AgName } | Select-Object -First 1
$groupCall = $script:SetCalls | Where-Object { $_.Group -eq $script:AgName } | Select-Object -First 1
Assert-OwnerPolicy ($resourceCall -and (($resourceCall.Owners | Sort-Object) -join ',') -eq 'SQLAO1,SQLAO2') 'resource Set call assigns exactly configured nodes'
Assert-OwnerPolicy ($groupCall -and (($groupCall.Owners | Sort-Object) -join ',') -eq 'SQLAO1,SQLAO2') 'group Set call assigns exactly configured nodes'

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO owner-policy assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO owner-policy tests passed.'
