<#
.SYNOPSIS
    Focused tests for preserving installed OSD clients during phase routing.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}

$phasePath = Join-Path $RootPath 'common\Common.Phases.ps1'
. (Import-TestFunction $phasePath 'Test-OsdClientCreatedThisRun')
. (Import-TestFunction $phasePath 'Get-OsdClientPhaseAction')

$global:OsdClientsCreatedThisRun = @('OSD2')
Assert-Equal $true (Test-OsdClientCreatedThisRun -VMName 'OSD2') 'Phase 1 OSD placeholder is owned by this run'
Assert-Equal $false (Test-OsdClientCreatedThisRun -VMName 'OSD1') 'pre-existing OSD client is not owned by this run'
Assert-Equal 'Continue' (Get-OsdClientPhaseAction -Phase 1 -VMName 'OSD2') 'Phase 1 retains normal OSD creation handling'
foreach ($phase in 2..8) {
    Assert-Equal 'StopFreshPlaceholder' (Get-OsdClientPhaseAction -Phase $phase -VMName 'OSD2') "Phase $phase keeps a fresh blank OSD target off while PXE policy is authored"
    Assert-Equal 'Skip' (Get-OsdClientPhaseAction -Phase $phase -VMName 'OSD1') "Phase $phase preserves a pre-existing OSD client"
}
foreach ($phase in 9..11) {
    Assert-Equal 'Skip' (Get-OsdClientPhaseAction -Phase $phase -VMName 'OSD2') "Phase $phase preserves a current-run OSD client after policy authoring"
    Assert-Equal 'Skip' (Get-OsdClientPhaseAction -Phase $phase -VMName 'OSD1') "Phase $phase preserves a pre-existing OSD client"
}
$global:OsdClientsCreatedThisRun = @()
Assert-Equal $false (Test-OsdClientCreatedThisRun -VMName 'OSD2') 'rerun without Phase 1 owns no OSD clients'
$global:OsdClientsCreatedThisRun = $null
Assert-Equal $false (Test-OsdClientCreatedThisRun -VMName 'OSD2') 'missing run state cannot authorize a power-off'

$phaseSource = Get-Content $phasePath -Raw
Assert-Equal $true ($phaseSource.Contains("`$_.vmName -notin `$existingVMs.vmName")) 'Phase 1 records only OSD clients absent before creation'
Assert-Equal $true ($phaseSource.Contains('$osdPhaseAction = Get-OsdClientPhaseAction -Phase $Phase -VMName $currentItem.vmName')) 'phase routing uses the tested OSD action policy'
Assert-Equal $false ($phaseSource.Contains('stop-vm2 -Name $currentItem.vmName -TurnOff')) 'unconditional legacy OSD stop is removed'
Assert-Equal $false ($phaseSource.Contains('installed OSDClient; running portable maintenance customizations')) 'Phase routing never opts an OSD client into maintenance'
$phase10Route = [regex]::Match($phaseSource, 'elseif \(\$Phase -eq 10\).*?if \(\$currentItem\.Role -in @\("OSDClient", "AADClient"\)\)', 'Singleline').Success
Assert-Equal $true $phase10Route 'Phase 10 dispatcher excludes every OSD client'
$phase11Route = [regex]::Match($phaseSource, 'if \(\$Phase -eq 11\).*?if \(\$currentItem\.Role -in @\("OSDClient", "AADClient"\)\)', 'Singleline').Success
Assert-Equal $true $phase11Route 'Phase 11 retains its existing OSD client exclusion'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD client power-state checks passed.'