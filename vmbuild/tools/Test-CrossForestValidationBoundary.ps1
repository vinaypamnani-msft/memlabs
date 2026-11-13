<#
.SYNOPSIS
    Verifies domain-aware site lookup and null deployConfig fail-closed behavior.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $root 'common\Common.Config.ps1'
$genConfigPath = Join-Path $root 'common\Common.GenConfig.ps1'
$newLabPath = Join-Path $root 'New-Lab.ps1'

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

$script:Inventory = @()
function Get-List {
    param([string] $Type, [string] $Domain, [string] $DomainName, [bool] $SmartUpdate)
    $wantedDomain = if ($Domain) { $Domain } else { $DomainName }
    @($script:Inventory | Where-Object { -not $wantedDomain -or $_.domain -ieq $wantedDomain })
}

. (Import-TestFunction -Path $configPath -Name 'Get-SiteServerForSiteCode')
. (Import-TestFunction -Path $configPath -Name 'Get-PrimarySiteServerForSiteCode')
. (Import-TestFunction -Path $configPath -Name 'Get-PassiveSiteServerForSiteCode')
. (Import-TestFunction -Path $configPath -Name 'Get-ActiveSiteServerForSiteCode')

$deployConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'client.test' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'CLIENT-PRI'; role = 'Primary'; siteCode = 'PRI'
        },
        [pscustomobject]@{
            vmName = 'SITE-PRI'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'
            domain = 'site.test'; hidden = $true
        },
        [pscustomobject]@{
            vmName = 'SITE-CAS'; role = 'CAS'; siteCode = 'CAS'; domain = 'site.test'; hidden = $true
        },
        [pscustomobject]@{
            vmName = 'SITE-PRI-P'; role = 'PassiveSite'; siteCode = 'PRI'; domain = 'site.test'; hidden = $true
        }
    )
}
$script:Inventory = @($deployConfig.virtualMachines)

Assert-Equal 'SITE-PRI' (Get-SiteServerForSiteCode -DeployConfig $deployConfig -SiteCode PRI `
        -DomainName site.test -Type Name) `
    'Domain-aware site lookup selected a same-code site in the client forest.'
Assert-Equal 'SITE-PRI' (Get-PrimarySiteServerForSiteCode -DeployConfig $deployConfig -SiteCode PRI `
        -DomainName site.test -Type Name) `
    'Domain-aware Primary lookup selected the wrong forest.'
Assert-Equal 'SITE-PRI-P' (Get-PassiveSiteServerForSiteCode -DeployConfig $deployConfig -SiteCode PRI `
        -DomainName site.test -Type Name) `
    'Domain-aware Passive lookup dropped a hidden remote support VM.'
Assert-Equal 'SITE-PRI' (Get-ActiveSiteServerForSiteCode -DeployConfig $deployConfig -SiteCode PRI `
        -DomainName site.test -Type Name) `
    'Domain-aware active-site lookup selected the wrong forest.'

$genConfigText = Get-Content -LiteralPath $genConfigPath -Raw
if ($genConfigText -notmatch '\$DomainName\s*=\s*if \(\$thisVM\.domain\)') {
    throw 'ConvertTo-DeployConfigEx does not derive the owning domain per VM.'
}
if ($genConfigText -notmatch '(?s)"SiteSystem".+?Get-SiteServerForSiteCode.+?-DomainName \$DomainName.+?Get-PassiveSiteServerForSiteCode.+?-DomainName \$DomainName') {
    throw 'SiteSystem generation does not propagate its owning domain to site lookups.'
}
$genTokens = $null
$genErrors = $null
$genAst = [Management.Automation.Language.Parser]::ParseFile(
    $genConfigPath, [ref]$genTokens, [ref]$genErrors)
if ($genErrors.Count) { throw "Common.GenConfig.ps1 has parse errors: $($genErrors -join '; ')" }
$siteLookupNames = @(
    'Get-SiteServerForSiteCode',
    'Get-PrimarySiteServerForSiteCode',
    'Get-PassiveSiteServerForSiteCode',
    'Get-ActiveSiteServerForSiteCode',
    'Get-SqlServerForSiteCode'
)
$unscopedSiteLookups = @($genAst.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst] -or
                $node.GetCommandName() -notin $siteLookupNames) {
                return $false
            }
            return @($node.CommandElements | Where-Object {
                    $_ -is [Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -eq 'DomainName'
                }).Count -eq 0
        }, $true))
if ($unscopedSiteLookups.Count -gt 0) {
    throw "GenConfig still has unscoped site lookup(s): $(@($unscopedSiteLookups.Extent.Text) -join ' | ')"
}

$newLabText = Get-Content -LiteralPath $newLabPath -Raw
$nullGuard = $newLabText.IndexOf('Configuration validation did not produce a deployConfig', [StringComparison]::Ordinal)
$deployUse = $newLabText.IndexOf('foreach ($vm in $deployConfig.virtualMachines)', [StringComparison]::Ordinal)
if ($nullGuard -lt 0 -or $deployUse -lt 0 -or $nullGuard -gt $deployUse) {
    throw 'New-Lab can consume a null deployConfig after validation.'
}
if ($newLabText -notmatch 'Continue anyway\? \(y/N\).+?-Default "n"') {
    throw 'Validation bypass still defaults to continuing after timeout.'
}

Write-Host 'PASS -- cross-forest site lookup is domain-aware and null validation results fail closed.'
