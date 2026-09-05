<#
.SYNOPSIS
    Mocked host/SSH boundary tests for Sync-LinuxDhcpRelay.
#>
[CmdletBinding()]
param ([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}
function Import-TestFunction {
    param ([string] $Path, [string] $Name)
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}

$linuxPath = Join-Path $RootPath 'common\Common.Linux.ps1'
. (Import-TestFunction $linuxPath 'Test-LinuxDhcpRelayAddressAvailable')
. (Import-TestFunction $linuxPath 'Sync-LinuxDhcpRelay')
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
. (Import-TestFunction $validationPath 'Test-LinuxDhcpRelay')

$script:Adapters = @()
$script:AddCalls = 0
$script:Events = @()
$script:Reservation = @()
$script:Lease = @()
$script:Neighbor = @()
$script:LastClientVariables = $null
$script:ServicePayload = $null
$script:ValidationPayload = $null
$script:ResolverCalls = 0
$script:ResolvedPaths = @()

function Reset-Fixture {
    param ([switch] $WithClient, [switch] $DuplicateClient)
    $script:AddCalls = 0
    $script:Events = @()
    $script:Reservation = @()
    $script:Lease = @()
    $script:Neighbor = @()
    $script:LastClientVariables = $null
    $script:ServicePayload = $null
    $script:ValidationPayload = $null
    $script:ResolverCalls = 0
    $script:Adapters = @([pscustomobject]@{
            Name = 'Network Adapter'; SwitchName = '192.168.1.0'; MacAddress = '00155D010001'; IPAddresses = @('192.168.1.4')
        })
    if ($WithClient) {
        $script:Adapters += [pscustomobject]@{
            Name = 'DHCPRelay-192.168.3.0'; SwitchName = '192.168.3.0'; MacAddress = '00155D030004'; IPAddresses = @('192.168.3.4')
        }
    }
    if ($DuplicateClient) {
        $script:Adapters += [pscustomobject]@{
            Name = 'DHCPRelay-duplicate'; SwitchName = '192.168.3.0'; MacAddress = '00155D030005'; IPAddresses = @()
        }
    }
}

function New-FixtureConfig {
    param ([switch] $NoActivePath, [switch] $StalePendingPath)
    $relay = [pscustomobject]@{
        vmName = 'RELAY1'; role = 'DHCPRelay'; osFamily = 'Linux'; operatingSystem = 'Ubuntu Server 24.04 LTS'
        network = '192.168.1.0'; relayMappings = @()
    }
    $paths = @()
    if (-not $NoActivePath) {
        $targetIp = '192.168.1.25'
        if ($StalePendingPath) { $targetIp = $null }
        $paths += [pscustomobject]@{
            clientNetwork = '192.168.3.0'; mode = 'Relay'; relayVM = 'RELAY1'; relayIPv4 = '192.168.3.4'
            distributionPointVM = 'DP1'; distributionPointNetwork = '192.168.1.0'
            distributionPointSiteCode = 'PS1'; distributionPointIPv4 = $targetIp
        }
    }
    $script:ResolvedPaths = @($paths | ForEach-Object {
            $resolvedPath = $_.PSObject.Copy()
            if ($resolvedPath.mode -eq 'Relay') { $resolvedPath.distributionPointIPv4 = '192.168.1.25' }
            $resolvedPath
        })
    [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'example.test'; network = '192.168.1.0' }
        virtualMachines = @($relay)
        osdPxePaths = @($paths)
    }
}

