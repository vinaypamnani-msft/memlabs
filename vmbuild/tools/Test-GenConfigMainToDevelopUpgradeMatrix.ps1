<#
.SYNOPSIS
    Exercises every exact-main GenConfig role through the develop existing-VM merge path.
#>
[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$MainRevision = '6f165b5f2d370598d65bf7091c2537f101909dcf'
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$repoRoot = Split-Path -Parent $RootPath
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$commonPath = Join-Path $RootPath 'Common.ps1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.ps1'
$newDomainPath = Join-Path $RootPath 'common\Common.GenConfig.NewDomain.ps1'
$cmMenusPath = Join-Path $RootPath 'common\Common.GenConfig.CmMenus.ps1'
$existingGenConfigPath = Join-Path $RootPath 'common\Common.GenConfig.Existing.ps1'

function Import-TestFunction {
    param([string]$Path, [string]$Name)
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

function Get-ArrayAssignmentValues {
    param([string]$FunctionText, [string]$VariableName)
    $match = [regex]::Match(
        $FunctionText,
        "(?s)\`$$([regex]::Escape($VariableName))\s*=\s*@\((.*?)\)"
    )
    if (-not $match.Success) { throw "Could not find array assignment '$VariableName'." }
    @([regex]::Matches($match.Groups[1].Value, '["'']([^"'']+)["'']') |
            ForEach-Object { $_.Groups[1].Value })
}

function Get-ObjectAssignmentPropertyNames {
    param([string]$SourceText, [string]$VariableName)
    $match = [regex]::Match(
        $SourceText,
        "(?s)\`$$([regex]::Escape($VariableName))\s*=\s*\[PSCustomObject\]@\{(.*?)\n\s*\}"
    )
    if (-not $match.Success) { throw "Could not find object assignment '$VariableName'." }
    @([regex]::Matches($match.Groups[1].Value, '(?m)^\s*([A-Za-z][A-Za-z0-9_]*)\s*=') |
            ForEach-Object { $_.Groups[1].Value })
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$mainCommon = @(git -C $repoRoot show "${MainRevision}:vmbuild/Common.ps1")
if ($LASTEXITCODE -ne 0 -or $mainCommon.Count -eq 0) { throw "Could not read Common.ps1 from $MainRevision." }
$mainText = $mainCommon -join "`n"
$mainTokens = $null
$mainErrors = $null
$mainAst = [Management.Automation.Language.Parser]::ParseInput($mainText, [ref]$mainTokens, [ref]$mainErrors)
if ($mainErrors.Count) { throw "Exact-main Common.ps1 has parse errors: $($mainErrors -join '; ')" }
$mainGenConfig = @(git -C $repoRoot show "${MainRevision}:vmbuild/genconfig.ps1")
if ($LASTEXITCODE -ne 0 -or $mainGenConfig.Count -eq 0) { throw "Could not read genconfig.ps1 from $MainRevision." }
$mainGenConfigText = $mainGenConfig -join "`n"
$mainGenConfigTokens = $null
$mainGenConfigErrors = $null
$mainGenConfigAst = [Management.Automation.Language.Parser]::ParseInput(
    $mainGenConfigText, [ref]$mainGenConfigTokens, [ref]$mainGenConfigErrors)
if ($mainGenConfigErrors.Count) { throw "Exact-main genconfig.ps1 has parse errors: $($mainGenConfigErrors -join '; ')" }
$mainSupported = @($mainAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-SupportedOptions'
        }, $true))
if ($mainSupported.Count -ne 1) { throw "Expected one exact-main Set-SupportedOptions, found $($mainSupported.Count)." }
$mainNewDomain = @($mainGenConfigAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Select-NewDomainConfig'
        }, $true))
if ($mainNewDomain.Count -ne 1) { throw "Expected one exact-main Select-NewDomainConfig, found $($mainNewDomain.Count)." }

$currentSupported = Import-TestFunction -Path $commonPath -Name 'Set-SupportedOptions'
$currentNewDomain = Import-TestFunction -Path $newDomainPath -Name 'Select-NewDomainConfig'
$currentCmMenu = Import-TestFunction -Path $cmMenusPath -Name 'Invoke-CMOptionsMenuForVM'
$mainRoles = @(Get-ArrayAssignmentValues -FunctionText $mainSupported[0].Extent.Text -VariableName 'roles')
$currentRoles = @(Get-ArrayAssignmentValues -FunctionText $currentSupported.ToString() -VariableName 'roles')
$mainUpdatable = @(Get-ArrayAssignmentValues -FunctionText $mainSupported[0].Extent.Text -VariableName 'updatablePropList')
$currentUpdatable = @(Get-ArrayAssignmentValues -FunctionText $currentSupported.ToString() -VariableName 'updatablePropList')

