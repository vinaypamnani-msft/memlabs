<#
.SYNOPSIS
    Collects read-only SQLAO cluster, failover-readiness, SQL, network, and DNS diagnostics.

.DESCRIPTION
    One-shot collector for the Phase 11 SQLAO failure:

      FAIL: Expected cluster IP '<ip>.201' not in DNS (found: )
      WARN: Cluster DNS has unexpected IP '' (expected '<ip>.201')
      WARN: Expected AG IP '<ip>.202' not in resolved addresses

    i.e. the cluster-name (CNO) and AG-listener A-records are missing / blank on
    the DC even though the AG is healthy and the listener accepts SQL connects.

    Runs from the Hyper-V host and uses PowerShell Direct to reach:

      - Each SQLAO node (default PT3-PS1SQLAO1 / PT3-PS1SQLAO2): dumps the full
        cluster picture (Get-Cluster / nodes / networks+roles / every resource +
        its private properties), with special focus on the Network Name (CNO +
        listener) and IP Address resources -- RegisterAllProvidersIP,
        HostRecordTTL, PublishPTRRecords, DnsName, online state, and the OWNER of
        each resource. Pulls the FailoverClustering System-event log entries that
        report DNS registration health (1196 / 1257 / 1228 / 1207 / 1579 / 1592 +
        recent context), a 30-min slice of the cluster.log grepped for the
        Netname/DNS registration path, the node's own NIC/SkipAsSource state, and
        what the node's resolver returns for the cluster + listener names.
        Also auto-DISCOVERS the cluster name, listener name(s), cluster IP and AG
        IP so the DC half needs no hand-entered names.

      - The DC / DNS server (default PT3-DC1): for the discovered names (cluster,
        listener, both nodes) dumps the RAW A-records (so a blank/empty RecordData
        is visible), each record's Timestamp (0 = static, non-zero = dynamic) and
        TTL, the zone's DynamicUpdate mode, and the zone + server aging/scavenging
        settings (a scavenge can delete a dynamically-registered CNO/listener
        record). Also dumps EVERY A-record in the zone matching the cluster
        prefix to surface duplicates / orphaned blanks.

    All output is written to a single timestamped file in vmbuild\logs so it can
    be parsed without further round-trips.

