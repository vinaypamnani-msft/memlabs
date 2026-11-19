<#
.SYNOPSIS
    Verifies Phase 8 diagnostics finish before terminal failure cancels dependent jobs.
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production failure branches read fixture variables dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.ScriptBlocks.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$source parse errors: $($errors -join '; ')" }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$setupFailures = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$bailEarly' -and
            $node.Extent.Text.Contains('$setupFailureMessage')
        }, $true))
$monitorFailures = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CatchClauseAst] -and
            $node.Body.Extent.Text.Contains('$monitoringFailure = $_')
        }, $true) | Sort-Object { $_.Extent.EndOffset - $_.Extent.StartOffset })
Assert-True ($setupFailures.Count -eq 1 -and $monitorFailures.Count -ge 1) 'Expected the shipped setup/monitoring failure handlers.'
$setup = [scriptblock]::Create($setupFailures[0].Extent.Text.Replace('$using:Phase', '$Phase'))
$monitor = [scriptblock]::Create(
    "try { throw 'fixture original monitoring failure' } catch " +
    $monitorFailures[0].Body.Extent.Text.Replace('$using:Phase', '$Phase'))

& {
    $state = [pscustomobject]@{
        CaptureThrows = $false
        Events = [System.Collections.Generic.List[string]]::new()
        Failures = [System.Collections.Generic.List[string]]::new()
    }
    function Write-Log {
        param($Text, [switch]$Warning, [switch]$Failure, [switch]$OutputStream, [switch]$LogOnly)
        if ($Failure -and $OutputStream) {
            $state.Events.Add('TerminalFailure')
            $state.Failures.Add("$Text")
        }
        elseif ($Warning -and $OutputStream) { $state.Events.Add('VisibleWarning') }
    }
    function Write-Progress2 { param($Activity, $Status, [switch]$Force) }
    function Save-CMSetupLogsFromVm {
        param($VmName, $DomainName, $Phase, $Mode, $DeployConfig)
        Assert-True ($VmName -eq 'CAS1' -and $Mode -eq 'Failure') 'The failure handler did not request failure evidence for the trigger.'
        $state.Events.Add('CollectStart')
        if ($state.CaptureThrows) { throw 'fixture diagnostic failure' }
        $state.Events.Add('CollectComplete')
    }
    $currentItem = [pscustomobject]@{ vmName = 'CAS1'; role = 'CAS' }
    $domainName = 'example.test'
    $deployConfig = [pscustomobject]@{ virtualMachines = @($currentItem) }
    $bailEarly = $true
    $failEntry = 'fixture original setup failure'
    $failContext = $null
    foreach ($Phase in @(8, 7)) {
        foreach ($handler in @($setup, $monitor)) {
            foreach ($captureThrows in @($false, $true)) {
                $state.CaptureThrows = $captureThrows
                $state.Events.Clear()
                $state.Failures.Clear()
                $null = & $handler
                Assert-True ($state.Failures.Count -eq 1) 'The original failure was lost or reported twice.'
                Assert-True ($state.Failures[0] -match 'fixture original' -and
                    $state.Failures[0] -notmatch 'fixture diagnostic failure') 'Capture failure replaced the setup/monitoring cause.'
                $terminal = $state.Events.IndexOf('TerminalFailure')
                $collect = $state.Events.IndexOf('CollectStart')
                if ($Phase -eq 8) {
                    Assert-True ($terminal -gt $collect -and $state.Events[0] -eq 'VisibleWarning') 'A CAS failure can cancel Phase 8 before its independently bounded evidence capture.'
                    if (-not $captureThrows) {
                        Assert-True ($terminal -gt $state.Events.IndexOf('CollectComplete')) 'Terminal failure preceded completed diagnostic transfer.'
                    }
                }
                else {
                    Assert-True ($terminal -lt $collect) 'The change unexpectedly delayed non-Phase-8 failure signaling.'
                }
            }
        }
    }
}

Write-Host 'PASS -- Phase 8 failure evidence precedes cancellation; capture errors preserve the original failure.'