Assert-True ($mainRoles.Count -eq 15) "Expected 15 exact-main roles, found $($mainRoles.Count)."
Assert-True (@($mainRoles | Where-Object { $_ -notin $currentRoles }).Count -eq 0) `
    'Develop dropped an exact-main GenConfig role.'
$expectedNewRoles = @('StandaloneRootCA', 'Proxy', 'LinuxServer', 'LinuxClient')
Assert-True ((@($currentRoles | Where-Object { $_ -notin $mainRoles } | Sort-Object) -join '|') -eq
    (@($expectedNewRoles | Sort-Object) -join '|')) 'Develop role additions changed unexpectedly.'
Assert-True (@($mainUpdatable | Where-Object { $_ -notin $currentUpdatable }).Count -eq 0) `
    'Develop dropped an exact-main existing-VM mutation property.'
$expectedNewMutationProperties = @(
    'useProxy', 'installOffice', 'useDatabaseReplica', 'replicaSqlServerVM',
    'replicaDbName', 'wsusDataBaseServer', 'wsusContentDir',
    'InstallPatchMyPC', 'PatchMyPCFileServer', 'pushClient'
)
Assert-True (@($expectedNewMutationProperties | Where-Object { $_ -notin $currentUpdatable }).Count -eq 0) `
    'Develop no longer exposes every expected additive existing-VM mutation.'

$mainDomainDefaults = @(Get-ObjectAssignmentPropertyNames -SourceText $mainNewDomain[0].Extent.Text -VariableName 'domainDefaults')
$currentDomainDefaults = @(Get-ObjectAssignmentPropertyNames -SourceText $currentNewDomain.ToString() -VariableName 'domainDefaults')
Assert-True (@($mainDomainDefaults | Where-Object { $_ -notin $currentDomainDefaults }).Count -eq 0) `
    'Develop dropped an exact-main domain default.'
$expectedNewDomainDefaults = @(
    'EnableSUPOnSiteServers', 'PushCMClientToClients', 'PushCMClientToServers',
    'PushCMClientToSiteSystems', 'UseProxyForClients', 'UseProxyForCM'
)
Assert-True (@($expectedNewDomainDefaults | Where-Object { $_ -notin $currentDomainDefaults }).Count -eq 0) `
    'Develop no longer declares every expected migrated domain default.'

$mainCmOptions = @(Get-ObjectAssignmentPropertyNames -SourceText $mainGenConfigText -VariableName 'newCmOptions')
$currentCmOptions = @(Get-ObjectAssignmentPropertyNames -SourceText $currentCmMenu.ToString() -VariableName 'defaults')
$legacyRootPushOption = 'PushClientToDomainMembers'
Assert-True (@($mainCmOptions | Where-Object {
            $_ -ne $legacyRootPushOption -and $_ -notin $currentCmOptions
        }).Count -eq 0) 'Develop dropped an exact-main ConfigMgr option without a migration.'
Assert-True (@(@('WsusImportBaseline', 'EnableBLM') | Where-Object { $_ -notin $currentCmOptions }).Count -eq 0) `
    'Develop ConfigMgr options are missing WSUS baseline or BLM defaults.'
$configSource = Get-Content -LiteralPath $configPath -Raw
Assert-True ($configSource -match 'PushClientToDomainMembers' -and
    $configSource -match 'pushClient property: auto-add') `
    'Legacy PushClientToDomainMembers no longer has an explicit per-VM pushClient migration.'

$existingGenConfigSource = Get-Content -LiteralPath $existingGenConfigPath -Raw
foreach ($pkiProperty in @('EnablePKI', 'IssuingCAVM', 'UseOfflineRoot', 'OfflineRootCAVM')) {
    Assert-True ($existingGenConfigSource -match "(?m)^\s*$pkiProperty\s*=") `
        "Develop existing-domain PKI defaults are missing '$pkiProperty'."
}

. (Import-TestFunction -Path $configPath -Name 'ConvertFrom-MemLabsVmNoteScalar')
. (Import-TestFunction -Path $configPath -Name 'Add-ModifiedExistingVMToDeployConfig')
. (Import-TestFunction -Path $validationPath -Name 'Test-ValidSiteRoleFlags')

$script:Inventory = @()
function Get-List {
    param([string]$Type)
    return @($script:Inventory)
}
function Start-VM2 { param([string]$Name) }
function Write-Log {
    param(
        [string]$Message,
        [switch]$Verbose,
        [switch]$LogOnly,
        [switch]$Warning,
        [switch]$Failure
    )
}
function Add-ValidationMessage {
    param(
        [string]$Message,
        [object]$ReturnObject,
        [switch]$Failure,
        [switch]$Warning
    )
    if ($Failure) { $script:ValidationFailures.Add($Message) }
}
$script:ValidationFailures = [System.Collections.Generic.List[string]]::new()

