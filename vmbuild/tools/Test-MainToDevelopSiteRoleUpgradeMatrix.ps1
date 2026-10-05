<#
.SYNOPSIS
    Verifies exact-main ConfigMgr role upgrades use develop repair and validation safeguards.
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
$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$phase7Path = Join-Path $RootPath 'DSC\phases\Phase7.ps1'

function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) { throw "Expected one $Name definition, found $($functions.Count)." }
    $functionErrors = @($errors | Where-Object {
            $_.Extent.StartOffset -ge $functions[0].Extent.StartOffset -and
            $_.Extent.EndOffset -le $functions[0].Extent.EndOffset
        })
    if ($functionErrors.Count) { throw "$Name has parse errors: $($functionErrors -join '; ')" }
    [scriptblock]::Create($functions[0].Extent.Text)
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ThrowsLike {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -like $Pattern) { return }
        throw "$Message`nExpected: $Pattern`nActual:   $($_.Exception.Message)"
    }
    throw "$Message`nExpected an exception matching: $Pattern"
}

function Write-Log {
    param([string]$Message, [switch]$Verbose, [switch]$LogOnly, [switch]$Warning)
}
$script:StartedVms = [System.Collections.Generic.List[string]]::new()
function Start-VM2 {
    param([string]$Name)
    $script:StartedVms.Add($Name)
}
function Set-VMNote { param([string]$VmName, [object]$VmNote) }
function Get-VMNote {
    param([string]$VMName)
    return $script:Inventory | Where-Object { $_.vmName -ieq $VMName } | Select-Object -First 1
}

. (Import-TestFunction -Path $configPath -Name 'Get-ExistingConfigMgrRoleUpgradePlan')
. (Import-TestFunction -Path $configPath -Name 'Add-ModifiedExistingVMToDeployConfig')
. (Import-TestFunction -Path $configPath -Name 'Add-ExistingVMToDeployConfig')
. (Import-TestFunction -Path $configPath -Name 'Add-ExistingVMsToDeployConfig')
. (Import-TestFunction -Path $configPath -Name 'Add-Phase11HierarchyParentsToDeployConfig')
. (Import-TestFunction -Path $configPath -Name 'Sync-ExistingHierarchyOptionsToDeployConfig')
. (Import-TestFunction -Path $phasesPath -Name 'Test-MemLabsIncludeHiddenVmForPhase')
. (Import-TestFunction -Path $validationPath -Name 'Get-Phase11ProjectedVmNetwork')
. (Import-TestFunction -Path $phase7Path -Name 'Test-MemLabsSupSyncsFromMicrosoftUpdate')

