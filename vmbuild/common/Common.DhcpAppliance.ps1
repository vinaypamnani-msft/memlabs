# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads common files under PS 5.1.
# DHCP backend selection and the Windows Client dnsmasq appliance implementation.

function Get-MemLabsDhcpBackend {
    [CmdletBinding()]
    param(
        [int] $ProductType = -1,
        [AllowNull()] [object] $HyperVAvailable = $null,
        [AllowNull()] [object] $NativeDhcpAvailable = $null
    )

    if ($ProductType -lt 0) {
        try { $ProductType = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType }
        catch { throw "Could not determine host operating-system ProductType: $($_.Exception.Message)" }
    }
    $hostType = if ($ProductType -eq 1) { 'Client' } else { 'Server' }
    if ($null -eq $HyperVAvailable) {
        $hasVmms = [bool](Get-Service vmms -ErrorAction SilentlyContinue)
        $hasCmdlets = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
        $HyperVAvailable = ($hasVmms -and $hasCmdlets)
    }
    if ($null -eq $NativeDhcpAvailable) {
        if ($hostType -eq 'Client') {
            $NativeDhcpAvailable = $false
        }
        else {
            $hasDhcpService = [bool](Get-Service DHCPServer -ErrorAction SilentlyContinue)
            $hasDhcpModule = [bool](Get-Module DhcpServer -ListAvailable -ErrorAction SilentlyContinue)
            $NativeDhcpAvailable = ($hasDhcpService -and $hasDhcpModule)
        }
    }

    $backendType = if ($hostType -eq 'Client') { 'DnsmasqAppliance' } else { 'WindowsDhcp' }
    $reason = if ($hostType -eq 'Client') {
        'Windows Client has no supported DHCP Server role; use the MemLabs dnsmasq appliance.'
    }
    else {
        'Windows Server uses the native DHCP Server role.'
    }

    return [pscustomobject]@{
        HostType            = $hostType
        ProductType         = $ProductType
        HyperVAvailable     = [bool]$HyperVAvailable
        NativeDhcpAvailable = [bool]$NativeDhcpAvailable
        BackendType         = $backendType
        Reason              = $reason
    }
}

function Test-MemLabsUsesDhcpAppliance {
    [CmdletBinding()]
    param()
    return [bool]($Common -and $Common.DhcpBackend -and $Common.DhcpBackend.BackendType -eq 'DnsmasqAppliance')
}

function Test-MemLabsVmStorageDriveAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $DriveLetter,
        [ValidateSet('Client', 'Server')] [string] $HostType
    )
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    if ($letter -in @('D', 'Z')) { return $false }
    if ($letter -ne 'C') { return $true }
    if (-not $HostType) {
        $backend = if ($Common -and $Common.DhcpBackend) { $Common.DhcpBackend } else { Get-MemLabsDhcpBackend }
        $HostType = [string]$backend.HostType
    }
    return ($HostType -eq 'Client')
}

function ConvertTo-MemLabsNormalizedMac {
    param([string] $MacAddress, [switch] $Colon)
    if (-not $MacAddress) { return '' }
    $compact = ($MacAddress -replace '[-:\.]', '').ToLowerInvariant()
    if ($compact -notmatch '^[0-9a-f]{12}$') { return '' }
    if (-not $Colon.IsPresent) { return $compact }
    return (($compact -split '(.{2})' | Where-Object { $_ }) -join ':')
}

function ConvertTo-MemLabsIpNumber {
    param([string] $IPAddress)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) { return $null }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $null }
    return ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
}

function Get-MemLabsDhcpApplianceNote {
    param([Parameter(Mandatory = $true)] $VM)
    if (-not $VM.Notes) { return $null }
    try {
        $note = $VM.Notes | ConvertFrom-Json -ErrorAction Stop
        if ($note.infrastructureType -ne 'MemLabsDhcpAppliance') { return $null }
        return $note
    }
    catch { return $null }
}

function Get-MemLabsDhcpApplianceVms {
    [CmdletBinding()]
    param([object[]] $LiveVMs)
    if ($null -eq $LiveVMs) { $LiveVMs = @(Get-VM -ErrorAction SilentlyContinue) }
    $result = @()
    foreach ($vm in @($LiveVMs | Where-Object { $_ })) {
        $note = Get-MemLabsDhcpApplianceNote -VM $vm
        if ($note) {
            $result += [pscustomobject]@{ VM = $vm; Note = $note }
        }
    }
    return $result
}

function Get-MemLabsVmAdapters {
    param([Parameter(Mandatory = $true)] $VM)
    if ($VM.PSObject.Properties['NetworkAdapters'] -and $VM.NetworkAdapters) {
        return @($VM.NetworkAdapters)
    }
    try { return @($VM | Get-VMNetworkAdapter -ErrorAction Stop) }
    catch { return @() }
}

