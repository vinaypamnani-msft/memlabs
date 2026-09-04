<#
.SYNOPSIS
    Focused dual-engine tests for the shared OSD PXE path resolver.

.DESCRIPTION
    Executes the pure resolver with injected inventory. No Hyper-V, DHCP, or
    ConfigMgr provider is required. Run under PowerShell 7 and Windows
    PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Inventory = @()

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "$Path has $(@($errors).Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Get-List2 { return @($script:Inventory) }
function Get-VMDeployedNetwork {
    param ([string] $VmName, [string] $Domain)
    return ($script:Inventory | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1).network
}

function New-TestConfig {
    param ([object[]] $VMs, [switch] $NoSite)

    $items = @()
    if (-not $NoSite) {
        $items += [pscustomobject]@{
            vmName = 'PS1'; role = 'Primary'; siteCode = 'PS1'; network = '192.168.1.0'; installDP = $true
        }
    }
    $items += @($VMs)
    return [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
        virtualMachines = @($items)
    }
}

function New-OsdClient {
    param ([string] $Name = 'OSD1', [string] $Network = '192.168.3.0')
    return [pscustomobject]@{ vmName = $Name; role = 'OSDClient'; network = $Network }
}

function New-Dp {
    param (
        [string] $Name,
        [string] $Network,
        [string] $SiteCode = 'PS1',
        [bool] $InstallDp = $true,
        [string] $AssignedIP
    )

    $dp = [pscustomobject]@{
        vmName = $Name; role = 'SiteSystem'; siteCode = $SiteCode
        network = $Network; installDP = $InstallDp; enablePullDP = $false
    }
    if ($AssignedIP) { $dp | Add-Member -MemberType NoteProperty -Name AssignedIP -Value $AssignedIP }
    return $dp
}

function New-Relay {
    param (
        [string] $Name = 'RELAY1',
        [string] $ClientNetwork = '192.168.3.0',
        [string] $Target = 'DP1'
    )

    return [pscustomobject]@{
        vmName = $Name; role = 'DHCPRelay'; operatingSystem = 'Ubuntu Server 24.04 LTS'
        osFamily = 'Linux'; network = '192.168.1.0'
        relayMappings = @([pscustomobject]@{
                clientNetwork = $ClientNetwork
                distributionPointVM = $Target
            })
    }
}

$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
. (Import-TestFunction -Path $configPath -Name 'Get-OsdEffectiveNetwork')
. (Import-TestFunction -Path $configPath -Name 'Get-OsdPxePaths')
. (Import-TestFunction -Path $configPath -Name 'Get-OsdBoundaryMappings')

Write-Host "engine : $($PSVersionTable.PSVersion)"

$config = New-TestConfig -VMs @()
Assert-Equal 0 @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines).Count 'no OSD clients returns no paths'

$config = New-TestConfig -NoSite -VMs @((New-OsdClient))
Assert-Equal 0 @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines).Count 'no ConfigMgr site returns no paths'

$directDp = New-Dp -Name 'DP1' -Network '192.168.3.0'
$config = New-TestConfig -VMs @((New-OsdClient), $directDp)
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'Direct:DP1' (($paths | ForEach-Object { "$($_.mode):$($_.distributionPointVM)" }) -join ',') 'one same-subnet DP resolves Direct'

$directDp2 = New-Dp -Name 'DP2' -Network '192.168.3.0'
$config = New-TestConfig -VMs @((New-OsdClient), $directDp, $directDp2)
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'DP1,DP2' (($paths.distributionPointVM | Sort-Object) -join ',') 'multiple direct DPs are all returned'

$conflictingDirectDp = New-Dp -Name 'DPSEC' -Network '192.168.3.0' -SiteCode 'SEC'
$config = New-TestConfig -VMs @((New-OsdClient), $directDp, $conflictingDirectDp)
Assert-Equal 'Invalid' @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)[0].mode 'direct DPs from conflicting sites are Invalid'

$remoteDp = New-Dp -Name 'DP1' -Network '192.168.1.0' -AssignedIP '192.168.1.25'
$relay = New-Relay
$config = New-TestConfig -VMs @((New-OsdClient), $remoteDp, $relay)
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'Relay:RELAY1:192.168.3.4:DP1:192.168.1.25' "$($paths[0].mode):$($paths[0].relayVM):$($paths[0].relayIPv4):$($paths[0].distributionPointVM):$($paths[0].distributionPointIPv4)" 'valid mapping resolves relay and target metadata'

$localDp = New-Dp -Name 'LOCALDP' -Network '192.168.3.0'
$config = New-TestConfig -VMs @((New-OsdClient), $remoteDp, $localDp, $relay)
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'Direct:LOCALDP' (($paths | ForEach-Object { "$($_.mode):$($_.distributionPointVM)" }) -join ',') 'direct DP overrides one stored relay mapping'

$config = New-TestConfig -VMs @((New-OsdClient), $remoteDp)
$config | Add-Member -MemberType NoteProperty -Name relayMappings -Value @([pscustomobject]@{
        clientNetwork = '192.168.3.0'; distributionPointVM = 'DP1'; relayVM = 'GONE-RELAY'
    })
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'Invalid' $paths[0].mode 'detached mapping with missing relay VM is Invalid'
Assert-Equal $true ($paths[0].reason -like "*GONE-RELAY*missing*") 'missing relay diagnostic names the VM'

