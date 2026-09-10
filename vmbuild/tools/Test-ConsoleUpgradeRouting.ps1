<#
.SYNOPSIS
    Guards console-upgrade routing, failure semantics, and Phase 11 validation.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$failures = 0

function Assert-ConsoleUpgrade {
    param([bool] $Condition, [string] $Description)
    if ($Condition) { Write-Host "PASS  $Description" }
    else { Write-Host "FAIL  $Description"; $script:failures++ }
}

$fixPath = Join-Path $RootPath 'Fixes\Fix-Upgrade-Console.ps1'
$upgradePath = Join-Path $RootPath 'DSC\phases\Upgrade-Console.ps1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$paths = @($fixPath, $upgradePath, $validationPath)

foreach ($path in $paths) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    $realErrors = @($errors | Where-Object { $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    Assert-ConsoleUpgrade ($realErrors.Count -eq 0) "$path parses"
}

$fixText = Get-Content -LiteralPath $fixPath -Raw
$upgradeText = Get-Content -LiteralPath $upgradePath -Raw
$validationText = Get-Content -LiteralPath $validationPath -Raw

Assert-ConsoleUpgrade ($fixText -match 'NeededOnFreshDeploy\s*=\s*\$true' -and $fixText -match 'AppliesToExisting\s*=\s*\$true') 'console fix is reachable from Phase 10 and fresh-deploy maintenance'
Assert-ConsoleUpgrade ($fixText -match 'returned no result' -and $fixText -match "Properties\['Success'\]") 'maintenance wrapper requires an explicit result'
Assert-ConsoleUpgrade ($upgradeText -match 'Get-ConsoleVersionState' -and $upgradeText -match 'ConsoleRelease\s*=') 'upgrader compares the installed console release'
Assert-ConsoleUpgrade ($upgradeText -match 'RequiredExtensionSiteVersion' -and $upgradeText -match 'RequiredExtensionVersion') 'upgrader compares the site-required extension version'
Assert-ConsoleUpgrade (@([regex]::Matches($upgradeText, 'Install-Console -ConsoleUIExe')).Count -eq 2) 'upgrader makes at most two install attempts'
Assert-ConsoleUpgrade ($upgradeText -match 'Console upgrade did not converge' -and $upgradeText -match 'throw "Upgrade-Console: CM install directory' -and $upgradeText -match 'throw "Upgrade-Console: console setup') 'missing prerequisites and retry exhaustion are terminating failures'
Assert-ConsoleUpgrade ($validationText -match 'ConfigMgr admin console is release' -and $validationText -match 'ConfigMgr admin console extension is' -and $validationText -match '\$results\.Passed = \$false') 'Phase 11 fails stale console release and extension versions'

if ($failures -gt 0) { throw "$failures console-upgrade regression assertion(s) failed" }
Write-Host 'PASS  console-upgrade routing and validation regression suite'