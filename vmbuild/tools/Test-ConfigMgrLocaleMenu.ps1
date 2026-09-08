<#
.SYNOPSIS
    Verifies the locale menu exposes only ConfigMgr-supported languages.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$Path has $($errors.Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    if ("$Expected" -ne "$Actual") {
        throw "$What`: expected '$Expected', actual '$Actual'"
    }
    Write-Host "PASS  $What"
}

function Get-Menu2 {
    param (
        [string] $MenuName,
        [string] $Prompt,
        [object[]] $OptionArray,
        [string] $CurrentValue
    )

    $script:MenuOptions = @($OptionArray)
    $script:MenuCurrentValue = $CurrentValue
    return $CurrentValue
}

function Get-LocaleAcquisitionMethod { return 'MicrosoftMedia' }
function Clear-LocaleMediaIsoValidationCache { }
function Get-LocaleDefinitionForOperatingSystem { param($LocaleDefinition) return $LocaleDefinition }

$sourcePath = Join-Path $RootPath 'common\Common.GenConfig.NewDomain.ps1'
. (Import-TestFunction -Path $sourcePath -Name 'Get-LocaleProfiles')
. (Import-TestFunction -Path $sourcePath -Name 'Select-Locale')

$global:Common = [pscustomobject]@{ ConfigPath = (Join-Path $RootPath 'config') }
$catalogPath = Join-Path $RootPath 'common\LocaleCatalog.json'
$expected = @(
    'en-US', 'cs-CZ', 'de-DE', 'es-ES', 'fr-FR', 'hu-HU', 'it-IT', 'ja-JP', 'ko-KR',
    'nl-NL', 'pl-PL', 'pt-BR', 'pt-PT', 'ru-RU', 'sv-SE', 'tr-TR', 'zh-CN', 'zh-TW'
)

$config = [pscustomobject]@{ vmOptions = [pscustomobject]@{ locale = 'en-US' } }
$null = Select-Locale -ConfigToCheck $config -CatalogPath $catalogPath
Assert-Equal 18 $script:MenuOptions.Count 'menu includes built-in English plus 17 ConfigMgr language packs'
Assert-Equal (($expected | Sort-Object) -join ',') (($script:MenuOptions | Sort-Object) -join ',') 'menu contains the exact ConfigMgr locale set'

$unsupportedTarget = [pscustomobject]@{ locale = 'fr-CA' }
$null = Select-Locale -ConfigToCheck $config -Target $unsupportedTarget -CatalogPath $catalogPath
Assert-Equal 'en-US' $script:MenuCurrentValue 'unsupported saved locale falls back to English in the menu'
Assert-Equal 'en-US' $unsupportedTarget.locale 'unsupported saved locale is replaced by a supported selection'

Write-Host 'ALL CONFIGMGR LOCALE MENU TESTS PASSED' -ForegroundColor Green