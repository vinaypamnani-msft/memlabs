#requires -Version 5.1
<#
.SYNOPSIS
    Verifies effective hierarchy defaults and read-only existing-domain discovery.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors." }
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
    if (-not $definition) { throw "Missing $Name." }
    [scriptblock]::Create($definition.Extent.Text)
}
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
foreach ($name in 'Get-TopLevelSiteServer', 'Get-ConfigCmOptions', 'Get-CmOptionsFingerprint',
    'Get-AddToExistingCmOptionsOwner', 'Test-AddToExistingCmOptionsChanged',
    'Get-CmOptionsOwnerPrimaryNames', 'Add-CmOptionsPersistenceTargetForPhase8',
    'Sync-ExistingHierarchyOptionsToDeployConfig') {
    . (Import-TestFunction -Path $configPath -Name $name)
}
. (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.GenConfig.Existing.ps1') -Name 'New-UserConfig')

function Write-Log { param($Message, [switch]$Verbose, [switch]$LogOnly) }
function Get-List {
    param($Type, $DomainName)
    $script:Inventory
}
function Get-VMNote {
    param($VmName)
    $script:Notes[$VmName]
}
function Set-VMNote {
    param($VmName, $VmNote)
    $script:Writes.Add($VmName)
    throw "Read-only discovery tried to write $VmName."
}
function Get-CmOptionsFromSiteServerBackup {
    param($VmName, $DomainName)
    $script:Backups[$VmName]
}
function get-PrefixForDomain { param($Domain) 'LAB-' }
function Get-MemlabsVmStorageRoot { 'C:\fixture-vms' }
function Get-DomainNetbiosName { param($DomainName) 'EXAMPLE' }
function Add-ExistingVMToDeployConfig {
    param($VmName, $ConfigToModify)
    $script:Scheduled.Add($VmName)
    $ConfigToModify.virtualMachines = @([pscustomobject]@{ vmName = $VmName; role = 'Primary'; hidden = $true })
}
$global:Common = [pscustomobject]@{ InJob = $false }
$script:Inventory = @(
    [pscustomobject]@{ vmName = 'DC1'; role = 'DC'; domain = 'example.test' },
    [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; siteCode = 'PS1'; domain = 'example.test' }
)
$script:Notes = @{}
$script:Backups = @{}
$script:Writes = [Collections.Generic.List[string]]::new()
$script:Scheduled = [Collections.Generic.List[string]]::new()
$defaults = @{
    EVALVersion = $false; UsePKI = $false; PrePopulateObjects = $true
    OfflineSCP = $false; OfflineSUP = $false; WsusImportBaseline = $true; EnableBLM = $false
}
foreach ($key in $defaults.Keys) {
    $legacy = [pscustomobject]@{ Version = '2509'; Install = $true }
    $script:Notes['PRI1'] = [pscustomobject]@{ cmOptions = $legacy }
    $desired = $legacy.PSObject.Copy()
    $desired | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
    $config = [pscustomobject]@{
        cmOptions = $desired
        vmOptions = [pscustomobject]@{ domainName = 'example.test' }
        virtualMachines = $null
    }
    $script:Scheduled.Clear()
    Assert-True (-not (Test-AddToExistingCmOptionsChanged -Config $config)) "$key default backfill became an authored change."
    Assert-True (-not (Add-CmOptionsPersistenceTargetForPhase8 -Config $config) -and
        $script:Scheduled.Count -eq 0) "$key default backfill scheduled an unrelated Primary."
    $desired.$key = -not $defaults[$key]
    Assert-True (Test-AddToExistingCmOptionsChanged -Config $config) "$key intentional nondefault change disappeared."
    Assert-True ((Add-CmOptionsPersistenceTargetForPhase8 -Config $config) -and
        ($script:Scheduled -join ',') -eq 'PRI1' -and $config.virtualMachines[0].cmOptionsChanged) 'Explicit options did not target only their owner.'
}

$script:Notes['PRI1'] = [pscustomobject]@{ cmOptions = [pscustomobject]@{ Version = '2509'; Install = $true; UsePKI = $false } }
$caseConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ version = '2509'; install = $true; usepki = $false }
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = $null
}
Assert-True (-not (Test-AddToExistingCmOptionsChanged -Config $caseConfig)) 'Case-only option names became an authored change.'
$caseConfig.cmOptions | Add-Member -NotePropertyName CustomSetting -NotePropertyValue 'intentional'
Assert-True (Test-AddToExistingCmOptionsChanged -Config $caseConfig) 'Unknown explicit scalar settings were ignored as defaults.'
$caseConfig.cmOptions.CustomSetting = [pscustomobject]@{ Nested = $true }
$threw = $false
try { $null = Test-AddToExistingCmOptionsChanged -Config $caseConfig } catch { $threw = $_.Exception.Message -like '*unsupported non-scalar*' }
Assert-True $threw 'Unsupported option shapes were silently normalized.'

$script:Notes['PRI1'] = [pscustomobject]@{ customMarker = 'retain' }
$script:Backups['PRI1'] = [pscustomobject]@{ Version = '2509'; Install = $true; UsePKI = $false }
$readConfig = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'example.test' }; virtualMachines = $null }
$recovered = Get-ConfigCmOptions -Config $readConfig
Assert-True ($recovered.Version -eq '2509') 'Read-only options lookup did not recover the authoritative backup.'
$generated = New-UserConfig -Domain 'example.test' -Subnet '192.168.1.0'
Assert-True ($generated.cmOptions.Version -eq '2509' -and $null -eq $generated.virtualMachines) 'Existing-domain authoring changed its intent shape.'
Assert-True (-not (Test-AddToExistingCmOptionsChanged -Config $generated)) 'Legacy backup import became an authored hierarchy edit.'
$childConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'example.test' }
    virtualMachines = @([pscustomobject]@{ vmName = 'CHILD'; role = 'Primary'; siteCode = 'CHD'; parentSiteCode = 'PS1' })
}
$null = Sync-ExistingHierarchyOptionsToDeployConfig -Config $childConfig -ExistingVMs $script:Inventory
Assert-True ($childConfig.virtualMachines[0].cmOptions.Version -eq '2509') 'Hierarchy resolution lost authoritative options.'
Assert-True ($script:Writes.Count -eq 0 -and $null -eq $script:Notes['PRI1'].cmOptions -and
    $script:Notes['PRI1'].customMarker -eq 'retain') 'Discovery/authoring/resolution mutated an unrelated server note.'
$script:Backups.Remove('PRI1')
$threw = $false
try { $null = Test-AddToExistingCmOptionsChanged -Config $generated } catch { $threw = $_.Exception.Message -like '*no options*' }
Assert-True ($threw -and $script:Writes.Count -eq 0) 'Missing authoritative options were silently accepted or backfilled.'
[Console]::WriteLine("PASS -- $script:Assertions hierarchy discovery/isolation assertions.")
