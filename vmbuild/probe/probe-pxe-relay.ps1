<#
.SYNOPSIS
    Captures one cross-subnet ConfigMgr PXE attempt from the Hyper-V host.

.DESCRIPTION
    Resolves an authored DHCPRelay path from a MemLabs deploy configuration,
    then writes a bounded evidence bundle under vmbuild\logs\pxe-relay-probe.
    The bundle contains:
      - DHCP scope options and lease data for the client subnet
      - host adapter addresses, routes, forwarding, NAT, and firewall profiles
      - a filtered Packet Monitor ETL/PCAPNG covering DHCP and all DP traffic
      - ConfigMgr DP PXE services, UDP listeners, firewall rules, routes,
        SMSPXE.log tail, and a point-in-time copy of the full SMSPXE.log
      - relay addresses, routes, dnsmasq config, listeners, and service journal

    The probe does not change DHCP, routing, the relay, or the DP. Packet
    Monitor filters are process-global, so capture is skipped rather than
    disturbing filters that existed before the probe. Filters created by this
    script are removed in finally. Use -RestartClientVM only when it is safe to
    hard-restart the selected disposable OSD client.

.PARAMETER ConfigPath
    Deploy config JSON. If omitted, the newest logs\VMBuild.*.config.json that
    contains one relay PXE path is used.

.PARAMETER ClientIPAddress
    Optional current PXE client address. If omitted, the probe tries the OSD
    VM's DHCP lease. The client subnet and DP are always captured regardless.

.PARAMETER CaptureSeconds
    Packet capture duration. Default 90 seconds.

.PARAMETER ClientVMName
    Optional OSDClient VM override when more than one client uses the subnet.

.PARAMETER RelayVMName
    Optional DHCPRelay VM filter when the config contains multiple relay paths.

.PARAMETER DPVMName
    Optional target distribution-point VM filter.

.PARAMETER RestartClientVM
    Hard-restart the selected OSDClient immediately after capture begins.

.PARAMETER NoPacketCapture
    Collect state and logs without starting Packet Monitor.

.EXAMPLE
    .\probe\probe-pxe-relay.ps1 -ConfigPath .\config\fabrikam.com-PRI-2509-9VMs.json -ClientIPAddress 192.168.3.20 -RestartClientVM
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $ClientIPAddress,
    [ValidateRange(15, 600)] [int] $CaptureSeconds = 90,
    [string] $ClientVMName,
    [string] $RelayVMName,
    [string] $DPVMName,
    [switch] $RestartClientVM,
    [switch] $NoPacketCapture
)

$ErrorActionPreference = 'Stop'
$vmbuildRoot = Split-Path -Parent $PSScriptRoot
Set-Location $vmbuildRoot
$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
. $commonPath -FastInit

function Test-CredLoaded {
    return ($Common -and $Common.LocalAdmin -and $Common.LocalAdmin.Password)
}
if (-not (Test-CredLoaded) -and (Get-Command Get-LocalAdminCredential -ErrorAction SilentlyContinue)) {
    if ($Common) { $Common.Initialized = $false }
    try { $null = Get-LocalAdminCredential } catch {}
}
if (-not (Test-CredLoaded)) {
    if ($Common) { $Common.Initialized = $false }
    . $commonPath
}
if (-not (Test-CredLoaded)) {
    throw 'MemLabs local administrator credential could not be loaded; guest evidence cannot be collected.'
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string] $Path, [AllowEmptyString()][string] $Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-SafeJson {
    param($InputObject, [int] $Depth = 8)
    try { return ($InputObject | ConvertTo-Json -Depth $Depth) }
    catch { return (@{ Error = $_.Exception.Message } | ConvertTo-Json) }
}

function Add-ReportLine {
    param([string] $Text = '')
    Write-Host $Text
    $script:Report.Add($Text)
}

function Get-NativeText {
    param([string] $FilePath, [string[]] $ArgumentList)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = ($output -join "`r`n") }
}

