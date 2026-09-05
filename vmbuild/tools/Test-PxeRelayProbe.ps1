<#
.SYNOPSIS
    Focused tests for PXE relay probe client-action and capture safety behavior.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}

$probePath = Join-Path $RootPath 'probe\probe-pxe-relay.ps1'
. (Import-TestFunction $probePath 'Invoke-ProbeClientAction')

$script:RestartClientVM = $true
$script:clientActionTaken = $false
$script:observeAttempt = $false
$script:captureStarted = $false
$script:clientVm = 'OSD1'
$script:RestartCalls = 0
$script:StartCalls = 0
$script:Messages = @()
function Get-VM { return [pscustomobject]@{ State = 'Running' } }
function Restart-VM { $script:RestartCalls++ }
function Start-VM { $script:StartCalls++ }
function Add-ReportLine { param($Text); $script:Messages += $Text }

Write-Host "engine : $($PSVersionTable.PSVersion)"
Invoke-ProbeClientAction
Assert-Equal 1 $script:RestartCalls 'RestartClientVM restarts a running client even when packet capture did not start'
Assert-Equal 0 $script:StartCalls 'running client is not started a second way'
Assert-Equal $true $script:clientActionTaken 'client action is recorded'
Assert-Equal $true $script:observeAttempt 'client restart arms the observation window without packet capture'
Invoke-ProbeClientAction
Assert-Equal 1 $script:RestartCalls 'client action is idempotent within one probe run'

$source = Get-Content -LiteralPath $probePath -Raw
Assert-Equal $true ($source.Contains('Packet capture: using pre-existing filters that include UDP')) 'probe can reuse existing UDP-covering Packet Monitor filters'
Assert-Equal $true ($source.Contains('Client action occurred despite packet-capture setup failure')) 'capture setup failure does not suppress an explicit client restart'
Assert-Equal $true ($source.Contains('if ($filtersAdded)')) 'probe still gates global filter removal on filters it added'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All PXE relay probe checks passed.'