.EXAMPLE
    .\tools\Get-SqlaoDnsDiag.ps1 `
        -NodeVm FAB-PS1SQLAO1,FAB-PS1SQLAO2 `
        -DcVm FAB-DC1 -Domain fabrikam.com -DomainNetbios fabrikam `
        -AgName 'PS1 Availability Group'

.NOTES
    PS5.1-safe inside the in-guest scriptblocks (no ternary / null-conditional).
    The lab admin password is entered interactively via Get-Credential -- never
    passed on the command line and never seen by the model.
#>
[CmdletBinding()]
param(
    [string[]]$NodeVm = @('PT3-PS1SQLAO1', 'PT3-PS1SQLAO2'),
    [string]$DcVm = 'PT3-DC1',
    [string]$Domain = 'pstest3.com',
    [string]$DomainNetbios = 'pstest3',
    [string]$AdminName = 'admin',
    [string]$AgName = '',
    [string]$SqlInstanceName = 'MSSQLSERVER',
    [int]$ListenerPort = 1500,
    [int]$EndpointPort = 5022,
    [string]$SnapshotLabel = '',
    [ValidateRange(1, 24)]
    [int]$Hours = 4,
    # Optional manual override if cluster auto-discovery on the nodes fails.
    [string[]]$ExtraNames = @(),
    [PSCredential]$Credential
)

$ErrorActionPreference = 'Continue'
# Script lives in vmbuild\tools; write diagnostics to vmbuild\logs (one level up).
$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeLabel = [string]$SnapshotLabel -replace '[^A-Za-z0-9_-]', '-'
$labelSuffix = if ([string]::IsNullOrWhiteSpace($safeLabel)) { '' } else { "-$safeLabel" }
$outFile = Join-Path $logDir "sqlao-health-diag$labelSuffix-$stamp.txt"

function Add-Section {
    param([string]$Title, [object]$Body)
    $sep = ('=' * 78)
    Add-Content -Path $outFile -Value "`r`n$sep`r`n=== $Title`r`n$sep"
    if ($null -ne $Body) {
        Add-Content -Path $outFile -Value ($Body | Out-String)
    }
}

Add-Content -Path $outFile -Value "SQLAO post-deployment health diagnostic  ($stamp)"
if ($safeLabel) { Add-Content -Path $outFile -Value "Snapshot=$safeLabel" }
Add-Content -Path $outFile -Value "Nodes=$($NodeVm -join ', ')   DC=$DcVm   Domain=$Domain   AG='$AgName' Instance='$SqlInstanceName'"

# One password for the lab. Entered locally; never via the model.
if (-not $Credential) {
    $pw = (Get-Credential -UserName "$DomainNetbios\$AdminName" -Message "Enter the lab admin password for $DomainNetbios").Password
    $Credential = New-Object System.Management.Automation.PSCredential ("$DomainNetbios\$AdminName", $pw)
}
$cred = $Credential

# ---------------------------------------------------------------------------
#  Node collection (runs in-guest on each SQLAO node -- PS5.1)
#  Returns an object: .Text (the human report) + discovered names so the DC
#  half can query the exact records without hand-entered values.
# ---------------------------------------------------------------------------
$nodeScript = {
    param($ExpectedAgName, $SqlInstanceName, $OtherNode, $ListenerPort, $EndpointPort, $Hours)
    $script:out = [System.Collections.Generic.List[string]]::new()
    $script:findings = [System.Collections.Generic.List[string]]::new()
    $script:acquisitionErrors = [System.Collections.Generic.List[string]]::new()
    function W { param($t) $script:out.Add([string]$t) }
    function F { param($t) $script:findings.Add([string]$t); W "FINDING: $t" }
    function E { param($t) $script:acquisitionErrors.Add([string]$t); W "ERR $t" }
    function Test-TcpFast {
        param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 3000)
        $client = New-Object Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
            $client.EndConnect($async)
            return $true
        }
        catch { return $false }
        finally { $client.Close() }
    }

    $discClusterName = ''
    $discListeners = New-Object System.Collections.Generic.List[string]
    $discClusterIPs = New-Object System.Collections.Generic.List[string]
    $discAgIPs = New-Object System.Collections.Generic.List[string]
    $discNodes = New-Object System.Collections.Generic.List[string]
    $agOwnerPolicies = New-Object System.Collections.Generic.List[object]
    $ownerOutcomeScript = {
        param($Policies, $ReplicaRows)
        $sqlGroupNames = @($ReplicaRows | ForEach-Object { [string]$_.GroupName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique)
        foreach ($sqlGroupName in $sqlGroupNames) {
            $matchingPolicies = @($Policies | Where-Object { $_.GroupName -eq $sqlGroupName })
            if ($matchingPolicies.Count -eq 0) {
                F "CRITICAL: SQL availability group '$sqlGroupName' has no matching WSFC SQL Server Availability Group resource."
                continue
            }
            if ($matchingPolicies.Count -ne 1) {
                F "CRITICAL: SQL availability group '$sqlGroupName' has $($matchingPolicies.Count) matching WSFC SQL Server Availability Group resources; expected exactly one."
                continue
            }
            $policy = $matchingPolicies[0]
            if ($policy.ResourceState -ne 'Online') {
                F "CRITICAL: AG resource '$($policy.ResourceName)' is '$($policy.ResourceState)'."
            }
            if ([string]::IsNullOrWhiteSpace($policy.GroupOwner) -or
                $policy.PossibleOwners -notcontains $policy.GroupOwner) {
                F "CRITICAL: AG resource '$($policy.ResourceName)' cannot run on current group owner '$($policy.GroupOwner)'; possible owners are [$($policy.PossibleOwners -join ', ')]."
            }
            foreach ($replica in @($ReplicaRows | Where-Object { $_.GroupName -eq $sqlGroupName })) {
                $replicaNode = ((([string]$replica.replica_server_name -split '\\', 2)[0] -split '\.')[0])
                if ($replica.failover_mode_desc -eq 'AUTOMATIC' -and
                    $policy.PossibleOwners -notcontains $replicaNode) {
                    F "AUTOMATIC replica '$($replica.replica_server_name)' is absent from AG resource '$($policy.ResourceName)' possible owners [$($policy.PossibleOwners -join ', ')]."
                }
                elseif ($replica.failover_mode_desc -eq 'MANUAL' -and
                    $replicaNode -ne $policy.GroupOwner -and
                    $policy.PossibleOwners -notcontains $replicaNode) {
                    W "INFO: MANUAL secondary '$($replica.replica_server_name)' is intentionally absent from SQL-managed possible owners."
                }
            }
        }
    }

    Import-Module FailoverClusters -ErrorAction SilentlyContinue

    W "### Get-Cluster ###"
    try {
        $cl = Get-Cluster -ErrorAction Stop
        $discClusterName = [string]$cl.Name
        W ($cl | Format-List Name, Domain, * | Out-String)
    }
    catch { E "Get-Cluster: $($_.Exception.Message)" }

    W "### Get-ClusterQuorum ###"
    try {
        $quorum = Get-ClusterQuorum -ErrorAction Stop
        W ($quorum | Format-List Cluster, QuorumType, QuorumResource | Out-String)
    }
    catch { E "Get-ClusterQuorum: $($_.Exception.Message)" }

    W "### Get-ClusterNode ###"
    try {
        $nodes = Get-ClusterNode -ErrorAction Stop
        foreach ($n in $nodes) { $discNodes.Add([string]$n.Name) }
        W ($nodes | Format-Table Name, State, DynamicWeight, NodeWeight -AutoSize | Out-String)
    }
    catch { E "Get-ClusterNode: $($_.Exception.Message)" }

    W "### Get-ClusterNetwork (+ role: 1=Cluster-only, 3=Cluster+Client) ###"
    try {
        W (Get-ClusterNetwork -ErrorAction Stop | Format-Table Name, State, Role, Address, AddressMask -AutoSize | Out-String)
    }
    catch { E "Get-ClusterNetwork: $($_.Exception.Message)" }

    W "### All cluster resources (State / Type / OwnerGroup) ###"
    $allRes = @()
    try {
        $allRes = @(Get-ClusterResource -ErrorAction Stop)
        W ($allRes | Format-Table Name, State, ResourceType, OwnerGroup, OwnerNode -AutoSize | Out-String)
        W "--- private parameters for every cluster resource ---"
        foreach ($resource in $allRes) {
            W "----- '$($resource.Name)' ($($resource.ResourceType)) -----"
            try {
                foreach ($parameter in @($resource | Get-ClusterParameter -ErrorAction Stop)) {
                    W ("    {0,-28} = {1}" -f $parameter.Name, $parameter.Value)
                }
            }
            catch { E "Get-ClusterParameter '$($resource.Name)': $($_.Exception.Message)" }
        }
    }
    catch { E "Get-ClusterResource: $($_.Exception.Message)" }

    W "### Clustered role/resource owner policy ###"
    try {
        $candidateGroups = if ($ExpectedAgName) {
            @(Get-ClusterGroup -Name $ExpectedAgName -ErrorAction Stop)
        }
        else {
            @(Get-ClusterGroup -ErrorAction Stop | Where-Object {
                    $_.Name -notin 'Cluster Group', 'Available Storage'
                })
        }
        if ($candidateGroups.Count -eq 0) {
            F "CRITICAL: No availability-group clustered role was identified. Supply -AgName when auto-discovery is ambiguous."
        }
        foreach ($group in $candidateGroups) {
            W "----- Group '$($group.Name)' State=$($group.State) Owner=$($group.OwnerNode) -----"
            $groupOwnerName = if ($group.OwnerNode.PSObject.Properties['Name']) {
                [string]$group.OwnerNode.Name
            }
            else {
                [string]$group.OwnerNode
            }
            $preferred = $group | Get-ClusterOwnerNode -ErrorAction Stop
            $preferredNames = @($preferred.OwnerNodes | ForEach-Object {
                    if ($_.PSObject.Properties['Name']) { [string]$_.Name } else { [string]$_ }
                })
            W "    PreferredOwners = $($preferredNames -join ', ')"
            $groupResources = @($allRes | Where-Object { [string]$_.OwnerGroup -eq [string]$group.Name })
            foreach ($resource in $groupResources) {
                $possible = $resource | Get-ClusterOwnerNode -ErrorAction Stop
                $possibleNames = @($possible.OwnerNodes | ForEach-Object {
                        if ($_.PSObject.Properties['Name']) { [string]$_.Name } else { [string]$_ }
                    })
                W "    Resource '$($resource.Name)' Type='$($resource.ResourceType)' State='$($resource.State)' PossibleOwners=[$($possibleNames -join ', ')]"
                try {
                    $dependency = $resource | Get-ClusterResourceDependency -ErrorAction Stop
                    if ($dependency.DependencyExpression) { W "        Dependency=$($dependency.DependencyExpression)" }
                }
                catch {}
                if ($resource.Name -ieq $group.Name -and
                    [string]$resource.ResourceType -eq 'SQL Server Availability Group') {
                    $agOwnerPolicies.Add([pscustomobject]@{
                            GroupName = [string]$group.Name
                            GroupOwner = $groupOwnerName
                            ResourceName = [string]$resource.Name
                            ResourceState = [string]$resource.State
                            PossibleOwners = @($possibleNames)
                            PreferredOwners = @($preferredNames)
                        })
                }
            }
            if ($group.State -ne 'Online') {
                F "AG/clustered role '$($group.Name)' is '$($group.State)' on '$($group.OwnerNode)'."
            }
        }
    }
    catch {
        E "AG preferred/possible owner enumeration: $($_.Exception.Message)"
        F "Could not enumerate AG preferred/possible owners: $($_.Exception.Message)"
    }

    W "### Network Name resources -- FULL private properties (CNO + AG listeners) ###"
    W "    (key fields: Name, DnsName, RegisterAllProvidersIP, HostRecordTTL, PublishPTRRecords, StatusDNS)"
    try {
        $nnRes = @($allRes | Where-Object { $_.ResourceType -eq 'Network Name' })
        foreach ($r in $nnRes) {
            W "----- Network Name resource: '$($r.Name)'  State=$($r.State)  Owner=$($r.OwnerNode)  Group=$($r.OwnerGroup) -----"
            try {
                $params = $r | Get-ClusterParameter -ErrorAction Stop
                foreach ($p in $params) { W ("    {0,-28} = {1}" -f $p.Name, $p.Value) }
                # Record the DNS name this resource is supposed to publish.
                $dnsP = $params | Where-Object { $_.Name -eq 'DnsName' } | Select-Object -First 1
                $nameP = $params | Where-Object { $_.Name -eq 'Name' } | Select-Object -First 1
                $published = ''
                if ($dnsP -and $dnsP.Value) { $published = [string]$dnsP.Value }
                elseif ($nameP -and $nameP.Value) { $published = [string]$nameP.Value }
                if ($published) {
                    # core cluster name resource is usually named 'Cluster Name'
                    if ($r.Name -eq 'Cluster Name' -or ($script:discClusterName -and $published -ieq $script:discClusterName)) {
                        if (-not $script:discClusterName) { $script:discClusterName = $published }
                    }
                    else {
                        $script:discListeners.Add($published)
                    }
                }
            }
            catch { W "    ERR Get-ClusterParameter: $($_.Exception.Message)" }
        }
        if (-not $nnRes) { W "(no Network Name resources found)" }
    }
    catch { E "Network Name enumeration: $($_.Exception.Message)" }

    W "### IP Address resources -- FULL private properties (cluster IP + AG VIP) ###"
    try {
        $ipRes = @($allRes | Where-Object { $_.ResourceType -eq 'IP Address' })
        foreach ($r in $ipRes) {
            W "----- IP Address resource: '$($r.Name)'  State=$($r.State)  Group=$($r.OwnerGroup) -----"
            try {
                $params = $r | Get-ClusterParameter -ErrorAction Stop
                foreach ($p in $params) { W ("    {0,-28} = {1}" -f $p.Name, $p.Value) }
                $addrP = $params | Where-Object { $_.Name -eq 'Address' } | Select-Object -First 1
                if ($addrP -and $addrP.Value) {
                    # AG listener IP resource name usually contains the AG/listener name; core cluster IP is 'Cluster IP Address'
                    if ($r.Name -like 'Cluster IP Address*') { $script:discClusterIPs.Add([string]$addrP.Value) }
                    else { $script:discAgIPs.Add([string]$addrP.Value) }
                }
            }
            catch { W "    ERR Get-ClusterParameter: $($_.Exception.Message)" }
        }
        if (-not $ipRes) { W "(no IP Address resources found)" }
    }
    catch { E "IP Address enumeration: $($_.Exception.Message)" }

    W "### SQL/cluster services and TCP reachability ###"
    foreach ($serviceName in @('ClusSvc', $(if ($SqlInstanceName -ieq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$SqlInstanceName" }))) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            W ("    {0,-24} {1}" -f $service.Name, $service.Status)
            if ($service.Status -ne 'Running') { F "Service '$serviceName' is '$($service.Status)'." }
        }
        catch {
            E "Service '$serviceName' query: $($_.Exception.Message)"
            F "Service '$serviceName' could not be queried: $($_.Exception.Message)"
        }
    }
    if ($OtherNode) {
        $endpointReachable = Test-TcpFast -ComputerName $OtherNode -Port $EndpointPort
        W "    TCP $OtherNode`:$EndpointPort reachable=$endpointReachable"
        if (-not $endpointReachable) { F "HADR endpoint TCP $OtherNode`:$EndpointPort is unreachable from '$env:COMPUTERNAME'." }
    }
    $uniqueListeners = @($discListeners | Where-Object { $_ } | Select-Object -Unique)
    if ($uniqueListeners.Count -eq 0) { F "No availability-group listener Network Name was discovered." }
    $listenerProbeScript = {
        param($Listener, $Port, [string[]]$ResolvedAddresses)
        try {
            $listenerAddresses = if ($PSBoundParameters.ContainsKey('ResolvedAddresses')) {
                @($ResolvedAddresses | Where-Object { $_ } | Select-Object -Unique)
            }
            else {
                @([Net.Dns]::GetHostAddresses($Listener) |
                    Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
                    ForEach-Object { $_.IPAddressToString } | Select-Object -Unique)
            }
            $reachableAddresses = [System.Collections.Generic.List[string]]::new()
            foreach ($listenerAddress in $listenerAddresses) {
                $reachable = Test-TcpFast -ComputerName $listenerAddress -Port $Port
                W "    TCP $Listener [$listenerAddress]:$Port reachable=$reachable"
                if ($reachable) { $reachableAddresses.Add($listenerAddress) }
            }
            if ($listenerAddresses.Count -eq 0) {
                F "Listener '$Listener' resolved to no IPv4 addresses."
            }
            elseif ($reachableAddresses.Count -eq 0) {
                F "Listener TCP $Listener`:$Port is unreachable on every provider address [$($listenerAddresses -join ', ')] from '$env:COMPUTERNAME'."
            }
        }
        catch {
            E "Listener '$Listener' DNS/TCP probe: $($_.Exception.Message)"
            F "Listener '$Listener' DNS/TCP probe failed: $($_.Exception.Message)"
        }
    }
    foreach ($listener in $uniqueListeners) {
        & $listenerProbeScript -Listener $listener -Port $ListenerPort
    }

    W "### SQL Always On state (local SQL instance) ###"
    $sqlTarget = if ($SqlInstanceName -ieq 'MSSQLSERVER') { 'localhost' } else { "localhost\$SqlInstanceName" }
    $connection = $null
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = "Data Source=$sqlTarget;Initial Catalog=master;Integrated Security=True;Connect Timeout=10;Encrypt=False;TrustServerCertificate=True"
        $connection.Open()
        function Invoke-Q {
            param([string]$Query)
            $command = $connection.CreateCommand()
            $command.CommandText = $Query
            $command.CommandTimeout = 30
            $table = New-Object System.Data.DataTable
            $reader = $command.ExecuteReader()
            try { $table.Load($reader) } finally { $reader.Close(); $command.Dispose() }
            return , $table
        }
        function Invoke-SqlProbe {
            param([string]$Label, [string]$Query)
            try {
                $table = Invoke-Q -Query $Query
                return , $table
            }
            catch {
                E "SQL probe '$Label': $($_.Exception.Message)"
                F "SQL probe '$Label' failed: $($_.Exception.Message)"
                return $null
            }
        }

        $serverState = Invoke-SqlProbe -Label 'server service state' -Query @"
