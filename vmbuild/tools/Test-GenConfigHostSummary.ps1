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