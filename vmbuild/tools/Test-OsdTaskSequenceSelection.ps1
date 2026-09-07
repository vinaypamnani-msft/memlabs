<#
.SYNOPSIS
    Focused tests for per-OSD-client required task-sequence targeting.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Collections = @{}
$script:Rules = @{}
$script:Deployments = @()
$script:Imports = @()
$script:Removals = @()
$script:Log = @()

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}
function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}
function Write-DscStatus { param($Message, [switch]$Failure); $script:Log += "$Message" }
function Get-CMDeviceCollection { param($Name); return $script:Collections[$Name] }
function New-CMDeviceCollection {
    param($Name, $LimitingCollectionName, $Comment)
    $collection = [pscustomobject]@{ Name = $Name; CollectionID = "COL$($script:Collections.Count + 1)" }
    $script:Collections[$Name] = $collection
    $script:Rules[$collection.CollectionID] = @()
    return $collection
}
function Get-CMDeviceCollectionDirectMembershipRule { param($CollectionId); return @($script:Rules[$CollectionId]) }
function Import-CMComputerInformation {
    [CmdletBinding()]
    param($ComputerName, $MacAddress, $CollectionId, [switch]$MergeIfExist)
    $script:Imports += [pscustomobject]@{ Name = $ComputerName; Mac = $MacAddress; CollectionID = $CollectionId }
    $script:Rules[$CollectionId] = @($script:Rules[$CollectionId]) + [pscustomobject]@{ RuleName = $ComputerName; ResourceName = $ComputerName }
}
function Remove-CMDeviceCollectionDirectMembershipRule {
    [CmdletBinding()]
    param($CollectionId, $ResourceName, [switch]$Force)
    $script:Removals += "$CollectionId/$ResourceName"
    $script:Rules[$CollectionId] = @($script:Rules[$CollectionId] | Where-Object RuleName -ne $ResourceName)
}
function Invoke-CMCollectionUpdate { param($CollectionId) }
function Get-CMDeployment { [CmdletBinding()] param($CollectionName); return @($script:Deployments | Where-Object CollectionName -eq $CollectionName) }
function New-CMTaskSequenceDeployment {
    [CmdletBinding()]
    param($TaskSequencePackageId, $CollectionId, $DeployPurpose, $MakeAvailableTo, $RerunBehavior, $AvailableDateTime, $ScheduleEvent)
    $collectionName = @($script:Collections.GetEnumerator() | Where-Object { $_.Value.CollectionID -eq $CollectionId })[0].Key
    $script:Deployments += [pscustomobject]@{ PackageID = $TaskSequencePackageId; CollectionName = $collectionName; Purpose = "$DeployPurpose"; Rerun = "$RerunBehavior"; ScheduleEvent = "$ScheduleEvent" }
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction $perfloadingPath 'Sync-MemLabsOsdTaskSequenceDeployments')
$taskSequences = @(
    [pscustomobject]@{ Name = 'MEMLABS-w11-Install OS image'; PackageID = 'PS100011' }
    [pscustomobject]@{ Name = 'MEMLABS-w10-Install OS image'; PackageID = 'PS100012' }
)
$clients = @(
    [pscustomobject]@{ vmName = 'OSD1'; osdMacAddress = '00:15:5D:00:00:01'; osdTaskSequence = 'MEMLABS-w11-Install OS image' }
    [pscustomobject]@{ vmName = 'OSD2'; osdMacAddress = '00:15:5D:00:00:02'; osdTaskSequence = $null }
    [pscustomobject]@{ vmName = 'OSD3'; osdMacAddress = '00:15:5D:00:00:03'; osdTaskSequence = 'MEMLABS-w10-Install OS image' }
)

Assert-Equal $true (Sync-MemLabsOsdTaskSequenceDeployments -OsdClients $clients -TaskSequences $taskSequences -StatusTag '[test]') 'mixed per-client selections reconcile'
Assert-Equal 2 $script:Collections.Count 'one managed collection is created per selected install sequence'
Assert-Equal 'OSD1,OSD3' (($script:Imports.Name | Sort-Object) -join ',') 'selected clients are prestaged by name and MAC'
Assert-Equal 2 $script:Deployments.Count 'one required deployment is created per selected sequence'
Assert-Equal 'Required,Required' (($script:Deployments.Purpose | Sort-Object) -join ',') 'managed deployments are required'
Assert-Equal 'RerunIfFailedPreviousAttempt,RerunIfFailedPreviousAttempt' (($script:Deployments.Rerun | Sort-Object) -join ',') 'managed deployments retry failures without reimaging successful clients'
Assert-Equal 'AsSoonAsPossible,AsSoonAsPossible' (($script:Deployments.ScheduleEvent | Sort-Object) -join ',') 'required deployments are scheduled immediately without an expired deadline'

$importsBefore = $script:Imports.Count
$deploymentsBefore = $script:Deployments.Count
Assert-Equal $true (Sync-MemLabsOsdTaskSequenceDeployments -OsdClients $clients -TaskSequences $taskSequences -StatusTag '[test]') 'unchanged rerun reconciles'
Assert-Equal $importsBefore $script:Imports.Count 'unchanged rerun does not import duplicate membership'
Assert-Equal $deploymentsBefore $script:Deployments.Count 'unchanged rerun does not duplicate deployments'

$clients[0].osdTaskSequence = $null
Assert-Equal $true (Sync-MemLabsOsdTaskSequenceDeployments -OsdClients $clients -TaskSequences $taskSequences -StatusTag '[test]') 'returning a client to PXE prompt reconciles'
Assert-Equal $true ([bool]($script:Removals -like '*/OSD1')) 'prompt mode removes stale required membership'

$invalid = [pscustomobject]@{ vmName = 'BAD'; osdMacAddress = '00:15:5D:00:00:04'; osdTaskSequence = 'MEMLABS-Custom TS Example' }
Assert-Equal $false (Sync-MemLabsOsdTaskSequenceDeployments -OsdClients @($invalid) -TaskSequences $taskSequences -StatusTag '[test]') 'non-install task sequence is rejected'
$importsBeforeMissing = $script:Imports.Count
$missing = [pscustomobject]@{ vmName = 'MISSING'; osdMacAddress = '00:15:5D:00:00:05'; osdTaskSequence = 'MEMLABS-w11-Install OS image' }
Assert-Equal $false (Sync-MemLabsOsdTaskSequenceDeployments -OsdClients @($missing) -TaskSequences @() -StatusTag '[test]') 'missing selected task sequence fails reconciliation'
Assert-Equal $importsBeforeMissing $script:Imports.Count 'missing task sequence fails before prestaging side effects'

$addVmSource = Get-Content (Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1') -Raw
$menuSource = Get-Content (Join-Path $RootPath 'common\Common.GenConfig.VMList.ps1') -Raw
$configSource = Get-Content (Join-Path $RootPath 'common\Common.Config.ps1') -Raw
$validationSource = Get-Content (Join-Path $RootPath 'common\Common.Validation.ps1') -Raw
Assert-Equal $true ($addVmSource.Contains("-Name 'osdTaskSequence' -Value `$null")) 'new OSD clients expose prompt-mode task-sequence option'
Assert-Equal $true ($menuSource.Contains('"MEMLABS-w11-Install OS image"')) 'GenConfig offers the Windows 11 install sequence'
Assert-Equal $true ($configSource.Contains("PSObject.Properties['osdTaskSequence']")) 'normalization adds the option only through the OSD lifecycle'
Assert-Equal $true ($validationSource.Contains('selects unsupported task sequence')) 'final validation rejects unsupported sequences'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD task-sequence selection checks passed.'