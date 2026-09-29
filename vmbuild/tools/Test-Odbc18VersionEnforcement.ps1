<#
.SYNOPSIS
    Verifies catalog-driven ODBC 18 enforcement for DSC and maintenance.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$genConfigPath = Join-Path $root 'common\Common.GenConfig.ps1'
$downloadCachePath = Join-Path $root 'common\Common.DownloadCache.ps1'
$fixPath = Join-Path $root 'Fixes\Fix-ODBC18.ps1'

foreach ($path in @($modulePath, $genConfigPath, $downloadCachePath, $fixPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$path has $($errors.Count) parse error(s): $($errors -join '; ')" }
}

$tokens = $null
$errors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
function Import-OdbcFunction {
    param([string]$Name)
    $definitions = @($moduleAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
. (Import-OdbcFunction -Name 'Get-MemLabsOdbcRequiredVersion')
. (Import-OdbcFunction -Name 'Get-MemLabsOdbcCatalogState')
. (Import-OdbcFunction -Name 'Get-MsiProductVersion')

$tempConfig = Join-Path ([IO.Path]::GetTempPath()) "memlabs-odbc-test-$([guid]::NewGuid().ToString('N')).json"
try {
    [IO.File]::WriteAllText($tempConfig, '{"URLMetadata":{"ODBC":{"version":"18.6.2.1"}}}')
    $catalogState = Get-MemLabsOdbcCatalogState -DeployConfigPath $tempConfig
    # Version without its fwlink is incomplete and must fall back as one pair.
    if ($catalogState.Version -ne [version]'18.6.2.1' -or $catalogState.Url -notmatch 'linkid=2358430') {
        throw 'DSC did not resolve the ODBC target from deployConfig URLMetadata.'
    }
    [IO.File]::WriteAllText($tempConfig, '{"URLMetadata":{"ODBC":{"version":"18.7.1.2","fwlink":9999999}}}')
    $catalogState = Get-MemLabsOdbcCatalogState -DeployConfigPath $tempConfig
    if ($catalogState.Version -ne [version]'18.7.1.2' -or $catalogState.Url -notmatch 'linkid=9999999') {
        throw 'DSC did not keep catalog ODBC version and fwlink atomic.'
    }
    [IO.File]::WriteAllText($tempConfig, '{}')
    $catalogState = Get-MemLabsOdbcCatalogState -DeployConfigPath $tempConfig
    if ($catalogState.Version -ne [version]'18.6.2.1' -or $catalogState.Url -notmatch 'linkid=2358430') {
        throw 'DSC compatibility floor is not ODBC 18.6.2.1.'
    }
}
finally {
    Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
}

$moduleText = Get-Content -LiteralPath $modulePath -Raw
$classMatch = [regex]::Match($moduleText, '(?s)\[DscResource\(\)\]\s*class InstallODBCDriver\s*\{.*?\n\}')
if (-not $classMatch.Success) { throw 'InstallODBCDriver class was not found.' }
$classText = $classMatch.Value
if ($classText -match '18\.1\.2\.1') {
    throw 'InstallODBCDriver still accepts the obsolete 18.1.2.1 minimum.'
}
if ($classText -notmatch 'Get-MemLabsOdbcCatalogState' -or $classText -notmatch 'Get-MemLabsOdbcRequiredVersion') {
    throw 'InstallODBCDriver does not use the atomic catalog state in Set and the catalog target in Test.'
}
if ($classText -notmatch 'Get-MsiProductVersion' -or
    $classText -notmatch '\$payloadVersion\s+-lt\s+\$requiredVersionParsed' -or
    $classText -notmatch '\$installedVersion\s+-lt\s+\$requiredVersionParsed') {
    throw 'InstallODBCDriver does not verify both MSI payload and post-install versions.'
}
if ($classText -notmatch '\[version\]::TryParse') {
    throw 'InstallODBCDriver still compares versions lexically.'
}
if ($classText -notmatch 'Invoke-DownloadFile.+-BypassCache') {
    throw 'A stale cache-DVD ODBC payload does not retry from the network.'
}

$genConfigText = Get-Content -LiteralPath $genConfigPath -Raw
$genTokens = $null
$genErrors = $null
$genAst = [System.Management.Automation.Language.Parser]::ParseFile($genConfigPath, [ref]$genTokens, [ref]$genErrors)
$resolverDefinition = @($genAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Resolve-DeployUrlCatalog'
        }, $true))
if ($resolverDefinition.Count -ne 1) { throw "Expected one Resolve-DeployUrlCatalog definition; found $($resolverDefinition.Count)." }
. ([scriptblock]::Create($resolverDefinition[0].Extent.Text))

$legacyCatalog = Resolve-DeployUrlCatalog -AzureFileList ([pscustomobject]@{
        Urls = @([pscustomobject]@{ ODBC = 'https://go.microsoft.com/fwlink/?linkid=2280794' })
        UrlsMeta = $null
    })
if ("$($legacyCatalog.Metadata.ODBC.version)" -ne '18.6.2.1' -or "$($legacyCatalog.Urls.ODBC)" -notmatch 'linkid=2358430') {
    throw 'Legacy catalog expansion did not replace ODBC version and URL as one pair.'
}
$futureCatalog = Resolve-DeployUrlCatalog -AzureFileList ([pscustomobject]@{
        Urls = @([pscustomobject]@{ ODBC = 'https://example.invalid/stale.msi' })
        UrlsMeta = [pscustomobject]@{ ODBC = [pscustomobject]@{ version = '18.7.1.2'; fwlink = 9999999 } }
    })
if ("$($futureCatalog.Metadata.ODBC.version)" -ne '18.7.1.2' -or "$($futureCatalog.Urls.ODBC)" -notmatch 'linkid=9999999') {
    throw 'Catalog expansion did not keep a future ODBC version/fwlink pair atomic.'
}
if ($genConfigText -notmatch 'Add-Member.+URLMetadata.+\$urlCatalog\.Metadata') {
    throw 'Expanded deployConfig does not carry an atomic ODBC version/fwlink pair.'
}

$script:Common = [pscustomobject]@{
    AzureFileList = [pscustomobject]@{
        UrlsMeta = [pscustomobject]@{
            ODBC = [pscustomobject]@{ version = '18.6.2.1'; fwlink = 2358430 }
        }
        Urls = @([pscustomobject]@{ ODBC = 'https://go.microsoft.com/fwlink/?linkid=2358430' })
    }
}
$script:fixesToPerform = @()
$script:vmNote = [pscustomobject]@{ role = 'DomainMember' }
. $fixPath
$fix = @($script:fixesToPerform | Where-Object { $_.FixName -eq 'Fix-ODBC18' }) | Select-Object -Last 1
if (-not $fix) { throw 'Fix-ODBC18 did not register.' }
if ($fix.FixVersion -ne '18.6.2.1' -or $fix.ArgumentList[0] -ne '18.6.2.1') {
    throw 'Fix-ODBC18 version is not driven by the catalog target.'
}
if ($fix.ArgumentList[1] -notmatch 'linkid=2358430' -or
    -not $fix.NeededOnFreshDeploy -or -not $fix.AppliesToExisting) {
    throw 'Fix-ODBC18 is not available to both new and existing VMs with the catalog URL.'
}
if (-not $fix.DoNotSeedFromWatermark) {
    throw 'Fix-ODBC18 can be incorrectly stamped by legacy watermark migration without running.'
}

$script:Common = [pscustomobject]@{
    AzureFileList = [pscustomobject]@{
        UrlsMeta = [pscustomobject]@{
            ODBC = [pscustomobject]@{ version = '18.7.1.2'; fwlink = 9999999 }
        }
        Urls = @([pscustomobject]@{ ODBC = 'https://example.invalid/stale.msi' })
    }
}
$script:fixesToPerform = @()
. $fixPath
$futureFix = @($script:fixesToPerform | Where-Object { $_.FixName -eq 'Fix-ODBC18' }) | Select-Object -Last 1
if ($futureFix.FixVersion -ne '18.7.1.2' -or $futureFix.ArgumentList[1] -notmatch 'linkid=9999999') {
    throw 'Fix-ODBC18 does not advance with a future catalog version/fwlink pair.'
}

$script:MsiStartCalls = 0
function Get-ItemPropertyValue {
    param($Path, $Name, $ErrorAction)
    '18.6.2.1'
}
function Start-Process {
    $script:MsiStartCalls++
    throw 'Start-Process should not run when ODBC is already current.'
}
$fixArgs = @($fix.ArgumentList)
$alreadyCurrent = & $fix.ScriptBlock @fixArgs
if (-not $alreadyCurrent.Success -or $script:MsiStartCalls -ne 0 -or
    $alreadyCurrent.Message -notmatch 'already 18\.6\.2\.1') {
    throw 'Fix-ODBC18 is not idempotent for an already-current VM.'
}

$fixText = Get-Content -LiteralPath $fixPath -Raw
$fixTokens = $null
$fixErrors = $null
$fixAst = [System.Management.Automation.Language.Parser]::ParseFile($fixPath, [ref]$fixTokens, [ref]$fixErrors)
$saveFunctions = @($fixAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Save-OdbcInstaller'
        }, $true))
