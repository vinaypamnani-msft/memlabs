<#
.SYNOPSIS
    Verifies CM role lookups are scoped when the target server's site is known.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$relativePaths = @(
    'common\Common.Validation.Functional.ps1',
    'DSC\phases\ConfigureCMProxy.ps1',
    'DSC\phases\InstallDPMPClient.ps1',
    'DSC\phases\InstallPassiveSiteServer.ps1',
    'DSC\phases\ScriptFunctions.ps1'
)
$roleCommands = @(
    'Get-CMManagementPoint',
    'Get-CMDistributionPoint',
    'Get-CMSiteSystemServer',
    'Set-CMSiteSystemServer',
    'Get-CMSoftwareUpdatePoint',
    'Set-CMSoftwareUpdatePoint'
)
$violations = [System.Collections.Generic.List[string]]::new()

foreach ($relativePath in $relativePaths) {
    $path = Join-Path $RootPath $relativePath
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$path has parse errors: $($errors -join '; ')" }
    $commands = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in $roleCommands
            }, $true))
    foreach ($command in $commands) {
        $parameters = @($command.CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.CommandParameterAst]
            } | ForEach-Object { $_.ParameterName })
        if ($parameters -contains 'SiteSystemServerName' -and
            $parameters -notcontains 'SiteCode' -and
            $parameters -notcontains 'AllSite') {
            $violations.Add("$relativePath`:$($command.Extent.StartLineNumber): $($command.Extent.Text -replace '\s+', ' ')")
        }
    }
}
if ($violations.Count -gt 0) {
    throw "Unscoped CM role queries found:`n$($violations -join "`n")"
}

$proxyText = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\phases\ConfigureCMProxy.ps1') -Raw
if (-not $proxyText.Contains('$proxyFailures = [System.Collections.Generic.List[string]]::new()') -or
    -not $proxyText.Contains('$Configuration.ConfigureCMProxy.Status = ''NotStart''') -or
    $proxyText -notmatch '(?s)ConfigureCMProxy has \$\(\$proxyFailures\.Count\) retryable failure\(s\).+?-Failure') {
    throw 'ConfigureCMProxy does not preserve requested proxy failures as an explicit retryable workflow failure.'
}

Write-Host 'PASS -- CM role queries with a target server also specify its owning site code.'