SELECT @@SERVERNAME AS ServerName,
       CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled,
       servicename, startup_type_desc, status_desc, service_account
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%'
"@
        if ($serverState) { W ($serverState | Format-Table -AutoSize | Out-String) }

        $agConfig = Invoke-SqlProbe -Label 'availability group configuration' -Query @"
SELECT name, automated_backup_preference_desc, failure_condition_level, health_check_timeout
FROM sys.availability_groups
"@
        W "--- sys.availability_groups ---"
        if ($agConfig) {
            W ($agConfig | Format-Table -AutoSize | Out-String)
            if ($agConfig.Rows.Count -eq 0) { F "No SQL availability group is configured on '$sqlTarget'." }
        }

        $replicaConfig = Invoke-SqlProbe -Label 'configured replicas' -Query @"
SELECT ag.name AS GroupName, ar.replica_server_name, ar.endpoint_url,
       ar.availability_mode_desc, ar.failover_mode_desc, ar.seeding_mode_desc,
       ar.session_timeout, ar.primary_role_allow_connections_desc,
       ar.secondary_role_allow_connections_desc
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
ORDER BY ag.name, ar.replica_server_name
"@
        W "--- configured replicas ---"
        if ($replicaConfig) {
            W ($replicaConfig | Format-Table -AutoSize | Out-String)
            if ($replicaConfig.Rows.Count -eq 0) { F "No availability replicas are configured on '$sqlTarget'." }
            foreach ($row in $replicaConfig) {
                if ($row.failover_mode_desc -eq 'MANUAL') {
                    F "INFO: Replica '$($row.replica_server_name)' is configured for MANUAL failover; powering off the primary will not automatically promote the secondary."
                }
            }
            & $ownerOutcomeScript -Policies $agOwnerPolicies -ReplicaRows $replicaConfig.Rows
        }

        $replicaState = Invoke-SqlProbe -Label 'replica runtime state' -Query @"