function Get-MemLabsDhcpDesiredState {
    [CmdletBinding()]
    param(
        [object] $DeployConfig,
        [object[]] $LiveVMs
    )

    if ($null -eq $LiveVMs) { $LiveVMs = @(Get-VM -ErrorAction Stop) }
    $scopeTable = @{}
    $vmRecords = @{}
    $domainDns = @{}

    function Add-DesiredScope {
        param([string] $ScopeId, [string] $DomainName, [string] $DnsServer, [string] $ScopeName)
        if (-not $ScopeId -or $ScopeId -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not $ScopeId.EndsWith('.0')) { return }
        if ($ScopeId -eq '10.250.251.0') { return }
        if (-not $scopeTable.ContainsKey($ScopeId)) {
            $base = $ScopeId.Substring(0, $ScopeId.LastIndexOf('.'))
            $switchName = if ($ScopeId -eq '172.31.250.0') { 'Internet' } elseif ($ScopeId -eq '10.250.250.0') { 'Cluster' } else { $ScopeId }
            $scopeTable[$ScopeId] = [ordered]@{
                ScopeId       = $ScopeId
                ScopeName     = $(if ($ScopeName) { $ScopeName } else { $switchName })
                SwitchName    = $switchName
                DomainName    = $DomainName
                ServerAddress = "$base.19"
                StartRange    = "$base.20"
                EndRange      = "$base.199"
                Router        = $(if ($ScopeId -eq '10.250.250.0') { '' } else { "$base.200" })
                DnsServers    = @()
                WinsServer    = ''
                Reservations  = @()
                InterfaceMac  = ''
            }
        }
        $scope = $scopeTable[$ScopeId]
        if ($DomainName) { $scope.DomainName = $DomainName }
        if ($DnsServer) {
            $scope.DnsServers = @($DnsServer)
            $scope.WinsServer = $DnsServer
        }
        elseif ($ScopeId -eq '172.31.250.0') {
            $scope.DnsServers = @('4.4.4.4', '8.8.8.8')
        }
    }

    foreach ($live in @($LiveVMs | Where-Object { $_ })) {
        $note = $null
        if ($live.Notes) {
            try { $note = $live.Notes | ConvertFrom-Json -ErrorAction Stop } catch { }
        }
        if (-not $note -or $note.infrastructureType -eq 'MemLabsDhcpAppliance') { continue }
        $network = [string]$note.network
        if ($note.role -in @('InternetClient', 'AADClient')) { $network = '172.31.250.0' }
        $record = [pscustomobject]@{ VM = $live; Note = $note; Network = $network }
        $vmRecords[$live.Name.ToLowerInvariant()] = $record
        if ($note.role -eq 'DC' -and $note.domain -and $network) {
            $domainDns[[string]$note.domain] = ($network -replace '\.0$', '.1')
        }
    }

    if ($DeployConfig) {
        $defaultNetwork = [string]$DeployConfig.vmOptions.network
        $domainName = [string]$DeployConfig.vmOptions.domainName
        $dc = @($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'DC' -and -not $_.hidden } | Select-Object -First 1)
        if ($dc.Count -gt 0) {
            $dcNetwork = if ($dc[0].network) { [string]$dc[0].network } else { $defaultNetwork }
            if ($domainName -and $dcNetwork) { $domainDns[$domainName] = ($dcNetwork -replace '\.0$', '.1') }
        }
        Add-DesiredScope -ScopeId $defaultNetwork -DomainName $domainName -DnsServer $domainDns[$domainName] -ScopeName $defaultNetwork
        foreach ($vm in @($DeployConfig.virtualMachines)) {
            if ($vm.hidden) { continue }
            $network = if ($vm.network) { [string]$vm.network } else { $defaultNetwork }
            if ($vm.role -in @('InternetClient', 'AADClient')) { $network = '172.31.250.0' }
            Add-DesiredScope -ScopeId $network -DomainName $(if ($network -eq '172.31.250.0') { '' } else { $domainName }) `
                -DnsServer $(if ($network -eq '172.31.250.0') { '' } else { $domainDns[$domainName] }) -ScopeName $network
        }
    }

    foreach ($record in $vmRecords.Values) {
        $note = $record.Note
        $network = $record.Network
        if (-not $network) { continue }
        $dns = if ($note.domain -and $domainDns.ContainsKey([string]$note.domain)) { $domainDns[[string]$note.domain] } else { '' }
        $scopeDomain = if ($network -eq '172.31.250.0') { '' } else { [string]$note.domain }
        Add-DesiredScope -ScopeId $network -DomainName $scopeDomain -DnsServer $dns -ScopeName $network

        $ip = if ($note.AssignedIP) { [string]$note.AssignedIP } elseif ($note.LastKnownIP) { [string]$note.LastKnownIP } else { '' }
        if (-not $ip -or -not $scopeTable.ContainsKey($network)) { continue }
        if ($ip -eq $scopeTable[$network].ServerAddress) {
            throw "DHCP appliance address conflict: VM '$($record.VM.Name)' already claims $ip on scope $network."
        }
        $lastOctet = 0
        if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [int]::TryParse(($ip -split '\.')[-1], [ref]$lastOctet) -or $lastOctet -lt 20 -or $lastOctet -gt 199) { continue }
        $scope = $scopeTable[$network]
        $adapter = @(Get-MemLabsVmAdapters -VM $record.VM | Where-Object { $_.SwitchName -eq $scope.SwitchName } | Select-Object -First 1)
        if (-not $adapter -or -not $adapter[0].MacAddress) { continue }
        $mac = ConvertTo-MemLabsNormalizedMac -MacAddress ([string]$adapter[0].MacAddress) -Colon
        if (-not $mac) { continue }
        $scope.Reservations += [pscustomobject]@{
            VMName     = $record.VM.Name
            MacAddress = $mac
            IPAddress  = $ip
        }
    }

    $seenIp = @{}
    $seenMac = @{}
    $scopes = @($scopeTable.Values | Sort-Object { [string]$_['ScopeId'] })
    foreach ($scope in $scopes) {
        $dedup = @()
        foreach ($reservation in @($scope.Reservations | Sort-Object VMName)) {
            $ipKey = "$($scope.ScopeId)|$($reservation.IPAddress)"
            $macKey = "$($scope.ScopeId)|$($reservation.MacAddress)"
            if ($seenIp.ContainsKey($ipKey) -and $seenIp[$ipKey] -ne $reservation.MacAddress) {
                throw "DHCP desired-state conflict: $($reservation.IPAddress) in $($scope.ScopeId) belongs to both $($seenIp[$ipKey]) and $($reservation.MacAddress)."
            }
            if ($seenMac.ContainsKey($macKey) -and $seenMac[$macKey] -ne $reservation.IPAddress) {
                throw "DHCP desired-state conflict: $($reservation.MacAddress) in $($scope.ScopeId) has both $($seenMac[$macKey]) and $($reservation.IPAddress)."
            }
            if (-not $seenIp.ContainsKey($ipKey)) { $dedup += $reservation }
            $seenIp[$ipKey] = $reservation.MacAddress
            $seenMac[$macKey] = $reservation.IPAddress
        }
        $scope.Reservations = $dedup
    }

    return [pscustomobject]@{
        SchemaVersion = 1
        GeneratedUtc  = [DateTime]::UtcNow.ToString('o')
        Scopes        = $scopes
    }
}

function Set-DnsmasqDeployConfigIPAddresses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object] $DeployConfig,
        [object[]] $LiveVMs
    )
    if ($null -eq $LiveVMs) { $LiveVMs = @(Get-VM -ErrorAction SilentlyContinue) }
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $existingIpByName = @{}
    $existingVirtualIpsByName = @{}
    $addressClaims = @{}
    foreach ($live in @($LiveVMs | Where-Object { $_ })) {
        if ($live.Notes) {
            try {
                $note = $live.Notes | ConvertFrom-Json -ErrorAction Stop
                foreach ($candidate in @($note.AssignedIP, $note.LastKnownIP)) {
                    if ($candidate) {
                        $ordinaryIp = [string]$candidate
                        $null = $used.Add($ordinaryIp)
                        if (-not $addressClaims.ContainsKey($ordinaryIp)) { $addressClaims[$ordinaryIp] = [Collections.Generic.List[object]]::new() }
                        $addressClaims[$ordinaryIp].Add([pscustomobject]@{ Name = $live.Name.ToLowerInvariant(); Kind = 'OrdinaryNote' })
                    }
                }
                foreach ($candidate in @($note.ClusterIPAddress, $note.AGIPAddress)) {
                    if ($candidate) {
                        $virtualIp = [string]$candidate -replace '/.+$', ''
                        $null = $used.Add($virtualIp)
                        if (-not $addressClaims.ContainsKey($virtualIp)) { $addressClaims[$virtualIp] = [Collections.Generic.List[object]]::new() }
                        $addressClaims[$virtualIp].Add([pscustomobject]@{ Name = $live.Name.ToLowerInvariant(); Kind = 'VirtualNote' })
                    }
                }
                $persistedIp = if ($note.AssignedIP) { [string]$note.AssignedIP } elseif ($note.LastKnownIP) { [string]$note.LastKnownIP } else { '' }
                if ($persistedIp) { $existingIpByName[$live.Name.ToLowerInvariant()] = $persistedIp }
                if ($note.ClusterIPAddress -or $note.AGIPAddress) {
                    $existingVirtualIpsByName[$live.Name.ToLowerInvariant()] = [pscustomobject]@{
                        ClusterIPAddress = [string]$note.ClusterIPAddress
                        AGIPAddress      = [string]$note.AGIPAddress
                    }
                }
            }
            catch { }
        }
        foreach ($adapter in @(Get-MemLabsVmAdapters -VM $live)) {
            foreach ($candidate in @($adapter.IPAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })) {
                $adapterIp = [string]$candidate
                $null = $used.Add($adapterIp)
                if (-not $addressClaims.ContainsKey($adapterIp)) { $addressClaims[$adapterIp] = [Collections.Generic.List[object]]::new() }
                $addressClaims[$adapterIp].Add([pscustomobject]@{ Name = $live.Name.ToLowerInvariant(); Kind = 'Adapter' })
            }
        }
    }

    $defaultNetwork = [string]$DeployConfig.vmOptions.network
    $sqlAoOwners = @($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' -and $_.OtherNode -and -not $_.hidden })

    # Validate and claim every explicit/restored VIP before allocating any missing
    # value. Otherwise a missing owner listed first can consume a later owner's
    # configured address even though other reserved-range addresses are free.
    foreach ($owner in $sqlAoOwners) {
        $scopeId = if ($owner.network) { [string]$owner.network } else { $defaultNetwork }
        $base = (($scopeId -split '\.') | Select-Object -First 3) -join '.'
        $ownerKey = ([string]$owner.vmName).ToLowerInvariant()
        $pairKeys = @($ownerKey, ([string]$owner.OtherNode).ToLowerInvariant())
        foreach ($property in 'ClusterIPAddress', 'AGIPAddress') {
            $configuredIp = if ($owner.$property) { [string]$owner.$property -replace '/.+$', '' } else { '' }
            $persistedIps = @($pairKeys | ForEach-Object {
                    if ($existingVirtualIpsByName.ContainsKey($_)) {
                        $value = $existingVirtualIpsByName[$_].$property
                        if ($value) { [string]$value -replace '/.+$', '' }
                    }
                } | Sort-Object -Unique)
            if ($persistedIps.Count -gt 1) {
                throw "$($owner.vmName)/$($owner.OtherNode): persisted SQLAO $property values disagree: $($persistedIps -join ', ')."
            }
            if ($configuredIp -and $persistedIps.Count -eq 1 -and $configuredIp -ne $persistedIps[0]) {
                throw "$($owner.vmName)/$($owner.OtherNode): configured SQLAO $property $configuredIp disagrees with persisted value $($persistedIps[0])."
            }
            $ip = if ($configuredIp) { $configuredIp } elseif ($persistedIps.Count -eq 1) { $persistedIps[0] } else { '' }
            if (-not $ip) { continue }
            $parsedIp = $null
            $octets = @($ip -split '\.')
            $validIp = [Net.IPAddress]::TryParse($ip, [ref]$parsedIp) -and $parsedIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $parsedIp.ToString() -eq $ip
            if (-not $validIp -or $octets.Count -ne 4 -or (($octets[0..2] -join '.') -ne $base) -or [int]$octets[3] -lt 201 -or [int]$octets[3] -gt 254) {
                throw "$($owner.vmName): persisted $property $ip must be a canonical IPv4 address in $base.201-$base.254."
            }
            $conflictingClaims = @($addressClaims[$ip] | Where-Object {
                    $null -ne $_ -and
                    -not ($_.Kind -eq 'VirtualNote' -and $_.Name -in $pairKeys) -and
                    -not ($_.Kind -eq 'Adapter' -and $_.Name -in $pairKeys)
                })
            if ($conflictingClaims.Count -gt 0) {
                throw "$($owner.vmName): SQLAO $property $ip is already in use by another VM or virtual endpoint."
            }
            $null = $used.Add($ip)
            if (-not $addressClaims.ContainsKey($ip)) { $addressClaims[$ip] = [Collections.Generic.List[object]]::new() }
            $addressClaims[$ip].Add([pscustomobject]@{ Name = $ownerKey; Kind = 'ConfigVirtual' })
            $owner | Add-Member -MemberType NoteProperty -Name $property -Value $ip -Force
        }
    }

    foreach ($owner in $sqlAoOwners) {
        $scopeId = if ($owner.network) { [string]$owner.network } else { $defaultNetwork }
        $base = (($scopeId -split '\.') | Select-Object -First 3) -join '.'
        $ownerKey = ([string]$owner.vmName).ToLowerInvariant()
        foreach ($property in 'ClusterIPAddress', 'AGIPAddress') {
            $ip = [string]$owner.$property
            if (-not $ip) {
                for ($octet = 201; $octet -le 254; $octet++) {
                    $candidate = "$base.$octet"
                    if (-not $used.Contains($candidate)) { $ip = $candidate; break }
                }
                if (-not $ip) { throw "No free SQLAO virtual address remains in $base.201-$base.254 for $($owner.vmName) $property." }
                $null = $used.Add($ip)
                if (-not $addressClaims.ContainsKey($ip)) { $addressClaims[$ip] = [Collections.Generic.List[object]]::new() }
                $addressClaims[$ip].Add([pscustomobject]@{ Name = $ownerKey; Kind = 'ConfigVirtual' })
                $owner | Add-Member -MemberType NoteProperty -Name $property -Value $ip -Force
            }
            Write-Log "$($owner.vmName): Pre-assigned appliance SQLAO $property $ip (scope $scopeId)" -LogOnly
        }
        if ($owner.ClusterIPAddress -eq $owner.AGIPAddress) {
            throw "$($owner.vmName): SQLAO ClusterIPAddress and AGIPAddress both resolved to $($owner.ClusterIPAddress)."
        }
    }

    foreach ($vm in @($DeployConfig.virtualMachines)) {
        if ($vm.hidden -or $vm.role -eq 'OSDClient') { continue }
        $scopeId = if ($vm.role -in @('InternetClient', 'AADClient')) { '172.31.250.0' } elseif ($vm.network) { [string]$vm.network } else { $defaultNetwork }
        $base = (($scopeId -split '\.') | Select-Object -First 3) -join '.'
        $ip = ''
        $reusedForVm = $false
        if ($vm.AssignedIP) {
            $ip = [string]$vm.AssignedIP
            $reusedForVm = $true
        }
        elseif ($vm.vmName -and $existingIpByName.ContainsKey(([string]$vm.vmName).ToLowerInvariant())) {
            $ip = [string]$existingIpByName[([string]$vm.vmName).ToLowerInvariant()]
            $reusedForVm = $true
        }
        if ($ip -and $ip -notlike "$base.*") {
            throw "$($vm.vmName): persisted address $ip is not in configured scope $scopeId."
        }
        if ($ip -in @("$base.19", "$base.200")) {
            throw "$($vm.vmName): persisted address $ip conflicts with the DHCP appliance or host gateway."
        }
        if (-not $ip) { switch ([string]$vm.role) {
            'DC'        { $ip = "$base.1" }
            'BDC'       { $ip = "$base.3" }
            'CAS'       { $ip = "$base.5" }
            'Primary'   { $ip = "$base.10" }
            'Secondary' { $ip = "$base.15" }
            'Proxy'     { $ip = "$base.2" }
            'DHCPRelay' { $ip = "$base.4" }
        } }
        if (-not $ip) {
            for ($octet = 20; $octet -le 199; $octet++) {
                $candidate = "$base.$octet"
                if (-not $used.Contains($candidate)) { $ip = $candidate; break }
            }
        }
        if (-not $ip) { throw "No free address remains in DHCP pool $base.20-$base.199 for $($vm.vmName)." }
        if (-not $used.Add($ip)) {
            if (-not $reusedForVm) { throw "DHCP allocation conflict: $ip is already in use while assigning $($vm.vmName)." }
        }
        $vm | Add-Member -MemberType NoteProperty -Name AssignedIP -Value $ip -Force
        Write-Log "$($vm.vmName): Pre-assigned appliance DHCP IP $ip (scope $scopeId)" -LogOnly
    }
    return $true
}

function Get-MemLabsDhcpApplianceImagePath {
    [CmdletBinding()]
    param([switch] $DownloadIfMissing)
    $image = @($Common.AzureFileList.OS | Where-Object { $_.id -eq 'Ubuntu Server 24.04 LTS' } | Select-Object -First 1)
    if (-not $image) { throw "Azure file list has no 'Ubuntu Server 24.04 LTS' appliance image." }
    $path = Join-Path $Common.AzureFilesPath $image[0].filename
    if (-not (Test-Path -LiteralPath $path) -and $DownloadIfMissing.IsPresent) {
        $worked = Get-FileFromStorage -File $image[0]
        if (-not $worked) { throw "Failed to download the DHCP appliance image '$($image[0].filename)'." }
    }
    if (-not (Test-Path -LiteralPath $path)) { throw "DHCP appliance image is missing: $path" }
    return $path
}

function Remove-MemLabsOwnedDhcpAppliance {
    param([Parameter(Mandatory = $true)] $VM)
    $note = Get-MemLabsDhcpApplianceNote -VM $VM
    if (-not $note) { throw "Refusing to remove '$($VM.Name)': the VM does not carry a MemLabs DHCP appliance ownership note." }
    $verifiedId = $VM.VMId
    $current = Get-VM -Id $verifiedId -ErrorAction Stop
    $currentNote = Get-MemLabsDhcpApplianceNote -VM $current
    if (-not $currentNote -or $current.Name -ne $VM.Name -or [int]$currentNote.schemaVersion -ne [int]$note.schemaVersion) {
        throw "Refusing to remove '$($VM.Name)': its live identity/ownership note changed after verification."
    }
    $path = $current.Path
    if ($current.State -ne 'Off') { Stop-VM -VM $current -TurnOff -Force -WarningAction SilentlyContinue }
    $current = Get-VM -Id $verifiedId -ErrorAction Stop
    if (-not (Get-MemLabsDhcpApplianceNote -VM $current)) {
        throw "Refusing to remove '$($VM.Name)': ownership could not be reverified immediately before Remove-VM."
    }
    Remove-VM -VM $current -Force -ErrorAction Stop
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
    try { Get-List -FlushCache | Out-Null } catch { }
}

function New-MemLabsDhcpApplianceVm {
    param(
        [Parameter(Mandatory = $true)] [string] $VMName,
        [Parameter(Mandatory = $true)] [object[]] $Scopes,
        [Parameter(Mandatory = $true)] [int] $ShardNumber
    )
    $primary = $Scopes[0]
    $imagePath = Get-MemLabsDhcpApplianceImagePath -DownloadIfMissing
    $infraRoot = Join-Path $Common.AzureFilesPath 'infrastructure'
    if (-not (Test-Path -LiteralPath $infraRoot)) { New-Item -ItemType Directory -Path $infraRoot -Force | Out-Null }
    $infraVm = [pscustomobject]@{
        vmName             = $VMName
        role               = 'DHCPAppliance'
        operatingSystem    = 'Ubuntu Server 24.04 LTS'
        osFamily           = 'Linux'
        memory             = '1GB'
        virtualProcs       = 1
        network            = $primary.ScopeId
        AssignedIP         = $primary.ServerAddress
        infrastructureType = 'MemLabsDhcpAppliance'
        schemaVersion      = 1
        shardNumber        = $ShardNumber
    }
    $infraConfig = [pscustomobject]@{
        vmOptions = [pscustomobject]@{
            network       = $primary.ScopeId
            domainName    = 'memlabs.infrastructure'
            domainNetBiosName = 'MEMLABS'
            adminName     = 'admin'
            prefix        = ''
            basePath      = $infraRoot
        }
        virtualMachines = @($infraVm)
    }
    $created = New-LinuxVirtualMachine -VmName $VMName -VmPath $infraRoot -SourceDiskPath $imagePath `
        -Memory '1GB' -Processors 1 -SwitchName $primary.SwitchName -Domain 'memlabs.infrastructure' -DeployConfig $infraConfig
    if (-not ($created -eq $true)) { throw "Creation of DHCP appliance '$VMName' failed." }
    Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStartDelay 0 -AutomaticStopAction Save -ErrorAction Stop
    $ready = Wait-LinuxVmReady -VmName $VMName -ExpectedIPAddress $primary.ServerAddress -TimeoutSeconds 900 -MaxRestarts 1
    if (-not $ready) { throw "DHCP appliance '$VMName' did not become SSH-ready at $($primary.ServerAddress)." }
    $cloudInit = Invoke-LinuxVmCommand -VmName $VMName -IPAddress $primary.ServerAddress -Sudo -TimeoutSeconds 960 `
        -BashCommand "timeout 900 cloud-init status --wait && cloud-init status --long" -DisplayName 'Wait for DHCP appliance cloud-init'
    if (-not $cloudInit.CommandResult -or $cloudInit.ScriptBlockOutput -notmatch '(?m)^status:\s+done\s*$') {
        throw "DHCP appliance '$VMName' cloud-init did not complete successfully: $($cloudInit.ScriptBlockOutput)"
    }
    return Get-VM -Name $VMName -ErrorAction Stop
}

function Wait-MemLabsDhcpApplianceAdapters {
    param(
        [Parameter(Mandatory = $true)] [string] $VMName,
        [Parameter(Mandatory = $true)] [string[]] $SwitchNames,
        [int] $TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        $adapters = @(Get-MemLabsVmAdapters -VM $vm)
        $valid = $true
        foreach ($switchName in $SwitchNames) {
            $matchingAdapters = @($adapters | Where-Object { $_.SwitchName -eq $switchName })
            if ($matchingAdapters.Count -ne 1 -or -not (ConvertTo-MemLabsNormalizedMac -MacAddress ([string]$matchingAdapters[0].MacAddress))) {
                $valid = $false
                break
            }
        }
        if ($valid) { return $vm }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "$VMName`: adapters did not expose exactly one valid MAC on each expected switch within $TimeoutSeconds seconds: $($SwitchNames -join ', ')."
}

function Sync-MemLabsDhcpAppliance {
    [CmdletBinding()]
    param(
        [object] $DeployConfig,
        [switch] $WhatIf
    )
    if (-not (Test-MemLabsUsesDhcpAppliance)) { return $true }
    if (-not $Common.DhcpBackend.HyperVAvailable) { throw 'The dnsmasq DHCP backend requires Hyper-V, but Hyper-V is unavailable.' }

    $desired = Get-MemLabsDhcpDesiredState -DeployConfig $DeployConfig
    $scopes = @($desired.Scopes)
    if ($WhatIf.IsPresent) {
        Write-Log "[What-If] Would reconcile dnsmasq DHCP for $($scopes.Count) scope(s)."
        return $true
    }

    $existingAppliances = @(Get-MemLabsDhcpApplianceVms)
    $allLiveVms = @(Get-VM -ErrorAction Stop)
    foreach ($scope in $scopes) {
        $owners = @($existingAppliances | Where-Object { $scope.ScopeId -in @($_.Note.ownedScopeIds) })
        if ($owners.Count -gt 1) {
            throw "Scope $($scope.ScopeId) is claimed by multiple DHCP appliances: $($owners.VM.Name -join ', '). Refusing to risk competing offers."
        }
        if (-not (Get-VMSwitch -Name $scope.SwitchName -ErrorAction SilentlyContinue)) {
            throw "Cannot serve scope $($scope.ScopeId): Hyper-V switch '$($scope.SwitchName)' does not exist."
        }
        foreach ($liveVm in $allLiveVms) {
            if (Get-MemLabsDhcpApplianceNote -VM $liveVm) { continue }
            foreach ($adapter in @(Get-MemLabsVmAdapters -VM $liveVm | Where-Object { $_.SwitchName -eq $scope.SwitchName })) {
                if (@($adapter.IPAddresses) -contains $scope.ServerAddress) {
                    throw "DHCP appliance address conflict: live VM '$($liveVm.Name)' reports $($scope.ServerAddress) on '$($scope.SwitchName)'."
                }
            }
        }
    }

    $mutex = [Threading.Mutex]::new($false, 'Global\MemLabs_DhcpAppliance')
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(20))
        if (-not $acquired) { throw 'Timed out waiting for the DHCP appliance reconciliation mutex.' }
        if ($scopes.Count -eq 0) {
            foreach ($owned in @(Get-MemLabsDhcpApplianceVms)) {
                Write-Log "$($owned.VM.Name): removing unused DHCP appliance because no managed scopes remain." -LogOnly
                Remove-MemLabsOwnedDhcpAppliance -VM $owned.VM
            }
            Write-Log 'DHCP appliance reconciliation complete: no managed lab scopes exist.' -LogOnly
            return $true
        }
        $groups = @()
        for ($offset = 0; $offset -lt $scopes.Count; $offset += 8) {
            $last = [Math]::Min($offset + 7, $scopes.Count - 1)
            $groups += ,@($scopes[$offset..$last])
        }

        for ($index = 0; $index -lt $groups.Count; $index++) {
            $group = @($groups[$index])
            $name = 'MemLabs-DHCP-{0:D2}' -f ($index + 1)
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if ($vm) {
                $note = Get-MemLabsDhcpApplianceNote -VM $vm
                if (-not $note) { throw "VM '$name' already exists but is not a proven MemLabs DHCP appliance. It will not be modified." }
                $currentScopes = @($note.ownedScopeIds | ForEach-Object { [string]$_ } | Sort-Object)
                $wantedScopes = @($group.ScopeId | Sort-Object)
                if (@(Compare-Object $currentScopes $wantedScopes).Count -gt 0) {
                    $primaryMatches = @((Get-MemLabsVmAdapters -VM $vm) | Where-Object { $_.SwitchName -eq $group[0].SwitchName }).Count -eq 1
                    if ($note.inProgress -and -not $note.appliedConfigHash -and $primaryMatches) {
                        Write-Log "$name`: resuming its proven in-progress creation on '$($group[0].SwitchName)' before assigning scopes." -Warning
                    }
                    else {
                        Write-Log "$name`: scope placement changed; rebuilding the owned appliance from VM-note desired state." -Warning
                        Remove-MemLabsOwnedDhcpAppliance -VM $vm
                        $vm = $null
                    }
                }
            }
            if (-not $vm) { $vm = New-MemLabsDhcpApplianceVm -VMName $name -Scopes $group -ShardNumber ($index + 1) }

            if ($vm.State -ne 'Running') { Start-VM -VM $vm -ErrorAction Stop | Out-Null }
            $primary = $group[0]
            $ready = Wait-LinuxVmReady -VmName $name -ExpectedIPAddress $primary.ServerAddress -TimeoutSeconds 600 -MaxRestarts 0
            if (-not $ready) {
                Write-Log "$name`: owned appliance is not SSH-ready; rebuilding once." -Warning
                Remove-MemLabsOwnedDhcpAppliance -VM $vm
                $vm = New-MemLabsDhcpApplianceVm -VMName $name -Scopes $group -ShardNumber ($index + 1)
            }

            $vm = Wait-MemLabsDhcpApplianceAdapters -VMName $name -SwitchNames @($primary.SwitchName)

            $adapters = @(Get-MemLabsVmAdapters -VM $vm)
            $currentSwitches = @($adapters.SwitchName | Sort-Object)
            $wantedSwitches = @($group.SwitchName | Sort-Object)
            if (@(Compare-Object $currentSwitches $wantedSwitches).Count -gt 0 -and $adapters.Count -gt 1) {
                Write-Log "$name`: adapter topology differs from desired state; rebuilding the owned appliance." -Warning
                Remove-MemLabsOwnedDhcpAppliance -VM $vm
                $vm = New-MemLabsDhcpApplianceVm -VMName $name -Scopes $group -ShardNumber ($index + 1)
                $adapters = @(Get-MemLabsVmAdapters -VM $vm)
            }

            $primaryAdapter = @($adapters | Where-Object { $_.SwitchName -eq $primary.SwitchName } | Select-Object -First 1)
            if (-not $primaryAdapter) { throw "$name`: primary adapter on '$($primary.SwitchName)' is missing." }
            $prepareScript = Get-LinuxScript -Name 'relay/prepare-management-network' -Variables @{
                MANAGEMENT_MAC     = [string]$primaryAdapter[0].MacAddress
                MANAGEMENT_IP      = $primary.ServerAddress
                MANAGEMENT_GATEWAY = ($primary.ScopeId -replace '\.0$', '.200')
                DNS_SERVERS        = '1.1.1.1, 8.8.8.8'
                DNS_SEARCH         = 'memlabs.infrastructure'
            }
            $prepared = Invoke-LinuxVmCommand -VmName $name -IPAddress $primary.ServerAddress -Sudo -TimeoutSeconds 180 `
                -BashCommand $prepareScript -DisplayName 'Prepare DHCP appliance management network'
            if (-not $prepared.CommandResult) { throw "$name`: management network preparation failed: $($prepared.ScriptBlockOutput)" }
            $primary.InterfaceMac = ConvertTo-MemLabsNormalizedMac -MacAddress ([string]$primaryAdapter[0].MacAddress) -Colon

            foreach ($scope in @($group | Select-Object -Skip 1)) {
                $adapters = @(Get-MemLabsVmAdapters -VM $vm)
                $adapter = @($adapters | Where-Object { $_.SwitchName -eq $scope.SwitchName })
                if ($adapter.Count -gt 1) { throw "$name`: duplicate adapters exist on '$($scope.SwitchName)'." }
                if ($adapter.Count -eq 0) {
                    Add-VMNetworkAdapter -VMName $name -SwitchName $scope.SwitchName -Name "DHCP-$($scope.ScopeId)" -ErrorAction Stop
                    $vm = Wait-MemLabsDhcpApplianceAdapters -VMName $name -SwitchNames @($primary.SwitchName, $scope.SwitchName)
                    $adapter = @(Get-MemLabsVmAdapters -VM $vm | Where-Object { $_.SwitchName -eq $scope.SwitchName })
                }
                if ($adapter.Count -ne 1) { throw "$name`: failed to establish one adapter on '$($scope.SwitchName)'." }
                $interfaceScript = Get-LinuxScript -Name 'relay/configure-client-interface' -Variables @{
                    CLIENT_MAC     = [string]$adapter[0].MacAddress
                    CLIENT_IP      = $scope.ServerAddress
                    CLIENT_NETWORK = $scope.ScopeId
                }
                $configured = Invoke-LinuxVmCommand -VmName $name -IPAddress $primary.ServerAddress -Sudo -TimeoutSeconds 180 `
                    -BashCommand $interfaceScript -DisplayName "Configure DHCP interface $($scope.ScopeId)"
                if (-not $configured.CommandResult) { throw "$name`: interface $($scope.ScopeId) failed: $($configured.ScriptBlockOutput)" }
                $scope.InterfaceMac = ConvertTo-MemLabsNormalizedMac -MacAddress ([string]$adapter[0].MacAddress) -Colon
            }

            $shardState = [pscustomobject]@{ SchemaVersion = 1; Scopes = $group }
            $json = $shardState | ConvertTo-Json -Depth 8 -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $payload = [Convert]::ToBase64String($bytes)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $configHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            $serviceScript = Get-LinuxScript -Name 'dhcp/configure-dhcp-server' -Variables @{ DHCP_STATE_B64 = $payload }
            $applied = Invoke-LinuxVmCommand -VmName $name -IPAddress $primary.ServerAddress -Sudo -TimeoutSeconds 600 `
                -BashCommand $serviceScript -DisplayName 'Apply authoritative DHCP configuration'
            if (-not $applied.CommandResult -or $applied.ScriptBlockOutput -notmatch 'DHCP_SERVER_READY') {
                throw "$name`: DHCP service reconciliation failed: $($applied.ScriptBlockOutput)"
            }
            $noteUpdate = [pscustomobject]@{
                infrastructureType        = 'MemLabsDhcpAppliance'
                inProgress                = $false
                success                   = $true
                schemaVersion             = 1
                applianceVersion          = 1
                shardNumber               = $index + 1
                ownedScopeIds             = @($group.ScopeId)
                appliedConfigHash          = $configHash
                lastSuccessfulReconcileUtc = [DateTime]::UtcNow.ToString('o')
            }
            Set-VMNote -VmName $name -VmNote $noteUpdate
            Write-Log "$name`: authoritative DHCP ready for $($group.Count) scope(s): $($group.ScopeId -join ', ')" -Success
        }
        foreach ($extra in @(Get-MemLabsDhcpApplianceVms | Where-Object { [int]$_.Note.shardNumber -gt $groups.Count })) {
            Write-Log "$($extra.VM.Name): removing surplus DHCP appliance shard after scope reconciliation." -LogOnly
            Remove-MemLabsOwnedDhcpAppliance -VM $extra.VM
        }
        return $true
    }
    finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Set-MemLabsDhcpApplianceReservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ScopeId,
        [Parameter(Mandatory = $true)] [string] $IPAddress,
        [Parameter(Mandatory = $true)] [string] $Mac,
        [ValidateSet('add', 'remove')] [string] $Action = 'add'
    )
    $scopeBase = $ScopeId -replace '\.0$', ''
    if ($ScopeId -notmatch '^\d{1,3}(\.\d{1,3}){2}\.0$' -or $IPAddress -notlike "$scopeBase.*") {
        throw "Reservation address $IPAddress does not belong to scope $ScopeId."
    }
    $lastOctet = [int](($IPAddress -split '\.')[-1])
    if ($lastOctet -lt 20 -or $lastOctet -gt 199) { return }
    $appliance = @(Get-MemLabsDhcpApplianceVms | Where-Object { $ScopeId -in @($_.Note.ownedScopeIds) } | Select-Object -First 1)
    if (-not $appliance) { throw "No DHCP appliance owns scope $ScopeId." }
    $serverIp = $ScopeId -replace '\.0$', '.19'
    $normalizedMac = ConvertTo-MemLabsNormalizedMac -MacAddress $Mac -Colon
    if (-not $normalizedMac) { throw "Invalid DHCP reservation MAC '$Mac'." }
    $script = Get-LinuxScript -Name 'dhcp/update-reservation' -Variables @{
        RESERVATION_ACTION = $Action
        RESERVATION_MAC    = $normalizedMac
        RESERVATION_IP     = $IPAddress
    }
    $result = Invoke-LinuxVmCommand -VmName $appliance[0].VM.Name -IPAddress $serverIp -Sudo -TimeoutSeconds 180 `
        -BashCommand $script -DisplayName "$Action DHCP reservation $IPAddress"
    if (-not $result.CommandResult -or $result.ScriptBlockOutput -notmatch "DHCP_RESERVATION_$($Action.ToUpperInvariant())") {
        throw "DHCP appliance reservation $Action failed for $IPAddress/$normalizedMac`: $($result.ScriptBlockOutput)"
    }
}

