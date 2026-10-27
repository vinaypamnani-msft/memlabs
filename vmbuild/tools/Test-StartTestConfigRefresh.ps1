<#
.SYNOPSIS
    Verifies Start-Test refreshes its staged configuration from the root fixture.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$startTestPath = Join-Path $RootPath 'Start-Test.ps1'

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) { throw "Expected one $Name definition, found $($functions.Count)." }
    [scriptblock]::Create($functions[0].Extent.Text)
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

. (Import-TestFunction -Path $startTestPath -Name 'Write-TestConfigSnapshot')

function Set-FeatureOverrides {}
function Resolve-TestConfigNetworks {}

$cmVersion = '2509'
$DoNotInstallCM = $false
$dynamicMemory = $false
$serverVersion = $null
$testRoot = Join-Path $env:TEMP "memlabs-start-test-config-refresh-$PID"
$sourcePath = Join-Path $testRoot 'fixture.json'
$stagedPath = Join-Path $testRoot 'staged\fixture.json'

function Write-Fixture {
    param([string] $Memory)
    [IO.File]::WriteAllText($sourcePath, (@{
            cmOptions = @{
                version = '2309'
                install = $true
            }
            vmOptions = @{
                domainName = 'refresh.test'
            }
            virtualMachines = @(
                @{
                    vmName = 'SQL1'
                    role = 'SQLAO'
                    memory = $Memory
                }
            )
        } | ConvertTo-Json -Depth 5))
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot -Force

    Write-Fixture -Memory '7GB'
    $null = Write-TestConfigSnapshot -SourcePath $sourcePath `
        -DestinationPath $stagedPath -ConfigName 'fixture.json'
    if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) {
        throw 'Initial snapshot did not create its destination directory and file.'
    }
    $staged = Get-Content -LiteralPath $stagedPath -Raw | ConvertFrom-Json
    Assert-Equal '7GB' $staged.virtualMachines[0].memory 'Initial snapshot did not use the root fixture.'
    Assert-Equal '2509' $staged.cmOptions.version 'Initial snapshot lost the runtime CM version override.'

    Write-Fixture -Memory '12GB'
    $null = Write-TestConfigSnapshot -SourcePath $sourcePath `
        -DestinationPath $stagedPath -ConfigName 'fixture.json'
    $staged = Get-Content -LiteralPath $stagedPath -Raw | ConvertFrom-Json
    Assert-Equal '12GB' $staged.virtualMachines[0].memory 'Refreshed snapshot reused stale root-fixture values.'
    Assert-Equal '2509' $staged.cmOptions.version 'Refreshed snapshot lost the runtime CM version override.'

    $startTestSource = Get-Content -LiteralPath $startTestPath -Raw
    if ($startTestSource -notmatch
        '(?s)Invoke-TestGitPull -Context "before retrying.+?Write-TestConfigSnapshot.+?Invoke-NewLab -ConfigFile \$ModifiedtestFile') {
        throw 'Retry flow does not refresh the staged configuration after pulling current source.'
    }

    Write-Host 'PASS -- Start-Test refreshes staged configuration values and reapplies runtime overrides.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
