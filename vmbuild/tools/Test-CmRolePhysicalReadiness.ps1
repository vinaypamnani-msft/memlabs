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
$rolesPath = Join-Path $RootPath 'DSC\phases\InstallRoles.ps1'
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
. (Import-TestFunction -Path $functionsPath -Name 'Get-CMSoftwareUpdatePointReadiness')
. (Import-TestFunction -Path $functionsPath -Name 'Get-CMReportingPointReadiness')
. (Import-TestFunction -Path $functionsPath -Name 'Wait-CMRoleRegistered')

$script:DpConfiguration = $null
$script:DpProviderInfo = $null
$script:DpShareReady = $false
$script:MpConfiguration = $null
$script:SupConfiguration = $null
$script:RpConfiguration = $null
$script:GuestState = $null
$script:WaitSequence = @()
$script:WaitProbeCount = 0

function Write-DscStatus { param([string] $Message, [switch] $Warning, [switch] $Failure) }
function Start-Sleep { param([int] $Seconds) }

function Get-CMDistributionPoint {
    param([string] $SiteSystemServerName, [string] $SiteCode, $ErrorAction)
    return $script:DpConfiguration
}
function Get-CMManagementPoint {
    param([string] $SiteSystemServerName, [string] $SiteCode, $ErrorAction)
    return $script:MpConfiguration
}
function Get-CMSoftwareUpdatePoint {
    param([string] $SiteSystemServerName, [string] $SiteCode, $ErrorAction)
    return $script:SupConfiguration
}
function Get-CMReportingServicePoint {
    param([string] $SiteSystemServerName, $ErrorAction)
    return $script:RpConfiguration
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
    param([string] $ComputerName, [scriptblock] $ScriptBlock, [object[]] $ArgumentList, $ErrorAction)
    return $script:GuestState
}

$script:WaitSequence = @($true, $false, $true, $true)
$stableResult = Wait-CMRoleRegistered -RoleName 'Synthetic role' -ServerFQDN 'role.contoso.test' `
    -TimeoutSeconds 10 -PollSeconds 1 -ConsecutiveSuccesses 2 -Probe {
        $value = $script:WaitSequence[$script:WaitProbeCount]
        $script:WaitProbeCount++
        if ($value) { return [pscustomobject]@{ Ready = $true } }
        return $null
    }
Assert-True ([bool]$stableResult) 'Stable-readiness wait did not return the successful observation.'
Assert-True ($script:WaitProbeCount -eq 4) 'Stable-readiness wait accepted a non-consecutive success.'

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
$script:GuestState = [pscustomobject]@{ RegistryReady = $true; IisReady = $false; W3SvcRunning = $true }
$mpState = Get-CMManagementPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-False $mpState.Ready 'An MP configuration row without the SMS_MP IIS application was accepted.'
$script:GuestState.IisReady = $true
$mpState = Get-CMManagementPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-True $mpState.Ready 'A configured MP with registry, SMS_MP IIS, and W3SVC readiness was not accepted.'

$script:SupConfiguration = [pscustomobject]@{ NetworkOSPath = '\\CT3-PS1DPMPSUP1.cstest3.com' }
$script:GuestState = [pscustomobject]@{
    ServiceReady = $true; PoolReady = $true; PortReady = $true; ApiReady = $false
}
$supState = Get-CMSoftwareUpdatePointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-False $supState.Ready 'A SUP configuration row without a working local WSUS API was accepted.'
$script:GuestState.ApiReady = $true
$supState = Get-CMSoftwareUpdatePointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-True $supState.Ready 'A configured SUP with service, pool, listener, and API readiness was not accepted.'

$script:RpConfiguration = [pscustomobject]@{ NetworkOSPath = '\\CT3-PS1DPMPSUP1.cstest3.com' }
$script:GuestState = [pscustomobject]@{ ServiceReady = $true; EndpointReady = $false }
$rpState = Get-CMReportingPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-False $rpState.Ready 'A Reporting Point configuration row without a functional ReportServer endpoint was accepted.'
$script:GuestState.EndpointReady = $true
$rpState = Get-CMReportingPointReadiness -ServerFQDN 'CT3-PS1DPMPSUP1.cstest3.com' -SiteCode 'PS1'
Assert-True $rpState.Ready 'A configured Reporting Point with service and endpoint readiness was not accepted.'

$functionsText = Get-Content -LiteralPath $functionsPath -Raw
$installerText = Get-Content -LiteralPath $installerPath -Raw
$rolesText = Get-Content -LiteralPath $rolesPath -Raw
$workflowText = Get-Content -LiteralPath $workflowPath -Raw
Assert-True ($functionsText -match "(?s)function Install-DP.+?DP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-DP no longer waits for bounded physical readiness.'
Assert-True ($functionsText -match "(?s)function Install-MP.+?MP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-MP no longer waits for bounded physical readiness.'
Assert-True ($functionsText -match "(?s)function Install-SUP.+?SUP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-SUP no longer waits for bounded physical readiness.'
Assert-True ($functionsText -match "(?s)function Install-SRP.+?Reporting Point physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-SRP no longer waits for bounded physical readiness.'
Assert-True (([regex]::Matches($functionsText, 'Restart-CMRoleProvisioning -RoleName').Count) -ge 4) `
    'Asynchronous role readiness no longer retries Site Component Manager.'
Assert-True ($functionsText -match 'function Write-CMRoleProvisioningDiagnostics') `
    'Physical-readiness failures no longer capture bounded producer/target diagnostics.'
Assert-True (([regex]::Matches($functionsText, 'Write-CMRoleProvisioningDiagnostics -RoleName').Count) -ge 5) `
    'Retry and terminal physical-readiness failures are not both diagnosed.'
Assert-True ($installerText -match 'Get-CMDistributionPointReadiness.+?\.Ready') `
    'The InstallDPMPClient quick path still trusts a DP configuration row.'
Assert-True ($installerText -match 'Get-CMManagementPointReadiness.+?\.Ready') `
    'The InstallDPMPClient quick path still trusts an MP configuration row.'
Assert-True ($installerText -match '\$mpInstallResult\s*=\s*@\(Install-MP') `
    'InstallDPMPClient does not consume the MP physical-readiness result.'
Assert-True ($rolesText -match 'Get-CMSoftwareUpdatePointReadiness.+?\.Ready') `
    'InstallRoles quick paths still trust SUP configuration rows.'
Assert-True ($rolesText -match 'Get-CMReportingPointReadiness.+?\.Ready') `
    'InstallRoles quick paths still trust Reporting Point configuration rows.'
Assert-True ($rolesText -match '\$supResult\s*=\s*@\(Install-SUP') `
    'InstallRoles does not consume the SUP physical-readiness result.'
Assert-True (([regex]::Matches($workflowText, 'Stopping before boundary, content, and perfloading work').Count) -eq 2) `
    'Both site-server workflow branches must stop after incomplete DP/MP installation.'
Assert-True ($workflowText -match 'Additional SMS Provider installation did not converge.+?-Failure') `
    'Remote SMS Provider failure no longer blocks workflow completion.'

Write-Host 'PASS -- asynchronous ConfigMgr roles require stable physical readiness, bounded recovery, and fail-fast workflow gating.'
