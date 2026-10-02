<#
.SYNOPSIS
    Guards client-push site resolution for add-to-existing deployments.
#>
[CmdletBinding()]
param([string] $RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$genConfigPath = Join-Path $RootPath 'common\Common.GenConfig.ps1'
$script:Failures = 0

function Assert-ClientPush {
    param([bool] $Condition, [string] $Description)

    if ($Condition) { Write-Host "PASS  $Description" }
    else { Write-Host "FAIL  $Description"; $script:Failures++ }
}

function Import-ClientPushFunction {
    param([string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($configPath, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "$configPath has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-ClientPushFunction -Name 'Get-EligiblePushSites')
. (Import-ClientPushFunction -Name 'Resolve-PushClientSite')

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
Assert-ClientPush ((Resolve-PushClientSite -VM $w10 -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'main-era Windows 10 client remains assigned to PS1'
Assert-ClientPush ((Resolve-PushClientSite -VM $w11 -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'main-era Windows 11 client remains assigned to PS1'
Assert-ClientPush ((Resolve-PushClientSite -VM $oldDp -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS2') `
    'existing site system on the new PS2 subnet resolves to PS2'
Assert-ClientPush ((Resolve-PushClientSite -VM $remoteClient -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'explicit PS1 client on a standalone subnet retains PS1 for boundary generation'

$genConfigText = [IO.File]::ReadAllText($genConfigPath)
Assert-ClientPush ($genConfigText -match '\$pushInventory\s*=\s*@\(get-list2 -DeployConfig \$deployConfig\)') `
    'generator resolves one shared client-push inventory snapshot'
Assert-ClientPush ($genConfigText -match 'Get-EligiblePushSites -Config \$deployConfig -Domain \$DomainName -Inventory \$pushInventory') `
    'eligible sites use the same inventory snapshot as client candidates'
Assert-ClientPush ($genConfigText -match '\$ClientNames\s*=\s*\$pushInventory') `
    'client candidates use the shared inventory snapshot'
Assert-ClientPush ($genConfigText -match '\$siteInventory\s*=\s*if \(\$thisVM\.Role -eq "Primary".+\$pushInventory') `
    'Primary boundary generation reuses the client-push inventory snapshot'
Assert-ClientPush ($genConfigText -match 'Get-EligiblePushSites -Config \$deployConfig -Domain \$DomainName -Inventory \$siteInventory') `
    'boundary site resolution uses the shared inventory snapshot'
Assert-ClientPush ($genConfigText -match 'foreach \(\$vm in \$siteInventory \| Where-Object \{ \$_.role -in \$bgPushableRoles') `
    'boundary client candidates use the shared inventory snapshot'

if ($script:Failures -gt 0) {
    throw "$script:Failures client-push site-resolution assertion(s) failed."
}

Write-Host 'PASS: client-push site resolution preserves existing subnet ownership.'
