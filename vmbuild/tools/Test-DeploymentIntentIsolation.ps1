#requires -Version 5.1
[CmdletBinding()]
param([switch]$GuestOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Read-TestAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parse failed: $Path; $($errors -join '; ')" }
    return $ast
}
function Import-TestFunction {
    param($Ast, [string]$Name)
    $definition = $Ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
    if (-not $definition) { throw "Function '$Name' was not found." }
    [scriptblock]::Create($definition.Extent.Text)
}
$configAst = Read-TestAst (Join-Path $root 'common\Common.Config.ps1')
$phaseAst = Read-TestAst (Join-Path $root 'common\Common.Phases.ps1')
foreach ($name in @('Test-MemLabsContextOnlyVM', 'Test-MemLabsPreserveExistingHierarchy', 'Test-PushClientRequested',
        'Get-MemLabsRequestedDeploymentVMs', 'Test-MemLabsRequestedVMIdentity', 'Resolve-MemLabsDeploymentPrimary')) {
    . (Import-TestFunction $configAst $name)
}
foreach ($name in @(
        'Test-MemLabsIncludeHiddenVmForPhase', 'Select-MemLabsPhaseConfigurationData',
        'Get-MemLabsExistingClientPushPlan', 'Assert-MemLabsExistingDeploymentDependencies',
        'Get-MemLabsDomainControllerReadinessProbe', 'Invoke-MemLabsExistingClientPush', 'Get-MemLabsExistingSiteConnectionScript',
        'Get-ConfigurationData', 'Get-Phase6ConfigurationData', 'Get-Phase8ConfigurationData', 'Sync-MemLabsRequestedDhcpRelays',
        'Set-CmMediaMountAndShare', 'Clear-CmMediaMount', 'Get-CmExternalSchemaServers', 'Get-MemLabsRequestedDirectoryBindingPlan', 'Invoke-MemLabsRequestedDirectoryBindings'
    )) {
    . (Import-TestFunction $phaseAst $name)
}
function Write-Log { param($Text, [switch]$LogOnly, [switch]$Verbose) }

$guestCommand = $phaseAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-MemLabsExistingClientPush'
    }, $true).Body.Find({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-VmCommand'
    }, $true)