$relay = New-Relay -Target 'GONE-DP'
$config = New-TestConfig -VMs @((New-OsdClient), $relay)
Assert-Equal 'Invalid' @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)[0].mode 'missing target DP is Invalid'

$notDp = New-Dp -Name 'DP1' -Network '192.168.1.0' -InstallDp:$false
$relay = New-Relay
$config = New-TestConfig -VMs @((New-OsdClient), $notDp, $relay)
Assert-Equal 'Invalid' @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)[0].mode 'target without DP capability is Invalid'

$ownerlessDp = New-Dp -Name 'DP1' -Network '192.168.1.0' -SiteCode ''
$config = New-TestConfig -VMs @((New-OsdClient), $ownerlessDp, $relay)
Assert-Equal 'Invalid' @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)[0].mode 'relay target without site ownership is Invalid'

$addresslessDp = New-Dp -Name 'DP1' -Network '192.168.1.0'
$config = New-TestConfig -VMs @((New-OsdClient), $addresslessDp, $relay)
Assert-Equal 'Invalid' @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)[0].mode 'relay target without stable IPv4 metadata is Invalid'

$invalidAddressDp = New-Dp -Name 'DP1' -Network '192.168.1.0' -AssignedIP '999.999.999.999'
$config = New-TestConfig -VMs @((New-OsdClient), $invalidAddressDp, $relay)
Assert-Equal 'Invalid' @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)[0].mode 'out-of-range dotted target address is not valid IPv4 evidence'

$relay2 = New-Relay -Name 'RELAY2'
$config = New-TestConfig -VMs @((New-OsdClient), $remoteDp, (New-Relay), $relay2)
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'Invalid' $paths[0].mode 'duplicate mappings for one client subnet are Invalid'

$config = New-TestConfig -VMs @((New-OsdClient -Name 'OSD1'), (New-OsdClient -Name 'OSD2'), $remoteDp, (New-Relay))
Assert-Equal 1 @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines).Count 'duplicate OSD clients are deduplicated by subnet'

$hiddenDp = New-Dp -Name 'HIDDENDP' -Network '192.168.1.0' -AssignedIP '192.168.1.30'
$hiddenDp | Add-Member -MemberType NoteProperty -Name hidden -Value $true
$hiddenDp.PSObject.Properties.Remove('network')
$hiddenDp | Add-Member -MemberType NoteProperty -Name thisParams -Value ([pscustomobject]@{ vmNetwork = '192.168.1.0' })
$hiddenRelay = New-Relay -Name 'HIDDENRELAY' -Target 'HIDDENDP'
$hiddenRelay | Add-Member -MemberType NoteProperty -Name hidden -Value $true
$config = New-TestConfig -VMs @((New-OsdClient), $hiddenDp, $hiddenRelay)
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'Relay:HIDDENRELAY:HIDDENDP' "$($paths[0].mode):$($paths[0].relayVM):$($paths[0].distributionPointVM)" 'hidden existing relay and DP metadata resolve'

$remoteDp = New-Dp -Name 'DP1' -Network '192.168.1.0' -AssignedIP '192.168.1.25'
$remoteDp | Add-Member -MemberType NoteProperty -Name LastKnownIP -Value '192.168.1.25'
$config = New-TestConfig -VMs @((New-OsdClient), $remoteDp, (New-Relay))
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'Relay:192.168.1.25' "$($paths[0].mode):$($paths[0].distributionPointIPv4)" 'agreeing target IP sources collapse to one value'
$remoteDp.LastKnownIP = '192.168.1.26'
$paths = @(Get-OsdPxePaths -Config $config -Inventory $config.virtualMachines)
Assert-Equal 'Invalid' $paths[0].mode 'disagreeing target IP sources are Invalid'

$directConfig = New-TestConfig -VMs @((New-OsdClient), (New-Dp -Name 'DP3' -Network '192.168.3.0' -SiteCode 'SEC'))
$script:Inventory = @($directConfig.virtualMachines)
$boundary = @(Get-OsdBoundaryMappings -Config $directConfig)
Assert-Equal 'SEC:192.168.3.0' (($boundary | ForEach-Object { "$($_.SiteCode):$($_.Subnet)" }) -join ',') 'Direct path creates boundary mapping for target site'

$relayConfig = New-TestConfig -VMs @((New-OsdClient), (New-Dp -Name 'DP1' -Network '192.168.1.0' -SiteCode 'SEC' -AssignedIP '192.168.1.25'), (New-Relay))
$script:Inventory = @($relayConfig.virtualMachines)
$boundary = @(Get-OsdBoundaryMappings -Config $relayConfig)
Assert-Equal 'SEC:192.168.3.0' (($boundary | ForEach-Object { "$($_.SiteCode):$($_.Subnet)" }) -join ',') 'Relay path maps client subnet to selected target DP site'

$missingConfig = New-TestConfig -VMs @((New-OsdClient))
$script:Inventory = @($missingConfig.virtualMachines)
Assert-Equal 0 @(Get-OsdBoundaryMappings -Config $missingConfig).Count 'Missing path does not fabricate a boundary mapping'

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All OSD PXE path checks passed.'
