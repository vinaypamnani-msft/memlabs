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

$unsafeOsdGroupFilters = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-WmiObject' -and
            $node.Extent.Text -match 'SMS_DPGroupMembers' -and
            $node.Extent.Text -match '\$osdGrpWmi\.GroupID'
        }, $true))
if ($unsafeOsdGroupFilters.Count -ne 0) {
    throw "Found $($unsafeOsdGroupFilters.Count) OSD membership query that interpolates GroupID from a possible group array."
}
$perGroupOsdFilters = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-WmiObject' -and
            $node.Extent.Text -match 'SMS_DPGroupMembers' -and
            $node.Extent.Text -match '\$osdGroupId'
        }, $true))
if ($perGroupOsdFilters.Count -ne 2) {
    throw "Expected two exact-GroupID OSD membership queries; found $($perGroupOsdFilters.Count)."
}
$perfloadingText = Get-Content -LiteralPath $perfloadingPath -Raw
if (-not $perfloadingText.Contains('Add-CMDistributionPointToGroup -DistributionPointGroupId $osdGroupId')) {
    throw 'OSD membership add does not pin the resolved GroupID.'
}
if (-not $perfloadingText.Contains("OSD content is not distributed by the ambiguous group name")) {
    throw 'Ambiguous OSD group names do not suppress unsafe name-based distribution.'
}
if ($perfloadingText -notmatch 'Could not resolve OSD DP group[\s\S]{0,300}-Warning') {
    throw 'OSD DP-group resolver failures are not warning-only.'
}
$pxeCommands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Set-CMDistributionPoint' -and
            $node.Extent.Text -match '-EnablePxe\s+\$true' -and
            $node.Extent.Text -match '\$d\.Fqdn'
        }, $true))
if ($pxeCommands.Count -ne 2) {
    throw "Expected NonWDS and fallback PXE reconciliation commands; found $($pxeCommands.Count)."
}
foreach ($pxeCommand in $pxeCommands) {
    if ($pxeCommand.Extent.Text -notmatch '-EnableUnknownComputerSupport\s+\$true') {
        throw "OSD PXE reconciliation at line $($pxeCommand.Extent.StartLineNumber) does not enable unknown-computer support."
    }
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
            $node.Name -in @('Get-MemLabsServerFromNalPath', 'Get-MemLabsBootImageSourceVersionProblem', 'Get-MemLabsMissingContentTargets', 'Sync-MemLabsOsdContentDistribution')
        }, $true))