$mainCommon = @(git -C $repoRoot show "${MainRevision}:vmbuild/Common.ps1")
if ($LASTEXITCODE -ne 0 -or $mainCommon.Count -eq 0) { throw "Could not read exact-main Common.ps1 from $MainRevision." }
$mainText = $mainCommon -join "`n"
foreach ($roleProperty in @('InstallDP', 'InstallMP', 'InstallSUP', 'InstallRP')) {
    Assert-True ($mainText -match [regex]::Escape($roleProperty)) `
        "Exact main did not expose expected existing-VM mutation '$roleProperty'."
}

$pkiOptions = [pscustomobject]@{
    EnablePKI = $true
    IssuingCAVM = 'DC1'
    UseOfflineRoot = $false
    OfflineRootCAVM = ''
}
$cmOptions = [pscustomobject]@{
    Version = '2403'
    Install = $true
    PrePopulateObjects = $true
    UsePKI = $true
}
$existing = @(
    [pscustomobject]@{
        vmName = 'DC1'; role = 'DC'; domain = 'upgrade.test'; InstallCA = $true
        pkiOptions = $pkiOptions; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'PRI1'; role = 'Primary'; domain = 'upgrade.test'; siteCode = 'PRI'
        network = '10.20.1.0'; cmOptions = $cmOptions; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'DP1'; role = 'SiteSystem'; domain = 'upgrade.test'; siteCode = 'PRI'
        network = '10.20.2.0'; installDP = $true; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'MP1'; role = 'SiteSystem'; domain = 'upgrade.test'; siteCode = 'PRI'
        network = '10.20.3.0'; installMP = $true; useDatabaseReplica = $true
        replicaSqlServerVM = 'SQL2'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'SUP1'; role = 'SiteSystem'; domain = 'upgrade.test'; siteCode = 'PRI'
        network = '10.20.4.0'; installSUP = $true; wsusDataBaseServer = 'SQL1'
        useProxy = $true; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'RP1'; role = 'SiteSystem'; domain = 'upgrade.test'; siteCode = 'PRI'
        network = '10.20.5.0'; installRP = $true; remoteSQLVM = 'SQL1'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'SQL1'; role = 'DomainMember'; domain = 'upgrade.test'
        sqlVersion = '2022'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'SQL2'; role = 'DomainMember'; domain = 'upgrade.test'
        sqlVersion = '2022'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'PROXY1'; role = 'Proxy'; domain = 'upgrade.test'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'OTHERDP'; role = 'SiteSystem'; domain = 'upgrade.test'; siteCode = 'OTH'
        network = '10.30.2.0'; installDP = $true; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'FOREIGNDP'; role = 'SiteSystem'; domain = 'foreign.test'; siteCode = 'PRI'
        network = '10.20.2.0'; installDP = $true; state = 'Running'
    }
)
$script:Inventory = @($existing)
function Get-List {
    param([string]$Type, [string]$DomainName, [switch]$SmartUpdate)
    $global:vm_List_LastUpdate = Get-Date
    $global:vm_List_Dirty = $false
    return @($script:Inventory)
}
function Test-PushClientRequested {
    param([object]$Vm)
    return $Vm.pushClient -eq $true -or ($Vm.pushClient -is [string] -and $Vm.pushClient)
}
function Get-ExistingForDomain {
    param([string]$DomainName, [string]$Role)
    if ($Role -eq 'Primary') { return 'PRI1' }
    if ($Role -eq 'Proxy') { return 'PROXY1' }
    return $null
}
function Get-PrimarySiteServerForSiteCode {
    param([object]$DeployConfig, [string]$SiteCode, [string]$Type, [switch]$SmartUpdate)
    return $script:Inventory | Where-Object { $_.role -eq 'Primary' -and $_.siteCode -eq $SiteCode } | Select-Object -First 1
}
function Get-SiteServerForSiteCode {
    param([object]$DeployConfig, [string]$SiteCode, [string]$Type, [switch]$SmartUpdate)
    return $script:Inventory | Where-Object {
        $_.role -in @('CAS', 'Primary', 'Secondary') -and $_.siteCode -eq $SiteCode
    } | Select-Object -First 1
}
function Get-VMFromList2 { param([object]$DeployConfig, [string]$VmName, [switch]$SmartUpdate) return $null }
function Add-RemoteSQLVMToDeployConfig {
    param([string]$VmName, [object]$ConfigToModify, [bool]$Hidden = $true)
    Add-ExistingVMToDeployConfig -VmName $VmName -ConfigToModify $ConfigToModify -Hidden $Hidden
}
function Add-Phase8DistributionPointMetadata {
    param([object]$Config, [object[]]$ExistingVMs, [bool]$InventoryRefreshVerified)
}

$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'upgrade.test'; network = '10.20.1.0' }
    cmOptions = [pscustomobject]@{ Version = '2509'; Install = $true; UsePKI = $false }
    pkiOptions = [pscustomobject]@{ EnablePKI = $false; IssuingCAVM = ''; UseOfflineRoot = $false; OfflineRootCAVM = '' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'NEWROLE'; role = 'SiteSystem'; siteCode = 'PRI'; network = '10.20.6.0'
            installDP = $true; installMP = $true; installSUP = $true; installRP = $true
        }
    )
}

$plan = Get-ExistingConfigMgrRoleUpgradePlan -Config $config -ExistingVMs $existing
Assert-Equal 'PRI1' (@($plan.OwnerSiteVmNames) -join ',') `
    'Role upgrade did not select the authoritative Primary for repair and validation.'
Assert-Equal 'DP1,MP1,RP1,SUP1' (@($plan.ExistingRoleVmNames | Sort-Object) -join ',') `
    'Role upgrade did not include every existing main-era explicit site role in the owner site.'
Assert-True ('OTHERDP' -notin $plan.ExistingRoleVmNames) 'Another site leaked into the role repair plan.'
Assert-True ('FOREIGNDP' -notin $plan.ExistingRoleVmNames) 'Another domain leaked into the role repair plan.'

$applyConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'upgrade.test'; network = '10.20.1.0' }
    parameters = [pscustomobject]@{ ExistingDCName = $null }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'NEWROLE'; role = 'SiteSystem'; siteCode = 'PRI'; network = '10.20.6.0'
            installDP = $true; installMP = $true; installSUP = $true; installRP = $true
        }
    )
}
Add-ExistingVMsToDeployConfig -Config $applyConfig
Assert-Equal 'DP1,MP1,NEWROLE,PRI1,PROXY1,RP1,SQL1,SQL2,SUP1' `
    (@($applyConfig.virtualMachines.vmName | Sort-Object) -join ',') `
    'Deploy expansion did not apply the complete owner-site repair plan, proxy, and SQL dependencies.'
foreach ($validationName in @('PRI1', 'DP1', 'MP1', 'SUP1', 'RP1')) {
    $validationVm = $applyConfig.virtualMachines | Where-Object vmName -eq $validationName | Select-Object -First 1
    Assert-Equal $true ([bool]$validationVm.phase11Validate) `
        "Repair target '$validationName' was not scheduled for Phase 11 validation."
    Assert-Equal $true ([bool]$validationVm.cmOptions.UsePKI) `
        "Repair target '$validationName' did not inherit the owner hierarchy's PKI mode."
}
Assert-True ('OTHERDP' -notin $applyConfig.virtualMachines.vmName) `
    'Deploy expansion added a role host owned by another site.'
Assert-True ('FOREIGNDP' -notin $applyConfig.virtualMachines.vmName) `
    'Deploy expansion added a role host owned by another domain.'

$pushConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'upgrade.test'; network = '10.20.1.0' }
    parameters = [pscustomobject]@{ ExistingDCName = $null }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'CLIENT2'; role = 'DomainMember'; network = '10.20.7.0'
            pushClient = 'PRI'
        }
    )
}
Add-ExistingVMsToDeployConfig -Config $pushConfig
$pushOwner = $pushConfig.virtualMachines | Where-Object vmName -eq 'PRI1' | Select-Object -First 1
Assert-Equal $true ([bool]$pushOwner.phase11Validate) `
    'Hidden Primary repairing a new cross-subnet client boundary was not scheduled for Phase 11.'

$null = Sync-ExistingHierarchyOptionsToDeployConfig -Config $config -ExistingVMs $existing
Assert-Equal $true ([bool]$config.virtualMachines[0].cmOptions.UsePKI) `
    'New develop role host did not inherit exact-main hierarchy PKI mode.'
Assert-Equal $true ([bool]$config.pkiOptions.EnablePKI) `
    'Develop did not restore PKI deployment metadata for the main-era hierarchy.'
Assert-Equal 'DC1' "$($config.pkiOptions.IssuingCAVM)" `
    'Develop did not retain the main-era issuing CA reference.'

$modifiedDp = [pscustomobject]@{
    vmName = 'DP1'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true
    installMP = $true; ExistingVM = $true; state = 'Running'
    phase11Validate = $false; osdValidate = $true; osdMetadataOnly = $true
}
$mergeConfig = [pscustomobject]@{
    virtualMachines = @([pscustomobject]@{
            vmName = 'DP1'; role = 'SiteSystem'; siteCode = 'PRI'; hidden = $true
            thisParams = [pscustomobject]@{ Stale = $true }
        })
}
Add-ModifiedExistingVMToDeployConfig -Vm $modifiedDp -ConfigToModify $mergeConfig -Hidden $true
$mergedDp = $mergeConfig.virtualMachines[0]
Assert-Equal $true ([bool]$mergedDp.phase11Validate) `
    'Modified main-era role host was not scheduled for Phase 11 validation.'
Assert-Equal $true ([bool]$mergedDp.ExistingVM) `
    'Modified main-era role host lost its per-run existing-VM mutation marker.'
Assert-True ($null -eq $mergedDp.PSObject.Properties['osdValidate']) `
    'Stale OSD validation metadata leaked from a VM note into the upgraded config.'
Assert-True ($null -eq $mergedDp.PSObject.Properties['osdMetadataOnly']) `
    'Stale OSD metadata-only state leaked from a VM note into the upgraded config.'

Assert-Equal $false (Test-MemLabsIncludeHiddenVmForPhase -Vm $mergedDp -Phase 1) `
    'Modified existing VM would be rebuilt in Phase 1.'
Assert-Equal $true (Test-MemLabsIncludeHiddenVmForPhase -Vm $mergedDp -Phase 8) `
    'Modified existing role host was excluded from its idempotent repair phase.'
Assert-Equal $false (Test-MemLabsIncludeHiddenVmForPhase -Vm $mergedDp -Phase 10) `
    'Modified existing VM would receive Phase 10 mutation work.'
Assert-Equal $true (Test-MemLabsIncludeHiddenVmForPhase -Vm $mergedDp -Phase 11) `
    'Modified existing role host was excluded from read-only Phase 11 validation.'
Assert-Equal $false (Test-MemLabsIncludeHiddenVmForPhase -Vm ([pscustomobject]@{ hidden = $true }) -Phase 11) `
    'Unmodified hidden dependency was unexpectedly included in Phase 11.'
Assert-Equal $true (Test-MemLabsIncludeHiddenVmForPhase -Vm ([pscustomobject]@{ hidden = $true; osdValidate = $true }) -Phase 11) `
    'Existing OSD validation exception regressed.'

$parentCas = [pscustomobject]@{
    vmName = 'CAS1'; role = 'CAS'; siteCode = 'CAS'; domain = 'upgrade.test'
    cmOptions = [pscustomobject]@{ Version = '2403'; UsePKI = $true }; state = 'Off'
}
$childValidationConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'upgrade.test' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'CHD1'; role = 'Primary'; siteCode = 'CHD'; parentSiteCode = 'CAS'
            hidden = $true; phase11Validate = $true
        }
    )
}
$savedInventory = @($script:Inventory)
$script:Inventory = @($parentCas)
$script:StartedVms.Clear()
$supportParents = @(Add-Phase11HierarchyParentsToDeployConfig -Config $childValidationConfig `
        -ExistingVMs @($parentCas))
