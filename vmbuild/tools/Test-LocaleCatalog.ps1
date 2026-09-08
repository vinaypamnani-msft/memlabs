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
. (Import-TestFunction -Path $localeModulePath -Name 'Get-LocaleMediaFiles')
. (Import-TestFunction -Path $localeModulePath -Name 'Test-LocaleMediaFiles')
. (Import-TestFunction -Path $localeModulePath -Name 'Update-CatalogLocaleSettings')
. (Import-TestFunction -Path $sourcePath -Name 'Get-LocaleProfiles')
. (Import-TestFunction -Path $sourcePath -Name 'Get-LocaleAcquisitionMethod')
. (Import-TestFunction -Path $sourcePath -Name 'Set-DefaultLocaleForVM')
. (Import-TestFunction -Path $sourcePath -Name 'Initialize-PerVmLocales')
. (Import-TestFunction -Path $sourcePath -Name 'Select-Locale')
. (Import-TestFunction -Path $summaryPath -Name 'Get-SortedProperties')

$global:Common = [pscustomobject]@{ ConfigPath = (Join-Path $RootPath 'config') }
$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ locale = 'en-US' }
}

Write-Host "engine : $($PSVersionTable.PSVersion)"
$catalogPath = Join-Path $RootPath 'common\LocaleCatalog.json'
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
$perfloading = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\phases\perfloading.ps1') -Raw
Assert-True -Condition ($phase3 -match '\$ThisVM\.localeSettings') -What 'Phase 3 consumes the per-VM profile'
Assert-True -Condition ($phase3 -match "\$localeAcquisition -eq 'WindowsUpdate'") -What 'Phase 3 selects the online acquisition resource per VM'
Assert-True -Condition ($phase3 -match 'Install-Language -Language \$language') -What 'online acquisition downloads the selected language'
Assert-True -Condition ($phase3 -match '\$global:DSCMachineStatus = 1') -What 'online acquisition requests an automatic DSC reboot'
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
Assert-True -Condition ($addVm -match 'Set-DefaultLocaleForVM.+-RequireAvailable') -What 'new VM creation applies only an available domain locale default'
Assert-True -Condition ($addVm -match "'operatingSystem', 'locale', 'localeSettings', 'localeAcquisition'") -What 'new OSD clients discard provisional OS locale metadata'
Assert-True -Condition ($vmList -match '"DefaultLocale"\s*\{') -What 'domain default has a locale menu handler'
Assert-True -Condition ($vmList -match 'Select-Locale -ConfigToCheck \$global:config -Target \$property') -What 'VM locale edits target only the selected VM'
Assert-True -Condition ($summary -match 'Initialize-PerVmLocales -ConfigToCheck \$Global:Config') -What 'authoring migrates legacy global locales before rendering'
Assert-True -Condition ($common -match 'Common\.Locale\.ps1') -What 'shared locale media helpers load in phase workers'
Assert-True -Condition ($common -match 'Initialize-LocaleMedia -Locale \$vmLocale -OperatingSystem \$vmOperatingSystem') -What 'language-pack copy prepares missing Microsoft media automatically'
Assert-True -Condition ($scriptBlocks -match '\$locale = if \(\$currentItem\.locale\)') -What 'DSC multi-config compilation consumes the per-VM locale'
Assert-True -Condition ($scriptBlocks -match '\$localeSettings = if \(\$currentItem\.localeSettings\)') -What 'DSC multi-config compilation consumes the per-VM locale profile'
Assert-True -Condition ($phase3 -match 'InstallLanguageFeaturesOffline') -What 'Phase 3 installs Server language capabilities from cached media'
Assert-True -Condition ($phase3.Contains("Add-WindowsCapability -Online -Name `$name -Source 'C:\LanguagePacks' -LimitAccess")) -What 'Server language features cannot fall through to Windows Update'

if ($script:Failures -ne 0) {
    throw "$script:Failures locale catalog test(s) failed"
}

Write-Host 'ALL LOCALE CATALOG TESTS PASSED' -ForegroundColor Green