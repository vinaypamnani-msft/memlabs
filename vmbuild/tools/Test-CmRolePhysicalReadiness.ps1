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
$phase3Path = Join-Path $RootPath 'DSC\phases\Phase3.ps1'
$genConfigPath = Join-Path $RootPath 'common\Common.GenConfig.ps1'
$siteInstallerPath = Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1'

function Get-TestFunctionText {
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
    return $functions[0].Extent.Text
}
function Import-TestFunction {
    param([string] $Path, [string] $Name)
    [scriptblock]::Create((Get-TestFunctionText -Path $Path -Name $Name))
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
. (Import-TestFunction -Path $functionsPath -Name 'Get-CMRoleRequiredWindowsFeatures')
. (Import-TestFunction -Path $genConfigPath -Name 'Test-ConfigMgrRemoteRoleRequested')

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
function Invoke-Command {
    param([string] $ComputerName, [scriptblock] $ScriptBlock, [object[]] $ArgumentList, $ErrorAction)
    return $script:GuestState
}
function Invoke-CMRoleTargetCommand {
    param(
        [string] $ComputerName,
        [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList,
        [int] $OpenTimeoutMs,
        [int] $OperationTimeoutMs
    )
    if ("$ScriptBlock" -match 'SMS_DP') { return $script:DpShareReady }
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
$phase3Text = Get-Content -LiteralPath $phase3Path -Raw
$genConfigText = Get-Content -LiteralPath $genConfigPath -Raw
$siteInstallerText = Get-Content -LiteralPath $siteInstallerPath -Raw
$targetCommandText = Get-TestFunctionText -Path $functionsPath -Name 'Invoke-CMRoleTargetCommand'
$prerequisiteStateText = Get-TestFunctionText -Path $functionsPath -Name 'Get-CMRoleTargetPrerequisiteState'
$confirmPrerequisitesText = Get-TestFunctionText -Path $functionsPath -Name 'Confirm-CMRoleTargetPrerequisites'
$installDpText = Get-TestFunctionText -Path $functionsPath -Name 'Install-DP'
$installPullDpText = Get-TestFunctionText -Path $functionsPath -Name 'Install-PullDP'
$installMpText = Get-TestFunctionText -Path $functionsPath -Name 'Install-MP'
$installSupText = Get-TestFunctionText -Path $functionsPath -Name 'Install-SUP'
$installSrpText = Get-TestFunctionText -Path $functionsPath -Name 'Install-SRP'
$wsusPoolText = Get-TestFunctionText -Path $functionsPath -Name 'Confirm-CMWsusPoolHardening'
$dpFeatures = @(Get-CMRoleRequiredWindowsFeatures -RoleName DP)
$mpFeatures = @(Get-CMRoleRequiredWindowsFeatures -RoleName MP)
foreach ($feature in @('Web-Server', 'Web-Windows-Auth', 'Web-WMI', 'Rdc', 'Web-Mgmt-Service')) {
    Assert-True ($feature -in $dpFeatures) "DP prerequisite contract dropped Windows feature '$feature'."
}
foreach ($feature in @('BITS', 'BITS-IIS-Ext', 'Web-Asp-Net45', 'Web-Net-Ext45')) {
    Assert-True ($feature -in $mpFeatures) "MP prerequisite contract dropped Windows feature '$feature'."
}
Assert-True ($phase3Text -match '(?s)installDP.+?Distribution point') `
    'Phase 3 no longer projects installDP into the Distribution point prerequisite feature set.'
Assert-True ($phase3Text -match '(?s)enablePullDP.+?Distribution point') `
    'Phase 3 no longer projects pull-DP intent into the Distribution point prerequisite feature set.'
Assert-True ($phase3Text -match '(?s)installMP.+?Management point') `
    'Phase 3 no longer projects installMP into the Management point prerequisite feature set.'
Assert-True ($phase3Text -match '(?s)role -in "CAS", "Primary", "Secondary".+?Distribution point.+?Management point') `
    'Phase 3 no longer pre-stages prerequisites for automatic site-server DP/MP placement.'
foreach ($roleProperty in @('installDP', 'enablePullDP', 'installMP', 'installSUP', 'installRP', 'installSMSProv')) {
    $fixture = [pscustomobject]@{ $roleProperty = $true }
    Assert-True (Test-ConfigMgrRemoteRoleRequested -VM $fixture) `
        "Remote ConfigMgr role prerequisite projection dropped '$roleProperty'."
}
Assert-False (Test-ConfigMgrRemoteRoleRequested -VM ([pscustomobject]@{ role = 'SiteSystem' })) `
    'A bare site system was incorrectly classified as requiring remote role installation access.'
Assert-True ($genConfigText -match '(?s)"SiteSystem".+?Test-ConfigMgrRemoteRoleRequested.+?Get-SiteServerForSiteCode.+?-LocalAdminAccounts') `
    'Remote role targets no longer receive the owning site server computer account as a local administrator.'
Assert-True ([bool]$prerequisiteStateText) `
    'Role installation no longer has a shared producer-prerequisite probe.'
Assert-True ($targetCommandText -match '(?s)OpenTimeout.+?OperationTimeout.+?New-PSSessionOption') `
    'Role-target probes no longer have explicit WSMan open/operation bounds.'
foreach ($evidence in @('ADMIN`$Write', 'ManagementScope', 'RebootPending', 'ExpectedSiteServerAccount',
        'ExpectedComputerName', 'IdentityReady', 'MissingFeatures')) {
    Assert-True ($prerequisiteStateText.Contains($evidence)) "Producer prerequisite diagnostics dropped '$evidence'."
}
Assert-True ($prerequisiteStateText -match 'InstallFeatureStatus\*\.txt') `
    'Producer prerequisites no longer consume the authoritative Phase 3 feature receipt.'
Assert-False ($prerequisiteStateText -match 'Get-WindowsFeature') `
    'Phase 8 producer prerequisites regressed to an unbounded ServerManager/CBS feature scan.'
Assert-True ($confirmPrerequisitesText -match '(?s)after 2 bounded attempts.+?Role configuration was not requested') `
    'Producer prerequisites no longer retry boundedly and fail before requesting invalid role state.'
Assert-True ($installDpText -match '(?s)Confirm-CMRoleTargetPrerequisites.+?RoleName ''DP''.+?Add-CMDistributionPoint') `
    'Install-DP does not gate role creation on producer prerequisites.'
Assert-True ($installPullDpText -match '(?s)Confirm-CMRoleTargetPrerequisites.+?RoleName ''DP''.+?Add-CMDistributionPoint') `
    'Install-PullDP does not gate role creation on producer prerequisites.'
Assert-True ($installMpText -match '(?s)Confirm-CMRoleTargetPrerequisites.+?RoleName ''MP''.+?Add-CMManagementPoint') `
    'Install-MP does not gate role creation on producer prerequisites.'
Assert-True ($installSupText -match '(?s)Confirm-CMRoleTargetPrerequisites.+?RoleName ''SUP''.+?Add-CMSoftwareUpdatePoint') `
    'Install-SUP does not gate role creation on producer prerequisites.'
Assert-True ($installSrpText -match '(?s)Confirm-CMRoleTargetPrerequisites.+?RoleName ''RP''.+?Add-CMReportingServicePoint') `
    'Install-SRP does not gate role creation on producer prerequisites.'
Assert-True ($installDpText -match "(?s)DP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-DP no longer waits for bounded physical readiness.'
Assert-True ($installPullDpText -match "(?s)Pull DP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-PullDP no longer waits for bounded physical readiness.'
Assert-True ($installMpText -match "(?s)MP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-MP no longer waits for bounded physical readiness.'
Assert-True ($installSupText -match "(?s)SUP physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-SUP no longer waits for bounded physical readiness.'
Assert-True ($installSupText -match 'Confirm-CMWsusPoolHardening') `
    'Install-SUP no longer reapplies WsusPool hardening after role installation.'
foreach ($setting in @('recycling.periodicRestart.privateMemory', 'recycling.periodicRestart.requests',
        'recycling.periodicRestart.time', 'queueLength', 'processModel.idleTimeout',
        'startMode', 'failure.rapidFailProtection')) {
    Assert-True ($wsusPoolText.Contains($setting)) "WsusPool hardening dropped '$setting'."
}
Assert-True ($rolesText -match '(?s)allRolesInstalled.+?Confirm-CMWsusPoolHardening.+?All roles \(RP \+ SUP\) already installed') `
    'InstallRoles quick path no longer verifies WsusPool hardening.'
Assert-True ($installSrpText -match "(?s)Reporting Point physical readiness.+?-TimeoutSeconds 300 -PollSeconds 15 -ConsecutiveSuccesses 2") `
    'Install-SRP no longer waits for bounded physical readiness.'
Assert-True (([regex]::Matches($functionsText, 'Restart-CMRoleProvisioning -RoleName').Count) -ge 4) `
    'Asynchronous role readiness no longer retries Site Component Manager.'
Assert-True ($functionsText -match 'function Write-CMRoleProvisioningDiagnostics') `
    'Physical-readiness failures no longer capture bounded producer/target diagnostics.'
foreach ($targetEvidence in @('SMS_BOOTSTRAP.log', 'Windows\Logs\DISM\dism.log', 'Windows\Logs\CBS\CBS.log',
        'FeatureReceipts', 'PendingReboot')) {
    Assert-True ($functionsText.Contains($targetEvidence)) "Role-target diagnostics dropped '$targetEvidence'."
}
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
Assert-True ($rolesText -match '(?s)\$accountDomain.+?NetbiosDomainName.+?\$domainUserName') `
    'SUP computer-account grants no longer use the NetBIOS domain name.'
Assert-True (([regex]::Matches($workflowText, 'Stopping before boundary, content, and perfloading work').Count) -eq 2) `
    'Both site-server workflow branches must stop after incomplete DP/MP installation.'
Assert-True ($workflowText -match 'Additional SMS Provider installation did not converge.+?-Failure') `
    'Remote SMS Provider failure no longer blocks workflow completion.'
foreach ($serviceName in @('SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER')) {
    Assert-True ($siteInstallerText -match "(?s)coreServiceName.+?$serviceName.+?did not reach Running.+?-Failure") `
        "Existing-site workflow no longer fails closed when $serviceName is stopped."
}

Write-Host 'PASS -- asynchronous ConfigMgr roles require stable physical readiness, bounded recovery, and fail-fast workflow gating.'