function Get-OsdEffectiveNetwork { param($VM, $Config) if ($VM.network) { $VM.network } else { $Config.vmOptions.network } }
function Get-OsdPxePaths {
    $script:ResolverCalls++
    return @($script:ResolvedPaths)
}
function Get-VM2 { [CmdletBinding()] param($Name); return [pscustomobject]@{ Name = 'RELAY1'; State = 'Running' } }
function Start-VM2 { return $true }
function Get-VM { [CmdletBinding()] param(); return @([pscustomobject]@{ Name = 'RELAY1'; State = 'Running' }) }
function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$VM)
    process { return @($script:Adapters) }
}
function Get-DhcpServerv4Reservation { [CmdletBinding()] param($ScopeId); return @($script:Reservation) }
function Get-DhcpServerv4Lease { [CmdletBinding()] param($ScopeId); return @($script:Lease) }
function Get-NetNeighbor { [CmdletBinding()] param($IPAddress); return @($script:Neighbor) }
function Test-Connection { [CmdletBinding()] param($ComputerName, $Count, [switch] $Quiet); return $script:Neighbor.Count -gt 0 }
function Get-VMSwitch { [CmdletBinding()] param($Name); return [pscustomobject]@{ Name = $Name } }
function Get-DhcpServerv4Scope { [CmdletBinding()] param($ScopeId); return [pscustomobject]@{ ScopeId = $ScopeId } }
function Add-Phase11Output { param($Text, $Level) }
function Add-VMNetworkAdapter {
    [CmdletBinding()]
    param($VMName, $SwitchName, $Name)
    $script:Events += 'add'
    $script:AddCalls++
    $script:Adapters += [pscustomobject]@{
        Name = $Name; SwitchName = $SwitchName; MacAddress = '00155D030004'; IPAddresses = @()
    }
}
function Get-LinuxScript {
    param($Name, $Variables)
    if ($Name -eq 'relay/configure-client-interface') {
        $script:LastClientVariables = $Variables
    }
    if ($Name -eq 'relay/configure-dhcp-relay') {
        $script:ServicePayload = $Variables.RELAY_MAPPINGS_B64
    }
    if ($Name -eq 'relay/validate-dhcp-relay') {
        $script:ValidationPayload = $Variables.EXPECTED_MAPPINGS_B64
    }
    return "SCRIPT:$Name"
}
function Invoke-LinuxVmCommand {
    param($VmName, $IPAddress, $BashCommand, $DisplayName, $TimeoutSeconds, [switch]$Sudo, [switch]$SuppressLog)
    if ($BashCommand -eq 'test -f /var/lib/memlabs/relay-network-schema && echo RELAY_NETWORK_SCHEMA_READY') {
        return [pscustomobject]@{ CommandResult = $true; ScriptBlockOutput = 'RELAY_NETWORK_SCHEMA_READY' }
    }
    if ($BashCommand -eq 'SCRIPT:relay/prepare-management-network') {
        $script:Events += 'prepare'
        return [pscustomobject]@{ CommandResult = $true; ScriptBlockOutput = 'management profile ready: eth0 192.168.1.4/24 via 192.168.1.200 MAC=00:15:5d:01:00:01' }
    }
    if ($BashCommand -eq 'SCRIPT:relay/configure-client-interface') {
        $script:Events += 'configure-client'
        return [pscustomobject]@{ CommandResult = $true; ScriptBlockOutput = 'RELAY_INTERFACE_READY=eth7|192.168.3.4|00:15:5d:03:00:04|changed=1' }
    }
    if ($BashCommand -eq 'SCRIPT:relay/configure-dhcp-relay') {
        $script:Events += 'service'
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ServicePayload))
        $marker = if ($decoded) { '[dhcp-relay] relay configuration is ready (1 mapping(s)); UDP/67 listener validated' } else { '[dhcp-relay] zero active mappings; service stopped' }
        return [pscustomobject]@{ CommandResult = $true; ScriptBlockOutput = $marker }
    }
    if ($BashCommand -eq 'SCRIPT:relay/validate-dhcp-relay') {
        return [pscustomobject]@{ CommandResult = $true; ScriptBlockOutput = 'DHCP_RELAY_CONFIGURATION_READY mappings=1 management=eth0/192.168.1.4' }
    }
    return [pscustomobject]@{ CommandResult = $true; ScriptBlockOutput = '' }
}
function Write-Log { param($Message, [switch]$Activity, [switch]$Success, [switch]$Warning) }