function Resolve-ConfigPath {
    param([string] $RequestedPath)
    if ($RequestedPath) {
        $resolved = Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop
        return $resolved.Path
    }

    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $vmbuildRoot 'logs') -Filter 'VMBuild.*.config.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    foreach ($candidate in $candidates) {
        try {
            $probeConfig = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json
            if (@($probeConfig.virtualMachines | Where-Object { $_.role -eq 'DHCPRelay' }).Count -gt 0 -and
                @($probeConfig.virtualMachines | Where-Object { $_.role -eq 'OSDClient' }).Count -gt 0) {
                return $candidate.FullName
            }
        }
        catch {}
    }
    throw 'ConfigPath was omitted and no synchronized deploy config containing DHCPRelay plus OSDClient was found.'
}

function Resolve-ActualVmName {
    param([string] $Name, [object] $Config)
    if (-not $Name) { return $null }
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { return $Name }
    $prefix = "$($Config.vmOptions.prefix)"
    if ($prefix -and $Name -notlike "$prefix*") {
        $prefixed = "$prefix$Name"
        if (Get-VM -Name $prefixed -ErrorAction SilentlyContinue) { return $prefixed }
    }
    return $Name
}

function Get-HostNetworkSnapshot {
    param([string] $ClientSubnet, [string] $DpSubnet, [string] $ClientIP, [string] $DpIP)
    $errors = [System.Collections.Generic.List[string]]::new()
    $scope = $null
    $options = @()
    $leases = @()
    try { $scope = Get-DhcpServerv4Scope -ScopeId $ClientSubnet -ErrorAction Stop }
    catch { $errors.Add("DHCP scope: $($_.Exception.Message)") }
    try { $options = @(Get-DhcpServerv4OptionValue -ScopeId $ClientSubnet -ErrorAction Stop | Select-Object OptionId, Name, Type, Value) }
    catch { $errors.Add("DHCP options: $($_.Exception.Message)") }
    try {
        $leases = @(Get-DhcpServerv4Lease -ScopeId $ClientSubnet -ErrorAction Stop |
            Where-Object { -not $ClientIP -or "$($_.IPAddress.IPAddressToString)" -eq $ClientIP } |
            Select-Object IPAddress, HostName, ClientId, AddressState, LeaseExpiryTime)
    }
    catch { $errors.Add("DHCP leases: $($_.Exception.Message)") }

    $aliases = @("vEthernet ($ClientSubnet)", "vEthernet ($DpSubnet)")
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -in $aliases } |
        Select-Object Name, InterfaceAlias, InterfaceIndex, Status, MacAddress, LinkSpeed)
    $interfaces = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -in $aliases } |
        Select-Object InterfaceAlias, InterfaceIndex, ConnectionState, Forwarding, Dhcp, InterfaceMetric)
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -in $aliases } |
        Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState)
    $prefixes = @("$ClientSubnet/24", "$DpSubnet/24", '0.0.0.0/0')
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -in $prefixes -or $_.InterfaceAlias -in $aliases } |
        Sort-Object DestinationPrefix, RouteMetric |
        Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, State)
    $nats = @(Get-NetNat -ErrorAction SilentlyContinue |
        Where-Object { $_.InternalIPInterfaceAddressPrefix -in @("$ClientSubnet/24", "$DpSubnet/24") -or $_.Name -in @($ClientSubnet, $DpSubnet) } |
        Select-Object Name, InternalIPInterfaceAddressPrefix, Active)
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -in $aliases } |
        Select-Object InterfaceAlias, NetworkCategory, IPv4Connectivity)

    return [pscustomobject]@{
        CollectedUtc = [DateTime]::UtcNow.ToString('o')
        ClientSubnet = $ClientSubnet
        DpSubnet = $DpSubnet
        ClientIP = $ClientIP
        DpIP = $DpIP
        DhcpScope = $scope
        DhcpOptions = $options
        DhcpLeases = $leases
        Adapters = $adapters
        IPInterfaces = $interfaces
        IPAddresses = $addresses
        Routes = $routes
        Nats = $nats
        Profiles = $profiles
        Errors = @($errors)
    }
}

