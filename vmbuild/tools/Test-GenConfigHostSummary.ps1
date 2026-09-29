#requires -Version 5.1
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Assertions = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $What)

    $script:Assertions++
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    [Console]::WriteLine(('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What))
    if (-not $passed) {
        [Console]::WriteLine("      expected: $Expected")
        [Console]::WriteLine("      actual:   $Actual")
    }
}

function Assert-True {
    param([bool] $Actual, [string] $What)
    Assert-Equal $true $Actual $What
}

function Get-TestAst {
    param([string] $Path)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has $(@($errors).Count) parse error(s)" }
    return $ast
}

function Import-TestFunction {
    param($Ast, [string] $Name)

    $definition = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

[Console]::WriteLine("engine : $($PSVersionTable.PSVersion)")

$newLabAst = Get-TestAst -Path (Join-Path $RootPath 'New-Lab.ps1')
$syncCalls = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Sync-MemLabsDhcpAppliance'
        }, $true))
$genConfigCalls = @($newLabAst.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
            $name = $node.GetCommandName()
            return $name -and $name.EndsWith('genconfig.ps1', [StringComparison]::OrdinalIgnoreCase)
        }, $true))
$configLoadCalls = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-UserConfiguration'
        }, $true))
$validationCalls = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Test-Configuration'
        }, $true))
$phaseCalls = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Start-Phase'
        }, $true))
$standaloneMaintenanceCalls = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Start-Maintenance'
        }, $true))

Assert-Equal 1 $syncCalls.Count 'New-Lab has one DHCP appliance reconciliation call'
Assert-Equal 1 $genConfigCalls.Count 'New-Lab has one GenConfig invocation'
Assert-Equal 0 $standaloneMaintenanceCalls.Count 'New-Lab does not run live-VM maintenance before GenConfig'
if ($syncCalls.Count -eq 1 -and $genConfigCalls.Count -eq 1) {
    Assert-True ($syncCalls[0].Extent.StartOffset -gt $genConfigCalls[0].Extent.EndOffset) 'DHCP appliance reconciliation occurs after GenConfig returns'
    Assert-True ($syncCalls[0].Extent.Text -match '(?i)-DeployConfig\s+\$deployConfig') 'DHCP appliance reconciliation receives the selected deployment config'
    $nonDeployExits = @($newLabAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ExitStatementAst] -and
                $node.Extent.StartOffset -gt $genConfigCalls[0].Extent.EndOffset -and
                $node.Extent.EndOffset -lt $syncCalls[0].Extent.StartOffset
            }, $true))
    Assert-True ($nonDeployExits.Count -ge 2) 'non-deploy GenConfig exits occur before DHCP appliance reconciliation'
}
if ($syncCalls.Count -eq 1 -and $configLoadCalls.Count -gt 0 -and $validationCalls.Count -gt 0 -and $phaseCalls.Count -gt 0) {
    Assert-True ($syncCalls[0].Extent.StartOffset -gt $configLoadCalls[0].Extent.EndOffset) 'DHCP appliance reconciliation occurs after configuration loading'
    Assert-True ($syncCalls[0].Extent.StartOffset -gt $validationCalls[0].Extent.EndOffset) 'DHCP appliance reconciliation occurs after configuration validation'
    Assert-True ($syncCalls[0].Extent.EndOffset -lt $phaseCalls[0].Extent.StartOffset) 'DHCP appliance reconciliation occurs before phase dispatch'
}

# Phase 0 maintenance gate: an explicit deployment targeting existing VMs must run
# required (AppliesToExisting) maintenance automatically, as part of Phase 0 --
# after Phase 0's own existing-VM preparation (and this deployment's earlier
# DHCP/network reconciliation) and strictly before Phase 1 dispatch begins -- and
# must abort the deployment (exit) if that maintenance fails. It is a distinct
# function from the interactive Start-Maintenance so "no live maintenance before
# GenConfig" and "menu-invoked maintenance stays interactive" both remain
# literally true. New VMs are never targeted here; they continue to receive fixes
# through DSC/Phase 10 once Phase 1 creates them.
$requiredMaintenanceCalls = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Start-RequiredExistingVMMaintenance'
        }, $true))
