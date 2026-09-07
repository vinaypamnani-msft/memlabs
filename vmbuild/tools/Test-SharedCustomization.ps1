<#
.SYNOPSIS
    Focused contract tests for the portable MemLabs customization runner.
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

$runner = Join-Path $RootPath 'baseimagestaging\filesToInject\staging\Invoke-MemLabsCustomization.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('MemLabsCustomization-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null

try {
    $successScript = @'
param([switch]$Register, [switch]$Apply)
[pscustomobject]@{
    Success = $true
    Message = if ($Register) { 'registered' } elseif ($Apply) { 'applied' } else { 'plain' }
    Errors = @()
    Blocked = if ($Register) { @('test blocked setting') } else { @() }
}
'@
    foreach ($name in @('Optimize-Defender.ps1', 'Set-MemLabsMachineSettings.ps1', 'Set-MemLabsUserShell.ps1')) {
        [IO.File]::WriteAllText((Join-Path $fixture $name), $successScript)
    }

    $result = & $runner -Name DefenderTuning, WindowsMachine, WindowsUserRegistration, WindowsUser -RootPath $fixture
    Assert-Equal $true $result.Success 'all shared customizations can run from an explicit payload root'
    Assert-Equal 'DefenderTuning,WindowsMachine,WindowsUserRegistration,WindowsUser' ($result.Results.Name -join ',') 'requested customization order is preserved'
    Assert-Equal 'registered' $result.Results[2].Message 'registration profile forwards the Register switch'
    Assert-Equal 'applied' $result.Results[3].Message 'user profile forwards the Apply switch'
    Assert-Equal 'test blocked setting' $result.Blocked[0] 'blocked-setting evidence reaches the aggregate result'

    [IO.File]::WriteAllText((Join-Path $fixture 'Set-MemLabsMachineSettings.ps1'), "[pscustomobject]@{ Success = `$false; Message = 'expected failure'; Errors = @('detail') }")
    $result = & $runner -Name WindowsMachine, WindowsUserRegistration -RootPath $fixture -ContinueOnError
    Assert-Equal $false $result.Success 'a structured payload failure fails the aggregate result'
    Assert-Equal 2 $result.Results.Count 'ContinueOnError executes later customizations'
    Assert-Equal 'detail' $result.Errors[0] 'payload error details reach the aggregate result'

    [IO.File]::WriteAllText((Join-Path $fixture 'Set-MemLabsMachineSettings.ps1'), "'unstructured output'")
    $result = & $runner -Name WindowsMachine -RootPath $fixture
    Assert-Equal $false $result.Success 'unstructured payload output cannot report success'
    Assert-Equal $true ($result.Errors[0] -like '*returned no structured result*') 'malformed-result reason is retained'

    Remove-Item -LiteralPath (Join-Path $fixture 'Optimize-Defender.ps1') -Force
    $result = & $runner -Name DefenderTuning -RootPath $fixture
    Assert-Equal $false $result.Success 'missing payload cannot report success'
    Assert-Equal $true ($result.Errors[0] -like '*Required customization script is missing*') 'missing-payload reason is retained'

    $fixesToPerform = @()
    . (Join-Path $RootPath 'Fixes\Fix-DefenderTuning.ps1')
    . (Join-Path $RootPath 'Fixes\Fix-WindowsCustomization.ps1')
    $defenderFix = @($fixesToPerform | Where-Object FixName -eq 'Fix-DefenderTuning')[0]
    $windowsFix = @($fixesToPerform | Where-Object FixName -eq 'Fix-WindowsCustomization')[0]
    Assert-Equal $false ($defenderFix.NotAppliesToRoles -contains 'OSDClient') 'Phase 10 Defender tuning includes OSD clients'
    Assert-Equal $true ($defenderFix.NotAppliesToRoles -contains 'AADClient') 'Phase 10 Defender tuning still excludes AAD clients'
    Assert-Equal 0 @($windowsFix.AppliesToRoles).Count 'Phase 10 shared Windows settings apply to all managed Windows roles'
    Assert-Equal 'Invoke-MemLabsCustomization.ps1,Set-MemLabsMachineSettings.ps1,Set-MemLabsUserShell.ps1' ($windowsFix.InjectFiles -join ',') 'Phase 10 injects the complete shared Windows payload'
    Assert-Equal $true ($windowsFix.ScriptBlock.ToString().Contains('WindowsUserRegistration, WindowsUser')) 'Phase 10 registers future users and applies the current real user profile'

    $baseImageCustomization = [IO.File]::ReadAllText((Join-Path $RootPath 'baseimagestaging\filesToInject\staging\Customize-WindowsSettings.ps1'))
    Assert-Equal $true ($baseImageCustomization.Contains('if (-not $customizationResult.Success)')) 'base-image customization rejects a failed shared aggregate'
    Assert-Equal $true ($baseImageCustomization.Contains('Required shared customization runner is missing')) 'base-image customization rejects a missing shared runner'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All shared customization contract checks passed.'