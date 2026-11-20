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
$appModes = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -in @('$allowOptionalAppWarnings', '$appFailureMode')
        }, $true) | Sort-Object { $_.Extent.StartOffset })
if ($appModes.Count -ne 2) { throw 'Expected the retained-site application failure policy assignments.' }
$appLoop = [scriptblock]::Create(($appModes.Extent.Text -join "`n") + "`n" + $appLoops[0].Extent.Text)
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
    $script:FilesystemWrites = 0
    $script:ImportedMsi = ''
    $script:ThisVM = [pscustomobject]@{ phase8RetainedSite = $Name -like 'Retained*' }
    $script:AppExists = $Name -notin @('Fresh', 'CreateUnreadable', 'OfficeDistributionFailure')
    $script:DeploymentTypeExists = $Name -notin @('Fresh', 'Partial', 'MsiImportFailure', 'RetainedMsiImportFailure')
    $script:AppDeploymentExists = $Name -in @('DuplicatePackage', 'PackageDeploymentQueryFailure')
    $script:PackageExists = $Name -notin @('Fresh', 'CreateUnreadable', 'DuplicateApp', 'AppDeploymentQueryFailure', 'DistributionFailure')
    $script:ProgramExists = $Name -in @('DuplicatePackage', 'PackageDeploymentQueryFailure')
    $script:PackageDeploymentExists = $Name -eq 'DuplicatePackage'
}

function Write-DscStatus {
    param ([Parameter(Position = 0)][string] $Message, [switch] $Failure, [switch] $Warning)

    [void]$script:Statuses.Add([pscustomobject]@{ Message = $Message; Failure = [bool]$Failure; Warning = [bool]$Warning })
}
function Test-Path {
    [CmdletBinding()]
    param($LiteralPath, $PathType)

    if ($script:Scenario -in @('MissingSource', 'RetainedMissingSource') -and $LiteralPath -eq 'C:\Apps\7-Zip 64-bit\7z.msi') { return $false }
    if ($LiteralPath -like 'C:\tools\*') { return $false }
    if ($LiteralPath -like '\\*') { return $false }
    if ($script:Scenario -in @('UncNotVisible', 'RetainedUncNotVisible') -and $LiteralPath -like 'FileSystem::\\*') { return $false }
    return $true
}
function New-Item {
    [CmdletBinding()]
    param($ItemType, $Value, $Path, [switch]$Force)

    $script:FilesystemWrites++
    return [pscustomobject]@{ FullName = $Path }
}
function Get-Item { param($LiteralPath); return [pscustomobject]@{ LinkType = 'HardLink' } }
function Get-MockedFileHash { param($LiteralPath, $Algorithm); return [pscustomobject]@{ Hash = 'SAME' } }
Set-Alias -Name Get-FileHash -Value Get-MockedFileHash -Scope Script
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

    if ($script:Scenario -like '*MsiImportFailure') { throw [IO.FileNotFoundException]::new('Synthetic MSI import failure.') }
    [void]$script:Mutations.Add('AddDeploymentType')
    $script:ImportedMsi = $ContentLocation
    $script:DeploymentTypeExists = $true
}
function Add-CMScriptDeploymentType {
    param($ApplicationName, $DeploymentTypeName, $ContentLocation, $InstallCommand, $UninstallCommand, $ScriptLanguage, $ScriptText, $LogonRequirementType, $UserInteractionMode, $InstallationBehaviorType, $MaximumRuntimeMins, $EstimatedRuntimeMins, [switch]$Force, $ErrorAction)

    [void]$script:Mutations.Add('AddScriptDeploymentType')
    $script:DeploymentTypeExists = $true
}
function Sync-MemLabsContentDistribution {
    param($ContentType, $ContentName, $DistributionPointGroupName, $LegacyDistributionPointGroupName, $MigrateLegacy, $StatusTag, $SiteCode, [switch]$WarnOnly)

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
Assert-Equal 0 $script:FilesystemWrites 'a current source remains a no-op while the CMSite provider rejects bare UNC paths'
Assert-Equal '\\PS1SITE\c$\Apps\7-Zip 64-bit\7z.msi' $script:ImportedMsi 'MSI import uses the verified UNC file, not its containing directory'

foreach ($scenario in 'MissingSource', 'MsiImportFailure', 'UncNotVisible') {
    Reset-Scenario -Name $scenario
    $caught = $null
    try { & $appLoop } catch { $caught = $_ }
    Assert-Equal $true ($null -ne $caught) "$scenario stops preloading with an explicit error"
    Assert-Equal '' ($script:Mutations -join ',') "$scenario stops before ConfigMgr object mutation"
    if ($scenario -eq 'MissingSource') {
        Assert-Equal $true ("$caught" -match [regex]::Escape('C:\Apps\7-Zip 64-bit\7z.msi')) 'missing-source error identifies the durable local installer'
        Assert-Equal 0 $script:FilesystemWrites 'missing installer stops before creating a source link'
    }
    elseif ($scenario -eq 'UncNotVisible') {
        Assert-Equal $true ("$caught" -match [regex]::Escape('\\PS1SITE\c$\Apps\7-Zip 64-bit\7z.msi')) 'UNC visibility error identifies the exact importer path'
    }
}
foreach ($scenario in 'RetainedMissingSource', 'RetainedMsiImportFailure', 'RetainedUncNotVisible') {
    Reset-Scenario -Name $scenario
    $caught = $null
    try { & $appLoop } catch { $caught = $_ }
    Assert-Equal $true ($null -eq $caught -and @($script:Statuses | Where-Object Failure).Count -eq 0) "$scenario does not fail the retained-site workflow"
    Assert-Equal 1 @($script:Statuses | Where-Object Warning).Count "$scenario reports the skipped optional application explicitly"
    Assert-Equal '' ($script:Mutations -join ',') "$scenario does not deploy incomplete application content"
}

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

& {
    $validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
    $validationAst = [System.Management.Automation.Language.Parser]::ParseFile($validationPath, [ref]$null, [ref]$null)
    $appChecks = @($validationAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text -match '^if \(\$expectedApps -and' -and
                $node.Extent.Text -match 'SMS_ApplicationLatest'
            }, $true))
    if ($appChecks.Count -ne 1) { throw 'Expected one Phase 11 demo-application presence check.' }
    $checkApplications = [scriptblock]::Create($appChecks[0].Extent.Text)
    function Get-WmiObject { param($Namespace, $Class, $Filter, $ErrorAction) }
    $expectedApps = @('MEMLABS-7-Zip 64-bit')
    foreach ($retainedSiteInner in 'False', 'True') {
        $results = @{ Passed = $true; Details = [Collections.Generic.List[string]]::new() }
        & $checkApplications
        Assert-Equal ($retainedSiteInner -eq 'True') $results.Passed "Phase 11 applies the selected retained-site warning policy ($retainedSiteInner)"
    }
}

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All perfloading application/package reconciliation checks passed.'