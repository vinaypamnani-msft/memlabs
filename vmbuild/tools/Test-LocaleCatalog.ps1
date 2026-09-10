<#
.SYNOPSIS
    Verifies catalog-backed locale selection and Japanese profile hydration.

.DESCRIPTION
    Executes the GenConfig locale picker with the shipped catalog and proves
    that selecting ja-JP embeds all settings consumed by guest deployment.
    Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
$script:MenuOptions = @()

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

function Assert-True {
    param ([bool] $Condition, [string] $What)

    Assert-Equal -Expected $true -Actual $Condition -What $What
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "$Path has $(@($errors).Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Get-Menu2 {
    param ([string] $MenuName, [string] $Prompt, [object[]] $OptionArray, [string] $CurrentValue)

    $script:MenuOptions = @($OptionArray)
    if ($script:MenuLocale) { return $script:MenuLocale }
    return 'ja-JP'
}

function Write-Log {
    param ([string] $Message, [switch] $Warning)

    if ($Warning) { Write-Host "WARN  $Message" }
}

$sourcePath = Join-Path $RootPath 'common\Common.GenConfig.NewDomain.ps1'
$localeModulePath = Join-Path $RootPath 'common\Common.Locale.ps1'
$summaryPath = Join-Path $RootPath 'common\Common.GenConfig.Summary.ps1'
. (Import-TestFunction -Path $localeModulePath -Name 'Get-LocaleMediaSource')
. (Import-TestFunction -Path $localeModulePath -Name 'Get-LocaleDefinitionForOperatingSystem')
. (Import-TestFunction -Path $localeModulePath -Name 'Get-LocaleMediaFiles')
. (Import-TestFunction -Path $localeModulePath -Name 'Test-LocaleMediaFiles')
. (Import-TestFunction -Path $localeModulePath -Name 'Test-LocaleMediaIso')
. (Import-TestFunction -Path $localeModulePath -Name 'Clear-LocaleMediaIsoValidationCache')
. (Import-TestFunction -Path $localeModulePath -Name 'Get-LocaleMediaMutexName')
. (Import-TestFunction -Path $localeModulePath -Name 'Initialize-LocaleMedia')
. (Import-TestFunction -Path $localeModulePath -Name 'Initialize-LocaleMediaForPhase2')
. (Import-TestFunction -Path $localeModulePath -Name 'Get-Phase3LocaleMediaIssues')
. (Import-TestFunction -Path $localeModulePath -Name 'Update-CatalogLocaleSettings')
. (Import-TestFunction -Path $sourcePath -Name 'Get-LocaleProfiles')
. (Import-TestFunction -Path $sourcePath -Name 'Get-LocaleAcquisitionMethod')
. (Import-TestFunction -Path $sourcePath -Name 'Set-DefaultLocaleForVM')
. (Import-TestFunction -Path $sourcePath -Name 'Initialize-PerVmLocales')
. (Import-TestFunction -Path $sourcePath -Name 'Select-Locale')
. (Import-TestFunction -Path $summaryPath -Name 'Get-SortedProperties')

$global:Common = [pscustomobject]@{ ConfigPath = (Join-Path $RootPath 'config'); AzureFilesPath = (Join-Path $RootPath 'azureFiles') }
$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ locale = 'en-US' }
}

Write-Host "engine : $($PSVersionTable.PSVersion)"
$catalogPath = Join-Path $RootPath 'common\LocaleCatalog.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$catalogTags = @($catalog.PSObject.Properties.Name | Sort-Object)
$expectedTags = @(
    'ar-SA', 'bg-BG', 'cs-CZ', 'da-DK', 'de-DE', 'el-GR', 'en-GB', 'en-US', 'es-ES', 'es-MX',
    'et-EE', 'fi-FI', 'fr-CA', 'fr-FR', 'he-IL', 'hr-HR', 'hu-HU', 'it-IT', 'ja-JP', 'ko-KR',
    'lt-LT', 'lv-LV', 'nb-NO', 'nl-NL', 'pl-PL', 'pt-BR', 'pt-PT', 'ro-RO', 'ru-RU', 'sk-SK',
    'sl-SI', 'sr-Latn-RS', 'sv-SE', 'th-TH', 'tr-TR', 'uk-UA', 'zh-CN', 'zh-TW'
) | Sort-Object
Assert-Equal -Expected 38 -Actual $catalogTags.Count -What 'catalog contains the 38-language Server and Windows client intersection'
Assert-Equal -Expected ($expectedTags -join ',') -Actual ($catalogTags -join ',') -What 'catalog language tags match the measured intersection'
Assert-True -Condition ($catalog.'ar-SA'.PSObject.Properties.Name -contains 'RemoveInputLanguages') -What 'Arabic explicitly defines input languages to remove'
Assert-True -Condition ($catalog.'ar-SA'.RemoveInputLanguages -is [array]) -What 'Arabic input-language removal remains an array'
Assert-Equal -Expected 0 -Actual $catalog.'ar-SA'.RemoveInputLanguages.Count -What 'Arabic retains the Windows English fallback input method'
Assert-Equal -Expected 0 -Actual $catalog.'ru-RU'.RemoveInputLanguages.Count -What 'Russian retains the Windows English fallback input method'

$server2022Capabilities = @{
    'ar-SA' = 'Basic,OCR,TextToSpeech'; 'bg-BG' = 'Basic,OCR,TextToSpeech'; 'cs-CZ' = 'Basic,Handwriting,OCR,TextToSpeech'
    'da-DK' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'; 'de-DE' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'
    'el-GR' = 'Basic,Handwriting,OCR,TextToSpeech'; 'en-GB' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'
    'es-ES' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'; 'es-MX' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'
    'et-EE' = 'Basic'; 'fi-FI' = 'Basic,Handwriting,OCR,TextToSpeech'; 'fr-CA' = 'Basic,OCR,Speech,TextToSpeech'
    'fr-FR' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'; 'he-IL' = 'Basic,TextToSpeech'
    'hr-HR' = 'Basic,Handwriting,OCR,TextToSpeech'; 'hu-HU' = 'Basic,OCR,TextToSpeech'
    'it-IT' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'; 'ja-JP' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'
    'ko-KR' = 'Basic,Handwriting,OCR,TextToSpeech'; 'lt-LT' = 'Basic'; 'lv-LV' = 'Basic'
    'nb-NO' = 'Basic,Handwriting,OCR,TextToSpeech'; 'nl-NL' = 'Basic,Handwriting,OCR,TextToSpeech'
    'pl-PL' = 'Basic,Handwriting,OCR,TextToSpeech'; 'pt-BR' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'
    'pt-PT' = 'Basic,Handwriting,OCR,TextToSpeech'; 'ro-RO' = 'Basic,Handwriting,OCR,TextToSpeech'
    'ru-RU' = 'Basic,Handwriting,OCR,TextToSpeech'; 'sk-SK' = 'Basic,Handwriting,OCR,TextToSpeech'
    'sl-SI' = 'Basic,Handwriting,OCR,TextToSpeech'; 'sr-Latn-RS' = 'Basic,Handwriting,OCR'
    'sv-SE' = 'Basic,Handwriting,OCR,TextToSpeech'; 'th-TH' = 'Basic,TextToSpeech'
    'tr-TR' = 'Basic,Handwriting,OCR,TextToSpeech'; 'uk-UA' = 'Basic'
    'zh-CN' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'; 'zh-TW' = 'Basic,Handwriting,OCR,Speech,TextToSpeech'
}
$server2025Capabilities = @{}
foreach ($tag in $server2022Capabilities.Keys) { $server2025Capabilities[$tag] = $server2022Capabilities[$tag] }
$server2025Capabilities['bg-BG'] = 'Basic,Handwriting,OCR,TextToSpeech'
$server2025Capabilities['et-EE'] = 'Basic,Handwriting'
$server2025Capabilities['he-IL'] = 'Basic,Handwriting,TextToSpeech'
$server2025Capabilities['hu-HU'] = 'Basic,Handwriting,OCR,TextToSpeech'
$server2025Capabilities['lt-LT'] = 'Basic,Handwriting'
$server2025Capabilities['lv-LV'] = 'Basic,Handwriting'
$server2025Capabilities['th-TH'] = 'Basic,Handwriting,TextToSpeech'
$server2025Capabilities['uk-UA'] = 'Basic,Handwriting'

$nativeCMLanguages = @{
    'en-US' = 'ENG'; 'zh-CN' = 'CHS'; 'zh-TW' = 'CHT'; 'cs-CZ' = 'CSY'; 'de-DE' = 'DEU'
    'es-ES' = 'ESN'; 'es-MX' = 'ESN'; 'fr-CA' = 'FRA'; 'fr-FR' = 'FRA'; 'hu-HU' = 'HUN'
    'it-IT' = 'ITA'; 'ja-JP' = 'JPN'; 'ko-KR' = 'KOR'; 'nl-NL' = 'NLD'; 'pl-PL' = 'PLK'
    'pt-BR' = 'PTB'; 'pt-PT' = 'PTG'; 'ru-RU' = 'RUS'; 'sv-SE' = 'SVE'; 'tr-TR' = 'TRK'
}

foreach ($tag in $expectedTags) {
    $localeProfile = $catalog.PSObject.Properties[$tag].Value
    $culture = [Globalization.CultureInfo]::GetCultureInfo($tag)
    $region = New-Object Globalization.RegionInfo($tag)
    $canonicalTips = @((New-WinUserLanguageList -Language $tag)[0].InputMethodTips)
    Assert-Equal -Expected $culture.LCID -Actual $localeProfile.LanguageID -What "$tag uses the Windows LCID"
    Assert-Equal -Expected $region.GeoId -Actual $localeProfile.LocationID -What "$tag uses the Windows GeoID"
    Assert-Equal -Expected ($canonicalTips -join ',') -Actual (@($localeProfile.AddInputLanguages) -join ',') -What "$tag uses the canonical Windows input method"
    $expectedCMLanguage = if ($nativeCMLanguages.ContainsKey($tag)) { $nativeCMLanguages[$tag] } else { 'ENG' }
    Assert-Equal -Expected $expectedCMLanguage -Actual $localeProfile.CMLanguage -What "$tag uses an available ConfigMgr 2509 language"

    if ($tag -eq 'en-US') { continue }
    Assert-Equal -Expected 2 -Actual ($localeProfile.MediaSources | Where-Object { $null -ne $_ }).Count -What "$tag has Server 2022 and 2025 media sources"
    Assert-Equal -Expected 'Windows 11*' -Actual @($localeProfile.WindowsUpdateOperatingSystems)[0] -What "$tag is available to Windows 11 clients"
    $server2022Profile = Get-LocaleDefinitionForOperatingSystem -LocaleDefinition $localeProfile -OperatingSystem 'Server 2022'
    $server2025Profile = Get-LocaleDefinitionForOperatingSystem -LocaleDefinition $localeProfile -OperatingSystem 'Server 2025'
    Assert-Equal -Expected $server2022Capabilities[$tag] -Actual (@($server2022Profile.LanguageCapabilities) -join ',') -What "$tag matches the Server 2022 capability set"
    Assert-Equal -Expected $server2025Capabilities[$tag] -Actual (@($server2025Profile.LanguageCapabilities) -join ',') -What "$tag matches the Server 2025 capability set"
}