SELECT ag.name AS GroupName, ar.replica_server_name, rs.is_local,
       rs.role_desc, rs.operational_state_desc, rs.connected_state_desc,
       rs.recovery_health_desc, rs.synchronization_health_desc,
       rs.last_connect_error_number, rs.last_connect_error_description,
       rs.last_connect_error_timestamp
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON ar.replica_id = rs.replica_id
ORDER BY ag.name, ar.replica_server_name
"@
        W "--- replica runtime state ---"
        if ($replicaState) {
            W ($replicaState | Format-Table -AutoSize | Out-String)
            if ($replicaState.Rows.Count -eq 0) { F "Replica runtime state returned no rows on '$sqlTarget'." }
            foreach ($row in $replicaState) {
                if ($row.is_local -and ($row.role_desc -eq 'RESOLVING' -or $row.connected_state_desc -eq 'DISCONNECTED')) {
                    F "Local replica '$($row.replica_server_name)' is role=$($row.role_desc), connection=$($row.connected_state_desc), health=$($row.synchronization_health_desc), lastError=$($row.last_connect_error_number) $($row.last_connect_error_description)."
                }
            }
        }

        $databaseState = Invoke-SqlProbe -Label 'database runtime state' -Query @"
SELECT ag.name AS GroupName, ar.replica_server_name, DB_NAME(drs.database_id) AS DatabaseName,
       drs.is_local, drs.synchronization_state_desc, drs.synchronization_health_desc,
       drs.database_state_desc, drs.is_suspended, drs.suspend_reason_desc,
       drs.log_send_queue_size, drs.redo_queue_size, drs.last_commit_time
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
ORDER BY ag.name, ar.replica_server_name, DatabaseName
"@
        W "--- database runtime state ---"
        if ($databaseState) {
            W ($databaseState | Format-Table -AutoSize | Out-String)
            if ($databaseState.Rows.Count -eq 0) { F "Availability database runtime state returned no rows on '$sqlTarget'." }
        }

        $failoverReady = Invoke-SqlProbe -Label 'database failover readiness' -Query @"
