<#
.SYNOPSIS
    Verifies that the non-authoritative client-package pre-stage probe is informational.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$prestagePath = Join-Path $root 'DSC\phases\InstallDPMPClient.ps1'
$coveragePath = Join-Path $root 'DSC\phases\InstallBoundaryGroups.ps1'

function Get-ScriptAst {
    param([Parameter(Mandatory)] [string] $Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "$(Split-Path $Path -Leaf) has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
    }
    return $ast
}

$prestageAst = Get-ScriptAst $prestagePath
$coverageAst = Get-ScriptAst $coveragePath

$deferredCommands = @($prestageAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Write-DscStatus' -and
            $node.Extent.Text -match 'Client package pre-stage deferred:'
        }, $true))
if ($deferredCommands.Count -ne 1) {
    throw "Expected one deferred pre-stage status; found $($deferredCommands.Count)."
}
$deferredParameters = @($deferredCommands[0].CommandElements |
        Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
        ForEach-Object { $_.ParameterName })
if ('Warning' -in $deferredParameters -or 'Failure' -in $deferredParameters) {
    throw 'The non-authoritative client-package pre-stage probe must be informational.'
}
if ($deferredCommands[0].Extent.Text -notmatch 'authoritative client-package coverage gate.*waits for Installed') {
    throw 'The pre-stage message does not identify the authoritative recovery gate.'
}

$coverageSuccess = @($coverageAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Write-DscStatus' -and
            $node.Extent.Text -match 'Client package is Installed on all'
        }, $true))
if ($coverageSuccess.Count -ne 1) {
    throw "Expected one authoritative coverage success status; found $($coverageSuccess.Count)."
}

$deadlineWarnings = @($coverageAst.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
                $node.GetCommandName() -ne 'Write-DscStatus' -or
                $node.Extent.Text -notmatch 'STILL not Installed at the wall-clock deadline') {
                return $false
            }
            $parameters = @($node.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
            return 'Warning' -in $parameters
        }, $true))
if ($deadlineWarnings.Count -ne 1) {
    throw "Expected one authoritative deadline warning; found $($deadlineWarnings.Count)."
}

if ($coverageAst.Extent.Text -notmatch '(?s)dpProviderSiteCode.+?InstallSMSProv') {
    throw 'Dedicated DP diagnostics are no longer guarded from invalid SMS Provider namespace probes.'
}
if ($coverageAst.Extent.Text -notmatch '(?s)clientPackageDiagCredential.+?sourceInvoke\.Credential') {
    throw 'Cross-site source-node diagnostics no longer use an explicit credential when available.'
}

Write-Host 'PASS -- pre-stage race is informational; coverage success/deadline remain authoritative.'