$selected = Select-Locale -ConfigToCheck $config -CatalogPath $catalogPath

Assert-Equal -Expected 'ja-JP' -Actual $selected -What 'Japanese can be selected from the locale menu'
Assert-True -Condition ($script:MenuOptions -contains 'en-US') -What 'menu includes the default locale'
Assert-True -Condition ($script:MenuOptions -contains 'ja-JP') -What 'menu includes the catalog Japanese locale'
Assert-Equal -Expected 'ja-JP' -Actual $config.vmOptions.localeSettings.LanguageTag -What 'selection embeds the language tag'
Assert-Equal -Expected 122 -Actual $config.vmOptions.localeSettings.LocationID -What 'selection embeds the Japan GeoID'
Assert-Equal -Expected 1041 -Actual $config.vmOptions.localeSettings.LanguageID -What 'selection embeds the Japanese LCID'
Assert-Equal -Expected 'JPN' -Actual $config.vmOptions.localeSettings.CMLanguage -What 'selection embeds the ConfigMgr language code'
Assert-Equal -Expected '0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}' -Actual @($config.vmOptions.localeSettings.AddInputLanguages)[0] -What 'selection embeds the Japanese Microsoft IME TIP'
$roundTrip = $config | ConvertTo-Json -Depth 5 | ConvertFrom-Json
Assert-Equal -Expected 'ja-JP' -Actual $roundTrip.vmOptions.localeSettings.LanguageTag -What 'embedded profile survives config serialization'
Assert-Equal -Expected '0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}' -Actual @($roundTrip.vmOptions.localeSettings.AddInputLanguages)[0] -What 'input language survives config serialization'

$staleProfileConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{
        locale = 'ja-JP'
        localeSettings = [pscustomobject]@{ LanguageTag = 'ja-JP'; AddInputLanguages = @('0411:00000411') }
    }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'STALE-JP'
            locale = 'ja-JP'
            localeSettings = [pscustomobject]@{ LanguageTag = 'ja-JP'; AddInputLanguages = @('0411:00000411') }
        },
        [pscustomobject]@{
            vmName = 'SECOND-JP'
            locale = 'ja-JP'
            localeSettings = [pscustomobject]@{ LanguageTag = 'ja-JP'; AddInputLanguages = @('0411:00000411') }
        },
        [pscustomobject]@{
            vmName = 'CUSTOM'
            locale = 'custom-locale'
            localeSettings = [pscustomobject]@{ LanguageTag = 'custom-locale'; AddInputLanguages = @('custom-input') }
        }
    )
}
Update-CatalogLocaleSettings -Config $staleProfileConfig -CatalogPath $catalogPath
Assert-Equal -Expected '0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}' -Actual @($staleProfileConfig.virtualMachines[0].localeSettings.AddInputLanguages)[0] -What 'config loading refreshes stale catalog-backed locale settings'
Assert-Equal -Expected '0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}' -Actual @($staleProfileConfig.vmOptions.localeSettings.AddInputLanguages)[0] -What 'config loading refreshes legacy root locale settings'
Assert-Equal -Expected 'custom-input' -Actual @($staleProfileConfig.virtualMachines[2].localeSettings.AddInputLanguages)[0] -What 'config loading preserves custom locale settings'
$staleProfileConfig.virtualMachines[0].localeSettings.AddInputLanguages[0] = 'mutated'
Assert-Equal -Expected '0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}' -Actual @($staleProfileConfig.virtualMachines[1].localeSettings.AddInputLanguages)[0] -What 'catalog profiles are deep-cloned per VM'
$missingCatalogConfig = [pscustomobject]@{ virtualMachines = @([pscustomobject]@{ locale = 'ja-JP'; localeSettings = [pscustomobject]@{ AddInputLanguages = @('unchanged') } }) }
Update-CatalogLocaleSettings -Config $missingCatalogConfig -CatalogPath (Join-Path ([IO.Path]::GetTempPath()) 'missing-locale-catalog.json')
Assert-Equal -Expected 'unchanged' -Actual @($missingCatalogConfig.virtualMachines[0].localeSettings.AddInputLanguages)[0] -What 'missing locale catalog leaves config unchanged'
$newLabSource = Get-Content -LiteralPath (Join-Path $RootPath 'New-Lab.ps1') -Raw
$loadIndex = $newLabSource.IndexOf('Get-UserConfiguration -Configuration $Configuration')
$refreshIndex = $newLabSource.IndexOf('Update-CatalogLocaleSettings -Config $userConfig')
$validateIndex = $newLabSource.IndexOf('Test-Configuration -InputObject $userConfig')
Assert-True -Condition ($loadIndex -ge 0 -and $refreshIndex -gt $loadIndex -and $validateIndex -gt $refreshIndex) -What 'New-Lab refreshes locale profiles after loading and before validation'

$scriptBlocks = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1') -Raw
$installCm = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1') -Raw
Assert-True -Condition ($scriptBlocks -match '\$currentItem\.localeSettings') -What 'language-pack copy consumes the per-VM profile'
Assert-True -Condition ($scriptBlocks -match '-and -not \$currentLocaleSettings') -What 'legacy profile file is copied only when no effective profile exists'
Assert-True -Condition ($installCm -match '\$ThisVM\.localeSettings') -What 'ConfigMgr setup consumes the per-VM profile'

$phase3 = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\phases\Phase3.ps1') -Raw
$phase4Path = Join-Path $RootPath 'DSC\phases\Phase4.ps1'
$phase4 = Get-Content -LiteralPath $phase4Path -Raw
$phase5 = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\phases\Phase5.ps1') -Raw
$templateHelpDscPath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$templateHelpDsc = Get-Content -LiteralPath $templateHelpDscPath -Raw
$phase8 = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\phases\Phase8.ps1') -Raw
$phase4Tokens = $null
$phase4ParseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($phase4Path, [ref]$phase4Tokens, [ref]$phase4ParseErrors)
$phase4StructuralErrors = @($phase4ParseErrors | Where-Object { $_.Message -notmatch '^Could not find the module ' })
Assert-Equal -Expected 0 -Actual $phase4StructuralErrors.Count -What 'Phase 4 has no structural parser errors beyond unavailable guest DSC modules'
$perfloading = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\phases\perfloading.ps1') -Raw
Assert-True -Condition ($phase3 -match '\$ThisVM\.localeSettings') -What 'Phase 3 consumes the per-VM profile'
Assert-True -Condition ($phase3 -match "\$localeAcquisition -eq 'WindowsUpdate'") -What 'Phase 3 selects the online acquisition resource per VM'
Assert-True -Condition ($phase3 -match 'Install-Language -Language \$language') -What 'online acquisition downloads the selected language'
Assert-True -Condition ($phase3 -match '\$global:DSCMachineStatus = 1') -What 'online acquisition records that a reboot is required'
Assert-True -Condition ($phase3 -match '(?s)\n        \}\r?\n\r?\n        LocalConfigurationManager \{\r?\n            RebootNodeIfNeeded\s*=\s*\$false') -What 'every Phase 3 node leaves reboot execution to the bounded host recovery monitor'
Assert-True -Condition ($scriptBlocks -match '\$staleRestartMax\s*=\s*2') -What 'host recovery bounds each unchanged-status reboot episode to two attempts'
Assert-True -Condition ($scriptBlocks -match '(?s)if \(\$dscStatusIsNew\) \{.*?\$staleRestartCount = 0 # a never-before-seen status starts a fresh bounded reboot episode') -What 'only genuine DSC status advancement starts a new bounded reboot episode'
Assert-True -Condition ($scriptBlocks -match 'rebootResumeMax=\$staleRestartMax') -What 'host recovery logs the effective reboot and resume budget'
Assert-True -Condition ($scriptBlocks -match 'reboot budget exhausted after \$staleRestartCount host-owned restart/resume attempt') -What 'host recovery fails instead of issuing an unbounded additional reboot'
Assert-True -Condition ($scriptBlocks -match 'Refusing another restart to prevent a reboot loop') -What 'reboot-loop failure explains why the host stopped recovery'
Assert-True -Condition ($scriptBlocks -match 'ScriptWorkflow state could not be verified\. Extending the confirmation window; not failing') -What 'an unknown workflow state cannot become a false reboot-loop failure'
Assert-True -Condition ($scriptBlocks -match '\[pscustomobject\]@\{ ProbeSucceeded = \$probeSucceeded; Running = \$running \}') -What 'workflow probes distinguish query failure from a task that is not running'
Assert-Equal -Expected 5 -Actual ([regex]::Matches($scriptBlocks, '\[pscustomobject\]@\{ ProbeSucceeded = \$probeSucceeded; Running = \$running \}').Count) -What 'all mutating and terminal workflow checks carry explicit probe provenance'
Assert-True -Condition ($scriptBlocks.Contains("Get-ScheduledTask -ErrorAction Stop | Where-Object { `$_.TaskName -eq 'ScriptWorkflow' }")) -What 'workflow probes treat an absent task as a successful query result'
Assert-True -Condition ($scriptBlocks -match 'ADServerDownException restart budget exhausted after \$staleRestartCount attempt') -What 'ADServerDownException recovery cannot restart indefinitely'
Assert-True -Condition ($scriptBlocks -match '(?s)\$adServerRestarted = \$true\s*break.*?if \(\$adServerRestarted\) \{ continue \}') -What 'ADServerDownException recovery refreshes DSC state after one restart per snapshot'
Assert-True -Condition ($scriptBlocks -match 'DSC status transport failed after \$forcedRestartCount VM restart attempt') -What 'DSC status transport failures cannot power-cycle indefinitely'
Assert-Equal -Expected 2 -Actual ([regex]::Matches($scriptBlocks, '\$lastDscProgressTime\s*=')).Count -What 'fatal-event window changes only at monitor start and genuine DSC progress'
Assert-True -Condition ($scriptBlocks -match 'Get-DscFatalGuestEvents -VMName \$currentItem\.vmName -StartTime \$lastDscProgressTime') -What 'fatal-event detection spans the whole unchanged DSC status episode'
Assert-True -Condition ($scriptBlocks -notmatch 'StartTime\s*=\s*\(Get-Date\)\.AddMinutes\(-20\)') -What 'fatal-event detection is not limited to a sliding 20-minute window'
Assert-True -Condition ($scriptBlocks -notmatch 'DSC requested reboot, Waiting 30 seconds to see if it reboots itself') -What 'dead duplicate reboot polling path remains removed'
Assert-True -Condition ($scriptBlocks -match '(?s)\$lcmPendingNoRebootSince.*?\$staleRestartCount -ge \$staleRestartMax.*?\$dscResumeCount -ge \$dscResumeMax.*?-or.*?\$lcmIdleSince.*?\$staleRestartCount -ge \$staleRestartMax') -What 'idle and stranded states reach terminal failure when their actual recovery actions are exhausted'
Assert-True -Condition ($phase3 -match '(?s)\$nextDepend\s*=\s*@\("\[InstallDotNet4\]DotNet"\).*?\$nextDepend\s*\+=\s*"\[Language\]ConfigureLanguage"') -What 'Phase 3 completion waits for DotNet and configured language convergence'
Assert-True -Condition ($scriptBlocks -match "\$currentLocaleAcquisition -ne 'WindowsUpdate'") -What 'online acquisition skips CAB copying'
Assert-True -Condition ($perfloading -match '\$ThisVM\.locale') -What 'SUP language selection consumes the per-VM locale'

$perVmConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ locale = 'en-US' }
    domainDefaults = [pscustomobject]@{ DefaultLocale = 'ja-JP' }
}
$firstVM = [pscustomobject]@{ vmName = 'CLIENT1'; operatingSystem = 'Windows 11 Latest' }
$secondVM = [pscustomobject]@{ vmName = 'CLIENT2'; operatingSystem = 'Windows 11 Latest' }
Set-DefaultLocaleForVM -ConfigToCheck $perVmConfig -VirtualMachine $firstVM -CatalogPath $catalogPath
Set-DefaultLocaleForVM -ConfigToCheck $perVmConfig -VirtualMachine $secondVM -CatalogPath $catalogPath
Assert-Equal -Expected 'ja-JP' -Actual $firstVM.locale -What 'first VM inherits the domain locale default'
Assert-Equal -Expected 'ja-JP' -Actual $secondVM.locale -What 'second VM inherits the domain locale default'

$osdVM = [pscustomobject]@{
    vmName = 'OSD1'
    role = 'OSDClient'
    locale = 'en-US'
    localeSettings = [pscustomobject]@{ LanguageTag = 'en-US' }
    localeAcquisition = 'Included'
}
Set-DefaultLocaleForVM -ConfigToCheck $perVmConfig -VirtualMachine $osdVM -CatalogPath $catalogPath
Assert-True -Condition (-not $osdVM.psobject.Properties['locale']) -What 'OS-less OSD client defers locale initialization'
Assert-True -Condition (-not $osdVM.psobject.Properties['localeSettings']) -What 'OS-less OSD client discards stale locale settings'
Assert-True -Condition (-not $osdVM.psobject.Properties['localeAcquisition']) -What 'OS-less OSD client has no locale acquisition route'

$localeMenuVM = [pscustomobject]@{
    vmName = 'CLIENT3'
    operatingSystem = 'Windows 11 Latest'
    locale = 'ja-JP'
    localeSettings = [pscustomobject]@{ LanguageTag = 'ja-JP' }
    localeAcquisition = 'WindowsUpdate'
}
$localeMenuProperties = @(Get-SortedProperties -Property $localeMenuVM)
Assert-True -Condition ($localeMenuProperties -contains 'locale') -What 'VM menu exposes the locale picker'
Assert-True -Condition ($localeMenuProperties -notcontains 'localeSettings') -What 'VM menu hides structured locale settings'
Assert-True -Condition ($localeMenuProperties -notcontains 'localeAcquisition') -What 'VM menu hides derived locale acquisition'

$missingOsRejected = $false
try {
    Set-DefaultLocaleForVM -ConfigToCheck $perVmConfig -VirtualMachine ([pscustomobject]@{ vmName = 'BROKEN'; role = 'DomainMember' }) -CatalogPath $catalogPath
}
catch {
    $missingOsRejected = $_.Exception.Message -like "*parameter 'OperatingSystem'*empty string*"
}
Assert-True -Condition $missingOsRejected -What 'OS-less non-OSD VM still fails locale initialization'

$script:MenuLocale = 'en-US'
$null = Select-Locale -ConfigToCheck $perVmConfig -Target $firstVM -CatalogPath $catalogPath
Assert-Equal -Expected 'en-US' -Actual $firstVM.locale -What 'one VM can override the domain locale default'
Assert-Equal -Expected 'ja-JP' -Actual $secondVM.locale -What 'per-VM override does not change its sibling'

$invalidLocaleVM = [pscustomobject]@{ vmName = 'INVALID'; operatingSystem = 'Windows 11 Latest'; locale = 'ja_JP' }
Set-DefaultLocaleForVM -ConfigToCheck $perVmConfig -VirtualMachine $invalidLocaleVM -CatalogPath $catalogPath
Assert-Equal -Expected 'en-US' -Actual $invalidLocaleVM.locale -What 'unknown per-VM locale falls back to en-US'
Assert-Equal -Expected 'en-US' -Actual $invalidLocaleVM.localeSettings.LanguageTag -What 'unknown locale cannot retain a missing profile'
Assert-True -Condition (($invalidLocaleVM | ConvertTo-Json -Depth 6) -notmatch 'ja_JP') -What 'unknown locale does not survive config serialization'

$japaneseProfile = (Get-LocaleProfiles -Path $catalogPath)['ja-JP']
Assert-Equal -Expected 'WindowsUpdate' -Actual (Get-LocaleAcquisitionMethod -Profile $japaneseProfile -OperatingSystem 'Windows 11 Latest' -ConfigPath $global:Common.ConfigPath) -What 'Windows 11 can acquire Japanese from Windows Update'
Assert-Equal -Expected '' -Actual (Get-LocaleAcquisitionMethod -Profile $japaneseProfile -OperatingSystem 'Server 2019' -ConfigPath $global:Common.ConfigPath) -What 'Server without matching media or source cannot acquire Japanese'
$emptyServer2022Root = Join-Path ([IO.Path]::GetTempPath()) ("memlabs-empty-s22-locale-" + [guid]::NewGuid().ToString('N'))
Assert-Equal -Expected 'MicrosoftMedia' -Actual (Get-LocaleAcquisitionMethod -Profile $japaneseProfile -OperatingSystem 'Server 2022' -ConfigPath $emptyServer2022Root) -What 'Server 2022 can acquire Japanese from Microsoft media'
$emptyMediaRoot = Join-Path ([IO.Path]::GetTempPath()) ("memlabs-empty-locale-" + [guid]::NewGuid().ToString('N'))
Assert-Equal -Expected 'MicrosoftMedia' -Actual (Get-LocaleAcquisitionMethod -Profile $japaneseProfile -OperatingSystem 'Server 2025' -ConfigPath $emptyMediaRoot) -What 'Server 2025 can acquire Japanese from Microsoft media'
$server2022Source = @($japaneseProfile.MediaSources | Where-Object OperatingSystemPattern -eq 'Server 2022*')[0]
$server2025Source = @($japaneseProfile.MediaSources | Where-Object OperatingSystemPattern -eq 'Server 2025*')[0]
Assert-Equal -Expected '850A318C277F9B0D7436031EFD91B36F5D27DAD6E8EA9972179204A3FC756517' -Actual $server2022Source.SHA256 -What 'Server 2022 Microsoft media is hash-pinned'
Assert-Equal -Expected '72C33705D0C35610CBA354DE8C3CBF1274B55A096227135B5BD8BABB8B222BE3' -Actual $server2025Source.SHA256 -What 'Server 2025 Microsoft media is hash-pinned'
Assert-Equal -Expected '' -Actual (Get-LocaleAcquisitionMethod -Profile $japaneseProfile -OperatingSystem 'Windows 11 Latest' -ConfigPath $global:Common.ConfigPath -OfflineMode $true) -What 'offline Windows 11 cannot use Windows Update acquisition'
$serverVM = [pscustomobject]@{ vmName = 'SERVER1'; operatingSystem = 'Server 2022' }
$originalConfigPath = $global:Common.ConfigPath
try {
    $global:Common.ConfigPath = $emptyServer2022Root
    Set-DefaultLocaleForVM -ConfigToCheck $perVmConfig -VirtualMachine $serverVM -CatalogPath $catalogPath -RequireAvailable
    Assert-Equal -Expected 'ja-JP' -Actual $serverVM.locale -What 'Server 2022 inherits the available domain locale default'
    Assert-Equal -Expected 'MicrosoftMedia' -Actual $serverVM.localeAcquisition -What 'Server 2022 records the Microsoft media route before caching'
    $script:MenuLocale = 'en-US'
    $null = Select-Locale -ConfigToCheck $perVmConfig -Target $serverVM -CatalogPath $catalogPath
    Assert-True -Condition ($script:MenuOptions -contains 'ja-JP') -What 'Server 2022 menu includes Japanese before media is cached'
}
finally {
    $global:Common.ConfigPath = $originalConfigPath
    Remove-Item -LiteralPath $emptyServer2022Root -Recurse -Force -ErrorAction SilentlyContinue
}

