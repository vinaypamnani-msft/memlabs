<#
.SYNOPSIS
    Proves add-to-existing ConfigMgr options override stale hidden VM notes.

.DESCRIPTION
    Reproduces extending a domain whose deployed Primary still carries the
    cmOptions from the original build. No Hyper-V or ConfigMgr provider is
    required. Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Inventory = @()
$script:VmStore = @{}
$script:SetVmCalls = 0
$script:SetVmShouldThrow = $false
$script:SetVmIgnoreWrite = $false
$script:BackupOptionsByVm = @{}
$script:BackupRequests = New-Object System.Collections.Generic.List[string]

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

function Assert-Throws {
    param ([scriptblock] $Action, [string] $MessagePattern, [string] $What)

    $caught = $null
    try { & $Action } catch { $caught = $_ }
    $passed = $caught -and $caught.Exception.Message -like $MessagePattern
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        $actual = if ($caught) { $caught.Exception.Message } else { '<no exception>' }
        Write-Host "      expected: $MessagePattern"
        Write-Host "      actual:   $actual"
    }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$Path has $($errors.Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Get-List {
    param ($Type, $DomainName, [switch] $SmartUpdate)
    $result = @($script:Inventory)
    if ($DomainName) {
        $result = @($result | Where-Object {
                $_.domain -and $_.domain -eq $DomainName
            })
    }
    return $result
}
function Get-ExistingForDomain {
    param ([string] $DomainName, [string] $Role)
    return @($script:Inventory | Where-Object {
            $_.role -eq $Role -and (-not $_.domain -or $_.domain -eq $DomainName)
        } | ForEach-Object { $_.vmName })
}
function Get-VM2 {
    param ([Parameter(Position = 0)] [string] $Name, [switch] $Fallback)
    return $script:VmStore[$Name]
}
function Set-VM {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true)] [object] $InputObject,
        [string] $Notes
    )
    process {
        if ($script:SetVmShouldThrow) { throw 'simulated VM-note write failure' }
        if (-not $script:SetVmIgnoreWrite) { $InputObject.Notes = $Notes }
        $script:SetVmCalls++
    }
}
function Start-VM2 { param ([string] $Name) }
function Write-Log {
    param ($Message, [switch] $LogOnly, [switch] $Warning, [switch] $Failure)
}
function Get-MemlabsVmStorageRoot { return 'C:\MemLabs-VMs' }
function Get-MemlabsDataRoot { return 'C:\MemLabs-Test-Data' }
function get-PrefixForDomain { param ([string] $Domain); return 'LAB-' }
function Get-CMLatestBaselineVersion { return '2509' }
function Get-OsdPxePaths { return @() }
function Get-CmOptionsFromSiteServerBackup {
    param ([string] $VmName, [string] $DomainName)
    $script:BackupRequests.Add($VmName)
    return $script:BackupOptionsByVm[$VmName]
}
function Set-TestVmNote {
    param ([string] $Name, [object] $Note)

    if ($null -eq $Note.PSObject.Properties['lastUpdate']) {
        $Note | Add-Member -MemberType NoteProperty -Name lastUpdate -Value '01/01/2026 00:00' -Force
    }
    $script:VmStore[$Name] = [pscustomobject]@{
        Name  = $Name
        Notes = ($Note | ConvertTo-Json -Depth 5 -Compress)
    }
}

function New-TestConfig {
    param ([bool] $EnableBLM, [switch] $WithAuthoredTopLevel)

    $vms = @([pscustomobject]@{ vmName = 'OSD1'; role = 'OSDClient'; BitLocker = $EnableBLM })
    if ($WithAuthoredTopLevel) {
        $vms += [pscustomobject]@{
            vmName = 'NEWPRI'; role = 'Primary'; siteCode = 'NEW'; cmOptions = [pscustomobject]@{ EnableBLM = $EnableBLM }
        }
    }
    return [pscustomobject]@{
        cmOptions       = [pscustomobject]@{ EnableBLM = $EnableBLM; Version = '2509' }
        vmOptions       = [pscustomobject]@{ domainName = 'example.test' }
        virtualMachines = @($vms)
    }
}

$sourcePath = Join-Path $RootPath 'common\Common.Config.ps1'
$commonPath = Join-Path $RootPath 'Common.ps1'
$existingPath = Join-Path $RootPath 'common\Common.GenConfig.Existing.ps1'
$genConfigPath = Join-Path $RootPath 'common\Common.GenConfig.ps1'
. (Import-TestFunction -Path $commonPath -Name 'Get-VMNote')
. (Import-TestFunction -Path $commonPath -Name 'Set-VMNote')
. (Import-TestFunction -Path $sourcePath -Name 'Get-CmOptionsFingerprint')
. (Import-TestFunction -Path $sourcePath -Name 'Get-AddToExistingCmOptionsOwner')
. (Import-TestFunction -Path $sourcePath -Name 'Get-LegacyCmOptionsRecoverySite')
. (Import-TestFunction -Path $sourcePath -Name 'Test-CmOptionsOwnerContainsVM')
. (Import-TestFunction -Path $sourcePath -Name 'Get-CmOptionsOwnerPrimaryNames')
. (Import-TestFunction -Path $sourcePath -Name 'Set-VmCmOptionsResolved')
. (Import-TestFunction -Path $sourcePath -Name 'Set-AddToExistingCmOptionsOnHiddenSiteRole')
. (Import-TestFunction -Path $sourcePath -Name 'Test-AddToExistingCmOptionsChanged')
. (Import-TestFunction -Path $sourcePath -Name 'Add-ExistingVMToDeployConfig')
. (Import-TestFunction -Path $sourcePath -Name 'Add-ModifiedExistingVMToDeployConfig')
. (Import-TestFunction -Path $sourcePath -Name 'Add-CmOptionsPersistenceTargetForPhase8')
. (Import-TestFunction -Path $sourcePath -Name 'Add-ExistingVMsToDeployConfig')
. (Import-TestFunction -Path $sourcePath -Name 'Move-CmOptionsToTopLevelSiteServer')
. (Import-TestFunction -Path $sourcePath -Name 'Sync-AddToExistingCmOptionsNotes')
. (Import-TestFunction -Path $sourcePath -Name 'New-DeployConfig')
. (Import-TestFunction -Path $existingPath -Name 'New-UserConfig')
. (Import-TestFunction -Path $genConfigPath -Name 'ConvertTo-DeployConfigEx')
$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
. (Import-TestFunction -Path $phasesPath -Name 'Get-Phase8ConfigurationData')

