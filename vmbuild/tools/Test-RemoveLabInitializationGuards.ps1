<#
.SYNOPSIS
    Verifies that removal skips environment probes and stops after initialization failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$vmbuildRoot = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
$removePath = Join-Path $vmbuildRoot 'Remove-Lab.ps1'

function Get-ParsedAst {
    param([Parameter(Mandatory = $true)][string] $Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "$Path has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
    }
    return $ast
}

function Test-HasEnvironmentSkipGuard {
    param([Parameter(Mandatory = $true)] $CommandAst)

    $parent = $CommandAst.Parent
    while ($parent) {
        if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $parent.Clauses) {
                $condition = $clause.Item1.Extent.Text
                if ($condition -match '\$effectiveSkipEnvironmentDetection' -and
                    $condition -match '-not') {
                    return $true
                }
            }
        }
        $parent = $parent.Parent
    }
    return $false
}

$commonAst = Get-ParsedAst -Path $commonPath
$initDnsCommands = @($commonAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-DnsClient' -and
            $node.Extent.StartLineNumber -gt 12000
        }, $true))
if ($initDnsCommands.Count -eq 0) {
    throw 'Common initialization no longer contains a Get-DnsClient probe; the guard test is vacuous.'
}
foreach ($command in $initDnsCommands) {
    if (-not (Test-HasEnvironmentSkipGuard -CommandAst $command)) {
        throw "Initialization Get-DnsClient at line $($command.Extent.StartLineNumber) is not guarded by -not `$effectiveSkipEnvironmentDetection."
    }
}

$removeAst = Get-ParsedAst -Path $removePath
$commonLoad = @($removeAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.Extent.Text -match 'Common\.ps1'
        }, $true) | Select-Object -First 1)
if ($commonLoad.Count -ne 1) {
    throw 'Remove-Lab Common.ps1 load was not found.'
}

$initFailureGuards = @($removeAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text -match '\$global:init_failed'
        }, $true))
if ($initFailureGuards.Count -ne 1) {
    throw "Expected one Remove-Lab initialization failure guard; found $($initFailureGuards.Count)."
}
$initFailureGuard = $initFailureGuards[0]
$exitStatements = @($initFailureGuard.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ExitStatementAst]
        }, $true))
if ($exitStatements.Count -ne 1) {
    throw 'Remove-Lab initialization failure guard does not terminate the process.'
}

$removalCommands = @($removeAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in @(
                'Remove-Orphaned',
                'Remove-InProgress',
                'Remove-VirtualMachine',
                'Remove-All',
                'Remove-Domain')
        }, $true))
$firstRemovalOffset = @($removalCommands | ForEach-Object { $_.Extent.StartOffset } |
    Measure-Object -Minimum).Minimum
if ($initFailureGuard.Extent.StartOffset -lt $commonLoad[0].Extent.EndOffset -or
    $initFailureGuard.Extent.EndOffset -gt $firstRemovalOffset) {
    throw 'Remove-Lab initialization failure guard is not between Common.ps1 loading and removal dispatch.'
}

Write-Host 'PASS -- removal skips environment probes and fails closed after initialization errors.'