$mediaRoot = Join-Path ([IO.Path]::GetTempPath()) ("memlabs-locale-" + [guid]::NewGuid().ToString('N'))
try {
    $serverMedia = Join-Path (Join-Path $mediaRoot 'locales') 'Server 2022'
    $null = New-Item -Path $serverMedia -ItemType Directory -Force
    $null = New-Item -Path (Join-Path $serverMedia 'Microsoft-Windows-Server-Language-Pack_x64_ja-jp.cab') -ItemType File -Force
    foreach ($capability in @($japaneseProfile.LanguageCapabilities)) {
        $packageName = "Microsoft-Windows-LanguageFeatures-$capability-ja-jp-Package~31bf3856ad364e35~amd64~~.cab"
        $null = New-Item -Path (Join-Path $serverMedia $packageName) -ItemType File -Force
    }
    Assert-Equal -Expected 'Media' -Actual (Get-LocaleAcquisitionMethod -Profile $japaneseProfile -OperatingSystem 'Server 2022' -ConfigPath $mediaRoot) -What 'complete cached Server package set enables media acquisition'
}
finally {
    Remove-Item -LiteralPath $mediaRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$packageRoot = Join-Path ([IO.Path]::GetTempPath()) ("memlabs-locale-packages-" + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -Path $packageRoot -ItemType Directory -Force
    $packageNames = @('Microsoft-Windows-Server-Language-Pack_x64_ja-jp.cab')
    foreach ($capability in @($japaneseProfile.LanguageCapabilities)) {
        $packageNames += "Microsoft-Windows-LanguageFeatures-$capability-ja-jp-Package~31bf3856ad364e35~amd64~~.cab"
    }
    foreach ($packageName in $packageNames) {
        $null = New-Item -Path (Join-Path $packageRoot $packageName) -ItemType File -Force
    }
    $selectedPackages = @(Get-LocaleMediaFiles -Path $packageRoot -LocaleDefinition $japaneseProfile)
    Assert-Equal -Expected 6 -Actual $selectedPackages.Count -What 'Server 2025 extraction selects the full Japanese package set'
    Assert-True -Condition (Test-LocaleMediaFiles -Files $selectedPackages -LocaleDefinition $japaneseProfile) -What 'complete Japanese package set passes structural validation'
}
finally {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$isoProbePath = Join-Path ([IO.Path]::GetTempPath()) ("memlabs-locale-iso-" + [guid]::NewGuid().ToString('N') + '.iso')
try {
    [IO.File]::WriteAllBytes($isoProbePath, [byte[]](1, 2, 3, 4))
    $isoFileTime = (Get-Item -LiteralPath $isoProbePath).LastWriteTimeUtc
    $isoProbeHash = (Get-FileHash -LiteralPath $isoProbePath -Algorithm SHA256).Hash
    $isoProbeSource = [pscustomobject]@{ Size = 4; SHA256 = $isoProbeHash }
    Assert-True -Condition (Test-LocaleMediaIso -Path $isoProbePath -Source $isoProbeSource) -What 'offline locale media accepts a cached ISO with exact size and hash'
    $isoProbeSource.Size = 5
    Assert-True -Condition (-not (Test-LocaleMediaIso -Path $isoProbePath -Source $isoProbeSource)) -What 'offline locale media rejects a cached ISO with the wrong size'
    $isoProbeSource.Size = 4
    $isoProbeSource.SHA256 = '00'
    Assert-True -Condition (-not (Test-LocaleMediaIso -Path $isoProbePath -Source $isoProbeSource)) -What 'offline locale media rejects a cached ISO with the wrong hash'
    Assert-True -Condition (-not (Test-LocaleMediaIso -Path "$isoProbePath.missing" -Source $isoProbeSource)) -What 'offline locale media rejects a missing cached ISO'

    Clear-LocaleMediaIsoValidationCache
    $isoProbeSource.SHA256 = $isoProbeHash
    Assert-True -Condition (Test-LocaleMediaIso -Path $isoProbePath -Source $isoProbeSource) -What 'first locale validates its shared cached ISO'
    Assert-True -Condition (Test-LocaleMediaIso -Path $isoProbePath -Source $isoProbeSource) -What 'second locale reuses validation for the unchanged shared ISO'

    $originalAzureFilesPath = $global:Common.AzureFilesPath
    $originalCommonConfigPath = $global:Common.ConfigPath
    $global:Common.AzureFilesPath = Split-Path -Parent $isoProbePath
    $global:Common.ConfigPath = Join-Path (Split-Path -Parent $isoProbePath) ('empty-config-' + [guid]::NewGuid().ToString('N'))
    $offlineProfile = $japaneseProfile | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $offlineProfile.MediaSources = @([pscustomobject]@{
            OperatingSystemPattern = 'Server 2022*'
            IsoRelativePath        = Split-Path -Leaf $isoProbePath
            Size                   = 4
            SHA256                 = $isoProbeHash
        })
    $offlineCatalogPath = "$isoProbePath.catalog.json"
    [pscustomobject]@{ 'en-US' = $catalog.'en-US'; 'ja-JP' = $offlineProfile } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $offlineCatalogPath -Encoding UTF8
    $offlineConfig = [pscustomobject]@{
        domainDefaults = [pscustomobject]@{ DefaultLocale = 'ja-JP' }
        vmOptions      = [pscustomobject]@{}
    }
    $offlineVm = [pscustomobject]@{ vmName = 'OFFLINE-S22'; operatingSystem = 'Server 2022' }
    $hadOfflineMode = $global:Common.PSObject.Properties.Name -contains 'OfflineMode'
    $originalOfflineMode = $global:Common.OfflineMode
    $global:Common | Add-Member -MemberType NoteProperty -Name OfflineMode -Value $true -Force
    Set-DefaultLocaleForVM -ConfigToCheck $offlineConfig -VirtualMachine $offlineVm -CatalogPath $offlineCatalogPath -RequireAvailable
    Assert-Equal -Expected 'ja-JP' -Actual $offlineVm.locale -What 'offline authoring preserves a locale backed by a hash-valid cached ISO'
    Assert-Equal -Expected 'MicrosoftMedia' -Actual $offlineVm.localeAcquisition -What 'offline authoring routes a valid cached ISO through Microsoft media extraction'
    Clear-LocaleMediaIsoValidationCache
    $offlineProfile.MediaSources[0].SHA256 = '00'
    [pscustomobject]@{ 'en-US' = $catalog.'en-US'; 'ja-JP' = $offlineProfile } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $offlineCatalogPath -Encoding UTF8
    $invalidOfflineVm = [pscustomobject]@{ vmName = 'INVALID-S22'; operatingSystem = 'Server 2022' }
    Set-DefaultLocaleForVM -ConfigToCheck $offlineConfig -VirtualMachine $invalidOfflineVm -CatalogPath $offlineCatalogPath -RequireAvailable
    Assert-Equal -Expected 'en-US' -Actual $invalidOfflineVm.locale -What 'offline authoring rejects a cached ISO whose hash is invalid'
    $global:Common.OfflineMode = $originalOfflineMode
    $global:Common.AzureFilesPath = $originalAzureFilesPath
    $global:Common.ConfigPath = $originalCommonConfigPath
    $isoProbeSource.SHA256 = $isoProbeHash
    Assert-True -Condition (Test-LocaleMediaIso -Path $isoProbePath -Source $isoProbeSource) -What 'direct validation reacquires the ISO lock after authoring cleanup'
    $writeBlocked = $false
    try { [IO.File]::WriteAllBytes($isoProbePath, [byte[]](4, 3, 2, 1)) } catch { $writeBlocked = $true }
    Assert-True -Condition $writeBlocked -What 'validated ISO bytes cannot change while validation is reused'
    Clear-LocaleMediaIsoValidationCache
    [IO.File]::WriteAllBytes($isoProbePath, [byte[]](4, 3, 2, 1))
    (Get-Item -LiteralPath $isoProbePath).LastWriteTimeUtc = $isoFileTime
    Assert-True -Condition (-not (Test-LocaleMediaIso -Path $isoProbePath -Source $isoProbeSource)) -What 'same-size same-timestamp changed ISO bytes fail fresh validation'
    Assert-Equal -Expected (Get-LocaleMediaMutexName -Path $isoProbePath) -Actual (Get-LocaleMediaMutexName -Path $isoProbePath) -What 'locale media mutex identity is stable for one ISO path'
}
finally {
    Clear-LocaleMediaIsoValidationCache
    if ($originalAzureFilesPath) { $global:Common.AzureFilesPath = $originalAzureFilesPath }
    if ($originalCommonConfigPath) { $global:Common.ConfigPath = $originalCommonConfigPath }
    if ($hadOfflineMode) {
        $global:Common.OfflineMode = $originalOfflineMode
    }
    elseif ($global:Common.PSObject.Properties.Name -contains 'OfflineMode') {
        $global:Common.PSObject.Properties.Remove('OfflineMode')
    }
    Remove-Item -LiteralPath "$isoProbePath.catalog.json" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $isoProbePath -Force -ErrorAction SilentlyContinue
}

$localeModuleText = Get-Content -LiteralPath $localeModulePath -Raw
$cachedIsoCheckIndex = $localeModuleText.IndexOf('$cachedIsoValid = Test-LocaleMediaIso')
$offlineRejectIndex = $localeModuleText.IndexOf('if ($Common.OfflineMode -and -not $cachedIsoValid)')
Assert-True -Condition ($cachedIsoCheckIndex -ge 0 -and $offlineRejectIndex -gt $cachedIsoCheckIndex) -What 'offline rejection occurs only after cached ISO validation'
Assert-True -Condition ($localeModuleText -match 'Get-FileWithHash.+-ForceDownload:\$replaceInvalidCache') -What 'online acquisition replaces an existing ISO that failed direct validation'
Assert-True -Condition ($localeModuleText -match '\[Threading\.Mutex\]::new') -What 'shared locale ISO validation and extraction are serialized across direct callers'
Assert-True -Condition ($localeModuleText -match '\$WhatIf -and -not \$Common\.OfflineMode') -What 'online dry run reports downloadable locale media as viable'
Assert-True -Condition ($localeModuleText -match 'if \(-not \$RetainIsoValidation\) \{ Clear-LocaleMediaIsoValidationCache \}') -What 'direct locale initialization releases cached ISO validation handles'
Assert-True -Condition ($localeModuleText -match 'Initialize-LocaleMedia.+-RetainIsoValidation') -What 'Phase 2 batch retains ISO validation only across serial pre-staging'
Assert-True -Condition ($localeModuleText -match 'Get-LocaleMediaMutexName -Path \$isoPath') -What 'locale media mutex follows the contested ISO path'
Assert-True -Condition ($localeModuleText -match '(?s)Dismount-DiskImage.+?finally \{\s*Remove-Item -LiteralPath \$stagePath') -What 'staging cleanup still runs when media dismount fails'

$legacyConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ locale = 'ja-JP'; localeSettings = $japaneseProfile }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'OLDCLIENT'; operatingSystem = 'Windows 11 Latest' }
        [pscustomobject]@{ vmName = 'LINUX1'; operatingSystem = 'Ubuntu Server 24.04 LTS'; osFamily = 'Linux' }
    )
}
Initialize-PerVmLocales -ConfigToCheck $legacyConfig -CatalogPath $catalogPath
Assert-Equal -Expected 'ja-JP' -Actual $legacyConfig.domainDefaults.DefaultLocale -What 'legacy global locale migrates to the domain default'
Assert-Equal -Expected 'ja-JP' -Actual $legacyConfig.virtualMachines[0].locale -What 'legacy global locale migrates to each Windows VM'
Assert-True -Condition (-not $legacyConfig.virtualMachines[1].psobject.Properties['locale']) -What 'locale migration ignores Linux VMs'
Assert-True -Condition (-not $legacyConfig.vmOptions.psobject.Properties['locale']) -What 'migration removes the global locale property'
Assert-True -Condition (-not $legacyConfig.vmOptions.psobject.Properties['localeSettings']) -What 'migration removes the global profile property'