$script:Inventory = @($savedInventory)
Assert-Equal 'CAS1' ($supportParents -join ',') `
    'Child Primary Phase 11 validation did not hydrate its parent CAS support dependency.'
$supportCas = $childValidationConfig.virtualMachines | Where-Object vmName -eq 'CAS1' | Select-Object -First 1
Assert-Equal $true ([bool]$supportCas.hidden) 'Parent CAS support dependency is not hidden.'
Assert-Equal $true ([bool]$supportCas.phase11Validate) `
    'Parent CAS support dependency was not scheduled for Phase 11.'
Assert-Equal 'CAS1' (@($script:StartedVms) -join ',') `
    'Powered-off parent CAS was not started as a hierarchy support dependency.'
foreach ($phase in @(0, 2, 3, 4, 5, 6, 7, 8, 9, 11)) {
    Assert-Equal $true (Test-MemLabsIncludeHiddenVmForPhase -Vm $supportCas -Phase $phase) `
        "Parent CAS support dependency was excluded from Phase $phase."
}
foreach ($phase in @(1, 10)) {
    Assert-Equal $false (Test-MemLabsIncludeHiddenVmForPhase -Vm $supportCas -Phase $phase) `
        "Parent CAS support dependency violated hidden-VM safety in Phase $phase."
}
Assert-Equal 'CAS1,CHD1' (@($childValidationConfig.virtualMachines.vmName | Sort-Object) -join ',') `
    'Hierarchy parent hydration did not preserve the complete deployConfig support snapshot.'
$script:Inventory = @($parentCas)
$secondSupportPass = @(Add-Phase11HierarchyParentsToDeployConfig -Config $childValidationConfig `
        -ExistingVMs @($parentCas))
$script:Inventory = @($savedInventory)
Assert-Equal 0 $secondSupportPass.Count `
    'Hierarchy support hydration was not idempotent when the parent CAS was already present.'
$supportCas.phase11Validate = $false
$script:Inventory = @($parentCas)
$null = Add-Phase11HierarchyParentsToDeployConfig -Config $childValidationConfig -ExistingVMs @($parentCas)
$script:Inventory = @($savedInventory)
Assert-Equal $true ([bool]$supportCas.phase11Validate) `
    'An already-present hidden parent CAS was not restored to Phase 11 validation scope.'
Assert-ThrowsLike {
    $duplicateParentConfig = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'upgrade.test' }
        virtualMachines = @([pscustomobject]@{
                vmName = 'CHD2'; role = 'Primary'; siteCode = 'CH2'; parentSiteCode = 'CAS'
                hidden = $true; phase11Validate = $true
            })
    }
    $duplicateParents = @(
        $parentCas,
        [pscustomobject]@{
            vmName = 'CAS2'; role = 'CAS'; siteCode = 'CAS'; domain = 'upgrade.test'; state = 'Running'
        }
    )
    Add-Phase11HierarchyParentsToDeployConfig -Config $duplicateParentConfig -ExistingVMs $duplicateParents
} '*expected exactly one existing CAS*found 2*' `
    'Ambiguous parent CAS inventory did not fail closed.'
Assert-ThrowsLike {
    $missingDependencyParent = [pscustomobject]@{
        vmName = 'CAS-MISSING'; role = 'CAS'; siteCode = 'CMS'; domain = 'upgrade.test'
        remoteSQLVM = 'SQL-MISSING'; state = 'Running'
    }
    $missingDependencyConfig = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'upgrade.test' }
        virtualMachines = @([pscustomobject]@{
                vmName = 'CHD-MISSING'; role = 'Primary'; siteCode = 'CHM'; parentSiteCode = 'CMS'
                hidden = $true; phase11Validate = $true
            })
    }
    $script:Inventory = @($missingDependencyParent)
    try {
        Add-Phase11HierarchyParentsToDeployConfig -Config $missingDependencyConfig `
            -ExistingVMs @($missingDependencyParent)
    }
    finally {
        $script:Inventory = @($savedInventory)
    }
} '*Failed to add remote SQL dependency ''SQL-MISSING''*' `
    'Missing parent hierarchy support dependency did not fail closed.'

$cstest3Inventory = @(
    [pscustomobject]@{
        vmName = 'CT3-CS1SITE'; role = 'CAS'; siteCode = 'CS1'; domain = 'cstest3.com'
        cmOptions = [pscustomobject]@{ Version = 'current-branch'; Install = $true; UsePKI = $false }
        remoteSQLVM = 'CT3-CS1SQL'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'CT3-CS1SITE-P'; role = 'PassiveSite'; siteCode = 'CS1'; domain = 'cstest3.com'
        remoteContentLibVM = 'CT3-FS1'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'CT3-CS1RPSUP1'; role = 'SiteSystem'; siteCode = 'CS1'; domain = 'cstest3.com'
        installSUP = $true; installRP = $true; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'CT3-CS1SQL'; role = 'DomainMember'; domain = 'cstest3.com'
        sqlVersion = 'SQL Server 2019'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'CT3-FS1'; role = 'FileServer'; domain = 'cstest3.com'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'CT3-PS1SITE'; role = 'Primary'; siteCode = 'PS1'; parentSiteCode = 'CS1'
        domain = 'cstest3.com'; state = 'Running'
    },
    [pscustomobject]@{
        vmName = 'CT3-DPMP1'; role = 'SiteSystem'; siteCode = 'PS1'; domain = 'cstest3.com'
        installDP = $true; installMP = $true; state = 'Running'
    }
)
$cstest3FollowOn = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'cstest3.com'; network = '192.168.31.0' }
    parameters = [pscustomobject]@{ ExistingDCName = $null }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'CT3-PS1DPMPSUP1'; role = 'SiteSystem'; siteCode = 'PS1'
            installDP = $true; installMP = $true; installSUP = $true
        }
    )
}
$script:Inventory = @($cstest3Inventory)
Add-ExistingVMsToDeployConfig -Config $cstest3FollowOn
$script:Inventory = @($savedInventory)
Assert-Equal 'CT3-CS1RPSUP1,CT3-CS1SITE,CT3-CS1SITE-P,CT3-CS1SQL,CT3-DPMP1,CT3-FS1,CT3-PS1DPMPSUP1,CT3-PS1SITE' `
    (@($cstest3FollowOn.virtualMachines.vmName | Sort-Object) -join ',') `
    'CSTest3-C expansion did not retain the complete child/parent hierarchy support closure.'
