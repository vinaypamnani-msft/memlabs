<#
.SYNOPSIS
    Verifies main-era multi-subnet DPs remain targetable when develop adds VMs.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'

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

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Write-Log {
    param([string]$Message, [switch]$LogOnly, [switch]$Warning)
}

. (Import-TestFunction -Path $configPath -Name 'Add-Phase8DistributionPointMetadata')
. (Import-TestFunction -Path $perfloadingPath -Name 'Get-MemLabsManagedDistributionPointNames')
. (Import-TestFunction -Path $perfloadingPath -Name 'Get-MemLabsOsdTargetingPlan')
. (Import-TestFunction -Path $validationPath -Name 'Get-Phase11OsdTargetingExpectation')

$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{
        domainName = 'multisubnet.test'
        network = '10.10.1.0'
    }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'; hidden = $true
            network = '10.10.1.0'
        },
        [pscustomobject]@{
            vmName = 'NEWDP4'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true
            network = '10.10.4.0'
        },
        [pscustomobject]@{
            vmName = 'DP3'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true
            hidden = $true
        }
    )
}
$existing = @(
    [pscustomobject]@{
        vmName = 'DP1'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true
        domain = 'multisubnet.test'; network = '10.10.1.0'
    },
    [pscustomobject]@{
        vmName = 'DP2'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true
        domain = 'multisubnet.test'; network = '10.10.2.0'
    },
    [pscustomobject]@{
        vmName = 'DP3'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true
        domain = 'multisubnet.test'; network = '10.10.3.0'
    },
    [pscustomobject]@{
        vmName = 'SEC1'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI'
        domain = 'multisubnet.test'; network = '10.10.2.0'
    },
    [pscustomobject]@{
        vmName = 'OSD1'; role = 'OSDClient'; domain = 'multisubnet.test'; network = '10.10.1.0'
    },
    [pscustomobject]@{
        vmName = 'OSD2'; role = 'OSDClient'; domain = 'multisubnet.test'; network = '10.10.2.0'
    },
    [pscustomobject]@{
        vmName = 'OSD3'; role = 'OSDClient'; domain = 'multisubnet.test'; network = '10.10.3.0'
    },
    [pscustomobject]@{
        vmName = 'OTHERDP'; role = 'SiteSystem'; siteCode = 'OTH'; installDP = $true
        domain = 'multisubnet.test'; network = '10.10.6.0'
    },
    [pscustomobject]@{
        vmName = 'OTHEROSD'; role = 'OSDClient'
        domain = 'multisubnet.test'; network = '10.10.6.0'
    },
    [pscustomobject]@{
        vmName = 'FOREIGNDP'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true
        domain = 'foreign.test'; network = '10.10.3.0'
    }
)

Add-Phase8DistributionPointMetadata -Config $config -ExistingVMs $existing -InventoryRefreshVerified $true
Assert-Equal '10.10.1.0,10.10.2.0,10.10.3.0,10.10.6.0' (@($config.phase8OsdClientSubnets | Sort-Object) -join ',') `
    'Domain-wide existing main-era OSD client subnets were not projected.'

$scope = @($config.phase8ManagedDistributionPointScopes | Where-Object PrimarySiteCode -eq 'PRI')
Assert-Equal 1 $scope.Count 'Expected one Primary ownership scope.'
Assert-Equal '10.10.1.0,10.10.2.0,10.10.3.0' (@($scope[0].OsdClientSubnets | Sort-Object) -join ',') `
    'Primary scope retained an OSD client subnet owned by another site.'
Assert-Equal 'DP1.multisubnet.test,DP2.multisubnet.test,DP3.multisubnet.test,NEWDP4.multisubnet.test,SEC1.multisubnet.test' `
    (@($scope[0].DistributionPointNames | Sort-Object) -join ',') `
    'Primary scope did not retain all legacy/new DPs and the child Secondary.'
$networkProjection = @($scope[0].DistributionPoints | Sort-Object Fqdn | ForEach-Object {
        "$($_.Fqdn)=$($_.Network)"
    }) -join ','
Assert-Equal 'DP1.multisubnet.test=10.10.1.0,DP2.multisubnet.test=10.10.2.0,DP3.multisubnet.test=10.10.3.0,NEWDP4.multisubnet.test=10.10.4.0,SEC1.multisubnet.test=10.10.2.0' `
    $networkProjection 'DP network metadata was not preserved across the revision boundary.'

$managedNames = @(Get-MemLabsManagedDistributionPointNames -VirtualMachines $config.virtualMachines `
        -DefaultDomainName 'multisubnet.test' -PrimarySiteCode 'PRI' `
        -AdditionalDistributionPointScopes $config.phase8ManagedDistributionPointScopes | Sort-Object)
Assert-Equal 'DP1.multisubnet.test,DP2.multisubnet.test,DP3.multisubnet.test,NEWDP4.multisubnet.test,SEC1.multisubnet.test' `
    ($managedNames -join ',') 'General content targeting dropped a legacy subnet DP.'

