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
. (Import-OdbcFunction -Name 'Get-MemLabsInstalledOdbc18Version')
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
if ($classText -notmatch 'Get-MemLabsInstalledOdbc18Version' -or
    $classText -notmatch '\.AddSeconds\(60\)' -or
    $classText -notmatch 'REINSTALL=ALL' -or
    $classText -notmatch 'REINSTALLMODE=vomus') {
    throw 'InstallODBCDriver does not use architecture-safe detection with bounded verification and repair.'
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

$maintenanceBody = [scriptblock]::Create(
    $fix.ScriptBlock.Ast.ParamBlock.Extent.Text + "`n" +
    ((@($fix.ScriptBlock.Ast.EndBlock.Statements | Where-Object {
                    $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst]
                }) | ForEach-Object { $_.Extent.Text }) -join "`n")
)
$odbcClassAst = $moduleAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq 'InstallODBCDriver'
    }, $true)
$dscSet = $odbcClassAst.Members | Where-Object Name -eq 'Set'
$dscBody = [scriptblock]::Create(
    ($dscSet.Body.EndBlock.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"
)

function Invoke-OdbcInstallerFixture {
    param([scriptblock]$Body, [string]$Mode, [switch]$Dsc)

    & {
        $script:OdbcFixture = @{
            Mode = $Mode
            Version = if ($Mode -eq 'Current') { [version]'18.6.2.1' } elseif ($Mode -eq 'Upgrade') { [version]'18.4.1.1' } else { $null }
            CoreState = if ($Mode -in @('Repair', 'RepairReboot', 'Current')) { 3 } else { 2 }
            Clock = [datetime]'2026-10-15T12:00:00'
            Calls = [System.Collections.Generic.List[object]]::new()
            Copies = [System.Collections.Generic.List[string]]::new()
            Removals = [System.Collections.Generic.List[string]]::new()
        }
        function Get-InstalledOdbc18Version { return $script:OdbcFixture.Version }
        function Get-MemLabsInstalledOdbc18Version { return $script:OdbcFixture.Version }
        function Get-MsiVersion {
            param($Path, [hashtable]$InstallerState)
            [void]$Path
            if ($null -ne $InstallerState) {
                $InstallerState.Clear()
                $InstallerState.Installed = $true
                $InstallerState.CoreState = $script:OdbcFixture.CoreState
                $InstallerState.PackageName = 'original-driver.msi'
            }
            return '18.6.2.1'
        }
        function Get-MsiProductVersion {
            param($Path, [hashtable]$InstallerState)
            Get-MsiVersion -Path $Path -InstallerState $InstallerState
        }
        function Get-MemLabsOdbcCatalogState {
            [pscustomobject]@{ Version = [version]'18.6.2.1'; Url = 'https://example.invalid/odbc.msi' }
        }
        function Install-OdbcVcRuntimePrerequisite {
            param($Url)
            [void]$Url
            [pscustomobject]@{ Message = 'VC++ runtime ready'; ExitCode = 0 }
        }
        function Save-OdbcInstaller {
            param($Url, $Path, [switch]$BypassCache)
            [void]$Url; [void]$Path; [void]$BypassCache
        }
        function Invoke-DownloadFile {
            param($Url, $Dest, [switch]$BypassCache)
            [void]$Url; [void]$Dest; [void]$BypassCache
        }
        function Test-Path { param($LiteralPath, $Path, $PathType) return $true }
        function New-Item { param($Path, $ItemType, [switch]$Force, $ErrorAction) }
        function Copy-Item {
            param($LiteralPath, $Destination, [switch]$Force, $ErrorAction)
            [void]$LiteralPath; [void]$Force; [void]$ErrorAction
            $script:OdbcFixture.Copies.Add("$Destination")
        }
        function Remove-Item {
            param($LiteralPath, [switch]$Force, $ErrorAction)
            [void]$Force; [void]$ErrorAction
            $script:OdbcFixture.Removals.Add("$LiteralPath")
        }
        function Get-Content { param($LiteralPath, $Path, $Tail, $ErrorAction) 'Feature: SQL_SQLODBC_CORE; Installed: Absent; Request: Null; Action: Null' }
        function Get-OdbcMsiFailureDetails {
            param($LogPath)
            "Feature: SQL_SQLODBC_CORE; Installed: Absent; Log: $LogPath"
        }
        function Write-Status { param($Status) [void]$Status }
        function Get-Date { return $script:OdbcFixture.Clock }
        function Start-Sleep {
            param([int]$Seconds)
            $script:OdbcFixture.Clock = $script:OdbcFixture.Clock.AddSeconds($Seconds)
        }
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow, $ErrorAction)
            [void]$Wait; [void]$PassThru; [void]$NoNewWindow; [void]$ErrorAction
            $line = @($ArgumentList) -join ' '
            $script:OdbcFixture.Calls.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = $line })
            $attempt = $script:OdbcFixture.Calls.Count
            if ($script:OdbcFixture.Mode -eq 'PermanentFailure' -or
                ($script:OdbcFixture.Mode -eq 'InitialFailure' -and $attempt -eq 1)) {
                return [pscustomobject]@{ ExitCode = 1603 }
            }
            $defer = $script:OdbcFixture.Mode -in @('Repair', 'RepairReboot') -and $attempt -eq 1
            $adding = $line -match '\bADDLOCAL=ALL\b' -and $line -notmatch '\bREINSTALL=ALL\b'
            $repairing = $line -match '\bREINSTALL=ALL\b' -and $script:OdbcFixture.CoreState -eq 3
            if (-not $defer -and $script:OdbcFixture.Mode -ne 'NoOp' -and ($adding -or $repairing)) {
                $script:OdbcFixture.CoreState = 3
                $script:OdbcFixture.Version = [version]'18.6.2.1'
            }
            [pscustomobject]@{ ExitCode = if ($script:OdbcFixture.Mode -eq 'RepairReboot' -and $attempt -eq 2) { 3010 } else { 0 } }
        }
        . (Import-OdbcFunction -Name 'Install-MSIPackage')
        $resource = [pscustomobject]@{ ODBCPath = 'C:\temp\msodbcsql.msi' }
        $resource | Add-Member -MemberType ScriptMethod -Name SetForTest -Value $Body
        $output = @()
        $failure = $null
        try {
            if ($Dsc) { $output = @($resource.SetForTest()) }
            else { $output = @(& $Body '18.6.2.1' 'https://example.invalid/odbc.msi' 'https://example.invalid/vc_redist.x64.exe' 3>$null 6>$null) }
        }
        catch { $failure = $_.Exception.Message }
        [pscustomobject]@{
            Calls = @($script:OdbcFixture.Calls)
            Copies = @($script:OdbcFixture.Copies)
            Removals = @($script:OdbcFixture.Removals)
            Version = $script:OdbcFixture.Version
            Failure = $failure
            Result = $output | Where-Object { $_.PSObject.Properties['Success'] } | Select-Object -Last 1
        }
    }
}

