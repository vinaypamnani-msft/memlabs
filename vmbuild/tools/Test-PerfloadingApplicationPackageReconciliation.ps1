<#
.SYNOPSIS
    Executes the perfloading application/package reconciliation loop with ConfigMgr cmdlet doubles.

.DESCRIPTION
    Covers fresh and partial reruns plus duplicate, provider-read, and distribution
    failures. Run under PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
$errors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($perfloadingPath, [ref]$tokens, [ref]$errors)
$parseErrors = @($errors | Where-Object { $null -ne $_ })
if ($parseErrors.Count -ne 0) { throw "$perfloadingPath has $($parseErrors.Count) parse error(s)" }
$appLoops = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.PipelineAst] -and
            $node.Extent.Text -match '^\s*\$apps\s*\|\s*ForEach-Object\s*\{'
        }, $true))
if ($appLoops.Count -ne 1) { throw "Expected one application/package loop, found $($appLoops.Count)" }
$appLoop = [scriptblock]::Create($appLoops[0].Extent.Text)
$officeLoops = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -eq 'channel' -and
            $node.Extent.Text -match 'Office application.*deployment complete'
        }, $true))
if ($officeLoops.Count -ne 1) { throw "Expected one Office channel loop, found $($officeLoops.Count)" }
$officeLoop = [scriptblock]::Create($officeLoops[0].Extent.Text)
$officeRecoveryLoops = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -eq 'ch' -and
            $node.Extent.Text -match 'Recovered missing Office deployment'
        }, $true))
if ($officeRecoveryLoops.Count -ne 1) { throw "Expected one Office recovery loop, found $($officeRecoveryLoops.Count)" }
$officeRecoveryLoop = [scriptblock]::Create($officeRecoveryLoops[0].Extent.Text)

$apps = @([pscustomobject]@{
        Name = '7-Zip 64-bit'
        AppMsi = '7z.msi'
        Description = 'Archive utility'
        Publisher = '7-Zip'
        SoftwareVersion = '1.0'
    })
$ThisMachineName = 'PS1SITE'
$DPGroupName = 'All MEMLABS DPs'
$LegacyDPGroupName = 'ALL DPS'
$legacyDPGroupExists = $true
$SiteCode = 'PS1'
$Tag = '[test]'
$officeSourceRoot = 'C:\OfficeSource'
$officeShareName = 'OfficeSource$'
$officeAppName = 'MEMLABS-Microsoft365Apps'

function Reset-Scenario {
    param ([string] $Name)

    $script:Scenario = $Name
    $script:Mutations = New-Object System.Collections.Generic.List[string]
    $script:Statuses = New-Object System.Collections.Generic.List[object]
    $script:AppExists = $Name -notin @('Fresh', 'CreateUnreadable', 'OfficeDistributionFailure')
    $script:DeploymentTypeExists = $Name -notin @('Fresh', 'Partial')
    $script:AppDeploymentExists = $Name -in @('DuplicatePackage', 'PackageDeploymentQueryFailure')
    $script:PackageExists = $Name -notin @('Fresh', 'CreateUnreadable', 'DuplicateApp', 'AppDeploymentQueryFailure', 'DistributionFailure')
    $script:ProgramExists = $Name -in @('DuplicatePackage', 'PackageDeploymentQueryFailure')
    $script:PackageDeploymentExists = $Name -eq 'DuplicatePackage'
}

