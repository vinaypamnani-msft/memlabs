<#
.SYNOPSIS
    Verifies that only the pre-content SMSSIG state is non-fatal in Phase 11.
#>
[CmdletBinding()]
param(
    [string]$RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($validationPath, [ref]$tokens, [ref]$errors)
$parseErrors = @($errors | Where-Object { $null -ne $_ })
if ($parseErrors.Count -ne 0) {
    throw "$validationPath has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$definitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-DpSignatureConfigPendingContent'
        }, $true))
if ($definitions.Count -ne 1) {
    throw "Expected one Test-DpSignatureConfigPendingContent definition, found $($definitions.Count)"
}
. ([scriptblock]::Create($definitions[0].Extent.Text))

$providerDefinitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-DpProviderProvisioningEvidence'
        }, $true))
if ($providerDefinitions.Count -ne 1) {
    throw "Expected one Get-DpProviderProvisioningEvidence definition, found $($providerDefinitions.Count)"
}
. ([scriptblock]::Create($providerDefinitions[0].Extent.Text))

$providerPathDefinitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-DpProviderLogPath'
        }, $true))
if ($providerPathDefinitions.Count -ne 1) {
    throw "Expected one Get-DpProviderLogPath definition, found $($providerPathDefinitions.Count)"
}
. ([scriptblock]::Create($providerPathDefinitions[0].Extent.Text))

$base = @{
    ConfigPath            = 'Default Web Site/SMS_DP_SMSSIG$'
    Description           = 'Cannot read configuration file'
    FileName              = '\\?\UNC\CT1-SS2SITE.CSTEST1.COM\SMSSIG$\web.config'
    LineNumber            = '0'
    PhysicalPath          = '\\CT1-SS2SITE.CSTEST1.COM\SMSSIG$'
    SignatureSharePresent = $false
    PackageState          = 'Missing'
    DpRegistryPresent     = $true
    DpSharePresent        = $true
    ProviderRan           = $true
    ProviderFailed        = $false
    LocalNames            = @('CT1-SS2SITE', 'CT1-SS2SITE.CSTEST1.COM')
}

function Assert-Classification {
    param(
        [Parameter(Mandatory)][bool]$Expected,
        [Parameter(Mandatory)][hashtable]$Overrides,
        [Parameter(Mandatory)][string]$Name
    )

    $case = $base.Clone()
    foreach ($key in $Overrides.Keys) { $case[$key] = $Overrides[$key] }
    $actual = Test-DpSignatureConfigPendingContent @case
    if ($actual -ne $Expected) {
        throw "$Name expected $Expected but returned $actual"
    }
    Write-Host "PASS  $Name"
}

Assert-Classification -Expected $true -Overrides @{} -Name 'fresh self-UNC signature app with no content is pending'
Assert-Classification -Expected $true -Overrides @{ PackageState = 'Empty' } -Name 'empty PkgLib is pending'
Assert-Classification -Expected $false -Overrides @{ PackageState = 'Populated' } -Name 'imported content keeps the failure fatal'
Assert-Classification -Expected $false -Overrides @{ PackageState = 'Unknown' } -Name 'unmeasurable package state keeps the failure fatal'
Assert-Classification -Expected $false -Overrides @{ SignatureSharePresent = $true } -Name 'published but unreadable share keeps the failure fatal'
Assert-Classification -Expected $false -Overrides @{ ProviderFailed = $true } -Name 'provider failure keeps the failure fatal'
Assert-Classification -Expected $false -Overrides @{ ProviderRan = $false } -Name 'missing provider evidence keeps the failure fatal'
Assert-Classification -Expected $false -Overrides @{ FileName = '\\?\UNC\OTHER.CSTEST1.COM\SMSSIG$\web.config' } -Name 'remote signature path keeps the failure fatal'
Assert-Classification -Expected $false -Overrides @{ PhysicalPath = 'E:\SMSSIG$' } -Name 'local path configuration error keeps the failure fatal'
Assert-Classification -Expected $false -Overrides @{ Description = "Cannot add duplicate collection entry of type 'add'" } -Name 'malformed web.config keeps the failure fatal'
Assert-Classification -Expected $false -Overrides @{ LineNumber = '42' } -Name 'nonzero configuration line keeps the failure fatal'

