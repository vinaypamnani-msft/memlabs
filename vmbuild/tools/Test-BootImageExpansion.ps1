<#
.SYNOPSIS
    Exercises boot-image expansion without a ConfigMgr site or guest mutations.
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production scriptblocks read these fixture variables dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\perfloading.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-TestFunction {
    param([string]$Name)
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    Assert-True ($definitions.Count -eq 1) "Expected one $Name definition."
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Get-TestFunction 'Get-MemLabsServerFromNalPath')
. (Get-TestFunction 'Get-MemLabsBootImagePayloadRepairTargets')

& {
    $state = [pscustomobject]@{
        Reachable = $true; PayloadPresent = $false; ProbeError = $false
        Probes = [System.Collections.Generic.List[string]]::new()
        Warnings = [System.Collections.Generic.List[string]]::new()
    }
    function Get-Item {
        param([string]$LiteralPath, [switch]$Force, $ErrorAction)
        $kind = if ($LiteralPath -like '*\wdsmgfw.efi') { 'Leaf' } else { 'Container' }
        $state.Probes.Add("$kind $LiteralPath")
        if ($state.ProbeError) { throw 'synthetic access denied' }
        if ($kind -eq 'Container' -and -not $state.Reachable) { throw [IO.IOException]::new('root not measured') }
        if ($kind -eq 'Leaf' -and -not $state.PayloadPresent) {
            throw [Management.Automation.ItemNotFoundException]::new('missing boot file')
        }
        [pscustomobject]@{ PSIsContainer = $kind -eq 'Container' }
    }
    function Write-DscStatus {
        param([string]$Message, [switch]$Warning)
        if ($Warning) { $state.Warnings.Add($Message) }
    }
    $arguments = @{
        PackageId = 'PRI00008'; SourceVersion = 4
        DistributionPointNames = @('DP1.memlabs.test'); StatusTag = '[test]'
    }
    foreach ($distributionState in @(1, 2, 7, 3)) {
        $rows = @([pscustomobject]@{
                ServerNALPath = '\\DP1.memlabs.test\'; State = $distributionState; SourceVersion = 4
            })
        $targets = @(Get-MemLabsBootImagePayloadRepairTargets @arguments -DistributionStatusRows $rows)
        Assert-True ($targets.Count -eq 0) "State $distributionState triggered a premature site-wide rebuild."
    }
    $targets = @(Get-MemLabsBootImagePayloadRepairTargets @arguments -DistributionStatusRows @())
    Assert-True ($targets.Count -eq 0 -and $state.Probes.Count -eq 0) 'A new DP with no status row was mistaken for a broken Installed DP.'
    $row = [pscustomobject]@{ ServerNALPath = '\\DP1.memlabs.test\'; State = 0; SourceVersion = 3 }
    $targets = @(Get-MemLabsBootImagePayloadRepairTargets @arguments -DistributionStatusRows @($row))
    Assert-True ($targets.Count -eq 0 -and $state.Probes.Count -eq 0) 'An old Installed version caused a rebuild during an update.'
    $row.SourceVersion = 4
    $targets = @(Get-MemLabsBootImagePayloadRepairTargets @arguments -DistributionStatusRows @($row))
    Assert-True ($targets.Count -eq 1 -and $targets[0] -eq 'DP1.memlabs.test') 'An Installed/current DP with no boot file was not repaired.'
    Assert-True ($state.Probes[1] -eq 'Leaf FileSystem::\\DP1.memlabs.test\SMS_DP$\sms\bin\SMSBoot\PRI00008\x64\wdsmgfw.efi') 'The repair does not measure the actual boot file through the FileSystem provider.'
    $state.PayloadPresent = $true
    Assert-True (@(Get-MemLabsBootImagePayloadRepairTargets @arguments -DistributionStatusRows @($row)).Count -eq 0) 'A healthy DP triggered a rebuild.'
    $state.Reachable = $false
    Assert-True (@(Get-MemLabsBootImagePayloadRepairTargets @arguments -DistributionStatusRows @($row)).Count -eq 0) 'An unreachable DP was treated as positive missing-payload evidence.'
    Assert-True (($state.Warnings -join ' ') -match 'not measured') 'An unreachable payload probe failed silently.'
    $state.ProbeError = $true
    Assert-True (@(Get-MemLabsBootImagePayloadRepairTargets @arguments -DistributionStatusRows @($row)).Count -eq 0) 'A denied probe triggered a rebuild.'
    Assert-True (($state.Warnings -join ' ') -match 'synthetic access denied') 'An unreadable payload probe lost its error.'
}

$publicationAssignments = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$bootImagePublicationNeeded'
        }, $true))