SELECT adc.database_name, ar.replica_server_name,
       drcs.is_database_joined, drcs.is_failover_ready
FROM sys.dm_hadr_database_replica_cluster_states drcs
JOIN sys.availability_databases_cluster adc ON drcs.group_database_id = adc.group_database_id
JOIN sys.availability_replicas ar ON drcs.replica_id = ar.replica_id
ORDER BY adc.database_name, ar.replica_server_name
"@
        W "--- cluster failover readiness ---"
        if ($failoverReady) {
            W ($failoverReady | Format-Table -AutoSize | Out-String)
            if ($failoverReady.Rows.Count -eq 0) { F "Database failover-readiness state returned no rows on '$sqlTarget'." }
            foreach ($row in $failoverReady) {
                if ($row.replica_server_name -like "$env:COMPUTERNAME*" -and -not $row.is_failover_ready) {
                    F "Database '$($row.database_name)' is not failover-ready on local replica '$($row.replica_server_name)'."
                }
            }
        }

        $endpoints = Invoke-SqlProbe -Label 'HADR endpoints' -Query @"
SELECT e.name, e.state_desc, e.role_desc, e.connection_auth_desc,
       e.encryption_algorithm_desc, t.port, t.ip_address
FROM sys.database_mirroring_endpoints e
LEFT JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id
"@
        W "--- database mirroring/HADR endpoints ---"
        if ($endpoints) {
            W ($endpoints | Format-Table -AutoSize | Out-String)
            if ($endpoints.Rows.Count -eq 0) { F "No database mirroring/HADR endpoint was found on '$sqlTarget'." }
            foreach ($endpoint in $endpoints) {
                if ($endpoint.state_desc -ne 'STARTED') { F "HADR endpoint '$($endpoint.name)' is '$($endpoint.state_desc)'." }
            }
        }

        $xeTargets = Invoke-SqlProbe -Label 'AlwaysOn_health extended events' -Query @"
SELECT configured.name AS SessionName,
       CASE WHEN running.address IS NULL THEN N'STOPPED' ELSE N'STARTED' END AS SessionState,
       target.target_name,
       CAST(target.target_data AS nvarchar(max)) AS TargetData