Assert-Equal 1 $requiredMaintenanceCalls.Count 'New-Lab has one Phase 0 mandatory existing-VM maintenance gate'
# Distinguish Phase 0's own Start-Phase call (literal "-Phase 0") from the main
# Phase 1..N loop's call (variable "-Phase $i") -- both share the command name
# Start-Phase, so $phaseCalls alone cannot tell them apart.
$phase0DispatchCalls = @($phaseCalls | Where-Object { $_.Extent.Text -match '-Phase\s+0\b' })
$phaseLoopDispatchCalls = @($phaseCalls | Where-Object { $_.Extent.Text -match '-Phase\s+\$i\b' })
Assert-Equal 1 $phase0DispatchCalls.Count 'New-Lab has one literal Phase 0 Start-Phase call'
Assert-True ($phaseLoopDispatchCalls.Count -ge 1) 'New-Lab has a Phase 1..N loop Start-Phase call'
if ($requiredMaintenanceCalls.Count -eq 1 -and $syncCalls.Count -eq 1 -and $phase0DispatchCalls.Count -eq 1 -and $phaseLoopDispatchCalls.Count -ge 1) {
    Assert-True ($requiredMaintenanceCalls[0].Extent.StartOffset -gt $syncCalls[0].Extent.EndOffset) 'Phase 0 maintenance gate runs after DHCP/network reconciliation'
    Assert-True ($requiredMaintenanceCalls[0].Extent.StartOffset -gt $phase0DispatchCalls[0].Extent.EndOffset) 'Phase 0 maintenance gate runs after Phase 0 existing-VM preparation'
    Assert-True ($requiredMaintenanceCalls[0].Extent.EndOffset -lt $phaseLoopDispatchCalls[0].Extent.StartOffset) 'Phase 0 maintenance gate runs before Phase 1 dispatch'
    Assert-True ($requiredMaintenanceCalls[0].Extent.Text -match '(?i)-OwnedMutexVmNames') 'Phase 0 maintenance gate accounts for mutexes the deployment already owns'

    # The gate must be clearly logged as belonging to Phase 0, not a generic/unlabeled step.
    $gateLogWindowStart = $phase0DispatchCalls[0].Extent.EndOffset
    $gateLogWindowEnd = $requiredMaintenanceCalls[0].Extent.StartOffset
    $gateLogWindowText = $newLabAst.Extent.Text.Substring($gateLogWindowStart, $gateLogWindowEnd - $gateLogWindowStart)
    Assert-True ($gateLogWindowText -match '(?i)\[Phase 0\].*maintenance') 'Phase 0 maintenance gate is logged with an explicit Phase 0 tag'

    $gateOffsetEnd = $requiredMaintenanceCalls[0].Extent.EndOffset
    $enclosingIf = $newLabAst.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.StartOffset -ge $gateOffsetEnd -and
            $node.Extent.StartOffset -lt ($gateOffsetEnd + 400)
        }, $true)
    Assert-True ($null -ne $enclosingIf) 'Phase 0 maintenance gate is immediately followed by a failure check'
    if ($enclosingIf) {
        $exitsInGate = @($enclosingIf.FindAll({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true))
        Assert-True ($exitsInGate.Count -ge 1) 'Phase 0 maintenance gate aborts the deployment when required maintenance fails'
        Assert-True ($enclosingIf.Extent.Text -match '(?i)\[Phase 0\]') 'Phase 0 maintenance gate failure is logged with an explicit Phase 0 tag'
    }
}
# Every maintenance-related call in New-Lab must occur at or after GenConfig returns.
$preGenConfigMaintenanceCalls = @(($standaloneMaintenanceCalls + $requiredMaintenanceCalls) | Where-Object {
        $genConfigCalls.Count -eq 0 -or $_.Extent.StartOffset -lt $genConfigCalls[0].Extent.EndOffset
    })
Assert-Equal 0 $preGenConfigMaintenanceCalls.Count 'no maintenance of any kind runs before GenConfig'

$maintAst = Get-TestAst -Path (Join-Path $RootPath 'common\Common.Maintenance.ps1')
$interactiveMaintenanceFn = @($maintAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-Maintenance'
        }, $true))
Assert-Equal 1 $interactiveMaintenanceFn.Count 'Common.Maintenance still defines the interactive Start-Maintenance entry point'
if ($interactiveMaintenanceFn.Count -eq 1) {
    Assert-True ($interactiveMaintenanceFn[0].Extent.Text -match '(?i)Read-YesOrNoWithTimeout') 'menu-invoked maintenance stays interactive (still prompts)'
}

