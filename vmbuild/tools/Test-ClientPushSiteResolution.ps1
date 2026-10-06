<#
.SYNOPSIS
    Guards client-push site resolution for add-to-existing deployments.
#>
[CmdletBinding()]
param([string] $RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$genConfigPath = Join-Path $RootPath 'common\Common.GenConfig.ps1'
$guestFunctionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
$script:Failures = 0

function Assert-ClientPush {
    param([bool] $Condition, [string] $Description)

    if ($Condition) { Write-Host "PASS  $Description" }
    else { Write-Host "FAIL  $Description"; $script:Failures++ }
}

function Import-ClientPushFunction {
    param(
        [string] $Name,
        [string] $Path = $configPath
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-ClientPushFunction -Name 'Get-EligiblePushSites')
. (Import-ClientPushFunction -Name 'Test-PushClientRequested')
. (Import-ClientPushFunction -Name 'Resolve-PushClientSite')
. (Import-ClientPushFunction -Name 'Update-VMFromHyperV')

function Get-VMDeployedNetwork { throw 'inventory snapshot should prevent a deployed-network lookup' }
function Get-ExistingSiteServer { throw 'inventory snapshot should prevent a second site lookup' }
function Write-Log { param($Message, [switch]$LogOnly, [switch]$Warning) }

$config = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{
        domainName = 'cstest1.com'
        network    = '192.168.11.0'
    }
    virtualMachines = @(
        [pscustomobject]@{
            vmName  = 'CT1-PS2SITE'
            role    = 'Primary'
            siteCode = 'PS2'
            network = '192.168.11.0'
        }
        [pscustomobject]@{
            vmName  = 'CT1-PS1SITE'
            role    = 'Primary'
            siteCode = 'PS1'
            hidden  = $true
        }
    )
}
$inventory = @(
    [pscustomobject]@{
        vmName = 'CT1-PS2SITE'; role = 'Primary'; siteCode = 'PS2'
        network = '192.168.99.0'; pushClient = $false
    }
    [pscustomobject]@{
        vmName = 'CT1-PS1SITE'; role = 'Primary'; siteCode = 'PS1'
        network = '192.168.10.0'; pushClient = $true
    }
    [pscustomobject]@{
        vmName = 'CT1-W10Client1'; role = 'DomainMember'
        network = '192.168.10.0'; pushClient = $true
    }
    [pscustomobject]@{
        vmName = 'CT1-W11Client2'; role = 'DomainMember'
        network = '192.168.10.0'; pushClient = $true
    }
    [pscustomobject]@{
        vmName = 'CT1-DPMP1'; role = 'SiteSystem'
        network = '192.168.11.0'; pushClient = $true
    }
    [pscustomobject]@{
        vmName = 'CT1-RemoteClient'; role = 'DomainMember'
        network = '172.16.1.0'; pushClient = 'PS1'
    }
    [pscustomobject]@{
        vmName = 'CT1-LegacyCAS'; role = 'CAS'; siteCode = 'LC1'
        network = '192.168.20.0'
    }
)

$eligible = @(Get-EligiblePushSites -Config $config -Domain 'cstest1.com' -Inventory $inventory)
Assert-ClientPush ($eligible.Count -eq 2) 'eligible sites merge new config and deployed inventory'
Assert-ClientPush (@($eligible | Where-Object { $_.SiteCode -eq 'PS1' -and $_.Network -eq '192.168.10.0' }).Count -eq 1) `
    'existing PS1 Primary retains ownership of its deployed subnet'
Assert-ClientPush (@($eligible | Where-Object { $_.SiteCode -eq 'PS2' -and $_.Network -eq '192.168.11.0' }).Count -eq 1) `
    'new PS2 config entry wins over a stale inventory duplicate'

$w10 = $inventory | Where-Object vmName -eq 'CT1-W10Client1'
$w11 = $inventory | Where-Object vmName -eq 'CT1-W11Client2'
$oldDp = $inventory | Where-Object vmName -eq 'CT1-DPMP1'
$remoteClient = $inventory | Where-Object vmName -eq 'CT1-RemoteClient'
$legacySiteServer = $inventory | Where-Object vmName -eq 'CT1-LegacyCAS'
Assert-ClientPush ((Resolve-PushClientSite -VM $w10 -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'main-era Windows 10 client remains assigned to PS1'
Assert-ClientPush ((Resolve-PushClientSite -VM $w11 -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'main-era Windows 11 client remains assigned to PS1'
Assert-ClientPush ((Resolve-PushClientSite -VM $oldDp -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS2') `
    'existing site system on the new PS2 subnet resolves to PS2'
Assert-ClientPush ((Resolve-PushClientSite -VM $remoteClient -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'explicit PS1 client on a standalone subnet retains PS1 for boundary generation'
Assert-ClientPush (-not (Test-PushClientRequested -VM $legacySiteServer)) `
    'legacy site server with missing pushClient is opted out'
Assert-ClientPush (-not (Resolve-PushClientSite -VM $legacySiteServer -Config $config -Domain 'cstest1.com' -EligibleSites $eligible)) `
    'missing pushClient never auto-resolves to a site'
Assert-ClientPush (Test-PushClientRequested -VM $w10) 'boolean true explicitly requests client push'
Assert-ClientPush (Test-PushClientRequested -VM $remoteClient) 'site-code string explicitly requests client push'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = $false }))) `
    'boolean false opts out'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = $null }))) `
    'null pushClient opts out'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = '' }))) `
    'empty pushClient opts out'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = '   ' }))) `
    'whitespace pushClient opts out'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = 1 }))) `
    'non-Boolean non-string pushClient opts out'

$global:vm_List = @()
$legacyVm = [pscustomobject]@{ State = 'Running' }
$legacyProjection = [pscustomobject]@{ Memory = 4GB }
$legacyNote = [pscustomobject]@{ vmName = 'CT1-OLD-CS1'; role = 'CAS' }
Update-VMFromHyperV -vm $legacyVm -vmObject $legacyProjection -vmNoteObject $legacyNote
Assert-ClientPush (($legacyProjection.PSObject.Properties.Name -contains 'pushClient') -and
    $legacyProjection.pushClient -eq $false) 'exact-main site-system note materializes missing pushClient as false'

$explicitProjection = [pscustomobject]@{ Memory = 4GB }
$explicitNote = [pscustomobject]@{ vmName = 'CT1-OLD-CLIENT'; role = 'DomainMember'; pushClient = 'PS1' }
Update-VMFromHyperV -vm $legacyVm -vmObject $explicitProjection -vmNoteObject $explicitNote
Assert-ClientPush ($explicitProjection.pushClient -eq 'PS1') 'exact-main note preserves explicit target site code'

$numericProjection = [pscustomobject]@{ Memory = 4GB; network = '10.12.3.0' }
$numericNote = [pscustomobject]@{
    vmName = 'CT1-NUMERIC-PRIMARY'; role = 'Primary'; siteCode = '123'; pushClient = '123'
}
Update-VMFromHyperV -vm $legacyVm -vmObject $numericProjection -vmNoteObject $numericNote
Assert-ClientPush (($numericProjection.pushClient -is [string]) -and $numericProjection.pushClient -eq '123') `
    'exact-main note preserves numeric target site code as a string'
