<#
.SYNOPSIS
    Verifies GenConfig network edits and custom-subnet OSD distribution-point placement.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$commonPath = Join-Path $RootPath 'common'

function Import-TestFunction {
    param([string] $File, [string] $Name)

    $path = Join-Path $commonPath $File
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)

    $script:Assertions++
    if ("$Expected" -ne "$Actual") { throw "$Message`nExpected: $Expected`nActual: $Actual" }
}

function Reset-Fixture {
    param([string] $Role = 'DomainMember')

    $script:MenuRenders = 0
    $script:ValidationCalls = 0
    $script:ConfigurationChecks = 0
    $script:VmPushUpdates = 0
    $script:DefaultPushUpdates = 0
    $script:SubnetPrompts = 0
    $script:SelectedSubnet = $null
    $script:InitialSubnet = $null
    $script:SubnetOptions = @()
    $script:OldNetwork = $null
    $script:RunOsdValidation = $false
    $script:Inventory = $null
    $global:Config = [pscustomobject]@{
        vmOptions       = [pscustomobject]@{ domainName = 'example.test'; network = '10.10.0.0'; basePath = 'C:\Lab' }
        virtualMachines = @(
            [pscustomobject]@{ vmName = 'PS1SITE'; Role = 'Primary'; SiteCode = 'PS1'; network = '10.10.0.0' },
            [pscustomobject]@{ vmName = 'PS1DPMP2'; Role = $Role; SiteCode = 'PS1' }
        )
    }
    $global:Config.virtualMachines[1]
}

function Get-SortedProperties {
    param($Object)
    $Object.PSObject.Properties.Name
}
function Get-AdditionalInformation {
    param($Item, $Data)
    "$Data"
}
function Get-AdditionalInformationColor {
    param($Item, $Data)
    'White'
}
function Get-EnhancedSubnetList {
    param($SubnetList, $ConfigToCheck)
    $SubnetList
}
function Write-Log {
    param($Message, [switch] $Verbose, [switch] $LogOnly, [switch] $Warning)
}
function Add-MenuItem {
    param($MenuName, [ref] $MenuItems, $ItemName, $ItemText, $Selectable, $Selected, $Color1, $HelpFunction, $Deletable)
    $null = $MenuItems.Value.Add([pscustomobject]@{ ItemName = "$ItemName"; ItemText = $ItemText })
}
function Get-Menu2 {
    param($MenuName, [ref] $MenuItems, $Prompt, $HideHelp, $Test, [switch] $AcceptsDelete, $DroppableItemPattern,
        $OptionArray, $CurrentValue, $AdditionalOptions, [switch] $Split)

    if ($null -eq $MenuItems) {
        $script:SubnetPrompts++
        if ($script:SubnetPrompts -gt 1) { throw 'The subnet picker did not accept the selected network.' }
        $script:SubnetOptions = @($OptionArray)
        $script:InitialSubnet = $CurrentValue
        return $script:SelectedSubnet
    }

    $script:MenuRenders++
    if ($script:MenuRenders -gt 2) { throw 'The property menu did not exit after the network edit.' }
    if ($script:MenuRenders -eq 1) {
        $networkItems = @($MenuItems.Value | Where-Object { $_.ItemText -match '^\s*network\s*=' })
        Assert-Equal 1 $networkItems.Count 'The property menu must expose exactly one network row.'
        return $networkItems[0].ItemName
    }
    '!'
}
function Get-List2 {
    param($DeployConfig, [switch] $SmartUpdate)
    if ($null -ne $script:Inventory) { return $script:Inventory }
    $DeployConfig.virtualMachines
}
function Select-Subnet {
    param($ConfigToCheck, $CurrentNetworkIsValid, $CurrentVM, $CurrentValue)
    $script:SubnetPrompts++
    $script:InitialSubnet = $CurrentValue
    $script:SelectedSubnet
}
function Get-AdditionalValidations {
    param($Property, $Name, [Parameter(Mandatory = $true)] [object] $CurrentValue)
    $script:ValidationCalls++
}
function Get-TestResult {
    param([switch] $SuccessOnError)
    $script:ConfigurationChecks++
    if ($script:RunOsdValidation) {
        $script:LastValidation = Test-Configuration -InputObject $global:Config -Fast
        Assert-Equal 0 $script:LastValidation.Failures "Configuration validation failed: $($script:LastValidation.Message)"
    }
    $true
}
function Update-PushClientForNetworkChange {
    param($ChangedVM, $OldNetwork, $Config)
    $script:VmPushUpdates++
    $script:OldNetwork = $OldNetwork
}
function Update-PushClientForDefaultNetworkChange {
    param($OldDefault, $Config)
    $script:DefaultPushUpdates++
    $script:OldNetwork = $OldDefault
}
function Add-ErrorMessage {
    param($Property, $Message, [switch] $Persist)
    throw "Unexpected validation error: $Message"
}
function Invoke-NetworkEdit {
    param($Property)
    Select-Options -MenuName 'Network edit' -PropertyEnum $Property -Prompt 'Select a property' -Test:$false | Out-Null
    Assert-Equal 2 $script:MenuRenders 'The network edit did not return to the property menu.'
}
function Assert-UnchangedNetworkEdit {
    param($Property)

    $before = $global:Config | ConvertTo-Json -Depth 10 -Compress
    Invoke-NetworkEdit -Property $Property
    Assert-Equal $before ($global:Config | ConvertTo-Json -Depth 10 -Compress) 'A no-change network edit mutated the configuration.'
    Assert-Equal 0 $script:ValidationCalls 'A no-change result reached post-edit validation.'
    Assert-Equal 0 $script:ConfigurationChecks 'A no-change result triggered a configuration check.'
    Assert-Equal 0 $script:VmPushUpdates 'A no-change result recalculated VM client push.'
    Assert-Equal 0 $script:DefaultPushUpdates 'A no-change result recalculated default-network client push.'
}