$addVm = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1') -Raw
$vmList = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.GenConfig.VMList.ps1') -Raw
$summary = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.GenConfig.Summary.ps1') -Raw
$common = Get-Content -LiteralPath (Join-Path $RootPath 'Common.ps1') -Raw
$phases = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Phases.ps1') -Raw
Assert-True -Condition ($addVm -match 'Set-DefaultLocaleForVM.+-RequireAvailable') -What 'new VM creation applies only an available domain locale default'
Assert-True -Condition ($addVm -match "'operatingSystem', 'locale', 'localeSettings', 'localeAcquisition'") -What 'new OSD clients discard provisional OS locale metadata'
Assert-True -Condition ($vmList -match '"DefaultLocale"\s*\{') -What 'domain default has a locale menu handler'
Assert-True -Condition ($vmList -match 'Select-Locale -ConfigToCheck \$global:config -Target \$property') -What 'VM locale edits target only the selected VM'
Assert-True -Condition ($summary -match 'Initialize-PerVmLocales -ConfigToCheck \$Global:Config') -What 'authoring migrates legacy global locales before rendering'
Assert-True -Condition ($common -match 'Common\.Locale\.ps1') -What 'shared locale media helpers load in phase workers'
Assert-True -Condition ($common -match 'Initialize-LocaleMedia -Locale \$vmLocale -OperatingSystem \$vmOperatingSystem') -What 'language-pack copy prepares missing Microsoft media automatically'
Assert-True -Condition ($common -match 'Get-LocaleDefinitionForOperatingSystem -LocaleDefinition \$catalog\.\$vmLocale -OperatingSystem \$vmOperatingSystem') -What 'language-pack copy resolves OS-specific capability overrides'
Assert-True -Condition ($common -match 'Test-LocaleMediaFiles -Files \$sourceFiles -LocaleDefinition \$localeDefinition') -What 'language-pack copy rejects incomplete OS-specific package sets'
Assert-True -Condition ($phases -match 'Initialize-LocaleMediaForPhase2 -DeployConfig \$deployConfig') -What 'Phase 2 prepares unique locale media before worker fan-out'
Assert-True -Condition ($phases -match '(?s)\$localeMediaIssues\s*=\s*@\(\).*?if \(\$ConfigurationData\).*?if \(\$phase3LocaleNodes\.Count -gt 0\).*?Get-Phase3LocaleMediaIssues') -What 'Linux-only Phase 3 bypasses locale media probing when ConfigurationData has no Windows nodes'
Assert-True -Condition ($scriptBlocks -match '\$locale = if \(\$currentItem\.locale\)') -What 'DSC multi-config compilation consumes the per-VM locale'
Assert-True -Condition ($scriptBlocks -match '\$localeSettings = if \(\$currentItem\.localeSettings\)') -What 'DSC multi-config compilation consumes the per-VM locale profile'
Assert-True -Condition ($scriptBlocks -match 'LanguageCapabilities\s*=\s*\$localeSettings\.LanguageCapabilities') -What 'legacy DSC configuration data preserves language capabilities'
Assert-True -Condition ($phase3 -match 'WriteStatus ApplyingLocale\s*\{\s*Status\s*=\s*"Applying \$languageTag locale: language pack"') -What 'Phase 3 reports language-pack progress before applying the resource'
Assert-True -Condition ($phase3 -match '(?s)Script InstallLanguagePackOnline\s*\{\s*DependsOn\s*=\s*\$localeStatusDependency') -What 'online language installation waits for the locale status message'
Assert-True -Condition ($phase3 -match '(?s)LanguagePack InstallLanguagePack\s*\{.*?DependsOn\s*=\s*\$localeStatusDependency') -What 'media-backed language installation waits for the locale status message'
Assert-True -Condition ($phase3 -match '(?s)WriteStatus ApplyingLanguageFeatures\s*\{.*?Status\s*=\s*"Applying \$languageTag locale: language capabilities".*?Script InstallLanguageFeaturesOffline\s*\{\s*DependsOn\s*=\s*''\[WriteStatus\]ApplyingLanguageFeatures''') -What 'Phase 3 reports capability progress before applying offline language features'
Assert-True -Condition ($phase3 -match '(?s)WriteStatus ConfiguringLocale\s*\{.*?Status\s*=\s*"Applying \$languageTag locale: regional settings".*?Language ConfigureLanguage\s*\{.*?DependsOn\s*=\s*''\[WriteStatus\]ConfiguringLocale''') -What 'Phase 3 reports regional-settings progress before applying the locale'
Assert-True -Condition ($phase3 -match 'InstallLanguageFeaturesOffline') -What 'Phase 3 installs Server language capabilities from cached media'
Assert-True -Condition ($phase3 -match '\$l\.LanguageCapabilities') -What 'Phase 3 consumes language capabilities from configuration data'
Assert-True -Condition ($phase3.Contains("Add-WindowsCapability -Online -Name `$name -Source 'C:\LanguagePacks' -LimitAccess")) -What 'Server language features cannot fall through to Windows Update'
Assert-True -Condition ($phase3 -match '(?s)Registry RAMDiskTFTPWIndowSize\s*\{.*?Key\s*=\s*["'']HKLM:\\SOFTWARE\\Microsoft\\SMS\\DP["''].*?\}') -What 'Phase 3 TFTP window registry resource uses a provider-qualified HKLM path'
Assert-True -Condition ($phase3 -match '(?s)Registry RAMDiskTFTPBlockSize\s*\{.*?Key\s*=\s*["'']HKLM:\\SOFTWARE\\Microsoft\\SMS\\DP["''].*?\}') -What 'Phase 3 TFTP block registry resource uses a provider-qualified HKLM path'
Assert-True -Condition ($phase3 -notmatch 'Key\s*=\s*["'']HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\SMS\\DP["'']') -What 'Phase 3 DP registry resources reject an unqualified registry hive path'
Assert-True -Condition ($phase4 -match '(?s)\$managedSQLSysAdminAccounts\s*=.*?NT AUTHORITY\\SYSTEM.*?foreach \(\$account in \$managedSQLSysAdminAccounts') -What 'Phase 4 does not recreate the locale-dependent LocalSystem SQL login name'
Assert-True -Condition ($phase4 -match 'MembersToInclude\s*=\s*\$managedSQLSysAdminAccounts') -What 'Phase 4 leaves the existing LocalSystem SID role membership unchanged'
$localSystemSidDefinitionIndex = $phase4.IndexOf("`$localSystemSidHex = '010100000000000512000000'")
$localSystemSidUseIndex = $phase4.IndexOf('DECLARE @sid varbinary(85) = 0x$localSystemSidHex')
$localSystemNameIndex = $phase4.IndexOf('SUSER_SNAME(@sid)')
$localSystemLoginIndex = $phase4.IndexOf('CREATE LOGIN')
$localSystemRoleIndex = $phase4.IndexOf('ALTER SERVER ROLE [sysadmin] ADD MEMBER')
Assert-True -Condition ($localSystemSidDefinitionIndex -ge 0 -and $localSystemSidUseIndex -gt $localSystemSidDefinitionIndex -and $localSystemNameIndex -gt $localSystemSidUseIndex -and $localSystemLoginIndex -gt $localSystemNameIndex -and $localSystemRoleIndex -gt $localSystemLoginIndex) -What 'Phase 4 repairs the LocalSystem SQL login and sysadmin role through stable SID resolution'
Assert-True -Condition ($phase4 -match '(?s)Script EnsureLocalSystemSqlSysadmin\s*\{.*?PsDscRunAsCredential\s*=\s*\$Admincreds') -What 'Phase 4 LocalSystem SQL repair uses a separately privileged credential'
Assert-Equal -Expected 2 -Actual ([regex]::Matches($phase4, 'EXEC sys\.sp_executesql @sql').Count) -What 'Phase 4 LocalSystem SQL repair executes valid dynamic statements through sp_executesql'
$spnSetStart = $phase4.IndexOf('Script SetSQLSPNs')
$spnSetEnd = $phase4.IndexOf('Script GrantSPNWritePermission', $spnSetStart)
$spnSetBlock = if ($spnSetStart -ge 0 -and $spnSetEnd -gt $spnSetStart) { $phase4.Substring($spnSetStart, $spnSetEnd - $spnSetStart) } else { '' }
$spnHolderIndex = $spnSetBlock.IndexOf('`$holders = @(Get-ADObject -Filter { servicePrincipalName -eq `$s }')
$spnRemoveIndex = $spnSetBlock.IndexOf('Set-ADObject -Identity `$holder')
$spnAddIndex = $spnSetBlock.IndexOf('Set-ADUser -Identity `$target')
Assert-True -Condition ($spnHolderIndex -ge 0 -and $spnRemoveIndex -gt $spnHolderIndex -and $spnAddIndex -gt $spnRemoveIndex) -What 'Phase 4 transfers SPNs from typed AD owners before adding them to the service account'
Assert-True -Condition ($spnSetBlock -match '(?s)foreach \(`\$attempt in 1\.\.3\).*?`\$holders\.Count -ne 1.*?after 3 attempts') -What 'Phase 4 bounds SPN reconciliation and requires target-exclusive final ownership'
Assert-True -Condition ($spnSetBlock -match '(?s)TestScript.*?Get-ADObject -Filter \{ servicePrincipalName -eq `\$s \}.*?`\$holders\.Count -ne 1.*?DistinguishedName -ne `\$user\.DistinguishedName') -What 'Phase 4 SPN compliance rejects target-plus-foreign duplicate ownership'
Assert-True -Condition ($spnSetBlock -match '(?s)try \{.*?Set-ADUser -Identity `\$target.*?`\$target = Get-ADUser.*?Get-ADObject.*?catch \{ `\$lastError') -What 'Phase 4 retries transient SPN mutation and verification failures together'
Assert-True -Condition ($phase4 -notmatch '\$_.Exception.Message -match [''"].*?(?:constraint|already exists|duplicate|not unique)') -What 'Phase 4 SPN ownership repair does not parse localized exception text'
$clusterShareStart = $phase5.IndexOf('SmbShare "ClusterShare$i"')
$backupShareStart = $phase5.IndexOf('SmbShare "BackupShare$i"')
$clusterShareBlock = if ($clusterShareStart -ge 0 -and $backupShareStart -gt $clusterShareStart) { $phase5.Substring($clusterShareStart, $backupShareStart - $clusterShareStart) } else { '' }
$backupShareEnd = $phase5.IndexOf('$WaitDepend += "[SmbShare]BackupShare$i"', $backupShareStart)
$backupShareBlock = if ($backupShareStart -ge 0 -and $backupShareEnd -gt $backupShareStart) { $phase5.Substring($backupShareStart, $backupShareEnd - $backupShareStart) } else { '' }
Assert-True -Condition ($clusterShareBlock -match 'FullAccess\s*=\s*\$primaryVM\.thisParams\.SQLAO\.GroupMembersFQ' -and $clusterShareBlock -match 'ChangeAccess\s*=\s*@\(\)' -and $clusterShareBlock -match 'ReadAccess\s*=\s*@\(\)' -and $clusterShareBlock -match 'DependsOn\s*=\s*"\[NTFSAccessEntry\]ClusterWitnessPermissions\$i"') -What 'Phase 5 witness share grants only the intended full-access principals'
Assert-True -Condition ($backupShareBlock -match 'FullAccess\s*=\s*\$primaryVM\.thisParams\.SQLAO\.SqlServiceAccountFQ.*?SqlAgentServiceAccountFQ.*?DomainAdminName.*?vmbuildadmin' -and $backupShareBlock -match 'ChangeAccess\s*=\s*@\(\)' -and $backupShareBlock -match 'ReadAccess\s*=\s*@\(\)' -and $backupShareBlock -match 'DependsOn\s*=\s*"\[NTFSAccessEntry\]ClusterBackupPermissions\$i"') -What 'Phase 5 backup share grants only the intended full-access principals'
Assert-True -Condition ($clusterShareBlock -notmatch 'Everyone|Todos|S-1-1-0' -and $backupShareBlock -notmatch 'Everyone|Todos|S-1-1-0') -What 'Phase 5 SMB shares do not use locale-dependent world-access account names'
Assert-True -Condition ($phase5 -match '(?s)Script ''ClusterWitness''\s*\{.*?Get-ClusterQuorum.*?Get-ClusterParameter -Name SharePath.*?Set-ClusterQuorum -FileShareWitness') -What 'Phase 5 quorum configuration uses the locale-neutral SharePath parameter'
Assert-True -Condition ($phase5 -notmatch "ClusterQuorum 'ClusterWitness'") -What 'Phase 5 does not use locale-sensitive FailoverClusterDsc quorum detection'
Assert-True -Condition ($phase5 -match "ResourceName\s*=\s*'\[Script\]ClusterWitness'") -What 'Phase 5 primary node waits for the locale-neutral quorum resource'
$clusSvcPermissionStarts = @([regex]::Matches($phase5, "SqlPermission 'AddNTServiceClusSvcPermissions'\s*\{") | ForEach-Object { $_.Index })
$clusSvcPermissionBlocks = @(foreach ($startIndex in $clusSvcPermissionStarts) {
    $endIndex = $phase5.IndexOf('# Create a DatabaseMirroring endpoint', $startIndex)
        if ($endIndex -gt $startIndex) { $phase5.Substring($startIndex, $endIndex - $startIndex) }
    })
