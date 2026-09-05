<#
.SYNOPSIS
    Focused dual-engine tests for the framework-only OSD bootstrap application.
#>
[CmdletBinding()]
param ([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Application = $null
$script:DeploymentTypes = @()
$script:Collection = $null
$script:Rules = @()
$script:Deployments = @()
$script:DistributionRequests = @()
$script:NewDeploymentArgs = $null
$script:Log = @()

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)
    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}

function Write-DscStatus { param($Message, [switch]$Failure, [switch]$Warning); $script:Log += "$Message" }
function Get-CMApplication { [CmdletBinding()] param($Name); return $script:Application }
function New-CMApplication {
    [CmdletBinding()]
    param($Name, $Description, $Publisher, $SoftwareVersion)
    $script:Application = [pscustomobject]@{ Name = $Name; SoftwareVersion = "$SoftwareVersion" }
    return $script:Application
}
function Add-CMScriptDeploymentType {
    [CmdletBinding()]
    param($Application, $DeploymentTypeName, $InstallCommand, $ContentLocation, $ScriptLanguage, $ScriptText, $InstallationBehaviorType, $LogonRequirementType)
    $script:DeploymentTypes = @([pscustomobject]@{
            LocalizedDisplayName     = $DeploymentTypeName
            InstallCommand           = $InstallCommand
            ContentLocation          = $ContentLocation
            ScriptLanguage           = $ScriptLanguage
            ScriptText               = $ScriptText
            InstallationBehaviorType = $InstallationBehaviorType
            LogonRequirementType     = $LogonRequirementType
        })
}
function Get-CMDeploymentType { [CmdletBinding()] param($ApplicationName); return $script:DeploymentTypes }
function Start-CMContentDistribution {
    [CmdletBinding()]
    param($ApplicationName, $DistributionPointGroupName)
    $script:DistributionRequests += "$ApplicationName->$DistributionPointGroupName"
}
function Get-CMDeviceCollection { [CmdletBinding()] param($Name); return $script:Collection }
function New-CMDeviceCollection {
    [CmdletBinding()]
    param($Name, $LimitingCollectionName, $Comment)
    $script:Collection = [pscustomobject]@{ Name = $Name; CollectionID = 'PS100123' }
    return $script:Collection
}
function Get-CMDeviceCollectionQueryMembershipRule { [CmdletBinding()] param($CollectionId); return $script:Rules }
function Remove-CMDeviceCollectionQueryMembershipRule {
    [CmdletBinding()]
    param($CollectionId, $RuleName, [switch]$Force)
    $script:Rules = @($script:Rules | Where-Object { $_.RuleName -ne $RuleName })
}
function Add-CMDeviceCollectionQueryMembershipRule {
    [CmdletBinding()]
    param($CollectionId, $QueryExpression, $RuleName)
    $script:Rules += [pscustomobject]@{ RuleName = $RuleName; QueryExpression = $QueryExpression }
}
function Set-CMCollection { [CmdletBinding()] param($CollectionId, $RefreshType) }
function Invoke-CMCollectionUpdate { [CmdletBinding()] param($CollectionId) }
function Get-CMApplicationDeployment { [CmdletBinding()] param($Application, $Collection); return $script:Deployments }
function New-CMApplicationDeployment {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$Application, $Collection, $DeployAction, $DeployPurpose, $UserNotification)
    process {
        $script:NewDeploymentArgs = "$DeployAction,$DeployPurpose,$UserNotification"
        $script:Deployments = @([pscustomobject]@{ Application = $Application.Name; Collection = $Collection.Name })
    }
}
function Get-CMTSStepInstallApplication {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName)
    process {
        $result = @($InputObject.Steps | Where-Object { $_.Type -eq 'InstallApplication' })
        if ($StepName) { $result = @($result | Where-Object { $_.Name -eq $StepName }) }
        return $result
    }
}
function Remove-CMTSStepInstallApplication {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName, [switch]$Force)
    process { $InputObject.Steps = @($InputObject.Steps | Where-Object { $_.Name -ne $StepName }) }
}
function New-CMTSStepInstallApplication {
    [CmdletBinding()]
    param($Name, $Application)
    return [pscustomobject]@{ Name = $Name; Type = 'InstallApplication'; Application = $Application.Name }
}
function Add-CMTaskSequenceStep {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, $Step)
    process { $InputObject.Steps = @($InputObject.Steps) + @($Step) }
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction $perfloadingPath 'Sync-MemLabsOsdBootstrapFramework')
Write-Host "engine : $($PSVersionTable.PSVersion)"