Write-Host "engine : $($PSVersionTable.PSVersion)"

$scalarOptionsA = [pscustomobject][ordered]@{ Version = '2509'; EnableBLM = $true; Install = $false }
$scalarOptionsB = [pscustomobject][ordered]@{ Install = $false; EnableBLM = $true; Version = '2509' }
$scalarValueChanged = [pscustomobject][ordered]@{ Install = $false; EnableBLM = $false; Version = '2509' }
$scalarFingerprint = Get-CmOptionsFingerprint -CmOptions $scalarOptionsA
Assert-Equal $scalarFingerprint (Get-CmOptionsFingerprint -CmOptions $scalarOptionsB) 'scalar property order does not change the options fingerprint'
Assert-Equal $false ($scalarFingerprint -eq (Get-CmOptionsFingerprint -CmOptions $scalarValueChanged)) 'scalar value changes alter the options fingerprint'
Assert-Throws { Get-CmOptionsFingerprint -CmOptions ([pscustomobject]@{ Version = '2509'; Advanced = [pscustomobject]@{ Beta = $true } }) } '*unsupported non-scalar type*' 'non-scalar cmOptions values fail explicitly'

$caseCollision = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
$caseCollision.Add('Mode', 1)
$caseCollision.Add('mode', 2)
Assert-Throws { Get-CmOptionsFingerprint -CmOptions $caseCollision } '*ambiguous keys*mode*' 'case-insensitive dictionary key collisions are rejected'

$script:Inventory = @(
    [pscustomobject]@{ vmName = 'A-STANDALONE'; role = 'Primary'; siteCode = 'STA'; domain = 'example.test' },
    [pscustomobject]@{ vmName = 'B-CAS'; role = 'CAS'; siteCode = 'CAS' }
)
Set-TestVmNote -Name 'A-STANDALONE' -Note ([pscustomobject]@{ vmName = 'A-STANDALONE'; role = 'Primary'; siteCode = 'STA'; domain = 'example.test' })
Set-TestVmNote -Name 'B-CAS' -Note ([pscustomobject]@{ vmName = 'B-CAS'; role = 'CAS'; siteCode = 'CAS' })
$script:BackupOptionsByVm = @{
    'A-STANDALONE' = [pscustomobject]@{ Version = '2403'; EnableBLM = $true; UsePKI = $false; Install = $true }
    'B-CAS' = [pscustomobject]@{ Version = '2509'; EnableBLM = $false; UsePKI = $true; Install = $true }
}
$script:BackupRequests.Clear()
$global:Common = [pscustomobject]@{ InJob = $false; IsAzureVM = $false }
$legacyRecoveryConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ Version = '2509'; EnableBLM = $false; UsePKI = $false; Install = $true }
    cmOptionsOwnerVM = 'B-CAS'
    vmOptions = [pscustomobject]@{
        domainName = 'example.test'; domainNetBiosName = 'EXAMPLE'; adminName = 'admin'
        prefix = ''; network = '192.168.1.0'
    }
    pkiOptions = $null
    virtualMachines = @()
}
$legacyDeploy = New-DeployConfig -ConfigObject $legacyRecoveryConfig
Assert-Equal 'B-CAS' ($script:BackupRequests -join ',') 'legacy recovery requests only the recorded hierarchy owner backup'
Assert-Equal 'B-CAS' $legacyDeploy.cmOptionsOwnerVM 'legacy recovery preserves hierarchy owner through New-DeployConfig'
Assert-Equal '2509' $legacyDeploy.cmOptions.Version 'legacy recovery adopts the owner hierarchy version'
Assert-Equal $false $legacyDeploy.cmOptions.EnableBLM 'legacy recovery does not borrow sibling BLM state'
Assert-Equal $true $legacyDeploy.cmOptions.UsePKI 'legacy recovery adopts the owner hierarchy PKI state'