$cstest3Cas = $cstest3FollowOn.virtualMachines | Where-Object vmName -eq 'CT3-CS1SITE' | Select-Object -First 1
$cstest3Primary = $cstest3FollowOn.virtualMachines | Where-Object vmName -eq 'CT3-PS1SITE' | Select-Object -First 1
$cstest3Passive = $cstest3FollowOn.virtualMachines | Where-Object vmName -eq 'CT3-CS1SITE-P' | Select-Object -First 1
$cstest3ParentRole = $cstest3FollowOn.virtualMachines | Where-Object vmName -eq 'CT3-CS1RPSUP1' | Select-Object -First 1
Assert-Equal $true ([bool]$cstest3Cas.phase11Validate) `
    'CSTest3-C parent CAS was not scheduled for functional validation.'
Assert-Equal $true ([bool]$cstest3Primary.phase11Validate) `
    'CSTest3-C owning Primary was not scheduled for functional validation.'
Assert-Equal $true ([bool]$cstest3Passive.phase11Validate) `
    'CSTest3-C parent passive site server was not scheduled for functional validation.'
Assert-Equal $true ([bool]$cstest3ParentRole.phase11Validate) `
    'CSTest3-C parent explicit role host was not scheduled for functional validation.'
$cstest3Phase11Names = @($cstest3FollowOn.virtualMachines | Where-Object {
        Test-MemLabsIncludeHiddenVmForPhase -Vm $_ -Phase 11
    } | ForEach-Object { $_.vmName } | Sort-Object)