. (Import-TestFunction 'Common.GenConfig.VMList.ps1' 'Select-Options')
. (Import-TestFunction 'Common.GenConfig.AddVM.ps1' 'Get-NetworkForVM')
. (Import-TestFunction 'Common.GenConfig.Validation.ps1' 'Get-GenConfigSiteServer')

$savedGlobals = @{}
foreach ($name in 'Config', 'Common', 'DisableSmartUpdate', 'TestConfigFastCache', 'MemLabsSkipValidation') {
    $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    $savedGlobals[$name] = [pscustomobject]@{ Exists = ($null -ne $variable); Value = $variable.Value }
}
$script:Assertions = 0
try {
    $global:Common = [pscustomobject]@{
        Colors = [pscustomobject]@{ GenConfigHeader = 'White'; GenConfigHelpHighlight = 'Yellow' }
        Supported = [pscustomobject]@{ UpdatablePropList = @() }
    }

    foreach ($role in 'PassiveSite') {
        foreach ($siteUsesDefault in $false, $true) {
            $vm = Reset-Fixture -Role $role
            if ($siteUsesDefault) { $global:Config.virtualMachines[0].PSObject.Properties.Remove('network') }
            Assert-Equal $null (Get-NetworkForVM -vm $vm) "$role should not require a replacement subnet."
            Assert-UnchangedNetworkEdit -Property $vm
        }
        $vm = Reset-Fixture -Role $role
        $vm | Add-Member -NotePropertyName network -NotePropertyValue '10.10.0.0'
        Assert-UnchangedNetworkEdit -Property $vm

        $vm = Reset-Fixture -Role $role
        $global:Config.virtualMachines[0].network = '10.20.0.0'
        Invoke-NetworkEdit -Property $vm
        Assert-Equal '10.20.0.0' $vm.network "$role did not follow its site's subnet."
        Assert-Equal 1 $script:ValidationCalls 'A role-bound subnet change did not run post-edit validation.'
        Assert-Equal 1 $script:VmPushUpdates 'A role-bound subnet change did not recalculate client push.'
        Assert-Equal '10.10.0.0' $script:OldNetwork 'A role-bound subnet change lost the original effective subnet.'
    }

    foreach ($siteUsesDefault in $false, $true) {
        $vm = Reset-Fixture -Role 'SiteSystem'
        if ($siteUsesDefault) { $global:Config.virtualMachines[0].PSObject.Properties.Remove('network') }
        Assert-Equal $null (Get-NetworkForVM -vm $vm -ReturnIfNotNeeded:$true) 'Adding a site system unnecessarily replaced its default subnet.'
        Assert-Equal 0 $script:SubnetPrompts 'Adding a site system unexpectedly opened an interactive network picker.'
        $vm | Add-Member -NotePropertyName network -NotePropertyValue '10.30.0.0'
        Assert-Equal '10.10.0.0' (Get-NetworkForVM -vm $vm -ReturnIfNotNeeded:$true) 'Automatic placement did not resolve an inherited site-server subnet.'
    }
    $vm = Reset-Fixture -Role 'SiteSystem'
    $global:Config.virtualMachines[0].network = '10.20.0.0'
    Assert-Equal '10.20.0.0' (Get-NetworkForVM -vm $vm -ReturnIfNotNeeded:$true) 'A new site system no longer starts on its site subnet.'
    Assert-Equal 0 $script:SubnetPrompts 'Automatic site-system placement opened a network picker.'

    foreach ($selection in @($null, '', ' ', 'ESCAPE')) {
        foreach ($role in 'DomainMember', 'SiteSystem') {
            foreach ($hasOverride in $false, $true) {
                $vm = Reset-Fixture -Role $role
                if ($hasOverride) { $vm | Add-Member -NotePropertyName network -NotePropertyValue '10.20.0.0' }
                $script:SelectedSubnet = $selection
                Assert-UnchangedNetworkEdit -Property $vm
                Assert-Equal 1 $script:SubnetPrompts "$role did not open its network picker."
            }
        }
        $null = Reset-Fixture
        $script:SelectedSubnet = $selection
        Assert-UnchangedNetworkEdit -Property $global:Config.vmOptions
    }

    foreach ($role in 'DomainMember', 'SiteSystem') {
        foreach ($hasOverride in $false, $true) {
            $vm = Reset-Fixture -Role $role
            $oldNetwork = $global:Config.vmOptions.network
            if ($hasOverride) {
                $oldNetwork = '10.20.0.0'
                $vm | Add-Member -NotePropertyName network -NotePropertyValue $oldNetwork
            }
            $script:SelectedSubnet = '10.30.0.0'
            Invoke-NetworkEdit -Property $vm
            Assert-Equal '10.30.0.0' $vm.network 'A valid subnet selection was not applied.'
            Assert-Equal 1 $script:ValidationCalls 'A valid VM network edit did not run post-edit validation once.'
            Assert-Equal 1 $script:ConfigurationChecks 'A valid VM network edit did not check the configuration once.'
            Assert-Equal 1 $script:VmPushUpdates 'A valid VM network edit did not recalculate client push once.'
            Assert-Equal $oldNetwork $script:OldNetwork 'Client-push recalculation lost the original effective subnet.'
            if ($role -eq 'SiteSystem') {
                Assert-Equal $oldNetwork $script:InitialSubnet 'The site-system picker did not highlight its current effective subnet.'
            }
        }
    }

    $vm = Reset-Fixture
    $vm | Add-Member -NotePropertyName network -NotePropertyValue '10.20.0.0'
    $script:SelectedSubnet = $global:Config.vmOptions.network
    Invoke-NetworkEdit -Property $vm
    Assert-Equal $null $vm.PSObject.Properties['network'] 'Moving to the default subnet did not remove the VM override.'
    Assert-Equal 1 $script:VmPushUpdates 'Moving back to the default subnet did not recalculate client push.'
    Assert-Equal '10.20.0.0' $script:OldNetwork 'Moving back to the default subnet lost the previous effective subnet.'

    $null = Reset-Fixture
    $script:SelectedSubnet = '10.30.0.0'
    Invoke-NetworkEdit -Property $global:Config.vmOptions
    Assert-Equal '10.30.0.0' $global:Config.vmOptions.network 'A valid default-subnet edit was not applied.'
    Assert-Equal 1 $script:DefaultPushUpdates 'A default-subnet edit did not recalculate default-network client push.'
    Assert-Equal '10.10.0.0' $script:OldNetwork 'A default-subnet edit lost the previous default.'
    Assert-Equal 1 $script:ValidationCalls 'A default-subnet edit did not run post-edit validation.'
    Assert-Equal 1 $script:ConfigurationChecks 'A default-subnet edit did not check the configuration.'

    foreach ($name in 'Select-Subnet', 'Get-ValidNetworksForVM') {
        . (Import-TestFunction 'Common.GenConfig.Existing.ps1' $name)
    }
    foreach ($name in 'Get-ValidSubnets', 'ConvertTo-DeployConfigEx') {
        . (Import-TestFunction 'Common.GenConfig.ps1' $name)
    }
    foreach ($name in 'Get-EligiblePushSites', 'Test-PushClientRequested', 'Resolve-PushClientSite') {
        . (Import-TestFunction 'Common.Config.ps1' $name)
    }
    foreach ($name in 'Test-Configuration', 'Add-ValidationMessage') {
        . (Import-TestFunction 'Common.Validation.ps1' $name)
    }

    function Get-NetworkList { @() }
    function Get-NetIPAddress { param($AddressFamily) @() }
    function Get-VM2 { param($Name, [switch] $Fallback) }
    function Get-List { param($Type, $Domain, $DomainName) @() }
    function Write-Progress2 { param($Activity, $Status, $PercentComplete, [switch] $Completed) }
    function Write-Exception { param($ExceptionInfo) throw $ExceptionInfo }
    function New-DeployConfig { param($ConfigObject) $ConfigObject }
    function Test-ValidVmOptions { param($ConfigObject, $ReturnObject) }
    function Test-ValidMachineName { param($VmName, $ReturnObject) }
    function Test-ValidCmOptions { param($ConfigObject, $ReturnObject) }
    function Test-ValidVmSupported { param($VM, $ConfigObject, $ReturnObject) }
    function Test-ValidVmMemory { param($VM, $ReturnObject) }
    function Test-ValidVmProcs { param($VM, $ReturnObject) }
    function Test-ValidVmDisks { param($VM, $ReturnObject) }
    function Test-ValidVmServerOS { param($VM, $ReturnObject) }
    function Test-ValidVmPath { param($VM, $PathProperty, $ValidPathExample, $ReturnObject) }
    function Test-ValidUserName { param($Name, $VmName) }
    function Test-ValidRoleDC { param($ConfigObject, $ReturnObject) }
    function Test-ValidRoleSiteServer { param($VM, $ConfigObject, $ReturnObject) }
    function Test-ValidRoleSiteSystem { param($VM, $ReturnObject) }
    function Get-VMFromList2 {
        param($DeployConfig, $VmName)
        Get-List2 -DeployConfig $DeployConfig | Where-Object vmName -eq $VmName
    }
    function Get-SiteServerForSiteCode {
        param($DeployConfig, $SiteCode, $Type, $DomainName)
        Get-List2 -DeployConfig $DeployConfig | Where-Object { $_.Role -eq 'Primary' -and $_.SiteCode -eq $SiteCode }
    }
    function Get-PassiveSiteServerForSiteCode { param($DeployConfig, $SiteCode, $Type, $DomainName) }
    function Get-RoleForSiteCode {
        param($ConfigToCheck, $SiteCode)
        (Get-SiteServerForSiteCode -DeployConfig $ConfigToCheck -SiteCode $SiteCode).Role
    }
    function Add-VMToAccountLists {
        param($ThisVM, $VM, $AccountLists, $DeployConfig, [switch] $SQLSysAdminAccounts, [switch] $LocalAdminAccounts, [switch] $WaitOnDomainJoin)
    }
    function Get-CMBaselineVersion { param($CMVersion) 'CM-CurrentBranch' }
    function Resolve-DeployUrlCatalog {
        param($AzureFileList)
        [pscustomobject]@{ Urls = [pscustomobject]@{}; Metadata = [pscustomobject]@{} }
    }

    $global:DisableSmartUpdate = $false
    $global:TestConfigFastCache = $null
    $global:MemLabsSkipValidation = $false
    $vm = Reset-Fixture -Role 'SiteSystem'
    $vm | Add-Member -NotePropertyName installDP -NotePropertyValue $true
    $vm | Add-Member -NotePropertyName pushClient -NotePropertyValue $false
    $global:Config.virtualMachines += @(
        [pscustomobject]@{ vmName = 'DC1'; Role = 'DC' },
        [pscustomobject]@{ vmName = 'OSD1'; Role = 'OSDClient'; network = '10.77.0.0' }
    )
    $global:Config | Add-Member -NotePropertyName parameters -NotePropertyValue ([pscustomobject]@{ DCName = 'DC1' })
    $before = Test-Configuration -InputObject $global:Config -Fast
    Assert-Equal 0 $before.Failures "The OSD fixture failed validation: $($before.Message)"
    Assert-Equal 1 $before.Warnings 'The fixture should have exactly the missing-local-DP warning.'
    Assert-Equal $true ("$($before.Message)" -like '*OSDClient Validation:*10.77.0.0*no Distribution Point*') 'The custom-subnet OSDClient did not warn about its missing local DP.'

    $script:SelectedSubnet = 'ESCAPE'
    $beforeCancel = $global:Config | ConvertTo-Json -Depth 10 -Compress
    Invoke-NetworkEdit -Property $vm
    Assert-Equal $beforeCancel ($global:Config | ConvertTo-Json -Depth 10 -Compress) 'Cancelling the actual site-system picker changed an inherited network.'
    $script:MenuRenders = 0
    $script:SubnetPrompts = 0
    $script:SelectedSubnet = '10.77.0.0'
    $script:RunOsdValidation = $true
    Invoke-NetworkEdit -Property $vm
    Assert-Equal 1 $script:SubnetPrompts 'The new site system did not open the actual subnet picker.'
    Assert-Equal $true ($script:SubnetOptions -contains '10.77.0.0') 'The OSDClient custom subnet was absent from the network options.'
    Assert-Equal '10.77.0.0' $vm.network 'The DP did not move to the OSDClient custom subnet.'
    Assert-Equal 0 $script:LastValidation.Warnings 'Placing the DP on the OSDClient subnet did not clear the warning.'
    Assert-Equal $false ("$($script:LastValidation.Message)" -like '*OSDClient Validation:*no Distribution Point*') 'The OSDClient warning remained after placing a DP on its subnet.'
    Assert-Equal $false $vm.pushClient 'Moving the DP enabled client push without consent.'

    $script:MenuRenders = 0
    $script:SubnetPrompts = 0
    $script:SelectedSubnet = 'ESCAPE'
    $beforeCancel = $global:Config | ConvertTo-Json -Depth 10 -Compress
    Invoke-NetworkEdit -Property $vm
    Assert-Equal '10.77.0.0' $script:InitialSubnet 'Reopening the site-system picker lost its custom subnet selection.'
    Assert-Equal $beforeCancel ($global:Config | ConvertTo-Json -Depth 10 -Compress) 'Cancelling the actual site-system picker changed its explicit custom subnet.'

    $script:Inventory = @($global:Config.virtualMachines) + @(
        [pscustomobject]@{ vmName = 'DP2'; Role = 'SiteSystem'; SiteCode = 'PS1'; installDP = $true; network = '10.77.0.0' },
        [pscustomobject]@{ vmName = 'PULLDP'; Role = 'SiteSystem'; SiteCode = 'PS1'; enablePullDP = $true; network = '10.78.0.0' },
        [pscustomobject]@{ vmName = 'NODP'; Role = 'SiteSystem'; SiteCode = 'PS1'; installDP = $false; network = '10.79.0.0' },
        [pscustomobject]@{ vmName = 'FOREIGNDP'; Role = 'SiteSystem'; SiteCode = 'PS1'; installDP = $true; network = '10.80.0.0'; domain = 'foreign.test' },
        [pscustomobject]@{ vmName = 'PS2SITE'; Role = 'Primary'; SiteCode = 'PS2'; network = '10.81.0.0' },
        [pscustomobject]@{ vmName = 'SHAREDDP'; Role = 'SiteSystem'; SiteCode = 'PS1'; installDP = $true; network = '10.81.0.0' },
        [pscustomobject]@{ vmName = 'CLIENT1'; Role = 'DomainMember'; pushClient = 'PS1'; network = '10.82.0.0' },
        [pscustomobject]@{ vmName = 'CLIENTDP'; Role = 'SiteSystem'; SiteCode = 'PS2'; installDP = $true; network = '10.82.0.0' }
    )
    foreach ($role in 'DC', 'Primary') {
        $projectionConfig = [pscustomobject]@{
            vmOptions = $global:Config.vmOptions
            virtualMachines = @($global:Config.virtualMachines | Where-Object Role -eq $role)
        }
        $projected = ConvertTo-DeployConfigEx -DeployConfig $projectionConfig
        $mappings = @($projected.virtualMachines[0].thisParams.sitesAndNetworks)
        Assert-Equal 1 @($mappings | Where-Object { $_.SiteCode -eq 'PS1' -and $_.Subnet -eq '10.77.0.0' }).Count "$role generation omitted the remote DP subnet when client push was disabled."
        Assert-Equal 1 @($mappings | Where-Object { $_.SiteCode -eq 'PS1' -and $_.Subnet -eq '10.10.0.0' }).Count "$role generation lost the original site-server subnet."
        Assert-Equal 1 @($mappings | Where-Object { $_.SiteCode -eq 'PS1' -and $_.Subnet -eq '10.78.0.0' }).Count "$role generation omitted a pull-DP subnet."
        Assert-Equal 0 @($mappings | Where-Object { $_.Subnet -in '10.79.0.0', '10.80.0.0' }).Count "$role generation added a disabled or foreign-domain DP."
        Assert-Equal 'PS2' ($mappings | Where-Object Subnet -eq '10.81.0.0').SiteCode "$role generation reassigned another site server's subnet."
        Assert-Equal 'PS1' ($mappings | Where-Object Subnet -eq '10.82.0.0').SiteCode "$role generation reassigned an explicitly targeted client subnet."
    }
    $script:Inventory += [pscustomobject]@{ vmName = 'BROKENDP'; Role = 'SiteSystem'; SiteCode = 'BAD'; installDP = $true; network = '10.83.0.0' }
    $rejected = $false
    try { ConvertTo-DeployConfigEx -DeployConfig $projectionConfig | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*DP 'BROKENDP'*valid Primary or Secondary site code*") { throw }
        $rejected = $true
    }
    Assert-Equal $true $rejected 'An unknown remote-DP site code generated a malformed boundary instead of failing.'

    Write-Host "PASS: $script:Assertions GenConfig network-edit assertions."
}
finally {
    foreach ($name in $savedGlobals.Keys) {
        if ($savedGlobals[$name].Exists) { Set-Variable -Name $name -Scope Global -Value $savedGlobals[$name].Value }
        else { Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue }
    }
}
