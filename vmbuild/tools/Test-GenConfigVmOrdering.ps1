# Focused dual-engine tests for existing-VM ordering in the GenConfig deployment menu.
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Assertions = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $What)

    $script:Assertions++
    $passed = "$Expected" -ceq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
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

function get-VMOptionsSummary { return '' }
function Get-PKIOptionsSummary { return '' }
function Get-VMString {
    param($config, $virtualMachine, [switch] $colors)
    return [string]$virtualMachine.vmName
}

$global:Common = [pscustomobject]@{
    Colors = [pscustomobject]@{
        GenConfigHeader = ''
        GenConfigNonDefault = ''
        GenConfigHelpHighlight = ''
        GenConfigNewVM = ''
        GenConfigNewVMNumber = ''
        GenConfigNonDefaultNumber = ''
        GenConfigDangerous = ''
        GenConfigDeploy = ''
        GenConfigDeployNumber = ''
    }
}
$global:Config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{}
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PS1-PENDING-ZETA'; Hidden = $false }
        [pscustomobject]@{ vmName = 'PS1-PENDING-ALPHA'; Hidden = $false }
    )
}
$global:existingMachines = @(
    [pscustomobject]@{ vmName = 'PS1-ZETA' }
    [pscustomobject]@{ vmName = 'ps1-alpha' }
    [pscustomobject]@{ vmName = 'PS1-Mike' }
)
Set-Variable -Name InternalUseOnly -Value ([switch]$false)
Set-Variable -Name enableDebug -Value $false

$genConfigPath = Join-Path $RootPath 'genconfig.ps1'
. (Import-TestFunction -Path $genConfigPath -Name 'Build-MainMenuOptions')

Write-Host "engine : $($PSVersionTable.PSVersion)"
$result = Build-MainMenuOptions
$vmKeys = @($result.Options.Keys | Where-Object { $_ -match '^-D\d+$' })
$existingKeys = @($vmKeys | Select-Object -First $global:existingMachines.Count)
$pendingKeys = @($vmKeys | Select-Object -Skip $global:existingMachines.Count)
$displayedNames = @($existingKeys | ForEach-Object { $result.Options[$_] })
$pendingNames = @($pendingKeys | ForEach-Object { $result.Options[$_] })
$mappedNames = @(1..5 | ForEach-Object { $result.VMNameToNumberMap[$_.ToString()] })

Assert-Equal 3 $existingKeys.Count 'three existing VM rows are measured'
Assert-Equal 2 $pendingKeys.Count 'two pending VM rows are measured'
Assert-Equal '-D1|-D2|-D3|-D4|-D5' ($vmKeys -join '|') 'VM rows retain consecutive numeric options across both sections'
Assert-Equal 'ps1-alpha|PS1-Mike|PS1-ZETA' ($displayedNames -join '|') 'existing VM rows are ordered alphabetically by VM name'
Assert-Equal 'PS1-PENDING-ZETA|PS1-PENDING-ALPHA' ($pendingNames -join '|') 'pending VM rows retain configuration order'
Assert-Equal 'ps1-alpha|PS1-Mike|PS1-ZETA|PS1-PENDING-ZETA|PS1-PENDING-ALPHA' ($mappedNames -join '|') 'numeric selections map to the displayed VM names across both sections'
Assert-Equal 'PS1-ZETA|ps1-alpha|PS1-Mike' (($global:existingMachines.vmName) -join '|') 'menu ordering does not mutate the source list'
Assert-Equal 'PS1-PENDING-ZETA|PS1-PENDING-ALPHA' (($global:Config.virtualMachines.vmName) -join '|') 'menu rendering does not mutate pending VM configuration order'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host "All GenConfig VM ordering checks passed ($script:Assertions assertions)."