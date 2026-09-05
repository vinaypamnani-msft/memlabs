<#
.SYNOPSIS
    Focused dual-engine tests for build-time proxy enforcement scope.
#>
[CmdletBinding()]
param ([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Applied = @()
$script:Cleared = @()
$global:MemLabsProxyAclWeightMin = 5000
$global:MemLabsProxyAclWeightMax = 5099

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)
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

function Test-VmUsesProxy { param($Vm, $DeployConfig); return [bool]$Vm.useProxy }
function Test-VmIsLinux { param($Vm); return $Vm.osFamily -eq 'Linux' }
function Set-VmProxyEnforcement { param($VmName); $script:Applied += $VmName; return $true }
function Clear-VmProxyEnforcement { param($VmName); $script:Cleared += $VmName }
function Get-VMNetworkAdapterExtendedAcl { [CmdletBinding()] param($VmName); return @() }
function Write-Log { param($Message, [switch]$Warning, [switch]$Verbose) }

$hyperVPath = Join-Path $RootPath 'common\Common.HyperV.ps1'
. (Import-TestFunction $hyperVPath 'Suspend-CmSetupProxyEnforcement')
. (Import-TestFunction $hyperVPath 'Set-VmProxyEnforcementForConfig')

$vms = @(
    [pscustomobject]@{ vmName = 'PROXY1'; role = 'Proxy'; useProxy = $false; osFamily = 'Linux' }
    [pscustomobject]@{ vmName = 'CLIENT1'; role = 'DomainMember'; useProxy = $true; osFamily = 'Windows' }
    [pscustomobject]@{ vmName = 'LINUX1'; role = 'LinuxClient'; useProxy = $true; osFamily = 'Linux' }
    [pscustomobject]@{ vmName = 'CAS1'; role = 'CAS'; useProxy = $true; osFamily = 'Windows' }
    [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; useProxy = $true; osFamily = 'Windows' }
    [pscustomobject]@{ vmName = 'SEC1'; role = 'Secondary'; useProxy = $true; osFamily = 'Windows' }
    [pscustomobject]@{ vmName = 'PASSIVE1'; role = 'PassiveSite'; useProxy = $true; osFamily = 'Windows' }
    [pscustomobject]@{ vmName = 'DP1'; role = 'SiteSystem'; useProxy = $true; osFamily = 'Windows' }
)
$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = $vms
}

Write-Host "engine : $($PSVersionTable.PSVersion)"
Assert-Equal $true (Set-VmProxyEnforcementForConfig -deployConfig $config) 'build-time enforcement completes'
Assert-Equal 'CLIENT1' ($script:Applied -join ',') 'Phase 2 enforces clients but defers Linux and CM infrastructure'
Assert-Equal 'CAS1,PRI1,SEC1,PASSIVE1,DP1' ($script:Cleared -join ',') 'Phase 2 removes stale deny ACLs from CM infrastructure'

$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
$startPhase = Import-TestFunction $phasesPath 'Start-Phase'
Assert-Equal $true ($startPhase.ToString() -like '*Suspend-CmSetupProxyEnforcement -deployConfig $deployConfig*') 'Phase 8 clears restored stale ACLs before its snapshot and jobs'

$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$testVmFunctionality = Import-TestFunction $validationPath 'Test-VmFunctionality'
Assert-Equal $true ($testVmFunctionality.ToString() -like '*Set-VmProxyEnforcement -VmName $VMName*') 'Phase 11 applies deferred CM infrastructure enforcement before testing direct egress'

$installScript = Get-Content (Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1') -Raw
Assert-Equal $true ($installScript -like '*Write-DscStatus "Pre-Req Downloading failed after 20 tries. see $CMLog" -Failure*') 'setupdl exhaustion reports the actual phase failure before dependent scripts run'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All build-time proxy enforcement scope checks passed.'