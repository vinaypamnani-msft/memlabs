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

    $ipResources[0].State = 'Offline'
    $zeroOnlineState = Get-SqlAoIpResourceHealth -Resources $ipResources -ExpectedClusterIPs $expectedClusterIps -ExpectedListenerIPs $expectedListenerIps
    Assert-Validation (-not $zeroOnlineState.Passed) 'multi-subnet validation rejects a resource group with no online provider'
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
    $functionalSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Validation.Functional.ps1') -Raw
    Assert-Validation ([regex]::Matches($functionalSource, 'validationArguments \+= ,@\(\$clusterIPs\)').Count -eq 2) 'Phase 5 and Phase 11 preserve nested cluster IP arrays in remote argument lists'
    Assert-Validation ([regex]::Matches($functionalSource, 'validationArguments \+= ,@\(\$agIPs\)').Count -eq 2) 'Phase 5 and Phase 11 preserve nested listener IP arrays in remote argument lists'
}
finally {
    Pop-Location
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO multi-subnet validation check(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO multi-subnet authoritative validation checks passed.'