$runtimeNoise = @{
    AssignedIP = '10.0.0.20'
    LastKnownIP = '10.0.0.20'
    ReservationCreated = $true
    ToolsFingerprint = 'ABC'
    DscShortcutsCreated = 'True'
    lastPhaseComplete = 11
    appliedFixes = @('Fix-X')
    state = 'Running'
    vmBuild = $true
    domainNetBiosName = 'LEGACY'
    domainDefaults = [pscustomobject]@{ RuntimeOnly = $true }
    pkiOptions = [pscustomobject]@{ RuntimeOnly = $true }
    source = 'runtime'
    vmID = [guid]::NewGuid()
    switch = '10.0.0.0'
}

foreach ($role in $mainRoles) {
    $vm = [pscustomobject]@{
        vmName = "LEG-$role"
        role = $role
        operatingSystem = if ($role -eq 'OSDClient') { $null } else { 'Server 2022' }
        memory = '4GB'
        virtualProcs = 2
        domain = 'legacy.test'
        prefix = 'LEG-'
        adminName = 'admin'
        deployedOS = 'Server 2022'
        memLabsDeployVersion = '260420.0'
        success = $true
        inProgress = $false
        lastUpdate = '10/04/2026 12:00'
        legacyCustomProperty = "preserve-$role"
    }
    foreach ($entry in $runtimeNoise.GetEnumerator()) {
        $vm | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
    }
    if ($role -in @('CAS', 'Primary', 'Secondary', 'SiteSystem', 'PassiveSite')) {
        $vm | Add-Member -NotePropertyName siteCode -NotePropertyValue (($role.Substring(0, [Math]::Min(3, $role.Length))).ToUpper()) -Force
    }
    if ($role -eq 'SiteSystem') {
        $vm | Add-Member -NotePropertyName InstallDP -NotePropertyValue $false -Force
        $vm | Add-Member -NotePropertyName InstallMP -NotePropertyValue $false -Force
        $vm | Add-Member -NotePropertyName InstallSUP -NotePropertyValue $false -Force
        $vm | Add-Member -NotePropertyName InstallRP -NotePropertyValue $false -Force
    }
    $script:Inventory += $vm
}

$config = [pscustomobject]@{ virtualMachines = @() }
foreach ($vm in $script:Inventory) {
    Add-ModifiedExistingVMToDeployConfig -vm $vm -configToModify $config -hidden $true
}
Assert-True ($config.virtualMachines.Count -eq $mainRoles.Count) `
    "Expected one upgraded entry per exact-main role; found $($config.virtualMachines.Count)."
foreach ($vm in $config.virtualMachines) {
    Assert-True ($vm.hidden -eq $true) "Existing VM '$($vm.vmName)' was not kept hidden."
    Assert-True ($vm.ExistingVM -eq $true) "Existing VM '$($vm.vmName)' lost its per-run mutation marker."
    Assert-True ($vm.phase11Validate -eq $true) "Modified existing VM '$($vm.vmName)' was not scheduled for Phase 11 validation."
    Assert-True ($vm.legacyCustomProperty -eq "preserve-$($vm.role)") `
        "Unknown exact-main property was dropped from upgraded VM '$($vm.vmName)'."
    foreach ($noise in $runtimeNoise.Keys) {
        Assert-True ($null -eq $vm.PSObject.Properties[$noise]) `
            "Runtime property '$noise' leaked into upgraded VM '$($vm.vmName)'."
    }
    foreach ($globalProperty in @('domain', 'prefix', 'adminName', 'deployedOS', 'memLabsDeployVersion', 'lastUpdate')) {
        Assert-True ($null -eq $vm.PSObject.Properties[$globalProperty]) `
            "Global/note property '$globalProperty' leaked into upgraded VM '$($vm.vmName)'."
    }
}

$siteSystem = $script:Inventory | Where-Object role -eq 'SiteSystem' | Select-Object -First 1
$siteSystem.InstallDP = $true
$siteSystem | Add-Member -NotePropertyName 'InstallDP-Original' -NotePropertyValue $false -Force
$existingEntry = [pscustomobject]@{
    vmName = $siteSystem.vmName
    role = 'SiteSystem'
    siteCode = $siteSystem.siteCode
    installDP = $false
    hidden = $true
    thisParams = [pscustomobject]@{ Stale = $true }
    SQLAO = [pscustomobject]@{ Stale = $true }
}
$mergeConfig = [pscustomobject]@{ virtualMachines = @($existingEntry) }
Add-ModifiedExistingVMToDeployConfig -vm $siteSystem -configToModify $mergeConfig -hidden $true
Assert-True ($mergeConfig.virtualMachines.Count -eq 1) 'Modified hidden dependency was duplicated instead of merged.'
Assert-True ($mergeConfig.virtualMachines[0].InstallDP -eq $true) 'Adding DP to an existing main-era SiteSystem was discarded.'
Assert-True ($mergeConfig.virtualMachines[0].ExistingVM -eq $true) 'Modified hidden dependency lost its per-run mutation marker.'
Assert-True ($null -eq $mergeConfig.virtualMachines[0].PSObject.Properties['InstallDP-Original']) 'Edit bookkeeping leaked into deploy config.'
Assert-True ($null -eq $mergeConfig.virtualMachines[0].PSObject.Properties['thisParams']) 'Stale thisParams survived the existing-VM mutation.'
Assert-True ($null -eq $mergeConfig.virtualMachines[0].PSObject.Properties['SQLAO']) 'Stale SQLAO data survived the existing-VM mutation.'