$script:Inventory = @([pscustomobject]@{
        vmName = 'PS1SITE'; role = 'Primary'; siteCode = 'PS1'; state = 'Running'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
Set-TestVmNote -Name 'PS1SITE' -Note ([pscustomobject]@{
        vmName = 'PS1SITE'; role = 'Primary'; siteCode = 'PS1'; customMarker = 'keep'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
$config = New-TestConfig -EnableBLM $true
Add-ExistingVMToDeployConfig -VmName 'PS1SITE' -ConfigToModify $config
$hiddenPrimary = $config.virtualMachines | Where-Object { $_.vmName -eq 'PS1SITE' }
Assert-Equal $true $hiddenPrimary.cmOptions.EnableBLM 'authored enable overrides stale disabled Primary note'
Assert-Equal $false ([object]::ReferenceEquals($config.cmOptions, $hiddenPrimary.cmOptions)) 'hidden Primary receives an independent options clone'

$config.cmOptions.EnableBLM = $false
Add-ExistingVMToDeployConfig -VmName 'PS1SITE' -ConfigToModify $config
$hiddenPrimary = $config.virtualMachines | Where-Object { $_.vmName -eq 'PS1SITE' }
Assert-Equal $false $hiddenPrimary.cmOptions.EnableBLM 'duplicate hidden Primary receives a later authored disable'

$script:Inventory[0].cmOptions.EnableBLM = $true
Set-TestVmNote -Name 'PS1SITE' -Note ([pscustomobject]@{
        vmName = 'PS1SITE'; role = 'Primary'; siteCode = 'PS1'
        cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    })
$config = New-TestConfig -EnableBLM $false
Add-ExistingVMToDeployConfig -VmName 'PS1SITE' -ConfigToModify $config
$hiddenPrimary = $config.virtualMachines | Where-Object { $_.vmName -eq 'PS1SITE' }
Assert-Equal $false $hiddenPrimary.cmOptions.EnableBLM 'authored disable overrides stale enabled Primary note'

$script:Inventory[0].cmOptions.EnableBLM = $false
Set-TestVmNote -Name 'PS1SITE' -Note ([pscustomobject]@{
        vmName = 'PS1SITE'; role = 'Primary'; siteCode = 'PS1'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
$config = New-TestConfig -EnableBLM $true -WithAuthoredTopLevel
Add-ExistingVMToDeployConfig -VmName 'PS1SITE' -ConfigToModify $config
$hiddenPrimary = $config.virtualMachines | Where-Object { $_.vmName -eq 'PS1SITE' }
Assert-Equal $false $hiddenPrimary.cmOptions.EnableBLM 'full config preserves an unrelated hidden hierarchy snapshot'

$script:Inventory = @([pscustomobject]@{
        vmName = 'MODPRI'; role = 'Primary'; siteCode = 'MOD'; state = 'Running'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
$config = New-TestConfig -EnableBLM $true
Add-ModifiedExistingVMToDeployConfig -VM $script:Inventory[0] -ConfigToModify $config
$modifiedPrimary = $config.virtualMachines | Where-Object { $_.vmName -eq 'MODPRI' }
Assert-Equal $true $modifiedPrimary.cmOptions.EnableBLM 'modified hidden Primary receives authored local options'
Assert-Equal 'example.test' $modifiedPrimary.domain 'modified hidden Primary retains domain provenance'

$script:Inventory = @([pscustomobject]@{
        vmName = 'REMOTEMOD'; role = 'Primary'; siteCode = 'RMD'; state = 'Running'; domain = 'remote.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2403' }
    })
$config = New-TestConfig -EnableBLM $true
Add-ModifiedExistingVMToDeployConfig -VM $script:Inventory[0] -ConfigToModify $config
$remoteModifiedPrimary = $config.virtualMachines | Where-Object { $_.vmName -eq 'REMOTEMOD' }
Assert-Equal $false $remoteModifiedPrimary.cmOptions.EnableBLM 'modified remote Primary keeps its BLM setting'
Assert-Equal 'remote.test' $remoteModifiedPrimary.domain 'modified remote Primary retains remote domain provenance'

$script:Inventory = @([pscustomobject]@{
        vmName = 'REMOTEPRI'; role = 'Primary'; siteCode = 'REM'; state = 'Running'; domain = 'remote.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2403' }
    })
Set-TestVmNote -Name 'REMOTEPRI' -Note ([pscustomobject]@{
        vmName = 'REMOTEPRI'; role = 'Primary'; siteCode = 'REM'; domain = 'remote.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2403' }
    })
$config = New-TestConfig -EnableBLM $true
Add-ExistingVMToDeployConfig -VmName 'REMOTEPRI' -ConfigToModify $config
$remotePrimary = $config.virtualMachines | Where-Object { $_.vmName -eq 'REMOTEPRI' }
Assert-Equal $false $remotePrimary.cmOptions.EnableBLM 'remote standalone Primary keeps its BLM setting'
Assert-Equal '2403' $remotePrimary.cmOptions.Version 'remote standalone Primary keeps its CM version'
$script:SetVmCalls = 0
Sync-AddToExistingCmOptionsNotes -DeployConfig $config
Assert-Equal 0 $script:SetVmCalls 'remote standalone Primary is excluded from local note persistence'

$remoteChildConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'REMOTECHILD'; role = 'Primary'; siteCode = 'RCH'; parentSiteCode = 'RCAS'
            hidden = $true; domain = 'remote.test'
            cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2403' }
        })
}
$script:SetVmCalls = 0
Sync-AddToExistingCmOptionsNotes -DeployConfig $remoteChildConfig
Assert-Equal 0 $script:SetVmCalls 'remote child Primary neither writes nor requires a local CAS lookup'

$script:Inventory = @([pscustomobject]@{
        vmName = 'OPTIONPRI'; role = 'Primary'; siteCode = 'OPT'; state = 'Running'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    })
Set-TestVmNote -Name 'OPTIONPRI' -Note ([pscustomobject]@{
        vmName = 'OPTIONPRI'; role = 'Primary'; siteCode = 'OPT'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    })
$optionOnlyConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
    vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
    virtualMachines = @([pscustomobject]@{ vmName = 'FS1'; role = 'FileServer'; hidden = $false })
}
Assert-Equal $true (Test-AddToExistingCmOptionsChanged -Config $optionOnlyConfig) 'option-only false-to-true change is detected from the persisted note'
Assert-Equal $true (Add-CmOptionsPersistenceTargetForPhase8 -Config $optionOnlyConfig) 'option-only false-to-true change adds a persistence target'
$optionPrimary = $optionOnlyConfig.virtualMachines | Where-Object { $_.vmName -eq 'OPTIONPRI' }
Assert-Equal $true $optionPrimary.cmOptionsChanged 'option-only persistence target is marked for Phase 8'
Assert-Equal $true $optionPrimary.cmOptions.EnableBLM 'option-only persistence target receives authored enable state'
$phase8Data = Get-Phase8ConfigurationData -DeployConfig $optionOnlyConfig
Assert-Equal 'OPTIONPRI' (@($phase8Data.AllNodes | Where-Object { $_.NodeName -ne '*' }).NodeName -join ',') 'option-only change makes Phase 8 applicable when Install is false'

$script:Inventory[0].cmOptions.EnableBLM = $true
Set-TestVmNote -Name 'OPTIONPRI' -Note ([pscustomobject]@{
        vmName = 'OPTIONPRI'; role = 'Primary'; siteCode = 'OPT'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
    })
$optionOnlyConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
    virtualMachines = @([pscustomobject]@{ vmName = 'FS1'; role = 'FileServer'; hidden = $false })
}
Assert-Equal $true (Test-AddToExistingCmOptionsChanged -Config $optionOnlyConfig) 'option-only true-to-false change is detected from the persisted note'
Assert-Equal $true (Add-CmOptionsPersistenceTargetForPhase8 -Config $optionOnlyConfig) 'option-only true-to-false change adds a persistence target'
$optionPrimary = $optionOnlyConfig.virtualMachines | Where-Object { $_.vmName -eq 'OPTIONPRI' }
Assert-Equal $false $optionPrimary.cmOptions.EnableBLM 'option-only persistence target receives authored disable state'
Assert-Equal 'OPTIONPRI' (@((Get-Phase8ConfigurationData -DeployConfig $optionOnlyConfig).AllNodes | Where-Object { $_.NodeName -ne '*' }).NodeName -join ',') 'option-only disable remains applicable to Phase 8'

$sameOptionsConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
    vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
    virtualMachines = @([pscustomobject]@{ vmName = 'FS1'; role = 'FileServer'; hidden = $false })
}
Assert-Equal $false (Test-AddToExistingCmOptionsChanged -Config $sameOptionsConfig) 'unchanged persisted options do not create Phase 8 work'
Assert-Equal $false (Add-CmOptionsPersistenceTargetForPhase8 -Config $sameOptionsConfig) 'unchanged options do not add a hidden Primary'

$script:Inventory = @(
    [pscustomobject]@{
        vmName = 'DC1'; role = 'DC'; domain = 'example.test'; adminName = 'admin'
        domainDefaults = [pscustomobject]@{ CMVersion = '2509' }
    },
    [pscustomobject]@{
        vmName = 'LEGACYPRI'; role = 'Primary'; siteCode = 'LEG'; state = 'Running'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    }
)
Set-TestVmNote -Name 'LEGACYPRI' -Note ([pscustomobject]@{
        vmName = 'LEGACYPRI'; role = 'Primary'; siteCode = 'LEG'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    })
$domainlessConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
    vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
    virtualMachines = @([pscustomobject]@{ vmName = 'FS1'; role = 'FileServer'; hidden = $false })
}
$domainFilteredPrimaries = @(Get-List -Type VM -DomainName 'example.test' | Where-Object { $_.role -eq 'Primary' })
Assert-Equal 0 $domainFilteredPrimaries.Count 'production-faithful domain filter excludes legacy domainless Primary'
$domainlessReconstructed = New-UserConfig -Domain 'example.test' -Subnet '192.168.1.0'
Assert-Equal 'LEGACYPRI' $domainlessReconstructed.cmOptionsOwnerVM 'existing-domain reconstruction records legacy domainless Primary owner'
Assert-Equal $true (Test-AddToExistingCmOptionsChanged -Config $domainlessConfig) 'host-wide divergence detection includes legacy domainless Primary'
Assert-Equal $true (Add-CmOptionsPersistenceTargetForPhase8 -Config $domainlessConfig) 'legacy domainless Primary becomes the option-only Phase 8 target'
Assert-Equal 'LEGACYPRI' (@((Get-Phase8ConfigurationData -DeployConfig $domainlessConfig).AllNodes | Where-Object { $_.NodeName -ne '*' }).NodeName -join ',') 'legacy domainless option change remains applicable to Phase 8'

