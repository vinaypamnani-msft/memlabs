<#
.SYNOPSIS
    Verifies that perfloading warns only when the qualified OSD share is unreachable.
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

$canaryConditions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            @($node.Clauses | Where-Object { $_.Item1.Extent.Text -match '^\s*-not\s+\$qualifiedCanary\s*$' }).Count -eq 1 -and
            $node.Extent.Text -match 'UNC path resolution FAILED:' -and
            $node.Extent.Text -match 'UNC path resolution note:'
        }, $true))
if ($canaryConditions.Count -ne 1) {
    throw "Expected one UNC canary condition; found $($canaryConditions.Count)."
}
$canary = [scriptblock]::Create($canaryConditions[0].Extent.Text)

function Write-DscStatus {
    param([Parameter(Position = 0)]$Message, [switch]$Warning)
    [pscustomobject]@{ Message = "$Message"; Warning = [bool]$Warning }
}

function Invoke-Canary {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Fixture locals are consumed by the extracted production scriptblock.')]
    param([bool]$Bare, [bool]$Qualified)

    $bareCanary = $Bare
    $qualifiedCanary = $Qualified
    $uncCanary = '\\PRIMARY\OSD'
    $Tag = '[perfloading]'
    @(& $canary)
}

$expectedProviderMismatch = @(Invoke-Canary -Bare $false -Qualified $true)
if ($expectedProviderMismatch.Count -ne 1 -or $expectedProviderMismatch[0].Warning -or
    $expectedProviderMismatch[0].Message -notmatch 'expected on the .* provider') {
    throw 'An expected CMSite-provider mismatch must be informational.'
}

$unreachableShare = @(Invoke-Canary -Bare $false -Qualified $false)
if ($unreachableShare.Count -ne 1 -or -not $unreachableShare[0].Warning -or
    $unreachableShare[0].Message -notmatch 'UNC path resolution FAILED') {
    throw 'An unreachable FileSystem-qualified share must warn.'
}

$matchingReads = @(Invoke-Canary -Bare $true -Qualified $true)
if ($matchingReads.Count -ne 1 -or $matchingReads[0].Warning -or
    $matchingReads[0].Message -notmatch 'UNC path resolution OK') {
    throw 'Matching successful probes must be informational.'
}

Write-Host 'PASS -- expected provider mismatch=INFO, qualified share missing=WARN, matching probes=INFO'
