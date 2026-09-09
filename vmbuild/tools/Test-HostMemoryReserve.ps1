# Focused dual-engine tests for the adaptive host-memory reserve.
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-NumericEqual {
    param([double] $Expected, [double] $Actual, [string] $What)
    $passed = [Math]::Abs($Expected - $Actual) -lt 0.001
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Assert-True {
    param([bool] $Actual, [string] $What)
    if (-not $Actual) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Actual) { 'PASS' } else { 'FAIL' }), $What)
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Get-Counter {
    [pscustomobject]@{
        CounterSamples = @([pscustomobject]@{ CookedValue = 20 * 1024 })
    }
}

function Get-CimInstance {
    param([string] $ClassName)
    if ($ClassName -ne 'Win32_ComputerSystem') { throw "Unexpected CIM class: $ClassName" }
    return [pscustomobject]@{ TotalPhysicalMemory = 32GB }
}

function Get-VM { return @() }

$commonPath = Join-Path $RootPath 'Common.ps1'
. (Import-TestFunction -Path $commonPath -Name 'Get-HostMemoryReserveGB')
. (Import-TestFunction -Path $commonPath -Name 'Get-AvailableMemoryGB')
Write-Host "engine : $($PSVersionTable.PSVersion)"

Assert-NumericEqual 2.4 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 16GB) '16GB host reserves 15 percent'
Assert-NumericEqual 4.8 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 32GB) '32GB host reserves 15 percent'
Assert-NumericEqual 8 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 64GB) '64GB host reserve is capped at 8GB'
Assert-NumericEqual 8 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 128GB) '128GB host keeps the existing 8GB cap'
Assert-NumericEqual 15.2 (Get-AvailableMemoryGB) 'deployable memory subtracts the adaptive 4.8GB reserve'

$phaseSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Phases.ps1') -Raw
$configSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Config.ps1') -Raw
$validationSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Validation.ps1') -Raw
Assert-True ($phaseSource.Contains('$hostReserveGB = Get-HostMemoryReserveGB')) 'Phase 1 uses the shared adaptive reserve'
Assert-True (-not $phaseSource.Contains('$hostReserveGB = 8')) 'Phase 1 no longer has a fixed reserve'
Assert-True ($configSource.Contains('[after 15% host reserve, capped at 8GB]')) 'configuration summary describes the adaptive reserve'
Assert-True ($validationSource.Contains('[15% host reserve, capped at 8GB]')) 'validation warning describes the adaptive reserve'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All host-memory reserve checks passed.'