$script:Inventory = @([pscustomobject]@{
        vmName = 'LEGACYCAS'; role = 'CAS'; siteCode = 'LCAS'; state = 'Running'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
Set-TestVmNote -Name 'LEGACYCAS' -Note ([pscustomobject]@{
        vmName = 'LEGACYCAS'; role = 'CAS'; siteCode = 'LCAS'; customMarker = 'legacy-cas'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
$domainlessChildConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    cmOptionsOwnerVM = 'LEGACYCAS'
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'LEGACYCHILD'; role = 'Primary'; siteCode = 'LPRI'; parentSiteCode = 'LCAS'; hidden = $true
            cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }; cmOptionsChanged = $true
        })
}
$script:SetVmCalls = 0
Sync-AddToExistingCmOptionsNotes -DeployConfig $domainlessChildConfig
Assert-Equal 1 $script:SetVmCalls 'domainless parent CAS is found through host-wide persistence fallback'
Assert-Equal $true (Get-VMNote -VMName 'LEGACYCAS').cmOptions.EnableBLM 'domainless parent CAS receives effective BLM state'
Assert-Equal 'legacy-cas' (Get-VMNote -VMName 'LEGACYCAS').customMarker 'domainless parent CAS note merge preserves unrelated fields'

$script:Inventory = @(
    [pscustomobject]@{
        vmName = 'LEGACYOTHER'; role = 'Primary'; siteCode = 'OLD'; state = 'Running'
        cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
    },
    [pscustomobject]@{
        vmName = 'EXACTPRI'; role = 'Primary'; siteCode = 'EXA'; state = 'Running'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    }
)
Set-TestVmNote -Name 'LEGACYOTHER' -Note ([pscustomobject]@{
        vmName = 'LEGACYOTHER'; role = 'Primary'; siteCode = 'OLD'
        cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
    })
Set-TestVmNote -Name 'EXACTPRI' -Note ([pscustomobject]@{
        vmName = 'EXACTPRI'; role = 'Primary'; siteCode = 'EXA'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    })
$preferredDomainConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
    cmOptionsOwnerVM = 'EXACTPRI'
    vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
    virtualMachines = @([pscustomobject]@{ vmName = 'FS1'; role = 'FileServer'; hidden = $false })
}
Assert-Equal $true (Test-AddToExistingCmOptionsChanged -Config $preferredDomainConfig) 'explicit-domain Primary wins over an earlier matching domainless note'
Assert-Equal $true (Add-CmOptionsPersistenceTargetForPhase8 -Config $preferredDomainConfig) 'explicit-domain Primary is selected as the Phase 8 target'
Assert-Equal 'EXACTPRI' (($preferredDomainConfig.virtualMachines | Where-Object { $_.cmOptionsChanged }).vmName -join ',') 'domainless Primary is only a fallback target'

$script:Inventory = @(
    [pscustomobject]@{ vmName = 'LEGACYCAS2'; role = 'CAS'; siteCode = 'PCAS'; state = 'Running' },
    [pscustomobject]@{ vmName = 'EXACTCAS'; role = 'CAS'; siteCode = 'PCAS'; state = 'Running'; domain = 'example.test' }
)
Set-TestVmNote -Name 'LEGACYCAS2' -Note ([pscustomobject]@{
        vmName = 'LEGACYCAS2'; role = 'CAS'; siteCode = 'PCAS'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
Set-TestVmNote -Name 'EXACTCAS' -Note ([pscustomobject]@{
        vmName = 'EXACTCAS'; role = 'CAS'; siteCode = 'PCAS'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
$preferredCasConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    cmOptionsOwnerVM = 'EXACTCAS'
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'LOCALCHILD'; role = 'Primary'; siteCode = 'LCL'; parentSiteCode = 'PCAS'
            hidden = $true; domain = 'example.test'
            cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }; cmOptionsChanged = $true
        })
}
$script:SetVmCalls = 0
Sync-AddToExistingCmOptionsNotes -DeployConfig $preferredCasConfig
Assert-Equal $true (Get-VMNote -VMName 'EXACTCAS').cmOptions.EnableBLM 'explicit-domain CAS wins over domainless CAS fallback'
Assert-Equal $false (Get-VMNote -VMName 'LEGACYCAS2').cmOptions.EnableBLM 'domainless CAS remains unchanged when exact domain CAS exists'