Write-Host "engine : $($PSVersionTable.PSVersion)"

Reset-Fixture
$script:Reservation = @([pscustomobject]@{
    IPAddress = [pscustomobject]@{ IPAddressToString = '192.168.1.4' }
    Name = ''
    ClientId = '00-15-5D-01-00-01'
})
$ownReservation = Test-LinuxDhcpRelayAddressAvailable -IPAddress '192.168.1.4' -Network '192.168.1.0' `
    -RelayVmName 'RELAY1' -DeployConfig (New-FixtureConfig)
Assert-Equal $true $ownReservation.Available 'blank-name reservation for the exact relay adapter MAC is not a conflict'

Reset-Fixture
$script:Reservation = @([pscustomobject]@{
    IPAddress = [pscustomobject]@{ IPAddressToString = '192.168.1.4' }
    Name = ''
    ClientId = '00-15-5D-01-00-99'
})
$foreignReservation = Test-LinuxDhcpRelayAddressAvailable -IPAddress '192.168.1.4' -Network '192.168.1.0' `
    -RelayVmName 'RELAY1' -DeployConfig (New-FixtureConfig)
Assert-Equal $false $foreignReservation.Available 'blank-name reservation for a different MAC remains a conflict'
Assert-Equal $true ($foreignReservation.Reason -like '*00-15-5D-01-00-99*') 'unnamed reservation diagnostic identifies its ClientId'

Reset-Fixture
$script:Lease = @([pscustomobject]@{
    IPAddress = [pscustomobject]@{ IPAddressToString = '192.168.1.4' }
    HostName = ''
    ClientId = '00-15-5D-01-00-01'
})
$ownLease = Test-LinuxDhcpRelayAddressAvailable -IPAddress '192.168.1.4' -Network '192.168.1.0' `
    -RelayVmName 'RELAY1' -DeployConfig (New-FixtureConfig)
Assert-Equal $true $ownLease.Available 'blank-hostname lease for the exact relay adapter MAC is not a conflict'

Reset-Fixture
$script:Lease = @([pscustomobject]@{
    IPAddress = [pscustomobject]@{ IPAddressToString = '192.168.1.4' }
    HostName = ''
    ClientId = '00-15-5D-01-00-99'
})
$foreignLease = Test-LinuxDhcpRelayAddressAvailable -IPAddress '192.168.1.4' -Network '192.168.1.0' `
    -RelayVmName 'RELAY1' -DeployConfig (New-FixtureConfig)
Assert-Equal $false $foreignLease.Available 'blank-hostname lease for a different MAC remains a conflict'
Assert-Equal $true ($foreignLease.Reason -like '*00-15-5D-01-00-99*') 'unnamed lease diagnostic identifies its ClientId'

Reset-Fixture
$script:Neighbor = @([pscustomobject]@{
    State = 'Reachable'
    LinkLayerAddress = '00-15-5D-01-00-01'
})
$ownNeighbor = Test-LinuxDhcpRelayAddressAvailable -IPAddress '192.168.1.4' -Network '192.168.1.0' `
    -RelayVmName 'RELAY1' -DeployConfig (New-FixtureConfig)
Assert-Equal $true $ownNeighbor.Available 'reachable neighbor for the exact relay adapter MAC is not a conflict'

Reset-Fixture
$script:Neighbor = @([pscustomobject]@{
    State = 'Reachable'
    LinkLayerAddress = '00-15-5D-01-00-99'
})
$foreignNeighbor = Test-LinuxDhcpRelayAddressAvailable -IPAddress '192.168.1.4' -Network '192.168.1.0' `
    -RelayVmName 'RELAY1' -DeployConfig (New-FixtureConfig)