$requiredMaintenanceFn = @($maintAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-RequiredExistingVMMaintenance'
        }, $true))
Assert-Equal 1 $requiredMaintenanceFn.Count 'Common.Maintenance defines the Phase 0 mandatory existing-VM maintenance function'
if ($requiredMaintenanceFn.Count -eq 1) {
    $requiredFnText = $requiredMaintenanceFn[0].Extent.Text
    Assert-True ($requiredFnText -match '(?i)Get-VM\s+-ErrorAction\s+Stop') 'Phase 0 maintenance enumerates live Hyper-V inventory fail-closed (ErrorAction Stop)'
    Assert-True ($requiredFnText -match '(?s)catch\s*\{[^}]*Get-VM.{0,10}$|catch\s*\{.{0,400}return\s+\$false') 'Phase 0 maintenance returns $false, not silent success, when live inventory cannot be enumerated'
    Assert-True ($requiredFnText -match '(?i)\$liveVmNameSet\.ContainsKey\(\$_\.vmName\)') 'Phase 0 maintenance targets every DeployConfig VM that already exists in live Hyper-V inventory'
    Assert-True ($requiredFnText -notmatch '(?i)\$_\.ExistingVM') 'Phase 0 maintenance no longer filters by the ExistingVM marker'
    Assert-True ($requiredFnText -notmatch '(?i)-not\s+\$_\.hidden') 'Phase 0 maintenance no longer excludes hidden entries'
    Assert-True ($requiredFnText -match '(?i)AppliesToRoles') 'Phase 0 maintenance documents per-fix role applicability (AppliesToRoles/NotAppliesToRoles)'
    Assert-True ($requiredFnText -match '(?i)Windows/Linux') 'Phase 0 maintenance documents Windows/Linux applicability'
    Assert-True ($requiredFnText -match '(?i)offline-root') 'Phase 0 maintenance documents offline-root-CA applicability'
    Assert-True ($requiredFnText -match '(?i)not applicable.{0,40}(is a )?successful no-op|successful no-op.{0,60}not a (gate )?failure') 'Phase 0 maintenance documents that an inapplicable fix/VM is a successful no-op, not a gate failure'
    Assert-True ($requiredFnText -match '(?i)AppliesToExisting') 'Phase 0 maintenance applies AppliesToExisting fixes'
    Assert-True ($requiredFnText -notmatch '(?i)NeededOnFreshDeploy') 'Phase 0 maintenance does not use fresh-deploy-only fix semantics'
    Assert-True ($requiredFnText -notmatch '(?i)Read-YesOrNoWithTimeout') 'Phase 0 maintenance never prompts and cannot be declined'
    Assert-True ($requiredFnText -match '(?i)OwnedMutexVmNames') 'Phase 0 maintenance accounts for mutexes the deployment already owns'
    Assert-True ($requiredFnText -match '(?i)result\.Failed\s+-gt\s+0') 'Phase 0 maintenance reports failure back to the caller'
    Assert-True ($requiredFnText -match '\[Phase 0\]') 'Phase 0 maintenance function logs with an explicit Phase 0 tag'
    Assert-True ($requiredFnText -match '(?i)Phase 0 maintenance') 'Phase 0 maintenance function documents itself as Phase 0 maintenance'
    Assert-True ($requiredFnText -match "(?i)not.{0,10}yet exist.{0,160}Phase 1|Phase 1.{0,40}creates? (it|them)") 'Phase 0 maintenance documents that not-yet-created VMs continue through DSC/Phase 10 once Phase 1 creates them'
    Assert-True ($requiredFnText -notmatch '(?i)dependency-only.{0,60}wait for Phase 10|dependency-only.{0,60}Phase 10.{0,60}already exist') 'Phase 0 maintenance does not claim already-existing dependency-only VMs wait for Phase 10'

    # Mandatory-gate mutex semantics: a required target found in use by another
    # operation must fail the gate outright, never be logged as "skipping" and
    # then folded back into a $true success.
    $inUseElsewhereMatch = [regex]::Match($requiredFnText, '(?s)\$inUseElsewhere\.Count\s+-gt\s+0\)\s*\{(.*?)\}')
    Assert-True $inUseElsewhereMatch.Success 'Phase 0 maintenance has an explicit in-use-elsewhere failure branch'
    if ($inUseElsewhereMatch.Success) {
        Assert-True ($inUseElsewhereMatch.Groups[1].Value -match '-Failure') 'in-use-elsewhere required target is logged as a failure, not a warning/skip'
        Assert-True ($inUseElsewhereMatch.Groups[1].Value -match 'return\s+\$false') 'in-use-elsewhere required target makes the mandatory gate return $false'
    }
    Assert-True ($requiredFnText -notmatch '(?i)skipping VM\(s\) already in use') 'Phase 0 maintenance no longer logs in-use-elsewhere targets as a skip'

    # Dispatch/accounting fail-closed semantics: Start-NormalJobs.Failed counts
    # VMs whose job never got created at all, so they never appear in .Jobs and
    # Wait-Phase can never see or report them. The gate must reject that silent
    # gap instead of only trusting Wait-Phase's own Failed counter.
    Assert-True ($requiredFnText -match '(?i)\$start\.Failed\s+-gt\s+0') 'Phase 0 maintenance checks Start-NormalJobs dispatch failures before trusting Wait-Phase'
    $dispatchFailBlockMatch = [regex]::Match($requiredFnText, '(?s)\$start\.Failed\s+-gt\s+0\)\s*\{(.*?)\}')
    Assert-True $dispatchFailBlockMatch.Success 'Phase 0 maintenance has an explicit dispatch-failure branch'
    if ($dispatchFailBlockMatch.Success) {
        Assert-True ($dispatchFailBlockMatch.Groups[1].Value -match '-Failure') 'a dispatch failure is logged as a failure'
        Assert-True ($dispatchFailBlockMatch.Groups[1].Value -match 'return\s+\$false') 'a dispatch failure makes the mandatory gate return $false'
    }
    Assert-True ($requiredFnText -match '(?i)\$start\.Failed') 'Phase 0 maintenance checks Start-NormalJobs.Failed at all (previously ignored)'
    $waitPhaseCallSiteMatch = [regex]::Match($requiredFnText, '\$result\s*=\s*Wait-Phase\b')
    $dispatchFailCheckIndex = $requiredFnText.IndexOf('$start.Failed -gt 0')
    Assert-True ($dispatchFailCheckIndex -ge 0 -and $waitPhaseCallSiteMatch.Success -and $dispatchFailCheckIndex -lt $waitPhaseCallSiteMatch.Index) 'the dispatch-failure check runs before Wait-Phase is called, not after'
    Assert-True ($requiredFnText -match '(?i)\$accountedFor\s*=\s*\$result\.Success\s*\+\s*\$result\.Failed') 'Phase 0 maintenance tallies Wait-Phase Success+Failed into an accounted-for total'
    Assert-True ($requiredFnText -match '(?i)\$accountedFor\s+-ne\s+\$start\.Jobs\.Count') 'Phase 0 maintenance verifies the accounted-for total matches every dispatched job'
    Assert-True ($requiredFnText -match '(?i)\$accountedFor\s+-ne\s+\$expectedJobCount') 'Phase 0 maintenance verifies the accounted-for total matches every required target'
    $accountingBlockMatch = [regex]::Match($requiredFnText, '(?s)\$accountedFor\s+-ne\s+\$start\.Jobs\.Count.{0,120}\{(.*?)\}')
    Assert-True $accountingBlockMatch.Success 'Phase 0 maintenance has an explicit accounting-mismatch failure branch'
    if ($accountingBlockMatch.Success) {
        Assert-True ($accountingBlockMatch.Groups[1].Value -match '-Failure') 'an accounting mismatch is logged as a failure'
        Assert-True ($accountingBlockMatch.Groups[1].Value -match 'return\s+\$false') 'an accounting mismatch makes the mandatory gate return $false'
    }
}