$dpCollector = {
    param($ClientIP, $ClientSubnet, $Stamp, $MakeLogSnapshot)
    $ErrorActionPreference = 'Continue'
    $errors = [System.Collections.Generic.List[string]]::new()
    $services = @(Get-Service -Name 'SccmPxe', 'WDSServer' -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType)
    $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 67, 68, 69, 4011 } |
        Select-Object LocalAddress, LocalPort, OwningProcess)
    $processes = @()
    foreach ($endpoint in $udp) {
        $processes += @(Get-Process -Id $endpoint.OwningProcess -ErrorAction SilentlyContinue |
            Select-Object Id, ProcessName, Path)
    }
    $routes = @()
    try {
        if ($ClientIP) {
            $routes += @(Find-NetRoute -RemoteIPAddress $ClientIP -ErrorAction Stop |
                Select-Object IPAddress, InterfaceAlias, NextHop, RouteMetric)
        }
        $routes += @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq "$ClientSubnet/24" } |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric)
    }
    catch { $errors.Add("Route lookup: $($_.Exception.Message)") }

    $firewall = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -match 'PXE|TFTP|BINL' -or $_.DisplayGroup -match 'Configuration Manager'
            })) {
        $ports = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue |
            Select-Object Protocol, LocalPort, RemotePort)
        $apps = @(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue |
            Select-Object Program)
        $firewall.Add([pscustomobject]@{
                DisplayName = $rule.DisplayName; Enabled = $rule.Enabled; Direction = $rule.Direction
                Action = $rule.Action; Profile = $rule.Profile; Ports = $ports; Applications = $apps
            })
    }

    $logCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $candidate = "$($drive.Root)SMS_DP`$\sms\logs\SMSPXE.log"
        if (Test-Path -LiteralPath $candidate) { $logCandidates.Add($candidate) }
    }
    foreach ($candidate in @(
            'C:\Program Files\Microsoft Configuration Manager\Logs\SMSPXE.log',
            'C:\Windows\CCM\Logs\SMSPXE.log')) {
        if (Test-Path -LiteralPath $candidate) { $logCandidates.Add($candidate) }
    }
    $smsPxePath = @($logCandidates | Select-Object -Unique) | Select-Object -First 1
    $snapshotPath = $null
    $tail = @()
    if ($smsPxePath) {
        try {
            $tail = @(Get-Content -LiteralPath $smsPxePath -Tail 500 -ErrorAction Stop)
            if ($MakeLogSnapshot) {
                $snapshotPath = Join-Path $env:TEMP "MemLabs-PXEProbe-SMSPXE-$Stamp.log"
                $source = [System.IO.File]::Open($smsPxePath, 'Open', 'Read', 'ReadWrite')
                try {
                    $destination = [System.IO.File]::Open($snapshotPath, 'Create', 'Write', 'None')
                    try { $source.CopyTo($destination) } finally { $destination.Dispose() }
                }
                finally { $source.Dispose() }
            }
        }
        catch { $errors.Add("SMSPXE snapshot: $($_.Exception.Message)") }
    }
    else { $errors.Add('SMSPXE.log was not found on any local filesystem drive.') }

    return [pscustomobject]@{
        CollectedUtc = [DateTime]::UtcNow.ToString('o')
        ComputerName = $env:COMPUTERNAME
        Services = $services
        UdpListeners = $udp
        ListenerProcesses = @($processes | Sort-Object Id -Unique)
        RoutesToClient = $routes
        FirewallRules = @($firewall)
        SmsPxePath = $smsPxePath
        SmsPxeSnapshotPath = $snapshotPath
        SmsPxeTail = $tail
        Errors = @($errors)
    }
}