Assert-Equal 'CT3-CS1RPSUP1,CT3-CS1SITE,CT3-CS1SITE-P,CT3-DPMP1,CT3-PS1DPMPSUP1,CT3-PS1SITE' `
    ($cstest3Phase11Names -join ',') `
    'CSTest3-C did not schedule the complete changed and supporting ConfigMgr surface for Phase 11.'

$standalonePrimary = [pscustomobject]@{
    vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'; installSUP = $true
}
$remoteTopSup = [pscustomobject]@{
    vmName = 'SUP1'; role = 'SiteSystem'; siteCode = 'PRI'; installSUP = $true
}
$childPrimary = [pscustomobject]@{
    vmName = 'CHD1'; role = 'Primary'; siteCode = 'CHD'; parentSiteCode = 'CAS'; installSUP = $true
}
$remoteChildSup = [pscustomobject]@{
    vmName = 'CHDSUP'; role = 'SiteSystem'; siteCode = 'CHD'; installSUP = $true
}
$cas = [pscustomobject]@{
    vmName = 'CAS1'; role = 'CAS'; siteCode = 'CAS'; installSUP = $true
}
Assert-Equal $true (Test-MemLabsSupSyncsFromMicrosoftUpdate -Vm $standalonePrimary `
        -DeployConfig ([pscustomobject]@{ virtualMachines = @($standalonePrimary) })) `
    'Standalone Primary SUP no longer owns Microsoft Update synchronization.'
Assert-Equal $true (Test-MemLabsSupSyncsFromMicrosoftUpdate -Vm $remoteTopSup `
        -DeployConfig ([pscustomobject]@{ virtualMachines = @($standalonePrimary, $remoteTopSup) })) `
    'Remote SUP for a standalone Primary did not inherit Microsoft Update ownership.'
Assert-Equal $false (Test-MemLabsSupSyncsFromMicrosoftUpdate -Vm $childPrimary `
        -DeployConfig ([pscustomobject]@{ virtualMachines = @($childPrimary) })) `
    'Child Primary incorrectly became a Microsoft Update synchronization owner when CAS was absent from the partial config.'
Assert-Equal $false (Test-MemLabsSupSyncsFromMicrosoftUpdate -Vm $remoteChildSup `
        -DeployConfig ([pscustomobject]@{ virtualMachines = @($childPrimary, $remoteChildSup) })) `
    'Remote child-Primary SUP incorrectly became a Microsoft Update synchronization owner.'
Assert-Equal $true (Test-MemLabsSupSyncsFromMicrosoftUpdate -Vm $cas `
        -DeployConfig ([pscustomobject]@{ virtualMachines = @($cas) })) `
    'CAS SUP no longer owns Microsoft Update synchronization.'
Assert-Equal $true (Test-MemLabsSupSyncsFromMicrosoftUpdate `
        -Vm ([pscustomobject]@{ vmName = 'WSUS1'; role = 'WSUS' }) `
        -DeployConfig ([pscustomobject]@{ virtualMachines = @() })) `
    'Standalone WSUS no longer owns its upstream synchronization.'

$networkConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ network = '10.20.1.0' }
    phase8ManagedDistributionPointScopes = @(
        [pscustomobject]@{
            DistributionPoints = @(
                [pscustomobject]@{ VmName = 'DP1'; Fqdn = 'DP1.upgrade.test'; Network = '10.20.2.0' }
            )
        }
    )
}
Assert-Equal '10.20.2.0' (Get-Phase11ProjectedVmNetwork -DeployConfig $networkConfig `
        -Vm ([pscustomobject]@{ vmName = 'DP1'; hidden = $true })) `
    'Hidden main-era DP did not recover its authoritative projected subnet for PXE validation.'
Assert-Equal '10.20.9.0' (Get-Phase11ProjectedVmNetwork -DeployConfig $networkConfig `
        -Vm ([pscustomobject]@{ vmName = 'DP1'; network = '10.20.9.0' })) `
    'Explicit develop network did not override projected legacy metadata.'

$phase7Source = Get-Content -LiteralPath $phase7Path -Raw
Assert-Equal 3 ([regex]::Matches($phase7Source, 'Test-MemLabsSupSyncsFromMicrosoftUpdate').Count) `
    'Phase 7 no longer uses one topology helper for both PBIRS and WSUS execution paths.'
$phasesSource = Get-Content -LiteralPath $phasesPath -Raw
Assert-True ($phasesSource -match 'Test-MemLabsIncludeHiddenVmForPhase -Vm \$currentItem -Phase \$Phase') `
    'Phase dispatcher is not wired to the hidden upgrade-validation policy.'
$configSource = Get-Content -LiteralPath $configPath -Raw
Assert-True ($configSource -match 'Get-ExistingConfigMgrRoleUpgradePlan -Config \$config') `
    'Existing role upgrade plan is not wired into deploy-config expansion.'

Write-Host 'PASS -- main-era PKI, DP, MP, SUP/WSUS, RP, PXE, and cross-subnet role upgrades use develop repair and validation safeguards.'