function Invoke-MultiHierarchyOwnerCase {
    param ([switch] $ReverseInventory)

    $dc = [pscustomobject]@{
        vmName = 'DC1'; role = 'DC'; domain = 'example.test'; adminName = 'admin'
        domainDefaults = [pscustomobject]@{ CMVersion = '2509' }
    }
    $standalone = [pscustomobject]@{
        vmName = 'A-STANDALONE'; role = 'Primary'; siteCode = 'STA'; state = 'Running'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    }
    $cas = [pscustomobject]@{
        vmName = 'B-CAS'; role = 'CAS'; siteCode = 'CAS'; state = 'Running'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    }
    $child = [pscustomobject]@{
        vmName = 'B-PRIMARY'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'; state = 'Running'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    }
    $domainlessChild = [pscustomobject]@{
        vmName = 'B-PRIMARY2'; role = 'Primary'; siteCode = 'PRI2'; parentSiteCode = 'CAS'; state = 'Running'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
    }
    $orderedSites = if ($ReverseInventory) { @($domainlessChild, $child, $cas, $standalone) } else { @($standalone, $cas, $child, $domainlessChild) }
    $script:Inventory = @($dc) + $orderedSites
    foreach ($site in @($standalone, $cas, $child, $domainlessChild)) {
        Set-TestVmNote -Name $site.vmName -Note ([pscustomobject]@{
                vmName = $site.vmName; role = $site.role; siteCode = $site.siteCode
                parentSiteCode = $site.parentSiteCode; domain = 'example.test'; cmOptions = $site.cmOptions
            })
    }

    $config = New-UserConfig -Domain 'example.test' -Subnet '192.168.1.0'
    $orderLabel = if ($ReverseInventory) { 'reversed inventory' } else { 'standalone-first inventory' }
    Assert-Equal 'B-CAS' $config.cmOptionsOwnerVM "existing-domain reconstruction selects CAS owner with $orderLabel"
    Assert-Equal $false $config.cmOptions.EnableBLM "root options come from the recorded CAS with $orderLabel"
    $deployConfig = ConvertTo-DeployConfigEx -DeployConfig $config
    Assert-Equal 'B-CAS' $deployConfig.cmOptionsOwnerVM "real deploy conversion preserves hierarchy owner with $orderLabel"

    $config.cmOptions.EnableBLM = $true
    $config.virtualMachines = @([pscustomobject]@{ vmName = 'FS1'; role = 'FileServer'; hidden = $false })
    Assert-Equal $true (Add-CmOptionsPersistenceTargetForPhase8 -Config $config) "CAS option change adds hierarchy target with $orderLabel"
    $marked = @($config.virtualMachines | Where-Object { $_.cmOptionsChanged } | ForEach-Object { $_.vmName }) -join ','
    Assert-Equal 'B-PRIMARY,B-PRIMARY2' $marked "all exact/domainless CAS child Primaries are marked with $orderLabel"
    $phaseNodes = @((Get-Phase8ConfigurationData -DeployConfig $config).AllNodes | Where-Object { $_.NodeName -ne '*' } | ForEach-Object { $_.NodeName }) -join ','
    Assert-Equal 'B-PRIMARY,B-PRIMARY2' $phaseNodes "Phase 8 runs every selected CAS child with $orderLabel"

    $script:SetVmCalls = 0
    Sync-AddToExistingCmOptionsNotes -DeployConfig $config
    Assert-Equal 1 $script:SetVmCalls "selected hierarchy persists one canonical note with $orderLabel"
    Assert-Equal $true (Get-VMNote -VMName 'B-CAS').cmOptions.EnableBLM "CAS owner note is updated with $orderLabel"
    Assert-Equal $false (Get-VMNote -VMName 'A-STANDALONE').cmOptions.EnableBLM "standalone sibling remains unchanged with $orderLabel"

    $membershipConfig = [pscustomobject]@{
        cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
        cmOptionsOwnerVM = 'B-CAS'
        vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
        parameters = [pscustomobject]@{ ExistingDCName = $null }
        virtualMachines = @([pscustomobject]@{
                vmName = 'CLIENT2'; role = 'DomainMember'; hidden = $false
                BitLocker = $true; pushClient = $false
            })
    }
    Add-ExistingVMsToDeployConfig -Config $membershipConfig
    $blmTargets = @($membershipConfig.virtualMachines | Where-Object { $_.blmHierarchyTarget } | ForEach-Object { $_.vmName }) -join ','
    Assert-Equal 'B-PRIMARY,B-PRIMARY2' $blmTargets "unchanged BLM routes membership to all owner children with $orderLabel"
    $membershipNodes = @((Get-Phase8ConfigurationData -DeployConfig $membershipConfig).AllNodes | Where-Object { $_.NodeName -ne '*' } | ForEach-Object { $_.NodeName }) -join ','
    Assert-Equal 'B-PRIMARY,B-PRIMARY2' $membershipNodes "unchanged BLM dispatches all owner children with $orderLabel"

    if (-not $ReverseInventory) {
        Set-TestVmNote -Name 'B-CAS' -Note ([pscustomobject]@{
            vmName = 'B-CAS'; role = 'CAS'; siteCode = 'CAS'; domain = 'example.test'
            cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509'; Install = $false }
            })
        $unionConfig = [pscustomobject]@{
            cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509'; Install = $false }
            cmOptionsOwnerVM = 'B-CAS'
            vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
            parameters = [pscustomobject]@{ ExistingDCName = $null }
            virtualMachines = @([pscustomobject]@{
                    vmName = 'PUSHCLIENT'; role = 'DomainMember'; hidden = $false
                    BitLocker = $false; pushClient = 'STA'
                })
        }
        Add-ExistingVMsToDeployConfig -Config $unionConfig
        $unionNodes = @((Get-Phase8ConfigurationData -DeployConfig $unionConfig).AllNodes | Where-Object { $_.NodeName -ne '*' } | ForEach-Object { $_.NodeName } | Sort-Object) -join ','
        Assert-Equal 'A-STANDALONE,B-PRIMARY,B-PRIMARY2' $unionNodes 'Phase 8 preserves the union of option and separate client-push targets'
    }
}

Invoke-MultiHierarchyOwnerCase
Invoke-MultiHierarchyOwnerCase -ReverseInventory

$script:Inventory = @(
    [pscustomobject]@{ vmName = 'B-CAS'; role = 'CAS'; siteCode = 'CAS'; domain = 'example.test' },
    [pscustomobject]@{ vmName = 'A-STANDALONE'; role = 'Primary'; siteCode = 'STA'; domain = 'example.test' }
)
$ambiguousConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @()
}
Assert-Throws { Get-AddToExistingCmOptionsOwner -Config $ambiguousConfig } '*ambiguous*B-CAS*A-STANDALONE*' 'ownerless multi-hierarchy configuration fails explicitly'

