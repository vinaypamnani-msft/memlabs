# Focused dual-engine tests for the adaptive host-memory reserve.
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-NumericEqual {
    param([double] $Expected, [double] $Actual, [string] $What)
    $passed = [Math]::Abs($Expected - $Actual) -lt 0.001
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Assert-True {
    param([bool] $Actual, [string] $What)
    if (-not $Actual) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Actual) { 'PASS' } else { 'FAIL' }), $What)
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

$script:AvailableMemoryMB = 20 * 1024
$script:VMs = @()
function Get-Counter {
    [pscustomobject]@{
        CounterSamples = @([pscustomobject]@{ CookedValue = $script:AvailableMemoryMB })
    }
}

$script:CimMode = 'ComputerSystem'
function Get-CimInstance {
    param([string] $ClassName)
    if ($script:CimMode -eq 'Unavailable') { throw 'CIM unavailable' }
    if ($ClassName -eq 'Win32_ComputerSystem') {
        if ($script:CimMode -eq 'OperatingSystem') { throw 'ComputerSystem unavailable' }
        if ($script:CimMode -eq 'ZeroThenUnavailable') { return [pscustomobject]@{ TotalPhysicalMemory = 0 } }
        return [pscustomobject]@{ TotalPhysicalMemory = 32GB }
    }
    if ($ClassName -eq 'Win32_OperatingSystem') {
        if ($script:CimMode -eq 'ZeroThenUnavailable') { throw 'OperatingSystem unavailable' }
        return [pscustomobject]@{ TotalVisibleMemorySize = 32GB / 1KB }
    }
    throw "Unexpected CIM class: $ClassName"
}

function Get-VM { return $script:VMs }

$commonPath = Join-Path $RootPath 'Common.ps1'
. (Import-TestFunction -Path $commonPath -Name 'Get-HostMemoryReserveGB')
. (Import-TestFunction -Path $commonPath -Name 'Get-AvailableMemoryGB')
Write-Host "engine : $($PSVersionTable.PSVersion)"

Assert-NumericEqual 2.4 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 16GB) '16GB host reserves 15 percent'
Assert-NumericEqual 4.8 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 32GB) '32GB host reserves 15 percent'
Assert-NumericEqual 7.95 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 53GB) '53GB host remains below the cap'
Assert-NumericEqual 8 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 54GB) '54GB host reaches the 8GB cap'
Assert-NumericEqual 8 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 64GB) '64GB host reserve is capped at 8GB'
Assert-NumericEqual 8 (Get-HostMemoryReserveGB -TotalPhysicalMemoryBytes 128GB) '128GB host keeps the existing 8GB cap'
Assert-NumericEqual 15.2 (Get-AvailableMemoryGB) 'deployable memory subtracts the adaptive 4.8GB reserve'
$script:CimMode = 'OperatingSystem'
Assert-NumericEqual 4.8 (Get-HostMemoryReserveGB) 'operating-system memory is used when computer-system CIM fails'
$script:CimMode = 'Unavailable'
Assert-NumericEqual 8 (Get-HostMemoryReserveGB) 'existing 8GB reserve is retained when CIM is unavailable'
$script:CimMode = 'ZeroThenUnavailable'
Assert-NumericEqual 8 (Get-HostMemoryReserveGB) 'zero total memory falls back to the existing 8GB reserve'

$phaseSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Phases.ps1') -Raw
$configSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Config.ps1') -Raw
$validationSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Validation.ps1') -Raw
Assert-True ($phaseSource.Contains('$hostReserveGB = Get-HostMemoryReserveGB')) 'Phase 1 uses the shared adaptive reserve'
Assert-True (-not $phaseSource.Contains('$hostReserveGB = 8')) 'Phase 1 no longer has a fixed reserve'
Assert-True ($configSource.Contains('[after 15% host reserve, capped at 8GB]')) 'configuration summary describes the adaptive reserve'
Assert-True ($validationSource.Contains('[15% host reserve, capped at 8GB]')) 'validation warning describes the adaptive reserve'

