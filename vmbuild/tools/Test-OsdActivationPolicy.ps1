<#
.SYNOPSIS
    Focused dual-engine tests for shared post-PXE activation policy.
#>
[CmdletBinding()]
param ([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Applications = @{}
$script:DeploymentTypes = @{}
$script:Collection = [pscustomobject]@{ Name = 'MEMLABS-OSD Clients'; CollectionID = 'PS100123' }
$script:Deployments = @()
$script:DistributionRequests = @()
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
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}
function Write-DscStatus { param($Message, [switch]$Failure, [switch]$Warning); $script:Log += "$Message" }
function Get-CMApplication { [CmdletBinding()] param($Name); return $script:Applications[$Name] }
function New-CMApplication {
    [CmdletBinding()]
    param($Name, $Description, $Publisher, $SoftwareVersion)
    $app = [pscustomobject]@{ Name = $Name; SoftwareVersion = "$SoftwareVersion" }
    $script:Applications[$Name] = $app
    return $app
}
function Add-CMScriptDeploymentType {
    [CmdletBinding()]
    param($Application, $DeploymentTypeName, $InstallCommand, $ContentLocation, $ScriptLanguage, $ScriptText, $InstallationBehaviorType, $LogonRequirementType)
    $script:DeploymentTypes[$Application.Name] = @([pscustomobject]@{
            LocalizedDisplayName = $DeploymentTypeName
            InstallCommand = $InstallCommand
            ContentLocation = $ContentLocation
            ScriptText = $ScriptText
            InstallationBehaviorType = $InstallationBehaviorType
            LogonRequirementType = $LogonRequirementType
        })
}
function Get-CMDeploymentType { [CmdletBinding()] param($ApplicationName); return $script:DeploymentTypes[$ApplicationName] }
function Start-CMContentDistribution { [CmdletBinding()] param($ApplicationName, $DistributionPointGroupName); $script:DistributionRequests += "$ApplicationName->$DistributionPointGroupName" }
function Get-CMDeviceCollection { [CmdletBinding()] param($Name); return $script:Collection }
function Get-CMApplicationDeployment { [CmdletBinding()] param($Application, $Collection); return @($script:Deployments | Where-Object Application -eq $Application.Name) }
function New-CMApplicationDeployment {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$Application, $Collection, $DeployAction, $DeployPurpose, $UserNotification)
    process { $script:Deployments += [pscustomobject]@{ Application = $Application.Name; Collection = $Collection.Name; Purpose = $DeployPurpose } }
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
$sharedPath = Join-Path $RootPath 'DSC\phases\WindowsActivation.Script.ps1'
. $sharedPath
. (Import-TestFunction $perfloadingPath 'Sync-MemLabsOsdActivationPolicy')
Write-Host "engine : $($PSVersionTable.PSVersion)"

$sourceRoot = Join-Path ([IO.Path]::GetTempPath()) ('MemLabsOsdActivation-' + [guid]::NewGuid().ToString('N'))
$clients = @([pscustomobject]@{ vmName = 'OSD1' })
try {
    Assert-Equal $true (Sync-MemLabsOsdActivationPolicy -SourceRoot $sourceRoot -SourceUnc '\\PS1SITE\OSD\MemLabsOsdActivation' -OsdClients $clients -DistributionPointGroupName 'OSD DPS' -EnableAzureActivation $false -ActivationScript $MemLabsWindowsActivationScript -StatusTag '[test]') 'non-Azure host skips activation policy'
    Assert-Equal 0 $script:Applications.Count 'non-Azure host authors no activation application'

    Assert-Equal $true (Sync-MemLabsOsdActivationPolicy -SourceRoot $sourceRoot -SourceUnc '\\PS1SITE\OSD\MemLabsOsdActivation' -OsdClients $clients -DistributionPointGroupName 'OSD DPS' -EnableAzureActivation $true -ActivationScript $MemLabsWindowsActivationScript -StatusTag '[test]') 'Azure activation policy reconcile succeeds'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Install.ps1')) 'shared activation installer is staged'
    Assert-Equal '1' $script:Applications['MEMLABS-OSD Activation'].SoftwareVersion 'activation application is versioned'
    Assert-Equal 'MEMLABS-OSD Activation v1' $script:DeploymentTypes['MEMLABS-OSD Activation'][0].LocalizedDisplayName 'activation deployment type is created'
    Assert-Equal 'InstallForSystem' $script:DeploymentTypes['MEMLABS-OSD Activation'][0].InstallationBehaviorType 'activation runs as system'
    Assert-Equal 'MEMLABS-OSD Activation->OSD DPS' ($script:DistributionRequests -join ',') 'activation content targets OSD DPs'
    Assert-Equal 'Required' $script:Deployments[0].Purpose 'activation is required post-PXE policy'

    $installText = Get-Content (Join-Path $sourceRoot 'Install.ps1') -Raw
    Assert-Equal $true ($installText.Contains('Activation attempt $attempt/${maxAttempts}')) 'published installer contains shared retry implementation'
    Assert-Equal $true ($installText.Contains("`$ErrorActionPreference = 'Continue'")) 'activation preserves Phase 10 native-command error semantics'
    $fixText = Get-Content (Join-Path $RootPath 'Fixes\Fix_ActivateWindows.ps1') -Raw
    Assert-Equal $true ($fixText.Contains('$Fix_ActivateWindows = $MemLabsWindowsActivationScript')) 'Phase 10 binds the same shared scriptblock'
}
finally {
    Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD activation policy checks passed.'