FROM sys.server_event_sessions configured
LEFT JOIN sys.dm_xe_sessions running ON configured.name = running.name
LEFT JOIN sys.dm_xe_session_targets target ON running.address = target.event_session_address
WHERE configured.name = N'AlwaysOn_health'
"@
        W "--- AlwaysOn_health extended-event target ---"
        if ($xeTargets) {
            W ($xeTargets | Format-List * | Out-String)
            $xeOutcomeScript = {
                param($Rows, $SqlTarget)
                if ($Rows.Count -eq 0) {
                    F "AlwaysOn_health extended-event session is not defined on '$SqlTarget'."
                }
                elseif ($Rows[0].SessionState -ne 'STARTED') {
                    F "AlwaysOn_health extended-event session is defined but stopped on '$SqlTarget'."
                }
                elseif ([Convert]::IsDBNull($Rows[0].target_name) -or
                    [string]::IsNullOrWhiteSpace([string]$Rows[0].target_name)) {
                    F "AlwaysOn_health is running without an active target on '$SqlTarget'."
                }
            }
            & $xeOutcomeScript -Rows $xeTargets.Rows -SqlTarget $sqlTarget
        }

        $errorLogInfo = Invoke-SqlProbe -Label 'SQL ERRORLOG path' -Query "SELECT CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(4000)) AS ErrorLogFileName"
        $errorLogPath = if ($errorLogInfo -and $errorLogInfo.Rows.Count -gt 0) { [string]$errorLogInfo.Rows[0].ErrorLogFileName } else { '' }
        if ($errorLogPath -and (Test-Path -LiteralPath $errorLogPath)) {
            W "--- SQL ERRORLOG HADR/failover lines (tail) ---"
            $patterns = 'Always On|availability replica|availability group|HADR|mirroring endpoint|connection timeout|352\d\d|4100[5-9]|411\d\d|lost quorum'
            foreach ($line in @(Get-Content -LiteralPath $errorLogPath -Tail 5000 -ErrorAction SilentlyContinue |
                    Select-String -Pattern $patterns | Select-Object -Last 250)) {
                W $line.Line
            }
        }
    }
    catch {
        E "SQL Always On query on '$sqlTarget': $($_.Exception.Message)"
        F "SQL Always On query failed on '$sqlTarget': $($_.Exception.Message)"
    }
    finally { if ($connection) { $connection.Dispose() } }

    W "### FailoverClustering DNS-registration events (System log) ###"
    W "    1196 = Netname failed DNS registration | 1257 = couldn't register, check perms | 1228/1207/1579/1592 = related"
    try {
        $evAll = @(Get-WinEvent -FilterHashtable @{
                LogName = 'System'
                ProviderName = 'Microsoft-Windows-FailoverClustering'
                StartTime = (Get-Date).AddHours(-$Hours)
            } -MaxEvents 500 -ErrorAction SilentlyContinue)
        $dnsIds = 1196, 1257, 1228, 1207, 1579, 1592, 1205, 1069
        $dnsEv = @($evAll | Where-Object { $dnsIds -contains $_.Id })
        if ($dnsEv) {
            W "--- DNS/registration-specific events (most recent 30) ---"
            foreach ($e in ($dnsEv | Select-Object -First 30)) {
                W ("[{0}] Id={1} {2}" -f $e.TimeCreated, $e.Id, $e.LevelDisplayName)
                W (("    " + (($e.Message -split "`r?`n") -join ' / ')).Substring(0, [Math]::Min(360, ("    " + (($e.Message -split "`r?`n") -join ' / ')).Length)))
            }
        }
        else { W "(no 1196/1257/1228/1207/1579/1592 DNS-registration events found)" }
        W "--- most recent 25 FailoverClustering events (context) ---"
        foreach ($e in ($evAll | Select-Object -First 25)) {
            W ("[{0}] Id={1} {2}: {3}" -f $e.TimeCreated, $e.Id, $e.LevelDisplayName, (($e.Message -split "`r?`n")[0]))
        }
    }
    catch { E "cluster events: $($_.Exception.Message)" }

    W "### cluster.log (last $Hours hour(s)) grepped for AG/resource/DNS/failover ###"
    $clusterLogDir = Join-Path $env:TEMP ("sqlao-clusterlog-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $clusterLogDir -Force -ErrorAction Stop | Out-Null
        $rep = Get-ClusterLog -Node $env:COMPUTERNAME -TimeSpan ($Hours * 60) -UseLocalTime -Destination $clusterLogDir -ErrorAction Stop
        $logFile = $null
        if ($rep) {
            $cand = @(Get-ChildItem -Path $clusterLogDir -Filter '*cluster.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($cand) { $logFile = $cand[0].FullName }
        }
        if ($logFile -and (Test-Path $logFile)) {
            $hits = Select-String -Path $logFile -Pattern 'availability|always.?on|ag |possible owner|preferred owner|online|offline|failed|71397|713cf|1069|1205|Netname|DnsName|register|DNS|RegisterAllProviders|PublishPTR' -ErrorAction SilentlyContinue
            foreach ($h in ($hits | Select-Object -Last 300)) { W $h.Line }
        }
        else { W "(cluster.log not produced)" }
    }
    catch { E "Get-ClusterLog: $($_.Exception.Message)" }
    finally {
        if (Test-Path -LiteralPath $clusterLogDir) {
            Remove-Item -LiteralPath $clusterLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    W "### Node NICs / DNS-client registration / SkipAsSource ###"
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' }
        W ($ips | Format-Table IPAddress, PrefixLength, InterfaceAlias, SkipAsSource, PrefixOrigin -AutoSize | Out-String)
        W "--- Get-DnsClient RegisterThisConnectionsAddress ---"
        W (Get-DnsClient -ErrorAction SilentlyContinue | Format-Table InterfaceAlias, RegisterThisConnectionsAddress, ConnectionSpecificSuffix -AutoSize | Out-String)
    }
    catch { E "NIC state: $($_.Exception.Message)" }

    W "### Node resolver view of cluster + listener names ###"
    try {
        $names = New-Object System.Collections.Generic.List[string]
        if ($discClusterName) { $names.Add($discClusterName) }
        foreach ($l in $discListeners) { if ($l) { $names.Add($l) } }
        foreach ($nm in ($names | Select-Object -Unique)) {
            W "--- Resolve-DnsName $nm (node's configured DNS) ---"
            try { W (Resolve-DnsName -Name $nm -Type A -ErrorAction Stop | Format-Table Name, Type, IPAddress, TTL -AutoSize | Out-String) }
            catch { W "    Resolve-DnsName $nm FAILED: $($_.Exception.Message)" }
        }
    }
    catch { E "resolver view: $($_.Exception.Message)" }

    W "### nltest /dsgetdc (which DC is this node bound to) ###"
    try {
        $nltestOutput = @(& nltest "/dsgetdc:$env:USERDNSDOMAIN" 2>&1)
        if ($LASTEXITCODE -ne 0) { E "nltest exited $LASTEXITCODE`: $($nltestOutput -join ' | ')" }
        else { W ($nltestOutput | Out-String) }
    }
    catch { E "nltest: $($_.Exception.Message)" }

    W "### Computer object for the cluster (CNO) in AD -- enabled? ###"
    try {
        if ($discClusterName) {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.Filter = "(&(objectClass=computer)(cn=$discClusterName))"
            $r = $searcher.FindOne()
            if ($r) {
                $uac = [int]$r.Properties['useraccountcontrol'][0]
                $disabled = (($uac -band 0x2) -ne 0)
                W "CNO '$discClusterName' found in AD. userAccountControl=$uac Disabled=$disabled whenCreated=$($r.Properties['whencreated'][0])"
            }
            else { W "CNO '$discClusterName' NOT found in AD via cn search." }
        }
    }
    catch { E "CNO AD lookup: $($_.Exception.Message)" }

    return [pscustomobject]@{
        Text        = ($script:out -join "`r`n")
        Findings    = @($script:findings)
        ClusterName = $discClusterName
        Listeners   = @($discListeners | Select-Object -Unique)
        ClusterIPs  = @($discClusterIPs | Select-Object -Unique)
        AgIPs       = @($discAgIPs | Select-Object -Unique)
        Nodes       = @($discNodes | Select-Object -Unique)
        AcquisitionErrors = @($script:acquisitionErrors)
    }
}

# ---------------------------------------------------------------------------
#  DC / DNS collection (runs in-guest on the DC -- PS5.1)
# ---------------------------------------------------------------------------
$dcScript = {
    param($Domain, $Names)
    $script:out = [System.Collections.Generic.List[string]]::new()
    $script:acquisitionErrors = [System.Collections.Generic.List[string]]::new()
    function W { param($t) $script:out.Add([string]$t) }
    function E { param($t) $script:acquisitionErrors.Add([string]$t); W "ERR $t" }

    Import-Module DnsServer -ErrorAction SilentlyContinue

    W "### DC time / uptime ###"
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        W ("Now={0}  LastBoot={1}" -f (Get-Date), $os.LastBootUpTime)
    }
    catch { E "time: $($_.Exception.Message)" }

    W "### Zone '$Domain' settings (DynamicUpdate mode) ###"
    try { W (Get-DnsServerZone -Name $Domain -ErrorAction Stop | Format-List ZoneName, ZoneType, DynamicUpdate, IsDsIntegrated, IsAutoCreated | Out-String) }
    catch { E "Get-DnsServerZone: $($_.Exception.Message)" }

    W "### Zone aging + server scavenging (a scavenge deletes dynamic CNO/listener records) ###"
    try { W (Get-DnsServerZoneAging -Name $Domain -ErrorAction Stop | Format-List * | Out-String) }
    catch { E "Get-DnsServerZoneAging: $($_.Exception.Message)" }
    try { W (Get-DnsServerScavenging -ErrorAction Stop | Format-List * | Out-String) }
    catch { E "Get-DnsServerScavenging: $($_.Exception.Message)" }

    W "### Per-name A-records (RAW -- shows blank/empty RecordData; Timestamp 0=static, else dynamic) ###"
    foreach ($nm in ($Names | Where-Object { $_ } | Select-Object -Unique)) {
        $short = $nm
        if ($short -like "*.$Domain") { $short = $short.Substring(0, $short.Length - ($Domain.Length + 1)) }
        W "----- '$short' (A) in $Domain -----"
        try {
            $recs = @(Get-DnsServerResourceRecord -ZoneName $Domain -Name $short -RRType A -ComputerName $env:COMPUTERNAME -ErrorAction Stop)
            if (-not $recs) { W "    (no A record -- name does not exist in zone)" }
            foreach ($rec in $recs) {
                $ip = ''
                try { if ($rec.RecordData -and $rec.RecordData.IPv4Address) { $ip = $rec.RecordData.IPv4Address.IPAddressToString } } catch {}
                W ("    HostName='{0}'  IPv4='{1}'  Timestamp='{2}'  TTL='{3}'  Type='{4}'" -f $rec.HostName, $ip, $rec.Timestamp, $rec.TimeToLive, $rec.RecordType)
            }
            # also dump the raw object for the first record so any odd shape is visible
            if ($recs) { W "    --- raw first record ---"; W (($recs[0] | Format-List * | Out-String)) }
        }
        catch { E "Get-DnsServerResourceRecord '$short': $($_.Exception.Message)" }
    }

    W "### ALL A-records in zone matching cluster/listener/node prefixes (catch duplicates / orphan blanks) ###"
    try {
        $prefixes = @()
        foreach ($nm in ($Names | Where-Object { $_ })) {
            $s = $nm
            if ($s -like "*.$Domain") { $s = $s.Substring(0, $s.Length - ($Domain.Length + 1)) }
            # use the first 3 chars (deployment prefix, e.g. PT3) plus the full short name
            if ($s.Length -ge 3) { $prefixes += $s.Substring(0, 3) }
            $prefixes += $s
        }
        $prefixes = @($prefixes | Select-Object -Unique)
        $allA = @(Get-DnsServerResourceRecord -ZoneName $Domain -RRType A -ComputerName $env:COMPUTERNAME -ErrorAction Stop)
        $match = @($allA | Where-Object { $h = $_.HostName; ($prefixes | Where-Object { $h -like "$_*" }).Count -gt 0 })
        foreach ($rec in $match) {
            $ip = ''
            try { if ($rec.RecordData -and $rec.RecordData.IPv4Address) { $ip = $rec.RecordData.IPv4Address.IPAddressToString } } catch {}
            W ("    {0,-24} IPv4='{1}'  Timestamp='{2}'" -f $rec.HostName, $ip, $rec.Timestamp)
        }
        if (-not $match) { W "(no matching A records)" }
    }
    catch { E "all-A scan: $($_.Exception.Message)" }

    W "### DNS Server event log -- recent registration/update events (last 20) ###"
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'DNS Server' } -MaxEvents 20 -ErrorAction SilentlyContinue)
        foreach ($e in $ev) { W ("[{0}] Id={1} {2}: {3}" -f $e.TimeCreated, $e.Id, $e.LevelDisplayName, (($e.Message -split "`r?`n")[0])) }
        if (-not $ev) { W "(no DNS Server log events)" }
    }
    catch { E "DNS Server log: $($_.Exception.Message)" }

    return [pscustomobject]@{
        Text = ($script:out -join "`r`n")
        AcquisitionErrors = @($script:acquisitionErrors)
    }
}