if ($saveFunctions.Count -ne 1) { throw "Expected one Save-OdbcInstaller definition; found $($saveFunctions.Count)." }
for ($ancestor = $saveFunctions[0].Parent; $ancestor; $ancestor = $ancestor.Parent) {
    if ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ancestor.Name -eq 'Get-MsiVersion') {
        throw 'Save-OdbcInstaller is incorrectly nested inside Get-MsiVersion.'
    }
}
foreach ($requiredPattern in @(
        "IACCEPTMSODBCSQLLICENSETERMS=YES",
        "ProductVersion",
        "InstalledVersion",
        "stale after direct retry",
        "Import-Module TemplateHelpDSC",
        "ExitCode -ne 1618",
        "ExitCode -notin @\(0, 3010\)"
    )) {
    if ($fixText -notmatch $requiredPattern) {
        throw "Fix-ODBC18 is missing required enforcement pattern '$requiredPattern'."
    }
}

# An old catalog must not combine the 18.6 floor with its 18.4 fwlink.
$script:Common = [pscustomobject]@{
    AzureFileList = [pscustomobject]@{
        UrlsMeta = $null
        Urls = @([pscustomobject]@{ ODBC = 'https://go.microsoft.com/fwlink/?linkid=2280794' })
    }
}
$script:fixesToPerform = @()
. $fixPath
$fallbackFix = @($script:fixesToPerform | Where-Object { $_.FixName -eq 'Fix-ODBC18' }) | Select-Object -Last 1
if ($fallbackFix.ArgumentList[0] -ne '18.6.2.1' -or $fallbackFix.ArgumentList[1] -notmatch 'linkid=2358430') {
    throw 'Legacy file-list fallback produced a mismatched ODBC version/URL pair.'
}

