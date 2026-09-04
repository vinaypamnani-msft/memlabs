<#
.SYNOPSIS
    Proves symbolic ConfigMgr versions are normalized in every cmOptions copy.

.DESCRIPTION
    Reproduces the modern GenConfig shape that carries cmOptions at the config
    root, on the top-level site server, and on other site-role VMs. Run under
    both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
$script:LatestBaselineCalls = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $color = if ($passed) { 'Green' } else { 'Red' }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $color
    if (-not $passed) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

function Import-TestFunction {
    param (
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "$Path has $(@($errors).Count) parse error(s)"
    }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) {
        throw "Expected one $Name definition in $Path, found $($definition.Count)"
    }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Get-CMLatestBaselineVersion {
    $script:LatestBaselineCalls++
    return '2509'
}

$sourcePath = Join-Path $RootPath 'common\Common.Config.ps1'
if (-not (Test-Path -LiteralPath $sourcePath)) {
    Write-Host "SETUP FAIL: source not found at $sourcePath" -ForegroundColor Red
    exit 2
}
. (Import-TestFunction -Path $sourcePath -Name 'Resolve-CmVersionAlias')
. (Import-TestFunction -Path $sourcePath -Name 'Get-CmVersionWithHintFallback')
. (Import-TestFunction -Path $sourcePath -Name 'Resolve-VmCmOptions')
. (Import-TestFunction -Path $sourcePath -Name 'Resolve-ConfigCmVersionAliases')

Write-Host "engine : $($PSVersionTable.PSVersion)"
Write-Host "source : $sourcePath"
Write-Host ''

Assert-Equal '2509' (Resolve-CmVersionAlias -Version 'current-branch') 'current-branch resolves to latest baseline'
Assert-Equal '2603' (Resolve-CmVersionAlias -Version '2603') 'explicit version passes through unchanged'
Assert-Equal 1 $script:LatestBaselineCalls 'direct alias resolution reads latest baseline once'
$script:LatestBaselineCalls = 0

$actualOptions = [pscustomobject]@{ Version = '2509' }
$versionHint = [pscustomobject]@{ CMVersion = '2603' }
Assert-Equal '2509' (Get-CmVersionWithHintFallback -CmOptions $actualOptions -DomainDefaults $versionHint -FallbackVersion 'current-branch') 'actual cmOptions wins over domain-default hint'
Assert-Equal '2603' (Get-CmVersionWithHintFallback -DomainDefaults $versionHint -FallbackVersion 'current-branch') 'domain-default hint seeds a missing actual version'
Assert-Equal 'current-branch' (Get-CmVersionWithHintFallback -FallbackVersion 'current-branch') 'fallback is used only when actual and hint are missing'

$config = [pscustomobject]@{
    cmOptions       = [pscustomobject]@{ Version = 'current-branch' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName    = 'PS1SITE'
            role      = 'Primary'
            cmOptions = [pscustomobject]@{ Version = 'current-branch' }
        },
        [pscustomobject]@{
            vmName    = 'PS1DPMP1'
            role      = 'SiteSystem'
            cmOptions = [pscustomobject]@{ Version = 'current-branch' }
        },
        [pscustomobject]@{
            vmName    = 'PS2SITE'
            role      = 'Primary'
            cmOptions = [pscustomobject]@{ Version = '2603' }
        }
    )
}

Resolve-ConfigCmVersionAliases -Config $config

Assert-Equal '2509' $config.cmOptions.Version 'root current-branch alias resolves to latest baseline'
Assert-Equal '2509' $config.virtualMachines[0].cmOptions.Version 'top-level site-server alias resolves to latest baseline'
Assert-Equal '2509' $config.virtualMachines[1].cmOptions.Version 'resolved site-role copy resolves to latest baseline'
Assert-Equal '2603' $config.virtualMachines[2].cmOptions.Version 'explicit target version is preserved'
Assert-Equal 1 $script:LatestBaselineCalls 'latest baseline is resolved once for all copies'