function Get-DpSnapshot {
    param([string] $VmName, [string] $Domain, [string] $ClientIP, [string] $ClientSubnet, [string] $Stamp, [bool] $MakeLogSnapshot)
    try {
        $session = Get-VmSession -VmName $VmName -VmDomainName $Domain
        if (-not $session) { throw 'Get-VmSession returned no session.' }
        return Invoke-Command -Session $session -ScriptBlock $dpCollector -ArgumentList $ClientIP, $ClientSubnet, $Stamp, $MakeLogSnapshot -ErrorAction Stop
    }
    catch { return [pscustomobject]@{ CollectedUtc = [DateTime]::UtcNow.ToString('o'); Errors = @($_.Exception.Message) } }
}

function Get-RelaySnapshot {
    param([string] $VmName, [string] $IPAddress)
    $command = @'
set -u
section() { printf '\n===== %s =====\n' "$1"; }
section identity; hostname; date -u --iso-8601=seconds
section addresses; ip -4 -o address show
section routes; ip -4 route show table all
section rules; ip rule show
section forwarding; sysctl net.ipv4.ip_forward
section dnsmasq-config; cat /etc/memlabs-dhcp-relay.conf 2>&1
section listeners; ss -H -lunp
section service; systemctl status memlabs-dhcp-relay.service --no-pager 2>&1
section journal; journalctl -u memlabs-dhcp-relay.service -b --no-pager -n 300 2>&1
'@
    try {
        $result = Invoke-LinuxVmCommand -VmName $VmName -IPAddress $IPAddress -BashCommand $command -Sudo -TimeoutSeconds 120 -SuppressLog -DisplayName 'PXE relay probe'
        return [pscustomobject]@{
            CommandResult = $result.CommandResult
            ExitCode = $result.ExitCode
            Output = "$($result.ScriptBlockOutput)"
        }
    }
    catch { return [pscustomobject]@{ CommandResult = $false; ExitCode = $null; Output = $_.Exception.Message } }
}

$ConfigPath = Resolve-ConfigPath -RequestedPath $ConfigPath
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$domain = "$($config.vmOptions.domainName)"
$paths = @(Get-OsdPxePaths -Config $config | Where-Object { $_.mode -eq 'Relay' })
if ($RelayVMName) { $paths = @($paths | Where-Object { $_.relayVM -eq $RelayVMName }) }
if ($DPVMName) { $paths = @($paths | Where-Object { $_.distributionPointVM -eq $DPVMName }) }
if ($paths.Count -ne 1) {
    $found = @($paths | ForEach-Object { "$($_.clientNetwork):$($_.relayVM)->$($_.distributionPointVM)/$($_.distributionPointIPv4)" }) -join '; '
    throw "Expected exactly one relay PXE path after filters; found $($paths.Count): $found"
}
$path = $paths[0]
$clientSubnet = "$($path.clientNetwork)"
$dpSubnet = "$($path.distributionPointNetwork)"
$dpIP = "$($path.distributionPointIPv4)"
$relayVm = Resolve-ActualVmName -Name $(if ($RelayVMName) { $RelayVMName } else { "$($path.relayVM)" }) -Config $config
$dpVm = Resolve-ActualVmName -Name $(if ($DPVMName) { $DPVMName } else { "$($path.distributionPointVM)" }) -Config $config

$clientCandidates = @($config.virtualMachines | Where-Object {
        $_.role -eq 'OSDClient' -and (Get-OsdEffectiveNetwork -VM $_ -Config $config) -eq $clientSubnet
    })
if ($ClientVMName) { $clientCandidates = @($clientCandidates | Where-Object { $_.vmName -eq $ClientVMName }) }
if ($clientCandidates.Count -lt 1) { throw "No OSDClient was resolved on relay subnet $clientSubnet." }
$clientVm = Resolve-ActualVmName -Name "$($clientCandidates[0].vmName)" -Config $config

