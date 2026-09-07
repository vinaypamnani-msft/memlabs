#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $RootPath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptPath))
}
$script:Failures = [Collections.Generic.List[string]]::new()
$script:FailureMessages = @()
function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    if ("$Expected" -ne "$Actual") {
        $script:Failures.Add("$Name -- expected '$Expected', got '$Actual'")
    }
    else { Write-Host "  PASS: $Name" -ForegroundColor Green }
}
function Assert-True {
    param([bool] $Value, [string] $Name)
    Assert-Equal $true $Value $Name
}
function Write-Log {
    param([Parameter(Position = 0)]$Message, [switch]$LogOnly, [switch]$Activity, [switch]$Warning, [switch]$Failure, [switch]$Success)
    if ($Failure) { $script:FailureMessages += "$Message" }
}

function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Could not parse ${Path}: $($errors[0].Message)" }
    $functionAst = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Function '$Name' not found in $Path" }
    return [scriptblock]::Create($functionAst.Extent.Text)
}

$modulePath = Join-Path $RootPath 'vmbuild\common\Common.DhcpAppliance.ps1'
. $modulePath

function Get-Service { throw 'native DHCP service discovery is forbidden on Windows Client' }
function Get-Module { throw 'native DHCP module discovery is forbidden on Windows Client' }
$client = Get-MemLabsDhcpBackend -ProductType 1 -HyperVAvailable $true
Assert-Equal 'Client' $client.HostType 'ProductType 1 selects Client'
Assert-Equal 'DnsmasqAppliance' $client.BackendType 'Client selects appliance backend'
Assert-Equal $false $client.NativeDhcpAvailable 'Client skips unsupported native DHCP discovery'

$server = Get-MemLabsDhcpBackend -ProductType 3 -HyperVAvailable $true -NativeDhcpAvailable $true
Assert-Equal 'Server' $server.HostType 'ProductType 3 selects Server'
Assert-Equal 'WindowsDhcp' $server.BackendType 'Server selects native backend'
Assert-Equal $true (Test-MemLabsVmStorageDriveAllowed -DriveLetter C -HostType Client) 'Client host allows C for VM storage'
Assert-Equal $false (Test-MemLabsVmStorageDriveAllowed -DriveLetter C -HostType Server) 'Server host rejects C for VM storage'
Assert-Equal $false (Test-MemLabsVmStorageDriveAllowed -DriveLetter D -HostType Client) 'Client host still rejects reserved D drive'
Assert-Equal $false (Test-MemLabsVmStorageDriveAllowed -DriveLetter Z -HostType Client) 'Client host still rejects reserved Z drive'
Assert-Equal $true (Test-MemLabsVmStorageDriveAllowed -DriveLetter E -HostType Server) 'Server host allows normal data drives'

$dcNote = [pscustomobject]@{
    lastUpdate = '09/06/2026 00:00'
    role = 'DC'; domain = 'example.test'; network = '192.168.44.0'
    AssignedIP = '192.168.44.1'
} | ConvertTo-Json -Compress
$clientNote = [pscustomobject]@{
    lastUpdate = '09/06/2026 00:00'
    role = 'DomainMember'; domain = 'example.test'; network = '192.168.44.0'
    AssignedIP = '192.168.44.25'
} | ConvertTo-Json -Compress
$internetNote = [pscustomobject]@{
    lastUpdate = '09/06/2026 00:00'
    role = 'InternetClient'; domain = 'WORKGROUP'; network = '192.168.44.0'
    AssignedIP = '172.31.250.30'
} | ConvertTo-Json -Compress
$infraNote = [pscustomobject]@{
    lastUpdate = '09/06/2026 00:00'
    infrastructureType = 'MemLabsDhcpAppliance'; ownedScopeIds = @('192.168.44.0')
} | ConvertTo-Json -Compress
$live = @(
    [pscustomobject]@{ Name = 'LAB-DC1'; Notes = $dcNote; NetworkAdapters = @([pscustomobject]@{ SwitchName = '192.168.44.0'; MacAddress = '00155D440001'; IPAddresses = @('192.168.44.1') }) },
    [pscustomobject]@{ Name = 'LAB-W11'; Notes = $clientNote; NetworkAdapters = @([pscustomobject]@{ SwitchName = '192.168.44.0'; MacAddress = '00155D440025'; IPAddresses = @('192.168.44.25') }) },
    [pscustomobject]@{ Name = 'INET-W11'; Notes = $internetNote; NetworkAdapters = @([pscustomobject]@{ SwitchName = 'Internet'; MacAddress = '00155DFA0030'; IPAddresses = @('172.31.250.30') }) },
    [pscustomobject]@{ Name = 'MemLabs-DHCP-01'; Notes = $infraNote; NetworkAdapters = @([pscustomobject]@{ SwitchName = '192.168.44.0'; MacAddress = '00155D44FF19'; IPAddresses = @('192.168.44.19') }) }
)
$desired = Get-MemLabsDhcpDesiredState -LiveVMs $live
Assert-Equal 2 @($desired.Scopes).Count 'VM notes reconstruct two scopes'
$domainScope = @($desired.Scopes | Where-Object ScopeId -eq '192.168.44.0')[0]
$internetScope = @($desired.Scopes | Where-Object ScopeId -eq '172.31.250.0')[0]
Assert-Equal '192.168.44.1' $domainScope.DnsServers[0] 'DC note reconstructs domain DNS option'
Assert-Equal '192.168.44.200' $domainScope.Router 'domain router is host .200'
Assert-Equal 1 @($domainScope.Reservations).Count 'only in-pool domain address becomes reservation'
Assert-Equal '00:15:5d:44:00:25' $domainScope.Reservations[0].MacAddress 'reservation MAC is normalized'
Assert-Equal 'Internet' $internetScope.SwitchName 'Internet subnet maps to named switch'
Assert-Equal 1 @($internetScope.Reservations).Count 'Internet reservation reconstructed'
Assert-True (-not (@($desired.Scopes.Reservations.VMName) -contains 'MemLabs-DHCP-01')) 'infrastructure VM is excluded from reservations'

