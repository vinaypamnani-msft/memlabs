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
$phase3Path = Join-Path $root 'DSC\phases\Phase3.ps1'

foreach ($path in @($modulePath, $genConfigPath, $downloadCachePath, $fixPath, $phase3Path)) {
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
if ($classText -notmatch 'SKIPPENDINGREBOOTCHECK=1') {
    throw 'InstallODBCDriver still lets unrelated pending file renames trigger MSI error 25003.'
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
        Urls = @([pscustomobject]@{
                ODBC = 'https://go.microsoft.com/fwlink/?linkid=2358430'
                VCredist = 'https://example.invalid/catalog-vc_redist.x64.exe'
            })
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
    $fix.ArgumentList[2] -ne 'https://example.invalid/catalog-vc_redist.x64.exe' -or
    -not $fix.NeededOnFreshDeploy -or -not $fix.AppliesToExisting) {
    throw 'Fix-ODBC18 is not available to both new and existing VMs with the ODBC and VC++ prerequisite URLs.'
}
$expectedCmRoles = @('CAS', 'DPMP', 'PassiveSite', 'Primary', 'Secondary', 'SiteSystem', 'WSUS')
if ((@($fix.AppliesToRoles | Sort-Object) -join ',') -ne ($expectedCmRoles -join ',') -or
    @($fix.NotAppliesToRoles).Count -ne 0) {
    throw "Fix-ODBC18 must apply only to ConfigMgr server and WSUS roles by default; actual roles: $(@($fix.AppliesToRoles) -join ', ')."
}
$script:vmNote = [pscustomobject]@{ role = 'DomainMember'; sqlVersion = 'SQL Server 2022' }
$script:fixesToPerform = @()
. $fixPath
$sqlHostFix = @($script:fixesToPerform | Where-Object { $_.FixName -eq 'Fix-ODBC18' }) | Select-Object -Last 1
if ($sqlHostFix.AppliesToRoles -notcontains 'DomainMember') {
    throw 'Fix-ODBC18 does not dynamically include a VM that hosts SQL.'
}
$script:vmNote = [pscustomobject]@{ role = 'InternetClient' }
$script:fixesToPerform = @()
. $fixPath
$internetClientFix = @($script:fixesToPerform | Where-Object { $_.FixName -eq 'Fix-ODBC18' }) | Select-Object -Last 1
if ($internetClientFix.AppliesToRoles -contains 'InternetClient') {
    throw 'Fix-ODBC18 still applies to an InternetClient that does not host SQL.'
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
$phase3Text = Get-Content -LiteralPath $phase3Path -Raw
if ($phase3Text -notmatch '(?s)\$cmServerRoles\s*=\s*@\(''CAS'',\s*''Primary'',\s*''Secondary'',\s*''SiteSystem'',\s*''PassiveSite'',\s*''DPMP''\).*?\$odbcRequired\s*=\s*\$ThisVM\.role\s+-in\s+\$cmServerRoles\s+-or\s+\$ThisVM\.role\s+-eq\s+''WSUS''\s+-or\s+-not\s+\[string\]::IsNullOrWhiteSpace\("\$\(\$ThisVM\.sqlVersion\)"\).*?if\s*\(\$odbcRequired\)\s*\{.*?InstallODBCDriver\s+ODBCDriverInstall') {
    throw 'Phase 3 does not gate ODBC installation to ConfigMgr servers, WSUS servers, or SQL hosts.'
}
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
$failureDetailFunctions = @($fixAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-OdbcMsiFailureDetails'
        }, $true))
if ($failureDetailFunctions.Count -ne 1) { throw "Expected one Get-OdbcMsiFailureDetails definition; found $($failureDetailFunctions.Count)." }
. ([scriptblock]::Create($failureDetailFunctions[0].Extent.Text))
$syntheticMsiLog = Join-Path ([IO.Path]::GetTempPath()) "memlabs-odbc-failure-$([guid]::NewGuid().ToString('N')).log"
try {
    @(
        'Action start 12:00:00: CA_ErrorPendingReboot.',
        'A previous installation required a reboot of the machine for changes to take effect.',
        'Action ended 12:00:00: CA_ErrorPendingReboot. Return value 3.',
        'Installation success or error status: 1603.'
    ) | Set-Content -LiteralPath $syntheticMsiLog -Encoding UTF8
    $failureDetails = Get-OdbcMsiFailureDetails -LogPath $syntheticMsiLog
    if ($failureDetails -notmatch 'Failure markers:' -or
        $failureDetails -notmatch 'previous installation required a reboot' -or
        $failureDetails -notmatch 'Return value 3') {
        throw "ODBC MSI failure diagnostics omitted the actionable pending-reboot markers: $failureDetails"
    }
}
finally {
    Remove-Item -LiteralPath $syntheticMsiLog -Force -ErrorAction SilentlyContinue
}
$vcInstallFunctions = @($fixAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Install-OdbcVcRuntimePrerequisite'
        }, $true))