foreach ($surface in @('Maintenance', 'DSC')) {
    $body = if ($surface -eq 'Maintenance') { $maintenanceBody } else { $dscBody }
    foreach ($mode in @('AbsentCore', 'Upgrade', 'Repair', 'RepairReboot', 'InitialFailure', 'PermanentFailure', 'NoOp')) {
        $probe = Invoke-OdbcInstallerFixture -Body $body -Mode $mode -Dsc:($surface -eq 'DSC')
        $expectedFailure = $mode -in @('PermanentFailure', 'NoOp')
        if ([bool]$probe.Failure -ne $expectedFailure -or
            (-not $expectedFailure -and $probe.Version -ne [version]'18.6.2.1')) {
            throw "$surface $mode did not converge or fail as expected: $($probe.Failure)"
        }
        if ($surface -eq 'Maintenance' -and -not $expectedFailure -and -not $probe.Result.Success) {
            throw "Maintenance $mode did not report explicit success."
        }
        if (@($probe.Copies | Where-Object { $_ -like '*\MemLabs\Installers\ODBC18\18.6.2.1\original-driver.msi' }).Count -ne 1 -or
            @($probe.Removals | Where-Object { $_ -like '*\MemLabs\Installers\ODBC18\*' }).Count) {
            throw "$surface $mode did not retain the validated MSI under its registered package name."
        }
        foreach ($call in $probe.Calls) {
            if ($call.Arguments -notmatch '\bADDLOCAL=ALL\b' -or
                $call.Arguments -notmatch '\bIACCEPTMSODBCSQLLICENSETERMS=YES\b' -or
                $call.Arguments -notmatch 'original-driver\.msi') {
                throw "$surface $mode lost feature selection, license acceptance, or the registered source filename."
            }
        }
        if ($mode -in @('AbsentCore', 'InitialFailure') -and
            @($probe.Calls | Where-Object Arguments -match '\bREINSTALL=ALL\b').Count) {
            throw "$surface $mode incorrectly used REINSTALL to add an absent core feature."
        }
        if ($mode -in @('Repair', 'RepairReboot', 'InitialFailure', 'PermanentFailure', 'NoOp')) {
            if ($probe.Calls.Count -ne 2) { throw "$surface $mode did not use exactly one bounded recovery stage." }
            $logs = @($probe.Calls | ForEach-Object {
                    [regex]::Match($_.Arguments, '/l\*v\s+"([^"]+)"').Groups[1].Value
                })
            if (-not $logs[0] -or -not $logs[1] -or $logs[0] -eq $logs[1]) {
                throw "$surface $mode overwrote the initial MSI log with its repair log."
            }
        }
        if ($surface -eq 'Maintenance' -and $mode -eq 'RepairReboot' -and
            ($probe.Result.Errors -join ' ') -notmatch 'reboot') {
            throw 'Maintenance did not retain the repair MSI reboot requirement.'
        }
    }
}
$alreadyCurrent = Invoke-OdbcInstallerFixture -Body $maintenanceBody -Mode 'Current'
if (-not $alreadyCurrent.Result.Success -or $alreadyCurrent.Calls.Count -ne 0 -or $alreadyCurrent.Failure) {
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
$installedVersionFunctions = @($fixAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-InstalledOdbc18Version'
        }, $true))