$maintenanceText = Get-Content -LiteralPath (Join-Path $root 'common\Common.Maintenance.ps1') -Raw
if ($maintenanceText -notmatch 'DoNotSeedFromWatermark' -or
    $maintenanceText -notmatch 'running non-seedable compliance fix') {
    throw 'Legacy watermark migration still skips non-seedable compliance fixes.'
}

$cacheTokens = $null
$cacheErrors = $null
$cacheAst = [System.Management.Automation.Language.Parser]::ParseFile($downloadCachePath, [ref]$cacheTokens, [ref]$cacheErrors)
$cacheResolver = @($cacheAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MemlabsCacheUrlForKey'
        }, $true))
if ($cacheResolver.Count -ne 1) { throw "Expected one Get-MemlabsCacheUrlForKey definition; found $($cacheResolver.Count)." }
. ([scriptblock]::Create($cacheResolver[0].Extent.Text))
$script:Common = [pscustomobject]@{
    AzureFileList = [pscustomobject]@{
        UrlsMeta = $null
        Urls = @([pscustomobject]@{ ODBC = 'https://go.microsoft.com/fwlink/?linkid=2280794' })
    }
}
if ((Get-MemlabsCacheUrlForKey -Key ODBC) -notmatch 'linkid=2358430') {
    throw 'Host download cache still resolves ODBC from the stale main-branch fwlink.'
}
$script:Common = [pscustomobject]@{
    AzureFileList = [pscustomobject]@{
        UrlsMeta = [pscustomobject]@{
            ODBC = [pscustomobject]@{ version = '18.7.1.2'; fwlink = 9999999 }
        }
        Urls = @([pscustomobject]@{ ODBC = 'https://example.invalid/stale.msi' })
    }
}
if ((Get-MemlabsCacheUrlForKey -Key ODBC) -notmatch 'linkid=9999999') {
    throw 'Host download cache does not advance with a future ODBC catalog pair.'
}