if ($helperDefinitions.Count -ne 4) {
    throw "Expected four OSD content reconciliation helpers; found $($helperDefinitions.Count)."
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

$publicationVersionCapture = $perfloadingText.IndexOf('$bootImagePublicationPreviousSourceVersion = [int]$bootImageBeforePublication.SourceVersion')
$publicationRequest = $perfloadingText.IndexOf('Update-CMDistributionPoint -BootImageId $packageId')
if ($publicationVersionCapture -lt 0 -or $publicationRequest -lt 0 -or $publicationVersionCapture -gt $publicationRequest) {
    throw 'Boot-image publication does not capture SourceVersion before Update-CMDistributionPoint.'
}

$problem = Get-MemLabsBootImageSourceVersionProblem -CurrentSourceVersion 2 -CurrentStoredVersion 2 -CommandSupportChanged $false -CommandSupportPreviousSourceVersion $null -PublicationNeeded $true -PublicationStarted $true -PublicationPreviousSourceVersion 2
if ($problem -notmatch 'has not advanced after publication') {
    throw "Pre-publication SourceVersion was accepted: '$problem'."
}
$problem = Get-MemLabsBootImageSourceVersionProblem -CurrentSourceVersion 3 -CurrentStoredVersion 3 -CommandSupportChanged $false -CommandSupportPreviousSourceVersion $null -PublicationNeeded $true -PublicationStarted $true -PublicationPreviousSourceVersion 2
if ($problem) {
    throw "Advanced publication SourceVersion was rejected: '$problem'."
}
$problem = Get-MemLabsBootImageSourceVersionProblem -CurrentSourceVersion 2 -CurrentStoredVersion 2 -CommandSupportChanged $false -CommandSupportPreviousSourceVersion $null -PublicationNeeded $true -PublicationStarted $false -PublicationPreviousSourceVersion 2
if ($problem -notmatch 'did not start') {
    throw "Failed publication was accepted: '$problem'."
}
$problem = Get-MemLabsBootImageSourceVersionProblem -CurrentSourceVersion 3 -CurrentStoredVersion 2 -CommandSupportChanged $false -CommandSupportPreviousSourceVersion $null -PublicationNeeded $true -PublicationStarted $true -PublicationPreviousSourceVersion 2
if ($problem -notmatch 'StoredPkgVersion=2') {
    throw "Site content lag was accepted: '$problem'."
}
$problem = Get-MemLabsBootImageSourceVersionProblem -CurrentSourceVersion 2 -CurrentStoredVersion 2 -CommandSupportChanged $false -CommandSupportPreviousSourceVersion $null -PublicationNeeded $false -PublicationStarted $false -PublicationPreviousSourceVersion $null
if ($problem) {
    throw "Warm rerun without publication was blocked: '$problem'."
}
$problem = Get-MemLabsBootImageSourceVersionProblem -CurrentSourceVersion 3 -CurrentStoredVersion 3 -CommandSupportChanged $false -CommandSupportPreviousSourceVersion $null -PublicationNeeded $true -PublicationStarted $true -PublicationPreviousSourceVersion $null
if ($problem -notmatch 'previous') {
    throw "Missing publication baseline was accepted: '$problem'."
}
if ($perfloadingText -notmatch 'bootCoverageTerminalProblem[\s\S]{0,500}break') {
    throw 'Unwinnable publication states do not skip the 15-minute coverage wait.'
}
if ($perfloadingText -notmatch 'for \(\$baselineTry = 1; \$baselineTry -le 3') {
    throw 'Pre-publication SourceVersion does not use a bounded retry.'
}

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

& {
    foreach ($name in @('Get-MemLabsOsdImportMutexName', 'Invoke-MemLabsOsdPackageImport', 'Test-MemLabsOsdDpIdentity', 'Wait-MemLabsOsdSharedWimReady')) {
        $definition = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true))
        if ($definition.Count -ne 1) { throw "Expected one $name helper." }
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }
    $state = @{
        Seconds = 0; Rows = @(); NewCalls = 0; NewAt = -1; ReadFails = $false
        NewFails = $false; DistributionCalls = 0; TargetSecond = $false; AutoTargetAt = -1
        SourceReadyAt = 30; DpReadyAt = 60; ExtraDpReadyAt = 90; StatusVersion = 1; StatusState = 1
        ImportAction = 0; ImportReadback = ''; FailClass = ''; Messages = [System.Collections.Generic.List[string]]::new()
    }
    $base = [datetime]'2026-11-24T00:00:00Z'
    function Get-Date { $base.AddSeconds($state.Seconds) }
    function Start-Sleep {
        param($Seconds)
        $state.Seconds += $Seconds
        if ($state.Seconds -gt 180) { throw 'Import fixture exceeded its bounded wait.' }
    }
    function Write-DscStatus {
        param($Message, [switch]$Warning, $RetrySeconds)
        $state.Messages.Add("$Message")
    }
    function Read-ImportFixture {
        param($Name, [switch]$Query)
        if ($state.ReadFails) { throw 'fixture provider read denied' }
        foreach ($row in @($state.Rows | Where-Object { $_.Name -eq $Name })) {
            $stored = 0; $action = 2; $version = 0
            if ($state.Seconds -ge $row.ReadyAt) {
                $stored = 1; $action = 1; $version = 1
                if ($Query) { $action = $state.ImportAction }
            }
            $sourceSite = 'PRI'
            if ($row.PSObject.Properties['SourceSite']) { $sourceSite = $row.SourceSite }
            [pscustomobject]@{
                Name = $Name; PackageID = $row.PackageID; SourceSite = $sourceSite
                SourceVersion = $version; StoredPkgVersion = $stored; ActionInProgress = $action
            }
        }
    }
    function Get-CimInstance {
        param($Namespace, $ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        if ($ClassName -ne 'SMS_PackageBaseclass' -or $OperationTimeoutSec -ne 10) {
            throw 'Import readiness requires a bounded package-state query.'
        }
        if ($ClassName -eq $state.FailClass) { throw 'fixture import-state query failed' }
        if ($Filter -notmatch "^PackageID='([A-Za-z0-9]{8})'$") { throw "Unexpected filter: $Filter" }
        $id = $Matches[1]
        if ($state.ImportReadback -eq 'Missing') { return }
        foreach ($name in @($state.Rows | Where-Object { $_.PackageID -eq $id } | Select-Object -ExpandProperty Name -Unique)) {
            foreach ($row in @(Read-ImportFixture $name -Query | Where-Object { $_.PackageID -eq $id })) {
                switch ($state.ImportReadback) {
                    WrongId { $row.PackageID = 'PRI99999' }
                    WrongSite { $row.SourceSite = 'OTH' }
                    SourceLag { $row.StoredPkgVersion = 0 }
                }
                $row
            }
        }
    }
    function Get-CMOperatingSystemUpgradePackage { param($Name, $ErrorAction) Read-ImportFixture $Name }
    function Get-CMOperatingSystemImage { param($Name, $ErrorAction) Read-ImportFixture $Name }
    function New-CMOperatingSystemImage {
        param($Name, $Path, $Version, $ErrorAction)
        $state.NewCalls++; $state.NewAt = $state.Seconds
        $state.Rows += [pscustomobject]@{ Name = $Name; PackageID = 'PRI00007'; ReadyAt = $state.Seconds + 30 }
        if ($state.NewFails) { throw 'fixture accepted import but response failed' }
    }
    function New-CMOperatingSystemInstaller {
        param($Name, $Path, $Version, $ErrorAction)
        New-CMOperatingSystemImage @PSBoundParameters
    }
    $import = @{
        ContentType = 'OperatingSystemImage'; Name = 'Windows 11'; OtherContentName = 'Windows 11 upgrade'
        Path = "\\fixture-$([guid]::NewGuid().ToString('N'))\OSD\Windows 11\sources\install.wim"
        Version = '10.0.26100'; SiteCode = 'PRI'; StatusTag = '[fixture]'; TimeoutSeconds = 120
    }
    $state.Rows = @([pscustomobject]@{ Name = 'Windows 11'; PackageID = 'PRI00007'; ReadyAt = 30 })
    if (-not (Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0 -or $state.Seconds -ne 30) {
        throw 'An existing import was resubmitted, accepted before source readiness, or blocked by the hydrated UPDATE flag after the provider query became idle.'
    }
    if (($state.Messages -join '; ') -notmatch 'RawActionInProgress=0.+HydratedActionInProgress=1') {
        throw 'Readiness diagnostics do not retain the raw/hydrated action disagreement.'
    }
    $state.Seconds = 0; $state.ImportAction = 1; $import.TimeoutSeconds = 30
    $state.Rows = @([pscustomobject]@{ Name = 'Windows 11'; PackageID = 'PRI00007'; ReadyAt = 0 })
    if ((Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0 -or $state.Seconds -ne 30) {
        throw 'A genuinely busy provider state bypassed the import guard or submitted another import.'
    }
    $state.Seconds = 0; $state.ImportAction = 0; $state.FailClass = 'SMS_PackageBaseclass'
    if ((Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0 -or $state.Seconds -ne 0) {
        throw 'An unreadable provider state authorized import reuse or another import.'
    }
    $state.FailClass = ''
    foreach ($readback in @('Missing', 'WrongId', 'WrongSite', 'SourceLag')) {
        $state.Seconds = 0; $state.ImportReadback = $readback
        $expectedWait = if ($readback -eq 'SourceLag') { 30 } else { 0 }
        if ((Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0 -or $state.Seconds -ne $expectedWait) {
            throw "Invalid raw provider readback '$readback' authorized import reuse or another import."
        }
    }
    $state.ImportReadback = ''
    $state.FailClass = ''; $import.TimeoutSeconds = 120
    $state.Seconds = 0; $state.Rows = @()
    if (-not (Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 1 -or $state.Seconds -ne 30) {
        throw 'A new import was not requested exactly once and verified asynchronously.'
    }
    $state.Seconds = 0; $state.NewCalls = 0
    $state.Rows = @([pscustomobject]@{ Name = 'Windows 11 upgrade'; PackageID = 'PRI00004'; ReadyAt = 30 })
    if (-not (Invoke-MemLabsOsdPackageImport @import) -or $state.NewAt -ne 30 -or $state.NewCalls -ne 1) {
        throw 'An image import overlapped an existing upgrade import of its WIM.'
    }
    $state.Seconds = 0; $state.Rows = @(); $state.NewCalls = 0; $state.ReadFails = $true
    if ((Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0) { throw 'A failed existence query became permission to import.' }
    $state.ReadFails = $false; $state.NewFails = $true
    if ((Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 1) { throw 'An uncertain creation response was blindly retried.' }
    $state.NewFails = $false
    $state.NewCalls = 0; $state.Seconds = 0
    $state.Rows = @(
        [pscustomobject]@{ Name = 'Windows 11'; PackageID = 'SRC00007'; SourceSite = 'SRC'; ReadyAt = 0 },
        [pscustomobject]@{ Name = 'Windows 11'; PackageID = 'PRI00007'; SourceSite = 'PRI'; ReadyAt = 0 }
    )
    if (-not (Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0) {
        throw 'A healthy unique site-owned package was rejected because another site owns a same-named copy.'
    }
    $state.Rows = @(
        [pscustomobject]@{ Name = 'Windows 11'; PackageID = 'SRC00007'; SourceSite = 'SRC'; ReadyAt = 0 },
        [pscustomobject]@{ Name = 'Windows 11'; PackageID = 'OTH00007'; SourceSite = 'OTH'; ReadyAt = 0 }
    )
    if (-not (Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0) {
        throw 'The existing hierarchy-owned fallback stopped reusing a multi-site catalog.'
    }
    $state.Rows = @(
        [pscustomobject]@{ Name = 'Windows 11'; PackageID = 'PRI00007'; ReadyAt = 0 },
        [pscustomobject]@{ Name = 'Windows 11'; PackageID = 'PRI00008'; ReadyAt = 0 }
    )
    if ((Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0) {
        throw 'Genuinely ambiguous local packages authorized another import.'
    }
    if (-not ('MemLabsOsdImportLockFixture' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Threading;
public sealed class MemLabsOsdImportLockFixture : IDisposable {
    readonly ManualResetEvent ready = new ManualResetEvent(false), release = new ManualResetEvent(false);
    readonly Thread thread;
    public MemLabsOsdImportLockFixture(string name) {
        thread = new Thread(delegate() {
            using (Mutex mutex = new Mutex(false, name)) {
                mutex.WaitOne(); ready.Set();
                try { release.WaitOne(); } finally { mutex.ReleaseMutex(); }
            }
        });
        thread.IsBackground = true; thread.Start();
        if (!ready.WaitOne(5000)) { release.Set(); throw new Exception("Fixture lease did not become ready"); }
    }
    public void Dispose() {
        release.Set();
        if (!thread.Join(5000)) throw new Exception("Fixture lease did not stop");
        ready.Dispose(); release.Dispose();
    }
}
'@ -ErrorAction Stop
    }
    $holder = [MemLabsOsdImportLockFixture]::new((Get-MemLabsOsdImportMutexName -WimPath $import.Path))
    try {
        $state.NewCalls = 0; $state.Rows = @()
        if ((Invoke-MemLabsOsdPackageImport @import) -or $state.NewCalls -ne 0) { throw 'Concurrent MemLabs callers both submitted an import.' }
    }
    finally { $holder.Dispose() }

    function Get-WmiObject {
        param($Namespace, $Class, $Filter, $ErrorAction)
        if ($Class -eq $state.FailClass) { throw 'fixture shared-WIM provider read failed' }
        if ($Filter -notmatch "PackageID='([^']+)'") { throw "Unexpected filter: $Filter" }
        $id = $Matches[1]
        if ($Class -eq 'SMS_PackageBaseclass') {
            $stored = 0
            if ($state.Seconds -ge $state.SourceReadyAt) { $stored = 1 }
            return [pscustomobject]@{ PackageID = $id; SourceSite = 'SRC'; SourceVersion = 1; StoredPkgVersion = $stored; ActionInProgress = 0 }
        }
        if ($Class -eq 'SMS_DistributionPoint') {
            if ($id -eq 'PRI00002') {
                if ($state.TargetSecond -or ($state.AutoTargetAt -ge 0 -and $state.Seconds -ge $state.AutoTargetAt)) {
                    [pscustomobject]@{ SiteCode = 'PRI'; ServerNALPath = '\\OSD-DP.memlabs.test\' }
                }
                return
            }
            [pscustomobject]@{ SiteCode = 'PRI'; ServerNALPath = '\\OSD-DP.memlabs.test\' }
            [pscustomobject]@{ SiteCode = 'PRI'; ServerNALPath = '\\EXTRA-DP.memlabs.test\' }
            return
        }
        if ($Class -eq 'SMS_PackageStatusDistPointsSummarizer') {
            foreach ($dp in @('OSD-DP', 'EXTRA-DP')) {
                $readyAt = $state.DpReadyAt
                if ($dp -eq 'EXTRA-DP') { $readyAt = $state.ExtraDpReadyAt }
                $number = $state.StatusState
                if ($state.Seconds -ge $readyAt) { $number = 0 }
                [pscustomobject]@{ ServerNALPath = "\\$dp.memlabs.test\"; State = $number; SourceVersion = $state.StatusVersion }
            }
            return
        }
        throw "Unexpected class: $Class"
    }
    function Start-CMContentDistribution {
        param($OperatingSystemInstallerId, $OperatingSystemImageId, $PackageId, $DistributionPointGroupName, $ErrorAction)
        $state.DistributionCalls++; $state.TargetSecond = $true
    }
    function Get-CimInstance {
        param($Namespace, $ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        if ($OperationTimeoutSec -ne 10) { throw 'Shared-WIM provider checks must have an operation timeout.' }
        Get-WmiObject -Namespace $Namespace -Class $ClassName -Filter $Filter -ErrorAction $ErrorAction
    }
    $gate = @{
        PackageId = 'PRI00001'; ExpectedDistributionPointNames = @('OSD-DP.memlabs.test')
        SiteCode = 'PRI'; StatusTag = '[fixture]'; Required = $true; TimeoutSeconds = 120
    }
    $state.Seconds = 0
    if (-not (Wait-MemLabsOsdSharedWimReady @gate) -or $state.Seconds -ne 90) {
        throw 'Shared-WIM delivery proceeded before source readiness and every local target DP finished.'
    }
    $state.Seconds = 0; $state.StatusVersion = 0
    $gate.TimeoutSeconds = 30
    if (Wait-MemLabsOsdSharedWimReady @gate) { throw 'Installed status for an old package version bypassed the guard.' }
    $state.StatusVersion = 1; $state.FailClass = 'SMS_PackageStatusDistPointsSummarizer'
    if (Wait-MemLabsOsdSharedWimReady @gate) { throw 'An unmeasured prerequisite authorized distribution.' }
    $sync = @{
        ContentType = 'OperatingSystemInstaller'; PackageId = 'PRI00002'; ContentName = 'upgrade'
        DistributionPointGroupName = 'OSD DPS'; ExpectedDistributionPointNames = @('OSD-DP.memlabs.test')
        SiteCode = 'PRI'; StatusTag = '[fixture]'; SharedWimPackageId = 'PRI00001'; RequireSharedWimCompletion = $true
        Attempts = 1; RetrySeconds = 0
    }
    if ((Sync-MemLabsOsdContentDistribution @sync) -or $state.DistributionCalls -ne 0) {
        throw 'A prerequisite read failure still submitted shared-WIM distribution.'
    }
    $state.TargetSecond = $true; $state.FailClass = 'SMS_PackageBaseclass'
    if (-not (Sync-MemLabsOsdContentDistribution @sync) -or $state.DistributionCalls -ne 0) {
        throw 'An already targeted package was re-requested or blocked by unrelated prerequisite state.'
    }
    $state.TargetSecond = $false; $state.FailClass = ''; $state.Seconds = 0; $state.AutoTargetAt = 90
    if (-not (Sync-MemLabsOsdContentDistribution @sync) -or $state.DistributionCalls -ne 0) {
        throw 'Targeting that appeared during the wait was requested a second time.'
    }
    if (($state.Messages -join ' ') -notmatch 'not submitting a duplicate import|not verified') { throw 'Import guard failures were not surfaced.' }
}
Write-Host 'PASS -- raw provider readiness overrides hydrated UPDATE flags, busy/unreadable states fail closed, imports are not duplicated, and shared-WIM delivery waits for current-version installation.'
