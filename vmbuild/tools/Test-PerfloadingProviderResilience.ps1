<#
.SYNOPSIS
    Verifies that the final noncritical collection refresh cannot abort perfloading.
#>
[CmdletBinding()]
param()

$perfloadingPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\perfloading.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $perfloadingPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "perfloading.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$refreshCommand = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Get-CMCollection' -and
        $node.Extent.Text -match 'All Unknown Computers'
    }, $true)
if (-not $refreshCommand) {
    throw 'The All Unknown Computers refresh lookup was not found.'
}

$tryStatement = $refreshCommand.Parent
while ($tryStatement -and $tryStatement -isnot [System.Management.Automation.Language.TryStatementAst]) {
    $tryStatement = $tryStatement.Parent
}
if (-not $tryStatement -or $tryStatement.CatchClauses.Count -eq 0) {
    throw 'The All Unknown Computers refresh is not protected by a catch block.'
}

$refreshText = $tryStatement.Extent.Text
if ($refreshText -notmatch 'Get-CMCollection[\s\S]+?-ErrorAction\s+Stop') {
    throw 'The collection lookup does not promote provider errors into the resilience catch block.'
}
if ($refreshText -notmatch 'Invoke-CMCollectionUpdate[\s\S]+?-ErrorAction\s+Stop') {
    throw 'The collection update does not promote provider errors into the resilience catch block.'
}
if ($refreshText -notmatch 'Could not refresh All Unknown Computers') {
    throw 'The resilience catch block does not emit an actionable warning.'
}

Write-Host 'PASS -- transient provider errors cannot abort the final perfloading collection refresh.'
