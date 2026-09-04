<#
.SYNOPSIS
    Verifies SiteSystem and OSDClient subnet selection rules.

.DESCRIPTION
    Proves that interactive SiteSystem edits open the subnet picker while new
    SiteSystems still inherit their site server's subnet by default. Also proves
    that an OSDClient can select any subnet and resolve a missing DP by promoting
    an eligible VM or adding a new DP-only SiteSystem.

    Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

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

$addVmPath = Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1'
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$genConfigPath = Join-Path $RootPath 'common\Common.GenConfig.ps1'
$existingPath = Join-Path $RootPath 'common\Common.GenConfig.Existing.ps1'
. (Import-TestFunction -Path $configPath -Name 'Get-OsdEffectiveNetwork')
. (Import-TestFunction -Path $configPath -Name 'Get-OsdFixedRoleIPv4')
. (Import-TestFunction -Path $configPath -Name 'Get-OsdPxePaths')
. (Import-TestFunction -Path $configPath -Name 'Get-OsdBoundaryMappings')
. (Import-TestFunction -Path $configPath -Name 'Add-ModifiedExistingVMToDeployConfig')
. (Import-TestFunction -Path $genConfigPath -Name 'Get-ValidSubnets')
foreach ($functionName in @(
        'Test-OsdNetworkHasDistributionPoint',
        'Get-OsdPxePathsForNetwork',
        'Get-OsdRelayDistributionPointCandidates',
        'Add-DhcpRelayForOsdNetwork',
        'Resolve-OsdPxePathForNetwork',
        'Get-OsdDistributionPointPromotionCandidates',
        'Select-OsdDistributionPointSiteCode',
        'Set-OsdDistributionPointPromotionProperty',
        'Enable-OsdDistributionPointOnCandidate',
        'Add-DistributionPointForOsdNetwork',
        'Select-OsdClientNetwork',
        'Get-NetworkForVM')) {
    . (Import-TestFunction -Path $addVmPath -Name $functionName)
}
. (Import-TestFunction -Path $existingPath -Name 'Get-ValidNetworksForVM')

$script:SelectedNetwork = '172.16.3.0'
$script:SelectorCalls = 0
$script:SiteServerNetwork = '192.168.2.0'
$script:MenuCalls = 0
$script:MenuResponses = New-Object System.Collections.Queue
$script:LastAdditionalOptions = $null
$script:EligibleSites = @([pscustomobject]@{ SiteCode = 'PS1'; Network = '192.168.2.0'; Role = 'Primary' })
$script:NewDpCalls = 0
$script:DistributionPointOnly = $false
$global:existingMachines = @()

function Select-Subnet {
    param ([object] $ConfigToCheck, [bool] $CurrentNetworkIsValid, [object] $CurrentVM)

    $script:SelectorCalls++
    return $script:SelectedNetwork
}

function Get-SiteServerForSiteCode {
    return [pscustomobject]@{ Network = $script:SiteServerNetwork }
}

function Get-List2 {
    param ([object] $DeployConfig)

    return @($DeployConfig.virtualMachines) + @($global:existingMachines)
}