foreach ($networkValue in @($clientSubnet, $dpSubnet)) {
    $parsedNetwork = $null
    if (-not [System.Net.IPAddress]::TryParse($networkValue, [ref]$parsedNetwork) -or
        $parsedNetwork.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parsedNetwork.GetAddressBytes()[3] -ne 0) {
        throw "Relay topology contains unsupported /24 network ID '$networkValue'."
    }
}
$parsedDpIP = $null
if (-not [System.Net.IPAddress]::TryParse($dpIP, [ref]$parsedDpIP) -or
    $parsedDpIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "Relay topology has no usable DP IPv4 address ('$dpIP')."
}
foreach ($vmCheck in @(
        @{ Role = 'OSD client'; Name = $clientVm },
        @{ Role = 'relay'; Name = $relayVm },
        @{ Role = 'DP'; Name = $dpVm }
    )) {
    if (-not (Get-VM -Name $vmCheck.Name -ErrorAction SilentlyContinue)) {
        throw "$($vmCheck.Role) VM '$($vmCheck.Name)' does not exist on this Hyper-V host."
    }
}

$relayConfigVm = $config.virtualMachines | Where-Object { $_.vmName -eq "$($path.relayVM)" } | Select-Object -First 1
$relayNetwork = Get-OsdEffectiveNetwork -VM $relayConfigVm -Config $config
$relayManagementIP = "$relayNetwork" -replace '\.0$', '.4'

