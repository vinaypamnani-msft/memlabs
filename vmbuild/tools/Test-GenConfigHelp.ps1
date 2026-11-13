<#
.SYNOPSIS
    Verifies context help for GenConfig menus and shipped configuration properties.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) { throw "Expected one $Name definition, found $($functions.Count)." }
    [scriptblock]::Create($functions[0].Extent.Text)
}

function Assert-Help {
    param([string] $Label, [string] $HelpFunction = 'Get-GenericHelp')

    $expected = & $HelpFunction -text $Label
    if ($expected -isnot [string] -or [string]::IsNullOrWhiteSpace($expected) -or $expected -like 'Help Missing*') {
        throw "$HelpFunction has no help for '$Label'."
    }

    foreach ($text in @("$($Label.PadRight(26)) = True", "  $($Label.ToUpperInvariant())  = value=with=equals")) {
        $actual = & $HelpFunction -text $text
        if ($actual -isnot [string] -or $actual -cne $expected) {
            throw "$HelpFunction did not resolve formatted menu text '$text' to the help for '$Label'."
        }
    }
}

$genericHelp = Import-TestFunction -Path (Join-Path $RootPath 'common\Common.GenConfig.Help.ps1') -Name 'Get-GenericHelp'
$sortedProperties = Import-TestFunction -Path (Join-Path $RootPath 'common\Common.GenConfig.Summary.ps1') -Name 'Get-SortedProperties'
. $genericHelp
. $sortedProperties
. (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.GenConfig.NewDomain.ps1') -Name 'Get-NewDomainConfigHelp')
. (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.GenConfig.PKIMenus.ps1') -Name 'Get-PKIHelp')

$order = $sortedProperties.Ast.Find({
        param($node)
        $node -is [Management.Automation.Language.HashtableAst]
    }, $true)
if ($null -eq $order) { throw 'Could not find the GenConfig menu property order.' }

$genericLabels = @{ 'Done with changes' = $true }
foreach ($label in (Get-SortedProperties -property ([pscustomobject]($order.SafeGetValue())))) {
    $genericLabels[$label] = $true
}

$helpSwitch = $genericHelp.Ast.Find({
        param($node)
        $node -is [Management.Automation.Language.SwitchStatementAst]
    }, $true)
if ($null -eq $helpSwitch) { throw 'Could not find the generic help definitions.' }
foreach ($clause in $helpSwitch.Clauses) {
    $genericLabels[$clause.Item1.SafeGetValue()] = $true
}

$fixtures = @(Get-ChildItem -LiteralPath (Join-Path $RootPath 'config\tests') -Filter '*.json' -File)
if (-not $fixtures.Count) { throw 'No GenConfig configuration fixtures were found.' }
foreach ($file in $fixtures) {
    $config = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $blocks = @($config.vmOptions, $config.cmOptions) + @($config.virtualMachines) + @($config.virtualMachines.cmOptions)
    foreach ($block in $blocks) {
        if ($null -eq $block) { continue }
        foreach ($label in (Get-SortedProperties -property $block)) {
            $genericLabels[$label] = $true
        }
    }
}

$missing = @(
    foreach ($label in ($genericLabels.Keys | Sort-Object)) {
        $help = Get-GenericHelp -text $label
        if ($help -isnot [string] -or [string]::IsNullOrWhiteSpace($help) -or $help -like 'Help Missing*') {
            $label
        }
    }
)
if ($missing.Count) { throw "Missing generic help for: $($missing -join ', ')." }
foreach ($label in $genericLabels.Keys) {
    Assert-Help -Label $label
}

$wizard = Import-TestFunction -Path (Join-Path $RootPath 'common\Common.GenConfig.NewDomain.ps1') -Name 'Select-NewDomainConfig'
$defaults = $wizard.Ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'domainDefaults'
    }, $true)
if ($null -eq $defaults) { throw 'Could not find the new-domain wizard defaults.' }
$defaultProperties = $defaults.Right.Find({
        param($node)
        $node -is [Management.Automation.Language.HashtableAst]
    }, $true)
if ($null -eq $defaultProperties) { throw 'Could not find the new-domain wizard property definitions.' }
foreach ($pair in $defaultProperties.KeyValuePairs) {
    Assert-Help -Label $pair.Item1.SafeGetValue() -HelpFunction 'Get-NewDomainConfigHelp'
}
Assert-Help -Label 'Done with changes' -HelpFunction 'Get-NewDomainConfigHelp'

$pkiLabels = @('EnablePKI', 'IssuingCA', 'UseOfflineRoot', 'OfflineRootCA', 'UsePKI for ConfigMgr', 'UsePKI on PS1SITE', 'Done with changes')
foreach ($label in $pkiLabels) {
    Assert-Help -Label $label -HelpFunction 'Get-PKIHelp'
}

$unknown = 'UnknownSetting = True'
foreach ($helpFunction in @('Get-GenericHelp', 'Get-NewDomainConfigHelp')) {
    if ((& $helpFunction -text $unknown) -cne "Help Missing for $unknown") {
        throw "$helpFunction no longer reports unknown settings."
    }
}

Write-Host "Validated $($genericLabels.Count) generic help labels, $($defaultProperties.KeyValuePairs.Count + 1) wizard labels, and $($pkiLabels.Count) PKI labels across $($fixtures.Count) configuration fixtures."
