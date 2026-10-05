<#
.SYNOPSIS
    Verifies ConfigMgr DP/MP role completion requires physical readiness.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$functionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
$installerPath = Join-Path $RootPath 'DSC\phases\InstallDPMPClient.ps1'
$workflowPath = Join-Path $RootPath 'DSC\phases\ScriptWorkflow.ps1'

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
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Assert-False {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { throw $Message }
}

. (Import-TestFunction -Path $functionsPath -Name 'Get-CMDistributionPointReadiness')
. (Import-TestFunction -Path $functionsPath -Name 'Get-CMManagementPointReadiness')

$script:DpConfiguration = $null
$script:DpProviderInfo = $null
$script:DpShareReady = $false
$script:MpConfiguration = $null
$script:MpGuestState = $null

function Get-CMDistributionPoint {
    param([string] $SiteSystemServerName, [string] $SiteCode, $ErrorAction)
    return $script:DpConfiguration
}
function Get-CMManagementPoint {
    param([string] $SiteSystemServerName, [string] $SiteCode, $ErrorAction)
    return $script:MpConfiguration
}
function Get-WmiObject {
    param([string] $Namespace, [string] $Class, $ErrorAction)
    if ($Class -eq 'SMS_DistributionPointInfo') { return $script:DpProviderInfo }
}
function Test-Path {
    param([string] $LiteralPath, $PathType, $ErrorAction)
    if ($LiteralPath -like '\\*\SMS_DP$') { return $script:DpShareReady }
    return $false
}
function Invoke-Command {
    param([string] $ComputerName, [scriptblock] $ScriptBlock, $ErrorAction)
    return $script:MpGuestState
}

# This is the exact false-positive shape from CSTest3-C: Add-CMDistributionPoint
# returned a site-control object immediately, but no installed provider row/share.
$script:DpConfiguration = [pscustomobject]@{
    RoleName = 'SMS Distribution Point'
    RoleCount = 0
    NetworkOSPath = ''
    SiteSystemStatus = 1
}
$dpState = Get-CMDistributionPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-False $dpState.Ready 'A site-control-only DP row was accepted as physically ready.'
Assert-True $dpState.ConfigurationVisible 'The false-positive fixture no longer represents a visible configuration row.'
Assert-False $dpState.ProviderVisible 'The false-positive fixture unexpectedly has provider readiness.'
Assert-False $dpState.ShareReady 'The false-positive fixture unexpectedly has SMS_DP$.'

$script:DpProviderInfo = [pscustomobject]@{ ServerName = 'CT3-PS1DPMPSUP1.CSTEST3.COM' }
$dpState = Get-CMDistributionPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-False $dpState.Ready 'Provider visibility without the physical DP share was accepted.'
$script:DpShareReady = $true
$dpState = Get-CMDistributionPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-True $dpState.Ready 'A configured, provider-visible DP with SMS_DP$ was not accepted.'

$script:MpConfiguration = [pscustomobject]@{ NetworkOSPath = '\\CT3-PS1DPMPSUP1.cstest3.com' }
$script:MpGuestState = [pscustomobject]@{ RegistryReady = $true; IisReady = $false; W3SvcRunning = $true }
$mpState = Get-CMManagementPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-False $mpState.Ready 'An MP configuration row without the SMS_MP IIS application was accepted.'
$script:MpGuestState.IisReady = $true
$mpState = Get-CMManagementPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-True $mpState.Ready 'A configured MP with registry, SMS_MP IIS, and W3SVC readiness was not accepted.'

$functionsText = Get-Content -LiteralPath $functionsPath -Raw
$installerText = Get-Content -LiteralPath $installerPath -Raw
$workflowText = Get-Content -LiteralPath $workflowPath -Raw
Assert-True ($functionsText -match "(?s)function Install-DP.+?DP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15") `
    'Install-DP no longer waits for bounded physical readiness.'
Assert-True ($functionsText -match "(?s)function Install-MP.+?MP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15") `
    'Install-MP no longer waits for bounded physical readiness.'
Assert-True (([regex]::Matches($functionsText, 'Restart-CMRoleProvisioning -RoleName').Count) -ge 2) `
    'DP/MP readiness no longer retries Site Component Manager.'
Assert-True ($installerText -match 'Get-CMDistributionPointReadiness.+?\.Ready') `
    'The InstallDPMPClient quick path still trusts a DP configuration row.'
Assert-True ($installerText -match 'Get-CMManagementPointReadiness.+?\.Ready') `
    'The InstallDPMPClient quick path still trusts an MP configuration row.'
Assert-True ($installerText -match '\$mpInstallResult\s*=\s*@\(Install-MP') `
    'InstallDPMPClient does not consume the MP physical-readiness result.'
Assert-True (([regex]::Matches($workflowText, 'Stopping before boundary, content, and perfloading work').Count) -eq 2) `
    'Both site-server workflow branches must stop after incomplete DP/MP installation.'

Write-Host 'PASS -- DP/MP completion requires provider plus physical readiness, with bounded recovery and fail-fast workflow gating.'