$cachedMsi = Join-Path $root 'azureFiles\cache\ODBC.dat'
$cachedMsiSource = "$cachedMsi.src"
$cacheMatchesTarget = $false
if (Test-Path -LiteralPath $cachedMsiSource -PathType Leaf) {
    try {
        $cacheMatchesTarget = (Get-Content -LiteralPath $cachedMsiSource -Raw | ConvertFrom-Json).url -match 'linkid=2358430'
    }
    catch {
        Write-Warning "Could not read ODBC cache source metadata '$cachedMsiSource': $($_.Exception.Message)"
    }
}
if ($cacheMatchesTarget -and (Test-Path -LiteralPath $cachedMsi -PathType Leaf)) {
    $cachedVersion = [version](Get-MsiProductVersion -Path $cachedMsi)
    if ($cachedVersion -lt [version]'18.6.2.1') {
        throw "Host ODBC cache is stale: $cachedVersion."
    }
    Write-Host "INFO -- cached ODBC MSI ProductVersion=$cachedVersion"

    $script:InstalledOdbcVersion = '18.4.1.1'
    $script:MsiStartCalls = 0
    $script:MsiArguments = @()
    function Get-ItemPropertyValue {
        param($Path, $Name, $ErrorAction)
        $script:InstalledOdbcVersion
    }
    function Start-Process {
        param(
            $FilePath,
            $ArgumentList,
            [switch]$Wait,
            [switch]$PassThru,
            [switch]$NoNewWindow,
            $ErrorAction
        )
        $script:MsiStartCalls++
        $script:MsiArguments = @($ArgumentList)
        $script:InstalledOdbcVersion = '18.6.2.1'
        [pscustomobject]@{ ExitCode = 0 }
    }
    $sourceUri = ([uri]::new((Resolve-Path -LiteralPath $cachedMsi).Path)).AbsoluteUri
    $upgradeOutput = @(& $fix.ScriptBlock '18.6.2.1' $sourceUri)
    $upgradeResult = @($upgradeOutput | Where-Object { $_.PSObject.Properties.Name -contains 'Success' }) | Select-Object -Last 1
    if (-not $upgradeResult.Success -or $script:MsiStartCalls -ne 1 -or
        ($script:MsiArguments -join ' ') -notmatch '/qn /norestart IACCEPTMSODBCSQLLICENSETERMS=YES' -or
        $upgradeResult.Message -notmatch "18\.4\.1\.1.+18\.6\.2\.1") {
        throw 'Fix-ODBC18 did not execute and verify the expected 18.4-to-18.6 upgrade path.'
    }
}
elseif (Test-Path -LiteralPath $cachedMsi -PathType Leaf) {
    Write-Host 'INFO -- cached ODBC MSI uses an older source URL; the download-cache resolver will refresh it.'
}

# Routing: ODBC enforcement (AppliesToExisting=$true, NeededOnFreshDeploy=$true) must
# reach an existing SQL/DomainMember VM through EVERY maintenance route memlabs has --
# the interactive Start-Maintenance existing-VM branch, the mandatory pre-phase-dispatch
# Start-RequiredExistingVMMaintenance gate, and Phase 10 -- and none of those routes may
# special-case or exclude it by name. All three must select fixes generically by the
# AppliesToExisting flag so a future compliance fix is picked up automatically too.
if ($maintenanceText -notmatch '(?s)function Start-Maintenance\b.*?AppliesToExisting -eq \$true') {
    throw 'Interactive Start-Maintenance no longer routes existing-VM fixes (including Fix-ODBC18) through the generic AppliesToExisting filter.'
}
if ($maintenanceText -notmatch '(?s)function Start-RequiredExistingVMMaintenance\b.*?AppliesToExisting -eq \$true') {
    throw 'The mandatory existing-VM maintenance gate no longer routes fixes (including Fix-ODBC18) through the generic AppliesToExisting filter.'
}
if ($maintenanceText -match "(?s)function Start-RequiredExistingVMMaintenance\b.*?Fix-ODBC18") {
    throw 'The mandatory existing-VM maintenance gate must not special-case Fix-ODBC18 by name -- it has to route generically via AppliesToExisting.'
}
$phaseText = Get-Content -LiteralPath (Join-Path $root 'common\Common.Phases.ps1') -Raw
if ($phaseText -notmatch '(?s)elseif \(\$Phase -eq 10\).*?\$global:Phase10Job.*?\$currentItem, \(, @\(\)\), \$false') {
    throw 'Phase 10 no longer dispatches every VM (fresh and existing) through the AppliesToExisting-equivalent FreshDeployOnly=$false path.'
}

Write-Host 'PASS -- ODBC 18 target is catalog-driven, payload-verified, and enforced by DSC plus maintenance.'
Write-Host 'PASS -- ODBC (and every AppliesToExisting fix) is routed generically through interactive maintenance, the mandatory existing-VM gate, and Phase 10.'