Assert-Equal $false $foreignNeighbor.Available 'reachable neighbor for a different MAC remains a conflict'
Assert-Equal $true ($foreignNeighbor.Reason -like '*00-15-5D-01-00-99*') 'foreign neighbor diagnostic identifies its MAC'

Reset-Fixture
$config = New-FixtureConfig -StalePendingPath
Assert-Equal $true (Sync-LinuxDhcpRelay -DeployConfig $config) 'missing relay NIC reconciles successfully'
Assert-Equal 1 $script:ResolverCalls 'reconciliation refreshes a serialized pending target IPv4 from current metadata'
Assert-Equal '192.168.1.25' $config.osdPxePaths[0].distributionPointIPv4 'refreshed PXE path replaces stale serialized state'
Assert-Equal 1 $script:AddCalls 'missing relay NIC is added exactly once'
Assert-Equal 'prepare,add,configure-client,service' ($script:Events -join ',') 'management handoff completes before hot-add and service restart'
Assert-Equal '00155D030004' $script:LastClientVariables.CLIENT_MAC 'guest configuration is keyed by captured Hyper-V MAC'
Assert-Equal "eth7|192.168.3.4|192.168.1.25`n" ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ServicePayload))) 'service mapping is LF-terminated so Bash reads the final row'
$null = Sync-LinuxDhcpRelay -DeployConfig $config
Assert-Equal 1 $script:AddCalls 'rerun does not add a second relay NIC'

Reset-Fixture -WithClient
$null = Sync-LinuxDhcpRelay -DeployConfig (New-FixtureConfig)
Assert-Equal 0 $script:AddCalls 'matching relay NIC is a no-op'

Reset-Fixture -WithClient
$validationConfig = New-FixtureConfig
Assert-Equal $true (Test-LinuxDhcpRelay -VMName 'RELAY1' -CurrentItem $validationConfig.virtualMachines[0] -DeployConfig $validationConfig) 'Phase 11 relay validation accepts one configured mapping'
Assert-Equal "00155D030004|192.168.3.4|192.168.1.25`n" ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ValidationPayload))) 'Phase 11 expected mapping is LF-terminated so Bash reads the final row'
$validatorSource = Get-Content (Join-Path $RootPath 'scripts\linux\relay\validate-dhcp-relay.sh') -Raw
Assert-Equal $true ($validatorSource.Contains("read -r expected_mac expected_ip expected_target extra || [ -n")) 'validator defensively processes an unterminated final row'

Reset-Fixture -WithClient -DuplicateClient
$duplicateFailed = $false
try { $null = Sync-LinuxDhcpRelay -DeployConfig (New-FixtureConfig) } catch {
    $duplicateError = $_.Exception.Message
    $duplicateFailed = $duplicateError -like '*duplicate adapters*'
}
Assert-Equal $true $duplicateFailed 'duplicate adapters on one client switch fail closed'
if (-not $duplicateFailed) { Write-Host "      exception: $duplicateError" }

Reset-Fixture
$script:Reservation = @([pscustomobject]@{
        IPAddress = [pscustomobject]@{ IPAddressToString = '192.168.3.4' }; Name = 'CONFLICT'
    })
$conflictFailed = $false
try { $null = Sync-LinuxDhcpRelay -DeployConfig (New-FixtureConfig) } catch { $conflictFailed = $_.Exception.Message -like '*address conflict*' }
Assert-Equal $true $conflictFailed '.4 conflict fails reconciliation'
Assert-Equal 0 $script:AddCalls '.4 conflict fails before NIC mutation'

Reset-Fixture -WithClient
$null = Sync-LinuxDhcpRelay -DeployConfig (New-FixtureConfig -NoActivePath)
Assert-Equal '' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ServicePayload))) 'zero active mappings sends empty desired state to stop service'
Assert-Equal 0 $script:AddCalls 'zero active mappings does not add a NIC'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All Linux DHCP relay reconciler checks passed.'