$addToExisting = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ network = '192.168.55.0'; domainName = 'example.test' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'LAB-DC1'; role = 'DC'; hidden = $true }
        [pscustomobject]@{ vmName = 'NEW-MEMBER'; role = 'DomainMember'; network = '192.168.55.0' }
    )
}
$addToExistingDesired = Get-MemLabsDhcpDesiredState -DeployConfig $addToExisting -LiveVMs $live
$newSubnetScope = @($addToExistingDesired.Scopes | Where-Object ScopeId -eq '192.168.55.0')[0]
Assert-Equal '192.168.44.1' $newSubnetScope.DnsServers[0] 'hidden existing DC cannot replace live domain DNS with the new default subnet'
Assert-Equal '172.31.250.0,192.168.44.0,192.168.55.0' (@($addToExistingDesired.Scopes | ForEach-Object { $_.ScopeId }) -join ',') 'ordered-dictionary scopes use stable lexical ordering'

$conflictNote = [pscustomobject]@{
    lastUpdate = '09/06/2026 00:00'; role = 'DomainMember'; domain = 'example.test'
    network = '192.168.44.0'; AssignedIP = '192.168.44.19'
} | ConvertTo-Json -Compress
$conflictVm = [pscustomobject]@{ Name = 'CONFLICT'; Notes = $conflictNote; NetworkAdapters = @() }
$conflictThrown = $false
try { $null = Get-MemLabsDhcpDesiredState -LiveVMs @($live + $conflictVm) } catch { $conflictThrown = $_.Exception.Message -like '*address conflict*' }
Assert-True $conflictThrown 'non-appliance VM at reserved .19 blocks reconciliation'

$deploy = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ network = '192.168.55.0'; domainName = 'new.test' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'NEW-DC1'; role = 'DC' },
        [pscustomobject]@{ vmName = 'NEW-W11'; role = 'DomainMember' },
        [pscustomobject]@{ vmName = 'NEW-W10'; role = 'DomainMember' },
        [pscustomobject]@{ vmName = 'NEW-OSD'; role = 'OSDClient' }
    )
}
$null = Set-DnsmasqDeployConfigIPAddresses -DeployConfig $deploy -LiveVMs @()
Assert-Equal '192.168.55.1' $deploy.virtualMachines[0].AssignedIP 'DC receives fixed .1'
Assert-Equal '192.168.55.20' $deploy.virtualMachines[1].AssignedIP 'first dynamic VM receives .20'
Assert-Equal '192.168.55.21' $deploy.virtualMachines[2].AssignedIP 'second dynamic VM receives .21'
Assert-True (-not $deploy.virtualMachines[3].PSObject.Properties['AssignedIP']) 'OSD client remains dynamic'

$rerunNote = [pscustomobject]@{
    lastUpdate = '09/06/2026 00:00'; role = 'DomainMember'; domain = 'new.test'
    network = '192.168.55.0'; AssignedIP = '192.168.55.77'
} | ConvertTo-Json -Compress
$rerunLive = @([pscustomobject]@{
    Name = 'NEW-EXISTING'; Notes = $rerunNote
    NetworkAdapters = @([pscustomobject]@{ SwitchName = '192.168.55.0'; MacAddress = '00155D550077'; IPAddresses = @() })
})
$rerunDeploy = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ network = '192.168.55.0'; domainName = 'new.test' }
    virtualMachines = @([pscustomobject]@{ vmName = 'NEW-EXISTING'; role = 'DomainMember' })
}
$null = Set-DnsmasqDeployConfigIPAddresses -DeployConfig $rerunDeploy -LiveVMs $rerunLive
Assert-Equal '192.168.55.77' $rerunDeploy.virtualMachines[0].AssignedIP 'rerun reuses AssignedIP from VM note'