$script:LatestBaselineCalls = 0
$explicitConfig = [pscustomobject]@{
    cmOptions       = [pscustomobject]@{ Version = '2603' }
    virtualMachines = @()
}
Resolve-ConfigCmVersionAliases -Config $explicitConfig
Assert-Equal 0 $script:LatestBaselineCalls 'explicit-only config does not resolve an unused alias'

$emptyConfig = [pscustomobject]@{ virtualMachines = @() }
Resolve-ConfigCmVersionAliases -Config $emptyConfig
Assert-Equal 0 $script:LatestBaselineCalls 'config without cmOptions is a safe no-op'

$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$validationText = Get-Content -LiteralPath $validationPath -Raw
$resolveCall = 'Resolve-CmVersionAlias -Version ([string]$effectiveCmOptions.version)'
$argumentValue = '$tftpProbeText, $effectiveCmVersion `'
Assert-Equal 1 ([regex]::Matches($validationText, [regex]::Escape($resolveCall))).Count 'Phase 11 independently resolves the configured version'
Assert-Equal 1 ([regex]::Matches($validationText, [regex]::Escape($argumentValue))).Count 'Phase 11 passes the concrete version to the guest probe'

$rdcPath = Join-Path $RootPath 'common\Common.RdcMan.ps1'
. (Import-TestFunction -Path $rdcPath -Name 'Get-RDCManCmVersionForVM')
$primaryOptions = [pscustomobject]@{ Version = '2503' }
$displayPrimary = [pscustomobject]@{ vmName = 'PS1SITE'; role = 'Primary'; siteCode = 'PS1'; cmOptions = $primaryOptions }
$displaySiteSystem = [pscustomobject]@{ vmName = 'PS1DPMP1'; role = 'SiteSystem'; siteCode = 'PS1' }
$displayConfig = [pscustomobject]@{ virtualMachines = @($displayPrimary, $displaySiteSystem) }
Assert-Equal 'CM2503' (Get-RDCManCmVersionForVM -VM $displayPrimary -Config $displayConfig -DomainDefaults $versionHint) 'connection label uses actual top-level cmOptions over hint'
Assert-Equal 'CM2503' (Get-RDCManCmVersionForVM -VM $displaySiteSystem -Config $displayConfig -DomainDefaults $versionHint) 'connection label inherits actual hierarchy version over hint'
$missingPrimary = [pscustomobject]@{ vmName = 'PS2SITE'; role = 'Primary'; siteCode = 'PS2' }
$missingConfig = [pscustomobject]@{ virtualMachines = @($missingPrimary) }
Assert-Equal 'CM2603' (Get-RDCManCmVersionForVM -VM $missingPrimary -Config $missingConfig -DomainDefaults $versionHint) 'connection label uses hint only when actual cmOptions is missing'

$addVmText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1') -Raw
$cmMenuText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.GenConfig.CmMenus.ps1') -Raw
$newDomainText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.GenConfig.NewDomain.ps1') -Raw
Assert-Equal 1 ([regex]::Matches($addVmText, [regex]::Escape('Get-CmVersionWithHintFallback -DomainDefaults $ConfigToModify.domainDefaults'))).Count 'new top-level VM consumes version hint only while creating missing cmOptions'
Assert-Equal 1 ([regex]::Matches($cmMenuText, [regex]::Escape('Get-CmVersionWithHintFallback -DomainDefaults $Global:Config.domainDefaults'))).Count 'lazy CM menu initialization consumes hint only when cmOptions is missing'
Assert-Equal 0 ([regex]::Matches($newDomainText, [regex]::Escape('$newConfig.cmOptions.version = $newconfig.domainDefaults.CMVersion'))).Count 'new-domain wizard never overwrites actual cmOptions from a hint'

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAIL: $script:Failures assertion(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host 'PASS: ConfigMgr version aliases normalize in every supported cmOptions location.' -ForegroundColor Green
exit 0