$providerEvidence = Get-DpProviderProvisioningEvidence -Lines @(
    'CSMSDPInstProv::CreateVirtualDirectory creating virtual directory SMS_DP_SMSPKG$',
    'Successfully created the virtual directory SMS_DP_SMSPKG$ for the physical path E:\SCCMContentLib.',
    'Successfully created the virtual directory SMS_DP_SMSSIG$ for the physical path \\CT1-SS2SITE.CSTEST1.COM\SMSSIG$.'
)
if (-not $providerEvidence.Ran -or $providerEvidence.Failed) {
    throw 'A successful current provider session was not recognized.'
}
Write-Host 'PASS  successful current provider session is recognized'

$providerEvidence = Get-DpProviderProvisioningEvidence -Lines @(
    'CSMSDPInstProv::CreateVirtualDirectory creating virtual directory SMS_DP_SMSPKG$',
    'Successfully created the virtual directory SMS_DP_SMSSIG$ for the physical path \\CT1-SS2SITE.CSTEST1.COM\SMSSIG$.',
    'CreateContentLibrary failed with a fatal error'
)
if (-not $providerEvidence.Ran -or -not $providerEvidence.Failed) {
    throw 'A failure in the current provider session was not preserved.'
}
Write-Host 'PASS  current provider-session failure remains fatal'

$providerEvidence = Get-DpProviderProvisioningEvidence -Lines @(
    'CreateContentLibrary failed with a fatal error',
    'CSMSDPInstProv::CreateVirtualDirectory creating virtual directory SMS_DP_SMSPKG$',
    'Successfully created the virtual directory SMS_DP_SMSSIG$ for the physical path E:\SMSSIG$.'
)
if (-not $providerEvidence.Ran -or $providerEvidence.Failed) {
    throw 'A recovered provider session inherited a failure from an older session.'
}
Write-Host 'PASS  older provider-session failures do not poison a recovered session'

$providerEvidence = Get-DpProviderProvisioningEvidence -Lines @('unrelated log output')
if ($providerEvidence.Ran -or $providerEvidence.Failed) {
    throw 'Unrelated or unmeasurable provider output was treated as provisioning evidence.'
}
Write-Host 'PASS  unrelated provider output is not sufficient evidence'

$activeProviderLog = Get-DpProviderLogPath -DpSharePath 'F:\SMS_DP$'
if ($activeProviderLog -ne 'F:\SMS_DP$\sms\logs\smsdpprov.log') {
    throw "Provider log path did not follow the active SMS_DP$ share: $activeProviderLog"
}
if (Get-DpProviderLogPath -DpSharePath '') {
    throw 'An absent active SMS_DP$ share produced a provider log path.'
}
Write-Host 'PASS  provider evidence is rooted at the active SMS_DP$ share'

$validationText = Get-Content -LiteralPath $validationPath -Raw
if ($validationText -notmatch '(?s)if \(Test-DpSignatureConfigPendingContent @pendingSignatureParams\).*?WARN: IIS signature application.*?continue') {
    throw 'Phase 11 does not downgrade the classified pre-content signature state to a warning.'
}
if ($validationText -notmatch '(?s)\$providerLines\s*=\s*@\(Get-Content.+?-ErrorAction Stop\).*?Get-DpProviderProvisioningEvidence') {
    throw 'Provider evidence collection does not fail closed when smsdpprov.log cannot be read.'
}
$providerSelection = [regex]::Match(
    $validationText,
    '(?s)\$providerLog\s*=\s*Get-DpProviderLogPath.+?\$providerFailed\s*=\s*\$false'
)
if (-not $providerSelection.Success -or
    $providerSelection.Value -notmatch [regex]::Escape('$dpShare.Path') -or
    $providerSelection.Value -match 'foreach\s*\(\$drive') {
    throw 'Provider evidence is not selected exclusively from the active SMS_DP$ share.'
}
if (-not $validationText.Contains("Get-SmbShareAccess -Name 'SMSSIG`$'")) {
    throw 'The DP failure collector does not capture SMSSIG$ share access.'
}
if (-not $validationText.Contains('IIS vdir ''$vd'' physical path')) {
    throw 'The DP failure collector does not capture IIS application physical paths.'
}
$collectorSection = [regex]::Match(
    $validationText,
    '(?s)# IIS is how a DP serves content.+?\$out\[''DpContent\.txt''\]'
)
if (-not $collectorSection.Success -or
    $collectorSection.Value -notmatch [regex]::Escape('NOCERT_SMS_DP_SMSSIG$')) {
    throw 'The DP failure collector omits the NOCERT signature application checked by validation.'
}

Write-Host 'PASS -- Phase 11 tolerates only the verified pre-content SMSSIG state and captures diagnostic evidence.'
