#requires -Version 5.1
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$failures = [Collections.Generic.List[string]]::new()
function Assert-Validation {
    param([bool] $Condition, [string] $Name)
    if ($Condition) {
        Write-Host "PASS  $Name"
    }
    else {
        Write-Host "FAIL  $Name"
        $failures.Add($Name)
    }
}

function Test-SplitNetworkRejection {
    param([Parameter(Mandatory = $true)]$ValidationResult)
    $messageText = @($ValidationResult.Message | ForEach-Object { [string]$_ }) -join ' | '
    return $messageText -match 'different networks|Both replicas must share one network'
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

function Import-AssignedScriptBlock {
    param([string] $Path, [string] $VariableName)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Could not parse ${Path}: $($errors[0].Message)" }
    $assignments = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq $VariableName -and
                $node.Right.Extent.Text.TrimStart().StartsWith('{')
            }, $true))
    if ($assignments.Count -ne 1) {
        throw "Expected one '$VariableName' scriptblock assignment in $Path, found $($assignments.Count)"
    }
    return [scriptblock]::Create($assignments[0].Right.Extent.Text).InvokeReturnAsIs()
}

Push-Location $RootPath
try {
    . .\Common.ps1 -SkipMaintenanceRefresh -SkipEnvironmentDetection -SkipHostPreparation
    $userConfig = Get-UserConfiguration -Configuration 'Locale-CM-SqlAo-HighMemory.json'
    $result = Test-Configuration -InputObject $userConfig.Config

    Assert-Validation (-not (Test-SplitNetworkRejection -ValidationResult $result)) 'authoritative validation accepts split-network SQLAO'
    $negativeControl = [pscustomobject]@{
        Failures = 1
        Message = @('SQL Validation: SQLAO nodes [SQL1] and [SQL2] are on different networks. Both replicas must share one network.')
    }
    Assert-Validation (Test-SplitNetworkRejection -ValidationResult $negativeControl) 'validation test detects the former split-network rejection'

    $sql1 = $result.DeployConfig.virtualMachines | Where-Object vmName -eq 'LH1-SQL1' | Select-Object -First 1
    $sql2 = $result.DeployConfig.virtualMachines | Where-Object vmName -eq 'LH1-SQL2' | Select-Object -First 1
    Assert-Validation ($null -ne $sql1) 'authoritative conversion emits LH1-SQL1'
    Assert-Validation ($null -ne $sql2) 'authoritative conversion emits LH1-SQL2'
    Assert-Validation ($sql1.thisParams.vmNetwork -eq '10.221.211.0') 'primary SQLAO node retains the default subnet'
    Assert-Validation ($sql2.thisParams.vmNetwork -eq '10.221.212.0') 'secondary SQLAO node retains its explicit subnet'
    Assert-Validation ($sql1.thisParams.vmNetwork -ne $sql2.thisParams.vmNetwork) 'authoritative conversion preserves distinct SQLAO networks'

    . (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.Validation.Functional.ps1') -Name 'Get-SqlAoIpResourceHealth')
    . (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.Validation.Functional.ps1') -Name 'Get-SqlAoVirtualIpAddresses')
    . (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.Validation.Functional.ps1') -Name 'Resolve-SqlAoNodeAddress')
    . (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.Validation.Functional.ps1') -Name 'Get-SqlAoConfigValue')
    function Get-ClusterParameter {
        param([Parameter(ValueFromPipeline)]$InputObject, [string]$Name)
        process { [pscustomobject]@{ Value = $InputObject.Parameters[$Name] } }
    }
    $coreGroup = 'Cluster Group'
    $listenerGroup = 'AG'
    $ipResources = @(
        [pscustomobject]@{ Name = 'Core-A'; State = 'Online'; OwnerGroup = $coreGroup; Parameters = @{ Address = '10.0.1.201'; Network = 'Net1' } },
        [pscustomobject]@{ Name = 'Core-B'; State = 'Offline'; OwnerGroup = $coreGroup; Parameters = @{ Address = '10.0.2.201'; Network = 'Net2' } },
        [pscustomobject]@{ Name = 'Listener-A'; State = 'Online'; OwnerGroup = $listenerGroup; Parameters = @{ Address = '10.0.1.202'; Network = 'Net1' } },
        [pscustomobject]@{ Name = 'Listener-B'; State = 'Offline'; OwnerGroup = $listenerGroup; Parameters = @{ Address = '10.0.2.202'; Network = 'Net2' } }
    )
    $expectedClusterIps = @('10.0.1.201', '10.0.2.201')
    $expectedListenerIps = @('10.0.1.202', '10.0.2.202')
    $healthyIpState = Get-SqlAoIpResourceHealth -Resources $ipResources -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation $healthyIpState.Passed 'multi-subnet validation accepts one online and one offline provider per OR group'
    Assert-Validation ($healthyIpState.ExpectedStandbyNames.Count -eq 2) 'healthy multi-subnet validation identifies only inactive-subnet standbys'
    $bothOnlineResources = @($ipResources | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                State = if ($_.Name -eq 'Core-B') { 'Online' } else { $_.State }
                OwnerGroup = $_.OwnerGroup
                Parameters = $_.Parameters
            }
        })
    $bothOnlineState = Get-SqlAoIpResourceHealth -Resources $bothOnlineResources -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $bothOnlineState.Passed) 'multi-subnet validation rejects two online providers in one OR group'
    $duplicateExpectedState = Get-SqlAoIpResourceHealth -Resources $ipResources -ExpectedClusterIPs @('10.0.1.201', '10.0.1.201', '10.0.2.201') -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $duplicateExpectedState.Passed) 'multi-subnet validation rejects duplicate desired addresses'

    $ipResources[0].State = 'Offline'
    $zeroOnlineState = Get-SqlAoIpResourceHealth -Resources $ipResources -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $zeroOnlineState.Passed) 'multi-subnet validation rejects a resource group with no online provider'
    Assert-Validation (
        $zeroOnlineState.ExpectedStandbyNames -notcontains 'Core-A' -and
        $zeroOnlineState.ExpectedStandbyNames -notcontains 'Core-B'
    ) 'zero-online group exposes no standby exclusions for its broken providers'
    $ipResources[0].State = 'Failed'
    $failedProviderState = Get-SqlAoIpResourceHealth -Resources $ipResources -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $failedProviderState.Passed) 'multi-subnet validation rejects a failed provider'
    $ipResources[0].State = 'Online'
    $ipResources += [pscustomobject]@{ Name = 'Unexpected'; State = 'Online'; OwnerGroup = $coreGroup; Parameters = @{ Address = '10.0.1.250'; Network = 'Net1' } }
    $unexpectedProviderState = Get-SqlAoIpResourceHealth -Resources $ipResources -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $unexpectedProviderState.Passed) 'multi-subnet validation rejects an unexpected IP resource'
    $baseResources = @($ipResources | Where-Object Name -ne 'Unexpected')
    $missingProviderState = Get-SqlAoIpResourceHealth -Resources @($baseResources | Where-Object Name -ne 'Core-B') -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $missingProviderState.Passed) 'multi-subnet validation rejects a missing inactive provider'
    $zeroResourceState = Get-SqlAoIpResourceHealth -Resources @() -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $zeroResourceState.Passed) 'multi-subnet validation rejects zero measured IP resources'
    $duplicateResources = @($baseResources + [pscustomobject]@{ Name = 'Core-A-Duplicate'; State = 'Offline'; OwnerGroup = $coreGroup; Parameters = @{ Address = '10.0.1.201'; Network = 'Net1' } })
    $duplicateProviderState = Get-SqlAoIpResourceHealth -Resources $duplicateResources -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $duplicateProviderState.Passed) 'multi-subnet validation rejects duplicate expected addresses'
    $collapsedResources = @($baseResources | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; State = $_.State; OwnerGroup = $coreGroup; Parameters = $_.Parameters }
        })
    $collapsedGroupState = Get-SqlAoIpResourceHealth -Resources $collapsedResources -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $collapsedGroupState.Passed) 'multi-subnet validation rejects core and listener addresses collapsed into one group'
    $singleOffline = @([pscustomobject]@{ Name = 'Single'; State = 'Offline'; OwnerGroup = $coreGroup; Parameters = @{ Address = '10.0.1.201'; Network = 'Net1' } })
    $singleOfflineState = Get-SqlAoIpResourceHealth -Resources $singleOffline -ExpectedClusterIPs @('10.0.1.201') -ExpectedListenerIPs @()
    Assert-Validation (-not $singleOfflineState.Passed) 'single-subnet offline IP remains actionable'
    Assert-Validation ($singleOfflineState.ExpectedStandbyNames.Count -eq 0) 'single-subnet offline IP is not filtered as expected standby'
    $virtualIpFixture = [pscustomobject]@{
        role = 'SQLAO'
        ClusterIPAddress = '10.0.1.201/24'
        AGIPAddress = '10.0.1.202/255.255.255.0'
        thisParams = [pscustomobject]@{
            SQLAO = [pscustomobject]@{
                ClusterIPAddresses = @('10.0.1.201/24', '10.0.2.201/24')
                AGIPAddresses = @('10.0.1.202/255.255.255.0', '10.0.2.202/255.255.255.0')
            }
        }
    }
    $virtualIpSet = @(Get-SqlAoVirtualIpAddresses -Sources @($virtualIpFixture) | Sort-Object)
    Assert-Validation (($virtualIpSet -join ',') -eq '10.0.1.201,10.0.1.202,10.0.2.201,10.0.2.202') 'DNS validation excludes singular and plural SQLAO virtual IPs on every subnet'
    $virtualIpFixture.thisParams.SQLAO | Add-Member -NotePropertyName SQLAOPort -NotePropertyValue 1500
    $nestedClusterIps = @(Get-SqlAoConfigValue -Vm $virtualIpFixture -Name 'ClusterIPAddresses' -AsArray)
    $nestedListenerIps = @(Get-SqlAoConfigValue -Vm $virtualIpFixture -Name 'AGIPAddresses' -AsArray)
    Assert-Validation (($nestedClusterIps -join ',') -eq '10.0.1.201/24,10.0.2.201/24') 'SQLAO validation resolves nested cluster IP arrays from saved deployment metadata'
    Assert-Validation (($nestedListenerIps -join ',') -eq '10.0.1.202/255.255.255.0,10.0.2.202/255.255.255.0') 'SQLAO validation resolves nested listener IP arrays from saved deployment metadata'
    Assert-Validation ((Get-SqlAoConfigValue -Vm $virtualIpFixture -Name 'SQLAOPort') -eq 1500) 'SQLAO validation resolves the nested listener port'
    $nodeResolutionFixture = [pscustomobject]@{
        vmName = 'FAB-PS1SQLAO2'
        role = 'SQLAO'
        thisParams = $virtualIpFixture.thisParams
    }
    $nodeResolutionNote = [pscustomobject]@{
        AssignedIP = '10.0.2.20'
        LastKnownIP = '10.0.2.201'
        ClusterIPAddresses = @('10.0.1.201/24', '10.0.2.201/24')
        AGIPAddresses = @('10.0.1.202/255.255.255.0', '10.0.2.202/255.255.255.0')
    }
    $nodeResolution = Resolve-SqlAoNodeAddress -Vm $nodeResolutionFixture -VmNote $nodeResolutionNote `
        -AdapterAddresses @('10.0.2.201', '10.0.2.20') -SqlAoSources @($virtualIpFixture, $nodeResolutionNote)
    Assert-Validation ($nodeResolution.Address -eq '10.0.2.20' -and $nodeResolution.Source -eq 'NoteAssignedIP') 'shared node resolver chooses persisted physical IP ahead of partner-subnet VIP'
    Assert-Validation ($nodeResolution.FilteredAdapterAddresses -join ',' -eq '10.0.2.20') 'shared node resolver removes every singular/plural VIP from adapter candidates'
    $functionalSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Validation.Functional.ps1') -Raw
    $functionalPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'

    . (Import-TestFunction -Path $functionalPath -Name 'Test-SQLAOFunctionality')
    . (Import-TestFunction -Path $functionalPath -Name 'Test-SQLAOPostPhase5')
    $tokens = $null
    $parseErrors = $null
    $functionalAst = [Management.Automation.Language.Parser]::ParseFile($functionalPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw "Could not parse ${functionalPath}: $($parseErrors[0].Message)" }
    $basicSqlAst = @($functionalAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SQLFunctionality'
            }, $true)) | Select-Object -First 1
    $basicSqlParameterNames = @($basicSqlAst.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert-Validation ($basicSqlParameterNames -notcontains 'RecoveryRetry') 'basic SQL validation does not own the SQLAO recovery retry switch'
    function Write-Log {}
    function Add-Phase11Output { param($Text, $Level) }
    function Test-SQLFunctionality { return $true }
    function Format-TestResult {
        param($VMName, $RoleLabel, $Result)
        return [bool]$Result.ScriptBlockOutput.Passed
    }
    $script:Phase11SqlAoArguments = $null
    $script:Phase5SqlAoArguments = $null
    $script:RecoveryScenario = 'None'
    $script:RecoveryValidationCalls = 0
    $script:RecoveryRestartCalls = 0
    function Invoke-VmCommand {
        param(
            $VmName, $VmDomainName, $ScriptBlock, [object[]]$ArgumentList,
            $DisplayName, $TimeoutSeconds, [switch]$SuppressLog, [switch]$AsJob,
            [switch]$PollProgress
        )
        if ($DisplayName -eq 'Phase11-SQLAO-Test') {
            $script:Phase11SqlAoArguments = $ArgumentList
            if ($script:RecoveryScenario -ne 'None') {
                $script:RecoveryValidationCalls++
                $requestRecovery = $script:RecoveryScenario -eq 'AlwaysRequest' -or
                    ($script:RecoveryScenario -in 'RecoverOnce', 'RestartFailure' -and $script:RecoveryValidationCalls -eq 1)
                return [pscustomobject]@{
                    ScriptBlockFailed = $false
                    ScriptBlockOutput = @{
                        Passed = -not $requestRecovery
                        Details = @()
                        RecoveryTarget = if ($requestRecovery) { 'FAB-PS1SQLAO2' } else { '' }
                        RecoveryService = if ($requestRecovery) { 'MSSQLSERVER' } else { '' }
                    }
                }
            }
        }
        if ($DisplayName -eq 'Phase11-SQLAO-Recovery-Restart') {
            $script:RecoveryRestartCalls++
            return [pscustomobject]@{
                ScriptBlockFailed = $script:RecoveryScenario -eq 'RestartFailure'
                ScriptBlockOutput = if ($script:RecoveryScenario -eq 'RestartFailure') { 'injected restart failure' } else { [string]$ArgumentList[0] }
            }
        }
        if ($DisplayName -eq 'Phase5-SQLAO-Validate') { $script:Phase5SqlAoArguments = $ArgumentList }
        [pscustomobject]@{
            ScriptBlockFailed = $false
            ScriptBlockOutput = @{ Passed = $true; Details = @() }
        }
    }
    $savedMetadataOwner = [pscustomobject]@{
        vmName = 'FAB-PS1SQLAO1'
        role = 'SQLAO'
        OtherNode = 'FAB-PS1SQLAO2'
        fileServerVM = 'FAB-FS1'
        ClusterName = 'FAB-SQLCLUSTER'
        AlwaysOnGroupName = 'PS1 Availability Group'
        AlwaysOnListenerName = 'FAB-ALWAYSON'
        sqlInstanceName = 'MSSQLSERVER'
        thisParams = [pscustomobject]@{
            SQLAO = [pscustomobject]@{
                ClusterName = 'FAB-SQLCLUSTER'
                ClusterIPAddress = '192.168.3.201/24'
                ClusterIPAddresses = @('192.168.3.201/24', '172.16.4.201/24')
                AlwaysOnGroupName = 'PS1 Availability Group'
                AlwaysOnListenerName = 'FAB-ALWAYSON'
                AGIPAddress = '192.168.3.202/255.255.255.0'
                AGIPAddresses = @('192.168.3.202/255.255.255.0', '172.16.4.202/255.255.255.0')
                FileServerName = 'FAB-FS1'
                WitnessShareFQ = '\\FAB-FS1\SQLCLUSTER-Witness'
                BackupShareFQ = '\\FAB-FS1\SQLCLUSTER-Backup'
                SQLAOPort = 1500
            }
        }
    }
    $savedMetadataDeploy = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'fabrikam.com'; prefix = 'FAB-' }
        virtualMachines = @(
            $savedMetadataOwner,
            [pscustomobject]@{ vmName = 'FAB-PS1SQLAO2'; role = 'SQLAO'; sqlInstanceName = 'MSSQLSERVER' }
        )
    }
    function Get-VMNote {
        param($VMName)
        $assigned = if ($VMName -eq 'FAB-PS1SQLAO1') { '192.168.3.22' } else { '172.16.4.20' }
        [pscustomobject]@{
            AssignedIP = $assigned
            LastKnownIP = $assigned
            ClusterIPAddresses = @('192.168.3.201/24', '172.16.4.201/24')
            AGIPAddresses = @('192.168.3.202/255.255.255.0', '172.16.4.202/255.255.255.0')
        }
    }
    function Get-VMNetworkAdapter {
        param($VMName)
        $assigned = if ($VMName -eq 'FAB-PS1SQLAO1') { '192.168.3.22' } else { '172.16.4.20' }
        [pscustomobject]@{ IPAddresses = @($assigned) }
    }
    $phase11MetadataPassed = Test-SQLAOFunctionality -VMName 'FAB-PS1SQLAO1' -CurrentItem $savedMetadataOwner -DeployConfig $savedMetadataDeploy
    $phase5MetadataPassed = Test-SQLAOPostPhase5 -DeployConfig $savedMetadataDeploy
    Assert-Validation $phase11MetadataPassed 'Phase 11 SQLAO fixture accepts saved nested metadata'
    Assert-Validation $phase5MetadataPassed 'post-Phase-5 SQLAO fixture accepts saved nested metadata'
    Assert-Validation ($script:Phase11SqlAoArguments[10] -eq '192.168.3.201,172.16.4.201') 'Phase 11 sends every nested cluster IP through the scalar remoting contract'
    Assert-Validation ($script:Phase11SqlAoArguments[11] -eq '192.168.3.202,172.16.4.202') 'Phase 11 sends every nested listener IP through the scalar remoting contract'
    Assert-Validation ($script:Phase11SqlAoArguments[13] -eq 'FAB-PS1SQLAO1,FAB-PS1SQLAO2') 'Phase 11 owner validation receives the exact configured replica set'
    Assert-Validation ($script:Phase5SqlAoArguments[10] -eq '192.168.3.201,172.16.4.201') 'post-Phase-5 validation sends every nested cluster IP'
    Assert-Validation ($script:Phase5SqlAoArguments[11] -eq '192.168.3.202,172.16.4.202') 'post-Phase-5 validation sends every nested listener IP'
    $phase11CallsBeforeSecondary = $script:RecoveryValidationCalls
    $secondaryValidationPassed = Test-SQLAOFunctionality -VMName 'FAB-PS1SQLAO2' -CurrentItem $savedMetadataDeploy.virtualMachines[1] -DeployConfig $savedMetadataDeploy
    Assert-Validation ($secondaryValidationPassed -and $script:RecoveryValidationCalls -eq $phase11CallsBeforeSecondary) 'secondary performs local SQL validation without duplicate concurrent AG validation'
    $savedMetadataOwner.sqlInstanceName = 'AO'
    $savedMetadataDeploy.virtualMachines[1].sqlInstanceName = 'AO'
    $null = Test-SQLAOFunctionality -VMName 'FAB-PS1SQLAO1' -CurrentItem $savedMetadataOwner -DeployConfig $savedMetadataDeploy
    $null = Test-SQLAOPostPhase5 -DeployConfig $savedMetadataDeploy
    Assert-Validation ($script:Phase11SqlAoArguments[7] -eq 'AO') 'Phase 11 receives the configured named SQL instance'
    Assert-Validation ($script:Phase5SqlAoArguments[13] -eq 'FAB-PS1SQLAO1\AO,FAB-PS1SQLAO2\AO') 'post-Phase-5 exact replica contract includes named instances'
    Assert-Validation ($script:Phase5SqlAoArguments[15] -eq 'AO') 'post-Phase-5 guest receives the configured named instance'
    Assert-Validation ($script:Phase5SqlAoArguments[16] -eq 'True') 'post-Phase-5 guest receives RegisterAllProvidersIP policy'
    Assert-Validation ($script:Phase5SqlAoArguments[17] -eq '300') 'post-Phase-5 guest receives listener DNS TTL policy'
    $savedMetadataOwner.sqlInstanceName = 'MSSQLSERVER'
    $savedMetadataDeploy.virtualMachines[1].sqlInstanceName = 'MSSQLSERVER'

    Assert-Validation ((Get-Command Test-SQLAOFunctionality).Parameters.ContainsKey('RecoveryRetry')) 'SQLAO validation declares the bounded recovery retry switch'
    function Start-Sleep {}
    $script:RecoveryScenario = 'RecoverOnce'
    $script:RecoveryValidationCalls = 0
    $script:RecoveryRestartCalls = 0
    $recoverySucceeded = Test-SQLAOFunctionality -VMName 'FAB-PS1SQLAO1' -CurrentItem $savedMetadataOwner -DeployConfig $savedMetadataDeploy
    Assert-Validation ($recoverySucceeded -and $script:RecoveryValidationCalls -eq 2 -and $script:RecoveryRestartCalls -eq 1) 'host recovery performs one restart and exactly one validation retry'

    $script:RecoveryScenario = 'AlwaysRequest'
    $script:RecoveryValidationCalls = 0
    $script:RecoveryRestartCalls = 0
    $boundedRetryResult = Test-SQLAOFunctionality -VMName 'FAB-PS1SQLAO1' -CurrentItem $savedMetadataOwner -DeployConfig $savedMetadataDeploy
    Assert-Validation (-not $boundedRetryResult -and $script:RecoveryValidationCalls -eq 2 -and $script:RecoveryRestartCalls -eq 1) 'persistent recovery request is bounded to two validations and one restart'

    $script:RecoveryValidationCalls = 0
    $script:RecoveryRestartCalls = 0
    $directRetryResult = Test-SQLAOFunctionality -VMName 'FAB-PS1SQLAO1' -CurrentItem $savedMetadataOwner -DeployConfig $savedMetadataDeploy -RecoveryRetry
    Assert-Validation (-not $directRetryResult -and $script:RecoveryValidationCalls -eq 1 -and $script:RecoveryRestartCalls -eq 0) 'RecoveryRetry cannot recurse or restart a second time'

    $script:RecoveryScenario = 'RestartFailure'
    $script:RecoveryValidationCalls = 0
    $script:RecoveryRestartCalls = 0
    $restartFailureResult = Test-SQLAOFunctionality -VMName 'FAB-PS1SQLAO1' -CurrentItem $savedMetadataOwner -DeployConfig $savedMetadataDeploy
    Assert-Validation (-not $restartFailureResult -and $script:RecoveryValidationCalls -eq 1 -and $script:RecoveryRestartCalls -eq 1) 'restart failure remains failed without recursive validation'

    $script:RecoveryScenario = 'None'

    . (Import-TestFunction -Path $functionalPath -Name 'Test-DCFunctionality')
    $script:ExpectedDnsArgument = $null
    $script:SqlAoNodeArgument = $null
    $script:AdapterLookupCount = 0
    function Get-VMNote {
        [pscustomobject]@{
            AssignedIP = '172.16.4.20'
            LastKnownIP = '172.16.4.20'
            ClusterIPAddresses = @('192.168.3.201/24', '172.16.4.201/24')
            AGIPAddresses = @('192.168.3.202/255.255.255.0', '172.16.4.202/255.255.255.0')
        }
    }
    function Get-VMNetworkAdapter {
        $script:AdapterLookupCount++
        throw 'VM adapter lookup must not run when VM-note AssignedIP exists'
    }
    function Invoke-VmCommand {
        param(
            $VmName, $VmDomainName, $ScriptBlock, [object[]]$ArgumentList,
            $DisplayName, $TimeoutSeconds, [switch]$SuppressLog, [switch]$AsJob
        )
        $script:ExpectedDnsArgument = $ArgumentList[2]
        $script:SqlAoNodeArgument = $ArgumentList[5]
        [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = [pscustomobject]@{ Passed = $true; Details = @() } }
    }
    function Test-DhcpReservations { return $true }

    $dnsFixture = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'fabrikam.com'; network = '192.168.3.0' }
        virtualMachines = @(
            [pscustomobject]@{
                vmName = 'FAB-PS1SQLAO2'
                role = 'SQLAO'
                network = '172.16.4.0'
                thisParams = [pscustomobject]@{
                    SQLAO = [pscustomobject]@{
                        ClusterIPAddresses = @('192.168.3.201/24', '172.16.4.201/24')
                        AGIPAddresses = @('192.168.3.202/255.255.255.0', '172.16.4.202/255.255.255.0')
                    }
                }
            }
        )
    }
    $dnsBuilderPassed = Test-DCFunctionality -VMName 'FAB-DC1' -Domain 'fabrikam.com' -DeployConfig $dnsFixture
    Assert-Validation $dnsBuilderPassed 'DC DNS validation fixture completes with mocked guest validation'
    Assert-Validation ($script:ExpectedDnsArgument -eq 'FAB-PS1SQLAO2=172.16.4.20') 'persisted allocator address takes precedence over live adapter virtual IPs'
    Assert-Validation ($script:SqlAoNodeArgument -eq 'FAB-PS1SQLAO2') 'SQLAO node identity crosses the scalar remoting contract'
    Assert-Validation ($script:AdapterLookupCount -eq 0) 'allocator-owned VM-note address bypasses ambiguous Hyper-V adapter addresses'

    $reconcileDnsARecord = Import-AssignedScriptBlock -Path $functionalPath -VariableName 'reconcileDnsARecord'
    function New-TestDnsRecord {
        param([string]$IPAddress)
        [pscustomobject]@{
            Id = [guid]::NewGuid().ToString('N')
            RecordData = [pscustomobject]@{
                IPv4Address = [pscustomobject]@{ IPAddressToString = $IPAddress }
            }
        }
    }
    function Set-TestDnsRecords {
        param([string[]]$IPAddresses)
        $script:DnsRecords = [System.Collections.Generic.List[object]]::new()
        foreach ($address in @($IPAddresses)) { $script:DnsRecords.Add((New-TestDnsRecord -IPAddress $address)) }
        $script:DnsQueryCall = 0
        $script:DnsFailQueryCall = 0
        $script:DnsNameNotFoundCall = 0
        $script:DnsFailAdd = $false
        $script:DnsFailRemove = $false
        $script:DnsConcurrentRemoveThenThrow = $false
    }
    function Get-TestDnsIps {
        return @($script:DnsRecords | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
    }
    function Get-DnsServerResourceRecord {
        param($ZoneName, $Name, $RRType, $ComputerName, $ErrorAction)
        $script:DnsQueryCall++
        if ($script:DnsNameNotFoundCall -eq $script:DnsQueryCall) {
            throw [ComponentModel.Win32Exception]::new(9701)
        }
        if ($script:DnsFailQueryCall -eq $script:DnsQueryCall) { throw 'injected DNS query failure' }
        return @($script:DnsRecords)
    }
    function Add-DnsServerResourceRecordA {
        param($ZoneName, $Name, $IPv4Address, $ComputerName, $ErrorAction)
        if ($script:DnsFailAdd) { throw 'injected DNS add failure' }
        $script:DnsRecords.Add((New-TestDnsRecord -IPAddress $IPv4Address))
    }
    function Remove-DnsServerResourceRecord {
        param($ZoneName, $InputObject, $ComputerName, [switch]$Force, $ErrorAction)
        if ($script:DnsConcurrentRemoveThenThrow) {
            $null = $script:DnsRecords.Remove($InputObject)
            $script:DnsConcurrentRemoveThenThrow = $false
            throw 'injected concurrent deletion'
        }
        if ($script:DnsFailRemove) { throw 'injected DNS removal failure' }
        $null = $script:DnsRecords.Remove($InputObject)
    }
    function Start-Sleep {}

    Set-TestDnsRecords -IPAddresses @()
    $emptyRepair = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation ($emptyRepair.Passed -and ((Get-TestDnsIps) -join ',') -eq '172.16.4.20') 'empty node RRset is repaired to the allocator address'

    Set-TestDnsRecords -IPAddresses @()
    $script:DnsNameNotFoundCall = 1
    $missingNameRepair = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation ($missingNameRepair.Passed -and ((Get-TestDnsIps) -join ',') -eq '172.16.4.20') 'authoritative DNS name-not-found is treated as an empty repairable RRset'

    Set-TestDnsRecords -IPAddresses @('172.16.4.201')
    $vipRepair = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation ($vipRepair.Passed -and ((Get-TestDnsIps) -join ',') -eq '172.16.4.20') 'VIP-only node RRset is repaired exactly'

    Set-TestDnsRecords -IPAddresses @('172.16.4.20', '172.16.4.201')
    $extraRepair = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation ($extraRepair.Passed -and ((Get-TestDnsIps) -join ',') -eq '172.16.4.20') 'expected-plus-VIP RRset removes the virtual address'

    Set-TestDnsRecords -IPAddresses @('172.16.4.20', '172.16.4.20')
    $duplicateRepair = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation ($duplicateRepair.Passed -and (Get-TestDnsIps).Count -eq 1) 'duplicate expected records converge to one record'

    Set-TestDnsRecords -IPAddresses @('172.16.4.201')
    $script:DnsConcurrentRemoveThenThrow = $true
    $concurrentRepair = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation ($concurrentRepair.Passed -and ((Get-TestDnsIps) -join ',') -eq '172.16.4.20') 'concurrent stale-record removal remains idempotent'

    Set-TestDnsRecords -IPAddresses @('172.16.4.201')
    $script:DnsFailRemove = $true
    $removeFailure = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation (-not $removeFailure.Passed) 'unresolved extra record fails the exact DNS postcondition'

    Set-TestDnsRecords -IPAddresses @()
    $script:DnsFailAdd = $true
    $addFailure = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation (-not $addFailure.Passed) 'missing record that cannot be added fails the exact DNS postcondition'

    Set-TestDnsRecords -IPAddresses @('172.16.4.20')
    $script:DnsFailQueryCall = 1
    $queryFailure = & $reconcileDnsARecord -Zone 'fabrikam.com' -Name 'FAB-PS1SQLAO2' -ExpectedIp '172.16.4.20' -DnsServer 'FAB-DC1' -MaxAttempts 1
    Assert-Validation (-not $queryFailure.Passed) 'authoritative DNS query failure cannot report success'

    $registrationScript = Import-AssignedScriptBlock -Path $functionalPath -VariableName 'registrationScript'
    $script:RegistrationAddresses = @(
        [pscustomobject]@{ IPAddress = '172.16.4.20'; InterfaceIndex = 7; SkipAsSource = $true },
        [pscustomobject]@{ IPAddress = '172.16.4.201'; InterfaceIndex = 7; SkipAsSource = $false },
        [pscustomobject]@{ IPAddress = '172.16.4.202'; InterfaceIndex = 7; SkipAsSource = $false }
    )
    $script:DnsClientState = [pscustomobject]@{ InterfaceIndex = 7; RegisterThisConnectionsAddress = $false }
    $script:FailNetIpQuery = $false
    function Get-NetIPAddress {
        param($AddressFamily, $InterfaceIndex, $ErrorAction)
        if ($script:FailNetIpQuery) { throw 'injected Get-NetIPAddress failure' }
        $filterByInterface = $PSBoundParameters.ContainsKey('InterfaceIndex')
        @($script:RegistrationAddresses | Where-Object { -not $filterByInterface -or $_.InterfaceIndex -eq $InterfaceIndex })
    }
    function Set-NetIPAddress {
        param($InterfaceIndex, $IPAddress, [bool]$SkipAsSource, $ErrorAction)
        ($script:RegistrationAddresses | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex -and $_.IPAddress -eq $IPAddress }).SkipAsSource = $SkipAsSource
    }
    function Get-DnsClient { param($InterfaceIndex, $ErrorAction); return $script:DnsClientState }
    function Set-DnsClient {
        param($InterfaceIndex, [bool]$RegisterThisConnectionsAddress, $ErrorAction)
        $script:DnsClientState.RegisterThisConnectionsAddress = $RegisterThisConnectionsAddress
    }
    Set-Item -Path Function:ipconfig.exe -Value { $global:LASTEXITCODE = 0 }
    $global:LASTEXITCODE = 0
    $null = & $registrationScript '172.16.4.20' 'FAB-PS1SQLAO2'
    $registrationState = @($script:RegistrationAddresses | ForEach-Object { "$($_.IPAddress)=$($_.SkipAsSource)" })
    Assert-Validation (
        $registrationState -contains '172.16.4.20=False' -and
        $registrationState -contains '172.16.4.201=True' -and
        $registrationState -contains '172.16.4.202=True' -and
        $script:DnsClientState.RegisterThisConnectionsAddress
    ) 'SQLAO registration keeps only the node address eligible for DNS'
    $null = & $registrationScript '172.16.4.20' 'FAB-PS1SQLAO2'
    Assert-Validation (
        @($script:RegistrationAddresses | Where-Object {
                ($_.IPAddress -eq '172.16.4.20' -and $_.SkipAsSource) -or
                ($_.IPAddress -ne '172.16.4.20' -and -not $_.SkipAsSource)
            }).Count -eq 0
    ) 'SQLAO SkipAsSource reconciliation is idempotent across registration events'

    Assert-Validation ($functionalSource -match '(?s)else \{\s+\$results\.Passed = \$false\s+\$mismatches\+\+.+?FAIL: DNS') 'failed exact DNS postcondition fails Phase 11'
    Assert-Validation (-not ($functionalSource -match '\$results\.Passed = \$true')) 'SQLAO recovery never resets the aggregate verdict to success'
    Assert-Validation ($functionalSource -match "FAIL: SQL connection via listener '.+did not succeed after bounded recovery") 'terminal listener timeout/error is a hard failure'
    Assert-Validation ($functionalSource -match 'cycling active AG IP resource.+inactive-subnet providers offline') 'listener recovery cycles only the active provider'
    Assert-Validation ($functionalSource.Contains("AG recovery is owned by '`$recoveryOwner'")) 'destructive AG recovery is serialized to one deterministic owner'
    Assert-Validation ($functionalSource -match '(?s)agHealthDeferred.+?Exact AG health query through' -and $functionalSource -match 'after listener recovery') 'initial listener failure defers exact AG verdict until listener recovery'
    Assert-Validation ($functionalSource.Contains('Invoke-Sqlcmd -ServerInstance $healthSqlTarget -Query $healthQuery')) 'Phase 11 AG health queries the active primary through the listener'
    Assert-Validation ($functionalSource.Contains('"MSSQL`$$sqlInstName"')) 'named SQLAO recovery targets the named SQL service'
    Assert-Validation ($functionalSource -match 'Phase11-SQLAO-Recovery-Restart' -and
        $functionalSource -match 'Invoke-VmCommand -VmName \$recoveryTarget') 'disconnected replica restart uses host PowerShell Direct'
    Assert-Validation (-not ($functionalSource -match 'Invoke-Command -ComputerName \$restartTarget')) 'SQLAO recovery does not depend on cross-subnet guest WinRM'
    Assert-Validation ($functionalSource -match 'expectedReplicaCsv -split' -and $functionalSource -match '\(\$expectedReplicaNames -join '',''\)') 'owner validation consumes the host-normalized configured replica set'
    Assert-Validation ($functionalSource -match 'shared cluster/AG validation and recovery are owned by') 'shared AG validation is serialized to the configured owner'
    Assert-Validation ($functionalSource -match 'AG replica set is.+expected exactly') 'post-Phase-5 validation requires the exact replica set'
    Assert-Validation ($functionalSource.Contains('$activeClusterIPs = @(Get-ClusterResource') -and
        $functionalSource.Contains('Where-Object { $_ -in $clusterIPs })')) 'post-Phase-5 derives the active core provider before exact cluster DNS validation'
    Assert-Validation ($functionalSource -match '(?s)Phase5-SQLAO-Validate.+?-AsJob -TimeoutSeconds 600') 'post-Phase-5 validation has a hard outer timeout'
    Assert-Validation ([regex]::Matches($functionalSource, '\(\$clusterIPs -join '',''\)').Count -ge 2) 'Phase 5 and Phase 11 serialize cluster IP arrays as scalar remoting arguments'
    Assert-Validation ([regex]::Matches($functionalSource, '\(\$agIPs -join '',''\)').Count -ge 2) 'Phase 5 and Phase 11 serialize listener IP arrays as scalar remoting arguments'
    Assert-Validation ([regex]::Matches($functionalSource, '\$clusterIpCsv -split '',''').Count -ge 2) 'Phase 5 and Phase 11 reconstruct cluster IP arrays in the guest'
    Assert-Validation ([regex]::Matches($functionalSource, '\$agIpCsv -split '',''').Count -ge 2) 'Phase 5 and Phase 11 reconstruct listener IP arrays in the guest'
    $argumentContract = {
        param($a1, $a2, $a3, $a4, $a5, $a6, $a7, $a8, $a9, $a10, $clusterCsv, $listenerCsv)
        [pscustomobject]@{
            Cluster = @($clusterCsv -split ',' | Where-Object { $_ })
            Listener = @($listenerCsv -split ',' | Where-Object { $_ })
        }
    }
    $contractArgs = @('1','2','3','4','5','6','7','8','9','10', ($expectedClusterIps -join ','), ($expectedListenerIps -join ','))
    $contractResult = & $argumentContract @contractArgs
    Assert-Validation (($contractResult.Cluster -join ',') -eq ($expectedClusterIps -join ',')) 'scalar argument contract round-trips cluster IP arrays'
    Assert-Validation (($contractResult.Listener -join ',') -eq ($expectedListenerIps -join ',')) 'scalar argument contract round-trips listener IP arrays'
    Assert-Validation ($functionalSource.Contains("-notmatch '^Domain Network(?: \d+)?$'")) 'cluster network validation accepts only deterministic Domain Network names'
    Assert-Validation ([regex]::Matches($functionalSource, 'AG health checks above can move ownership').Count -eq 2) 'Phase 5 and Phase 11 refresh active listener ownership immediately before DNS checks'
    Assert-Validation ($functionalSource -match 'FAIL: Listener DNS RRset is.+expected exactly') 'Phase 11 fails any non-exact listener DNS provider set'
    Assert-Validation ($functionalSource -match 'expectedListenerDns = if \(\$listenerRegisterAllProvidersIP\)') 'post-Phase-5 DNS derives the expected set from RegisterAllProvidersIP'
    Assert-Validation ($functionalSource -match '(?s)Add-DnsServerResourceRecordA.+?TimeToLive' -and $functionalSource -match 'Remove-DnsServerResourceRecord.+?InputObject') 'post-Phase-5 DNS remediation adds missing expected records and removes stale or duplicate records'
    Assert-Validation ($functionalSource -match 'Exact listener DNS RRset verified on DC') 'post-Phase-5 DNS remediation verifies exact state on every DC'
    Assert-Validation ($functionalSource -match 'no expected provider set could be identified; refusing to synthesize') 'post-Phase-5 DNS remediation refuses an unverified provider set'
    Assert-Validation ($functionalSource -match 'if \(\$keep\) \{ \$null = \$seenExpected\.Add\(\$recordIp\) \}') 'wrong-TTL records are not marked as retained before replacement'
    $physicalAddressScript = Import-AssignedScriptBlock -Path $functionalPath -VariableName 'physicalAddressScript'
    $script:RegistrationAddresses = @(
        [pscustomobject]@{ IPAddress = '172.16.4.20'; InterfaceIndex = 7; SkipAsSource = $false },
        [pscustomobject]@{ IPAddress = '172.16.4.201'; InterfaceIndex = 7; SkipAsSource = $true },
        [pscustomobject]@{ IPAddress = '172.16.4.202'; InterfaceIndex = 7; SkipAsSource = $true }
    )
    $physicalHealthy = & $physicalAddressScript '172.16.4.20' '192.168.3.201,172.16.4.201' '192.168.3.202,172.16.4.202'
    Assert-Validation ($physicalHealthy.Valid -and $physicalHealthy.NodeCount -eq 1 -and -not $physicalHealthy.NodeSkipAsSource) 'shipped physical-address check accepts one registrable node IP and skipped VIPs'
    $script:RegistrationAddresses[0].SkipAsSource = $true
    $physicalNodeSkipped = & $physicalAddressScript '172.16.4.20' '192.168.3.201,172.16.4.201' '192.168.3.202,172.16.4.202'
    Assert-Validation (-not $physicalNodeSkipped.Valid) 'shipped physical-address check rejects a skipped node IP'
    $script:RegistrationAddresses[0].SkipAsSource = $false
    $script:RegistrationAddresses[1].SkipAsSource = $false
    $physicalVipRegistrable = & $physicalAddressScript '172.16.4.20' '192.168.3.201,172.16.4.201' '192.168.3.202,172.16.4.202'
    Assert-Validation (-not $physicalVipRegistrable.Valid -and @($physicalVipRegistrable.BadVirtualIps) -contains '172.16.4.201') 'shipped physical-address check rejects a registrable cluster VIP'
    $script:RegistrationAddresses = @($script:RegistrationAddresses | Where-Object { $_.IPAddress -ne '172.16.4.20' })
    $physicalNodeMissing = & $physicalAddressScript '172.16.4.20' '192.168.3.201,172.16.4.201' '192.168.3.202,172.16.4.202'
    Assert-Validation (-not $physicalNodeMissing.Valid -and $physicalNodeMissing.NodeCount -eq 0) 'shipped physical-address check rejects a missing node IP'
    $script:FailNetIpQuery = $true
    $physicalQueryFailed = $false
    try { $null = & $physicalAddressScript '172.16.4.20' '192.168.3.201,172.16.4.201' '192.168.3.202,172.16.4.202' }
    catch { $physicalQueryFailed = $_.Exception.Message -like '*injected Get-NetIPAddress failure*' }
    Assert-Validation $physicalQueryFailed 'shipped physical-address check surfaces address query failures'
    $script:FailNetIpQuery = $false
    $scriptBlocksSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1') -Raw
    Assert-Validation ([regex]::Matches($scriptBlocksSource, 'Resolve-SqlAoNodeAddress').Count -ge 3) 'LastKnownIP, Phase 5 preflight, and Phase 5 scrub share physical-node resolution'
    Assert-Validation (-not ($scriptBlocksSource -match 'GetIPs-unfiltered')) 'SQLAO LastKnownIP refresh has no unfiltered virtual-IP fallback'
    Assert-Validation ($scriptBlocksSource -match 'Refusing to publish a possible cluster/listener VIP') 'Phase 5 preflight fails closed when no physical node IP can be proven'
    Assert-Validation ($scriptBlocksSource -match '\$pfResolvedIps\.Count -ne 1 -or \$pfResolvedIps\[0\] -ne \$pfOwnIp') 'Phase 5 preflight requires exactly one physical-node A record'
    Assert-Validation ($scriptBlocksSource -match 'Reconcile physical SQLAO node DNS' -and $scriptBlocksSource -match 'DNS postcondition is') 'Phase 5 preflight authoritatively reconciles and verifies the exact node RRset'
}
finally {
    Pop-Location
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO multi-subnet validation check(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO multi-subnet authoritative validation checks passed.'