function Remove-MemLabsDhcpApplianceReservationByMac {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Mac)
    $normalizedMac = ConvertTo-MemLabsNormalizedMac -MacAddress $Mac -Colon
    if (-not $normalizedMac) { throw "Invalid DHCP reservation MAC '$Mac'." }
    foreach ($appliance in @(Get-MemLabsDhcpApplianceVms)) {
        $primaryScope = @($appliance.Note.ownedScopeIds | ForEach-Object { [string]$_ } | Sort-Object | Select-Object -First 1)
        if (-not $primaryScope) { continue }
        $serverIp = $primaryScope[0] -replace '\.0$', '.19'
        $script = Get-LinuxScript -Name 'dhcp/update-reservation' -Variables @{
            RESERVATION_ACTION = 'remove'
            RESERVATION_MAC    = $normalizedMac
            RESERVATION_IP     = ''
        }
        $result = Invoke-LinuxVmCommand -VmName $appliance.VM.Name -IPAddress $serverIp -Sudo -TimeoutSeconds 180 `
            -BashCommand $script -DisplayName "Remove DHCP reservation for $normalizedMac"
        if (-not $result.CommandResult -or $result.ScriptBlockOutput -notmatch 'DHCP_RESERVATION_REMOVE') {
            throw "DHCP appliance reservation removal failed for $normalizedMac on $($appliance.VM.Name): $($result.ScriptBlockOutput)"
        }
    }
}

function Get-MemLabsDhcpReservationIpForMac {
    param([string] $ScopeId, [string] $Mac)
    $wanted = ConvertTo-MemLabsNormalizedMac -MacAddress $Mac
    if (-not $wanted) { return $null }
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        $note = $null
        try { if ($vm.Notes) { $note = $vm.Notes | ConvertFrom-Json -ErrorAction Stop } } catch { }
        if (-not $note -or $note.infrastructureType) { continue }
        $network = if ($note.role -in @('InternetClient', 'AADClient')) { '172.31.250.0' } else { [string]$note.network }
        if ($network -ne $ScopeId) { continue }
        $switchName = if ($ScopeId -eq '172.31.250.0') { 'Internet' } elseif ($ScopeId -eq '10.250.250.0') { 'Cluster' } else { $ScopeId }
        $adapter = @(Get-MemLabsVmAdapters -VM $vm | Where-Object { $_.SwitchName -eq $switchName } | Select-Object -First 1)
        if ($adapter -and (ConvertTo-MemLabsNormalizedMac -MacAddress ([string]$adapter[0].MacAddress)) -eq $wanted) {
            if ($note.AssignedIP) { return [string]$note.AssignedIP }
            if ($note.LastKnownIP) { return [string]$note.LastKnownIP }
        }
    }
    return $null
}

function Get-MemLabsAllDhcpReservations {
    [CmdletBinding()]
    param()
    $desired = Get-MemLabsDhcpDesiredState
    $result = @()
    foreach ($scope in @($desired.Scopes)) {
        foreach ($reservation in @($scope.Reservations)) {
            $result += [pscustomobject]@{
                ScopeId = [string]$scope.ScopeId
                Mac     = (ConvertTo-MemLabsNormalizedMac -MacAddress ([string]$reservation.MacAddress)).ToUpperInvariant()
                Ip      = [string]$reservation.IPAddress
            }
        }
    }
    return $result
}

function Test-MemLabsDhcpApplianceScopeReady {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $ScopeId)
    $owners = @(Get-MemLabsDhcpApplianceVms | Where-Object { $ScopeId -in @($_.Note.ownedScopeIds) })
    return ($owners.Count -eq 1 -and $owners[0].VM.State -eq 'Running')
}

function Restart-MemLabsDhcpApplianceScope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $ScopeId)
    $owners = @(Get-MemLabsDhcpApplianceVms | Where-Object { $ScopeId -in @($_.Note.ownedScopeIds) })
    if ($owners.Count -ne 1) { throw "Expected one DHCP appliance owner for $ScopeId; found $($owners.Count)." }
    $primaryScope = @($owners[0].Note.ownedScopeIds | ForEach-Object { [string]$_ } | Sort-Object | Select-Object -First 1)
    $serverIp = $primaryScope[0] -replace '\.0$', '.19'
    $result = Invoke-LinuxVmCommand -VmName $owners[0].VM.Name -IPAddress $serverIp -Sudo -TimeoutSeconds 120 `
        -BashCommand "systemctl restart memlabs-dhcp.service && systemctl is-active --quiet memlabs-dhcp.service && echo DHCP_SERVICE_READY" `
        -DisplayName "Restart DHCP appliance for $ScopeId"
    if (-not $result.CommandResult -or $result.ScriptBlockOutput -notmatch 'DHCP_SERVICE_READY') {
        throw "DHCP appliance restart failed for $ScopeId`: $($result.ScriptBlockOutput)"
    }
    return $true
}