if (-not $ClientIPAddress) {
    try {
        $clientAdapter = Get-VMNetworkAdapter -VMName $clientVm -ErrorAction Stop | Where-Object { $_.SwitchName -eq $clientSubnet } | Select-Object -First 1
        $clientMac = "$($clientAdapter.MacAddress)" -replace '[-:]', ''
        $lease = Get-DhcpServerv4Lease -ScopeId $clientSubnet -ErrorAction Stop | Where-Object {
            ("$($_.ClientId)" -replace '[-:]', '') -eq $clientMac
        } | Select-Object -First 1
        if ($lease) { $ClientIPAddress = "$($lease.IPAddress.IPAddressToString)" }
    }
    catch {}
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$domainTag = if ($domain) { $domain -replace '[^A-Za-z0-9.-]', '_' } else { 'unknown-domain' }
$destRoot = Join-Path $vmbuildRoot "logs\pxe-relay-probe\$domainTag-$stamp"
New-Item -Path $destRoot -ItemType Directory -Force | Out-Null
$script:Report = [System.Collections.Generic.List[string]]::new()
$reportPath = Join-Path $destRoot 'summary.txt'

Add-ReportLine 'MemLabs cross-subnet PXE relay probe'
Add-ReportLine "Collected       : $(Get-Date -Format o)"
Add-ReportLine "Config          : $ConfigPath"
Add-ReportLine "Domain          : $domain"
Add-ReportLine "Client VM       : $clientVm"
Add-ReportLine "Client subnet/IP: $clientSubnet / $(if ($ClientIPAddress) { $ClientIPAddress } else { '<not resolved>' })"
Add-ReportLine "Relay VM/IP     : $relayVm / $relayManagementIP"
Add-ReportLine "DP VM/subnet/IP : $dpVm / $dpSubnet / $dpIP"
Add-ReportLine "Capture seconds : $CaptureSeconds"
Add-ReportLine "Destination     : $destRoot"
Add-ReportLine

$hostBefore = Get-HostNetworkSnapshot -ClientSubnet $clientSubnet -DpSubnet $dpSubnet -ClientIP $ClientIPAddress -DpIP $dpIP
Write-Utf8NoBom -Path (Join-Path $destRoot 'host-network-before.json') -Text (ConvertTo-SafeJson $hostBefore 10)
$dpBefore = Get-DpSnapshot -VmName $dpVm -Domain $domain -ClientIP $ClientIPAddress -ClientSubnet $clientSubnet -Stamp $stamp -MakeLogSnapshot $false
Write-Utf8NoBom -Path (Join-Path $destRoot 'dp-before.json') -Text (ConvertTo-SafeJson $dpBefore 12)
$relayBefore = Get-RelaySnapshot -VmName $relayVm -IPAddress $relayManagementIP
Write-Utf8NoBom -Path (Join-Path $destRoot 'relay-before.txt') -Text "$($relayBefore.Output)"

$router = @($hostBefore.DhcpOptions | Where-Object OptionId -eq 3 | ForEach-Object { @($_.Value) } | Where-Object { $null -ne $_ -and "$_" })
$clientForwarding = @($hostBefore.IPInterfaces | Where-Object { $_.InterfaceAlias -eq "vEthernet ($clientSubnet)" } | Select-Object -ExpandProperty Forwarding)
$dpForwarding = @($hostBefore.IPInterfaces | Where-Object { $_.InterfaceAlias -eq "vEthernet ($dpSubnet)" } | Select-Object -ExpandProperty Forwarding)
Add-ReportLine "Pre-capture DHCP option 3 : $(if ($router.Count) { $router -join ', ' } else { '<absent>' })"
Add-ReportLine "Pre-capture host forwarding: client=$($clientForwarding -join ',') dp=$($dpForwarding -join ',')"
Add-ReportLine "Pre-capture DP errors      : $(@($dpBefore.Errors).Count)"
Add-ReportLine "Pre-capture relay result   : $($relayBefore.CommandResult)"
Add-ReportLine

$pktmon = Get-Command pktmon.exe -ErrorAction SilentlyContinue
$pktmonPath = if ($pktmon) { "$($pktmon.Source)" } else { '' }
if ($pktmon -and -not $pktmonPath) { $pktmonPath = "$($pktmon.Path)" }
$captureStarted = $false
$filtersAdded = $false
$etlPath = Join-Path $destRoot 'host-pxe.etl'
$pcapPath = Join-Path $destRoot 'host-pxe.pcapng'
$packetTextPath = Join-Path $destRoot 'host-pxe.txt'
$packetKeyPath = Join-Path $destRoot 'host-pxe-key-lines.txt'
$pktmonLog = [System.Collections.Generic.List[string]]::new()
try {
    if ($NoPacketCapture) {
        Add-ReportLine 'Packet capture: skipped by -NoPacketCapture.'
    }
    elseif (-not $pktmon) {
        Add-ReportLine 'Packet capture: NOT COLLECTED because pktmon.exe is unavailable.'
    }
    else {
        $existingFilters = Get-NativeText -FilePath $pktmonPath -ArgumentList @('filter', 'list')
        $pktmonLog.Add("===== pre-existing filters =====`r`n$($existingFilters.Text)")
        if ($existingFilters.ExitCode -ne 0) {
            Add-ReportLine "Packet capture: NOT COLLECTED because Packet Monitor filter inspection failed (rc=$($existingFilters.ExitCode)): $($existingFilters.Text)"
        }
        elseif ($existingFilters.Text -and $existingFilters.Text -notmatch '(?i)no filters|filter count\s*:\s*0') {
            Add-ReportLine 'Packet capture: NOT COLLECTED because Packet Monitor already has global filters; they were left untouched.'
        }
        else {
            foreach ($filter in @(
                    @{ Name = 'MemLabsPXE-DHCP67'; Args = @('-t', 'UDP', '-p', '67') },
                    @{ Name = 'MemLabsPXE-DHCP68'; Args = @('-t', 'UDP', '-p', '68') },
                    @{ Name = 'MemLabsPXE-DP'; Args = @('-t', 'UDP', '-i', $dpIP) },
                    @{ Name = 'MemLabsPXE-ClientSubnet'; Args = @('-t', 'UDP', '-i', "$clientSubnet/24") }
                )) {
                $added = Get-NativeText -FilePath $pktmonPath -ArgumentList (@('filter', 'add', $filter.Name) + $filter.Args)
                $pktmonLog.Add("===== add $($filter.Name) rc=$($added.ExitCode) =====`r`n$($added.Text)")
                if ($added.ExitCode -ne 0) { throw "pktmon filter add $($filter.Name) failed: $($added.Text)" }
                $filtersAdded = $true
            }
            $started = Get-NativeText -FilePath $pktmonPath -ArgumentList @('start', '--capture', '--comp', 'nics', '--pkt-size', '0', '--file-name', $etlPath, '--file-size', '256', '--log-mode', 'circular')
            $pktmonLog.Add("===== start rc=$($started.ExitCode) =====`r`n$($started.Text)")
            if ($started.ExitCode -ne 0) { throw "pktmon start failed: $($started.Text)" }
            $captureStarted = $true
            Add-ReportLine "Packet capture: RUNNING for $CaptureSeconds seconds. Trigger PXE now."

            if ($RestartClientVM) {
                $clientState = (Get-VM -Name $clientVm -ErrorAction Stop).State
                if ($clientState -eq 'Running') {
                    Restart-VM -Name $clientVm -Force -ErrorAction Stop
                    Add-ReportLine "Client action  : hard-restarted running VM '$clientVm'."
                }
                else {
                    Start-VM -Name $clientVm -ErrorAction Stop | Out-Null
                    Add-ReportLine "Client action  : started VM '$clientVm'."
                }
            }
            else {
                Add-ReportLine "Client action  : restart/start '$clientVm' manually while capture is running."
            }

            $deadline = (Get-Date).AddSeconds($CaptureSeconds)
            $nextNotice = Get-Date
            while ((Get-Date) -lt $deadline) {
                if ((Get-Date) -ge $nextNotice) {
                    $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
                    Write-Host "  capture remaining: ${remaining}s"
                    $nextNotice = (Get-Date).AddSeconds(10)
                }
                Start-Sleep -Milliseconds 500
            }
        }
    }
}
catch {
    Add-ReportLine "Packet capture error: $($_.Exception.Message)"
}
finally {
    if ($captureStarted) {
        $counters = Get-NativeText -FilePath $pktmonPath -ArgumentList @('counters')
        $pktmonLog.Add("===== counters rc=$($counters.ExitCode) =====`r`n$($counters.Text)")
        $stopped = Get-NativeText -FilePath $pktmonPath -ArgumentList @('stop')
        $pktmonLog.Add("===== stop rc=$($stopped.ExitCode) =====`r`n$($stopped.Text)")
        $captureStarted = $false
    }
    if ($filtersAdded) {
        $removed = Get-NativeText -FilePath $pktmonPath -ArgumentList @('filter', 'remove')
        $pktmonLog.Add("===== remove filters rc=$($removed.ExitCode) =====`r`n$($removed.Text)")
        $filtersAdded = $false
    }
    Write-Utf8NoBom -Path (Join-Path $destRoot 'pktmon-command.log') -Text ($pktmonLog -join "`r`n")
}

if ((Test-Path -LiteralPath $etlPath) -and $pktmonPath) {
    $pcap = Get-NativeText -FilePath $pktmonPath -ArgumentList @('etl2pcap', $etlPath, '--out', $pcapPath)
    $text = Get-NativeText -FilePath $pktmonPath -ArgumentList @('etl2txt', $etlPath, '--out', $packetTextPath, '--timestamp', '--brief')
    Add-ReportLine "Packet ETL     : $etlPath"
    Add-ReportLine "Packet PCAPNG  : $(if ($pcap.ExitCode -eq 0) { $pcapPath } else { "conversion failed: $($pcap.Text)" })"
    Add-ReportLine "Packet text    : $(if ($text.ExitCode -eq 0) { $packetTextPath } else { "conversion failed: $($text.Text)" })"
    if ($text.ExitCode -eq 0 -and (Test-Path -LiteralPath $packetTextPath)) {
        $keyPatterns = @($dpIP, $ClientIPAddress, ':67', ':68', ':69', ':4011') | Where-Object { $_ }
        $keyLines = @(Select-String -LiteralPath $packetTextPath -Pattern $keyPatterns -SimpleMatch -ErrorAction SilentlyContinue |
            Select-Object -First 10000 | ForEach-Object { $_.Line })
        Write-Utf8NoBom -Path $packetKeyPath -Text ($keyLines -join "`r`n")
        Add-ReportLine "Packet key lines: $packetKeyPath ($($keyLines.Count) line(s))"
    }
}

$hostAfter = Get-HostNetworkSnapshot -ClientSubnet $clientSubnet -DpSubnet $dpSubnet -ClientIP $ClientIPAddress -DpIP $dpIP
Write-Utf8NoBom -Path (Join-Path $destRoot 'host-network-after.json') -Text (ConvertTo-SafeJson $hostAfter 10)
$dpAfter = Get-DpSnapshot -VmName $dpVm -Domain $domain -ClientIP $ClientIPAddress -ClientSubnet $clientSubnet -Stamp "$stamp-after" -MakeLogSnapshot $true
Write-Utf8NoBom -Path (Join-Path $destRoot 'dp-after.json') -Text (ConvertTo-SafeJson $dpAfter 12)
$relayAfter = Get-RelaySnapshot -VmName $relayVm -IPAddress $relayManagementIP
Write-Utf8NoBom -Path (Join-Path $destRoot 'relay-after.txt') -Text "$($relayAfter.Output)"

$snapshotGuestPath = "$($dpAfter.SmsPxeSnapshotPath)"
if ($snapshotGuestPath) {
    try {
        $null = Copy-ItemFromVM -Path $snapshotGuestPath -Destination $destRoot -VMName $dpVm -VMDomainName $domain
        $session = Get-VmSession -VmName $dpVm -VmDomainName $domain
        if ($session) { $null = Invoke-Command -Session $session -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } -ArgumentList $snapshotGuestPath }
    }
    catch { Add-ReportLine "SMSPXE full-log copy: NOT COLLECTED - $($_.Exception.Message)" }
}