# Execute the Client branches lifted from Common.ps1. Native DHCP access is a
# throwing sentinel: any accidental fall-through fails the test immediately.
$commonPath = Join-Path $RootPath 'vmbuild\Common.ps1'
. (Import-TestFunction -Path $commonPath -Name 'Start-DHCP')
. (Import-TestFunction -Path $commonPath -Name 'Add-SwitchAndDhcp')
. (Import-TestFunction -Path $commonPath -Name 'Get-DHCPReservationIPForMac')
. (Import-TestFunction -Path $commonPath -Name 'Set-DeployConfigIPAddresses')
$global:Common = [pscustomobject]@{ DhcpBackend = $client }
function Get-Service { throw 'native DHCP service access is forbidden in Client routing test' }
function Test-NetworkSwitch { param($NetworkName, $NetworkSubnet, $DomainName); $script:SwitchCall = "$NetworkName|$NetworkSubnet|$DomainName"; return $true }
function Get-MemLabsDhcpReservationIpForMac { param($ScopeId, $Mac); return "$ScopeId|$Mac" }
$script:AllocatorCalls = 0
function Set-DnsmasqDeployConfigIPAddresses { param($DeployConfig); $script:AllocatorCalls++; return $true }

Assert-Equal $true (Start-DHCP) 'Start-DHCP is a successful native-service-free Client no-op'
Assert-Equal $true (Add-SwitchAndDhcp -NetworkName '192.168.66.0' -NetworkSubnet '192.168.66.0' -DomainName 'route.test') 'network entry point routes Client to switch/NAT only'
Assert-Equal '192.168.66.0|00155D660020' (Get-DHCPReservationIPForMac -ScopeId '192.168.66.0' -Mac '00155D660020') 'reservation lookup routes to appliance provider'
$null = Set-DeployConfigIPAddresses -DeployConfig ([pscustomobject]@{})
Assert-Equal 0 $script:AllocatorCalls 'Phase 1 rejects a missing default network before appliance allocation'
Assert-True ([bool]($script:FailureMessages -like '*No default network*')) 'missing default network reports an actionable failure'
$validClientDeploy = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ network = '192.168.66.0' }
    virtualMachines = @()
}
$phaseOutput = @(Set-DeployConfigIPAddresses -DeployConfig $validClientDeploy)
Assert-Equal 1 $script:AllocatorCalls 'Phase 1 allocation routes to appliance allocator once'
Assert-Equal 0 $phaseOutput.Count 'Phase 1 appliance allocation does not pollute Start-Phase output'

$serverScriptPath = Join-Path $RootPath 'vmbuild\scripts\linux\dhcp\configure-dhcp-server.sh'
$serverScript = Get-Content -LiteralPath $serverScriptPath -Raw
Assert-True ($serverScript -match '"port=0"') 'appliance DNS service is disabled'
Assert-True ($serverScript -match '"dhcp-authoritative"') 'appliance is authoritative on isolated scopes'
Assert-True ($serverScript -match '"dhcp-ignore-clid"') 'PXE/full-OS leases are keyed by MAC'
Assert-True ($serverScript -match 'reserved_macs' -and $serverScript -match 'reserved_ips') 'reservation reconciliation evicts stale leases by MAC and IP'
Assert-True ($serverScript -match 'DHCP_LISTENING' -and $serverScript -match 'seq 1 20') 'appliance waits for UDP 67 after service startup'
Assert-True ($serverScript -notmatch '(?m)^[^#\r\n]*(enable-tftp|dhcp-boot|pxe-service|dhcp-range=.*proxy)') 'appliance does not claim TFTP or proxy-PXE duties'
$reservationScript = Get-Content -LiteralPath (Join-Path $RootPath 'vmbuild\scripts\linux\dhcp\update-reservation.sh') -Raw
Assert-True ($reservationScript -match 'reserved_mac' -and $reservationScript -match 'reserved_ip') 'direct reservation updates evict stale leases by MAC and IP'

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "  FAIL: $_" -ForegroundColor Red }
    throw "$($script:Failures.Count) DHCP appliance backend test(s) failed."
}
Write-Host 'DHCP appliance backend tests passed.' -ForegroundColor Cyan
