<#
.SYNOPSIS
    Verifies partial add-to-existing configs retain hierarchy-wide SUP product demand.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'

function Import-TestFunction {
    param([string] $Path, [string] $Name)
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
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Assert-ThrowsLike {
    param([scriptblock] $Action, [string] $Pattern, [string] $Message)
    $actual = ''
    try { & $Action }
    catch { $actual = $_.Exception.Message }
    if ($actual -notlike $Pattern) {
        throw "$Message`nExpected: $Pattern`nActual:   $actual"
    }
}
function Write-Log { param($Message, [switch]$LogOnly, [switch]$Warning) }
function Get-VMDeployedNetwork { param($VmName, $Domain) return $null }
$script:RawNotes = @{}
function Get-VMNote {
    param([string] $VMName)
    return $script:RawNotes[$VMName]
}

. (Import-TestFunction -Path $configPath -Name 'Test-PushClientRequested')
. (Import-TestFunction -Path $configPath -Name 'Get-EligiblePushSites')
. (Import-TestFunction -Path $configPath -Name 'Resolve-PushClientSite')
. (Import-TestFunction -Path $configPath -Name 'Add-Phase8SoftwareUpdateProductMetadata')

$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'upgrade.test'; network = '10.20.2.0' }
    cmOptions = [pscustomobject]@{ pushClientToDomainMembers = $true }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'CAS1'; role = 'CAS'; siteCode = 'CAS'; domain = 'upgrade.test'
        },
        [pscustomobject]@{
            vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'
            domain = 'upgrade.test'; network = '10.20.1.0'
        },
        [pscustomobject]@{
            vmName = 'NEW-SUP'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'upgrade.test'
            installSUP = $true; pushClient = $false
        }
    )
}
$inventory = @(
    [pscustomobject]@{
        vmName = 'CAS1'; role = 'CAS'; siteCode = 'CAS'; domain = 'upgrade.test'; network = '10.20.1.0'
    },
    [pscustomobject]@{
        vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'
        domain = 'upgrade.test'; network = '10.20.1.0'
    },
    [pscustomobject]@{
        vmName = 'W10'; role = 'DomainMember'; domain = 'upgrade.test'
        operatingSystem = 'Windows 10 Latest (64-bit)'; network = '10.20.1.0'; pushClient = $false
    },
    [pscustomobject]@{
        vmName = 'W11'; role = 'DomainMember'; domain = 'upgrade.test'
        operatingSystem = 'Windows 11 Latest'; network = '10.20.1.0'; pushClient = $false
    },
    [pscustomobject]@{
        vmName = 'SQL1'; role = 'DomainMember'; domain = 'upgrade.test'
        operatingSystem = 'Server 2022'; sqlVersion = 'SQL Server 2019'; network = '10.20.1.0'; pushClient = $false
    },
    [pscustomobject]@{
        vmName = 'OPT-OUT'; role = 'DomainMember'; domain = 'upgrade.test'
        operatingSystem = 'Windows 11 Latest'; network = '10.20.1.0'; pushClient = $false
    },
    [pscustomobject]@{
        vmName = 'FOREIGN'; role = 'DomainMember'; domain = 'foreign.test'
        operatingSystem = 'Windows 11 Latest'; network = '10.20.1.0'
    }
)
$script:RawNotes['W10'] = [pscustomobject]@{ vmName = 'W10'; role = 'DomainMember' }
$script:RawNotes['W11'] = [pscustomobject]@{ vmName = 'W11'; role = 'DomainMember' }
$script:RawNotes['SQL1'] = [pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember' }
$script:RawNotes['OPT-OUT'] = [pscustomobject]@{
    vmName = 'OPT-OUT'; role = 'DomainMember'; pushClient = $false
}

Add-Phase8SoftwareUpdateProductMetadata -Config $config -ExistingVMs $inventory
$projected = @($config.phase8SoftwareUpdateProductInventory)
Assert-Equal 'SQL1,W10,W11' (@($projected.VmName | Sort-Object) -join ',') `
    'Existing push-client inventory was not projected exactly once.'
Assert-Equal 'CAS' (@($projected.TopSiteCode | Select-Object -Unique) -join ',') `
    'Projected clients were not assigned to the owning CAS hierarchy.'
Assert-Equal 'PRI' (@($projected.TargetSiteCode | Select-Object -Unique) -join ',') `
    'Projected clients were not assigned to their Primary site.'
Assert-Equal 'upgrade.test' (@($projected.TargetSiteDomain | Select-Object -Unique) -join ',') `
    'Projected clients lost the target site domain.'
Assert-Equal 'upgrade.test' (@($projected.TopSiteDomain | Select-Object -Unique) -join ',') `
    'Projected clients lost the top-level site domain.'
Assert-True (@($projected | Where-Object { $_.OperatingSystem -like 'Windows 10*' }).Count -eq 1) `
    'Windows 10 product demand was lost.'
Assert-True (@($projected | Where-Object { $_.SqlVersion -eq 'SQL Server 2019' }).Count -eq 1) `
    'SQL Server product demand was lost.'

$perfloading = Get-Content -LiteralPath $perfloadingPath -Raw
Assert-True ($perfloading -match 'phase8SoftwareUpdateProductInventory') `
    'perfloading does not consume projected existing-client product demand.'
Assert-True ($perfloading -match '(?s)\$clientByName.+?\$deployConfig\.virtualMachines.+?\$clientVMs') `
    'perfloading does not de-duplicate projected and configured clients.'
Assert-True ($perfloading -match '(?s)\$products\s*=\s*@\(\$clientVMs\.operatingSystem.+?\+\s*@\(\$clientVMs\.sqlversion') `
    'perfloading can concatenate scalar OS and SQL product names instead of building two arrays.'
Assert-True ($perfloading -match '(?s)if \(\$ThisVM\.hidden\).+?elseif \(\$isTopLevel\).+?Invoke-FullSync.+?Hidden downstream Primary') `
    'A hidden downstream Primary can still force a WSUS sync before its upstream subscription replicates.'

$externalConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'client.test'; network = '10.30.2.0' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'CLIENT-DC1'; role = 'DC'; ForestTrust = 'site.test'
            externalDomainJoinSiteCode = 'PRI'
        },
        [pscustomobject]@{
            vmName = 'SITE-PRI1'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'
            domain = 'site.test'; network = '10.30.1.0'
        },
        [pscustomobject]@{
            vmName = 'CLIENT-W11'; role = 'DomainMember'; domain = 'client.test'
            operatingSystem = 'Windows 11 Latest'; network = '10.30.2.0'; pushClient = 'PRI'
        }
    )
}
$externalInventory = @(
    [pscustomobject]@{
        vmName = 'SITE-CAS1'; role = 'CAS'; siteCode = 'CAS'; domain = 'site.test'; network = '10.30.1.0'
    },
    [pscustomobject]@{
        vmName = 'COLLISION-PRI1'; role = 'Primary'; siteCode = 'PRI'; domain = 'collision.test'; network = '10.40.1.0'
    }
)
$script:RawNotes.Clear()
Add-Phase8SoftwareUpdateProductMetadata -Config $externalConfig -ExistingVMs $externalInventory
$externalProjection = @($externalConfig.phase8SoftwareUpdateProductInventory)
Assert-Equal 1 $externalProjection.Count 'External-forest client demand was not projected exactly once.'
Assert-Equal 'PRI' $externalProjection[0].TargetSiteCode 'External-forest client lost its target Primary.'
Assert-Equal 'site.test' $externalProjection[0].TargetSiteDomain `
    'External-forest client resolved a same-code site in the wrong domain.'
Assert-Equal 'CAS' $externalProjection[0].TopSiteCode `
    'External-forest client did not walk to the remote hierarchy CAS.'
Assert-Equal 'site.test' $externalProjection[0].TopSiteDomain `
    'External-forest hierarchy ownership lost its domain.'
Assert-True ($perfloading -match '(?s)\$hierarchyDomain.+?TopSiteDomain.+?\$hierarchyDomain') `
    'Perfloading does not scope projected product demand by hierarchy domain.'

$missingParentConfig = $externalConfig | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$missingParentConfig.PSObject.Properties.Remove('phase8SoftwareUpdateProductInventory')
Assert-ThrowsLike {
    Add-Phase8SoftwareUpdateProductMetadata -Config $missingParentConfig -ExistingVMs @()
} "*expected one owner for site 'CAS' in 'site.test'*found 0*" `
    'An external hierarchy with a missing parent site did not fail closed.'

$ambiguousExternalConfig = $externalConfig | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$ambiguousExternalConfig.PSObject.Properties.Remove('phase8SoftwareUpdateProductInventory')
$duplicateSiteOwner = [pscustomobject]@{
    vmName = 'SITE-PRI2'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'
    domain = 'site.test'; network = '10.30.3.0'
}
Assert-ThrowsLike {
    Add-Phase8SoftwareUpdateProductMetadata -Config $ambiguousExternalConfig `
        -ExistingVMs @($externalInventory + $duplicateSiteOwner)
} "*expected one owner for site 'PRI' in 'site.test'*found 2*" `
    'Duplicate external site ownership did not fail closed.'

Write-Host 'PASS -- partial configs retain hierarchy-wide existing-client SUP product demand.'