function Get-EligiblePushSites { return @($script:EligibleSites) }
function Get-PushClientSubnetLock { return $null }
function Get-VMDeployedNetwork {
    param ([string] $VmName, [string] $Domain)

    return ($global:existingMachines | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1).network
}
function Get-List { return @($global:existingMachines) }
function Start-VM2 { return $true }
function Get-Menu2 {
    param ([string] $MenuName, [string] $Prompt, [object[]] $OptionArray, [object] $AdditionalOptions, [bool] $Test, [switch] $Split, [string] $CurrentValue)
    $script:MenuCalls++
    $script:LastAdditionalOptions = $AdditionalOptions
    if ($script:MenuResponses.Count -eq 0) { return $null }
    return $script:MenuResponses.Dequeue()
}
function Add-NewVMForRole {
    param (
        [string] $Role,
        [string] $Domain,
        [object] $ConfigToModify,
        [string] $SiteCode,
        [string] $Network,
        [bool] $ReturnMachineName,
        [bool] $DistributionPointOnly
    )

    $script:NewDpCalls++
    $script:DistributionPointOnly = $DistributionPointOnly
    if ($Role -eq 'DHCPRelay') {
        $newRelay = [pscustomobject]@{
            vmName = "AUTORELAY$($script:NewDpCalls)"
            role = 'DHCPRelay'
            operatingSystem = 'Ubuntu Server 24.04 LTS'
            osFamily = 'Linux'
            network = $Network
            relayMappings = @()
        }
        $ConfigToModify.virtualMachines += $newRelay
        return $newRelay.vmName
    }
    $newDP = [pscustomobject]@{
        vmName = "AUTODP$($script:NewDpCalls)"
        role = $Role
        operatingSystem = 'Server 2025'
        siteCode = $SiteCode
        network = $Network
        installDP = $true
        installMP = -not $DistributionPointOnly
    }
    $ConfigToModify.virtualMachines += $newDP
    return $newDP.vmName
}
function Set-SiteSystemPropertiesForOperatingSystem { param ([object] $VirtualMachine) }
function Get-NetworkList { return @() }
function Get-NetIPAddress { param ([string] $AddressFamily); return @() }
function Write-Log { param ([string] $Message, [switch] $Success, [switch] $Verbose, [switch] $LogOnly) }
function Write-RedX { param ([string] $Message) }

Write-Host "engine : $($PSVersionTable.PSVersion)"

$siteSystem = [pscustomobject]@{
    vmName = 'PS1DPMP2'
    role = 'SiteSystem'
    siteCode = 'PS1'
    installDP = $true
}
$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{
        DomainName = 'example.test'
        Network = '192.168.2.0'
    }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'PS1'; installDP = $true }
        $siteSystem
        [pscustomobject]@{ vmName = 'W11CLIENT3'; role = 'DomainMember'; operatingSystem = 'Windows 11 25H2'; network = '10.0.1.0' }
    )
}

$editedNetwork = Get-NetworkForVM -vm $siteSystem -ConfigToModify $config
Assert-Equal '172.16.3.0' $editedNetwork 'interactive SiteSystem network edit returns the picker selection'
Assert-Equal 1 $script:SelectorCalls 'interactive SiteSystem network edit opens the subnet picker once'

$script:SelectorCalls = 0
$sameSubnet = Get-NetworkForVM -vm $siteSystem -ConfigToModify $config -ReturnIfNotNeeded:$true
Assert-Equal '' $sameSubnet 'new SiteSystem needs no override when its site server uses the default subnet'
Assert-Equal 0 $script:SelectorCalls 'new SiteSystem inheritance does not open an interactive picker'

$script:SiteServerNetwork = '172.16.3.0'
$inheritedNetwork = Get-NetworkForVM -vm $siteSystem -ConfigToModify $config -ReturnIfNotNeeded:$true
Assert-Equal '172.16.3.0' $inheritedNetwork 'new SiteSystem inherits a non-default site-server subnet'
Assert-Equal 0 $script:SelectorCalls 'non-default inheritance remains non-interactive'

$siteSystem | Add-Member -MemberType NoteProperty -Name network -Value '172.16.3.0'
$osdClient = [pscustomobject]@{ vmName = 'OSD2'; role = 'OSDClient' }
$osdNetworks = @(Get-ValidNetworksForVM -CurrentVM $osdClient -ConfigToCheck $config)
Assert-Equal '10.0.1.0,172.16.3.0,192.168.2.0' ($osdNetworks -join ',') 'OSDClient picker includes DP-bearing and DP-less subnets'
$osdSubnetsWithGenerated = @(Get-ValidSubnets -ConfigToCheck $config -VMToCheck $osdClient)
Assert-Equal $true ($osdSubnetsWithGenerated -contains '192.168.1.0') 'OSDClient picker includes a generated empty subnet'

