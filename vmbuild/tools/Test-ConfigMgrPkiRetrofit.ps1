#requires -Version 5.1
[CmdletBinding()]
param([switch]$GuestOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1 -or $errors.Count) { throw "Cannot import $Name from $Path`: $($errors -join '; ')" }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -like $Pattern) { return }
        throw
    }
    throw "Expected an exception matching '$Pattern'."
}
function Write-Log { param($Message, [switch]$Failure, [switch]$Verbose, [switch]$Warning, [switch]$LogOnly) }
function Write-DscStatus { param($Message, [switch]$Failure) }

if (-not $GuestOnly) {
    $configPath = Join-Path $root 'common\Common.Config.ps1'
    foreach ($name in @('Get-ExistingConfigMgrPkiConversionTargets', 'Sync-ExistingHierarchyOptionsToDeployConfig',
            'New-DeployConfig', 'Add-ExistingVMToDeployConfig', 'Add-ModifiedExistingVMToDeployConfig',
            'Add-RemoteSQLVMToDeployConfig', 'ConvertFrom-MemLabsVmNoteScalar',
            'Resolve-ConfigVmReference', 'Update-ConfigVmReferences', 'Resolve-VmCmOptions', 'Set-VmCmOptionsResolved',
            'Add-Phase11HierarchyParentsToDeployConfig', 'Get-SQLAOConfig')) {
        . (Import-TestFunction $configPath $name)
    }
    foreach ($name in @('Get-Phase2ConfigurationData', 'Get-Phase4ConfigurationData', 'Get-Phase6ConfigurationData', 'Get-Phase8ConfigurationData',
            'Test-MemLabsIncludeHiddenVmForPhase')) {
        . (Import-TestFunction (Join-Path $root 'common\Common.Phases.ps1') $name)
    }
    $script:Common = [pscustomobject]@{ InJob = $false }
    $script:Inventory = @(
        [pscustomobject]@{ vmName = 'LAB-DC'; role = 'DC'; domain = 'lab.test'; state = 'Running' },
        [pscustomobject]@{
            vmName = 'LAB-PRI'; role = 'Primary'; siteCode = 'PRI'; domain = 'lab.test'; state = 'Running'
            cmOptions = [pscustomobject]@{ UsePKI = $false; Install = $false; Version = '2609' }
            remoteSQLVM = 'SQLAO1'; replicaSqlServerVM = 'SQLAO2'
        },
        [pscustomobject]@{
            vmName = 'LAB-MPDP'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'lab.test'; state = 'Running'
            installMP = $true; installDP = $true
        },
        [pscustomobject]@{
            vmName = 'LAB-SUP'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'lab.test'; state = 'Running'; installSUP = $true
            wsusDataBaseServer = 'SQLAO1'
        },
        [pscustomobject]@{
            vmName = 'LAB-SEC'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI'; domain = 'lab.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'LAB-CLIENT'; role = 'DomainMember'; pushClient = 'SEC'; domain = 'lab.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'LAB-LEGACY'; role = 'DomainMember'; pushClient = 'True'; domain = 'lab.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'FOREIGN-PRI'; role = 'Primary'; siteCode = 'PRI'; domain = 'foreign.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'LAB-SQLAO1'; role = 'SQLAO'; domain = 'lab.test'; state = 'Running'
            OtherNode = 'SQLAO2'; fileServerVM = 'FS1'; remoteContentLibVM = 'MISSING'
            ClusterName = 'DEPLOYED-CLUSTER'; AlwaysOnListenerName = 'DEPLOYED-LISTENER'
            ClusterIPAddress = '10.1.1.201'; AGIPAddress = '10.1.1.202'
        },
        [pscustomobject]@{
            vmName = 'LAB-SQLAO2'; role = 'SQLAO'; domain = 'lab.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'LAB-FS1'; role = 'FileServer'; domain = 'lab.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'SQLAO2'; role = 'DomainMember'; domain = 'foreign.test'; state = 'Running'
        }
    )
    function Get-List {
        param($Type, $DomainName, [switch]$FailOnError)
        if ($DomainName) { $script:FailClosedInventory = [bool]$FailOnError }
        @($script:Inventory | Where-Object { -not $DomainName -or $_.domain -eq $DomainName })
    }
    function Get-VMNote {
        param($VMName)
        $script:Inventory | Where-Object vmName -eq $VMName | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }
    function Start-VM2 { param($Name) throw "Fixture must not start $Name." }
    function Get-ExistingForDomain { param($DomainName, $Role) if ($Role -eq 'DC') { 'LAB-DC' } }
    function Get-MemlabsDataRoot { Join-Path $env:TEMP '__memlabs_pki_fixture_no_data__' }
    function Write-Exception { param($ExceptionInfo, $AdditionalInfo) throw $ExceptionInfo }
    function Get-CmOptionsFromSiteServerBackup { param($VmName, $DomainName) throw 'Unexpected backup recovery.' }
    function Test-PushClientRequested { param($VM) $false }
    function New-FixtureConfig {
        [pscustomobject]@{
            vmOptions = [pscustomobject]@{ domainName = 'lab.test'; prefix = 'LAB-' }
            cmOptions = [pscustomobject]@{ UsePKI = $true; Install = $true; Version = '9999' }
            pkiOptions = [pscustomobject]@{ EnablePKI = $true; IssuingCAVM = 'CA'; UseOfflineRoot = $false }
            virtualMachines = @([pscustomobject]@{ vmName = 'CA'; role = 'DomainMember'; InstallCA = $true })
        }
    }

    $converted = New-DeployConfig -configObject (New-FixtureConfig)
    Assert-True $script:FailClosedInventory 'PKI retrofit must use fail-closed domain inventory.'
    $targets = @($converted.virtualMachines | Where-Object pkiReconfigure)
    Assert-True (($targets.vmName | Sort-Object) -join ',' -eq 'LAB-CLIENT,LAB-LEGACY,LAB-MPDP,LAB-PRI,LAB-SEC,LAB-SQLAO1,LAB-SQLAO2,LAB-SUP') `
        'CA-only UsePKI enablement did not include exactly the existing hierarchy and its domain members.'
    foreach ($vm in $targets) {
        Assert-True ($vm.hidden -and $vm.phase11Validate) "$($vm.vmName) lost rebuild protection or independent validation."
        Assert-True (-not (Test-MemLabsIncludeHiddenVmForPhase -Vm $vm -Phase 1) -and
            -not (Test-MemLabsIncludeHiddenVmForPhase -Vm $vm -Phase 10) -and
            (Test-MemLabsIncludeHiddenVmForPhase -Vm $vm -Phase 11)) 'Retrofit changed hidden VM phase safety.'
    }
    & {
        function Get-ValidDomainNames { @{ 'lab.test'='LAB-' } }
        $automatic = New-FixtureConfig
        $automatic.vmOptions.domainName = 'AUTO'
        $automatic.vmOptions.prefix = 'AUTO'
        $automaticDeploy = New-DeployConfig $automatic
        Assert-True ($automaticDeploy.vmOptions.domainName -eq 'lab.test' -and
            @($automaticDeploy.virtualMachines | Where-Object pkiReconfigure).Count -eq 8) `
            'AUTO domain resolution happened after existing-hierarchy PKI discovery.'
    }
    $primary = $converted.virtualMachines | Where-Object vmName -eq 'LAB-PRI'
    Assert-True ($primary.remoteSQLVM -eq 'LAB-SQLAO1' -and $primary.replicaSqlServerVM -eq 'LAB-SQLAO2') `
        'Hidden PKI conversion retained unprefixed SQL dependencies or selected a foreign-domain VM.'
    $sup = $converted.virtualMachines | Where-Object vmName -eq 'LAB-SUP'
    Assert-True ($sup.wsusDataBaseServer -eq 'LAB-SQLAO1') 'Hidden SUP lost its canonical WSUS SQL dependency.'
    $declared = New-FixtureConfig
    $declared.virtualMachines += @(
        [pscustomobject]@{
            vmName='PRI'; role='Primary'; siteCode='PRI'; remoteSQLVM='SQLAO1'; replicaSqlServerVM='SQLAO2'
        },
        [pscustomobject]@{
            vmName='SUP'; role='SiteSystem'; siteCode='PRI'; installSUP=$true; wsusDataBaseServer='SQLAO1'
        },
        [pscustomobject]@{
            vmName='SQLAO1'; role='SQLAO'; OtherNode='SQLAO2'; fileServerVM='FS1'
            ClusterName='TEMPLATE-CLUSTER'; AlwaysOnListenerName='TEMPLATE-LISTENER'
            ClusterIPAddress='192.0.2.201'; AGIPAddress='192.0.2.202'
        }
    )
    $declaredDeploy = New-DeployConfig $declared
    $declaredPrimary = $declaredDeploy.virtualMachines | Where-Object vmName -eq 'LAB-PRI'
    $declaredSup = $declaredDeploy.virtualMachines | Where-Object vmName -eq 'LAB-SUP'
    Assert-True ($declaredPrimary.hidden -and $declaredPrimary.remoteSQLVM -eq 'LAB-SQLAO1' -and
        $declaredPrimary.replicaSqlServerVM -eq 'LAB-SQLAO2' -and $declaredSup.hidden -and
        $declaredSup.wsusDataBaseServer -eq 'LAB-SQLAO1') 'Declared VMs hidden before prefixing retained base dependency names.'
    $declaredSql = $declaredDeploy.virtualMachines | Where-Object vmName -eq 'LAB-SQLAO1'
    Assert-True ($declaredSql.ClusterName -eq 'DEPLOYED-CLUSTER' -and
        $declaredSql.AlwaysOnListenerName -eq 'DEPLOYED-LISTENER' -and
        $declaredSql.ClusterIPAddress -eq '10.1.1.201' -and $declaredSql.AGIPAddress -eq '10.1.1.202') `
        'PKI conversion replaced deployed SQLAO identities or addresses with saved-template values.'
    foreach ($conflict in @('Role', 'Domain')) {
        $bad = New-FixtureConfig
        $row = [pscustomobject]@{ vmName='PRI'; role='Primary'; siteCode='PRI' }
        if ($conflict -eq 'Role') { $row.role = 'OSDClient' }
        else { $row | Add-Member NoteProperty domain 'foreign.test' }
        $bad.virtualMachines += $row
        Assert-Throws { New-DeployConfig $bad } '*PKI conversion*conflict*LAB-PRI*'
    }
    Assert-True ($primary.cmOptions.UsePKI -and -not $primary.cmOptions.Install -and $primary.cmOptions.Version -eq '2609') `
        'PKI intent was overwritten, or conversion changed unrelated hierarchy options.'
    Assert-True (-not $script:Inventory[1].cmOptions.UsePKI) 'Planning mutated the deployed hierarchy inventory.'
    Assert-True ($script:Inventory[1].remoteSQLVM -eq 'SQLAO1') 'Dependency normalization mutated the VM inventory.'
    Assert-True ((Get-Phase4ConfigurationData $converted).AllNodes.NodeName -contains 'LAB-MPDP') 'Hidden role host missed certificate enrollment.'
    Assert-True ((Get-Phase6ConfigurationData $converted).AllNodes.NodeName -contains 'LAB-SUP') 'Hidden SUP missed WSUS TLS configuration.'
    Assert-True ((Get-Phase8ConfigurationData $converted).AllNodes.NodeName -contains 'LAB-PRI') 'Install=false suppressed the PKI conversion workflow.'
    $dcText = [IO.File]::ReadAllText((Join-Path $root 'DSC\phases\Phase2DC.ps1'))
    $start = $dcText.IndexOf('    $sitecount = 0')
    $end = $dcText.IndexOf('    # Domain creds', $start)
    Assert-True ($start -ge 0 -and $end -gt $start) 'Could not locate production DC group membership selection.'
    $deployConfig = $converted
    $waitOnDomainJoin = [Collections.ArrayList]@()
    $members = @(& ([scriptblock]::Create($dcText.Substring($start, $end - $start) + "`n`$iisgroupMembers")))
    Assert-True ($members -contains 'LAB-MPDP$' -and $members -contains 'LAB-SUP$') 'Existing role hosts missed IIS certificate enrollment permissions.'

    $dependencies = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'lab.test'; prefix = 'LAB-' }
        virtualMachines = $null
    }
    Add-RemoteSQLVMToDeployConfig -vmName $primary.remoteSQLVM -configToModify $dependencies
    Assert-True (($dependencies.virtualMachines.vmName | Sort-Object) -join ',' -eq 'LAB-FS1,LAB-SQLAO1,LAB-SQLAO2') `
        'Existing SQLAO hydration missed its prefixed peer/file server or imported the foreign SQLAO2.'
    $sql = $dependencies.virtualMachines | Where-Object vmName -eq 'LAB-SQLAO1'
    Assert-True ($sql.OtherNode -eq 'LAB-SQLAO2' -and $sql.fileServerVM -eq 'LAB-FS1' -and
        $sql.remoteContentLibVM -eq 'MISSING' -and $sql.hidden) 'Hydrated VM references were not canonical, unknown names were guessed, or rebuild protection was lost.'
    Add-RemoteSQLVMToDeployConfig -vmName $primary.remoteSQLVM -configToModify $dependencies
    Assert-True ($dependencies.virtualMachines.Count -eq 3) 'Repeated dependency hydration added duplicates or double-prefixed names.'
    $aliasDependencies = [pscustomobject]@{
        vmOptions=[pscustomobject]@{ domainName='lab.test'; prefix='LAB-' }
        virtualMachines=@()
    }
    Add-RemoteSQLVMToDeployConfig -vmName 'SQLAO1' -configToModify $aliasDependencies -DomainName 'lab.test'
    Assert-True (($aliasDependencies.virtualMachines.vmName | Sort-Object) -join ',' -eq 'LAB-FS1,LAB-SQLAO1,LAB-SQLAO2') `
        'SQL hydration reused a raw inventory reference without resolving its owning domain and lab prefix.'
    foreach ($sqlDomain in @('lab.test', 'foreign.test')) {
        $scopedSql = [pscustomobject]@{
            vmOptions=[pscustomobject]@{ domainName='lab.test'; prefix='LAB-' }
            virtualMachines=@()
        }
        Add-RemoteSQLVMToDeployConfig -vmName 'SQLAO2' -configToModify $scopedSql -DomainName $sqlDomain
        $expectedName = if ($sqlDomain -eq 'lab.test') { 'LAB-SQLAO2' } else { 'SQLAO2' }
        Assert-True ($scopedSql.virtualMachines.Count -eq 1 -and $scopedSql.virtualMachines[0].vmName -eq $expectedName) `
            'An overlapping bare SQL name resolved outside the owning VM domain.'
        if ($sqlDomain -eq 'foreign.test') {
            Assert-Throws { Add-RemoteSQLVMToDeployConfig -vmName 'SQLAO2' -configToModify $scopedSql -DomainName 'lab.test' } '*not its owning VM*'
        }
    }
    Add-RemoteSQLVMToDeployConfig -vmName 'LAB-SQLAO1' -configToModify $declaredDeploy
    $generatedSql = Get-SQLAOConfig -deployConfig $declaredDeploy -vmName 'LAB-SQLAO1'
    Assert-True ($generatedSql.GroupName -eq 'DEPLOYED-CLUSTERGroup' -and
        $generatedSql.FileServerName -eq 'LAB-FS1' -and $generatedSql.SecondaryNodeName -eq 'LAB-SQLAO2') `
        'SQLAO phase-data generation did not consume the hydrated topology.'
    foreach ($emptyPrefix in @('', $null)) {
        $unprefixedSql = $declaredDeploy | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $unprefixedSql.vmOptions.prefix = $emptyPrefix
        Assert-True ((Get-SQLAOConfig -deployConfig $unprefixedSql -vmName 'LAB-SQLAO1').WitnessLocalPath -eq
            'F:\DEPLOYED-CLUSTER-Witness') 'SQLAO configuration failed with an empty/absent optional lab prefix.'
    }
    $missingWitness = $declaredDeploy | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $missingWitness.virtualMachines = @($missingWitness.virtualMachines | Where-Object vmName -ne 'LAB-FS1')
    Assert-Throws { Get-SQLAOConfig -deployConfig $missingWitness -vmName 'LAB-SQLAO1' } '*witness*LAB-FS1*hydration is incomplete*'
    $hierarchySupport = [pscustomobject]@{
        vmOptions = $dependencies.vmOptions
        virtualMachines = @(
            [pscustomobject]@{
                vmName='LAB-CAS'; role='CAS'; siteCode='CAS'; hidden=$true
                remoteSQLVM=$declaredPrimary.remoteSQLVM; replicaSqlServerVM=$declaredPrimary.replicaSqlServerVM
            },
            [pscustomobject]@{
                vmName='LAB-CHILD'; role='Primary'; siteCode='CHD'; parentSiteCode='CAS'; hidden=$true; phase11Validate=$true
            }
        )
    }
    $null = Add-Phase11HierarchyParentsToDeployConfig -Config $hierarchySupport -ExistingVMs $script:Inventory
    Assert-True ($hierarchySupport.virtualMachines.Count -eq 5 -and
        $hierarchySupport.virtualMachines.vmName -contains 'LAB-SQLAO1' -and
        $hierarchySupport.virtualMachines.vmName -contains 'LAB-SQLAO2' -and
        $hierarchySupport.virtualMachines.vmName -contains 'LAB-FS1') 'CAS hierarchy support still rejects the normalized remote SQL dependency.'
    $wid = [pscustomobject]@{ vmName='LAB-WID-SUP'; wsusDataBaseServer='WID' }
    Update-ConfigVmReferences -VM $wid -KnownVMs @([pscustomobject]@{ vmName='LAB-WID' }) -DomainName 'lab.test' -Prefix 'LAB-'
    Assert-True ($wid.wsusDataBaseServer -eq 'WID') 'The internal WSUS database marker was resolved as a VM name.'

    foreach ($merge in @($false, $true)) {
        $modifiedConfig = [pscustomobject]@{
            vmOptions=[pscustomobject]@{ domainName='lab.test'; prefix='LAB-' }
            virtualMachines=@()
        }
        if ($merge) {
            $modifiedConfig.virtualMachines = @([pscustomobject]@{ vmName='LAB-PRI'; role='Primary'; hidden=$true })
        }
        Add-ModifiedExistingVMToDeployConfig -vm (Get-VMNote 'LAB-PRI') -configToModify $modifiedConfig
        Assert-True ($modifiedConfig.virtualMachines.Count -eq 1 -and
            $modifiedConfig.virtualMachines[0].remoteSQLVM -eq 'LAB-SQLAO1' -and
            $modifiedConfig.virtualMachines[0].replicaSqlServerVM -eq 'LAB-SQLAO2' -and
            $modifiedConfig.virtualMachines[0].hidden) 'Modified-VM append/merge bypassed canonical reference resolution.'
    }
    $duplicateSql = [pscustomobject]@{
        vmOptions=[pscustomobject]@{ domainName='lab.test'; prefix='LAB-' }
        virtualMachines=@(
            [pscustomobject]@{ vmName='LAB-SQL'; role='DomainMember' },
            [pscustomobject]@{ vmName='LAB-SQL'; role='DomainMember' }
        )
    }
    Assert-Throws { Add-RemoteSQLVMToDeployConfig -vmName 'LAB-SQL' -configToModify $duplicateSql } '*SQL dependency*LAB-SQL*2*'
    & {
        function Get-VMFromList2 { param($DeployConfig,$VmName,$SmartUpdate,$Global) $null }
        Assert-Throws { Add-RemoteSQLVMToDeployConfig -vmName 'SQL-MISSING' -configToModify $dependencies } '*Required SQL dependency*SQL-MISSING*lab.test*LAB-*'
    }
    foreach ($noteMode in @('Unreadable', 'WrongName', 'WrongDomain', 'DuplicateInventory', 'InventoryFailure')) {
        & {
            param($Mode)
            $probeState = @{ Starts=0 }
            function Get-List {
                param($Type,[switch]$FailOnError)
                if ($Mode -eq 'InventoryFailure') {
                    if ($FailOnError) { throw 'LAB-BAD inventory access failed' }
                    return
                }
                $row = [pscustomobject]@{ vmName='LAB-BAD'; domain='lab.test'; role='SiteSystem'; state='Off' }
                if ($Mode -eq 'DuplicateInventory') { $row; $row } else { $row }
            }
            function Get-VMNote {
                param($VMName)
                if ($Mode -eq 'Unreadable') { return }
                $row = [pscustomobject]@{ vmName='LAB-BAD'; domain='lab.test'; role='SiteSystem' }
                if ($Mode -eq 'WrongName') { $row.vmName='LAB-OTHER' }
                if ($Mode -eq 'WrongDomain') { $row.domain='foreign.test' }
                $row
            }
            function Start-VM2 { param($Name) $probeState.Starts++ }
            $config = [pscustomobject]@{
                vmOptions=[pscustomobject]@{ domainName='lab.test'; prefix='LAB-' }
                virtualMachines=@()
            }
            Assert-Throws { Add-ExistingVMToDeployConfig -vmName 'LAB-BAD' -configToModify $config } '*LAB-BAD*'
            Assert-True ($probeState.Starts -eq 0 -and $config.virtualMachines.Count -eq 0) `
                "$Mode VM metadata was powered on or added before its identity was verified."
        } $noteMode
    }

    $caOnly = New-FixtureConfig
    $caOnly.cmOptions.UsePKI = $false
    Assert-True (@((New-DeployConfig $caOnly).virtualMachines | Where-Object pkiReconfigure).Count -eq 0) `
        'CA infrastructure without ConfigMgr UsePKI requested a hierarchy conversion.'
    $existingCa = New-FixtureConfig
    $existingCa.virtualMachines = @()
    $existingCa.pkiOptions.IssuingCAVM = 'DC'
    $existingCaDeploy = New-DeployConfig $existingCa
    Assert-True (@($existingCaDeploy.virtualMachines | Where-Object {
                $_.vmName -eq 'LAB-DC' -and $_.hidden -and $_.InstallCA
            }).Count -eq 1) 'Existing selected CA was not included without rebuilding it.'
    Assert-True (@(Get-Phase2ConfigurationData $existingCaDeploy).Count -gt 0) 'All-hidden conversion skipped the DC permissions/policy phase.'

    $script:Inventory += [pscustomobject]@{
        vmName = 'LAB-OTHER'; role = 'Primary'; siteCode = 'OTH'; domain = 'lab.test'; state = 'Running'
        cmOptions = [pscustomobject]@{ UsePKI = $false; Install = $false; Version = '2609' }
    }
    Assert-Throws { New-DeployConfig (New-FixtureConfig) } '*multiple hierarchies*'
    $scoped = New-FixtureConfig
    $scoped.virtualMachines += [pscustomobject]@{
        vmName = 'PRI'; role = 'Primary'; siteCode = 'PRI'; cmOptions = [pscustomobject]@{ UsePKI = $true }
    }
    $scopedDeploy = New-DeployConfig $scoped
    Assert-True ($scopedDeploy.virtualMachines.vmName -notcontains 'LAB-OTHER' -and
        $scopedDeploy.virtualMachines.vmName -notcontains 'FOREIGN-PRI') 'PKI conversion escaped the selected hierarchy/domain.'
    $child = New-FixtureConfig
    $child.virtualMachines += [pscustomobject]@{
        vmName = 'CHILD'; role = 'Primary'; siteCode = 'NEW'; parentSiteCode = 'PRI'
        cmOptions = [pscustomobject]@{ UsePKI = $true }
    }
    $childDeploy = New-DeployConfig $child
    Assert-True (@($childDeploy.virtualMachines | Where-Object pkiReconfigure).Count -eq 0) 'A child-site default silently converted its existing hierarchy.'
    & {
        foreach ($name in @('Install-PKI', 'Test-PKIStepResult')) {
            . (Import-TestFunction (Join-Path $root 'common\Common.PKI.ps1') $name)
        }
        $script:CaSteps = [Collections.Generic.List[string]]::new()
        function Test-Path { [CmdletBinding()]param($LiteralPath) if ($script:CaMode -eq 'Permission') { throw 'fixture denied' }; $script:CaMode -ne 'Unconfigured' }
        function Get-ItemProperty { [CmdletBinding()]param($LiteralPath) [pscustomobject]@{ Active = 'FixtureCA' } }
        function Get-Service {
            [CmdletBinding()]param()
            $status = if ($script:CaMode -eq 'Stopped') { 'Stopped' } else { 'Running' }
            [pscustomobject]@{ Name = 'CertSvc'; Status = $status }
        }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, $DisplayName, $ScriptBlock)
            if ($script:CaMode -eq 'Missing') { return }
            $state = & $ScriptBlock
            if ($script:CaMode -eq 'Malformed') { $state.Ready = 'true' }
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $state }
        }
        function Install-PKICertificateTemplates { param($CAVMName, $DomainName, $DeployConfig, $LogPrefix) $script:CaSteps.Add('Templates'); $true }
        function Install-SingleTierPKI { param($DeployConfig) $script:CaSteps.Add('SingleTier'); $true }
        function Install-TwoTierPKI { param($DeployConfig) throw 'An operational existing CA must not start its offline root.' }
        function Initialize-PKIMemberCertificates { param($DeployConfig) $script:CaSteps.Add('Members'); $true }
        $caConfig = [pscustomobject]@{
            vmOptions = @{ domainName = 'lab.test' }
            virtualMachines = @([pscustomobject]@{ vmName = 'CA'; hidden = $true; InstallCA = $true; UseOfflineRoot = $true })
        }
        $script:CaMode = 'Ready'
        Assert-True ((Install-PKI $caConfig) -and ($script:CaSteps -join ',') -eq 'Templates,Members') `
            'Existing healthy issuing CA did not reuse templates without reinstalling/waking its offline root.'
        foreach ($failure in @('Stopped', 'Permission', 'Missing', 'Malformed')) {
            $script:CaSteps.Clear()
            $script:CaMode = $failure
            Assert-True (-not (Install-PKI $caConfig) -and $script:CaSteps.Count -eq 0) "$failure CA inspection incorrectly continued conversion."
        }
        $script:CaSteps.Clear()
        $script:CaMode = 'Unconfigured'
        $caConfig.virtualMachines[0].UseOfflineRoot = $false
        Assert-True ((Install-PKI $caConfig) -and ($script:CaSteps -join ',') -eq 'SingleTier,Members') `
            'An existing VM selected as a new CA skipped actual CA provisioning.'
    }
    Write-Host 'PASS -- existing-hierarchy PKI targeting, intent preservation, permissions, enrollment phases, and rebuild protection.'
}

$functionsPath = Join-Path $root 'DSC\phases\ScriptFunctions.ps1'
foreach ($name in @('Get-MemLabsConfigMgrRoleHttpsState', 'Invoke-MemLabsConfigMgrPkiConversion')) {
    . (Import-TestFunction $functionsPath $name)
}
$script:Calls = [Collections.Generic.List[string]]::new()
$script:Mode = 'Ready'
$script:RoleModes = @{}
$script:SiteMode = 0
function Get-SMSProvider { param($SiteCode) [pscustomobject]@{ FQDN = 'SITE.lab.test' } }
function Set-CMSiteProvider { param($SiteCode, $ProviderFQDN) $script:Mode -ne 'ProviderFailure' }
function Set-Location { [CmdletBinding()]param($Path) }
function Get-CMManagementPoint { [CmdletBinding()]param($SiteSystemServerName, $SiteCode) if ($script:Mode -eq 'ImplicitRoles') { [pscustomobject]@{ Found = $true } } }
function Get-CMDistributionPoint { [CmdletBinding()]param($SiteSystemServerName, $SiteCode) if ($script:Mode -eq 'ImplicitRoles') { [pscustomobject]@{ Found = $true } } }
function Test-Path { param($LiteralPath, $PathType) $script:Mode -ne 'MissingPfx' }
function Get-Content { [CmdletBinding()]param($LiteralPath) 'fixture-password-not-a-credential' }
function Test-MPHttpsBinding { param($MPFQDN) $script:Mode -ne 'MissingBinding' }
function Invoke-DotSource {
    param($Script, $Arguments, [switch]$Rethrow)
    Assert-True ($Rethrow -and $Script -like '*EnableHTTPS.ps1') 'Conversion did not preserve HTTPS failure propagation.'
    $script:Calls.Add('EnableHTTPS')
}
function Set-CMSite {
    [CmdletBinding()]param($SiteCode, $UsePkiClientCertificate, $ClientComputerCommunicationType)
    Assert-True ($UsePkiClientCertificate -and $ClientComputerCommunicationType -eq 'HttpsOnly') 'Site did not request HTTPS-only mode.'
    $script:SiteMode = 1
}
function Set-CMManagementPoint {
    [CmdletBinding()]param($SiteSystemServerName, $SiteCode, [bool]$EnableSsl)
    Assert-True $EnableSsl 'MP conversion did not request SSL.'
    if ($script:Mode -eq 'SetFailure') { throw 'fixture MP update failure' }
    $script:Calls.Add("MP:$SiteSystemServerName/$SiteCode")
    $script:RoleModes.MP = 63
}
function Set-CMDistributionPoint {
    [CmdletBinding()]param($SiteSystemServerName, $SiteCode, $ClientCommunicationType, $CertificatePath,
        [securestring]$CertificatePassword, [switch]$Force)
    Assert-True ($ClientCommunicationType -eq 'Https' -and $CertificatePath -like '*DistributionPointCertificate.pfx' -and
        $null -ne $CertificatePassword -and $Force) 'DP conversion omitted HTTPS or its PKI identity certificate.'
    $script:Calls.Add("DP:$SiteSystemServerName/$SiteCode")
    $script:RoleModes.DP = 63
}
function Set-CMSoftwareUpdatePoint {
    [CmdletBinding()]param($SiteSystemServerName, $SiteCode, [bool]$EnableSsl, $HttpPort, $HttpsPort)
    Assert-True ($EnableSsl -and $HttpPort -eq 8530 -and $HttpsPort -eq 8531) 'SUP conversion omitted WSUS TLS settings.'
    $script:Calls.Add("SUP:$SiteSystemServerName/$SiteCode")
    $script:RoleModes.SUP = 1
}
function Get-WmiObject {
    [CmdletBinding()]param($Namespace, $Class, $Filter)
    if ($script:Mode -eq 'SecondaryScope') {
        Assert-True ($Namespace -eq 'root\SMS\site_PRI' -and $Filter -like "*SiteCode='SEC'*") `
            'Secondary role readback used a nonexistent local secondary provider namespace.'
    }
    if ($script:Mode -eq 'MissingRow') { return }
    $role = if ($Filter -like '*Management Point*') { 'MP' } elseif ($Filter -like '*Distribution Point*') { 'DP' } else { 'SUP' }
    $value = $script:RoleModes[$role]
    if ($script:Mode -eq 'NoConvergence') { $value = 0 }
    $name = if ($role -eq 'SUP') { 'SSLWSUS' } else { 'SslState' }
    $row = [pscustomobject]@{
        NALPath = '\\ROLE.lab.test\'
        Props = @([pscustomobject]@{ PropertyName = $name; Value = $value },
            [pscustomobject]@{ PropertyName = 'WSUSIISSSLPort'; Value = 8531 })
    }
    $row | Add-Member -MemberType ScriptMethod -Name Get -Value {}
    if ($script:Mode -eq 'MissingProperty') { $row.Props = @() }
    if ($script:Mode -eq 'InvalidProperty') { $row.Props[0].Value = 'invalid' }
    $row
    if ($script:Mode -eq 'DuplicateRow') { $row }
    if ($script:Mode -eq 'ImplicitRoles') {
        $implicit = $row.PSObject.Copy()
        $implicit.NALPath = '\\SITE.lab.test\'
        $implicit
    }
}
function Wait-CMRoleRegistered {
    param($RoleName, $ServerFQDN, $TimeoutSeconds, $PollSeconds, $Probe)
    & $Probe
}
function Get-CMSite {
    [CmdletBinding()]param($SiteCode)
    if ($script:Mode -eq 'SiteNoConvergence') { [pscustomobject]@{ Mode = 0 } }
    elseif ($script:Mode -ne 'MissingSite') { [pscustomobject]@{ Mode = $script:SiteMode } }
}
function Get-CMSiteComponent {
    [CmdletBinding()]param($SiteCode, $ComponentName)
    [pscustomobject]@{ Props = @([pscustomobject]@{ PropertyName = 'IISSSLState'; Value = 63 }) }
}
$site = [pscustomobject]@{
    vmName = 'SITE'; role = 'Primary'; siteCode = 'PRI'; pkiReconfigure = $true
    cmOptions = [pscustomobject]@{ UsePKI = $true }
}
$roleVm = [pscustomobject]@{
    vmName = 'ROLE'; role = 'SiteSystem'; siteCode = 'PRI'; pkiReconfigure = $true
    installMP = $true; installDP = $true; installSUP = $true
}
$guestConfig = [pscustomobject]@{
    vmOptions = @{ domainName = 'lab.test' }
    virtualMachines = @($site, $roleVm,
        [pscustomobject]@{ vmName = 'OTHER'; role = 'SiteSystem'; siteCode = 'OTH'; pkiReconfigure = $true; installMP = $true },
        [pscustomobject]@{ vmName = 'FOREIGN'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'other.test'; pkiReconfigure = $true; installDP = $true })
}
Invoke-MemLabsConfigMgrPkiConversion -DeployConfig $guestConfig -CurrentVM $site -ConfigFilePath 'fixture.json' -LogPath 'C:\fixture'
Assert-True (($script:Calls -join ',') -eq 'EnableHTTPS,MP:ROLE.lab.test/PRI,DP:ROLE.lab.test/PRI,SUP:ROLE.lab.test/PRI') `
    'Existing role conversion omitted a role or updated an unrelated hierarchy/domain.'
foreach ($failure in @('ProviderFailure', 'MissingPfx', 'MissingBinding', 'SetFailure', 'NoConvergence', 'MissingRow', 'SiteNoConvergence', 'MissingSite')) {
    $script:Mode = $failure
    Assert-Throws {
        Invoke-MemLabsConfigMgrPkiConversion -DeployConfig $guestConfig -CurrentVM $site -ConfigFilePath 'fixture.json' -LogPath 'C:\fixture'
    } '*'
}
foreach ($failure in @('MissingRow', 'DuplicateRow', 'MissingProperty', 'InvalidProperty', 'NoConvergence')) {
    $script:Mode = $failure
    Assert-True (-not (Get-MemLabsConfigMgrRoleHttpsState -ServerFQDN 'ROLE.lab.test' -SiteCode 'PRI' -Role MP).Ready) `
        "$failure incorrectly verified a role as HTTPS."
}
$script:Mode = 'ImplicitRoles'
$script:Calls.Clear()
Invoke-MemLabsConfigMgrPkiConversion -DeployConfig $guestConfig -CurrentVM $site -ConfigFilePath 'fixture.json' -LogPath 'C:\fixture'
Assert-True ($script:Calls.Contains('MP:SITE.lab.test/PRI') -and $script:Calls.Contains('DP:SITE.lab.test/PRI')) `
    'Existing default co-located MP/DP roles were missed because InstallMP/DP flags were absent.'
$script:Mode = 'SecondaryScope'
Assert-True (Get-MemLabsConfigMgrRoleHttpsState -ServerFQDN 'ROLE.lab.test' -SiteCode SEC -Role MP -ProviderSiteCode PRI).Ready `
    'Secondary-site HTTPS readback did not use its managing provider.'
