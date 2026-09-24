<#
.SYNOPSIS
    Verifies that OSD content targeting is independent of task-sequence creation.
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

$taskSequenceGuards = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            @($node.Clauses | Where-Object { $_.Item1.Extent.Text -match '^\s*!\s*\$taskSequences\s*$' }).Count -eq 1 -and
            $node.Extent.Text -match 'New-CMTaskSequence'
        }, $true))
if ($taskSequenceGuards.Count -ne 1) {
    throw "Expected one task-sequence create guard; found $($taskSequenceGuards.Count)."
}
$taskSequenceGuard = $taskSequenceGuards[0]

$distributionCommands = @($ast.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
                $node.GetCommandName() -ne 'Start-CMContentDistribution') {
                return $false
            }
            $parameterNames = @($node.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
            return 'OperatingSystemImageIds' -in $parameterNames -or
                'OperatingSystemInstallerIds' -in $parameterNames
        }, $true))
if ($distributionCommands.Count -ne 2) {
    throw "Expected two OS-content distribution commands; found $($distributionCommands.Count)."
}

foreach ($command in $distributionCommands) {
    $insideTaskSequenceGuard = $false
    $insideOsdTargetGuard = $false
    $parent = $command.Parent
    while ($parent) {
        if ($parent -eq $taskSequenceGuard) { $insideTaskSequenceGuard = $true }
        if ($parent -is [System.Management.Automation.Language.IfStatementAst] -and
            $parent.Extent.Text -match 'if\s*\(\s*\$hasOsdTargets\s*\)') {
            $insideOsdTargetGuard = $true
        }
        $parent = $parent.Parent
    }
    if ($insideTaskSequenceGuard) {
        throw "OS-content distribution at line $($command.Extent.StartLineNumber) is create-only and cannot heal an existing task sequence."
    }
    if (-not $insideOsdTargetGuard) {
        throw "OS-content distribution at line $($command.Extent.StartLineNumber) is not gated by `$hasOsdTargets."
    }
}

$resolverAssignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$resolveSitePackageId'
        }, $true))
if ($resolverAssignments.Count -ne 1) {
    throw "Expected one site-package resolver assignment; found $($resolverAssignments.Count)."
}
$firstDistributionLine = @($distributionCommands | ForEach-Object { $_.Extent.StartLineNumber } | Measure-Object -Minimum)[0].Minimum
if ($resolverAssignments[0].Extent.StartLineNumber -gt $firstDistributionLine) {
    throw 'The site-package resolver is defined after OSD content distribution.'
}

Write-Host "PASS -- OS-content distribution commands=$($distributionCommands.Count), create-only descendants=0, OSD-target-gated=$($distributionCommands.Count)"