if ($vcInstallFunctions.Count -ne 1) { throw "Expected one Install-OdbcVcRuntimePrerequisite definition; found $($vcInstallFunctions.Count)." }
$vcInstallProbe = & {
    $script:VcStateReads = 0
    $script:VcStartCalls = 0
    $script:VcArguments = @()
    function Get-OdbcVcRuntimeState {
        $script:VcStateReads++
        if ($script:VcStateReads -eq 1) {
            return [pscustomobject]@{ Ready = $false; Major = 0; Minor = 0; Build = 0; FilesReady = $false; RegistryPath = 'test' }
        }
        return [pscustomobject]@{ Ready = $true; Major = 14; Minor = 44; Build = 35211; FilesReady = $true; RegistryPath = 'test' }
    }
    function Save-OdbcInstaller {
        param($Url, $Path, [switch]$BypassCache, $Label)
        [void]$Url
        [void]$Path
        [void]$BypassCache
        [void]$Label
    }
    function Get-Item {
        param($LiteralPath, $ErrorAction)
        [void]$LiteralPath
        [void]$ErrorAction
        [pscustomobject]@{ Length = 25MB }
    }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow, $ErrorAction)
        [void]$FilePath
        [void]$Wait
        [void]$PassThru
        [void]$NoNewWindow
        [void]$ErrorAction
        $script:VcStartCalls++
        $script:VcArguments = @($ArgumentList)
        [pscustomobject]@{ ExitCode = 0 }
    }
    function Remove-Item {
        param($LiteralPath, [switch]$Force, $ErrorAction)
        [void]$LiteralPath
        [void]$Force
        [void]$ErrorAction
    }
    . ([scriptblock]::Create($vcInstallFunctions[0].Extent.Text))
    $result = Install-OdbcVcRuntimePrerequisite -Url 'https://example.invalid/vc_redist.x64.exe'
    [pscustomobject]@{
        Result     = $result
        StateReads = $script:VcStateReads
        StartCalls = $script:VcStartCalls
        Arguments  = @($script:VcArguments)
    }
}
if (-not $vcInstallProbe.Result.Installed -or
    $vcInstallProbe.StateReads -ne 2 -or
    $vcInstallProbe.StartCalls -ne 1 -or
    ($vcInstallProbe.Arguments -join ' ') -notmatch '/install /quiet /norestart /log') {
    throw 'Fix-ODBC18 did not install and verify the missing VC++ x64 runtime prerequisite.'
}
foreach ($requiredPattern in @(
        "IACCEPTMSODBCSQLLICENSETERMS=YES",
        "ProductVersion",
        "InstalledVersion",
        "stale after direct retry",
        "Import-Module TemplateHelpDSC",
        "Get-OdbcVcRuntimeState",
        "Install-OdbcVcRuntimePrerequisite",
        "vc_redist\.x64\.exe",
        "20MB",
        "33135",
        "SKIPPENDINGREBOOTCHECK=1",
        "previous installation required a reboot",
        "Return value 3",
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
$hostVcRuntime = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64' -ErrorAction SilentlyContinue
$hostVcReady = (($hostVcRuntime.Major -gt 14) -or
    ($hostVcRuntime.Major -eq 14 -and $hostVcRuntime.Minor -gt 34) -or
    ($hostVcRuntime.Major -eq 14 -and $hostVcRuntime.Minor -eq 34 -and $hostVcRuntime.Bld -ge 33135)) -and
    (Test-Path -LiteralPath "$env:windir\System32\vcruntime140.dll" -PathType Leaf) -and
    (Test-Path -LiteralPath "$env:windir\System32\msvcp140.dll" -PathType Leaf)
if (Test-Path -LiteralPath $cachedMsiSource -PathType Leaf) {
    try {
        $cacheMatchesTarget = (Get-Content -LiteralPath $cachedMsiSource -Raw | ConvertFrom-Json).url -match 'linkid=2358430'
    }
    catch {
        Write-Warning "Could not read ODBC cache source metadata '$cachedMsiSource': $($_.Exception.Message)"
    }
}
if ($cacheMatchesTarget -and (Test-Path -LiteralPath $cachedMsi -PathType Leaf) -and $hostVcReady) {
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
    $upgradeOutput = @(& $fix.ScriptBlock '18.6.2.1' $sourceUri $fix.ArgumentList[2])
    $upgradeResult = @($upgradeOutput | Where-Object { $_.PSObject.Properties.Name -contains 'Success' }) | Select-Object -Last 1
    if (-not $upgradeResult.Success -or $script:MsiStartCalls -ne 1 -or
        ($script:MsiArguments -join ' ') -notmatch '/qn /norestart IACCEPTMSODBCSQLLICENSETERMS=YES SKIPPENDINGREBOOTCHECK=1' -or
        $upgradeResult.Message -notmatch "18\.4\.1\.1.+18\.6\.2\.1") {
        throw 'Fix-ODBC18 did not execute and verify the expected 18.4-to-18.6 upgrade path.'
    }
}
elseif ($cacheMatchesTarget -and (Test-Path -LiteralPath $cachedMsi -PathType Leaf)) {
    Write-Host 'INFO -- skipping the real cached-MSI upgrade probe because this test host lacks the VC++ runtime; the mocked missing-runtime path was validated above.'
}
elseif (Test-Path -LiteralPath $cachedMsi -PathType Leaf) {
    Write-Host 'INFO -- cached ODBC MSI uses an older source URL; the download-cache resolver will refresh it.'
}

Write-Host 'PASS -- ODBC 18 target is catalog-driven, payload-verified, and enforced by DSC plus maintenance.'