$dhcpApplianceAst = Get-TestAst -Path (Join-Path $RootPath 'common\Common.DhcpAppliance.ps1')
$readinessFn = @($dhcpApplianceAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Confirm-MemLabsDhcpReadiness'
        }, $true))
Assert-Equal 1 $readinessFn.Count 'Common.DhcpAppliance defines the shared DHCP-readiness helper'
if ($readinessFn.Count -eq 1) {
    $readinessText = $readinessFn[0].Extent.Text
    Assert-True ($readinessText -match '(?i)Test-MemLabsUsesDhcpAppliance') 'DHCP readiness distinguishes appliance mode from native DHCP'
    Assert-True ($readinessText -match '(?i)Sync-MemLabsDhcpAppliance') 'DHCP readiness reconciles the appliance when in use'
    Assert-True ($readinessText -match '(?i)DHCPServer') 'DHCP readiness ensures the native DHCP Server role otherwise'
}
# New-Lab.ps1 performs the equivalent DHCP-readiness logic inline (its own
# pre-existing appliance-reconcile-or-native-service-check block) rather than
# calling the shared helper -- only the GenConfig menu action calls it.
$newLabReadinessCalls = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Confirm-MemLabsDhcpReadiness'
        }, $true))
Assert-Equal 0 $newLabReadinessCalls.Count 'New-Lab does not call Confirm-MemLabsDhcpReadiness (it has its own equivalent inline DHCP-readiness logic)'