# ---------------------------------------------------------------------------
#  Orchestrate
# ---------------------------------------------------------------------------
$collectedNames = New-Object System.Collections.Generic.List[string]
$allFindings = New-Object System.Collections.Generic.List[string]
$collectionErrors = New-Object System.Collections.Generic.List[string]
foreach ($e in $ExtraNames) { if ($e) { $collectedNames.Add($e) } }

foreach ($node in $NodeVm) {
    Write-Host "Collecting from SQLAO node '$node' ..." -ForegroundColor Cyan
    try {
        $otherNode = [string]($NodeVm | Where-Object { $_ -ne $node } | Select-Object -First 1)
        $res = Invoke-Command -VMName $node -Credential $cred -ScriptBlock $nodeScript `
            -ArgumentList $AgName, $SqlInstanceName, $otherNode, $ListenerPort, $EndpointPort, $Hours -ErrorAction Stop
        Add-Section -Title "SQLAO node: $node" -Body $res.Text
        foreach ($finding in @($res.Findings)) { if ($finding) { $allFindings.Add("$node`: $finding") } }
        foreach ($collectionError in @($res.AcquisitionErrors)) {
            if ($collectionError) { $collectionErrors.Add("$node`: $collectionError") }
        }
        if ($res.ClusterName) { $collectedNames.Add($res.ClusterName) }
        foreach ($l in $res.Listeners) { if ($l) { $collectedNames.Add($l) } }
        foreach ($n in $res.Nodes) { if ($n) { $collectedNames.Add($n) } }
        # record discovered IPs in the header so the DC dump is interpretable
        Add-Content -Path $outFile -Value ("    [discovered on $node] Cluster='{0}' Listeners='{1}' ClusterIPs='{2}' AgIPs='{3}'" -f `
                $res.ClusterName, ($res.Listeners -join ','), ($res.ClusterIPs -join ','), ($res.AgIPs -join ','))
    }
    catch {
        Add-Section -Title "SQLAO node: $node -- COLLECTION FAILED" -Body $_.Exception.Message
        $collectionError = "$node`: COLLECTION FAILED: $($_.Exception.Message)"
        $collectionErrors.Add($collectionError)
        $allFindings.Add($collectionError)
    }
}

# Always include the node short-names themselves so the DC dumps their A-records too.
foreach ($node in $NodeVm) { $collectedNames.Add($node) }
$namesForDc = @($collectedNames | Where-Object { $_ } | Select-Object -Unique)
Add-Content -Path $outFile -Value "`r`nNames queried on DC: $($namesForDc -join ', ')"

Write-Host "Collecting from DC / DNS '$DcVm' ..." -ForegroundColor Cyan
try {
    $dcResult = Invoke-Command -VMName $DcVm -Credential $cred -ScriptBlock $dcScript -ArgumentList $Domain, $namesForDc -ErrorAction Stop
    Add-Section -Title "DC / DNS: $DcVm ($Domain)" -Body $dcResult.Text
    foreach ($collectionError in @($dcResult.AcquisitionErrors)) {
        if ($collectionError) { $collectionErrors.Add("$DcVm`: $collectionError") }
    }
}
catch {
    Add-Section -Title "DC / DNS: $DcVm -- COLLECTION FAILED" -Body $_.Exception.Message
    $collectionError = "$DcVm`: DNS COLLECTION FAILED: $($_.Exception.Message)"
    $collectionErrors.Add($collectionError)
    $allFindings.Add($collectionError)
}

foreach ($collectionError in $collectionErrors) {
    if ($allFindings -notcontains $collectionError) {
        $allFindings.Add("COLLECTION INCOMPLETE: $collectionError")
    }
}
if ($allFindings.Count -eq 0) {
    $allFindings.Add('No collector-detected faults. Review the detailed cluster/SQL event sections for transient failures.')
}
Add-Section -Title 'FINDINGS SUMMARY' -Body ($allFindings -join "`r`n")

$zipFile = [IO.Path]::ChangeExtension($outFile, '.zip')
Compress-Archive -LiteralPath $outFile -DestinationPath $zipFile -Force -ErrorAction Stop
Write-Host ""
Write-Host "Diagnostic written to:" -ForegroundColor Green
Write-Host "  $outFile"
Write-Host "Shareable archive:" -ForegroundColor Green
Write-Host "  $zipFile"
return [pscustomobject]@{
    SnapshotLabel = $safeLabel
    ReportPath = $outFile
    ArchivePath = $zipFile
    Findings = @($allFindings)
    CollectionComplete = $collectionErrors.Count -eq 0
    CollectionErrors = @($collectionErrors)
}
