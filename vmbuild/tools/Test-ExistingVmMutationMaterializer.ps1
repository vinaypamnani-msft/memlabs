<#
.SYNOPSIS
    Verifies declarative existing-VM mutations preserve GenConfig diff semantics.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$materializerPath = Join-Path $RootPath 'tools\New-ExistingVmMutationConfig.ps1'
$runnerPath = Join-Path $RootPath 'tools\Invoke-MainToDevelopExpansionTest.ps1'
$manifestPath = Join-Path $RootPath 'config\tests\mutations\CSTest3-D-MutateExistingSiteSystem.json'
$baselinePath = Join-Path $RootPath 'config\tests\CSTest3-A-CSPS-CSHA.json'

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

function Assert-ThrowsLike {
    param([scriptblock] $Action, [string] $Pattern, [string] $Message)
    $actual = ''
    try { & $Action } catch { $actual = $_.Exception.Message }
    if ($actual -notlike $Pattern) {
        throw "$Message`nExpected: $Pattern`nActual:   $actual"
    }
}

. (Import-TestFunction -Path $materializerPath -Name 'Set-MemLabsExistingVmMutation')

$vm = [pscustomobject]@{
    vmName = 'CT3-CS1RPSUP1'
    role = 'SiteSystem'
    InstallDP = $false
    InstallMP = $false
    memory = '8GB'
    virtualProcs = 4
}
$changes = [pscustomobject]@{
    InstallDP = $true
    InstallMP = $true
    memory = '10GB'
    dynamicMinRam = '2GB'
    virtualProcs = 6
}
$allowed = @('InstallDP', 'InstallMP', 'memory', 'dynamicMinRam', 'virtualProcs')
Set-MemLabsExistingVmMutation -Vm $vm -Changes $changes -AllowedProperties $allowed

Assert-Equal $true ([bool]$vm.InstallDP) 'DP mutation was not applied.'
Assert-Equal $true ([bool]$vm.InstallMP) 'MP mutation was not applied.'
Assert-Equal '10GB' $vm.memory 'Memory mutation was not applied.'
Assert-Equal '2GB' $vm.dynamicMinRam 'Dynamic-memory mutation was not applied.'
Assert-Equal 6 $vm.virtualProcs 'CPU mutation was not applied.'
Assert-Equal $false ([bool]$vm.'InstallDP-Original') 'Original DP state was not retained.'
Assert-Equal $false ([bool]$vm.'InstallMP-Original') 'Original MP state was not retained.'
Assert-Equal '8GB' $vm.'memory-Original' 'Original memory was not retained.'
Assert-Equal 4 $vm.'virtualProcs-Original' 'Original CPU count was not retained.'

Set-MemLabsExistingVmMutation -Vm $vm `
    -Changes ([pscustomobject]@{ memory = '12GB' }) -AllowedProperties $allowed
Assert-Equal '8GB' $vm.'memory-Original' 'A replay overwrote the original GenConfig comparison value.'
Assert-Equal '12GB' $vm.memory 'A replay did not update the requested value.'

Assert-ThrowsLike {
    Set-MemLabsExistingVmMutation -Vm $vm `
        -Changes ([pscustomobject]@{ operatingSystem = 'Server 2025' }) -AllowedProperties $allowed
} "*not supported for existing VMs*" 'Unsupported mutation property did not fail closed.'
Assert-ThrowsLike {
    Set-MemLabsExistingVmMutation -Vm $vm -Changes ([pscustomobject]@{}) -AllowedProperties $allowed
} '*contains no changes*' 'Empty mutation did not fail closed.'

$runnerSource = Get-Content -LiteralPath $runnerPath -Raw
Assert-Equal $true ([bool]($runnerSource -match '(?s)Start-Step -Step \$step.*?Invoke-ExistingVmMutationMaterializer')) `
    'Runner does not checkpoint before invoking the mutation materializer.'
Assert-Equal $true ([bool]($runnerSource -match 'tools\\New-ExistingVmMutationConfig\.ps1')) `
    'Runner is not wired to the pinned mutation materializer.'
Assert-Equal $true ([bool]($runnerSource -match 'generated-mutations')) `
    'Runner does not keep generated mutation configs outside fixture sources.'

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
Assert-Equal 1 ([int]$manifest.existingVmMutationVersion) 'Mutation manifest schema version changed unexpectedly.'
Assert-Equal 'CS1RPSUP1' "$($manifest.virtualMachines[0].vmName)" 'Mutation fixture target changed unexpectedly.'
Assert-Equal 'dynamicMinRam,InstallDP,InstallMP,memory,virtualProcs' `
    (@($manifest.virtualMachines[0].changes.PSObject.Properties.Name | Sort-Object) -join ',') `
    'Mutation fixture no longer covers the intended role and resource changes.'
$baselineTarget = $baseline.virtualMachines | Where-Object vmName -eq $manifest.virtualMachines[0].vmName | Select-Object -First 1
Assert-Equal 'SiteSystem' "$($baselineTarget.role)" 'Mutation target is not created by the CSTest3 main baseline.'
Assert-Equal $false ([bool]$baselineTarget.installDP) 'Main baseline target already has the DP role.'
Assert-Equal $false ([bool]$baselineTarget.installMP) 'Main baseline target already has the MP role.'
Assert-Equal $true ([bool]$baselineTarget.installSUP) 'Main baseline target no longer carries the inherited SUP role.'
Assert-Equal $true ([bool]$baselineTarget.installRP) 'Main baseline target no longer carries the inherited RP role.'

Write-Host 'PASS -- declarative existing-VM mutations preserve supported-property, original-value, checkpoint, and replay semantics.'