Assert-True ($publicationAssignments.Count -eq 1) 'Expected one production publication decision.'
$evaluatePublication = [scriptblock]::Create("$($publicationAssignments[0].Extent.Text)`n`$bootImagePublicationNeeded")
& {
    $commandSupportChanged = $false
    $bootTemplateRestored = $false
    $pxeBootFlagSet = $false
    $pxePayloadMissingOn = @()
    $missingOsdDps = @('NEWDP.memlabs.test')
    Assert-True (-not (& $evaluatePublication)) 'Adding a destination still rebuilds an unchanged boot image.'
    foreach ($name in @('commandSupportChanged', 'bootTemplateRestored', 'pxeBootFlagSet')) {
        Set-Variable -Name $name -Value $true
        Assert-True ([bool](& $evaluatePublication)) "$name no longer publishes a changed boot image."
        Set-Variable -Name $name -Value $false
    }
    $pxePayloadMissingOn = @('BROKENDP.memlabs.test')
    Assert-True ([bool](& $evaluatePublication)) 'A confirmed broken Installed payload no longer triggers repair.'
    Assert-True ($missingOsdDps.Count -eq 1) 'The expansion fixture lost its new destination.'
}

$rearmLoops = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -eq 'incompleteDp'
        }, $true))
Assert-True ($rearmLoops.Count -eq 1) 'Expected one production boot-coverage recovery loop.'
$recover = [scriptblock]::Create($rearmLoops[0].Extent.Text)
& {
    $state = [pscustomobject]@{
        Now = [datetime]'2026-10-30T08:00:00'
        NoTarget = $false
        Starts = 0
        Messages = [System.Collections.Generic.List[string]]::new()
    }
    $target = [pscustomobject]@{
        ServerNALPath = '\\DP1.memlabs.test\'
        RefreshNow = $false; PutCount = 0; ThrowOnPut = $false
    }
    $target | Add-Member -MemberType ScriptMethod -Name Put -Value {
        $this.PutCount++
        if ($this.ThrowOnPut) { throw 'synthetic target write failure' }
    }
    function Get-Date { return $state.Now }
    function Get-WmiObject {
        param($Namespace, $Class, $Filter, $ErrorAction)
        if (-not $state.NoTarget) { return $target }
    }
    function Start-CMContentDistribution {
        param($BootImageId, $DistributionPointName, $ErrorAction)
        $state.Starts++
    }
    function Write-DscStatus {
        param([string]$Message)
        $state.Messages.Add($Message)
    }
    $Tag = '[test]'
    $SiteCode = 'PRI'
    $packageId = 'PRI00008'
    $biName = 'Boot image'
    $bootSourceVersion = '4'
    $bootStoredVersion = '4'
    $bootIncompleteDps = @('DP1.memlabs.test')
    $bootCoverageLastArm = @{}
    $bootCoverageIncompleteSince = @{}
    $row = [pscustomobject]@{ ServerNALPath = '\\DP1.memlabs.test\'; State = 1; SourceVersion = 4 }
    $bootDpRows = @($row)
    & $recover
    $row.State = 7
    $state.Now = $state.Now.AddMinutes(10)
    & $recover
    Assert-True ($target.PutCount -eq 0 -and $bootCoverageIncompleteSince.Count -eq 0) 'Pending or validating first-time content was interrupted.'
    $row.State = 2
    & $recover
    $state.Now = $state.Now.AddSeconds(299)
    & $recover
    Assert-True ($target.PutCount -eq 0) 'InstallRetrying was re-armed before five minutes.'
    $state.Now = $state.Now.AddSeconds(1)
    & $recover
    Assert-True ($target.PutCount -eq 1 -and $target.RefreshNow) 'A persistent retry did not get its one bounded RefreshNow.'
    $state.Now = $state.Now.AddMinutes(10)
    & $recover
    Assert-True ($target.PutCount -eq 1) 'A pending distribution was repeatedly reset at the same version.'

    $bootCoverageLastArm.Clear()
    $bootCoverageIncompleteSince.Clear()
    $state.NoTarget = $true
    & $recover
    $state.Now = $state.Now.AddSeconds(300)
    & $recover
    & $recover
    Assert-True ($state.Starts -eq 1) 'A disappeared target was not recreated exactly once.'

    $bootCoverageLastArm.Clear()
    $bootCoverageIncompleteSince.Clear()
    $state.NoTarget = $false
    $target.ThrowOnPut = $true
    & $recover
    $state.Now = $state.Now.AddSeconds(300)
    & $recover
    & $recover
    Assert-True ($target.PutCount -eq 2) 'A failed target write was retried without a new version.'
    Assert-True (($state.Messages -join ' ') -match 'synthetic target write failure') 'A failed recovery write was hidden.'
}

$versionResets = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text.Contains('$bootCoverageObservedSourceVersion -ne $bootSourceVersion')
        }, $true))
Assert-True ($versionResets.Count -eq 1) 'Expected one source-version recovery reset.'
$resetVersion = [scriptblock]::Create($versionResets[0].Extent.Text)
& {
    $bootCoverageObservedSourceVersion = '3'
    $bootSourceVersion = '4'
    $bootCoverageLastArm = @{ DP1 = [datetime]::UtcNow }
    $bootCoverageIncompleteSince = @{ DP1 = [datetime]::UtcNow }
    . $resetVersion
    Assert-True ($bootCoverageObservedSourceVersion -eq '4' -and
        $bootCoverageLastArm.Count -eq 0 -and $bootCoverageIncompleteSince.Count -eq 0) 'A genuinely new source version cannot receive its own bounded recovery.'
}

Write-Host 'PASS -- new DP targeting does not rebuild unchanged boot images; first transfers settle before one bounded recovery.'