if ($installedVersionFunctions.Count -ne 1) { throw "Expected one Get-InstalledOdbc18Version definition; found $($installedVersionFunctions.Count)." }
. ([scriptblock]::Create($installedVersionFunctions[0].Extent.Text))
$crossViewVersion = Get-InstalledOdbc18Version -RegistryValueReader {
    @('', '18.4.1.1', 'not-a-version', '18.6.2.1')
}
if ($crossViewVersion -ne [version]'18.6.2.1') {
    throw "Architecture-safe ODBC version detection did not select the highest valid registry value: $crossViewVersion"
}
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
        'Feature: SQL_SQLODBC_CORE; Installed: Absent; Request: Null; Action: Null',
        'Action start 12:00:00: CA_ErrorPendingReboot.',
        'A previous installation required a reboot of the machine for changes to take effect.',
        'Action ended 12:00:00: CA_ErrorPendingReboot. Return value 3.',
        'Installation success or error status: 1603.'
    ) | Set-Content -LiteralPath $syntheticMsiLog -Encoding UTF8
    $failureDetails = Get-OdbcMsiFailureDetails -LogPath $syntheticMsiLog
    if ($failureDetails -notmatch 'Failure markers:' -or
        $failureDetails -notmatch 'Feature: SQL_SQLODBC_CORE' -or
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
        "ADDLOCAL=ALL",
        '\$argumentLine = \$arguments -join '' ''',
        '-ArgumentList \$argumentLine',
        "ProductVersion",
        "InstalledVersion",
        "ODBCINST\.INI",
        "DisplayVersion",
        "GetValue\('Driver'",
        "REINSTALL=ALL",
        "REINSTALLMODE=vomus",
        "remained unavailable after a successful forced repair",
        "RegistryView\]::Registry64",
        "RegistryView\]::Registry32",
        "\.AddSeconds\(60\)",
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
if ($fixText -match '[''"]/x[''"]') {
    throw 'Fix-ODBC18 must never uninstall an existing ODBC driver.'
}
if ($classText -match 'VerifyRegistryPath\s+"HKLM:\\Software\\Microsoft\\MSODBCSQL18"') {
    throw 'InstallODBCDriver still performs the legacy immediate registry assertion before bounded recovery.'
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

}
elseif (Test-Path -LiteralPath $cachedMsi -PathType Leaf) {
    Write-Host 'INFO -- cached ODBC MSI uses an older source URL; the download-cache resolver will refresh it.'
}

Write-Host 'PASS -- ODBC 18 feature selection, source identity, bounded recovery, and catalog versions are enforced by DSC plus maintenance.'