$script:ValidationFailures.Clear()
Test-ValidSiteRoleFlags -VM ([pscustomobject]@{
        vmName = 'LEG-DOMAINMEMBER'; role = 'DomainMember'; installDP = $true
    }) -ReturnObject ([pscustomobject]@{})
Assert-True ($script:ValidationFailures.Count -eq 1) `
    'A generic DomainMember can still acquire ConfigMgr site-system flags without an explicit role promotion.'
$script:ValidationFailures.Clear()
Test-ValidSiteRoleFlags -VM ([pscustomobject]@{
        vmName = 'LEG-SITESYSTEM'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true
    }) -ReturnObject ([pscustomobject]@{})
Assert-True ($script:ValidationFailures.Count -eq 0) `
    'A valid existing SiteSystem DP promotion was rejected.'

$validationSource = Get-Content -LiteralPath $validationPath -Raw
foreach ($requiredFailure in @(
        "does not contain siteCode.+-Failure",
        "doesn't belong to an existing Site Server.+-Failure",
        "not allowed on CAS.+-Failure"
    )) {
    Assert-True ($validationSource -match $requiredFailure) `
        "SiteSystem validation is not fail-closed for pattern '$requiredFailure'."
}
Assert-True ($validationSource -match '(?s)Get-ExistingSiteServer.+?-Role CAS.+?-SiteCode') `
    'SiteSystem validation no longer checks existing CAS ownership when the CAS is absent from a partial config.'

$mutationValues = @{
    memory = '8GB'
    dynamicMinRam = '2GB'
    virtualProcs = 4
    replicaSqlServerVM = 'LEG-SQL'
    replicaDbName = 'CM_PRI_REPLICA'
    wsusDataBaseServer = 'LEG-SQL'
    wsusContentDir = 'E:\WSUS'
    PatchMyPCFileServer = 'LEG-FS'
    pushClient = 'PRI'
}
foreach ($propertyName in $currentUpdatable) {
    $mutationVm = [pscustomobject]@{
        vmName = "MUT-$propertyName"
        role = 'SiteSystem'
        siteCode = 'PRI'
        operatingSystem = 'Server 2022'
        ExistingVM = $true
        state = 'Running'
    }
    $newValue = if ($mutationValues.ContainsKey($propertyName)) { $mutationValues[$propertyName] } else { $true }
    $oldValue = if ($newValue -is [bool]) { -not $newValue } elseif ($newValue -is [int]) { 2 } else { 'OLD' }
    $mutationVm | Add-Member -NotePropertyName $propertyName -NotePropertyValue $newValue -Force
    $mutationVm | Add-Member -NotePropertyName "$propertyName-Original" -NotePropertyValue $oldValue -Force
    $script:Inventory += $mutationVm

    $mutationEntry = [pscustomobject]@{
        vmName = $mutationVm.vmName
        role = 'SiteSystem'
        siteCode = 'PRI'
        hidden = $true
        thisParams = [pscustomobject]@{ Stale = $true }
    }
    $mutationConfig = [pscustomobject]@{ virtualMachines = @($mutationEntry) }
    Add-ModifiedExistingVMToDeployConfig -vm $mutationVm -configToModify $mutationConfig -hidden $true
    Assert-True ($mutationConfig.virtualMachines.Count -eq 1) `
        "Existing-VM mutation '$propertyName' duplicated its hidden dependency."
    Assert-True ("$($mutationConfig.virtualMachines[0].$propertyName)" -eq "$newValue") `
        "Existing-VM mutation '$propertyName' was discarded."
    Assert-True ($null -eq $mutationConfig.virtualMachines[0].PSObject.Properties["$propertyName-Original"]) `
        "Existing-VM mutation marker '$propertyName-Original' leaked into deploy config."
}

Write-Host "PASS -- $($mainRoles.Count) exact-main roles and $($currentUpdatable.Count) existing-VM mutations survive develop schema upgrade."
