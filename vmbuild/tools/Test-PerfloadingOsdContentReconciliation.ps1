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

$helperDefinitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Get-MemLabsServerFromNalPath', 'Get-MemLabsMissingContentTargets', 'Sync-MemLabsOsdContentDistribution')
        }, $true))
if ($helperDefinitions.Count -ne 3) {
    throw "Expected three OSD content reconciliation helpers; found $($helperDefinitions.Count)."
}
foreach ($helperDefinition in $helperDefinitions | Sort-Object { $_.Extent.StartLineNumber }) {
    Invoke-Expression $helperDefinition.Extent.Text
}

$distributionCommands = @($ast.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
                $node.GetCommandName() -ne 'Start-CMContentDistribution') {
                return $false
            }
            $parameterNames = @($node.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
                return 'OperatingSystemImageId' -in $parameterNames -or
                'OperatingSystemInstallerId' -in $parameterNames
        }, $true))
if ($distributionCommands.Count -ne 2) {
            throw "Expected two per-package OS-content distribution commands; found $($distributionCommands.Count)."
}

foreach ($command in $distributionCommands) {
    $insideTaskSequenceGuard = $false
    $parent = $command.Parent
    while ($parent) {
        if ($parent -eq $taskSequenceGuard) { $insideTaskSequenceGuard = $true }
        $parent = $parent.Parent
    }
    if ($insideTaskSequenceGuard) {
        throw "OS-content distribution at line $($command.Extent.StartLineNumber) is create-only and cannot heal an existing task sequence."
    }
}

$reconcileCalls = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Sync-MemLabsOsdContentDistribution'
        }, $true))
if ($reconcileCalls.Count -ne 1) {
    throw "Expected one production OSD content reconciliation call; found $($reconcileCalls.Count)."
}
$insideTaskSequenceGuard = $false
$insideOsdTargetGuard = $false
$parent = $reconcileCalls[0].Parent
while ($parent) {
    if ($parent -eq $taskSequenceGuard) { $insideTaskSequenceGuard = $true }
    if ($parent -is [System.Management.Automation.Language.IfStatementAst] -and
        $parent.Extent.Text -match 'if\s*\(\s*\$hasOsdTargets\s*\)') {
        $insideOsdTargetGuard = $true
    }
    $parent = $parent.Parent
}
if ($insideTaskSequenceGuard) { throw 'OSD content reconciliation is create-only and cannot heal existing task sequences.' }
if (-not $insideOsdTargetGuard) { throw 'OSD content reconciliation is not gated by $hasOsdTargets.' }

$resolverAssignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$resolveSitePackageId'
        }, $true))
if ($resolverAssignments.Count -ne 1) {
    throw "Expected one site-package resolver assignment; found $($resolverAssignments.Count)."
}
$reconcileLine = $reconcileCalls[0].Extent.StartLineNumber
if ($resolverAssignments[0].Extent.StartLineNumber -gt $reconcileLine) {
    throw 'The site-package resolver is defined after OSD content distribution.'
}

$script:TargetedPackageIds = @{}
$script:DistributionCalls = New-Object System.Collections.Generic.List[string]
$script:StatusLines = New-Object System.Collections.Generic.List[string]
$script:ThrowAfterTarget = $false
$script:ThrowWithoutTarget = $false
$script:ThrowTargetReadFor = ''

function Get-WmiObject {
    param($Namespace, $Class, $Filter, $ErrorAction)

    if ($Class -ne 'SMS_DistributionPoint') { return @() }
    $packageId = if ($Filter -match "PackageID='([^']+)'" ) { $Matches[1] } else { '' }
    if ($packageId -eq $script:ThrowTargetReadFor) { throw 'simulated target read failure' }
    if ($script:TargetedPackageIds.ContainsKey($packageId)) {
        return [pscustomobject]@{ ServerNALPath = '\\OSD-DP.memlabs.test\' }
    }
    return @()
}

function Start-CMContentDistribution {
    param(
        $PackageId,
        $OperatingSystemImageId,
        $OperatingSystemInstallerId,
        $DistributionPointGroupName,
        $ErrorAction
    )

    $id = @($PackageId, $OperatingSystemImageId, $OperatingSystemInstallerId | Where-Object { $_ })[0]
    $script:DistributionCalls.Add("$id")
    if ($script:ThrowAfterTarget) {
        $script:TargetedPackageIds["$id"] = $true
        throw 'No content destination was found'
    }
    if ($script:ThrowWithoutTarget) { throw 'simulated provider failure' }
    $script:TargetedPackageIds["$id"] = $true
}

function Write-DscStatus {
    param([Parameter(Position = 0)]$Message, [switch]$Warning)
    $script:StatusLines.Add("$Message")
}

function Start-Sleep { param($Seconds) }

$common = @{
    DistributionPointGroupName      = 'OSD DPS'
    ExpectedDistributionPointNames = @('OSD-DP.memlabs.test')
    SiteCode                        = 'PRI'
    StatusTag                       = '[test]'
    Attempts                        = 2
    RetrySeconds                    = 0
}

$script:TargetedPackageIds['PRI00001'] = $true
$alreadyTargeted = Sync-MemLabsOsdContentDistribution -ContentType OperatingSystemImage -PackageId PRI00001 -ContentName 'existing' @common
if (-not $alreadyTargeted -or $script:DistributionCalls.Count -ne 0) {
    throw 'An already-targeted package must succeed without another distribution request.'
}

$script:ThrowAfterTarget = $true
$readbackRecovered = Sync-MemLabsOsdContentDistribution -ContentType OperatingSystemImage -PackageId PRI00002 -ContentName 'readback' @common
if (-not $readbackRecovered -or $script:DistributionCalls.Count -ne 1) {
    throw 'A provider exception with positive target readback must succeed.'
}

$script:ThrowAfterTarget = $false
$script:ThrowWithoutTarget = $true
$firstFailed = Sync-MemLabsOsdContentDistribution -ContentType OperatingSystemImage -PackageId PRI00003 -ContentName 'failed image' @common
$secondFailed = Sync-MemLabsOsdContentDistribution -ContentType OperatingSystemInstaller -PackageId PRI00004 -ContentName 'later installer' @common
if ($firstFailed -or $secondFailed) { throw 'Missing targets after provider failures must return false.' }
if (($script:DistributionCalls -join ',') -ne 'PRI00002,PRI00003,PRI00004') {
    throw "A failed package aborted or reordered later reconciliation: $($script:DistributionCalls -join ',')"
}

$script:ThrowWithoutTarget = $false
$script:ThrowTargetReadFor = 'PRI00005'
$readFailed = Sync-MemLabsOsdContentDistribution -ContentType OperatingSystemImage -PackageId PRI00005 -ContentName 'unreadable image' @common
$script:ThrowTargetReadFor = ''
$laterSucceeded = Sync-MemLabsOsdContentDistribution -ContentType OperatingSystemInstaller -PackageId PRI00006 -ContentName 'later success' @common
if ($readFailed -or -not $laterSucceeded) { throw 'A target-read failure must return false without blocking later content.' }
if (($script:DistributionCalls -join ',') -ne 'PRI00002,PRI00003,PRI00004,PRI00006') {
    throw "A target-read failure invoked or blocked the wrong distribution: $($script:DistributionCalls -join ',')"
}

Write-Host "PASS -- per-package commands=$($distributionCommands.Count), already-targeted skip=1, positive-readback recovery=1, provider failures continued=2, target-read failure isolated=1"