$tokens = $null; $errors = $null
$workflowAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'DSC\phases\ScriptWorkFlow.ps1'), [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'ScriptWorkflow has parser errors.'
$refresh = @($workflowAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$requiresTlsRefresh'
        }, $true))
$bounce = @($workflowAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '$requiresTlsRefresh -and -not (Test-Path $mpBounceFlag)'
        }, $true))
Assert-True ($refresh.Count -eq 1 -and $bounce.Count -eq 1) 'Could not locate production MP TLS refresh control flow.'
$bounceBlock = [scriptblock]::Create($refresh[0].Extent.Text + "`n" + $bounce[0].Extent.Text)
$script:BounceCalls = [Collections.Generic.List[string]]::new()
$script:BounceMode = 'Ready'
function Test-Path { param($Path) $false }
function iisreset.exe {
    param($Argument)
    $script:BounceCalls.Add('IIS')
    $global:LASTEXITCODE = 0
    if ($script:BounceMode -eq 'IisFailure') { $global:LASTEXITCODE = 5 }
}
function Restart-Service { [CmdletBinding()]param($Name, [switch]$Force) $script:BounceCalls.Add('CcmExec') }
function Restart-Computer {
    [CmdletBinding()]param($ComputerName, [switch]$Force)
    if ($script:BounceMode -eq 'RestartFailure') { throw 'fixture restart failure' }
    $script:BounceCalls.Add("Restart:$ComputerName")
}
function Start-Sleep { param($Seconds) }
function Get-Service { [CmdletBinding()]param($ComputerName, $Name) [pscustomobject]@{ Status = 'Running' } }
function Set-Content {
    [CmdletBinding()]param($Path, $Value, [switch]$Force, $Encoding)
    if ($script:BounceMode -eq 'StampFailure') { throw 'fixture flag write failure' }
    $script:BounceCalls.Add('Stamp')
}
$local = $site.PSObject.Copy()
$local | Add-Member -MemberType NoteProperty -Name installMP -Value $true
$ThisVM = $local
$deployConfig = [pscustomobject]@{ virtualMachines = @($local, $roleVm) }
$DomainFullName = 'lab.test'
$mpBounceFlag = 'C:\fixture\mp.flag'
$needCertPulse = $false
& $bounceBlock
Assert-True (($script:BounceCalls -join ',') -eq 'IIS,CcmExec,Restart:ROLE,Stamp') `
    'PKI retrofit skipped local/remote MP TLS refresh when no new client push was required.'
foreach ($failure in @('IisFailure', 'RestartFailure', 'StampFailure')) {
    $script:BounceCalls.Clear()
    $script:BounceMode = $failure
    Assert-Throws { & $bounceBlock } '*'
    Assert-True (-not $script:BounceCalls.Contains('Stamp')) "$failure incorrectly recorded a successful TLS refresh."
}
$script:BounceCalls.Clear()
$ThisVM.pkiReconfigure = $false
& $bounceBlock
Assert-True ($script:BounceCalls.Count -eq 0) 'An ordinary already-installed client triggered a new MP TLS restart.'
Write-Host 'PASS -- existing MP/DP/SUP HTTPS updates, independent site-control readback, scoped targets, and failure propagation.'
Write-Host 'PASS -- existing MP TLS refresh is required without client push and cannot silently ignore restart or receipt failures.'
