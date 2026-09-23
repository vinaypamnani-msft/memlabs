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
. (Import-TestFunction -Path (Join-Path $RootPath 'vmbuild\DSC\phases\InstallAndUpdateSCCM.ps1') -Name 'Get-CmOdbcPreflightCandidates')

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
Assert-Equal $true ($phase5 -match 'Add-DnsServerResourceRecordA[\s\S]+-TimeToLive \$listenerTtl') 'listener DNS repair applies the configured TTL'
Assert-Equal $true ($phase5 -match 'if \(-not \$using:listenerRegisterAllProviders\)') 'listener DNS repair honors RegisterAllProvidersIP=0'
Assert-Equal $true ($phase5 -match 'foreach \(\$repairDC in \$allDCs\)') 'listener DNS repair reconciles every DC on every attempt'
Assert-Equal $true ($phase5 -match 'if \(\$primaryAddressMissing -and \$attempt -le 2\)') 'listener DNS bounce is limited to primary-DC address loss'
Assert-Equal $true ($phase5.IndexOf('ClusterNetwork "ChangeDomainNetwork$domainNetworkIndex"') -lt $phase5.IndexOf('SqlAoMultiSubnetNetworkName MultiSubnetClusterName')) 'domain network convergence precedes core Network Name convergence'

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

Write-Host 'SQLAO multi-subnet configuration tests passed.' -ForegroundColor Green