$genConfigMainAst = Get-TestAst -Path (Join-Path $RootPath 'genconfig.ps1')
$pendingMaintenanceFn = @($genConfigMainAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Select-PendingVMMaintenance'
        }, $true))
Assert-Equal 1 $pendingMaintenanceFn.Count 'GenConfig defines the Apply Pending VM Maintenance menu action'
if ($pendingMaintenanceFn.Count -eq 1) {
    $dhcpReadinessCall = @($pendingMaintenanceFn[0].FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Confirm-MemLabsDhcpReadiness'
            }, $true))
    $interactiveMaintenanceCall = @($pendingMaintenanceFn[0].FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Maintenance'
            }, $true))
    Assert-Equal 1 $dhcpReadinessCall.Count 'menu action reconciles DHCP/networking'
    Assert-Equal 1 $interactiveMaintenanceCall.Count 'menu action starts interactive (opt-in) maintenance'
    if ($dhcpReadinessCall.Count -eq 1 -and $interactiveMaintenanceCall.Count -eq 1) {
        Assert-True ($dhcpReadinessCall[0].Extent.EndOffset -lt $interactiveMaintenanceCall[0].Extent.StartOffset) 'menu action reconciles networking before starting maintenance'
    }
}
$genConfigMainText = Get-Content -LiteralPath (Join-Path $RootPath 'genconfig.ps1') -Raw
Assert-True ($genConfigMainText -match '(?i)"A"\s*=\s*"Apply Pending VM Maintenance') 'main menu exposes the Apply Pending VM Maintenance option'
Assert-True ($genConfigMainText -match '(?im)"a"\s*\{\s*Select-PendingVMMaintenance\s*\}') 'main menu routes "a" to the maintenance action'

$storageAst = Get-TestAst -Path (Join-Path $RootPath 'common\Common.StorageToken.ps1')
. (Import-TestFunction -Ast $storageAst -Name 'Get-MemlabsVmStorageRoot')
$script:HostSettingsMode = 'Unset'
$script:MalformedPersistedSetting = "C:\bad$([char]0)path"
$script:HostSettingWrites = 0
function Get-MemlabsHostSettings {
    if ($script:HostSettingsMode -eq 'Invalid') {
        return [pscustomobject]@{ vmStorageRoot = 'Q:\Missing\VirtualMachines' }
    }
    if ($script:HostSettingsMode -eq 'Malformed') {
        return [pscustomobject]@{ vmStorageRoot = $script:MalformedPersistedSetting }
    }
    return $null
}
function Set-MemlabsHostSetting { param($Name, $Value); $script:HostSettingWrites++ }
function Get-MemlabsEligibleStorageDrives {
    return @([pscustomobject]@{ DriveLetter = 'C'; FreeSpace = 200GB; Size = 512GB })
}
function Write-Log { param($Message, [switch] $Warning) }

$savedStorageOverride = $env:MEMLABS_VM_STORAGE_ROOT
try {
    Remove-Item Env:MEMLABS_VM_STORAGE_ROOT -ErrorAction SilentlyContinue
    $null = Get-MemlabsVmStorageRoot -ReadOnly
    Assert-Equal 0 $script:HostSettingWrites 'read-only storage resolution does not persist an unset default'
    $script:HostSettingsMode = 'Invalid'
    $unavailableSavedRoot = Get-MemlabsVmStorageRoot -ReadOnly
    Assert-Equal $null $unavailableSavedRoot 'read-only storage resolution does not replace an unavailable saved root'
    Assert-Equal 0 $script:HostSettingWrites 'read-only storage resolution does not replace an unavailable saved root'
    $script:HostSettingsMode = 'Malformed'
    $malformedResolution = Get-MemlabsVmStorageRoot -ReadOnly
    Assert-Equal $null $malformedResolution 'read-only storage resolution rejects a malformed persisted root'
    Assert-Equal 0 $script:HostSettingWrites 'read-only storage resolution does not replace a malformed persisted root'
}
finally {
    if ($null -eq $savedStorageOverride) { Remove-Item Env:MEMLABS_VM_STORAGE_ROOT -ErrorAction SilentlyContinue }
    else { $env:MEMLABS_VM_STORAGE_ROOT = $savedStorageOverride }
}