Assert-Equal -Expected 2 -Actual $clusSvcPermissionBlocks.Count -What 'Phase 5 defines one ClusSvc permission resource per SQLAO replica path'
Assert-True -Condition (@($clusSvcPermissionBlocks | Where-Object { $_ -notmatch "Permission\s*=\s*@\('ConnectSql', 'AlterAnyAvailabilityGroup', 'ViewServerState'\)" }).Count -eq 0) -What 'Phase 5 grants ClusSvc all permissions required by SqlServerDsc on both replicas'
Assert-True -Condition ($phase5 -notmatch 'if \(\$Node\.DBName\)') -What 'Phase 5 SQLAO secondary always waits for the phase-owned TESTDB seed'
Assert-True -Condition ($phase5 -match '(?s)WaitForAll RecoveryModel.*?WaitForAll AddAGDatabaseMemberships.*?\$nextDepend = ''\[WaitForAll\]AddAGDatabaseMemberships''') -What 'Phase 5 SQLAO secondary completion depends on TESTDB recovery and AG membership'
Assert-True -Condition ($phase5 -match '(?s)Script EnsurePhase5DatabaseOnSecondary.*?sys\.dm_hadr_database_replica_states.*?BACKUP DATABASE.*?BACKUP LOG.*?RESTORE DATABASE.*?RESTORE LOG.*?SET HADR AVAILABILITY GROUP.*?DependsOn\s*=\s*''\[WaitForAll\]AddAGDatabaseMemberships''') -What 'Phase 5 repairs a missing local TESTDB replica with fresh full and log backups'
Assert-True -Condition ($phase5 -match '(?s)\$_phase5Primary = if \(\$_phase5Instance -eq ''MSSQLSERVER''\).*?\$_phase5Local = if \(\$_phase5Instance -eq ''MSSQLSERVER''\)') -What 'Phase 5 secondary seeding targets default and named SQL instances explicitly'
Assert-True -Condition ([regex]::Matches($phase5, 'Data Source=\$localServer;Initial Catalog=master').Count -eq 2 -and $phase5 -notmatch "Data Source=localhost;Initial Catalog=master") -What 'Phase 5 restore and membership polling use the same default or named local SQL instance'
Assert-True -Condition ($phase5.Contains("DATABASEPROPERTYEX(N'`$databaseLiteral', 'Status') <> 'RESTORING'")) -What 'Phase 5 secondary seeding preserves an existing restoring database before replacement'
Assert-True -Condition ($phase5 -match '(?s)Script ''ClusterWitness''.*?TestScript.*?QuorumResource\.State -eq ''Online''.*?sharePath -eq') -What 'Phase 5 quorum resource requires online state and the expected SharePath'
$functionalValidationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$sqlAoValidation = (Import-TestFunction -Path $functionalValidationPath -Name 'Test-SQLAOFunctionality').ToString()
$postPhase5Validation = (Import-TestFunction -Path $functionalValidationPath -Name 'Test-SQLAOPostPhase5').ToString()
$coreClusterResourceFunction = Import-TestFunction -Path $templateHelpDscPath -Name 'Get-CoreClusterNetworkNameResource'
$clusterNicResource = [regex]::Match($templateHelpDsc, '(?ms)^\[DscResource\(\)\]\s*class DisableClusterNicDnsRegistration\s*\{.*?(?=^\[DscResource\(\)\]|\z)').Value
$clusterIpCleanupResource = [regex]::Match($templateHelpDsc, '(?ms)^\[DscResource\(\)\]\s*class ClusterRemoveUnwantedIPs\s*\{.*?(?=^\[DscResource\(\)\]|\z)').Value
$clusterAccessResource = [regex]::Match($templateHelpDsc, '(?ms)^\[DscResource\(\)\]\s*class WaitForClusterAccess\s*\{.*?(?=^\[DscResource\(\)\]|\z)').Value
Assert-True -Condition ($sqlAoValidation -match '(?s)# 7\. Backup and Witness share accessibility.*?if \(\$witnessShare\).*?Get-ClusterQuorum.*?Get-ClusterParameter -Name SharePath.*?quorumResource\.State.*?Online.*?if \(\$backupShare\).*?Test-Path \$backupShare') -What 'Phase 11 validates the restricted witness through typed online quorum state and probes the backup share directly'
Assert-True -Condition ($sqlAoValidation -match '(?s)\[string\]::Equals\(\[string\]\$configuredWitness, \[string\]\$witnessShare, \[System\.StringComparison\]::OrdinalIgnoreCase\).*?else\s*\{\s*\$results\.Passed = \$false.*?catch\s*\{\s*\$results\.Passed = \$false') -What 'Phase 11 compares the expected witness path without case sensitivity and fails mismatches or query errors'
Assert-True -Condition ($sqlAoValidation -notmatch 'Test-Path[^\r\n]*(?:\$witnessShare|\$share\.Path)') -What 'Phase 11 does not probe the restricted witness through its admin session'
Assert-True -Condition ($postPhase5Validation -match '(?s)Get-ClusterQuorum.*?Get-ClusterParameter -Name SharePath.*?QuorumResource\.State.*?Online') -What 'post-Phase-5 validation uses typed online quorum witness state'
Assert-True -Condition ($postPhase5Validation -notmatch 'Test-Path\s+\$witnessShare') -What 'post-Phase-5 validation does not probe the restricted witness as an admin'
Assert-True -Condition ($sqlAoValidation -match '(?s)RegisterAllProvidersIP.*?Get-ClusterResource.*?ResourceType -eq ''Network Name''.*?Get-ClusterParameter -Name DnsName.*?OrdinalIgnoreCase.*?Get-ClusterParameter -Name RegisterAllProvidersIP') -What 'Phase 11 discovers the core cluster resource through its invariant DNS name'
Assert-True -Condition ($sqlAoValidation -notmatch 'Get-ClusterResource[^\r\n]*-Name\s+[''"]Cluster Name[''"]') -What 'Phase 11 does not address the core cluster resource by its localized display name'
Assert-True -Condition ($sqlAoValidation -match '(?s)coreClusterGroupName = \[string\]\$clusNameRes\.OwnerGroup\.Name.*?OwnerGroup\.Name -eq \$coreClusterGroupName') -What 'Phase 11 audits cluster IP resources through the core resource actual localized group name'
$coreClusterProbe = & {
    param([scriptblock] $Definition)
    $listener = [pscustomobject]@{ Name = 'Localized Listener'; ResourceType = 'Network Name'; DnsName = 'APP-LISTENER' }
    $core = [pscustomobject]@{ Name = 'Localized Core Name'; ResourceType = 'Network Name'; DnsName = 'LAB-CLUSTER' }
    function Get-ClusterResource {
        [CmdletBinding()]
        param([string] $Cluster)
        return @($listener, $core)
    }
    function Get-ClusterParameter {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)]
            [object] $InputObject,
            [string] $Name
        )
        process { return [pscustomobject]@{ Value = $InputObject.DnsName } }
    }
    . $Definition
    return Get-CoreClusterNetworkNameResource -Cluster '192.0.2.10' -ClusterName 'lab-cluster'
} $coreClusterResourceFunction
Assert-Equal -Expected 'Localized Core Name' -Actual $coreClusterProbe.Name -What 'core cluster resource discovery skips a listener and matches DNS name without case sensitivity'
$missingCoreFailed = & {
    param([scriptblock] $Definition)
    function Get-ClusterResource {
        [CmdletBinding()]
        param([string] $Cluster)
        return [pscustomobject]@{ Name = 'Localized Listener'; ResourceType = 'Network Name'; DnsName = 'APP-LISTENER' }
    }
    function Get-ClusterParameter {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)]
            [object] $InputObject,
            [string] $Name
        )
        process { return [pscustomobject]@{ Value = $InputObject.DnsName } }
    }
    . $Definition
    try {
        $null = Get-CoreClusterNetworkNameResource -Cluster '192.0.2.10' -ClusterName 'LAB-CLUSTER'
        return $false
    }
    catch { return $true }
} $coreClusterResourceFunction
Assert-True -Condition $missingCoreFailed -What 'core cluster resource discovery fails when no DNS name matches'
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($clusterNicResource)) -What 'locale test located the DisableClusterNicDnsRegistration resource'
Assert-True -Condition ($clusterNicResource -match '(?s)Get-CoreClusterNetworkNameResource.*?Get-ClusterParameter -Name RegisterAllProvidersIP') -What 'Phase 5 discovers the core cluster resource through its invariant DNS name'
Assert-True -Condition ($clusterNicResource -notmatch 'Get-ClusterResource[^\r\n]*-Name\s+[''"]Cluster Name[''"]') -What 'Phase 5 does not address the core cluster resource by its localized display name'
Assert-True -Condition ($clusterNicResource -match '(?s)ManageClusterNameResource.*?Set-ClusterParameter -Name RegisterAllProvidersIP -Value 0 -ErrorAction Stop.*?Stop-ClusterResource -Wait 30 -ErrorAction Stop.*?Start-ClusterResource -Wait 30 -ErrorAction Stop.*?restartObserved.*?resourceState -ne ''Online''.*?appliedRegAll -ne 0') -What 'Phase 5 bounds and verifies the core cluster resource restart and RegisterAllProvidersIP readback'
Assert-True -Condition ($clusterNicResource -match '(?s)else\s*\{.*?State -ne ''Online''.*?Start-ClusterResource -Wait 30 -ErrorAction Stop') -What 'Phase 5 recovers an offline core resource even when RegisterAllProvidersIP is already zero'
Assert-True -Condition ($clusterNicResource -notmatch '(?:Stop|Start)-ClusterResource[^\r\n]*-ErrorAction SilentlyContinue') -What 'Phase 5 does not suppress core cluster resource restart failures'
Assert-True -Condition ($clusterNicResource -match '(?s)catch\s*\{\s*throw "Could not enforce RegisterAllProvidersIP=0') -What 'Phase 5 propagates RegisterAllProvidersIP discovery and mutation failures'
Assert-Equal -Expected 1 -Actual ([regex]::Matches($phase5, 'ManageClusterNameResource\s*=\s*\$true').Count) -What 'Phase 5 assigns RegisterAllProvidersIP mutation to one SQLAO replica'
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($clusterIpCleanupResource)) -What 'locale test located the ClusterRemoveUnwantedIPs resource'
Assert-True -Condition ($clusterIpCleanupResource -match '(?s)Get-CoreClusterNetworkNameResource.*?clusterGroupName = \[string\]\$nameRes\.OwnerGroup\.Name.*?Add-ClusterResource -Name \$resName -Group \$clusterGroupName.*?Add-ClusterResourceDependency -Resource \$nameRes\.Name.*?\$nameRes \| Update-ClusterNetworkNameResource') -What 'Phase 5 IP cleanup uses the invariant core resource and its actual localized group and resource names'
Assert-True -Condition ($clusterIpCleanupResource -notmatch '(?:Get-ClusterResource|Add-ClusterResourceDependency|Start-ClusterResource)[^\r\n]*(?:-Name|-Resource)\s+[''"]Cluster Name[''"]') -What 'Phase 5 IP cleanup does not address the core cluster resource by its localized display name'
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($clusterAccessResource)) -What 'locale test located the WaitForClusterAccess resource'
Assert-True -Condition ([regex]::Matches($clusterAccessResource, 'Get-CoreClusterNetworkNameResource').Count -ge 3 -and $clusterAccessResource -match 'clusterGroupName = \[string\]\$nameRes\.OwnerGroup\.Name') -What 'Phase 5 cluster access recovery discovers the core resource and its actual localized group name'
Assert-True -Condition ($clusterAccessResource -notmatch '(?:Get-ClusterResource|Get-ClusterGroup|Add-ClusterResource|Add-ClusterResourceDependency|Start-ClusterResource)[^\r\n]*(?:-Name|-Group|-Resource)\s+[''"]Cluster (?:Name|Group)[''"]') -What 'Phase 5 cluster access recovery does not address core objects by localized display names'
Assert-True -Condition ($phase8 -match '(?s)Script EnsurePMPCAppsAccess.*?SecurityIdentifier\]''S-1-1-0''.*?Translate\(\[Security\.Principal\.NTAccount\]\).*?New-SmbShare.*?-FullAccess @\(\$worldName, \$adminName\)') -What 'Phase 8 PMPCApps access resolves the world SID to the localized account name'
Assert-True -Condition ($phase8 -notmatch '(?s)(?:NTFSAccessEntry PMPCApps|SmbShare "PMPCShare").*?Everyone') -What 'Phase 8 PMPCApps resources do not use the English Everyone account name'
Assert-True -Condition ($phase8 -match '(?s)EnsurePMPCAppsAccess.*?share\.Path.*?E:\\PMPCApps.*?Remove-SmbShare.*?New-SmbShare') -What 'Phase 8 PMPCApps repairs an existing share that targets the wrong path'
Assert-True -Condition ($phase8 -match '(?s)EnsurePMPCAppsAccess.*?ContainerInherit.*?ObjectInherit.*?PropagationFlags.*?None.*?RemoveAccessRuleSpecific') -What 'Phase 8 PMPCApps requires inherited full access and removes explicit deny rules'
Assert-True -Condition ($phase8 -match '(?s)\$_pmpcAdmin.*?targetSids.*?adminSid.*?FullAccess @\(\$worldName, \$adminName\)') -What 'Phase 8 PMPCApps preserves explicit domain-admin full access'
$highMemoryRunner = Get-Content -LiteralPath (Join-Path $RootPath 'tools\Invoke-LocaleCmSqlAoHighMemoryTest.ps1') -Raw
$highMemoryConfigPath = Join-Path $RootPath 'config\tests\Locale-CM-SqlAo-HighMemory.json'
$highMemoryConfig = Get-Content -LiteralPath $highMemoryConfigPath -Raw | ConvertFrom-Json
Assert-True -Condition ($highMemoryRunner -match 'TotalPhysicalMemory' -and $highMemoryRunner -match '-not \$PlanOnly -and \$totalMemoryGB -lt 120') -What 'high-memory SQLAO locale test refuses real runs below the 128 GB class'
$storageProbe = Import-TestFunction -Path (Join-Path $RootPath 'tools\Invoke-LocaleCmSqlAoHighMemoryTest.ps1') -Name 'Get-MemLabsHighMemoryStorageInfo'
$missingStorageError = & {
    param($Definition)
    function Test-Path { return $false }
    function Get-PSDrive { throw 'Get-PSDrive must not run for a missing root' }
    . $Definition
    try { $null = Get-MemLabsHighMemoryStorageInfo -Path 'Q:\VirtualMachines' } catch { return $_.Exception.Message }
} $storageProbe
Assert-True -Condition ($missingStorageError -like '*storage drive is unavailable*Q:\*') -What 'high-memory SQLAO locale test rejects a missing VM storage drive'
$undersizedStorageError = & {
    param($Definition)
    function Test-Path { return $true }
    function Get-PSDrive { [pscustomobject]@{ Free = 104GB } }
    . $Definition
    try { $null = Get-MemLabsHighMemoryStorageInfo -Path 'Q:\VirtualMachines' } catch { return $_.Exception.Message }
} $storageProbe
Assert-True -Condition ($undersizedStorageError -like '*at least 105 GB free*104 GB is available*') -What 'high-memory SQLAO locale test rejects undersized VM storage'
$roundedBoundaryError = & {
    param($Definition)
    function Test-Path { return $true }
    function Get-PSDrive { [pscustomobject]@{ Free = (104.96 * 1GB) } }
    . $Definition
    try { $null = Get-MemLabsHighMemoryStorageInfo -Path 'Q:\VirtualMachines' } catch { return $_.Exception.Message }
} $storageProbe
Assert-True -Condition ($roundedBoundaryError -like '*at least 105 GB free*') -What 'high-memory SQLAO locale test compares raw free bytes before display rounding'
$sufficientStorage = & {
    param($Definition)
    function Test-Path { return $true }
    function Get-PSDrive { [pscustomobject]@{ Free = 200GB } }
    . $Definition
    Get-MemLabsHighMemoryStorageInfo -Path 'Q:\VirtualMachines'
} $storageProbe
Assert-True -Condition ($sufficientStorage.Path -eq 'Q:\VirtualMachines' -and $sufficientStorage.FreeGB -eq 200) -What 'high-memory SQLAO locale test accepts sufficient VM storage'
Assert-Equal -Expected 2 -Actual ([regex]::Matches($highMemoryRunner, "= '16GB'").Count) -What 'high-memory SQLAO locale test pins SQL maximum and minimum to 16 GB'
Assert-True -Condition ($highMemoryRunner -match '(?s)StartPhase -eq 0.*?target VM\(s\) already exist.*?StartPhase -gt 0.*?target VM\(s\) are missing') -What 'high-memory SQLAO locale test distinguishes fresh and resume VM safety'
Assert-True -Condition ($highMemoryRunner -match 'Invoke-MemLabsMonitoredDeployment\.ps1' -and $highMemoryRunner -match 'ExpectedCompletedPhase\s*=\s*11') -What 'high-memory SQLAO locale test requires monitored Phase 11 completion'
Assert-Equal -Expected 'DC,BDC,FileServer,SQLAO,SQLAO,Primary,SiteSystem,DomainMember' -Actual (@($highMemoryConfig.virtualMachines.role) -join ',') -What 'high-memory SQLAO config covers identity, storage, cluster, ConfigMgr, site-system, and client roles'
Assert-Equal -Expected 'E:\VirtualMachines' -Actual $highMemoryConfig.vmOptions.basePath -What 'high-memory SQLAO config uses the standard non-system VM storage drive'
Assert-Equal -Expected 61GB -Actual (@($highMemoryConfig.virtualMachines | ForEach-Object { $_.memory / 1 }) | Measure-Object -Sum).Sum -What 'high-memory SQLAO config remains within a 128 GB host budget'
$setLocaleMatches = [regex]::Matches($highMemoryRunner, "(?:DC1|BDC1|FS1|SQL1|SQL2|PS1SITE|DPMP1|CL1) = '([^']+)'")
$setLocales = @($setLocaleMatches | ForEach-Object { $_.Groups[1].Value })
Assert-Equal -Expected 40 -Actual $setLocales.Count -What 'five high-memory locale sets assign all eight roles'
Assert-Equal -Expected 38 -Actual @($setLocales | Sort-Object -Unique).Count -What 'high-memory locale sets cover all 38 catalog locales'
Assert-Equal -Expected ($catalogTags -join ',') -Actual (@($setLocales | Sort-Object -Unique) -join ',') -What 'high-memory locale-set coverage exactly matches the locale catalog'
Assert-Equal -Expected 'tr-TR,es-ES,it-IT,ru-RU,fr-FR' -Actual (@([regex]::Matches($highMemoryRunner, "PS1SITE = '([^']+)'") | ForEach-Object { $_.Groups[1].Value }) -join ',') -What 'high-memory sets exercise five native ConfigMgr setup languages'

