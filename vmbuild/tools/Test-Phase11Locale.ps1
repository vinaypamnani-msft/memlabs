<#
.SYNOPSIS
    Verifies the Phase 11 selected-language validation probe.

.DESCRIPTION
    Exercises healthy and failing machine-level locale states without a VM.
    Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
$script:MuiLanguages = @('en-US', 'ja-JP')
$script:SystemLocale = 'ja-JP'
$script:PreferredUILanguage = 'ja-JP'
$script:PreferredUiCommandAvailable = $true
$script:SystemPreferredUILanguages = @('ja-JP')
$script:SystemPreferredUiReadFails = $false
$script:MissingCapability = $null

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Get-TestNestedScriptBlock {
    param (
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $FunctionName,
        [Parameter(Mandatory)][string] $VariableName
    )

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $errorCount = ($errors | Where-Object { $null -ne $_ }).Count
    if ($errorCount -ne 0) { throw "$Path has $errorCount parse error(s)" }
    $function = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
            }, $true))
    if ($function.Count -ne 1) { throw "Expected one $FunctionName definition, found $($function.Count)" }
    $assignment = @($function[0].FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $VariableName
            }, $true))
    if ($assignment.Count -ne 1) { throw "Expected one $VariableName assignment in $FunctionName, found $($assignment.Count)" }
    return $assignment[0].Right.Expression.ScriptBlock.GetScriptBlock()
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $errorCount = ($errors | Where-Object { $null -ne $_ }).Count
    if ($errorCount -ne 0) { throw "$Path has $errorCount parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Get-CimInstance {
    [pscustomobject]@{ MUILanguages = @($script:MuiLanguages) }
}

function Get-WinSystemLocale {
    [pscustomobject]@{ Name = $script:SystemLocale }
}

function Get-SystemPreferredUILanguage {
    $script:PreferredUILanguage
}

function Get-Command {
    param ([string] $Name)

    if ($Name -eq 'Get-SystemPreferredUILanguage' -and $script:PreferredUiCommandAvailable) {
        return [pscustomobject]@{ Name = $Name }
    }
    return $null
}

function Get-ItemPropertyValue {
    if ($script:SystemPreferredUiReadFails) { throw 'registry unavailable' }
    return $script:SystemPreferredUILanguages
}

function Get-WindowsCapability {
    param ([string] $Name)

    $state = if ($script:MissingCapability -and $Name -like "Language.$($script:MissingCapability)~~~*") { 'NotPresent' } else { 'Installed' }
    [pscustomobject]@{ Name = $Name; State = $state }
}

$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$probe = Get-TestNestedScriptBlock -Path $validationPath -FunctionName 'Test-LocaleFunctionality' -VariableName '$scriptBlock'
. (Import-TestFunction -Path $validationPath -Name 'Test-LocaleFunctionality')
$capabilities = @('Basic', 'Handwriting', 'OCR', 'Speech', 'TextToSpeech')
$serverArguments = @('ja-JP', 'ja-JP', 'ja-JP', ($capabilities -join ','), $true)
$clientArguments = @('ja-JP', 'ja-JP', 'ja-JP', ($capabilities -join ','), $false)

Write-Host "engine : $($PSVersionTable.PSVersion)"

$healthy = & $probe @serverArguments
Assert-Equal $true $healthy.Passed 'matching MUI, system locale, and capabilities pass'
Assert-Equal 8 ($healthy.Details | Where-Object { $null -ne $_ }).Count 'healthy Japanese probe measures every expected fact'

$script:MuiLanguages = @('en-US')
$missingMui = & $probe @serverArguments
Assert-Equal $false $missingMui.Passed 'missing selected MUI language fails'
Assert-Equal 1 @($missingMui.Details | Where-Object { $_ -like "FAIL: Installed MUI languages*" }).Count 'MUI failure is actionable'
$script:MuiLanguages = @('en-US', 'ja-JP')

$script:SystemLocale = 'en-US'
$wrongSystemLocale = & $probe @serverArguments
Assert-Equal $false $wrongSystemLocale.Passed 'wrong system locale fails'
Assert-Equal 1 @($wrongSystemLocale.Details | Where-Object { $_ -like "FAIL: System locale*" }).Count 'system-locale failure is actionable'
$script:SystemLocale = 'ja-JP'

$script:PreferredUILanguage = 'en-US'
$wrongPreferredUi = & $probe @serverArguments
Assert-Equal $false $wrongPreferredUi.Passed 'wrong system preferred UI language fails'
Assert-Equal 1 @($wrongPreferredUi.Details | Where-Object { $_ -like "FAIL: System preferred UI language*" }).Count 'preferred-UI failure is actionable'
$script:PreferredUILanguage = 'ja-JP'