$healthAst = Get-TestAst -Path (Join-Path $RootPath 'common\Common.Health.ps1')
foreach ($functionName in 'Get-HealthStats', 'Get-HealthThresholdColor', 'Write-HealthBar', 'Write-HealthStatusIcon', 'Check-OverallHealth') {
    . (Import-TestFunction -Ast $healthAst -Name $functionName)
}

$script:RealStorageResolver = ${function:Get-MemlabsVmStorageRoot}
$script:UseRealStorageResolver = $false
$script:StorageRoot = 'C:\VirtualMachines'
$script:RequestedDrive = $null
$script:NoPromptRequested = $false
$script:ReadOnlyRequested = $false
$script:RenderedText = [Text.StringBuilder]::new()
function Get-MemlabsVmStorageRoot {
    param([switch] $NoPrompt, [switch] $ReadOnly)
    $script:NoPromptRequested = $NoPrompt.IsPresent
    $script:ReadOnlyRequested = $ReadOnly.IsPresent
    if ($script:UseRealStorageResolver) {
        return & $script:RealStorageResolver -NoPrompt:$NoPrompt -ReadOnly:$ReadOnly
    }
    return $script:StorageRoot
}
function Get-Volume {
    [CmdletBinding()]
    param([string] $DriveLetter)
    $script:RequestedDrive = $DriveLetter
    return [pscustomobject]@{ Size = 512GB; SizeRemaining = 200GB }
}
function Get-CimInstance {
    param([Parameter(Position = 0)][string] $ClassName)
    return [pscustomobject]@{ FreePhysicalMemory = 19MB; TotalVisibleMemorySize = 64MB }
}
function Get-Uptime { return [TimeSpan]::FromHours(1) }
function Get-List { param($Type, [switch] $SmartUpdate); return @() }
function Get-PendingVMs { return @() }
function Get-Date { return [datetime]'2026-09-09T12:00:00' }
function Write-Host {
    param([Parameter(Position = 0)] $Object = '', [switch] $NoNewline, [string] $ForegroundColor)
    [void]$script:RenderedText.Append([string]$Object)
    if (-not $NoNewline) { [void]$script:RenderedText.AppendLine() }
}
function Write-Host2 {
    param([Parameter(Position = 0)] $Object = '', [switch] $NoNewline, [string] $ForegroundColor)
    Write-Host $Object -NoNewline:$NoNewline
}

$Global:HealthStatsCache = $null
$Global:HealthStatsCacheTTLSeconds = 20
$stats = Get-HealthStats -Force
Assert-True $script:NoPromptRequested 'Quick Stats storage resolution cannot prompt during menu rendering'
Assert-True $script:ReadOnlyRequested 'Quick Stats storage resolution cannot change host settings'
Assert-Equal 'C' $script:RequestedDrive 'Quick Stats queries the Windows Client VM-storage drive'
Assert-Equal 'C' $stats.DiskDriveLetter 'Quick Stats retains the VM-storage drive letter'
Assert-Equal 200 $stats.DiskFreeGB 'Quick Stats reads free space from the VM-storage drive'
Assert-Equal 512 $stats.DiskTotalGB 'Quick Stats reads total space from the VM-storage drive'

$script:RenderedText.Clear() | Out-Null
Check-OverallHealth
$rendered = $script:RenderedText.ToString()
Assert-True $rendered.Contains('Disk C:') 'Quick Stats labels the Windows Client VM-storage drive'
Assert-True $rendered.Contains('19/64GB Free') 'Quick Stats identifies the memory ratio as free RAM'