$script:PreparedLocaleRequests = [Collections.Generic.List[string]]::new()
$script:ClearLocaleCacheCalls = 0
function Initialize-LocaleMedia {
    param ([string] $Locale, [string] $OperatingSystem, [switch] $RetainIsoValidation)
    $script:PreparedLocaleRequests.Add("$Locale|$OperatingSystem")
    return $true
}
function Clear-LocaleMediaIsoValidationCache { $script:ClearLocaleCacheCalls++ }

$domainFallbackConfig = [pscustomobject]@{
    domainDefaults  = [pscustomobject]@{ DefaultLocale = 'ja-JP' }
    vmOptions       = [pscustomobject]@{}
    virtualMachines = @([pscustomobject]@{ vmName = 'DOMAIN-FALLBACK'; operatingSystem = 'Server 2022' })
}
Assert-True -Condition (Initialize-LocaleMediaForPhase2 -DeployConfig $domainFallbackConfig) -What 'Phase 2 pre-stage accepts a domain-default-only locale'
Assert-True -Condition ($script:PreparedLocaleRequests -contains 'ja-JP|Server 2022') -What 'Phase 2 pre-stage prepares the domain-default locale before fan-out'

$script:PreparedLocaleRequests.Clear()
$legacyFallbackConfig = [pscustomobject]@{
    domainDefaults  = [pscustomobject]@{}
    vmOptions       = [pscustomobject]@{ locale = 'ko-KR' }
    virtualMachines = @([pscustomobject]@{ vmName = 'LEGACY-FALLBACK'; operatingSystem = 'Server 2025' })
}
Assert-True -Condition (Initialize-LocaleMediaForPhase2 -DeployConfig $legacyFallbackConfig) -What 'Phase 2 pre-stage accepts a legacy-root-only locale'
Assert-True -Condition ($script:PreparedLocaleRequests -contains 'ko-KR|Server 2025') -What 'Phase 2 pre-stage prepares the legacy root locale before fan-out'
Assert-Equal -Expected 2 -Actual $script:ClearLocaleCacheCalls -What 'Phase 2 fallback pre-stage clears validation handles after each batch'

