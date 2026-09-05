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
$script:Configured = @()
$script:ConfigureFailures = @()
$script:EnforcementFailures = @()

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
function Set-VmProxyEnforcement { param($VmName); $script:Applied += $VmName; return $VmName -notin $script:EnforcementFailures }
function Set-WindowsClientProxy { param($VmName, $Domain, $ProxyFqdn, $BypassNetwork); $script:Configured += $VmName; return $VmName -notin $script:ConfigureFailures }
function Get-ExistingForDomain { return $null }
function Write-Log { param($Message, [switch]$Warning, [switch]$Verbose, [switch]$Failure) }

$hyperVPath = Join-Path $RootPath 'common\Common.HyperV.ps1'
. (Import-TestFunction $hyperVPath 'Set-VmProxyEnforcementForConfig')
$linuxPath = Join-Path $RootPath 'common\Common.Linux.ps1'
. (Import-TestFunction $linuxPath 'Sync-CmSetupProxyClients')

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
Assert-Equal 'CLIENT1,CAS1,PRI1,SEC1,PASSIVE1,DP1' ($script:Applied -join ',') 'Phase 2 enforces every opted-in Windows VM, including CM infrastructure'
$script:Applied = @()
Assert-Equal $true (Sync-CmSetupProxyClients -deployConfig $config) 'Phase 8 CM proxy reconciliation completes'
Assert-Equal 'CAS1,PRI1,SEC1,PASSIVE1,DP1' ($script:Configured -join ',') 'Phase 8 re-stamps CM infrastructure guest proxy state'
Assert-Equal 'CAS1,PRI1,SEC1,PASSIVE1,DP1' ($script:Applied -join ',') 'Phase 8 keeps CM infrastructure direct egress blocked'
$script:ConfigureFailures = @('PRI1')
Assert-Equal $false (Sync-CmSetupProxyClients -deployConfig $config) 'Phase 8 fails when a CM guest proxy cannot be re-stamped'
$script:ConfigureFailures = @()
$script:EnforcementFailures = @('DP1')
Assert-Equal $false (Sync-CmSetupProxyClients -deployConfig $config) 'Phase 8 fails when a CM direct-egress deny ACL cannot be reconciled'
$script:EnforcementFailures = @()
$configWithoutProxy = [pscustomobject]@{ vmOptions = $config.vmOptions; virtualMachines = @($vms | Where-Object { $_.role -ne 'Proxy' }) }
Assert-Equal $false (Sync-CmSetupProxyClients -deployConfig $configWithoutProxy) 'Phase 8 fails when proxied CM infrastructure has no available Proxy VM'

$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
$startPhase = Import-TestFunction $phasesPath 'Start-Phase'
Assert-Equal $false ($startPhase.ToString() -like '*Suspend-CmSetupProxyEnforcement*') 'Phase 8 does not open direct egress for setupdl'
Assert-Equal $true ($startPhase.ToString() -like '*Sync-CmSetupProxyClients -deployConfig $deployConfig*') 'Phase 8 reconciles CM setup proxy clients before snapshot and jobs'

$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$testVmFunctionality = Import-TestFunction $validationPath 'Test-VmFunctionality'
Assert-Equal $false ($testVmFunctionality.ToString() -like '*proxyEnforcementDeferred*') 'Phase 11 has no deferred CM enforcement path'

$linuxSource = Get-Content (Join-Path $RootPath 'common\Common.Linux.ps1') -Raw
$logonSource = Get-Content (Join-Path $RootPath 'baseimagestaging\filesToInject\staging\Enable-LogMachine.ps1') -Raw
$validationSource = Get-Content $validationPath -Raw
Assert-Equal $true ($linuxSource.Contains('GetBytes([uint32]0x46)') -and $linuxSource.Contains('ToUInt32($old, 4) + 1')) 'runtime proxy writer emits Windows blob version and reads the counter at offset 4'
Assert-Equal $true ($logonSource.Contains('GetBytes([uint32]0x46)') -and $logonSource.Contains('$ctr = $(if') -and $logonSource.Contains('ToUInt32($old,4)+1')) 'logon repair writer preserves the Windows blob layout with executable conditional syntax'
Assert-Equal $true ($validationSource -like '*ToInt32($blob, 12)*GetString($blob, 16, $len)*') 'Phase 11 parses proxy length and value at Windows blob offsets'

$installScript = Get-Content (Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1') -Raw
Assert-Equal $true ($installScript -like '*Write-DscStatus "Pre-Req Downloading failed after 20 tries. see $CMLog" -Failure*') 'setupdl exhaustion reports the actual phase failure before dependent scripts run'
$scriptFunctions = Get-Content (Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1') -Raw
Assert-Equal $true ($scriptFunctions.Contains("-ArgumentList ('/NOUI ' + `$CMRedist)") -and -not $scriptFunctions.Contains("'/ProxyUri")) 'baseline setupdl remains in normal proxy-discovery mode rather than incomplete EasyUpdate mode'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All build-time proxy enforcement scope checks passed.'
