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
function Set-CMApplication {
    [CmdletBinding()]
    param($Name, $SoftwareVersion, $Description)
    $script:Application.SoftwareVersion = "$SoftwareVersion"
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
function Set-CMScriptDeploymentType {
    [CmdletBinding()]
    param($ApplicationName, $DeploymentTypeName, $NewName, $InstallCommand, $ContentLocation, $ScriptLanguage, $ScriptText)
    if ($NewName) { $script:DeploymentTypes[0].LocalizedDisplayName = $NewName }
    $script:DeploymentTypes[0].InstallCommand = $InstallCommand
    $script:DeploymentTypes[0].ContentLocation = $ContentLocation
    $script:DeploymentTypes[0].ScriptLanguage = $ScriptLanguage
    $script:DeploymentTypes[0].ScriptText = $ScriptText
}
function Update-CMDistributionPoint {
    [CmdletBinding()]
    param($ApplicationName, $DeploymentTypeName)
}
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
function Get-CMTSStepReboot {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName)
    process {
        $result = @($InputObject.Steps | Where-Object { $_.Type -eq 'Reboot' })
        if ($StepName) { $result = @($result | Where-Object { $_.Name -eq $StepName }) }
        return $result
    }
}
function Remove-CMTSStepReboot {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName, [switch]$Force)
    process { $InputObject.Steps = @($InputObject.Steps | Where-Object { $_.Name -ne $StepName }) }
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
function New-CMTSStepReboot {
    [CmdletBinding()]
    param($Name, $RunAfterRestart, $NotificationMessage, $MessageTimeout)
    $target = if ($RunAfterRestart -eq 'HardDisk') { 'HD' } else { 'WinPE' }
    return [pscustomobject]@{ Name = $Name; Type = 'Reboot'; Target = $target }
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
$payloadSourceRoot = Join-Path ([IO.Path]::GetTempPath()) ('MemLabsOsdPayload-' + [guid]::NewGuid().ToString('N'))
$toolsRoot = Join-Path ([IO.Path]::GetTempPath()) ('MemLabsOsdTools-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $payloadSourceRoot 'bginfo') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $payloadSourceRoot 'DSC\phases') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $toolsRoot 'LogMachine') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $payloadSourceRoot 'Enable-LogMachine.ps1'), '# test')
$sharedPayloadRoot = Join-Path $RootPath 'baseimagestaging\filesToInject\staging'
foreach ($name in @('Invoke-MemLabsCustomization.ps1', 'Optimize-Defender.ps1', 'Set-MemLabsMachineSettings.ps1', 'Set-MemLabsUserShell.ps1')) {
    Copy-Item -LiteralPath (Join-Path $sharedPayloadRoot $name) -Destination (Join-Path $payloadSourceRoot $name) -Force
}
foreach ($name in @('CLIENT.bgi', 'bginfo_CLIENT.lnk', 'bginfo.exe')) {
    [IO.File]::WriteAllText((Join-Path (Join-Path $payloadSourceRoot 'bginfo') $name), 'test')
}
[IO.File]::WriteAllText((Join-Path $toolsRoot 'LogMachine\LogMachine.exe'), 'test')
$diskInitializerSource = Join-Path $RootPath 'DSC\phases\Initialize-OsdDataDisks.ps1'
Copy-Item -LiteralPath $diskInitializerSource -Destination (Join-Path $payloadSourceRoot 'DSC\phases\Initialize-OsdDataDisks.ps1') -Force
$clients = @(
    [pscustomobject]@{ vmName = 'OSD1'; additionalDisks = [pscustomobject][ordered]@{ E = [int64](20GB); F = [int64](20GB) } }
    [pscustomobject]@{ vmName = 'OSD2' }
)
$taskSequences = @(
    [pscustomobject]@{ Name = 'MEMLABS-w11-Install OS image'; Steps = @(
            [pscustomobject]@{ Name = 'Setup Windows'; Type = 'Other' }
            [pscustomobject]@{ Name = 'MEMLABS restart into installed OS'; Type = 'Reboot'; Target = 'HD' }
            [pscustomobject]@{ Name = 'MEMLABS install OSD Bootstrap'; Type = 'InstallApplication'; Application = 'MEMLABS-OSD Bootstrap' }
        ) }
    [pscustomobject]@{ Name = 'MEMLABS-w10-Install OS image'; Steps = @() }
    [pscustomobject]@{ Name = 'MEMLABS-w11-In-Place Upgrade Task Sequence'; Steps = @() }
)

try {
    $result = Sync-MemLabsOsdBootstrapFramework -SourceRoot $sourceRoot `
        -SourceUnc '\\PS1SITE\OSD\MemLabsOsdBootstrap' `
        -PayloadSourceRoot $payloadSourceRoot -DataDiskInitializerSource $diskInitializerSource `
        -ToolsRoot $toolsRoot -OsdClients $clients `
        -TaskSequences $taskSequences -DistributionPointGroupName 'OSD DPS' -StatusTag '[test]'
    Assert-Equal $true $result 'fresh framework reconcile succeeds'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Install.ps1')) 'versioned install payload is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Manifest.json')) 'framework manifest is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\Enable-LogMachine.ps1')) 'desktop shortcut script is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\Invoke-MemLabsCustomization.ps1')) 'shared customization runner is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\Optimize-Defender.ps1')) 'shared Defender implementation is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\Set-MemLabsMachineSettings.ps1')) 'shared machine settings are staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\Set-MemLabsUserShell.ps1')) 'shared user shell settings are staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\bginfo\bginfo.exe')) 'BGInfo executable is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\LogMachine\LogMachine.exe')) 'LogMachine is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\Initialize-OsdDataDisks.ps1')) 'data-disk initializer is staged'
    Assert-Equal $true (Test-Path (Join-Path $sourceRoot 'Payload\DiskConfig.json')) 'per-client disk configuration is staged'
    $diskConfig = Get-Content (Join-Path $sourceRoot 'Payload\DiskConfig.json') -Raw | ConvertFrom-Json
    $osd1DiskConfig = @($diskConfig.Clients | Where-Object ComputerName -eq 'OSD1')[0]
    $osd2DiskConfig = @($diskConfig.Clients | Where-Object ComputerName -eq 'OSD2')[0]
    Assert-Equal 'E,F' (@($osd1DiskConfig.Disks.Letter) -join ',') 'two same-size OSD1 disks retain configured attachment order'
    Assert-Equal '0,1' (@($osd1DiskConfig.Disks.DiskIndex) -join ',') 'disk manifest carries deterministic attachment ordinals'
    Assert-Equal 0 @($osd2DiskConfig.Disks).Count 'zero-disk OSD client has an explicit empty plan'
    $coreInstallText = Get-Content (Join-Path $sourceRoot 'Install.ps1') -Raw
    Assert-Equal $true ($coreInstallText.Contains("`$ErrorActionPreference = 'Continue'")) 'desktop script runs without inherited Stop semantics'
    Assert-Equal $true ($coreInstallText.Contains('Required desktop shortcut was not created')) 'desktop policy validates required shortcut postconditions'
    Assert-Equal $true ($coreInstallText.Contains('Initialize-MemLabsOsdDataDisks')) 'installer invokes data-disk initializer before marking compliance'
    Assert-Equal $true ($coreInstallText.Contains('TrimStart([char]0xFEFF)')) 'installer tolerates duplicate BOMs in the staged disk initializer'
    Assert-Equal $true ($coreInstallText.Contains("'DefenderTuning', 'WindowsMachine', 'WindowsUserRegistration'")) 'installer invokes the shared OSD customization profile'
    Assert-Equal 'MEMLABS-OSD Bootstrap' $script:Application.Name 'OSD core application is created'
    Assert-Equal $true ($script:Application.SoftwareVersion -match '^5\.[0-9A-F]{12}$') 'OSD core application uses a v5 content fingerprint version'
    Assert-Equal 'MEMLABS-OSD Bootstrap v3' $script:DeploymentTypes[0].LocalizedDisplayName 'versioned core deployment type is created'
    Assert-Equal 'InstallForSystem' $script:DeploymentTypes[0].InstallationBehaviorType 'deployment type installs as system'
    Assert-Equal 'WhetherOrNotUserLoggedOn' $script:DeploymentTypes[0].LogonRequirementType 'deployment type does not require a user session'
    Assert-Equal 'MEMLABS-OSD Bootstrap->OSD DPS' ($script:DistributionRequests -join ',') 'bootstrap content targets the OSD DP group'
    Assert-Equal 'Install,Required,HideAll' $script:NewDeploymentArgs 'ongoing policy is required and silent'
    Assert-Equal $true ($script:Rules[0].QueryExpression -like "*Client = 1*Name in ('OSD1','OSD2')*") 'policy collection is config-name keyed and client gated'
    Assert-Equal 0 @($taskSequences[0].Steps | Where-Object Name -eq 'MEMLABS restart into installed OS').Count 'Windows 11 install TS removes the experimental bootstrap reboot'
    Assert-Equal 0 @($taskSequences[0].Steps | Where-Object Name -eq 'MEMLABS install OSD Bootstrap').Count 'Windows 11 install TS removes the experimental bootstrap app step'
    Assert-Equal 'Setup Windows' $taskSequences[0].Steps[-1].Name 'native Setup Windows action is terminal again'
    Assert-Equal 0 @($taskSequences[1].Steps | Where-Object Name -eq 'MEMLABS install OSD Bootstrap').Count 'Windows 10 install TS remains free of bootstrap execution steps'
    Assert-Equal 0 @($taskSequences[2].Steps | Where-Object Name -eq 'MEMLABS install OSD Bootstrap').Count 'in-place upgrade TS is not changed'

    $result = Sync-MemLabsOsdBootstrapFramework -SourceRoot $sourceRoot `
        -SourceUnc '\\PS1SITE\OSD\MemLabsOsdBootstrap' `
        -PayloadSourceRoot $payloadSourceRoot -DataDiskInitializerSource $diskInitializerSource `
        -ToolsRoot $toolsRoot -OsdClients $clients `
        -TaskSequences $taskSequences -DistributionPointGroupName 'OSD DPS' -StatusTag '[test]'
    Assert-Equal $true $result 'rerun framework reconcile succeeds'
    Assert-Equal 0 @($taskSequences[0].Steps | Where-Object Name -eq 'MEMLABS restart into installed OS').Count 'rerun keeps bootstrap reboot absent'
    Assert-Equal 0 @($taskSequences[0].Steps | Where-Object Name -eq 'MEMLABS install OSD Bootstrap').Count 'rerun keeps bootstrap app step absent'
    Assert-Equal 1 $script:Deployments.Count 'rerun does not duplicate required deployment'
    Assert-Equal 1 $script:Rules.Count 'rerun does not duplicate collection rule'

    $originalVersion = $script:Application.SoftwareVersion
    $script:Application.SoftwareVersion = '1'
    $script:DeploymentTypes[0].LocalizedDisplayName = 'MEMLABS-OSD Bootstrap v1'
    $result = Sync-MemLabsOsdBootstrapFramework -SourceRoot $sourceRoot `
        -SourceUnc '\\PS1SITE\OSD\MemLabsOsdBootstrap' `
        -PayloadSourceRoot $payloadSourceRoot -DataDiskInitializerSource $diskInitializerSource `
        -ToolsRoot $toolsRoot -OsdClients $clients `
        -TaskSequences $taskSequences -DistributionPointGroupName 'OSD DPS' -StatusTag '[test]'
    Assert-Equal $true $result 'existing version 1 application revises in place'
    Assert-Equal $originalVersion $script:Application.SoftwareVersion 'application revision restores fingerprinted software version'
    Assert-Equal 'MEMLABS-OSD Bootstrap v3' $script:DeploymentTypes[0].LocalizedDisplayName 'application revision updates deployment type'

    $clients[0].additionalDisks.E = [int64](21GB)
    $result = Sync-MemLabsOsdBootstrapFramework -SourceRoot $sourceRoot `
        -SourceUnc '\\PS1SITE\OSD\MemLabsOsdBootstrap' `
        -PayloadSourceRoot $payloadSourceRoot -DataDiskInitializerSource $diskInitializerSource `
        -ToolsRoot $toolsRoot -OsdClients $clients `
        -TaskSequences $taskSequences -DistributionPointGroupName 'OSD DPS' -StatusTag '[test]'
    Assert-Equal $true $result 'disk configuration change revises existing v3 policy'
    Assert-Equal $true ($script:Application.SoftwareVersion -ne $originalVersion) 'disk configuration change produces a new application version'
    Assert-Equal 'MEMLABS-OSD Bootstrap v3' $script:DeploymentTypes[0].LocalizedDisplayName 'content-only v3 revision preserves deployment type name'
    Assert-Equal $true ($script:DeploymentTypes[0].ScriptText.Contains('FileSystemLabel')) 'detection verifies configured filesystem labels'
    Assert-Equal $true ($script:DeploymentTypes[0].ScriptText.Contains('DisableWindowsConsumerFeatures')) 'detection verifies shared machine settings'
    Assert-Equal $true ($script:DeploymentTypes[0].ScriptText.Contains('{9EA95B85-EEB7-4A88-AE03-1C377BBFD411}')) 'detection verifies Active Setup registration'
    Assert-Equal $true ($script:DeploymentTypes[0].ScriptText.Contains('ScanAvgCPULoadFactor')) 'detection verifies shared Defender tuning'

    $script:Collection = $null
    $script:Rules = @()
    $script:Deployments = @()
    $noDpTaskSequence = [pscustomobject]@{ Name = 'MEMLABS-w11-Install OS image'; Steps = @() }
    $result = Sync-MemLabsOsdBootstrapFramework -SourceRoot $sourceRoot `
        -SourceUnc '\\PS1SITE\OSD\MemLabsOsdBootstrap' `
        -PayloadSourceRoot $payloadSourceRoot -DataDiskInitializerSource $diskInitializerSource `
        -ToolsRoot $toolsRoot -OsdClients $clients `
        -TaskSequences @($noDpTaskSequence) -DistributionPointGroupName '' -StatusTag '[test]'
    Assert-Equal $true $result 'missing OSD DP is handled without authoring broken references'
    Assert-Equal $true ($null -eq $script:Collection) 'missing OSD DP does not create policy collection'
    Assert-Equal 0 $noDpTaskSequence.Steps.Count 'missing OSD DP does not add bootstrap task-sequence step'
}
finally {
    Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $payloadSourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $toolsRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$source = Get-Content $perfloadingPath -Raw
Assert-Equal $true ($source.Contains('Sync-MemLabsOsdBootstrapFramework')) 'perfloading contains bootstrap reconciler'
Assert-Equal $true ($source.Contains("`$bootstrapPayloadSource = 'C:\staging'")) 'runtime bootstrap assets come from injected C:\staging payload'
$scriptBlocksSource = Get-Content (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1') -Raw
Assert-Equal $true ($scriptBlocksSource.Contains('refreshed shared OSD customization payload')) 'Phase 8 refreshes shared payload on existing site servers'
Assert-Equal $true ($scriptBlocksSource.Contains('Copy-Item -ToSession $ps -LiteralPath $sharedCustomizationSource')) 'Phase 8 transports shared payload through its established VM session'
Assert-Equal $true ($source.Contains("Join-Path `$PSScriptRoot 'Initialize-OsdDataDisks.ps1'")) 'disk initializer resolves beside the running DSC phase'
Assert-Equal $false ($source.Contains('Split-Path (Split-Path $PSScriptRoot -Parent) -Parent')) 'runtime payload root is not inferred by walking up from DSC phase path'
Assert-Equal $true ($source.Contains('-DeployPurpose Required -UserNotification HideAll')) 'required policy path is present'
Assert-Equal $true ($source.Contains("Label = 'scheduled scan CPU limit seeded'")) 'ConfigMgr CPU limit is seeded while scheduled scanning is enabled'
Assert-Equal $true ($source.Contains('[int]$rawAntimalwareConfig.LimitCPUUsage -ne 10')) 'ConfigMgr CPU policy is verified through the hydrated provider object'
Assert-Equal $false ($source.Contains('Add-CMTaskSequenceStep -Step @($rebootStep, $installStep)')) 'bootstrap is not executed inside the OS deployment task sequence'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD bootstrap framework checks passed.'