$beforeTailCount = @($dpBefore.SmsPxeTail | Where-Object { $null -ne $_ }).Count
$afterTail = @($dpAfter.SmsPxeTail | Where-Object { $null -ne $_ })
Write-Utf8NoBom -Path (Join-Path $destRoot 'SMSPXE-tail-after.txt') -Text ($afterTail -join "`r`n")
$subnetPrefix = ''
if ($clientSubnet -match '^(\d+\.\d+\.\d+)\.0$') { $subnetPrefix = "$($Matches[1])." }
$clientHits = @($afterTail | Where-Object {
        ($ClientIPAddress -and "$_" -match [regex]::Escape($ClientIPAddress)) -or
    ($subnetPrefix -and "$_" -match [regex]::Escape($subnetPrefix))
    })
Write-Utf8NoBom -Path (Join-Path $destRoot 'SMSPXE-client-subnet-lines.txt') -Text ($clientHits -join "`r`n")

Add-ReportLine
$dpAfterErrors = @($dpAfter.Errors | Where-Object { $null -ne $_ -and "$_" })
Add-ReportLine "Post-capture DP errors       : $($dpAfterErrors.Count)"
if ($dpAfter.SmsPxePath) {
    Add-ReportLine "SMSPXE tail lines before/after: $beforeTailCount/$($afterTail.Count)"
    Add-ReportLine "SMSPXE client-subnet lines    : $($clientHits.Count)"
}
else {
    Add-ReportLine 'SMSPXE tail/client lines      : NOT COLLECTED (log path unresolved)'
}
Add-ReportLine "Relay post-capture result     : $($relayAfter.CommandResult)"
Add-ReportLine
Add-ReportLine 'Interpretation guardrails:'
Add-ReportLine '- A DHCP offer alone proves only broadcast relay, not routed TFTP.'
Add-ReportLine '- NBP file size proves a TFTP option response, not completion of all DATA blocks.'
Add-ReportLine '- A packet trace with zero relevant packets is NOT a negative result if capture was not started.'
Add-ReportLine '- Compare packet direction at both vEthernet interfaces before naming host, DP firewall, or client gateway as the drop point.'
Add-ReportLine
Add-ReportLine "COMPLETE: evidence bundle written to $destRoot"
Write-Utf8NoBom -Path $reportPath -Text ($script:Report -join "`r`n")
Write-Host "`nProbe complete: $reportPath" -ForegroundColor Green