$sourceRoot = Join-Path ([IO.Path]::GetTempPath()) ('MemLabsOsdBootstrap-' + [guid]::NewGuid().ToString('N'))
$clients = @(
    [pscustomobject]@{ vmName = 'OSD1' }
    [pscustomobject]@{ vmName = 'OSD2' }
)
$taskSequences = @(
    [pscustomobject]@{ Name = 'MEMLABS-w11-Install OS image'; Steps = @([pscustomobject]@{ Name = 'Setup Windows'; Type = 'Other' }) }
    [pscustomobject]@{ Name = 'MEMLABS-w10-Install OS image'; Steps = @() }
    [pscustomobject]@{ Name = 'MEMLABS-w11-In-Place Upgrade Task Sequence'; Steps = @() }
)

try {
    $result = Sync-MemLabsOsdBootstrapFramework -SourceRoot $sourceRoot `
        -SourceUnc '\\PS1SITE\OSD\MemLabsOsdBootstrap' -OsdClients $clients `
        -TaskSequences $taskSequences -DistributionPointGroupName 'OSD DPS' -StatusTag '[test]'
    Assert-Equal $true $result 'fresh framework reconcile succeeds'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Install.ps1')) 'versioned install payload is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Manifest.json')) 'framework manifest is staged'
    Assert-Equal 'MEMLABS-OSD Bootstrap' $script:Application.Name 'bootstrap application is created'
    Assert-Equal 'InstallForSystem' $script:DeploymentTypes[0].InstallationBehaviorType 'deployment type installs as system'
    Assert-Equal 'WhetherOrNotUserLoggedOn' $script:DeploymentTypes[0].LogonRequirementType 'deployment type does not require a user session'
    Assert-Equal 'MEMLABS-OSD Bootstrap->OSD DPS' ($script:DistributionRequests -join ',') 'bootstrap content targets the OSD DP group'
    Assert-Equal 'Install,Required,HideAll' $script:NewDeploymentArgs 'ongoing policy is required and silent'
    Assert-Equal $true ($script:Rules[0].QueryExpression -like "*Client = 1*Name in ('OSD1','OSD2')*") 'policy collection is config-name keyed and client gated'
    Assert-Equal 1 @($taskSequences[0].Steps | Where-Object Name -eq 'MEMLABS install OSD Bootstrap').Count 'Windows 11 install TS gets one bootstrap step'
    Assert-Equal 'MEMLABS install OSD Bootstrap' $taskSequences[0].Steps[-1].Name 'bootstrap step is appended after generated setup actions'
    Assert-Equal 1 @($taskSequences[1].Steps | Where-Object Name -eq 'MEMLABS install OSD Bootstrap').Count 'Windows 10 install TS gets one bootstrap step'
    Assert-Equal 0 @($taskSequences[2].Steps | Where-Object Name -eq 'MEMLABS install OSD Bootstrap').Count 'in-place upgrade TS is not changed'

    $result = Sync-MemLabsOsdBootstrapFramework -SourceRoot $sourceRoot `
        -SourceUnc '\\PS1SITE\OSD\MemLabsOsdBootstrap' -OsdClients $clients `
        -TaskSequences $taskSequences -DistributionPointGroupName 'OSD DPS' -StatusTag '[test]'
    Assert-Equal $true $result 'rerun framework reconcile succeeds'
    Assert-Equal 1 @($taskSequences[0].Steps | Where-Object Name -eq 'MEMLABS install OSD Bootstrap').Count 'rerun does not duplicate task-sequence step'
    Assert-Equal 1 $script:Deployments.Count 'rerun does not duplicate required deployment'
    Assert-Equal 1 $script:Rules.Count 'rerun does not duplicate collection rule'

    $script:Collection = $null
    $script:Rules = @()
    $script:Deployments = @()
    $noDpTaskSequence = [pscustomobject]@{ Name = 'MEMLABS-w11-Install OS image'; Steps = @() }
    $result = Sync-MemLabsOsdBootstrapFramework -SourceRoot $sourceRoot `
        -SourceUnc '\\PS1SITE\OSD\MemLabsOsdBootstrap' -OsdClients $clients `
        -TaskSequences @($noDpTaskSequence) -DistributionPointGroupName '' -StatusTag '[test]'
    Assert-Equal $true $result 'missing OSD DP is handled without authoring broken references'
    Assert-Equal $true ($null -eq $script:Collection) 'missing OSD DP does not create policy collection'
    Assert-Equal 0 $noDpTaskSequence.Steps.Count 'missing OSD DP does not add bootstrap task-sequence step'
}
finally {
    Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$source = Get-Content $perfloadingPath -Raw
Assert-Equal $true ($source.Contains('Sync-MemLabsOsdBootstrapFramework')) 'perfloading contains bootstrap reconciler'
Assert-Equal $true ($source.Contains('-DeployPurpose Required -UserNotification HideAll')) 'required policy path is present'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD bootstrap framework checks passed.'