. (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.Config.ps1') -Name 'Show-Summary')
$script:SummaryMessages = [Collections.Generic.List[object]]::new()
function Write-GreenCheck {
    param([string] $Text, [switch] $NoNewLine)
    $script:SummaryMessages.Add([pscustomobject]@{ Text = $Text; Warning = $false })
}
function Write-OrangePoint {
    param([string] $Text)
    $script:SummaryMessages.Add([pscustomobject]@{ Text = $Text; Warning = $true })
}
function Write-RedX { param([string] $Text) }
function Write-Host2 { param([string] $Text, [switch] $NoNewLine, [string] $ForegroundColor) }
function Write-WhiteI { param([string] $Text, [int] $Indent) }
function Get-List { param([string] $Type) return @() }
function Test-VmIsLinux { param($Vm) return $false }

function Get-TestMemorySummary {
    param([object[]] $VirtualMachines)

    $script:SummaryMessages.Clear()
    $deployConfig = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'lab.test'; network = '192.168.2.0' }
        cmOptions = [pscustomobject]@{ install = $false }
        parameters = [pscustomobject]@{ ExistingDCName = 'LAB-DC' }
        virtualMachines = $VirtualMachines
    }
    Show-Summary -deployConfig $deployConfig 6>$null
    $messages = @($script:SummaryMessages | Where-Object { $_.Text -like 'This configuration will use *' })
    if ($messages.Count -ne 1) { throw "Expected one RAM summary, found $($messages.Count)." }
    return $messages[0]
}

$global:Common = [pscustomobject]@{
    DevBranch = $true
    supported = [pscustomobject]@{ PropsToUpdate = @('memory', 'dynamicMinRam') }
}
$script:CimMode = 'ComputerSystem'
$existingVMs = @(
    [pscustomobject]@{ vmName = 'LAB-CLIENT1'; hidden = $true; role = 'DomainMember'; memory = '4GB' }
    [pscustomobject]@{ vmName = 'LAB-CLIENT2'; hidden = $true; role = 'DomainMember'; memory = '4GB' }
)
$script:VMs = @(
    [pscustomobject]@{ Name = 'LAB-CLIENT1'; State = 'Running'; MemoryAssigned = 2GB }
    [pscustomobject]@{ Name = 'LAB-CLIENT2'; State = 'Running'; MemoryAssigned = 2GB }
)
$summary = Get-TestMemorySummary -VirtualMachines $existingVMs
Assert-True ($summary.Text.Contains('use 8GB (4GB already running; 4GB additional)')) 'two existing VMs increased from 2GB to 4GB include their 4GB RAM increase'
Assert-True (-not $summary.Warning) 'existing-VM RAM increases fit when sufficient deployable memory remains'

$script:AvailableMemoryMB = 8.8 * 1024
$summary = Get-TestMemorySummary -VirtualMachines $existingVMs
Assert-True (-not $summary.Warning) 'existing allocations are credited when the RAM increase exactly fits'
$script:AvailableMemoryMB = 8.79 * 1024
$summary = Get-TestMemorySummary -VirtualMachines $existingVMs
Assert-True $summary.Warning 'a RAM increase 0.01GB above deployable capacity warns'

$script:AvailableMemoryMB = 20 * 1024
$newVM = [pscustomobject]@{ vmName = 'LAB-NEW'; role = 'DomainMember'; memory = '3GB'; virtualProcs = 2 }
$summary = Get-TestMemorySummary -VirtualMachines ($existingVMs + @($newVM))
Assert-True ($summary.Text.Contains('use 11GB (4GB already running; 7GB additional)')) 'mixed configurations include new VM RAM plus existing VM RAM increases'

$script:VMs = @([pscustomobject]@{ Name = 'LAB-CLIENT1'; State = 'Running'; MemoryAssigned = 1GB })
$summary = Get-TestMemorySummary -VirtualMachines @($existingVMs[0])
Assert-True ($summary.Text.Contains('use 4GB (1GB already running; 3GB additional)')) 'dynamic-memory VMs credit actual assigned RAM rather than their requested maximum'

$script:VMs = @([pscustomobject]@{ Name = 'LAB-CLIENT1'; State = 'Off'; MemoryAssigned = 0 })
$summary = Get-TestMemorySummary -VirtualMachines @($existingVMs[0])
Assert-True ($summary.Text.Contains('use 4GB out of 15.2GB')) 'stopped existing VMs require their full requested RAM'

$script:VMs = @([pscustomobject]@{ Name = 'LAB-CLIENT1'; State = 'Running'; MemoryAssigned = 6GB })
$summary = Get-TestMemorySummary -VirtualMachines @($existingVMs[0])
Assert-True ($summary.Text.Contains('use 4GB (6GB already running; 0GB additional)')) 'RAM reductions never report a negative additional requirement'

$script:VMs = @()
$summary = Get-TestMemorySummary -VirtualMachines @($newVM)
Assert-True ($summary.Text.Contains('use 3GB out of 15.2GB')) 'new-only configurations retain their existing RAM summary'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All host-memory reserve checks passed.'