# A cleanup cmdlet that writes success output must not turn a failed media
# preparation into a truthy multi-item result.
. $localeModulePath
function Get-LocaleMediaFiles { @() }
function Test-LocaleMediaFiles { $false }
function Test-LocaleMediaIso { $true }
function Mount-DiskImage { [pscustomobject]@{ Mounted = $true } }
function Get-Volume { [pscustomobject]@{ FileSystemLabel = 'SERVER_FOD_LP_X64FRE_MULTI_DV9'; DriveLetter = 'Z' } }
function Dismount-DiskImage { [pscustomobject]@{ Dismounted = $true } }
function Clear-LocaleMediaIsoValidationCache { }
$failureConfigRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-locale-failure-' + [guid]::NewGuid().ToString('N'))
$savedCommon = $global:Common
try {
    $global:Common = [pscustomobject]@{
        ConfigPath     = $failureConfigRoot
        AzureFilesPath = $failureConfigRoot
        TempPath       = $failureConfigRoot
        OfflineMode    = $false
    }
    $failureResult = @(Initialize-LocaleMedia -Locale 'ja-JP' -OperatingSystem 'Server 2022')
    Assert-Equal -Expected 1 -Actual $failureResult.Count -What 'media preparation failure remains one scalar result when dismount emits output'
    Assert-Equal -Expected $false -Actual $failureResult[0] -What 'media preparation failure remains false after cleanup'
}
finally {
    $global:Common = $savedCommon
    Remove-Item -LiteralPath $failureConfigRoot -Recurse -Force -ErrorAction SilentlyContinue
}

. (Import-TestFunction -Path $localeModulePath -Name 'Get-LocaleMediaFiles')
. (Import-TestFunction -Path $localeModulePath -Name 'Test-LocaleMediaFiles')
$phase3GateRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-locale-phase3-' + [guid]::NewGuid().ToString('N'))
$savedCommon = $global:Common
$script:GuestLocaleFiles = @()
$script:LocaleSessionCalls = 0
function Get-VmSession {
    $script:LocaleSessionCalls++
    [pscustomobject]@{ Name = 'locale-phase3-test' }
}
function Invoke-Command {
    [CmdletBinding()]
    param ([object] $Session, [scriptblock] $ScriptBlock)
    return @($script:GuestLocaleFiles)
}
try {
    $global:Common = [pscustomobject]@{ ConfigPath = $phase3GateRoot }
    $phase3GateConfig = [pscustomobject]@{
        domainDefaults  = [pscustomobject]@{}
        vmOptions       = [pscustomobject]@{ domainName = 'example.test' }
        virtualMachines = @([pscustomobject]@{
                vmName           = 'JP-SERVER'
                operatingSystem  = 'Server 2025'
                locale           = 'ja-JP'
                localeAcquisition = 'MicrosoftMedia'
            })
    }
    $hostPackageDir = Join-Path (Join-Path $phase3GateRoot 'locales') 'Server 2025'
    $null = New-Item -Path $hostPackageDir -ItemType Directory -Force
    $server2025JapaneseProfile = Get-LocaleDefinitionForOperatingSystem -LocaleDefinition $japaneseProfile -OperatingSystem 'Server 2025'
    $expectedPackageNames = @("Microsoft-Windows-Server-Language-Pack_x64_ja-jp.cab")
    foreach ($capability in $server2025JapaneseProfile.LanguageCapabilities) {
        $expectedPackageNames += "Microsoft-Windows-LanguageFeatures-$capability-ja-jp-Package~31bf3856ad364e35~amd64~~.cab"
    }
    foreach ($packageName in $expectedPackageNames) {
        Set-Content -LiteralPath (Join-Path $hostPackageDir $packageName) -Value $packageName -Encoding ASCII
    }

    $missingGuestIssues = @(Get-Phase3LocaleMediaIssues -DeployConfig $phase3GateConfig -ApplicableVMNames @('JP-SERVER'))
    Assert-Equal -Expected 1 -Actual $missingGuestIssues.Count -What 'Phase 3 locale gate rejects a guest whose Phase 2 package copy is absent'
    Assert-Equal -Expected 'GuestMedia' -Actual $missingGuestIssues[0].Stage -What 'Phase 3 locale gate identifies guest staging as the missing prerequisite'

    $script:GuestLocaleFiles = @(Get-ChildItem -LiteralPath $hostPackageDir -File | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Length = $_.Length } })
    Assert-Equal -Expected 0 -Actual @(Get-Phase3LocaleMediaIssues -DeployConfig $phase3GateConfig -ApplicableVMNames @('JP-SERVER')).Count -What 'Phase 3 locale gate accepts a complete Phase 2 host and guest package set'

    Remove-Item -LiteralPath (Join-Path $hostPackageDir $expectedPackageNames[0]) -Force
    $missingHostIssues = @(Get-Phase3LocaleMediaIssues -DeployConfig $phase3GateConfig -ApplicableVMNames @('JP-SERVER'))
    Assert-Equal -Expected 1 -Actual $missingHostIssues.Count -What 'Phase 3 locale gate rejects an incomplete Phase 2 host package cache'
    Assert-Equal -Expected 'HostCache' -Actual $missingHostIssues[0].Stage -What 'Phase 3 locale gate identifies host preparation as the missing prerequisite'

    $phase3GateConfig.virtualMachines[0].localeAcquisition = 'WindowsUpdate'
    Assert-Equal -Expected 0 -Actual @(Get-Phase3LocaleMediaIssues -DeployConfig $phase3GateConfig -ApplicableVMNames @('JP-SERVER')).Count -What 'Phase 3 locale gate bypasses Windows Update locale acquisition'

    $phase3GateConfig.virtualMachines = @(
        'WorkgroupMember', 'InternetClient', 'OSDClient', 'OtherDC', 'AADClient', 'StandaloneRootCA', 'Proxy', 'DHCPRelay', 'LinuxServer', 'LinuxClient' |
            ForEach-Object {
                [pscustomobject]@{
                    vmName            = "EXCLUDED-$_"
                    role              = $_
                    operatingSystem   = 'Server 2025'
                    locale            = 'ja-JP'
                    localeAcquisition = 'MicrosoftMedia'
                }
            }
    )
    $sessionCallsBeforeExcludedRoles = $script:LocaleSessionCalls
    Assert-Equal -Expected 0 -Actual @(Get-Phase3LocaleMediaIssues -DeployConfig $phase3GateConfig -ApplicableVMNames @()).Count -What 'Phase 3 locale gate ignores roles excluded from Phase 3 ConfigurationData'
    Assert-Equal -Expected $sessionCallsBeforeExcludedRoles -Actual $script:LocaleSessionCalls -What 'Phase 3 locale gate does not probe guests excluded from Phase 3 ConfigurationData'
}
finally {
    $global:Common = $savedCommon
    Remove-Item -LiteralPath $phase3GateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -ne 0) {
    throw "$script:Failures locale catalog test(s) failed"
}

Write-Host 'ALL LOCALE CATALOG TESTS PASSED' -ForegroundColor Green