$guestArgument = $guestCommand.CommandElements | Where-Object {
    $_ -is [Management.Automation.Language.ScriptBlockExpressionAst]
}
if (@($guestArgument).Count -ne 1) { throw 'Scoped client-push guest block was not found uniquely.' }
$guest = $guestArgument.ScriptBlock.GetScriptBlock()
foreach ($mode in @('Ready', 'MissingDevice', 'AmbiguousDevice', 'InvalidResource', 'BrokenProvider', 'StoppedService', 'MissingModule', 'WrongDriveRoot', 'MissingProvider')) {
    & {
        param($Mode, $Guest)
        $script:PushMode = $Mode
        $script:PushCalls = [Collections.Generic.List[string]]::new()
        function Get-ItemPropertyValue {
            param($Path, $Name)
            if ($Name -eq 'Site Code') { return 'PRI' }
            if ($Name -eq 'UI Installation Directory') { return 'C:\ConfigMgr\AdminConsole' }
            throw "Unexpected registry lookup '$Name'."
        }
        function Get-Service { param($Name, $ErrorAction); return [pscustomobject]@{ Status = $(if ($script:PushMode -eq 'StoppedService') { 'Stopped' } else { 'Running' }) } }
        function Test-Path { param($LiteralPath, $PathType); return $script:PushMode -ne 'MissingModule' }
        function Import-Module { param($Name, $ErrorAction) }
        function Get-PSDrive {
            param($Name, $PSProvider, $ErrorAction)
            return [pscustomobject]@{ Name = 'PRI'; Root = $(if ($script:PushMode -eq 'WrongDriveRoot') { 'UNRELATED.fixture.test' } else { 'PRI1.fixture.test' }) }
        }
        function Get-WmiObject {
            param($Namespace, $Class, $ErrorAction)
            if ($script:PushMode -ne 'MissingProvider') { [pscustomobject]@{ SiteCode = 'PRI'; ProviderForLocalSite = $true; Machine = 'PRI1.fixture.test' } }
        }
        function Set-Location { param($Path) }
        function Get-CMClientPushInstallation {
            param($SiteCode, $ErrorAction)
            if ($script:PushMode -eq 'BrokenProvider') { throw 'Deliberate provider fault.' }
            return [pscustomobject]@{ SiteCode = $SiteCode }
        }
        function Get-CMDevice {
            param($Name, $ErrorAction)
            if ($Name -eq 'CLIENT2' -and $script:PushMode -eq 'MissingDevice') { return }
            if ($script:PushMode -eq 'InvalidResource') { return [pscustomobject]@{ Name = $Name; ResourceID = 'not-a-resource-id' } }
            [pscustomobject]@{ Name = $Name; ResourceID = $(if ($Name -eq 'CLIENT1') { 11 } else { 12 }) }
            if ($script:PushMode -eq 'AmbiguousDevice') { [pscustomobject]@{ Name = $Name; ResourceID = 99 } }
        }
        function Install-CMClient {
            [CmdletBinding()]
            param([string]$DeviceId, [string]$SiteCode)
            $script:PushCalls.Add("$SiteCode/$DeviceId")
        }
        function Restart-Service { throw 'Existing service repair is forbidden.' }
        function Start-Service { throw 'Existing service repair is forbidden.' }
        function Set-CMClientPushInstallation { throw 'Existing site-wide settings must not be changed.' }
        function New-CMAccount { throw 'Existing site accounts must not be changed.' }
        function Invoke-CMSystemDiscovery { throw 'Hierarchy discovery must not be triggered as a repair.' }
        function Remove-CMDevice { throw 'Existing records must not be removed.' }
        $result = $null
        $failure = ''
        try { $result = & $Guest 'PRI' @('CLIENT1', 'CLIENT2') (Get-MemLabsExistingSiteConnectionScript).ToString() }
        catch { $failure = $_.Exception.Message }
        if ($Mode -eq 'Ready') {
            Assert-True (-not $failure -and $result.Status -eq 'Submitted' -and
                ($script:PushCalls -join ',') -eq 'PRI/11,PRI/12') 'The narrow guest action did not submit exactly the approved resource IDs.'
        }
        else {
            Assert-True ($failure -and $script:PushCalls.Count -eq 0) "Broken prerequisite '$Mode' was repaired, ignored, or allowed partial client submission."
            if ($Mode -eq 'MissingDevice') {
                Assert-True ($failure -like '*Resolve discovery explicitly*') 'Missing discovery did not report its specific prerequisite.'
            }
        }
    } $mode $guest
}
$workflowAst = Read-TestAst (Join-Path $root 'DSC\phases\ScriptFunctions.ps1')
foreach ($name in @('Test-MemLabsWorkflowContextOnlyVM', 'Get-MemLabsWorkflowRequestedVMs', 'Get-MemLabsRetainedCasContext')) {
    . (Import-TestFunction $workflowAst $name)
}
& {
    $old = [pscustomobject]@{
        vmName = 'OLD-ROLES'; role = 'SiteSystem'; siteCode = 'PRI'; hidden = $true
        installDP = $true; installMP = $true; installRP = $true; installSUP = $true; InstallSMSProv = $true
    }
    $new = [pscustomobject]@{ vmName = 'NEW-ROLE'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true }
    $owner = [pscustomobject]@{
        vmName = 'NEW-PRI'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'
        thisParams = [pscustomobject]@{ ParentSiteServer = 'OLD-CAS' }
    }
    $cas = [pscustomobject]@{ vmName = 'OLD-CAS'; role = 'CAS'; siteCode = 'CAS'; hidden = $true }
    $fixture = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'fixture.test'; domainNetBiosName = 'FIXTURE' }
        cmOptions = [pscustomobject]@{ UsePKI = $false }
        parameters = [pscustomobject]@{ ThisMachineName = 'NEW-PRI' }
        virtualMachines = @($old, $new, $owner, $cas)
    }
    $deployConfig = $fixture
    $requestedVMs = @(Get-MemLabsWorkflowRequestedVMs -DeployConfig $fixture)
    Assert-True (($requestedVMs.vmName -join ',') -eq 'NEW-ROLE,NEW-PRI') 'Guest workflow selection included old role flags as new requests.'
    $dpAst = Read-TestAst (Join-Path $root 'DSC\phases\InstallDPMPClient.ps1')
    $selection = $dpAst.Find({
            param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -eq 'vm' -and $node.Condition.Extent.Text.Contains('SiteSystem')
        }, $true)
    if (-not $selection) { throw 'Owned workflow SiteSystem planner was not found.' }
    $DPs = @(); $MPs = @(); $PullDPs = @(); $BareSiteSystems = @()
    $ValidSiteCodes = @('PRI'); $ReportingSiteCodes = @()
    # Execute in the caller scope because the production loop appends plan arrays there.
    . ([scriptblock]::Create($selection.Extent.Text))
    Assert-True (($DPs.ServerName -join ',') -eq 'NEW-ROLE' -and $MPs.Count -eq 0 -and $PullDPs.Count -eq 0 -and $BareSiteSystems.Count -eq 0) `
        'An owned new Primary planned an unrequested retained DP/MP/site system.'
    $path = Join-Path ([IO.Path]::GetTempPath()) "memlabs-owned-workflow-$([guid]::NewGuid().ToString('N')).json"
    $fixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    try {
        $ownedOutcome = [pscustomobject]@{ Statuses = [Collections.Generic.List[string]]::new(); SupStatus = '' }
        function Write-DscStatus { param($Status); $ownedOutcome.Statuses.Add("$Status") }
        function Get-VmSqlConnectionTarget { param($SiteVm, $DeployConfig, $DomainFullName); return 'OLD-CAS.fixture.test' }
        function Read-ScriptWorkflowData {
            param($ConfigurationFile, $RequiredSteps)
            if ($ConfigurationFile.StartsWith('\\')) { throw 'A child without requested SUPs must not wait on deliberately broken CAS SUM receipts.' }
            return [pscustomobject]@{ InstallSUP = [pscustomobject]@{ Status = 'NotStarted'; StartTime = ''; EndTime = '' } }
        }
        function Write-ScriptWorkflowData { param($Configuration, $ConfigurationFile); $ownedOutcome.SupStatus = "$($Configuration.InstallSUP.Status)" }
        function Get-ItemPropertyValue { param($Path, $Name); if ($Name -ne 'Site Code') { throw 'Unexpected installation lookup.' }; return 'PRI' }
        function Get-SMSProvider { param($SiteCode); return [pscustomobject]@{ FQDN = 'NEW-PRI.fixture.test' } }
        function Set-CMSiteProvider { param($SiteCode, $ProviderFQDN); return $true }
        function Set-Location { param($Path) }
        function Get-Location { return [pscustomobject]@{ Drive = [pscustomobject]@{ Name = 'PRI' } } }
        function Get-CMSite { return [pscustomobject]@{ SiteCode = 'PRI'; ReportingSiteCode = '' } }
        function Get-CMReportingPointReadiness { throw 'An intentionally broken context reporting point must not be queried or repaired.' }
        function Get-CMSoftwareUpdatePointReadiness { throw 'An unrelated context SUP must not be queried or repaired.' }
        function Confirm-CMWsusPoolHardening { throw 'An unrelated context WSUS pool must not be hardened.' }
        & (Join-Path $root 'DSC\phases\InstallRoles.ps1') -ConfigFilePath $path -LogPath 'C:\fixture'
        Assert-True ($ownedOutcome.SupStatus -eq 'Completed') 'Owned role workflow did not complete without inspecting context RP/SUP flags.'
        function Get-ItemPropertyValue { throw 'Context provider flags must not reach site setup/registry work.' }
        & (Join-Path $root 'DSC\phases\InstallProvider.ps1') -ConfigFilePath $path -LogPath 'C:\fixture'
        Assert-True ($ownedOutcome.Statuses[-1] -like '*Nothing to do*') 'Owned provider workflow did not ignore old provider flags.'
    }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
}
& {
    $shareDefinition = $workflowAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CMDistributionPointShareAccess'
        }, $true)
    $jobCommand = $shareDefinition.Body.Find({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Job'
        }, $true)
    $producer = @($jobCommand.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] })[0].ScriptBlock.GetScriptBlock()
    $script:ProbeWrites = 0
    function Get-Item { param($LiteralPath, [switch]$Force, $ErrorAction); return [pscustomobject]@{ Name = 'existing-share' } }
    function Get-ChildItem { param($LiteralPath, [switch]$Force, $ErrorAction); return [pscustomobject]@{ Name = 'existing-content' } }
    function Set-Content { param($LiteralPath, $Value, [switch]$NoNewline, $Encoding, $ErrorAction); $script:ProbeWrites++ }
    function Remove-Item { param($LiteralPath, [switch]$Force, $ErrorAction); $script:ProbeWrites++ }
    $proof = & $producer 'OLD-DP.fixture.test' $true
    Assert-True ($proof.Ready -and $script:ProbeWrites -eq 0) 'Read-only existing pull-source validation wrote an access-probe file.'
    $proof = & $producer 'NEW-DP.fixture.test' $false
    Assert-True ($proof.Ready -and $script:ProbeWrites -eq 2) 'Requested producer access no longer proves write/delete access.'
}
foreach ($case in @('Ready', 'RestrictedObject', 'RestrictedInheritedObject', 'RestrictedPropagation', 'ExistingDelegation', 'MissingGroup', 'DeniedContainer', 'WrongContainer', 'NoDirectoryWork')) {
    & {
        param($Case)
        $oldSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1000')
        $newSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
        $supSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002')
        $siteDn = 'CN=ConfigMgr Site Servers,DC=fixture,DC=test'
        $iisDn = 'CN=ConfigMgr IIS Servers,DC=fixture,DC=test'
        $adFixture = [pscustomobject]@{
            Case = $Case; RpcCalls = 0; Adds = [Collections.Generic.List[string]]::new(); AclWrites = 0
            Members = @{
                $siteDn = [Collections.Generic.List[object]]::new()
                $iisDn = [Collections.Generic.List[object]]::new()
            }
            Acl = [DirectoryServices.ActiveDirectorySecurity]::new()
        }
        foreach ($dn in @($siteDn, $iisDn)) { $adFixture.Members[$dn].Add([pscustomobject]@{ SID = $oldSid }) }
        $adFixture.Acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new(
                $oldSid, [DirectoryServices.ActiveDirectoryRights]::GenericRead, [Security.AccessControl.AccessControlType]::Allow))
        if ($Case -eq 'DeniedContainer') {
            $adFixture.Acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new(
                    $newSid, [DirectoryServices.ActiveDirectoryRights]::GenericAll, [Security.AccessControl.AccessControlType]::Deny))
        }
        if ($Case -in @('RestrictedObject', 'RestrictedInheritedObject', 'RestrictedPropagation', 'ExistingDelegation')) {
            $objectType = if ($Case -eq 'RestrictedObject') { [guid]::NewGuid() } else { [guid]::Empty }
            $inheritedType = if ($Case -eq 'RestrictedInheritedObject') { [guid]::NewGuid() } else { [guid]::Empty }
            $inheritance = if ($Case -eq 'RestrictedPropagation') { [DirectoryServices.ActiveDirectorySecurityInheritance]::Children } else { [DirectoryServices.ActiveDirectorySecurityInheritance]::All }
            $adFixture.Acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new(
                    $newSid, [DirectoryServices.ActiveDirectoryRights]::GenericAll, [Security.AccessControl.AccessControlType]::Allow,
                    $objectType, $inheritance, $inheritedType))
        }
        $fixture = [pscustomobject]@{
            vmOptions = [pscustomobject]@{ domainName = 'fixture.test'; adminName = 'Admin' }
            cmOptions = [pscustomobject]@{ UsePKI = $true; Install = $false }
            virtualMachines = @(
                [pscustomobject]@{ vmName = 'DC'; role = 'DC'; hidden = $true },
                [pscustomobject]@{ vmName = 'OLDPRI'; role = 'Primary'; hidden = $true },
                [pscustomobject]@{ vmName = 'NEWPRI'; role = 'Primary' },
                [pscustomobject]@{ vmName = 'NEWSUP'; role = 'SiteSystem'; installSUP = $true }
            )
        }
        if ($Case -eq 'NoDirectoryWork') { $fixture.virtualMachines = @($fixture.virtualMachines | Where-Object { $_.hidden }) }
        function Import-Module { param($Name, $ErrorAction) }
        function Get-ADGroup {
            param($Identity, $ErrorAction)
            if ($adFixture.Case -eq 'MissingGroup' -and $Identity -eq 'ConfigMgr IIS Servers') {
                Write-Error 'Missing required existing group' -Category ObjectNotFound -ErrorAction Stop
            }
            return [pscustomobject]@{
                GroupCategory = 'Security'; SID = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-2000')
                DistinguishedName = $(if ($Identity -eq 'ConfigMgr IIS Servers') { $iisDn } else { $siteDn })
            }
        }
        function Get-ADRootDSE { param($ErrorAction); return [pscustomobject]@{ defaultNamingContext = 'DC=fixture,DC=test' } }
        function Get-ADObject { param($Identity, $ErrorAction); return [pscustomobject]@{ ObjectClass = $(if ($adFixture.Case -eq 'WrongContainer') { 'computer' } else { 'container' }) } }
        function Get-ADComputer {
            param($Identity, $Properties, $ErrorAction)
            return [pscustomobject]@{
                SID = $(if ($Identity -eq 'NEWPRI') { $newSid } else { $supSid })
                DNSHostName = "$Identity.fixture.test"; DistinguishedName = "CN=$Identity,DC=fixture,DC=test"; tokenGroups = @()
            }
        }
        function Get-ADGroupMember { param($Identity, [switch]$Recursive, $ErrorAction); return $adFixture.Members[$Identity].ToArray() }
        function Add-ADGroupMember {
            param($Identity, $Members, $ErrorAction)
            $sid = if ($Members -like 'CN=NEWPRI,*') { $newSid } else { $supSid }
            $adFixture.Members[$Identity].Add([pscustomobject]@{ SID = $sid })
            $adFixture.Adds.Add("$Identity|$Members")
        }
        function Get-Acl { param($LiteralPath, $ErrorAction); return $adFixture.Acl }
        function Set-Acl { param($LiteralPath, $AclObject, $ErrorAction); $adFixture.Acl = $AclObject; $adFixture.AclWrites++ }
        function New-ADGroup { throw 'Existing hierarchy groups must not be recreated.' }
        function New-ADObject { throw 'Existing System Management container must not be recreated.' }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, $VmDomainAccount, [switch]$RequireDomainIdentity, [switch]$AsJob, $TimeoutSeconds,
                $SessionMaxRetries, [switch]$RebootIfUnresponsive, [switch]$FailOnRemoteError, $ScriptBlock, $ArgumentList)
            $adFixture.RpcCalls++
            Assert-True ($VmName -eq 'DC' -and $RequireDomainIdentity -and -not $RebootIfUnresponsive) 'Directory binding work widened its owner or enabled repair.'
            try { return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @(& $ScriptBlock @ArgumentList) } }
            catch { return [pscustomobject]@{ ScriptBlockFailed = $true; ErrorDetails = $_.Exception.Message } }
        }
        $failure = ''
        try { Invoke-MemLabsRequestedDirectoryBindings -DeployConfig $fixture } catch { $failure = $_.Exception.Message }
        $authorized = $Case -in @('Ready', 'RestrictedObject', 'RestrictedInheritedObject', 'RestrictedPropagation', 'ExistingDelegation')
        Assert-True ((-not $failure) -eq ($authorized -or $Case -eq 'NoDirectoryWork')) "Required directory binding '$Case' was misclassified: $failure"
        $expectedAdds = if ($authorized) { 3 } else { 0 }
        Assert-True ($adFixture.Adds.Count -eq $expectedAdds -and
            @($adFixture.Members[$siteDn] | Where-Object { $_.SID -eq $oldSid }).Count -eq 1 -and
            @($adFixture.Members[$iisDn] | Where-Object { $_.SID -eq $oldSid }).Count -eq 1) 'New directory authorizations changed unrelated old membership.'
        Assert-True ($adFixture.AclWrites -eq $(if ($authorized -and $Case -ne 'ExistingDelegation') { 1 } else { 0 })) 'Directory baseline failure was repaired or a new site binding was not written.'
        if ($Case -eq 'NoDirectoryWork') { Assert-True ($adFixture.RpcCalls -eq 0) 'A request with no new AD binding accessed the retained DC.' }
    } $case
}
if ($GuestOnly) {
    Write-Host "PASS -- $script:Assertions scoped client-push guest assertions on PowerShell $($PSVersionTable.PSVersion)."
    return
}
. (Join-Path $root 'common\Common.ExistingHierarchy.ps1')
& {
    $aclWrites = [Collections.Generic.List[string]]::new()
    $hypervAst = Read-TestAst (Join-Path $root 'common\Common.HyperV.ps1')
    foreach ($name in @('Set-VmProxyEnforcementForConfig', 'Set-VmProxyEnforcementForAllLabs')) { . (Import-TestFunction $hypervAst $name) }
    function Test-VmUsesProxy { param($Vm, $DeployConfig); return $Vm.useProxy -eq $true }
    function Test-VmIsLinux { param($Vm); return $false }
    function Set-VmProxyEnforcement { param($VmName); $aclWrites.Add("SET:$VmName"); return $true }
    function Clear-VmProxyEnforcement { param($VmName); $aclWrites.Add("CLEAR:$VmName") }
    function Get-VMNetworkAdapterExtendedAcl { param($VMName, $ErrorAction); return [pscustomobject]@{ Weight = 5001 } }
    $global:MemLabsProxyAclWeightMin = 5000; $global:MemLabsProxyAclWeightMax = 5099
    $fixture = [pscustomobject]@{ virtualMachines = @(
            [pscustomobject]@{ vmName = 'PROXY'; role = 'Proxy'; hidden = $true },
            [pscustomobject]@{ vmName = 'NEWCLIENT'; role = 'DomainMember'; useProxy = $true },
            [pscustomobject]@{ vmName = 'OLDIN'; role = 'DomainMember'; useProxy = $true; hidden = $true },
            [pscustomobject]@{ vmName = 'OLDOUT'; role = 'DomainMember'; useProxy = $false; hidden = $true },
            [pscustomobject]@{ vmName = 'OLDOSD'; role = 'OSDClient'; hidden = $true }
        ) }
    function Get-List { param($Type); return $fixture.virtualMachines }
    $null = Set-VmProxyEnforcementForConfig -deployConfig $fixture
    $null = Set-VmProxyEnforcementForAllLabs -VMNames @('NEWCLIENT')
    Assert-True (($aclWrites -join ',') -eq 'SET:NEWCLIENT,SET:NEWCLIENT') 'Expansion proxy hooks repaired retained opted-in/out or OSD ACLs.'
}
& {
    $relayPaths = @(
        [pscustomobject]@{ mode = 'Relay'; relayVM = 'NEWRELAY'; clientNetwork = '192.168.1.0'; distributionPointIPv4 = '192.168.2.5' },
        [pscustomobject]@{ mode = 'Invalid'; relayVM = 'OLDRELAY'; clientNetwork = '192.168.9.0'; reason = 'deliberate reproduction' }
    )
    $fixture = [pscustomobject]@{
        vmOptions = [pscustomobject]@{}
        virtualMachines = @([pscustomobject]@{ vmName = 'NEWRELAY'; role = 'DHCPRelay' }, [pscustomobject]@{ vmName = 'OLDRELAY'; role = 'DHCPRelay'; hidden = $true })
        osdPxePaths = $relayPaths
    }
    function Get-OsdPxePaths { param($Config); return $relayPaths }
    $linuxAst = Read-TestAst (Join-Path $root 'common\Common.Linux.ps1')
    $definition = $linuxAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sync-LinuxDhcpRelay' }, $true)
    $statements = @($definition.Body.EndBlock.Statements)
    $prefix = @()
    foreach ($statement in $statements) {
        if ($statement -is [Management.Automation.Language.ForEachStatementAst] -and $statement.Variable.VariablePath.UserPath -eq 'relayName') { break }
        $prefix += $statement.Extent.Text
    }
    $nativeScope = [scriptblock]::Create('param($DeployConfig,$Paths)' + "`n" + ($prefix -join "`n") + "`n[pscustomobject]@{Paths=`$paths;Names=`$relayNames}")
    function Sync-LinuxDhcpRelay {
        param($DeployConfig, $Paths)
        function Get-OsdPxePaths { throw 'The authoritative requested path set must not be re-resolved inside reconciliation.' }
        $scope = & $nativeScope $DeployConfig $Paths
        Assert-True (($scope.Names -join ',') -eq 'NEWRELAY' -and $scope.Paths.Count -eq 1) 'Retained stopped relay or unrelated invalid path re-entered reconciliation.'
        return $true
    }
    $null = Sync-MemLabsRequestedDhcpRelays -DeployConfig $fixture
}
& {
    $external = [pscustomobject]@{ vmName = 'EXTERNAL'; role = 'CAS'; domain = 'external.test'; cmOptions = [pscustomobject]@{ version = 'current-branch' } }
    $fixture = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'new.test' }
        virtualMachines = @([pscustomobject]@{ vmName = 'NEWDC'; role = 'DC'; thisParams = [pscustomobject]@{ ExternalTopLevelSiteServer = 'EXTERNAL.external.test' } })
    }
    function Get-List { param($Type, [switch]$SmartUpdate); return $external }
    function Get-CmIsoPathForVersion { param($CmVersion); return 'C:\fixture\CM.iso' }
    $targets = @(Get-CmExternalSchemaServers -deployConfig $fixture)
    Assert-True ($targets.Count -eq 1 -and $targets[0].Vm.vmName -eq 'EXTERNAL') 'Actual host-wide external media lookup was not exercised.'
    $mediaState = [pscustomobject]@{ Ready = $true; Reads = 0 }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries, [switch]$RebootIfUnresponsive,
            [switch]$FailOnRemoteError, $ScriptBlock, $ArgumentList)
        $mediaState.Reads++
        Assert-True ($VmName -eq 'EXTERNAL' -and -not $RebootIfUnresponsive) 'External prerequisite probe changed its target or enabled recovery.'
        function Get-SmbShare { param($Name, $ErrorAction); return [pscustomobject]@{ Path = 'C:\fixture\existing-media' } }
        function Test-Path { param($LiteralPath, $PathType); return $mediaState.Ready }
        try { return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @(& $ScriptBlock @ArgumentList) } }
        catch { return [pscustomobject]@{ ScriptBlockFailed = $true; ErrorDetails = $_.Exception.Message } }
    }
    function Set-VMDvdDrive { throw 'External source ISO must not be mounted/ejected.' }
    function New-SmbShare { throw 'External media share must not be repaired.' }
    $null = Set-CmMediaMountAndShare -Target $targets[0] -deployConfig $fixture -Phase 2
    $mediaState.Ready = $false
    $failure = ''
    try { Set-CmMediaMountAndShare -Target $targets[0] -deployConfig $fixture -Phase 2 } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*no ISO, volume or share was changed*') 'Missing external schema media was silently mounted/shared instead of reported.'
    $reads = $mediaState.Reads
    $null = Clear-CmMediaMount -Target $targets[0] -deployConfig $fixture -Phase 2
    Assert-True ($mediaState.Reads -eq $reads) 'External media cleanup attempted to eject/remove retained media.'
}
& {
    $owner = [pscustomobject]@{ vmName = 'OWNER'; role = 'Primary'; siteCode = 'PRI'; hidden = $true }
    $targets = @(
        [pscustomobject]@{ vmName = 'ROLE'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true },
        [pscustomobject]@{ vmName = 'SUP'; role = 'WSUS'; siteCode = 'PRI'; installSUP = $true },
        [pscustomobject]@{ vmName = 'SEC'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI' },
        [pscustomobject]@{ vmName = 'PASSIVE'; role = 'PassiveSite'; siteCode = 'PRI' },
        [pscustomobject]@{ vmName = 'SQLROLE'; role = 'DomainMember'; sqlVersion = '2022'; installRP = $true }
    )
    $fixture = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'fixture.test'; domainNetBiosName = 'FIXTURE' }
        cmOptions = [pscustomobject]@{ Install = $false; UsePKI = $false }
        virtualMachines = @($owner) + $targets
    }
    $action = [pscustomobject]@{ Kind = 'SiteRoles'; OwnerVMName = 'OWNER'; TargetVMNames = @($targets.vmName) }
    $data = Get-Phase8ConfigurationData -deployConfig $fixture -ScopedRoleActions @($action)
    $data = Select-MemLabsPhaseConfigurationData -ConfigurationData $data -DeployConfig $fixture -Phase 8
    Assert-True (@($data.AllNodes | Where-Object NodeName -ne '*').Count -eq 5 -and
        @($data.AllNodes | Where-Object { $_.NodeName -eq 'SQLROLE' -and $_.Role -eq 'SqlServer' }).Count -eq 1) `
        'Install=false excluded requested role preparation or mapped a remote-SQL role incorrectly.'
    $run = [guid]::NewGuid()
    Initialize-MemLabsScopedHierarchyActionRun -DeployConfig $fixture -Actions @($action) -RunId $run
    $startupRequests = [Collections.Generic.List[string]]::new()
    function Get-List { param($Type, $DomainName, [switch]$SmartUpdate); return $fixture.virtualMachines }
    function Get-CriticalVMs { param($domain, $vmNames, $InputVMs); return [pscustomobject]@{ Names = @($vmNames) } }
    function Invoke-SmartStartVMs { param($CritList); foreach ($name in $CritList.Names) { $startupRequests.Add("$name") }; return 0 }
    function Write-Progress2 { param($Activity, $Status, $PercentComplete, [switch]$log) }
    function Start-Sleep { param($Milliseconds) }
    $ConfigurationData = Get-ConfigurationData -Phase 8 -deployConfig $fixture -OnlyVMs @('SUP')
    Assert-True (($ConfigurationData.AllNodes.NodeName -join ',') -eq 'SUP,*' -and
        ($startupRequests -join ',') -eq 'SUP' -and
        (Get-MemLabsScopedRoleRetryRunId -DeployConfig $fixture -VMNames @('SUP')) -eq $run.ToString() -and
        $targets[0].phase8ScopedHierarchyAction.RunId -eq $run.ToString()) `
        'A target recovery restarted unrelated preparations or lost the outstanding owner action identity.'
    $startupRequests.Clear()
    $null = Get-ConfigurationData -Phase 8 -deployConfig $fixture
    Assert-True (($startupRequests -join ',') -eq ($targets.vmName -join ',')) 'Normal phase preparation lost its complete requested target scope.'
    $startupRequests.Clear()
    $null = Get-ConfigurationData -Phase 6 -deployConfig $fixture -OnlyVMs @('SUP')
    Assert-True (($startupRequests -join ',') -eq 'SUP') 'Target-only preparation filtering occurred after startup in another multi-node phase.'
    $owner.hidden = $false
    $fixture.virtualMachines += [pscustomobject]@{ vmName = 'OTHERBDC'; role = 'BDC'; State = 'Off' }
    function Start-VM2 { throw 'An unrelated BDC must not start during a requested target retry.' }
    $startupRequests.Clear()
    $null = Get-ConfigurationData -Phase 8 -deployConfig $fixture -OnlyVMs @('SUP')
    Assert-True (($startupRequests -join ',') -eq 'SUP') 'Full-provisioning target recovery still performed unrelated BDC startup.'
    function Get-Phase2ConfigurationData { param($deployConfig); return @{ AllNodes = @(@{ NodeName = 'LOCALHOST'; Role = 'DomainMember' }, @{ NodeName = '*' }) } }
    $startupRequests.Clear()
    $phase2 = Get-ConfigurationData -Phase 2 -deployConfig $fixture -OnlyVMs @('SUP')
    Assert-True ($phase2 -and ($phase2.AllNodes.NodeName -join ',') -eq 'LOCALHOST,*' -and $startupRequests.Count -eq 0) `
        'Phase 2 target recovery discarded its valid LOCALHOST configuration or inherited another startup scope.'
    $owner.hidden = $true
    $dispatch = $phaseAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-PhaseJobs' }, $true)
    $generation = $dispatch.Body.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$phaseRunGuid' }, $true)
    $generationStatements = @($generation.Parent.Statements)
    $generationIndex = [array]::IndexOf($generationStatements, $generation)
    $generationFactory = [scriptblock]::Create(
        'param($Phase,$OnlyVMs,$PreparationRunId,$deployConfig,$scopedHierarchyActions)' + "`n" +
        (($generationStatements[$generationIndex..($generationIndex + 2)].Extent.Text) -join "`n") + "`nreturn `$phaseRunGuid")
    $token = $run.ToString()
    Assert-True ((& $generationFactory 3 @('SUP') $token $fixture @()) -eq $token) 'Ordinary coordinated worker recovery replaced its outstanding generation.'
    Assert-True ((& $generationFactory 8 @('SUP') $token $fixture @()) -eq $token) 'Scoped actor/target recovery changed its coordinator token.'
    $failure = ''
    try { $null = & $generationFactory 8 @('SUP') ([guid]::NewGuid().ToString()) $fixture @() } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*conflicts*') 'A conflicting coordinator/actor generation was silently substituted.'
    $job = [pscustomobject]@{ Id = 1 }
    $phaseRunGuid = $token
    $multiNodeDsc = $true
    $deployConfig = [pscustomobject]@{ virtualMachines = @([pscustomobject]@{ vmName = 'DC'; role = 'DC' }) }
    $configurationDataForJob = @{ AllNodes = @(@{ NodeName = 'DC' }, @{ NodeName = 'MEMBER' }, @{ NodeName = '*' }) }
    $stamps = @($dispatch.Body.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Member' -and
                $node.Extent.Text -match 'MemLabsPreparationRunId|MemLabsUsesDscCoordinator|MemLabsCoordinatorConfigurationData'
            }, $true))
    Assert-True ($stamps.Count -eq 3) 'Recovery generation/cohort dispatch contracts were not found.'
    . ([scriptblock]::Create(($stamps | ForEach-Object { $_.Parent.Extent.Text }) -join "`n"))
    Assert-True ($job.MemLabsPreparationRunId -eq $token -and $job.MemLabsUsesDscCoordinator -and
        ($job.MemLabsCoordinatorConfigurationData.AllNodes.NodeName -join ',') -eq 'DC,MEMBER,*') `
        'A coordinator job did not retain its original generation and complete cohort for recovery.'
}
& {
    . (Join-Path $root 'common\Common.ExistingHierarchy.Roles.ps1')
    . (Join-Path $root 'common\Common.ExistingHierarchy.Osd.ps1')
    . (Join-Path $root 'common\Common.ExistingHierarchy.BitLocker.ps1')
    foreach ($intent in @('New', 'ExistingVM', 'cmOptionsChanged')) {
        $owner = [pscustomobject]@{ vmName = 'OWNER'; role = 'Primary'; siteCode = 'PRI'; hidden = $true }
        if ($intent -eq 'New') { $owner.hidden = $false }
        else { $owner | Add-Member -NotePropertyName $intent -NotePropertyValue $true }
        $fixture = [pscustomobject]@{
            vmOptions = [pscustomobject]@{ domainName = 'fixture.test'; network = '192.168.1.0' }
            cmOptions = [pscustomobject]@{ Install = $false; UsePKI = $false }
            virtualMachines = @($owner,
                [pscustomobject]@{ vmName = 'ROLE'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true },
                [pscustomobject]@{ vmName = 'DP'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true; hidden = $true },
                [pscustomobject]@{ vmName = 'OSD'; role = 'OSDClient'; network = '192.168.1.0' })
            osdPxePaths = @([pscustomobject]@{ clientNetwork = '192.168.1.0'; mode = 'Direct'; distributionPointVM = 'DP'; distributionPointSiteCode = 'PRI' })
        }
        Assert-True (@(Get-MemLabsExistingHierarchyActions -DeployConfig $fixture).Count -eq 0) `
            'The aggregate Role/OSD planner disagreed with requested-owner intent.'
    }
}
& {
    $child = [pscustomobject]@{ vmName = 'NEWPRI'; role = 'Primary'; siteCode = 'NEW'; parentSiteCode = 'CAS'; installSUP = $false }
    $sup = [pscustomobject]@{ vmName = 'NEWSUP'; role = 'SiteSystem'; siteCode = 'NEW'; installSUP = $true }
    $cas = [pscustomobject]@{ vmName = 'OLDCAS'; role = 'CAS'; siteCode = 'CAS'; hidden = $true }
    $fixture = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'fixture.test' }; virtualMachines = @($child, $sup, $cas) }
    $phase6 = Get-Phase6ConfigurationData -deployConfig $fixture
    Assert-True (@($phase6.AllNodes | Where-Object { $_.NodeName -eq 'NEWPRI' -and $_.Role -eq 'WSUSApiOnly' }).Count -eq 1 -and
        @($phase6.AllNodes | Where-Object NodeName -eq 'OLDCAS').Count -eq 0) `
        'Remote-SUP child proof prerequisites were not confined to the requested new child.'
    $sup.installSUP = $false
    Assert-True ($null -eq (Get-Phase6ConfigurationData -deployConfig $fixture)) 'A child with no requested SUP acquired unrelated WSUS work.'
    $child.installSUP = $true
    $phase6 = Get-Phase6ConfigurationData -deployConfig $fixture
    Assert-True (@($phase6.AllNodes | Where-Object { $_.NodeName -eq 'NEWPRI' -and $_.Role -eq 'WSUS' }).Count -eq 1 -and
        @($phase6.AllNodes | Where-Object Role -eq 'WSUSApiOnly').Count -eq 0) 'A local SUP lost its normal WSUS provisioning or acquired duplicate work.'
}
function Get-MemLabsExistingRoleActions { param($DeployConfig) }
function Get-MemLabsExistingOsdActions { param($DeployConfig) }
function Get-MemLabsExistingBitLockerActions { param($DeployConfig) }

$dc = [pscustomobject]@{ vmName = 'DC1'; role = 'DC'; hidden = $true }
$primary = [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'; hidden = $true; clientPushTarget = $true }
$sql = [pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember'; sqlVersion = '2022'; hidden = $true; installRP = $true }
$client = [pscustomobject]@{ vmName = 'CLIENT1'; role = 'DomainMember'; pushClient = 'PRI'; memory = '4GB'; dynamicMinRam = '1GB' }
$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'fixture.test'; domainNetBiosName = 'FIXTURE' }
    parameters = [pscustomobject]@{ ExistingDCName = 'DC1' }
    virtualMachines = @($dc, $primary, $sql, $client)
}
$before = $config | ConvertTo-Json -Depth 10 -Compress
foreach ($phase in 0..11) {
    foreach ($context in @($dc, $primary, $sql)) {
        Assert-True (-not (Test-MemLabsIncludeHiddenVmForPhase -Vm $context -Phase $phase)) `
            "Context '$($context.vmName)' was scheduled for phase $phase."
    }
}
$plan = @(Get-MemLabsExistingClientPushPlan -DeployConfig $config)
Assert-True ($plan.Count -eq 1 -and $plan[0].OwnerVMName -eq 'PRI1' -and $plan[0].ClientVMName -eq 'CLIENT1') `
    'Client submission did not resolve its one explicit owner/action.'
$data = @{ AllNodes = @(
        @{ NodeName = '*' }, @{ NodeName = 'DC1'; Role = 'DC' }, @{ NodeName = 'PRI1'; Role = 'Primary' },
        @{ NodeName = 'SQL1'; Role = 'SqlServer' }, @{ NodeName = 'CLIENT1'; Role = 'DomainMember' }
    ) }
$selected = Select-MemLabsPhaseConfigurationData -ConfigurationData $data -DeployConfig $config -Phase 3
Assert-True (($selected.AllNodes.NodeName -join ',') -eq '*,CLIENT1') 'Phase data still applies DSC to existing hierarchy context.'
Assert-True (-not (Select-MemLabsPhaseConfigurationData -ConfigurationData (@{
                AllNodes = @(@{ NodeName = '*' }, @{ NodeName = 'PRI1'; Role = 'Primary' })
            }) -DeployConfig $config -Phase 8)) 'A contextual Primary still triggers Phase 8 setup, media, or recovery.'

& {
    $script:Observed = [Collections.Generic.List[string]]::new()
    $script:DcState = 'Running'
    $script:DcReady = $true
    function Get-VM {
        param($Name, $ErrorAction)
        $script:Observed.Add("$Name")
        return [pscustomobject]@{ State = $(if ($Name -eq 'SQL1') { 'Off' } else { $script:DcState }) }
    }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, [switch]$AsJob, $TimeoutSeconds,
            $SessionMaxRetries, [switch]$RebootIfUnresponsive, [switch]$SuppressLog)
        Assert-True (-not $RebootIfUnresponsive -and $VmName -eq 'DC1') 'Read-only readiness requested unrelated access or reboot recovery.'
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = [pscustomobject]@{ Ready = $script:DcReady } }
    }
    function Start-VM2 { throw 'Existing VM power must not be changed.' }
    function Stop-VM2 { throw 'Existing VM power must not be changed.' }
    function Restart-UnresponsiveVm { throw 'Existing VM recovery must not run.' }
    Assert-MemLabsExistingDeploymentDependencies -DeployConfig $config
    Assert-True (($script:Observed -join ',') -eq 'DC1,PRI1') 'Unrelated intentionally stopped SQL was treated as a required prerequisite.'
    $script:DcState = 'Off'
    $failure = ''
    try { Assert-MemLabsExistingDeploymentDependencies -DeployConfig $config }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like "*DC1*Start or repair it explicitly*") 'Stopped required DC did not block without being started.'
    $script:DcState = 'Running'
    $script:DcReady = $false
    $failure = ''
    try { Assert-MemLabsExistingDeploymentDependencies -DeployConfig $config }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*AD DS/DNS/Netlogon*left unchanged*') 'Broken existing AD did not stop with a no-repair prerequisite failure.'
}
& {
    function Get-VM { param($Name, $ErrorAction); return [pscustomobject]@{ State = 'Running' } }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, [switch]$AsJob, $TimeoutSeconds,
            $VmDomainAccount, [switch]$RequireDomainIdentity, $SessionMaxRetries, [switch]$RebootIfUnresponsive, [switch]$FailOnRemoteError)
        Assert-True ($VmName -eq 'PRI1' -and $RequireDomainIdentity -and -not $RebootIfUnresponsive -and $FailOnRemoteError) `
            'Existing hierarchy action targeted another server or enabled recovery.'
        Assert-True ($ArgumentList[0] -eq 'PRI' -and (@($ArgumentList[1]) -join ',') -eq 'CLIENT1') `
            'Host client submission expanded its requested client scope.'
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = [pscustomobject]@{
                Status = 'Submitted'; SiteCode = 'PRI'; Clients = @('CLIENT1')
            } }
    }
    Invoke-MemLabsExistingClientPush -DeployConfig $config
}
& {
    $maintenanceAst = Read-TestAst (Join-Path $root 'common\Common.Maintenance.ps1')
    . (Import-TestFunction $maintenanceAst 'Start-RequiredExistingVMMaintenance')
    function Get-VM { throw 'Expansion maintenance must stop before inventory or guest fixes.' }
    Assert-True (Start-RequiredExistingVMMaintenance -DeployConfig $config) 'Existing hierarchy maintenance was not explicitly skipped.'
}
& {
    . (Import-TestFunction $configAst 'Add-ExistingVMToDeployConfig')
    function Get-List { param($Type); return [pscustomobject]@{ vmName = 'OFF1'; state = 'Off' } }
    function Get-VMNote { param($VMName); return [pscustomobject]@{ vmName = 'OFF1'; role = 'Primary' } }
    function ConvertFrom-MemLabsVmNoteScalar { param($Value); return $Value }
    function Set-AddToExistingCmOptionsOnHiddenSiteRole { param($Config, $VM) }
    function Start-VM2 { throw 'Metadata discovery must not power on existing VMs.' }
    $authoring = [pscustomobject]@{ virtualMachines = @() }
    Add-ExistingVMToDeployConfig -vmName OFF1 -configToModify $authoring
    Assert-True ($authoring.virtualMachines.Count -eq 1 -and $authoring.virtualMachines[0].hidden) `
        'Existing metadata could not be collected without starting the VM.'
}
& {
    . (Import-TestFunction $phaseAst 'Get-Phase3ConfigurationData')
    . (Import-TestFunction $phaseAst 'Get-ConfigurationData')
    $script:StartedNames = @()
    function Get-CriticalVMs {
        param($domain, $vmNames, $InputVMs)
        Assert-True ((@($InputVMs.vmName) -join ',') -eq 'CLIENT1') 'Critical-VM preparation can still infer and start existing hierarchy dependencies.'
        return [pscustomobject]@{ Names = @($vmNames) }
    }
    function Invoke-SmartStartVMs {
        param($CritList)
        $script:StartedNames += $CritList.Names
        return 0
    }
    function Get-List {
        param($Type, $DomainName, [switch]$SmartUpdate)
        [pscustomobject]@{ vmName = 'INTENTIONALLY-OFF-BDC'; Role = 'BDC'; State = 'Off' }
        [pscustomobject]@{ vmName = 'CLIENT1'; Role = 'DomainMember'; State = 'Running' }
    }
    function Start-VM2 { throw 'Unrequested domain controllers must not be started.' }
    function Restart-UnresponsiveVm { throw 'Existing domain-controller recovery must not run.' }
    function Start-Sleep { param($Milliseconds) }
    function Write-Progress2 { param($Activity, $Status, $PercentComplete, [switch]$Log) }
    $savedCommon = $global:Common
    $global:Common = [pscustomobject]@{ VerboseEnabled = $false }
    try {
        $phaseData = Get-ConfigurationData -Phase 3 -deployConfig $config
        Assert-True (($phaseData.AllNodes.NodeName -join ',') -eq '*,CLIENT1' -and
            ($script:StartedNames -join ',') -eq 'CLIENT1') 'Actual Phase 3 preparation still starts or configures hierarchy context.'
    }
    finally { $global:Common = $savedCommon }
}
& {
    $blocksAst = Read-TestAst (Join-Path $root 'common\Common.ScriptBlocks.ps1')
    $isolation = $blocksAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$isolatedDsc'
        }, $true)
    if (-not $isolation) { throw 'Requested-node DSC isolation was not found.' }
    $siblings = @($isolation.Parent.Statements)
    $start = -1
    $finish = -1
    for ($i = 0; $i -lt $siblings.Count; $i++) {
        if ([object]::ReferenceEquals($siblings[$i], $isolation)) { $start = $i }
        if ($siblings[$i] -is [Management.Automation.Language.IfStatementAst] -and
            $siblings[$i].Clauses[0].Item1.Extent.Text.Contains('-not $isolatedDsc')) { $finish = $i; break }
    }
    if ($start -lt 0 -or $finish -lt $start) { throw 'Cannot isolate shipped local-compilation selection.' }
    $text = (@(for ($i = $start; $i -le $finish; $i++) { $siblings[$i].Extent.Text })) -join "`n"
    $factory = [scriptblock]::Create(
        'param($multiNodeDsc,$currentItem,$deployConfig,$ConfigurationData)' + "`n" + $text +
        "`n[pscustomobject]@{Skip=`$skipStartDsc;Nodes=@(`$ConfigurationData.AllNodes.NodeName)}")
    $result = & $factory $true $client $config (@{
            AllNodes = @(@{ NodeName = '*' }, @{ NodeName = 'CLIENT1'; Role = 'DomainMember' }, @{ NodeName = 'PRI1'; Role = 'Primary' })
        })
    Assert-True (-not $result.Skip -and ($result.Nodes -join ',') -eq 'CLIENT1,*') `
        'Requested client DSC still waits for, compiles for, or applies to an existing hierarchy coordinator.'
}
& {
    . (Import-TestFunction $phaseAst 'Mount-CmIsoForPhase')
    . (Import-TestFunction $phaseAst 'Invoke-Phase8PreInstallSnapshot')
    function Get-CmMediaSiteServers {
        param($deployConfig, [switch]$IncludeHidden)
        [pscustomobject]@{ Vm = $primary }
    }
    function Set-CmMediaMountAndShare { throw 'Context Primary media must not be mounted or reshared.' }
    function Test-Phase8AutoSnapshotExists { throw 'Context-only Phase 8 must not checkpoint the domain.' }
    function Get-Phase8ConfigurationData {
        param($deployConfig)
        return @{ AllNodes = @(@{ NodeName = '*' }, @{ NodeName = 'PRI1'; Role = 'Primary' }) }
    }
    Mount-CmIsoForPhase -deployConfig $config -Phase 8
    Assert-True (Invoke-Phase8PreInstallSnapshot -deployConfig $config) 'Context-only Phase 8 did not skip media/checkpoint preparation.'
}
& {
    . (Import-TestFunction $configAst 'Test-InProgress')
    function Get-VMFromList2 {
        param($deployConfig, $vmName)
        if ($vmName -ne 'CLIENT1') { throw 'Unrelated hierarchy inProgress notes must not gate a client addition.' }
        return [pscustomobject]@{ vmName = $vmName; inProgress = $false }
    }
    Assert-True (-not (Test-InProgress -DeployConfig $config)) 'An unrelated pending hierarchy blocked requested-client preparation.'
}
& {
    $dispatch = $phaseAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-PhaseJobs'
        }, $true)
    $loop = $dispatch.Body.Find({
            param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Condition.Extent.Text -eq '$vmDispatchList'
        }, $true)
    if (-not $loop) { throw 'Shipped VM dispatch loop was not found.' }
    $factory = [scriptblock]::Create(@'
param($Phase,$vmDispatchList,$scopedHierarchyActions,$hierarchyActionsOnly,$Common)
$jobs=[Collections.ArrayList]::new()
$job_created_yes=0
$job_created_no=0
$failedDispatchVMNames=[Collections.Generic.List[string]]::new()
$maxVmNameLength=0
$maxRoleNameLength=0
'@ + "`n" + $loop.Extent.Text + "`n[pscustomobject]@{Created=`$job_created_yes;Failed=`$job_created_no;FailedNames=`$failedDispatchVMNames.ToArray();Jobs=@(`$jobs)}")
    $global:VM_ExistingHierarchyActions = { 'SCOPED-ACTION-MARKER' }
    $script:DispatchFailure = $false
    function Start-Job {
        param($ScriptBlock, $Name, $ErrorAction)
        if ($script:DispatchFailure) { throw 'Fixture job creation failed.' }
        Assert-True ($ScriptBlock.ToString().Contains('SCOPED-ACTION-MARKER') -and $Name -like 'PRI1 *') `
            'Existing hierarchy work still uses ordinary VM_Config/DSC dispatch.'
        return [pscustomobject]@{ Id = 42; Name = $Name }
    }
    $actor = [pscustomobject]@{ Kind = 'ClientPush'; OwnerVMName = 'PRI1'; TargetVMNames = @('CLIENT1') }
    $dispatchResult = & $factory 8 @($primary, $client) @($actor) $true ([pscustomobject]@{ VerboseEnabled = $false })
    Assert-True ($dispatchResult.Created -eq 1 -and $dispatchResult.Failed -eq 0 -and $dispatchResult.Jobs.Count -eq 1) `
        'Actor-only Phase 8 failed to dispatch its exact owner without ordinary client/context workers.'
    $script:DispatchFailure = $true
    $dispatchResult = & $factory 8 @($primary) @($actor) $true ([pscustomobject]@{ VerboseEnabled = $false })
    Assert-True ($dispatchResult.Created -eq 0 -and $dispatchResult.Failed -eq 1 -and ($dispatchResult.FailedNames -join ',') -eq 'PRI1') `
        'Failed scoped actor job creation was reported as success.'
}
& {
    $classifier = $phaseAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$contextFailure'
        }, $true)
    $crashed = $phaseAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$workerCrashed'
        }, $true)
    if (-not $classifier -or -not $crashed) { throw 'Failed-job no-replay classification was not found.' }
    $classify = [scriptblock]::Create('param($DeployConfig,$fvmName,$jobOutput)' + "`n" +
        $classifier.Extent.Text + "`n" + $crashed.Extent.Text + "`nreturn [bool]`$workerCrashed")
    Assert-True (-not (& $classify $config 'PRI1' 'Unhandled exception from existing provider')) `
        'A scoped existing-owner failure still automatically replays hierarchy actions.'
    Assert-True (& $classify $config 'CLIENT1' 'background process reported an error') `
        'New-target worker crash recovery was disabled together with existing hierarchy repair.'
}
Assert-True (($config | ConvertTo-Json -Depth 10 -Compress) -eq $before) 'Read-only planning/actions changed the existing VM configuration.'
Write-Host "PASS -- $script:Assertions deployment-intent assertions on PowerShell $($PSVersionTable.PSVersion)."