$script:EligibleSites = @(
    [pscustomobject]@{ SiteCode = 'PS1'; Network = '192.168.2.0'; Role = 'Primary' }
    [pscustomobject]@{ SiteCode = 'SEC'; Network = '10.0.9.0'; Role = 'Secondary' }
)
$script:MenuResponses.Enqueue('SEC [Secondary, 10.0.9.0]')
$selectedSiteCode = Select-OsdDistributionPointSiteCode -Network '10.0.8.0' -Config $config
Assert-Equal 'SEC' $selectedSiteCode 'DP remediation normalizes the highlighted owning site on bare Enter'
$siteMenuCalls = $script:MenuCalls
$boundaryOwnerConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'BOUNDCLIENT'; role = 'DomainMember'; operatingSystem = 'Windows 11 25H2'
            network = '10.0.8.0'; pushClient = 'SEC'
        })
}
$lockedSiteCode = Select-OsdDistributionPointSiteCode -Network '10.0.8.0' -Config $boundaryOwnerConfig
Assert-Equal 'SEC' $lockedSiteCode 'DP remediation honors an existing subnet site assignment'
Assert-Equal $siteMenuCalls $script:MenuCalls 'locked subnet ownership does not show a conflicting site picker'
$ownedSiteSystem = [pscustomobject]@{
    vmName = 'PS1MP'; role = 'SiteSystem'; siteCode = 'PS1'; operatingSystem = 'Server 2025'; network = '10.0.8.0'
}
$siteSystemOwner = Select-OsdDistributionPointSiteCode -Network '10.0.7.0' -Config $config -CandidateVM $ownedSiteSystem
Assert-Equal 'PS1' $siteSystemOwner 'existing SiteSystem keeps its current owning site when adding DP'
$conflictingSiteSystemOwner = Select-OsdDistributionPointSiteCode -Network '10.0.8.0' -Config $boundaryOwnerConfig -CandidateVM $ownedSiteSystem
Assert-Equal '' $conflictingSiteSystemOwner 'SiteSystem on a subnet owned by another site is rejected as a DP host'
$script:EligibleSites = @([pscustomobject]@{ SiteCode = 'PS1'; Network = '192.168.2.0'; Role = 'Primary' })

$script:SelectedNetwork = '192.168.2.0'
$script:SelectorCalls = 0
$script:MenuCalls = 0
$selectedDpNetwork = Select-OsdClientNetwork -VM $osdClient -Config $config
Assert-Equal '192.168.2.0' $selectedDpNetwork 'OSDClient accepts a subnet that already has a DP'
Assert-Equal 0 $script:MenuCalls 'existing DP avoids the remediation prompt'
$script:SelectedNetwork = $null
$cancelledNetwork = Select-OsdClientNetwork -VM $osdClient -Config $config
Assert-Equal '192.168.2.0' $cancelledNetwork 'cancelling OSD subnet selection preserves the current effective network'
$noCmConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'nocm.test'; Network = '192.168.50.0' }
    virtualMachines = @([pscustomobject]@{ vmName = 'MEMBER1'; role = 'DomainMember'; operatingSystem = 'Server 2025' })
}
$script:SelectedNetwork = '10.0.50.0'
$menuCallsBeforeNoCm = $script:MenuCalls
$noCmNetwork = Select-OsdClientNetwork -VM $osdClient -Config $noCmConfig
Assert-Equal '10.0.50.0' $noCmNetwork 'No-ConfigMgr lab accepts an OSDClient subnet without a DP'
Assert-Equal $menuCallsBeforeNoCm $script:MenuCalls 'No-ConfigMgr OSDClient does not show DP remediation'

$script:SelectedNetwork = '10.0.1.0'
$script:MenuCalls = 0
$script:MenuResponses.Enqueue('D')
$script:MenuResponses.Enqueue('W11CLIENT3')
$promotedNetwork = Select-OsdClientNetwork -VM $osdClient -Config $config
$promotedVM = $config.virtualMachines | Where-Object { $_.vmName -eq 'W11CLIENT3' } | Select-Object -First 1
Assert-Equal '10.0.1.0' $promotedNetwork 'OSDClient accepts a DP-less subnet after VM promotion'
Assert-Equal 'SiteSystem' $promotedVM.role 'eligible Windows 11 DomainMember is promoted to SiteSystem'
Assert-Equal $true $promotedVM.installDP 'promoted VM has the Distribution Point role enabled'
Assert-Equal 'PS1' $promotedVM.siteCode 'promoted VM is assigned to an eligible site'
Assert-Equal 0 $script:NewDpCalls 'existing-VM promotion does not create another VM'

$candidateConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'W10'; role = 'DomainMember'; operatingSystem = 'Windows 10 22H2'; network = '10.0.4.0' }
        [pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember'; operatingSystem = 'Server 2025'; sqlVersion = 'SQL Server 2022'; network = '10.0.4.0' }
    )
}
$ineligibleCandidates = @(Get-OsdDistributionPointPromotionCandidates -Network '10.0.4.0' -Config $candidateConfig)
Assert-Equal 0 $ineligibleCandidates.Count 'Windows 10 and SQL hosts are excluded from DP promotion'

$newDpConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @([pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'PS1'; installDP = $true })
}
$script:SelectedNetwork = '10.0.2.0'
$script:MenuResponses.Enqueue('D')
$script:MenuResponses.Enqueue('N')
$newDpNetwork = Select-OsdClientNetwork -VM $osdClient -Config $newDpConfig
$newDP = $newDpConfig.virtualMachines | Where-Object { $_.role -eq 'SiteSystem' } | Select-Object -First 1
Assert-Equal '10.0.2.0' $newDpNetwork 'OSDClient accepts an empty subnet after creating a DP VM'
Assert-Equal '10.0.2.0' $newDP.network 'new DP VM is placed on the selected OSD subnet'
Assert-Equal $true $newDP.installDP 'new DP VM has installDP enabled'
Assert-Equal $false $newDP.installMP 'new DP VM is DP-only'
Assert-Equal $true $script:DistributionPointOnly 'new DP remediation requests DP-only defaults during VM creation'

$relayFastConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'PS1'; network = '192.168.2.0'; installDP = $true; AssignedIP = '192.168.2.10' }
        [pscustomobject]@{
            vmName = 'RELAY1'; role = 'DHCPRelay'; operatingSystem = 'Ubuntu Server 24.04 LTS'; osFamily = 'Linux'; network = '192.168.2.0'
            relayMappings = @([pscustomobject]@{ clientNetwork = '10.0.9.0'; distributionPointVM = 'PS1' })
        }
    )
}
$global:existingMachines = @()
$script:SelectedNetwork = '10.0.9.0'
$relayFastMenuCalls = $script:MenuCalls
$relayFastNetwork = Select-OsdClientNetwork -VM $osdClient -Config $relayFastConfig
Assert-Equal '10.0.9.0' $relayFastNetwork 'OSDClient accepts a valid stored relay path'
Assert-Equal $relayFastMenuCalls $script:MenuCalls 'valid stored relay avoids remediation menus'

$noRelayOptionConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'PS1'; network = '192.168.2.0'; installDP = $false }
        [pscustomobject]@{ vmName = 'DYNAMICDP'; role = 'SiteSystem'; siteCode = 'PS1'; network = '192.168.2.0'; installDP = $true }
    )
}
$script:MenuResponses.Enqueue('B')
$null = Resolve-OsdPxePathForNetwork -Network '10.0.10.0' -Config $noRelayOptionConfig
Assert-Equal $false ($script:LastAdditionalOptions.Keys -contains 'R') 'relay option is hidden when no remote DP has a stable IPv4 address'

$fixedPrimaryConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'PS1'; role = 'Primary'; siteCode = 'PS1'; network = '192.168.2.0'; installDP = $true
        })
}
$fixedPrimaryCandidates = @(Get-OsdRelayDistributionPointCandidates -Network '192.168.3.0' -Config $fixedPrimaryConfig)
Assert-Equal 'PS1:192.168.2.10' (($fixedPrimaryCandidates | ForEach-Object { "$($_.VM.vmName):$($_.IPv4)" }) -join ',') 'new Primary is a relay target before AssignedIP is stamped'
$script:MenuResponses.Enqueue('B')
$null = Resolve-OsdPxePathForNetwork -Network '192.168.3.0' -Config $fixedPrimaryConfig
Assert-Equal $true ($script:LastAdditionalOptions.Keys -contains 'R') 'missing-path menu offers relay for a deterministic new Primary target'

$relayCreateConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'REMOTEDP'; role = 'Primary'; siteCode = 'PS1'; network = '192.168.2.0'; installDP = $true; AssignedIP = '192.168.2.10'
        })
}
$beforeRelayCreateCalls = $script:NewDpCalls
$script:SelectedNetwork = '10.0.11.0'
$script:MenuResponses.Enqueue('R')
$script:MenuResponses.Enqueue('REMOTEDP')
$relayCreatedNetwork = Select-OsdClientNetwork -VM $osdClient -Config $relayCreateConfig
$createdRelay = $relayCreateConfig.virtualMachines | Where-Object { $_.role -eq 'DHCPRelay' } | Select-Object -First 1
Assert-Equal '10.0.11.0' $relayCreatedNetwork 'selecting relay accepts the OSD subnet after re-resolution'
Assert-Equal ($beforeRelayCreateCalls + 1) $script:NewDpCalls 'selecting relay creates one relay VM when absent'
Assert-Equal '10.0.11.0:REMOTEDP' "$($createdRelay.relayMappings[0].clientNetwork):$($createdRelay.relayMappings[0].distributionPointVM)" 'new relay stores only client network and target DP intent'

$existingRelayConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @([pscustomobject]@{
            vmName = 'REMOTEDP'; role = 'Primary'; siteCode = 'PS1'; network = '192.168.2.0'; installDP = $true; AssignedIP = '192.168.2.10'
        })
}
$existingRelay = [pscustomobject]@{
    vmName = 'EXISTINGRELAY'; role = 'DHCPRelay'; operatingSystem = 'Ubuntu Server 24.04 LTS'; osFamily = 'Linux'
    network = '192.168.2.0'; state = 'Running'
    relayMappings = @([pscustomobject]@{ clientNetwork = '10.0.12.0'; distributionPointVM = 'REMOTEDP' })
}
$global:existingMachines = @($existingRelay)
$script:MenuResponses.Enqueue('REMOTEDP')
$existingRelayUpdated = Add-DhcpRelayForOsdNetwork -Network '10.0.13.0' -Config $existingRelayConfig
$persistedRelays = @($existingRelayConfig.virtualMachines | Where-Object { $_.vmName -eq 'EXISTINGRELAY' -and $_.hidden })
Assert-Equal $true $existingRelayUpdated 'existing relay mapping update succeeds after re-resolution'
Assert-Equal 1 $persistedRelays.Count 'existing relay update persists one hidden snapshot'
Assert-Equal '10.0.12.0,10.0.13.0' (@($persistedRelays[0].relayMappings.clientNetwork | Sort-Object) -join ',') 'existing relay update preserves prior mapping and adds the new mapping'

$mappingBeforeCancel = ($existingRelay.relayMappings | ConvertTo-Json -Compress)
$script:MenuResponses.Enqueue('ESCAPE')
$cancelledRelayUpdate = Add-DhcpRelayForOsdNetwork -Network '10.0.14.0' -Config $existingRelayConfig
Assert-Equal $false $cancelledRelayUpdate 'cancelling remote DP selection declines relay update'
Assert-Equal $mappingBeforeCancel ($existingRelay.relayMappings | ConvertTo-Json -Compress) 'cancel leaves existing relay mappings unchanged'

$existingConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @([pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'PS1'; installDP = $true })
}
$existingClient = [pscustomobject]@{
    vmName = 'EXISTINGCLIENT'
    role = 'DomainMember'
    operatingSystem = 'Windows 11 25H2'
    network = '10.0.3.0'
    memory = '4GB'
    installDP = $false
    state = 'Off'
}
$global:existingMachines = @($existingClient)
$script:SelectedNetwork = '10.0.3.0'
$script:MenuResponses.Enqueue('D')
$script:MenuResponses.Enqueue('EXISTINGCLIENT')
$existingDpNetwork = Select-OsdClientNetwork -VM $osdClient -Config $existingConfig
Assert-Equal '10.0.3.0' $existingDpNetwork 'OSDClient accepts a subnet after promoting a deployed VM'
Assert-Equal $true $existingClient.ExistingVM 'deployed VM promotion marks the object for existing-VM persistence'
Assert-Equal 'DomainMember' $existingClient.'role-Original' 'deployed VM promotion records the original role'
Assert-Equal $false $existingClient.'installDP-Original' 'deployed VM promotion records the original DP state'
Assert-Equal $true $existingClient.installDP 'deployed VM promotion enables installDP'
$persistedExistingDP = $existingConfig.virtualMachines | Where-Object { $_.vmName -eq 'EXISTINGCLIENT' -and $_.hidden } | Select-Object -First 1
Assert-Equal $true ($null -ne $persistedExistingDP) 'deployed VM promotion is persisted immediately as a hidden modification'
Assert-Equal '10.0.3.0' (Get-OsdEffectiveNetwork -VM $persistedExistingDP -Config $existingConfig) 'hidden promoted DP resolves its deployed subnet'
$existingClient.memory = '6GB'
$null = Add-ModifiedExistingVMToDeployConfig -VM $existingClient -ConfigToModify $existingConfig -Hidden:$true
$refreshedExistingDP = @($existingConfig.virtualMachines | Where-Object { $_.vmName -eq 'EXISTINGCLIENT' -and $_.hidden })
Assert-Equal 1 $refreshedExistingDP.Count 'later deployed-VM edits replace rather than duplicate the hidden snapshot'
Assert-Equal '6GB' $refreshedExistingDP[0].memory 'later deployed-VM edits refresh the persisted hidden snapshot'
$metadataDP = [pscustomobject]@{
    vmName = 'METADATADP'
    hidden = $true
    thisParams = [pscustomobject]@{ vmNetwork = '10.0.6.0' }
}
Assert-Equal '10.0.6.0' (Get-OsdEffectiveNetwork -VM $metadataDP -Config $existingConfig) 'converted hidden DP uses thisParams network metadata'

$boundaryConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ DomainName = 'example.test'; Network = '192.168.2.0' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'PS1'; network = '192.168.2.0'; installDP = $true }
        [pscustomobject]@{ vmName = 'OSD3'; role = 'OSDClient'; network = '10.0.6.0' }
        [pscustomobject]@{ vmName = 'DP3'; role = 'SiteSystem'; siteCode = 'PS1'; network = '10.0.6.0'; installDP = $true }
        [pscustomobject]@{ vmName = 'OSD4'; role = 'OSDClient'; network = '10.0.8.0' }
    )
}
$boundaryMappings = @(Get-OsdBoundaryMappings -Config $boundaryConfig)
Assert-Equal 'PS1:10.0.6.0' (($boundaryMappings | ForEach-Object { "$($_.SiteCode):$($_.Subnet)" }) -join ',') 'same-subnet DP creates an OSD boundary mapping'
Assert-Equal $false ($boundaryMappings.Subnet -contains '10.0.8.0') 'DP-less OSD subnet does not fabricate a boundary owner'
$genConfigText = Get-Content -LiteralPath $genConfigPath -Raw
Assert-Equal 1 ([regex]::Matches($genConfigText, 'Get-OsdBoundaryMappings -Config \$deployConfig').Count) 'deploy conversion consumes OSD boundary mappings once'

$failedPromotionVM = [pscustomobject]@{
    vmName = 'MISSINGFROMHOST'
    role = 'DomainMember'
    operatingSystem = 'Windows 11 25H2'
    network = '10.0.7.0'
    installDP = $false
}
$global:existingMachines = @()
$failedPromotion = Enable-OsdDistributionPointOnCandidate `
    -Candidate ([pscustomobject]@{ VM = $failedPromotionVM; TrackChanges = $true }) `
    -SiteCode 'PS1' -Config $existingConfig
Assert-Equal '' $failedPromotion 'failed persistence rejects deployed-VM promotion'
Assert-Equal 'DomainMember' $failedPromotionVM.role 'failed persistence leaves the deployed VM role unchanged'
Assert-Equal $false $failedPromotionVM.installDP 'failed persistence leaves the deployed VM DP state unchanged'

$script:MenuResponses.Enqueue('B')
$wentBack = Add-DistributionPointForOsdNetwork -Network '10.0.5.0' -Config $existingConfig
Assert-Equal $false $wentBack 'go back declines DP provisioning without accepting the subnet'

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All GenConfig network-selection checks passed.'