$script:PreferredUiCommandAvailable = $false
$fallbackPreferredUi = & $probe @serverArguments
Assert-Equal $true $fallbackPreferredUi.Passed 'Server 2022 reads LanguageDsc SYSTEM preferred UI language'
$script:SystemPreferredUILanguages = @()
$missingFallbackUi = & $probe @serverArguments
Assert-Equal $false $missingFallbackUi.Passed 'missing SYSTEM preferred UI language fails closed'
Assert-Equal 1 @($missingFallbackUi.Details | Where-Object { $_ -like "FAIL: Could not read system preferred UI language*" }).Count 'empty SYSTEM preferred UI fallback is actionable'
$script:SystemPreferredUILanguages = @('ja-JP')
$script:SystemPreferredUiReadFails = $true
$failedFallbackUi = & $probe @serverArguments
Assert-Equal $false $failedFallbackUi.Passed 'failed SYSTEM preferred-UI registry query fails closed'
$script:SystemPreferredUiReadFails = $false
$script:PreferredUiCommandAvailable = $true

$script:MissingCapability = 'OCR'
$missingCapability = & $probe @serverArguments
Assert-Equal $false $missingCapability.Passed 'missing required Server capability fails'
Assert-Equal 1 @($missingCapability.Details | Where-Object { $_ -like "FAIL: Language.OCR*" }).Count 'capability failure identifies the missing package'

$clientProbe = & $probe @clientArguments
Assert-Equal $true $clientProbe.Passed 'Windows Update client route does not require Server CAB capabilities'
Assert-Equal 3 ($clientProbe.Details | Where-Object { $null -ne $_ }).Count 'client route measures only machine locale facts'

function Write-Log { param() }
function Invoke-VmCommand {
    param ([scriptblock] $ScriptBlock, [object[]] $ArgumentList)

    $script:CapturedArguments = @($ArgumentList)
    [pscustomobject]@{ ScriptBlockOutput = (& $ScriptBlock @ArgumentList); ScriptBlockFailed = $false }
}
function Format-TestResult {
    param ([object] $Result)

    return [bool]$Result.ScriptBlockOutput.Passed
}

$domainDefaultConfig = [pscustomobject]@{
    domainDefaults = [pscustomobject]@{ DefaultLocale = 'ja-JP' }
    vmOptions = [pscustomobject]@{ localeSettings = [pscustomobject]@{ MUILanguage = 'ja-JP'; SystemLocale = 'ja-JP'; LanguageCapabilities = $capabilities } }
}
$legacyItem = [pscustomobject]@{ localeAcquisition = 'WindowsUpdate' }
$wrapperPassed = Test-LocaleFunctionality -VMName 'CLIENT1' -Domain 'example.test' -CurrentItem $legacyItem -DeployConfig $domainDefaultConfig
Assert-Equal $true $wrapperPassed 'wrapper validates a domain-default locale when the VM field is absent'
Assert-Equal 'ja-JP' $script:CapturedArguments[0] 'wrapper uses the Phase 3 domain-default fallback'
Assert-Equal 'ja-JP' $script:CapturedArguments[1] 'wrapper passes the configured MUI language'
Assert-Equal 'ja-JP' $script:CapturedArguments[2] 'wrapper passes the configured system locale'
$legacyItem.PSObject.Properties.Remove('localeAcquisition')
$legacyServerPassed = Test-LocaleFunctionality -VMName 'SERVER1' -Domain 'example.test' -CurrentItem $legacyItem -DeployConfig $domainDefaultConfig
Assert-Equal $true $legacyServerPassed 'wrapper defaults legacy locale acquisition to Server media validation'
Assert-Equal $true $script:CapturedArguments[4] 'legacy Server profile checks declared language capabilities'

$customItem = [pscustomobject]@{
    locale = 'ja-JP'
    localeAcquisition = 'WindowsUpdate'
    localeSettings = [pscustomobject]@{ MUILanguage = 'ja-JP'; SystemLocale = 'en-US'; LanguageCapabilities = @() }
}
$script:SystemLocale = 'en-US'
$customSystemLocalePassed = Test-LocaleFunctionality -VMName 'CUSTOM1' -Domain 'example.test' -CurrentItem $customItem -DeployConfig $domainDefaultConfig
Assert-Equal $true $customSystemLocalePassed 'wrapper honors a profile system locale that differs from its language tag'
Assert-Equal 'en-US' $script:CapturedArguments[2] 'custom profile system locale reaches the guest probe'
$script:SystemLocale = 'ja-JP'

$validationSource = Get-Content -LiteralPath $validationPath -Raw
Assert-Equal $true ($validationSource -match 'Test-LocaleFunctionality -VMName \$VMName.+-DeployConfig \$DeployConfig') 'Phase 11 dispatcher invokes locale validation with config context'

if ($script:Failures -ne 0) {
    throw "$script:Failures Phase 11 locale test(s) failed"
}

Write-Host 'ALL PHASE 11 LOCALE TESTS PASSED' -ForegroundColor Green