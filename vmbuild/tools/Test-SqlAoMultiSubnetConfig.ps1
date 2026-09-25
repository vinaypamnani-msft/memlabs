#requires -Version 5.1
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) {
    $RootPath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    if ("$Expected" -ne "$Actual") { throw "$Name -- expected '$Expected', got '$Actual'" }
    Write-Host "  PASS: $Name" -ForegroundColor Green
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Could not parse ${Path}: $($errors[0].Message)" }
    $functionAst = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Function '$Name' not found in $Path" }
    return [scriptblock]::Create($functionAst.Extent.Text)
}

function Write-Log {}
function Remove-VmNamePrefix { param($Name, $Prefix) return $Name }
function Get-List { return @() }

. (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\common\Common.Config.ps1') -Name 'Get-SQLAOConfig')
. (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\common\Common.Config.ps1') -Name 'Add-RemoteSQLVMToDeployConfig')
. (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\common\Common.Config.ps1') -Name 'Repair-SqlAoMissingPartners')
. (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\DSC\phases\InstallAndUpdateSCCM.ps1') -Name 'Get-CmOdbcPreflightCandidates')
. (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\DSC\phases\InstallPSForHierarchy.ps1') -Name 'Get-HierarchyOdbcConnectionString')
. (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\DSC\phases\InstallPSForHierarchy.ps1') -Name 'Get-HierarchyRecoveryAction')
$stopHierarchyInstallSource = (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\DSC\phases\InstallPSForHierarchy.ps1') -Name 'Stop-HierarchyInstall').ToString()
. (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\DSC\phases\ScriptFunctions.ps1') -Name 'Get-VmSqlConnectionTarget')

$deploy = [pscustomobject]@{
    vmOptions = [pscustomobject]@{
        network = '10.10.1.0'; domainName = 'sqlao.test'; domainNetBiosName = 'SQLAO'; prefix = ''
    }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'SQL1'; role = 'SQLAO'; OtherNode = 'SQL2'; FileServerVM = 'FS1'
            ClusterName = 'SQLCLUSTER'; SqlServiceAccount = 'SqlSvc'; SqlAgentAccount = 'SqlAgent'
            AlwaysOnGroupName = 'CM Availability Group'; AlwaysOnListenerName = 'CM-LISTENER'
            ClusterIPAddress = '10.10.1.201'; AGIPAddress = '10.10.1.202'
            ClusterIPAddresses = @('10.10.1.201', '10.10.2.201')
            AGIPAddresses = @('10.10.1.202', '10.10.2.202')
        },
        [pscustomobject]@{ vmName = 'SQL2'; role = 'SQLAO'; network = '10.10.2.0' },
        [pscustomobject]@{ vmName = 'FS1'; role = 'FileServer' }
    )
}

$result = Get-SQLAOConfig -deployConfig $deploy -vmName 'SQL1'
Assert-Equal '10.10.1.0,10.10.2.0' (@($result.DomainNetworks) -join ',') 'both SQLAO node subnets are emitted'
Assert-Equal '10.10.1.201/24,10.10.2.201/24' (@($result.ClusterIPAddresses) -join ',') 'cluster IP list includes both subnets'
Assert-Equal '10.10.1.202/255.255.255.0,10.10.2.202/255.255.255.0' (@($result.AGIPAddresses) -join ',') 'listener IP list includes both subnets'
Assert-Equal $true $result.MultiSubnetFailover 'different node subnets enable multi-subnet failover'
Assert-Equal $true $result.ListenerRegisterAllProvidersIP 'multi-subnet listener registers all provider IPs'
Assert-Equal 300 $result.ListenerHostRecordTTL 'multi-subnet listener uses the default lab TTL'

$healthySecondaryDeploy = $deploy | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$healthySecondary = $healthySecondaryDeploy.virtualMachines | Where-Object vmName -eq 'SQL2'
$healthySecondary | Add-Member -MemberType NoteProperty -Name SQLAOOwnerVM -Value 'SQL1' -Force
$healthySecondary | Add-Member -MemberType NoteProperty -Name ClusterName -Value 'SQLCLUSTER' -Force
$healthySecondary | Add-Member -MemberType NoteProperty -Name AlwaysOnListenerName -Value 'CM-LISTENER' -Force
Assert-Equal $null (Get-SQLAOConfig -deployConfig $healthySecondaryDeploy -vmName 'SQL2') 'healthy reciprocal secondary does not emit a second SQLAO owner config'

$degradedDeploy = $deploy | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$degradedOwner = $degradedDeploy.virtualMachines | Where-Object vmName -eq 'SQL1'
$degradedOwner.OtherNode = $null
$degradedDeploy.virtualMachines = @($degradedDeploy.virtualMachines | Where-Object vmName -ne 'SQL2')
$degradedResult = Get-SQLAOConfig -deployConfig $degradedDeploy -vmName 'SQL1'
Assert-Equal $true $degradedResult.Degraded 'surviving SQLAO owner emits a degraded connection object'
Assert-Equal 1500 $degradedResult.SQLAOPort 'degraded SQLAO connection preserves the listener port'
Assert-Equal '10.10.1.0,10.10.2.0' (@($degradedResult.DomainNetworks) -join ',') 'degraded SQLAO connection preserves both listener subnets'
$degradedOwner | Add-Member -MemberType NoteProperty -Name thisParams -Value ([pscustomobject]@{ SQLAO = $degradedResult }) -Force
$degradedTarget = Get-VmSqlConnectionTarget -SiteVm ([pscustomobject]@{ vmName = 'SITE'; remoteSQLVM = 'SQL1' }) `
    -DeployConfig $degradedDeploy -DomainFullName 'sqlao.test'
Assert-Equal 'CM-LISTENER.sqlao.test,1500' $degradedTarget 'degraded site connection continues through the listener port'

$survivingPartner = [pscustomobject]@{
    vmName = 'SQL2'; role = 'SQLAO'; SQLAOOwnerVM = 'MISSING-SQL1'
    AlwaysOnListenerName = 'CM-LISTENER'; ClusterName = 'SQLCLUSTER'
}
$replacementDeploy = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'sqlao.test' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'SITE'; role = 'Primary'; remoteSQLVM = 'MISSING-SQL1' },
        [pscustomobject]@{ vmName = 'SUP'; role = 'WSUS'; wsusDataBaseServer = 'MISSING-SQL1' },
        [pscustomobject]@{ vmName = 'MP'; role = 'SiteSystem'; replicaSqlServerVM = 'MISSING-SQL1' }
    )
}
$script:ExistingSqlInventory = @($survivingPartner)
function Get-List { return @($script:ExistingSqlInventory) }
function Add-ExistingVMToDeployConfig {
    param($vmName, $configToModify, [bool]$hidden)
    if (-not ($configToModify.virtualMachines | Where-Object vmName -eq $vmName)) {
        $candidate = $script:ExistingSqlInventory | Where-Object vmName -eq $vmName | Select-Object -First 1
        if ($candidate) { $configToModify.virtualMachines += $candidate }
    }
}
function Get-VMFromList2 {
    param($deployConfig, $vmName, [bool]$SmartUpdate, [bool]$Global)
    $candidate = $deployConfig.virtualMachines | Where-Object vmName -eq $vmName | Select-Object -First 1
    if (-not $candidate -and $Global) {
        $candidate = $script:ExistingSqlInventory | Where-Object vmName -eq $vmName | Select-Object -First 1
    }
    return $candidate
}
Add-RemoteSQLVMToDeployConfig -vmName 'MISSING-SQL1' -configToModify $replacementDeploy
Assert-Equal 'SQL2' $replacementDeploy.virtualMachines[0].remoteSQLVM 'missing SQLAO owner reference is redirected to the surviving partner'
Assert-Equal 'SQL2' $replacementDeploy.virtualMachines[1].wsusDataBaseServer 'missing SQLAO owner WSUS reference is redirected to the surviving partner'
Assert-Equal 'SQL2' $replacementDeploy.virtualMachines[2].replicaSqlServerVM 'missing SQLAO owner MP replica reference is redirected to the surviving partner'
Assert-Equal 1 @($replacementDeploy.virtualMachines | Where-Object vmName -eq 'SQL2').Count 'surviving SQLAO partner is added to the deploy config once'
$configSource = Get-Content (Join-Path $RootPath 'vmbuild\common\Common.Config.ps1') -Raw
Assert-Equal $true ($configSource -match 'Add-Member -MemberType NoteProperty -Name OtherNode -Value \$null -Force') 'degraded healing durably tombstones the missing partner'
$script:ExistingSqlInventory = @(
    [pscustomobject]@{ vmName = 'SQL2A'; role = 'SQLAO'; SQLAOOwnerVM = 'MISSING-SQL1' },
    [pscustomobject]@{ vmName = 'SQL2B'; role = 'SQLAO'; SQLAOOwnerVM = 'MISSING-SQL1' }
)
$ambiguousDeploy = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'sqlao.test' }
    virtualMachines = @([pscustomobject]@{ vmName = 'SITE2'; role = 'Primary'; remoteSQLVM = 'MISSING-SQL1' })
}
Add-RemoteSQLVMToDeployConfig -vmName 'MISSING-SQL1' -configToModify $ambiguousDeploy
Assert-Equal 'MISSING-SQL1' $ambiguousDeploy.virtualMachines[0].remoteSQLVM 'ambiguous surviving partners do not rewrite SQL references'
function Get-List { return @() }

$healingOwner = [pscustomobject]@{
    vmName = 'SQL1'; role = 'SQLAO'; hidden = $true; OtherNode = 'SQL2'; AlwaysOnListenerName = 'CM-LISTENER'
}
$healingConfig = [pscustomobject]@{ virtualMachines = @($healingOwner) }
$script:StoredSqlAoNote = [pscustomobject]@{ vmName = 'SQL1'; OtherNode = 'SQL2' }
$script:FailSqlAoNoteWrite = $false
function Get-VMNote {
    return ($script:StoredSqlAoNote | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
}
function Set-VMNote {
    param($VMName, $vmNote, [switch]$Force)
    if (-not $script:FailSqlAoNoteWrite) {
        $script:StoredSqlAoNote = $vmNote | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    }
}
Repair-SqlAoMissingPartners -Config $healingConfig -RefreshedVmInventory @() -InventoryRefreshVerified $false
Assert-Equal 'SQL2' $healingOwner.OtherNode 'unverified empty inventory does not degrade a healthy SQLAO pair'

$script:FailSqlAoNoteWrite = $true
Repair-SqlAoMissingPartners -Config $healingConfig -RefreshedVmInventory @() -InventoryRefreshVerified $true
Assert-Equal 'SQL2' $healingOwner.OtherNode 'failed note persistence preserves the in-memory SQLAO pair'

$script:FailSqlAoNoteWrite = $false
Repair-SqlAoMissingPartners -Config $healingConfig -RefreshedVmInventory @() -InventoryRefreshVerified $true
Assert-Equal $null $healingOwner.OtherNode 'verified missing partner degrades the in-memory SQLAO pair'
Assert-Equal $null $script:StoredSqlAoNote.OtherNode 'verified missing partner persists a null tombstone'
Repair-SqlAoMissingPartners -Config $healingConfig -RefreshedVmInventory @() -InventoryRefreshVerified $true
Assert-Equal $null $script:StoredSqlAoNote.OtherNode 'second healing pass does not restore the stale partner'

foreach ($invalidTtl in 0, 29, 86401) {
    $ttlDeploy = $deploy | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    ($ttlDeploy.virtualMachines | Where-Object vmName -eq 'SQL1') |
        Add-Member -MemberType NoteProperty -Name listenerHostRecordTTL -Value $invalidTtl -Force
    $ttlRejected = $false
    try { $null = Get-SQLAOConfig -deployConfig $ttlDeploy -vmName 'SQL1' }
    catch { $ttlRejected = $_.Exception.Message -like '*listenerHostRecordTTL must be between*' }
    Assert-Equal $true $ttlRejected "listener TTL $invalidTtl is rejected"
}
foreach ($validTtl in 30, 86400) {
    $ttlDeploy = $deploy | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    ($ttlDeploy.virtualMachines | Where-Object vmName -eq 'SQL1') |
        Add-Member -MemberType NoteProperty -Name listenerHostRecordTTL -Value $validTtl -Force
    $ttlResult = Get-SQLAOConfig -deployConfig $ttlDeploy -vmName 'SQL1'
    Assert-Equal $validTtl $ttlResult.ListenerHostRecordTTL "listener TTL $validTtl is preserved"
}

$phase5 = Get-Content (Join-Path $RootPath 'vmbuild\DSC\phases\Phase5.ps1') -Raw
Assert-Equal $true ($phase5 -match 'SqlAoMultiSubnetNetworkName MultiSubnetClusterName') 'Phase 5 converges the core cluster Network Name'
Assert-Equal $true ($phase5 -match 'SqlAoMultiSubnetNetworkName MultiSubnetListener') 'Phase 5 converges the listener Network Name'
Assert-Equal $true ($phase5 -match 'IpAddress\s+=\s+\$thisVM\.thisParams\.SQLAO\.AGIPAddresses') 'SqlAGListener declares the complete multi-subnet listener IP set'
Assert-Equal $true ($phase5 -match 'Add-DnsServerResourceRecordA[\s\S]+-TimeToLive \$listenerTtl') 'listener DNS repair applies the configured TTL'
Assert-Equal $true ($phase5 -match 'if \(-not \$using:listenerRegisterAllProviders\)') 'listener DNS repair honors RegisterAllProvidersIP=0'
Assert-Equal $true ($phase5 -match 'foreach \(\$repairDC in \$allDCs\)') 'listener DNS repair reconciles every DC on every attempt'
Assert-Equal $true ($phase5 -match 'if \(\$primaryAddressMissing -and \$attempt -le 2\)') 'listener DNS bounce is limited to primary-DC address loss'
Assert-Equal $true ($phase5.IndexOf('ClusterNetwork "ChangeDomainNetwork$domainNetworkIndex"') -lt $phase5.IndexOf('SqlAoMultiSubnetNetworkName MultiSubnetClusterName')) 'domain network convergence precedes core Network Name convergence'
Assert-Equal $false ($phase5 -match 'Address\s+=\s+\$Node1VM\.thisParams\.vmNetwork') 'secondary Phase 5 does not configure the primary node subnet'
Assert-Equal $false ($phase5 -match "ClusterNetwork 'ChangeNetwork-192'") 'secondary Phase 5 does not compete with primary-owned cluster network naming'
Assert-Equal $true ($phase5 -match "Script PrimaryAgReady") 'secondary replica add waits for SQL-level primary readiness'
Assert-Equal $true ($phase5 -match "rs\.role_desc = 'PRIMARY'") 'primary readiness gate verifies the local AG role'
Assert-Equal $true ($phase5 -match '\$_localAgTarget') 'primary readiness gate checks existing local replica membership first'
Assert-Equal $true ($phase5 -match 'local replica is absent and configured primary is not PRIMARY') 'primary readiness gate distinguishes initial add from converged failover state'
Assert-Equal $false ($phase5 -match "SqlWaitForAG 'SQLConfigureAG-WaitAG'") 'local membership gate has no mandatory configured-primary SqlWaitForAG predecessor'
Assert-Equal $false ($phase5 -match 'WaitForAll AG \{') 'local membership gate has no remote listener WaitForAll predecessor'
Assert-Equal $true ($phase5 -match '\[DateTime\]::UtcNow\.AddMinutes\(10\)') 'primary readiness gate uses an absolute ten-minute deadline'
Assert-Equal $true ($phase5 -match 'while \(\[DateTime\]::UtcNow -lt \$deadline\)') 'primary readiness retries stop at the deadline'

$install = Get-Content (Join-Path $RootPath 'vmbuild\DSC\phases\InstallAndUpdateSCCM.ps1') -Raw
Assert-Equal $true ($install -match 'MultiSubnetFailover=True') 'listener-targeted probes enable SQL client multi-subnet failover'
Assert-Equal $true ($install -match "'MSF Enabled'") 'ConfigMgr MSF registry state is configured after listener validation'
Assert-Equal 2 ([regex]::Matches($install, 'GetValueKind').Count) 'ConfigMgr MSF registry validation enforces DWORD value kinds'
Assert-Equal 2 ([regex]::Matches($install, 'Get-CmOdbcPreflightCandidates -Target \$sqlTarget').Count) 'initial and retry ODBC preflights both use the shared candidate builder'
$multiSubnetCandidates = @(Get-CmOdbcPreflightCandidates -Target 'listener.test,1500' -MultiSubnet $true)
Assert-Equal 1 $multiSubnetCandidates.Count 'multi-subnet ODBC preflight exposes only one supported driver'
Assert-Equal 'ODBC Driver 18' $multiSubnetCandidates[0].Driver 'multi-subnet ODBC preflight skips the legacy driver'
Assert-Equal $true ($multiSubnetCandidates[0].ConnectionString -like '*MultiSubnetFailover=Yes*') 'multi-subnet ODBC candidate enables parallel listener probing'
Assert-Equal $true ($multiSubnetCandidates[0].ConnectionString -like '*Encrypt=no;TrustServerCertificate=yes*') 'multi-subnet ODBC candidate works with the default lab SQL certificate'
$singleSubnetCandidates = @(Get-CmOdbcPreflightCandidates -Target 'listener.test,1500' -MultiSubnet $false)
Assert-Equal 2 $singleSubnetCandidates.Count 'single-subnet ODBC preflight preserves legacy fallback'
Assert-Equal $false (($singleSubnetCandidates.ConnectionString -join ';') -like '*MultiSubnetFailover=*') 'single-subnet ODBC candidates do not change connection behavior'

$hierarchyMultiSubnet = Get-HierarchyOdbcConnectionString -Target 'listener.test,1500' -MultiSubnet $true
Assert-Equal $true ($hierarchyMultiSubnet -like '*MultiSubnetFailover=Yes*') 'hierarchy child Primary enables multi-subnet ODBC probing'
Assert-Equal $true ($hierarchyMultiSubnet -like '*Encrypt=no;TrustServerCertificate=yes*') 'hierarchy ODBC probing supports the default lab SQL certificate'
$hierarchySource = Get-Content (Join-Path $RootPath 'vmbuild\DSC\phases\InstallPSForHierarchy.ps1') -Raw
Assert-Equal $true ($hierarchySource -match 'Start-Process[\s\S]+-PassThru') 'hierarchy setup captures the setup process exit code'
Assert-Equal $true ($hierarchySource -match 'InstallSCCM\.Status -eq ''Running''') 'hierarchy setup detects stale Running state'
Assert-Equal $true ($hierarchySource -match 'Running at preflight stage; resetting') 'hierarchy setup safely retries failures that occur before setup starts'
Assert-Equal $true ($hierarchySource -match 'InstallPSForHierarchy\.setup\.stage') 'hierarchy setup persists resumable stage metadata'
Assert-Equal $true ($hierarchySource -match "'LaunchConfirmed'") 'hierarchy setup distinguishes confirmed launch from preflight'
Assert-Equal $true ($hierarchySource -match "'SetupCompleted'") 'hierarchy setup resumes failed postflight without reinstalling'
Assert-Equal $true ($hierarchySource -match 'AddHours\(2\)') 'hierarchy Primary readiness wait has a hard deadline'
Assert-Equal $true ($hierarchySource -match "'MSF Enabled'") 'hierarchy setup converges ConfigMgr MSF registry state'
Assert-Equal 'RetrySetup' (Get-HierarchyRecoveryAction -Stage 'Preflight' -SiteReady $false -ModulePresent $false) 'hierarchy preflight failure is safely retryable'
Assert-Equal 'RequireCheckpoint' (Get-HierarchyRecoveryAction -Stage 'LaunchConfirmed' -SiteReady $false -ModulePresent $false) 'hierarchy partial setup requires checkpoint recovery'
Assert-Equal 'RequireCheckpoint' (Get-HierarchyRecoveryAction -Stage 'LaunchConfirmed' -SiteReady $true -ModulePresent $false) 'hierarchy launch without module evidence requires checkpoint recovery'
Assert-Equal 'ResumePostflight' (Get-HierarchyRecoveryAction -Stage 'LaunchConfirmed' -SiteReady $true -ModulePresent $true) 'hierarchy completed launch resumes postflight'
Assert-Equal 'ResumePostflight' (Get-HierarchyRecoveryAction -Stage 'SetupCompleted' -SiteReady $true -ModulePresent $false) 'hierarchy postflight failure resumes without reinstalling'
Assert-Equal $false ($stopHierarchyInstallSource -match 'InstallSCCM\.Status') 'hierarchy prerequisite failures do not overwrite completed install state'

$resourceModule = Get-Content (Join-Path $RootPath 'vmbuild\DSC\TemplateHelpDSC\TemplateHelpDSC.psm1') -Raw
Assert-Equal $true ($resourceModule -match 'Get-ClusterResourceDependency') 'Network Name desired-state test validates dependencies'
Assert-Equal $true ($resourceModule -match 'DependencyExpression') 'Network Name desired-state test reads the authoritative dependency expression'
Assert-Equal $false ($resourceModule -match '\$dependencyInfo \| Out-String') 'Network Name dependency validation does not rely on formatted output'
Assert-Equal $true ($resourceModule -match "parameters\.EnableDhcp -ne 0") 'Network Name desired-state test validates static IP resources'
Assert-Equal $true ($resourceModule -match "networkName\.State -ne 'Online'") 'Network Name desired-state test requires an online resource'

$templateManifest = Join-Path $RootPath 'vmbuild\DSC\TemplateHelpDSC\TemplateHelpDSC.psd1'
Import-Module $templateManifest -Force -ErrorAction Stop
$templateModule = Get-Module TemplateHelpDSC
$mockResults = & $templateModule {
    function Import-Module { param($Name) }
    $group = [pscustomobject]@{ Name = 'AG' }
    $script:mockGroup = $group
    $script:networkName = [pscustomobject]@{
        Name = 'Listener'; ResourceType = 'Network Name'; OwnerGroup = $group; State = 'Online'
        Parameters = @{ DnsName = 'LISTENER'; RegisterAllProvidersIP = 1; HostRecordTTL = 300 }
    }
    $script:ip1 = [pscustomobject]@{
        Name = 'IP1'; ResourceType = 'IP Address'; OwnerGroup = $group; State = 'Online'
        Parameters = @{ Address = '10.1.1.202'; SubnetMask = '255.255.255.0'; Network = 'Net1'; EnableDhcp = 0 }
    }
    $script:ip2 = [pscustomobject]@{
        Name = 'IP2'; ResourceType = 'IP Address'; OwnerGroup = $group; State = 'Offline'
        Parameters = @{ Address = '10.1.2.202'; SubnetMask = '255.255.255.0'; Network = 'Net2'; EnableDhcp = 0 }
    }
    $script:dependencyExpression = '[IP1] or [IP2]'

    function Get-ClusterResource {
        param($Cluster, $Name)
        $resources = @($script:networkName, $script:ip1, $script:ip2)
        if ($Name) { return @($resources | Where-Object Name -eq $Name) }
        return $resources
    }
    function Get-ClusterParameter {
        param([Parameter(ValueFromPipeline)]$InputObject, $Name)
        process {
            if ($Name) { return [pscustomobject]@{ Name = $Name; Value = $InputObject.Parameters[$Name] } }
            foreach ($key in $InputObject.Parameters.Keys) {
                [pscustomobject]@{ Name = $key; Value = $InputObject.Parameters[$key] }
            }
        }
    }
    function Get-ClusterNetwork {
        [CmdletBinding()]
        param($Cluster)
        return @(
            [pscustomobject]@{ Name = 'Net1'; Address = '10.1.1.0' },
            [pscustomobject]@{ Name = 'Net2'; Address = '10.1.2.0' }
        )
    }
    function Get-ClusterResourceDependency {
        param([Parameter(ValueFromPipeline)]$InputObject)
        process { return [pscustomobject]@{ DependencyExpression = $script:dependencyExpression } }
    }

    $resource = [SqlAoMultiSubnetNetworkName]::new()
    $resource.Name = 'LISTENER'
    $resource.ClusterName = 'CLUSTER'
    $resource.Kind = 'Listener'
    $resource.IPAddresses = @('10.1.1.202/24', '10.1.2.202/24')
    $resource.RegisterAllProvidersIP = 1
    $resource.HostRecordTTL = 300

    $valid = $resource.Test()
    $script:dependencyExpression = '[IP1] or [IP2] or [STALE]'
    $extraProvider = $resource.Test()
    $script:dependencyExpression = '([IP1] or [IP2]) and [OTHER]'
    $mixedAnd = $resource.Test()
    $script:dependencyExpression = '[IP1] or [IP2]'
    $script:ip2.Parameters.Network = 'WrongNetwork'
    $wrongNetwork = $resource.Test()
    $script:ip2.Parameters.Network = 'Net2'
    $script:networkName.State = 'Offline'
    $offlineName = $resource.Test()

    return [pscustomobject]@{
        Valid = $valid
        ExtraProvider = $extraProvider
        MixedAnd = $mixedAnd
        WrongNetwork = $wrongNetwork
        OfflineName = $offlineName
    }
}
Assert-Equal $true $mockResults.Valid 'Network Name Test accepts the exact healthy OR dependency'
Assert-Equal $false $mockResults.ExtraProvider 'Network Name Test rejects an extra dependency provider'
Assert-Equal $false $mockResults.MixedAnd 'Network Name Test rejects mixed AND/OR dependencies'
Assert-Equal $false $mockResults.WrongNetwork 'Network Name Test rejects an IP bound to the wrong cluster network'
Assert-Equal $false $mockResults.OfflineName 'Network Name Test rejects an offline Network Name'

$setResults = & $templateModule {
    function Import-Module { param($Name) }
    $group = [pscustomobject]@{ Name = 'AG' }
    $script:mockGroup = $group
    $script:networkName = [pscustomobject]@{
        Name = 'Listener'; ResourceType = 'Network Name'; OwnerGroup = $group; State = 'Online'
        Parameters = @{ DnsName = 'LISTENER'; RegisterAllProvidersIP = 1; HostRecordTTL = 300 }
    }
    $script:ip1 = [pscustomobject]@{
        Name = 'IP1'; ResourceType = 'IP Address'; OwnerGroup = $group; State = 'Online'
        Parameters = @{ Address = '10.1.1.202'; SubnetMask = '255.255.255.0'; Network = 'Net1'; EnableDhcp = 0 }
    }
    $script:orphan = [pscustomobject]@{
        Name = 'LISTENER IP Address (10.1.2.202)'; ResourceType = 'IP Address'; OwnerGroup = $group; State = 'Offline'
        Parameters = @{}
    }
    $script:resources = [Collections.Generic.List[object]]::new()
    $script:resources.Add($script:networkName)
    $script:resources.Add($script:ip1)
    $script:resources.Add($script:orphan)
    $script:dependencyExpression = '[IP1] or [LISTENER IP Address (10.1.2.202)]'
    $script:addCount = 0
    $script:removeCount = 0
    $script:failNewResourceSet = $false
    $script:failCleanup = $false

    function Get-ClusterResource {
        param($Cluster, $Name)
        if ($Name) { return @($script:resources | Where-Object Name -eq $Name) }
        return @($script:resources)
    }
    function Get-ClusterParameter {
        param([Parameter(ValueFromPipeline)]$InputObject, $Name)
        process {
            if ($Name) { return [pscustomobject]@{ Name = $Name; Value = $InputObject.Parameters[$Name] } }
            foreach ($key in $InputObject.Parameters.Keys) {
                [pscustomobject]@{ Name = $key; Value = $InputObject.Parameters[$key] }
            }
        }
    }
    function Set-ClusterParameter {
        param([Parameter(ValueFromPipeline)]$InputObject, $Multiple)
        process {
            if ($script:failNewResourceSet -and $InputObject.Name -eq 'LISTENER IP Address (10.1.2.202)') {
                throw 'injected parameter failure'
            }
            foreach ($key in $Multiple.Keys) { $InputObject.Parameters[$key] = $Multiple[$key] }
            return $InputObject
        }
    }
    function Get-ClusterNetwork {
        return @(
            [pscustomobject]@{ Name = 'Net1'; Address = '10.1.1.0' },
            [pscustomobject]@{ Name = 'Net2'; Address = '10.1.2.0' }
        )
    }
    function Get-ClusterResourceDependency {
        param([Parameter(ValueFromPipeline)]$InputObject)
        process { return [pscustomobject]@{ DependencyExpression = $script:dependencyExpression } }
    }
    function Set-ClusterResourceDependency {
        [CmdletBinding()]
        param($Resource, $Dependency)
        $script:dependencyExpression = $Dependency
    }
    function Add-ClusterResource {
        [CmdletBinding()]
        param($Cluster, $Name, $Group, $ResourceType)
        $script:addCount++
        $newResource = [pscustomobject]@{
            Name = $Name; ResourceType = $ResourceType; OwnerGroup = $script:mockGroup; State = 'Offline'; Parameters = @{}
        }
        $script:resources.Add($newResource)
        return $newResource
    }
    function Remove-ClusterResource {
        [CmdletBinding()]
        param($Cluster, $Name, [switch]$Force)
        $script:removeCount++
        if ($script:failCleanup) {
            Write-Error 'injected cleanup failure'
            return
        }
        $target = $script:resources | Where-Object Name -eq $Name | Select-Object -First 1
        if ($target) { $script:resources.Remove($target) }
    }
    function Stop-ClusterResource {
        param([Parameter(ValueFromPipeline)]$InputObject, $Wait)
        process { $InputObject.State = 'Offline'; return $InputObject }
    }
    function Start-ClusterResource {
        param([Parameter(ValueFromPipeline)]$InputObject, $Wait)
        process {
            $InputObject.State = 'Online'
            $onlineIp = $script:resources | Where-Object { $_.ResourceType -eq 'IP Address' } | Select-Object -First 1
            if ($onlineIp) { $onlineIp.State = 'Online' }
            return $InputObject
        }
    }
    function Update-ClusterNetworkNameResource {
        param([Parameter(ValueFromPipeline)]$InputObject)
        process { return $InputObject }
    }

    $resource = [SqlAoMultiSubnetNetworkName]::new()
    $resource.Name = 'LISTENER'
    $resource.ClusterName = 'CLUSTER'
    $resource.Kind = 'Listener'
    $resource.IPAddresses = @('10.1.1.202/24', '10.1.2.202/24')
    $resource.RegisterAllProvidersIP = 1
    $resource.HostRecordTTL = 300

    try { $resource.Set() } catch { throw "orphan reuse scenario failed: $($_.Exception.Message)" }
    $orphanReused = $script:addCount -eq 0 -and
        $script:orphan.Parameters.Address -eq '10.1.2.202' -and
        $resource.Test()

    $crossNamed = [pscustomobject]@{
        Name = 'LISTENER IP Address (10.1.2.202)'; ResourceType = 'IP Address'; OwnerGroup = $group; State = 'Offline'
        Parameters = @{ Address = '10.1.1.202'; SubnetMask = '255.255.255.0'; Network = 'Net1'; EnableDhcp = 0 }
    }
    $script:resources.Clear()
    $script:resources.Add($script:networkName)
    $script:resources.Add($crossNamed)
    $script:networkName.State = 'Online'
    $script:dependencyExpression = '[LISTENER IP Address (10.1.2.202)]'
    $script:addCount = 0
    $script:removeCount = 0
    try { $resource.Set() } catch { throw "cross-named scenario failed: $($_.Exception.Message)" }
    $crossNamedIps = @($script:resources | Where-Object ResourceType -eq 'IP Address')
    $crossNamedAddresses = @($crossNamedIps | ForEach-Object { ($_ | Get-ClusterParameter -Name Address).Value } | Sort-Object -Unique)
    $crossNamedConverged = $crossNamedIps.Count -eq 2 -and
        @($crossNamedIps.Name | Sort-Object -Unique).Count -eq 2 -and
        $crossNamedAddresses.Count -eq 2 -and
        $script:dependencyExpression -notmatch '\[\]'
    $crossNamedAddCount = $script:addCount

    $script:resources.Clear()
    $script:resources.Add($script:networkName)
    $script:resources.Add($script:ip1)
    $script:networkName.State = 'Online'
    $script:resources.Remove($script:orphan)
    $script:dependencyExpression = '[IP1]'
    $script:addCount = 0
    $script:removeCount = 0
    $script:failNewResourceSet = $true
    $failedSetThrew = $false
    try { $resource.Set() } catch { $failedSetThrew = $_.Exception.Message -like '*injected parameter failure*' }
    $failedResourceRemoved = -not ($script:resources | Where-Object Name -eq 'LISTENER IP Address (10.1.2.202)')

    $script:resources.Clear()
    $script:resources.Add($script:networkName)
    $script:resources.Add($script:ip1)
    $script:networkName.State = 'Online'
    $script:dependencyExpression = '[IP1]'
    $script:addCount = 0
    $script:removeCount = 0
    $script:failCleanup = $true
    $cleanupFailureSurfaced = $false
    try { $resource.Set() }
    catch {
        $cleanupFailureSurfaced = $_.Exception.Message -like "*Cleanup also failed*injected cleanup failure*"
    }

    return [pscustomobject]@{
        OrphanReused = $orphanReused
        CrossNamedConverged = $crossNamedConverged
        CrossNamedAddCount = $crossNamedAddCount
        FailedSetThrew = $failedSetThrew
        FailedResourceRemoved = $failedResourceRemoved
        CleanupFailureSurfaced = $cleanupFailureSurfaced
    }
}
Assert-Equal $true $setResults.OrphanReused 'Network Name Set reuses and repairs a deterministic orphan resource'
Assert-Equal $true $setResults.CrossNamedConverged 'Network Name Set assigns a cross-named stale resource to only one desired address'
Assert-Equal 1 $setResults.CrossNamedAddCount 'Network Name Set creates the second resource required by a cross-named stale address'
Assert-Equal $true $setResults.FailedSetThrew 'Network Name Set surfaces initialization failure'
Assert-Equal $true $setResults.FailedResourceRemoved 'Network Name Set removes a newly created resource after initialization failure'
Assert-Equal $true $setResults.CleanupFailureSurfaced 'Network Name Set reports initialization and cleanup failures together'

Write-Host 'SQLAO multi-subnet configuration tests passed.' -ForegroundColor Green