Assert-ClientPush (($numericProjection.siteCode -is [string]) -and $numericProjection.siteCode -eq '123') `
    'exact-main note preserves numeric siteCode as a string'

$leadingZeroProjection = [pscustomobject]@{ Memory = 4GB; network = '10.0.1.0' }
$leadingZeroNote = [pscustomobject]@{
    vmName = 'CT1-ZERO-SECONDARY'; role = 'Secondary'; siteCode = '001'
    parentSiteCode = '123'; pushClient = '001'
}
Update-VMFromHyperV -vm $legacyVm -vmObject $leadingZeroProjection -vmNoteObject $leadingZeroNote
Assert-ClientPush (($leadingZeroProjection.pushClient -is [string]) -and $leadingZeroProjection.pushClient -eq '001') `
    'exact-main note preserves leading-zero target site code'
Assert-ClientPush (($leadingZeroProjection.siteCode -is [string]) -and $leadingZeroProjection.siteCode -eq '001') `
    'exact-main note preserves leading-zero siteCode'
Assert-ClientPush (($leadingZeroProjection.parentSiteCode -is [string]) -and $leadingZeroProjection.parentSiteCode -eq '123') `
    'exact-main note preserves numeric parentSiteCode as a string'

$numericConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'numeric.test'; network = '10.12.3.0' }
    virtualMachines = @()
}
$numericEligible = @(Get-EligiblePushSites -Config $numericConfig -Domain 'numeric.test' -Inventory @(
        $numericProjection, $leadingZeroProjection
    ))