function Write-DscStatus {
    param ([Parameter(Position = 0)][string] $Message, [switch] $Failure)

    [void]$script:Statuses.Add([pscustomobject]@{ Message = $Message; Failure = [bool]$Failure })
}
function Test-Path { param($LiteralPath); return $true }
function Get-Item { param($LiteralPath); return [pscustomobject]@{ LinkType = 'HardLink' } }
function Get-FileHash { param($LiteralPath, $Algorithm); return [pscustomobject]@{ Hash = 'SAME' } }
function Get-CMApplication {
    param($Name, [switch]$Fast, $ErrorAction)

    if ($script:Scenario -eq 'DuplicateApp') { return @([pscustomobject]@{ CI_ID = 1 }, [pscustomobject]@{ CI_ID = 2 }) }
    if ($script:AppExists) { return [pscustomobject]@{ CI_ID = 1; LocalizedDisplayName = $Name } }
}
function New-CMApplication {
    param($Name, $Description, $Publisher, $SoftwareVersion, $AutoInstall, $ErrorAction)

    [void]$script:Mutations.Add('NewApplication')
    if ($script:Scenario -ne 'CreateUnreadable') { $script:AppExists = $true }
    return [pscustomobject]@{ CI_ID = 1 }
}
function Get-CMDeploymentType {
    param($ApplicationName, $ErrorAction)

    if ($script:DeploymentTypeExists) { return [pscustomobject]@{ LocalizedDisplayName = '7z.msi' } }
}
function Add-CMMSiDeploymentType {
    param($ApplicationName, $DeploymentTypeName, $ContentLocation, $Comment, [switch]$Force, $ErrorAction)

    [void]$script:Mutations.Add('AddDeploymentType')
    $script:DeploymentTypeExists = $true
}
function Add-CMScriptDeploymentType {
    param($ApplicationName, $DeploymentTypeName, $ContentLocation, $InstallCommand, $UninstallCommand, $ScriptLanguage, $ScriptText, $LogonRequirementType, $UserInteractionMode, $InstallationBehaviorType, $MaximumRuntimeMins, $EstimatedRuntimeMins, [switch]$Force, $ErrorAction)

    [void]$script:Mutations.Add('AddScriptDeploymentType')
    $script:DeploymentTypeExists = $true
}
function Sync-MemLabsContentDistribution {
    param($ContentType, $ContentName, $DistributionPointGroupName, $LegacyDistributionPointGroupName, $MigrateLegacy, $StatusTag, $SiteCode)

    [void]$script:Mutations.Add("Sync$ContentType")
    return $script:Scenario -notin @('DistributionFailure', 'OfficeDistributionFailure', 'OfficeRecoveryDistributionFailure')
}
function Get-CMApplicationDeployment {
    param($Name, $CollectionName, $ErrorAction)

    if ($script:Scenario -eq 'AppDeploymentQueryFailure') { throw 'application deployment query failed' }
    if ($script:AppDeploymentExists) { return [pscustomobject]@{ AssignmentID = 1 } }
}
function New-CMApplicationDeployment {
    param($ApplicationName, $CollectionName, $DeployAction, $DeployPurpose, $UserNotification, $ErrorAction)

    [void]$script:Mutations.Add('NewApplicationDeployment')
    $script:AppDeploymentExists = $true
}
function Get-CMPackage {
    param($Name, [switch]$Fast, $ErrorAction)

    if ($script:Scenario -eq 'DuplicatePackage') { return @([pscustomobject]@{ PackageID = 'PS100001' }, [pscustomobject]@{ PackageID = 'PS100002' }) }
    if ($script:PackageExists) { return [pscustomobject]@{ PackageID = 'PS100001' } }
}
function New-CMPackage {
    param($Name, $Path, $Description, $ErrorAction)

    [void]$script:Mutations.Add('NewPackage')
    $script:PackageExists = $true
    return [pscustomobject]@{ PackageID = 'PS100001' }
}
function Get-CMProgram {
    param($PackageId, $ProgramName, $ErrorAction)

    if ($script:ProgramExists) { return [pscustomobject]@{ ProgramName = $ProgramName } }
}
function New-CMProgram {
    param($PackageId, $StandardProgramName, $CommandLine, $ErrorAction)

    [void]$script:Mutations.Add('NewProgram')
    $script:ProgramExists = $true
}
function Get-CMPackageDeployment {
    param($PackageId, $ProgramName, $CollectionName, $ErrorAction)

    if ($script:Scenario -eq 'PackageDeploymentQueryFailure') { throw 'package deployment query failed' }
    if ($script:PackageDeploymentExists) { return [pscustomobject]@{ AdvertisementID = 'PS120001' } }
}
function New-CMPackageDeployment {
    param([switch]$StandardProgram, $PackageId, $ProgramName, $CollectionName, $DeployPurpose, $ErrorAction)

    [void]$script:Mutations.Add('NewPackageDeployment')
    $script:PackageDeploymentExists = $true
}

Write-Host "engine : $($PSVersionTable.PSVersion)"

Reset-Scenario -Name Fresh
& $appLoop
Assert-Equal 'NewApplication,AddDeploymentType,SyncApplication,NewApplicationDeployment,NewPackage,NewProgram,SyncPackage,NewPackageDeployment' ($script:Mutations -join ',') 'fresh state creates content, targets it, then creates deployments'

Reset-Scenario -Name Partial
& $appLoop
Assert-Equal 'AddDeploymentType,SyncApplication,NewApplicationDeployment,NewProgram,SyncPackage,NewPackageDeployment' ($script:Mutations -join ',') 'partial state reconciles every independently missing child object'

Reset-Scenario -Name DuplicateApp
& $appLoop
Assert-Equal '' ($script:Mutations -join ',') 'duplicate applications stop before mutation'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'duplicate applications record one failure'

Reset-Scenario -Name CreateUnreadable
& $appLoop
Assert-Equal 'NewApplication' ($script:Mutations -join ',') 'unreadable application creation stops before child mutation'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'unreadable application creation records one failure'

Reset-Scenario -Name DuplicatePackage
& $appLoop
Assert-Equal 'SyncApplication' ($script:Mutations -join ',') 'duplicate packages stop before package mutation'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'duplicate packages record one failure'

Reset-Scenario -Name AppDeploymentQueryFailure
& $appLoop
Assert-Equal 'SyncApplication' ($script:Mutations -join ',') 'application deployment query failure suppresses deployment creation'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'application deployment query failure records one failure'

Reset-Scenario -Name PackageDeploymentQueryFailure
& $appLoop
Assert-Equal 'SyncApplication,SyncPackage' ($script:Mutations -join ',') 'package deployment query failure suppresses deployment creation'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'package deployment query failure records one failure'

Reset-Scenario -Name DistributionFailure
& $appLoop
Assert-Equal 'SyncApplication' ($script:Mutations -join ',') 'distribution failure suppresses both deployment models'

$channels = @('Monthly')
Reset-Scenario -Name OfficeDistributionFailure
& $officeLoop
Assert-Equal 'NewApplication,AddScriptDeploymentType,SyncApplication' ($script:Mutations -join ',') 'Office distribution failure suppresses the initial required deployment'

$officeChannels = @('Monthly')
$officeAppNameBase = 'MEMLABS-Microsoft365Apps'
$officeColName = 'MEMLABS-Office Install Targets'
Reset-Scenario -Name OfficeRecoveryDistributionFailure
& $officeRecoveryLoop
Assert-Equal 'SyncApplication' ($script:Mutations -join ',') 'Office distribution failure suppresses recovery deployment'

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All perfloading application/package reconciliation checks passed.'