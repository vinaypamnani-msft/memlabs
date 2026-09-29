<#
.SYNOPSIS
    Verifies optional Secondary DP coverage exits and implicit role validation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$coveragePath = Join-Path $root 'DSC\phases\InstallBoundaryGroups.ps1'
$validationPath = Join-Path $root 'common\Common.Validation.Functional.ps1'

foreach ($path in @($coveragePath, $validationPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$path has $($errors.Count) parse error(s): $($errors -join '; ')" }
}

$coverageText = Get-Content -LiteralPath $coveragePath -Raw
$validationText = Get-Content -LiteralPath $validationPath -Raw

if ($coverageText -notmatch '\$coverageExitReason\s*=\s*''OptionalGrace''') {
    throw 'Optional grace does not record a distinct exit reason.'
}
if ($coverageText -match "moving on after the.*grace[\s\S]{0,300}-Warning") {
    throw 'The intentional optional-grace exit still emits an unconditional warning.'
}
if ($coverageText -notmatch '(?s)\$physicalContent\s*=\s*&\s*\$dpHasPackageContent.+?\$versionMatches.+?\$physicalContent\s+-eq\s+\$true\s+-and\s+\$versionMatches.+?\$optionalStatusLag\.Add') {
    throw 'Optional summarizer lag is not gated on physical PkgLib content at the matching source version.'
}
if ($coverageText -notmatch 'optional grace ended, but final verification could not prove current physical content plus matching DP source version') {
    throw 'Optional content that is absent or unmeasurable no longer captures diagnostics.'
}
if ($coverageText -notmatch "'optional-grace-complete'") {
    throw 'The timeline does not distinguish optional grace from a wall-clock deadline.'
}

$secondaryCase = [regex]::Match($validationText, "(?s)'Secondary'\s*\{(?:(?!\n\s{8}'\w+'\s*\{).)*?\n\s{8}\}")
if (-not $secondaryCase.Success -or
    $secondaryCase.Value -notmatch 'Test-SecondaryFunctionality' -or
    $secondaryCase.Value -notmatch '\$siteSystemRolesOk\s*=\s*Test-SiteSystemFunctionality' -or
    $secondaryCase.Value -notmatch '\$testsPassed\s*=\s*\$testsPassed\s+-and\s+\$siteSystemRolesOk') {
    throw 'Secondary Phase 11 validation does not include the shared site-system role checks.'
}
if ($validationText -notmatch '\$isSecondary\s*=\s*.*role.*Secondary' -or
    $validationText -notmatch 'if \(\$CurrentItem\.installMP -or \$isSecondary\)' -or
    $validationText -notmatch 'if \(\$CurrentItem\.installDP -or \$isSecondary\)') {
    throw 'Test-SiteSystemFunctionality does not treat Secondary MP/DP roles as implicit.'
}
if ($validationText -notmatch '(?s)\$dpOsdPaths\s*=\s*@\(\$DeployConfig\.osdPxePaths.+?distributionPointVM\s*-eq\s*\$CurrentItem\.vmName') {
    throw 'DP OSD-service detection no longer resolves through the serialized deployConfig.osdPxePaths model.'
}
$configText = Get-Content -LiteralPath (Join-Path $root 'common\Common.Config.ps1') -Raw
if ($configText -notmatch '(?s)\$distributionPoints\s*=\s*@\(\$allVMs\s*\|\s*Where-Object\s*\{\s*\$_\.installDP\s*-eq\s*\$true\s*-or\s*\$_\.enablePullDP\s*-eq\s*\$true\s*\}\)') {
    throw 'Get-OsdPxePaths no longer restricts DP targets to installDP/enablePullDP-flagged VMs; an implicit Secondary DP could be selected for PXE.'
}
if ($validationText -notmatch "(?s)'this is an implicit Secondary DP and MemLabs does not enable PXE on Secondary sites'.+?skipping all PXE checks") {
    throw 'Secondary implicit DP validation incorrectly assumes MemLabs enabled PXE on that role.'
}

Write-Host 'PASS -- optional Secondary DP lag is informational only with physical content, and implicit MP/DP roles are validated.'