Assert-ClientPush (@($numericEligible | Where-Object SiteCode -eq '123').Count -eq 1 `
    -and @($numericEligible | Where-Object SiteCode -eq '001').Count -eq 1) `
    'hydrated numeric site inventory remains eligible without type errors'
Assert-ClientPush ((Resolve-PushClientSite -VM $numericProjection -Config $config -Domain 'cstest1.com' -EligibleSites $numericEligible) -eq '123') `
    'numeric target site code remains explicitly selected'
Assert-ClientPush ((Resolve-PushClientSite -VM $leadingZeroProjection -Config $numericConfig -Domain 'numeric.test' -EligibleSites $numericEligible) -eq '001') `
    'leading-zero target site code remains explicitly selected'

$hostCases = @(
    [pscustomobject]@{ pushClient = $true },
    [pscustomobject]@{ pushClient = $false },
    [pscustomobject]@{ pushClient = 'PS1' },
    [pscustomobject]@{ pushClient = '' },
    [pscustomobject]@{}
)
$hostResults = @($hostCases | ForEach-Object { Test-PushClientRequested -VM $_ })
. (Import-ClientPushFunction -Name 'Test-PushClientRequested' -Path $guestFunctionsPath)
$guestResults = @($hostCases | ForEach-Object { Test-PushClientRequested -VM $_ })
Assert-ClientPush (($hostResults -join ',') -eq ($guestResults -join ',')) `
    'guest and host pushClient predicates have identical behavior'

$genConfigText = [IO.File]::ReadAllText($genConfigPath)
Assert-ClientPush ($genConfigText -match '\$pushInventory\s*=\s*@\(get-list2 -DeployConfig \$deployConfig\)') `
    'generator resolves one shared client-push inventory snapshot'
Assert-ClientPush ($genConfigText -match 'Get-EligiblePushSites -Config \$deployConfig -Domain \$DomainName -Inventory \$pushInventory') `
    'eligible sites use the same inventory snapshot as client candidates'
Assert-ClientPush ($genConfigText -match '\$ClientNames\s*=\s*\$pushInventory') `
    'client candidates use the shared inventory snapshot'
Assert-ClientPush ($genConfigText -match '\$_.role -in \$pushableRoles -and \(Test-PushClientRequested -VM \$_\)') `
    'client candidates require explicit pushClient opt-in'
Assert-ClientPush ($genConfigText -match '\$siteInventory\s*=\s*if \(\$thisVM\.Role -eq "Primary".+\$pushInventory') `
    'Primary boundary generation reuses the client-push inventory snapshot'
Assert-ClientPush ($genConfigText -match 'Get-EligiblePushSites -Config \$deployConfig -Domain \$DomainName -Inventory \$siteInventory') `
    'boundary site resolution uses the shared inventory snapshot'
Assert-ClientPush ($genConfigText -match 'foreach \(\$vm in \$siteInventory \| Where-Object \{ \$_.role -in \$bgPushableRoles') `
    'boundary client candidates use the shared inventory snapshot'
Assert-ClientPush ($genConfigText -match '\$_.role -in \$bgPushableRoles -and \(Test-PushClientRequested -VM \$_\)') `
    'boundary candidates require explicit pushClient opt-in'

foreach ($consumerPath in @(
        'common\Common.Config.ps1',
        'common\Common.GenConfig.ps1',
        'common\Common.Phases.ps1',
        'common\Common.Validation.Functional.ps1',
        'DSC\phases\InstallBoundaryGroups.ps1',
        'DSC\phases\InstallMultiDomainPKI.ps1',
        'DSC\phases\perfloading.ps1'
    )) {
    $consumerText = [IO.File]::ReadAllText((Join-Path $RootPath $consumerPath))
    Assert-ClientPush ($consumerText -notmatch 'pushClient\s*-ne\s*\$false') `
        "$consumerPath has no fail-open pushClient comparison"
}

if ($script:Failures -gt 0) {
    throw "$script:Failures client-push site-resolution assertion(s) failed."
}

Write-Host 'PASS: client-push site resolution preserves existing subnet ownership.'
