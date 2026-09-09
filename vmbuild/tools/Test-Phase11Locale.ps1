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
$validationText = Get-Content -LiteralPath $validationPath -Raw
$probe = Get-TestNestedScriptBlock -Path $validationPath -FunctionName 'Test-LocaleFunctionality' -VariableName '$scriptBlock'
$timeSyncEvidence = Get-TestNestedScriptBlock -Path $validationPath -FunctionName 'Test-DomainMemberFunctionality' -VariableName '$getTimeSyncEvidence'
. (Import-TestFunction -Path $validationPath -Name 'Test-LocaleFunctionality')
$capabilities = @('Basic', 'Handwriting', 'OCR', 'Speech', 'TextToSpeech')
$serverArguments = @('ja-JP', 'ja-JP', 'ja-JP', ($capabilities -join ','), $true)
$clientArguments = @('ja-JP', 'ja-JP', 'ja-JP', ($capabilities -join ','), $false)

Write-Host "engine : $($PSVersionTable.PSVersion)"
Assert-Equal $true ($validationText -match 'INFO: Windows Time secondary evidence unavailable \(\$diagnostic\)') 'successful sync surfaces secondary collector failures as informational evidence'
Assert-Equal $true ($validationText -match '\$syncExitCode = \$LASTEXITCODE') 'repadmin validation captures the native exit code immediately'
Assert-Equal $true ($validationText -match 'if \(\$syncExitCode -eq 0\)') 'localized repadmin success is decided by exit code'
Assert-Equal $false ($validationText -match "SyncAll terminated with no errors") 'repadmin validation does not parse English success text'

$japaneseW32tm = @(
    'localized leap indicator: 0'
    'localized last sync label: 2026/09/08 11:23:23'
)
$testNow = [datetimeoffset]'2026-09-08T16:00:00Z'
$structuredTimeStatus = @([pscustomobject]@{ Name = 'LastSuccessfulSyncTime'; Value = '2026-09-08T15:23:23.566Z' })
$structuredEvidenceOutput = @(& $timeSyncEvidence $japaneseW32tm 0 $structuredTimeStatus $null $testNow @())
Assert-Equal 1 $structuredEvidenceOutput.Count 'structured time evaluator returns exactly one result'
$structuredEvidence = $structuredEvidenceOutput[0]
Assert-Equal $true $structuredEvidence.Synchronized 'Japanese w32tm output passes with structured last-sync evidence'
Assert-Equal 'last successful sync 2026-09-08T15:23:23.566Z' $structuredEvidence.Evidence 'structured sync evidence remains language-neutral'

$structuredWithCollectorFailure = & $timeSyncEvidence $japaneseW32tm 0 $structuredTimeStatus $null $testNow @('W32Time counter query failed: unavailable')
Assert-Equal 'W32Time counter query failed: unavailable' ($structuredWithCollectorFailure.Diagnostics -join ',') 'successful evidence preserves secondary collector failures'

$sourceEvidence = & $timeSyncEvidence $japaneseW32tm 0 @() ([pscustomobject]@{ NTPClientTimeSourceCount = 1 }) $testNow @()
Assert-Equal $false $sourceEvidence.Synchronized 'active W32Time source alone does not prove successful synchronization'

$englishEvidence = & $timeSyncEvidence @('Last Successful Sync Time: 9/8/2026 11:23:23 AM') 0 @() $null $testNow @()
Assert-Equal $true $englishEvidence.Synchronized 'older English systems retain the w32tm text fallback'

$missingTimeEvidence = & $timeSyncEvidence $japaneseW32tm 0 @() ([pscustomobject]@{ NTPClientTimeSourceCount = 0 }) $testNow @()
Assert-Equal $false $missingTimeEvidence.Synchronized 'time validation warns when no structured sync evidence or active source exists'

$uninitializedTimeStatus = @([pscustomobject]@{ Name = 'LastSuccessfulSyncTime'; Value = '1601-01-01T00:00:00.000Z' })
$uninitializedEvidence = & $timeSyncEvidence $japaneseW32tm 0 $uninitializedTimeStatus ([pscustomobject]@{ NTPClientTimeSourceCount = 0 }) $testNow @()
Assert-Equal $false $uninitializedEvidence.Synchronized 'uninitialized FILETIME epoch is not accepted as a successful sync'

$staleTimeStatus = @([pscustomobject]@{ Name = 'LastSuccessfulSyncTime'; Value = '2026-09-01T15:23:23.566Z' })
$staleEvidence = & $timeSyncEvidence $japaneseW32tm 0 $staleTimeStatus $null $testNow @()
Assert-Equal $false $staleEvidence.Synchronized 'structured sync evidence older than 24 hours is rejected'

$invalidEnglishEvidence = & $timeSyncEvidence @('Last Successful Sync Time: unspecified') 0 @() $null $testNow @()
Assert-Equal $false $invalidEnglishEvidence.Synchronized 'English fallback requires a parseable recent timestamp'

$failedTimeQuery = & $timeSyncEvidence @('localized error') 5 $structuredTimeStatus ([pscustomobject]@{ NTPClientTimeSourceCount = 1 }) $testNow @()
Assert-Equal $false $failedTimeQuery.Synchronized 'failed w32tm query is not hidden by a stale source counter'

$collectorFailureOutput = @(& $timeSyncEvidence $japaneseW32tm 0 @() $null $testNow @('event 260 query failed: unavailable'))
Assert-Equal 1 $collectorFailureOutput.Count 'warning time evaluator returns exactly one result'
$collectorFailure = $collectorFailureOutput[0]
Assert-Equal $true ($collectorFailure.Evidence -like '*event 260 query failed: unavailable*') 'collector failures remain visible in warning evidence'

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

$russianArguments = @('ru-RU', 'ru-RU', 'ru-RU', ($capabilities -join ','), $true)
$script:MuiLanguages = @('en-US', 'ru-RU')
$script:SystemLocale = 'ru-RU'
$script:PreferredUILanguage = 'ru'
$neutralPreferredUi = & $probe @russianArguments
Assert-Equal $true $neutralPreferredUi.Passed 'neutral parent system preferred UI language matches the configured regional language'
Assert-Equal 1 @($neutralPreferredUi.Details | Where-Object { $_ -eq "OK: System preferred UI language 'ru' is the neutral parent of 'ru-RU'" }).Count 'neutral parent success reports both language values'
$script:PreferredUILanguage = 'en'
$wrongNeutralPreferredUi = & $probe @russianArguments
Assert-Equal $false $wrongNeutralPreferredUi.Passed 'unrelated neutral system preferred UI language fails'
$script:MuiLanguages = @('en-US', 'ja-JP')
$script:SystemLocale = 'ja-JP'
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