$script:StorageRoot = 'F:\MemLabs\VirtualMachines'
$script:RequestedDrive = $null
$Global:HealthStatsCache = $null
$stats = Get-HealthStats -Force
Assert-Equal 'F' $script:RequestedDrive 'Quick Stats follows a configured alternate VM-storage drive'
Assert-Equal 'F' $stats.DiskDriveLetter 'Quick Stats labels a configured alternate VM-storage drive'
$script:RenderedText.Clear() | Out-Null
Check-OverallHealth
Assert-True $script:RenderedText.ToString().Contains('Disk F:') 'Quick Stats renders a configured alternate VM-storage drive'

foreach ($unsupportedRoot in @('relative\VirtualMachines', '\\server\share\VirtualMachines', '\\?\C:\VirtualMachines', ("C:\bad$([char]0)path"))) {
    $script:StorageRoot = $unsupportedRoot
    $script:RequestedDrive = $null
    $Global:HealthStatsCache = $null
    $stats = Get-HealthStats -Force
    Assert-Equal $null $script:RequestedDrive "unsupported storage root does not query a volume: $unsupportedRoot"
    Assert-Equal $false $stats.DiskAvailable "unsupported storage root is marked unavailable: $unsupportedRoot"
    $script:RenderedText.Clear() | Out-Null
    Check-OverallHealth
    $unsupportedRendered = $script:RenderedText.ToString()
    Assert-True $unsupportedRendered.Contains('unavailable') "unsupported storage root renders unavailable: $unsupportedRoot"
    Assert-Equal $false $unsupportedRendered.Contains('0/0GB') "unsupported storage root does not claim zero capacity: $unsupportedRoot"
}

$script:UseRealStorageResolver = $true
$script:HostSettingsMode = 'Malformed'
$script:RequestedDrive = $null
$Global:HealthStatsCache = $null
$malformedPersistedStats = Get-HealthStats -Force
Assert-Equal $null $script:RequestedDrive 'malformed persisted root does not reach Get-Volume through the real resolver'
Assert-Equal $false $malformedPersistedStats.DiskAvailable 'malformed persisted root is unavailable through the real resolver'
$script:RenderedText.Clear() | Out-Null
Check-OverallHealth
$malformedPersistedRendered = $script:RenderedText.ToString()
Assert-True $malformedPersistedRendered.Contains('unavailable') 'malformed persisted root renders unavailable through the real resolver'
Assert-Equal $false $malformedPersistedRendered.Contains('0/0GB') 'malformed persisted root does not claim zero capacity through the real resolver'

$invalidPathChars = @([System.IO.Path]::GetInvalidPathChars() | Sort-Object { [int]$_ } -Unique)
[Console]::WriteLine("invalid persisted path inputs : $($invalidPathChars.Count)")
Assert-True ($invalidPathChars.Count -gt 0) 'invalid persisted path matrix has applicable inputs'
$resolverFailures = [Collections.Generic.List[string]]::new()
$healthFailures = [Collections.Generic.List[string]]::new()
foreach ($invalidPathChar in $invalidPathChars) {
    $codePoint = 'U+{0:X4}' -f [int]$invalidPathChar
    $script:MalformedPersistedSetting = "C:\bad${invalidPathChar}path"
    try {
        $resolvedRoot = & $script:RealStorageResolver -NoPrompt -ReadOnly
        if ($null -ne $resolvedRoot) { $resolverFailures.Add("$codePoint returned '$resolvedRoot'") }
    }
    catch {
        $resolverFailures.Add("$codePoint threw $($_.Exception.GetType().Name)")
    }

    $script:RequestedDrive = $null
    $Global:HealthStatsCache = $null
    try {
        $invalidStats = Get-HealthStats -Force
        if ($null -ne $script:RequestedDrive) { $healthFailures.Add("$codePoint queried $script:RequestedDrive") }
        if ($invalidStats.DiskAvailable) { $healthFailures.Add("$codePoint reported available") }
    }
    catch {
        $healthFailures.Add("$codePoint threw $($_.Exception.GetType().Name)")
    }
}
Assert-Equal '' ($resolverFailures -join '; ') 'real resolver rejects every platform-defined invalid path character'
Assert-Equal '' ($healthFailures -join '; ') 'Quick Stats handles every platform-defined invalid persisted path character'

if ($script:Failures) {
    [Console]::WriteLine("$script:Failures check(s) failed.")
    exit 1
}
[Console]::WriteLine("All GenConfig host-summary checks passed ($script:Assertions assertions).")