$liveDps = @(
    [pscustomobject]@{ NetworkOSPath = '\\PRI1.multisubnet.test' },
    [pscustomobject]@{ NetworkOSPath = '\\DP1.multisubnet.test' },
    [pscustomobject]@{ NetworkOSPath = '\\DP2.multisubnet.test' },
    [pscustomobject]@{ NetworkOSPath = '\\DP3.multisubnet.test' },
    [pscustomobject]@{ NetworkOSPath = '\\NEWDP4.multisubnet.test' },
    [pscustomobject]@{ NetworkOSPath = '\\SEC1.multisubnet.test' },
    [pscustomobject]@{ NetworkOSPath = '\\OTHERDP.multisubnet.test' },
    [pscustomobject]@{ NetworkOSPath = '\\FOREIGNDP.foreign.test' }
)
$plan = Get-MemLabsOsdTargetingPlan -DeployConfig $config -PrimarySiteCode 'PRI' -LiveDistributionPoints $liveDps
Assert-Equal '10.10.1.0,10.10.2.0,10.10.3.0' (@($plan.ClientSubnets | Sort-Object) -join ',') `
    'Perfloading did not consume projected legacy OSD client subnets.'
Assert-Equal 'DP1.multisubnet.test,DP2.multisubnet.test,DP3.multisubnet.test,PRI1.multisubnet.test' `
    (@($plan.DistributionPoints.Fqdn | Sort-Object) -join ',') `
    'OSD targeting did not select exactly the same-subnet Primary-site DPs.'
Assert-Equal '10.10.3.0' "$(($plan.DistributionPoints | Where-Object Fqdn -eq 'DP3.multisubnet.test').Subnet)" `
    'A hidden DP without a config network did not recover its authoritative inventory network.'
Assert-Equal 0 @($plan.UncoveredSubnets).Count 'Covered legacy OSD subnets were reported uncovered.'
$phase11 = Get-Phase11OsdTargetingExpectation -DeployConfig $config -SiteCode 'PRI' -Domain 'multisubnet.test'
Assert-Equal (@($plan.DistributionPoints.Fqdn | Sort-Object) -join ',') `
    (@($phase11.DistributionPoints.Name | Sort-Object) -join ',') `
    'Phase 11 expected coverage diverged from perfloading targeting.'
Assert-Equal (@($plan.UncoveredSubnets | Sort-Object) -join ',') `
    (@($phase11.UncoveredSubnets | Sort-Object) -join ',') `
    'Phase 11 uncovered-subnet validation diverged from perfloading.'

$config.virtualMachines += [pscustomobject]@{
    vmName = 'NEWOSD4'; role = 'OSDClient'; network = '10.10.4.0'
}
Add-Phase8DistributionPointMetadata -Config $config -ExistingVMs $existing -InventoryRefreshVerified $true
$planWithNewClient = Get-MemLabsOsdTargetingPlan -DeployConfig $config -PrimarySiteCode 'PRI' -LiveDistributionPoints $liveDps
Assert-Equal 'DP1.multisubnet.test,DP2.multisubnet.test,DP3.multisubnet.test,NEWDP4.multisubnet.test,PRI1.multisubnet.test' `
    (@($planWithNewClient.DistributionPoints.Fqdn | Sort-Object) -join ',') `
    'Develop OSD client did not add its same-subnet new DP without disturbing legacy targets.'
$phase11WithNewClient = Get-Phase11OsdTargetingExpectation -DeployConfig $config -SiteCode 'PRI' -Domain 'multisubnet.test'
Assert-Equal (@($planWithNewClient.DistributionPoints.Fqdn | Sort-Object) -join ',') `
    (@($phase11WithNewClient.DistributionPoints.Name | Sort-Object) -join ',') `
    'Phase 11 did not follow perfloading after adding a develop OSD client.'

$existingWithUnownedClient = @($existing) + [pscustomobject]@{
    vmName = 'OSD5'; role = 'OSDClient'; domain = 'multisubnet.test'; network = '10.10.5.0'
}
Add-Phase8DistributionPointMetadata -Config $config -ExistingVMs $existingWithUnownedClient -InventoryRefreshVerified $true
$uncoveredPlan = Get-MemLabsOsdTargetingPlan -DeployConfig $config -PrimarySiteCode 'PRI' -LiveDistributionPoints $liveDps
Assert-Equal '10.10.5.0' (@($uncoveredPlan.UncoveredSubnets) -join ',') `
    'OSD client subnet without a live DP did not fail closed as uncovered.'
$phase11Uncovered = Get-Phase11OsdTargetingExpectation -DeployConfig $config -SiteCode 'PRI' -Domain 'multisubnet.test'
Assert-Equal '10.10.5.0' (@($phase11Uncovered.UncoveredSubnets) -join ',') `
    'Phase 11 did not report the same uncovered OSD subnet as perfloading.'

Write-Host 'PASS -- multi-subnet perfloading preserves legacy DPs and targets OSD content only to same-subnet Primary-site DPs.'