$script:Inventory = @(
    [pscustomobject]@{ vmName = 'DC1'; role = 'DC'; domain = 'example.test'; adminName = 'admin'; domainDefaults = [pscustomobject]@{ CMVersion = '2509' } },
    [pscustomobject]@{ vmName = 'CAS-NONOTE'; role = 'CAS'; siteCode = 'CAS'; domain = 'example.test' },
    [pscustomobject]@{ vmName = 'STANDALONE-NOTE'; role = 'Primary'; siteCode = 'STD'; domain = 'example.test'; cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' } }
)
$casWithoutNoteConfig = New-UserConfig -Domain 'example.test' -Subnet '192.168.1.0'
Assert-Equal 'CAS-NONOTE' $casWithoutNoteConfig.cmOptionsOwnerVM 'owner selection prefers canonical CAS before inspecting cmOptions presence'
Assert-Equal $false $casWithoutNoteConfig.cmOptions.EnableBLM 'missing CAS options are synthesized instead of borrowing standalone options'

$localOwner = [pscustomobject]@{ vmName = 'LOCALCAS'; role = 'CAS'; siteCode = 'COL'; domain = 'example.test' }
$remoteCollision = [pscustomobject]@{
    vmName = 'REMOTEPRI'; role = 'Primary'; siteCode = 'COL'; parentSiteCode = 'COL'; hidden = $true; domain = 'remote.test'
    cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2403' }
}
$remoteCollisionConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    cmOptionsOwnerVM = 'LOCALCAS'
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @($remoteCollision)
}
Assert-Equal $false (Test-CmOptionsOwnerContainsVM -Config $remoteCollisionConfig -Owner $localOwner -VM $remoteCollision) 'explicit remote VM is outside owner hierarchy despite colliding site codes'
$script:Inventory = @($localOwner, $remoteCollision)
Set-AddToExistingCmOptionsOnHiddenSiteRole -Config $remoteCollisionConfig -VM $remoteCollision
Assert-Equal $false $remoteCollision.cmOptions.EnableBLM 'remote colliding-site VM does not receive local options'

$migrationConfig = [pscustomobject]@{
    cmOptions       = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'PS1SITE'; role = 'Primary'; siteCode = 'PS1'; hidden = $true
            cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
        })
}
Move-CmOptionsToTopLevelSiteServer -Config $migrationConfig
Assert-Equal $true ($null -ne $migrationConfig.cmOptions) 'root intent is retained when only hidden site inventory exists'
Assert-Equal $false $migrationConfig.virtualMachines[0].cmOptions.EnableBLM 'root migration does not overwrite hidden deployed state prematurely'

$script:Inventory = @([pscustomobject]@{
        vmName = 'CAS1'; role = 'CAS'; siteCode = 'CAS'; state = 'Running'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
Set-TestVmNote -Name 'CAS1' -Note ([pscustomobject]@{
        vmName = 'CAS1'; role = 'CAS'; siteCode = 'CAS'; customMarker = 'keep'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
$sourcePrimary = [pscustomobject]@{
    vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'; hidden = $true
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }; cmOptionsChanged = $true
}
$deployConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    cmOptionsOwnerVM = 'CAS1'
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @(
        $sourcePrimary,
        [pscustomobject]@{
            vmName = 'PRI2'; role = 'Primary'; siteCode = 'PRI2'; parentSiteCode = 'CAS'; hidden = $true
            cmOptions = [pscustomobject][ordered]@{ Version = '2509'; EnableBLM = $true }; cmOptionsChanged = $true
        }
    )
}
$script:SetVmCalls = 0
Sync-AddToExistingCmOptionsNotes -DeployConfig $deployConfig
$persistedCas = Get-VMNote -VMName 'CAS1'
Assert-Equal 1 $script:SetVmCalls 'reordered equivalent child options deduplicate to one canonical CAS note write'
Assert-Equal $true $persistedCas.cmOptions.EnableBLM 'parent CAS receives enabled BLM state'
Assert-Equal 'keep' $persistedCas.customMarker 'canonical note merge preserves unrelated properties'

$conflictingConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    cmOptionsOwnerVM = 'CAS1'
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @(
        $sourcePrimary,
        [pscustomobject]@{
            vmName = 'PRI2'; role = 'Primary'; siteCode = 'PRI2'; parentSiteCode = 'CAS'; hidden = $true
            cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }; cmOptionsChanged = $true
        }
    )
}
Assert-Throws { Sync-AddToExistingCmOptionsNotes -DeployConfig $conflictingConfig } '*Conflicting cmOptions*PRI2*' 'conflicting child Primary options fail before canonical persistence'

$script:Inventory = @([pscustomobject]@{
        vmName = 'STANDALONE'; role = 'Primary'; siteCode = 'STD'; state = 'Running'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
Set-TestVmNote -Name 'STANDALONE' -Note ([pscustomobject]@{
        vmName = 'STANDALONE'; role = 'Primary'; siteCode = 'STD'; customMarker = 'standalone'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
$standaloneConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    cmOptionsOwnerVM = 'STANDALONE'
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'STANDALONE'; role = 'Primary'; siteCode = 'STD'; hidden = $true
            cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }; cmOptionsChanged = $true
        })
}
$script:SetVmCalls = 0
Sync-AddToExistingCmOptionsNotes -DeployConfig $standaloneConfig
Assert-Equal 1 $script:SetVmCalls 'hidden standalone Primary persists through the host Phase 8 path'
Assert-Equal $true (Get-VMNote -VMName 'STANDALONE').cmOptions.EnableBLM 'standalone Primary note receives enabled BLM state'
Assert-Equal 'standalone' (Get-VMNote -VMName 'STANDALONE').customMarker 'standalone note merge preserves unrelated properties'

$missingCasConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }
    cmOptionsOwnerVM = 'MISSINGCAS'
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'ORPHANPRI'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'MISSING'; hidden = $true
            cmOptions = [pscustomobject]@{ EnableBLM = $true; Version = '2509' }; cmOptionsChanged = $true
        })
}
$script:Inventory = @()
Assert-Throws { Sync-AddToExistingCmOptionsNotes -DeployConfig $missingCasConfig } '*owner*MISSINGCAS*not found*' 'missing hierarchy owner fails persistence'

$script:Inventory = @([pscustomobject]@{
        vmName = 'STANDALONE'; role = 'Primary'; siteCode = 'STD'; state = 'Running'; domain = 'example.test'
        cmOptions = [pscustomobject]@{ EnableBLM = $false; Version = '2509' }
    })
$standaloneConfig.cmOptions.EnableBLM = $false
$standaloneConfig.virtualMachines[0].cmOptions.EnableBLM = $false
$script:SetVmShouldThrow = $true
Assert-Throws { Sync-AddToExistingCmOptionsNotes -DeployConfig $standaloneConfig } '*simulated VM-note write failure*' 'VM-note write failure escapes to the phase boundary'
$script:SetVmShouldThrow = $false
$script:SetVmIgnoreWrite = $true
Assert-Throws { Sync-AddToExistingCmOptionsNotes -DeployConfig $standaloneConfig } '*verification failed*STANDALONE*' 'unchanged Hyper-V note fails readback verification'
$script:SetVmIgnoreWrite = $false

$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
$phaseErrors = $null
$phaseTokens = $null
$phasesAst = [Management.Automation.Language.Parser]::ParseFile($phasesPath, [ref]$phaseTokens, [ref]$phaseErrors)
if ($phaseErrors.Count -ne 0) { throw "$phasesPath has $($phaseErrors.Count) parse error(s)" }
$startPhase = @($phasesAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-Phase'
        }, $true))
$syncCalls = @($startPhase[0].Body.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Sync-AddToExistingCmOptionsNotes'
        }, $true))
Assert-Equal 1 $syncCalls.Count 'Start-Phase owns one canonical persistence call'
$startPhaseText = $startPhase[0].Extent.Text
Assert-Equal $true ($startPhaseText -match '(?s)if \(\$Phase -eq 8 -and \$result\.Failed -eq 0\).*?Sync-AddToExistingCmOptionsNotes.*?catch.*?\$result\.Failed\+\+') 'Phase 8 write failure changes the phase verdict'

$script:CmDismountCalls = 0
function Sync-CmSetupProxyClients { return $true }
function Invoke-Phase8PreInstallSnapshot {}
function Mount-CmIsoForPhase {}
function Dismount-CmIsoForPhase { $script:CmDismountCalls++ }
function Start-PhaseJobs {
    return [pscustomobject]@{
        Applicable      = $true
        PreflightFailed = $false
        Jobs            = @()
        AdditionalData  = $null
        Success         = 1
        Failed          = 0
    }
}
function Wait-Phase {
    return [pscustomobject]@{
        Success = 1
        Warning = 0
        Failed  = 0
        Crashed = $false
        Elapsed = [timespan]::FromSeconds(1)
    }
}
function Resolve-WaitPhaseResult { param ($Raw, $Phase); return $Raw }
function Write-OrangePoint {}
function Write-RedX {}
. ([scriptblock]::Create($startPhase[0].Extent.Text))

$global:BuildStats = $null
$script:SetVmIgnoreWrite = $false
$script:SetVmShouldThrow = $true
$script:CmDismountCalls = 0
$phaseFailureResult = @(Start-Phase -Phase 8 -DeployConfig $standaloneConfig)
Assert-Equal 1 $phaseFailureResult.Count 'Phase 8 persistence failure returns one verdict'
Assert-Equal $false $phaseFailureResult[0] 'Phase 8 persistence failure returns false'
Assert-Equal 0 $script:CmDismountCalls 'failed persistence suppresses success-only CM media dismount'

$script:SetVmShouldThrow = $false
$script:CmDismountCalls = 0
$phaseSuccessResult = @(Start-Phase -Phase 8 -DeployConfig $standaloneConfig)
Assert-Equal 1 $phaseSuccessResult.Count 'successful Phase 8 returns one verdict'
Assert-Equal $true $phaseSuccessResult[0] 'successful Phase 8 returns true'
Assert-Equal 1 $script:CmDismountCalls 'successful persistence allows one CM media dismount'

$commonText = Get-Content -LiteralPath $commonPath -Raw
Assert-Equal 0 ([regex]::Matches($commonText, 'Sync-AddToExistingCmOptionsNotes')).Count 'hidden persistence is not trapped behind New-VmNote gating'

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAIL: $script:Failures assertion(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host 'PASS: add-to-existing ConfigMgr options override stale hidden VM notes.' -ForegroundColor Green
exit 0
