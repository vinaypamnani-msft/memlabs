<#
.SYNOPSIS
    Performs a guarded, planned no-data-loss SQLAO failover and failback test.
.DESCRIPTION
    Runs from the Hyper-V host with PowerShell Direct. The test refuses to move
    the availability group unless both replicas are synchronous, connected and
    healthy, and every database on the target is synchronized and failover-ready.

    The first transition is initiated through SQL on the target secondary, never
    through Failover Cluster Manager. Listener connectivity is then verified with
    MultiSubnetFailover before the same checks and planned failback are performed.

    This script never uses FORCE_FAILOVER_ALLOW_DATA_LOSS and never powers off a VM.
.EXAMPLE
    .\tools\Test-SqlAoPlannedFailover.ps1 `
        -NodeVm FAB-PS1SQLAO1,FAB-PS1SQLAO2 `
        -DomainNetbios fabrikam -AdminName admin `
        -AgName 'PS1 Availability Group' `
        -ListenerName FAB-ALWAYSON -Database CM_PS1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateCount(2, 2)]
    [string[]]$NodeVm,

    [Parameter(Mandatory)]
    [string]$DomainNetbios,

    [string]$AdminName = 'admin',
    [string]$Domain = '',
    [string]$DcVm = '',

    [Parameter(Mandatory)]
    [string]$AgName,

    [Parameter(Mandatory)]
    [string]$ListenerName,

    [string]$SqlInstanceName = 'MSSQLSERVER',
    [int]$ListenerPort = 1500,
    [string]$Database = 'CM_PS1',

    [ValidateRange(60, 900)]
    [int]$TimeoutSeconds = 300,

    [ValidateRange(1, 24)]
    [int]$HealthHours = 4,

    [switch]$NoFailback,
    [switch]$SkipHealthSnapshots,
    [PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'
if (-not $Credential) {
    $password = (Get-Credential -UserName "$DomainNetbios\$AdminName" -Message "Enter the lab administrator credential").Password
    $Credential = [PSCredential]::new("$DomainNetbios\$AdminName", $password)
}

$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath = Join-Path $logDir ("sqlao-planned-failover-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$healthCollectorPath = Join-Path $PSScriptRoot 'Get-SqlaoDnsDiag.ps1'
$healthCollectorInvoker = {
    param([string]$Path, [hashtable]$Parameters)
    & $Path @Parameters
}
$script:healthSnapshotEnvironment = $null
$script:healthSnapshotArtifacts = [Collections.Generic.List[object]]::new()
$script:healthSnapshotFailures = [Collections.Generic.List[string]]::new()

function Write-TestLog {
    param([string]$Message)
    $line = '[{0:O}] {1}' -f (Get-Date), $Message
    Write-Host $Message
    try { Add-Content -LiteralPath $logPath -Value $line -ErrorAction Stop }
    catch { Write-Warning "Could not append to '$logPath': $($_.Exception.Message)" }
}

function Invoke-NodeCommand {
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [datetime]$Deadline = [datetime]::MinValue
    )
    if ($Deadline -eq [datetime]::MinValue) {
        return Invoke-Command -VMName $VmName -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
    $remaining = [int][Math]::Floor(($Deadline - (Get-Date)).TotalSeconds)
    if ($remaining -le 0) { throw "Deadline expired before contacting '$VmName'." }
    $job = $null
    try {
        $job = Invoke-Command -VMName $VmName -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob -ErrorAction Stop
        $remaining = [int][Math]::Floor(($Deadline - (Get-Date)).TotalSeconds)
        if ($remaining -le 0) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "PowerShell Direct operation on '$VmName' exceeded its deadline while starting."
        }
        if (-not (Wait-Job -Job $job -Timeout $remaining)) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "PowerShell Direct operation on '$VmName' exceeded the remaining ${remaining}s deadline."
        }
        if ((Get-Date) -ge $Deadline) {
            throw "PowerShell Direct operation on '$VmName' completed after its deadline."
        }
        if ($job.State -ne 'Completed') {
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
            throw "PowerShell Direct operation on '$VmName' ended in state '$($job.State)': $($reason.Message)"
        }
        $result = Receive-Job -Job $job -ErrorAction Stop
        if ((Get-Date) -ge $Deadline) {
            throw "PowerShell Direct operation on '$VmName' exceeded its deadline while receiving results."
        }
        return $result
    }
    finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}

function Resolve-HealthSnapshotEnvironment {
    if ($SkipHealthSnapshots) { return $null }
    $resolvedDomain = [string]$Domain
    $resolvedDcVm = [string]$DcVm
    if ([string]::IsNullOrWhiteSpace($resolvedDomain) -or [string]::IsNullOrWhiteSpace($resolvedDcVm)) {
        $discovery = Invoke-NodeCommand -VmName $NodeVm[0] -ScriptBlock {
            param($DomainHint)
            $domainName = [string]$DomainHint
            if ([string]::IsNullOrWhiteSpace($domainName)) {
                $domainName = [string]$env:USERDNSDOMAIN
            }
            if ([string]::IsNullOrWhiteSpace($domainName)) {
                $domainName = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
            }
            $dcName = [string]$env:LOGONSERVER
            if ($dcName) { $dcName = $dcName.TrimStart('\') }
            if ([string]::IsNullOrWhiteSpace($dcName) -and $domainName) {
                $nltest = @(& nltest "/dsgetdc:$domainName" 2>&1)
                $dcLine = $nltest | Where-Object { $_ -match '^\s*DC:\s+\\\\([^\s.]+)' } | Select-Object -First 1
                if ($dcLine -and $dcLine -match '^\s*DC:\s+\\\\([^\s.]+)') { $dcName = $Matches[1] }
            }
            [pscustomobject]@{ Domain = $domainName; DcVm = $dcName }
        } -ArgumentList $resolvedDomain -Deadline (Get-Date).AddSeconds($TimeoutSeconds)
        if ([string]::IsNullOrWhiteSpace($resolvedDomain)) { $resolvedDomain = [string]$discovery.Domain }
        if ([string]::IsNullOrWhiteSpace($resolvedDcVm)) { $resolvedDcVm = [string]$discovery.DcVm }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedDomain) -or [string]::IsNullOrWhiteSpace($resolvedDcVm)) {
        throw 'Could not discover the DNS domain or DC VM for health snapshots. Supply -Domain and -DcVm explicitly.'
    }
    $dcState = Get-VM -Name $resolvedDcVm -ErrorAction Stop
    if ($dcState.State -ne 'Running') {
        throw "DC VM '$resolvedDcVm' is '$($dcState.State)'; health snapshots require it to be running."
    }
    return [pscustomobject]@{ Domain = $resolvedDomain; DcVm = $resolvedDcVm }
}

function Invoke-HealthSnapshot {
    param([Parameter(Mandatory)][string]$Label)
    if ($SkipHealthSnapshots) {
        Write-TestLog "Health snapshot '$Label' skipped by request."
        return $null
    }
    if (-not $script:healthSnapshotEnvironment) {
        $script:healthSnapshotEnvironment = Resolve-HealthSnapshotEnvironment
    }
    if (-not (Test-Path -LiteralPath $healthCollectorPath)) {
        throw "SQLAO health collector was not found at '$healthCollectorPath'."
    }
    $collectorParameters = @{
        NodeVm = @($NodeVm)
        DcVm = [string]$script:healthSnapshotEnvironment.DcVm
        Domain = [string]$script:healthSnapshotEnvironment.Domain
        DomainNetbios = $DomainNetbios
        AdminName = $AdminName
        AgName = $AgName
        SqlInstanceName = $SqlInstanceName
        ListenerPort = $ListenerPort
        Hours = $HealthHours
        SnapshotLabel = $Label
        Credential = $Credential
    }
    $collectorOutput = @(& $healthCollectorInvoker $healthCollectorPath $collectorParameters)
    $artifact = @($collectorOutput | Where-Object {
            $_ -and $_.PSObject.Properties['ReportPath'] -and $_.PSObject.Properties['ArchivePath']
        } | Select-Object -Last 1)
    if ($artifact.Count -ne 1 -or
        -not (Test-Path -LiteralPath $artifact[0].ReportPath) -or
        -not (Test-Path -LiteralPath $artifact[0].ArchivePath)) {
        throw "Health snapshot '$Label' did not produce a report and archive."
    }
    if (-not $artifact[0].PSObject.Properties['CollectionComplete'] -or
        -not [bool]$artifact[0].CollectionComplete) {
        $collectionErrors = @($artifact[0].CollectionErrors | Where-Object { $_ })
        throw "Health snapshot '$Label' preserved incomplete artifacts report='$($artifact[0].ReportPath)' archive='$($artifact[0].ArchivePath)': $($collectionErrors -join ' | ')"
    }
    Write-TestLog "Health snapshot '$Label' captured: report='$($artifact[0].ReportPath)' archive='$($artifact[0].ArchivePath)'."
    return $artifact[0]
}

function Save-HealthSnapshot {
    param(
        [Parameter(Mandatory)][string]$Label,
        [switch]$Required
    )
    try {
        $artifact = Invoke-HealthSnapshot -Label $Label
        if ($artifact) { $script:healthSnapshotArtifacts.Add($artifact) }
    }
    catch {
        $message = "Health snapshot '$Label' failed: $($_.Exception.Message)"
        Write-TestLog $message
        if ($Required) { throw }
        $script:healthSnapshotFailures.Add($message)
    }
}

$stateScript = {
    param($AgName, $SqlInstanceName)
    $sqlTarget = if ($SqlInstanceName -ieq 'MSSQLSERVER') { 'localhost' } else { "localhost\$SqlInstanceName" }
    $connection = [Data.SqlClient.SqlConnection]::new(
        "Data Source=$sqlTarget;Initial Catalog=master;Integrated Security=True;Connect Timeout=10;Encrypt=False;TrustServerCertificate=True"
    )
    $connection.Open()
    try {
        function Invoke-Table {
            param([string]$Query, [string]$AgName)
            $command = $connection.CreateCommand()
            $command.CommandText = $Query
            $null = $command.Parameters.Add('@ag', [Data.SqlDbType]::NVarChar, 128)
            $command.Parameters['@ag'].Value = $AgName
            $adapter = [Data.SqlClient.SqlDataAdapter]::new($command)
            $table = [Data.DataTable]::new()
            try { $null = $adapter.Fill($table) } finally { $adapter.Dispose(); $command.Dispose() }
            return , $table
        }

        $replica = Invoke-Table -AgName $AgName -Query @'
SELECT @@SERVERNAME AS LocalServer,
       ar.replica_server_name,
       ar.availability_mode_desc,
       ar.failover_mode_desc,
       rs.role_desc,
       rs.connected_state_desc,
       rs.synchronization_health_desc
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs
  ON ar.replica_id = rs.replica_id AND rs.is_local = 1
WHERE ag.name = @ag AND ar.replica_server_name = @@SERVERNAME
'@
        $databases = Invoke-Table -AgName $AgName -Query @'
SELECT adc.database_name,
       drs.synchronization_state_desc,
       drs.synchronization_health_desc,
       drs.is_suspended,
       drcs.is_database_joined,
       drcs.is_failover_ready
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
JOIN sys.availability_replicas ar
  ON ag.group_id = ar.group_id AND ar.replica_server_name = @@SERVERNAME
LEFT JOIN sys.dm_hadr_database_replica_states drs
  ON adc.group_database_id = drs.group_database_id AND drs.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_cluster_states drcs
  ON adc.group_database_id = drcs.group_database_id AND drcs.replica_id = ar.replica_id
WHERE ag.name = @ag
ORDER BY adc.database_name
'@
        [pscustomobject]@{
            Replica = if ($replica.Rows.Count -eq 1) { [pscustomobject]@{
                    LocalServer = [string]$replica.Rows[0].LocalServer
                    ReplicaServer = [string]$replica.Rows[0].replica_server_name
                    AvailabilityMode = [string]$replica.Rows[0].availability_mode_desc
                    FailoverMode = [string]$replica.Rows[0].failover_mode_desc
                    Role = [string]$replica.Rows[0].role_desc
                    Connection = [string]$replica.Rows[0].connected_state_desc
                    Health = [string]$replica.Rows[0].synchronization_health_desc
                } } else { $null }
            Databases = @($databases.Rows | ForEach-Object {
                    [pscustomobject]@{
                        Name = [string]$_.database_name
                        Synchronization = [string]$_.synchronization_state_desc
                        Health = [string]$_.synchronization_health_desc
                        Suspended = -not [Convert]::IsDBNull($_.is_suspended) -and [bool]$_.is_suspended
                        Joined = -not [Convert]::IsDBNull($_.is_database_joined) -and [bool]$_.is_database_joined
                        FailoverReady = -not [Convert]::IsDBNull($_.is_failover_ready) -and [bool]$_.is_failover_ready
                    }
                })
        }
    }
    finally { $connection.Dispose() }
}

$failoverScript = {
    param($AgName, $SqlInstanceName)
    $sqlTarget = if ($SqlInstanceName -ieq 'MSSQLSERVER') { 'localhost' } else { "localhost\$SqlInstanceName" }
    $escapedAgName = $AgName.Replace(']', ']]')
    $connection = [Data.SqlClient.SqlConnection]::new(
        "Data Source=$sqlTarget;Initial Catalog=master;Integrated Security=True;Connect Timeout=10;Encrypt=False;TrustServerCertificate=True"
    )
    $connection.Open()
    try {
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 60
        $command.CommandText = "ALTER AVAILABILITY GROUP [$escapedAgName] FAILOVER;"
        $null = $command.ExecuteNonQuery()
    }
    finally { $connection.Dispose() }
}

$listenerScript = {
    param($ListenerName, $ListenerPort, $Database, $AgName)
    $target = if ($ListenerPort -eq 1433) { $ListenerName } else { "$ListenerName,$ListenerPort" }
    $connection = [Data.SqlClient.SqlConnection]::new(
        "Data Source=$target;Initial Catalog=master;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True;MultiSubnetFailover=True"
    )
    $connection.Open()
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = @'
SELECT @@SERVERNAME AS ServerName,
       ar.replica_server_name AS ReplicaServer,
       rs.role_desc AS LocalRole,
       CAST(CASE WHEN EXISTS
       (
           SELECT 1
           FROM sys.availability_databases_cluster adc
           JOIN sys.availability_groups ag2 ON adc.group_id = ag2.group_id
           WHERE ag2.name = @ag AND adc.database_name = @database
       ) THEN 1 ELSE 0 END AS bit) AS DatabaseInAg
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states rs
  ON ar.replica_id = rs.replica_id AND rs.is_local = 1
WHERE ag.name = @ag
'@
        $null = $command.Parameters.Add('@ag', [Data.SqlDbType]::NVarChar, 128)
        $command.Parameters['@ag'].Value = $AgName
        $null = $command.Parameters.Add('@database', [Data.SqlDbType]::NVarChar, 128)
        $command.Parameters['@database'].Value = $Database
        $command.CommandTimeout = 30
        $reader = $command.ExecuteReader()
        try {
            if (-not $reader.Read()) { throw "Listener query returned no local AG replica row for '$AgName'." }
            return [pscustomobject]@{
                ServerName = [string]$reader['ServerName']
                ReplicaServer = [string]$reader['ReplicaServer']
                Role = [string]$reader['LocalRole']
                DatabaseInAg = [bool]$reader['DatabaseInAg']
            }
        }
        finally { $reader.Close(); $command.Dispose() }
    }
    finally { $connection.Dispose() }
}

$clusterPreflightScript = {
    param($AgName, $ExpectedNodesCsv)
    Import-Module FailoverClusters -ErrorAction Stop
    $expectedNodes = @($ExpectedNodesCsv -split ',' | Where-Object { $_ })
    $nodes = @(Get-ClusterNode -ErrorAction Stop)
    $downNodes = @($nodes | Where-Object { $_.State -ne 'Up' })
    $quorum = Get-ClusterQuorum -ErrorAction Stop
    $group = Get-ClusterGroup -Name $AgName -ErrorAction Stop
    $resource = Get-ClusterResource -Name $AgName -ErrorAction Stop
    $possibleInfo = $resource | Get-ClusterOwnerNode -ErrorAction Stop
    $preferredInfo = $group | Get-ClusterOwnerNode -ErrorAction Stop
    $possible = @($possibleInfo.OwnerNodes | ForEach-Object {
            if ($_.PSObject.Properties['Name']) { [string]$_.Name } else { [string]$_ }
        } | Sort-Object)
    $preferred = @($preferredInfo.OwnerNodes | ForEach-Object {
            if ($_.PSObject.Properties['Name']) { [string]$_.Name } else { [string]$_ }
        })
    $groupOwner = if ($group.OwnerNode.PSObject.Properties['Name']) {
        [string]$group.OwnerNode.Name
    }
    else {
        [string]$group.OwnerNode
    }
    [pscustomobject]@{
        NodesUp = $downNodes.Count -eq 0 -and $nodes.Count -eq $expectedNodes.Count
        DownNodes = @($downNodes.Name)
        QuorumType = [string]$quorum.QuorumType
        QuorumResource = [string]$quorum.QuorumResource
        GroupState = [string]$group.State
        GroupOwner = $groupOwner
        ResourceState = [string]$resource.State
        PossibleOwners = @($possible)
        PreferredOwners = @($preferred)
    }
}

function Get-PairState {
    param([datetime]$Deadline = [datetime]::MinValue)
    $states = @{}
    foreach ($node in $NodeVm) {
        $states[$node] = Invoke-NodeCommand -VmName $node -ScriptBlock $stateScript -ArgumentList $AgName, $SqlInstanceName -Deadline $Deadline
    }
    return $states
}

function Test-DatabaseNameSet {
    param([string[]]$Actual, [string[]]$Expected)
    $actualValues = @($Actual)
    $expectedValues = @($Expected)
    if ($actualValues.Count -ne $expectedValues.Count) { return $false }

    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $actualValues) {
        if ([string]::IsNullOrEmpty($name) -or -not $actualSet.Add($name)) { return $false }
    }
    foreach ($name in $expectedValues) {
        if ([string]::IsNullOrEmpty($name) -or -not $expectedSet.Add($name)) { return $false }
    }
    return $actualSet.SetEquals($expectedSet)
}

function Test-TargetReady {
    param([object]$State, [string[]]$ExpectedDatabases)
    $actualDatabases = @($State.Databases | ForEach-Object { [string]$_.Name })
    return $State -and $State.Replica -and
        $State.Replica.AvailabilityMode -eq 'SYNCHRONOUS_COMMIT' -and
        $State.Replica.Role -eq 'SECONDARY' -and
        $State.Replica.Connection -eq 'CONNECTED' -and
        $State.Replica.Health -eq 'HEALTHY' -and
        (Test-DatabaseNameSet -Actual $actualDatabases -Expected $ExpectedDatabases) -and
        @($State.Databases | Where-Object {
                $_.Synchronization -ne 'SYNCHRONIZED' -or
                $_.Health -ne 'HEALTHY' -or
                $_.Suspended -or -not $_.Joined -or -not $_.FailoverReady
            }).Count -eq 0
}

function Test-PrimaryReady {
    param([object]$State, [string[]]$ExpectedDatabases)
    $actualDatabases = @($State.Databases | ForEach-Object { [string]$_.Name })
    return $State -and $State.Replica -and
        $State.Replica.Role -eq 'PRIMARY' -and
        $State.Replica.Connection -eq 'CONNECTED' -and
        $State.Replica.Health -eq 'HEALTHY' -and
        (Test-DatabaseNameSet -Actual $actualDatabases -Expected $ExpectedDatabases) -and
        @($State.Databases | Where-Object {
                $_.Health -ne 'HEALTHY' -or $_.Suspended -or -not $_.Joined
            }).Count -eq 0
}

function Test-ListenerState {
    param([object]$State, [string]$ExpectedReplica)
    return $State -and
        $State.Role -eq 'PRIMARY' -and
        $State.DatabaseInAg -and
        [string]::Equals([string]$State.ReplicaServer, $ExpectedReplica, [StringComparison]::OrdinalIgnoreCase)
}

function Wait-ForRoleConvergence {
    param(
        [Parameter(Mandatory)][string]$ExpectedPrimary,
        [Parameter(Mandatory)][string]$ExpectedSecondary,
        [Parameter(Mandatory)][string[]]$ExpectedDatabases,
        [Parameter(Mandatory)][datetime]$Deadline
    )
    do {
        $remaining = ($Deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min(5, [Math]::Max(1, [int]$remaining)))
        try {
            $states = Get-PairState -Deadline $Deadline
            $primaryState = $states[$ExpectedPrimary]
            $secondaryState = $states[$ExpectedSecondary]
            $primaryHealthy = Test-PrimaryReady -State $primaryState -ExpectedDatabases $ExpectedDatabases
            $secondaryHealthy = Test-TargetReady -State $secondaryState -ExpectedDatabases $ExpectedDatabases
            if ($primaryHealthy -and $secondaryHealthy) {
                return $states
            }
        }
        catch {
            Write-TestLog "Transition pending: $($_.Exception.Message)"
        }
    } while ((Get-Date) -lt $Deadline)
    throw "AG did not converge to primary '$ExpectedPrimary' with synchronized secondary '$ExpectedSecondary' within $TimeoutSeconds seconds."
}

function Wait-ForListener {
    param(
        [Parameter(Mandatory)][string]$ExpectedPrimary,
        [Parameter(Mandatory)][string]$ExpectedReplica,
        [Parameter(Mandatory)][datetime]$Deadline
    )
    do {
        try {
            $listenerState = Invoke-NodeCommand -VmName $ExpectedPrimary -ScriptBlock $listenerScript `
                -ArgumentList $ListenerName, $ListenerPort, $Database, $AgName -Deadline $Deadline
            if (Test-ListenerState -State $listenerState -ExpectedReplica $ExpectedReplica) {
                return $listenerState
            }
        }
        catch { Write-TestLog "Listener transition pending: $($_.Exception.Message)" }
        $remaining = ($Deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min(5, [Math]::Max(1, [int]$remaining)))
    } while ((Get-Date) -lt $Deadline)
    throw "Listener '$ListenerName' did not route database '$Database' to exact replica '$ExpectedReplica' within $TimeoutSeconds seconds."
}

function Wait-ForReconciliationDecision {
    param(
        [Parameter(Mandatory)][string]$OriginalPrimary,
        [Parameter(Mandatory)][string]$TargetSecondary,
        [Parameter(Mandatory)][string[]]$ExpectedDatabases,
        [Parameter(Mandatory)][datetime]$Deadline,
        [switch]$NoFailback
    )
    if ($NoFailback) {
        return [pscustomobject]@{ Outcome = 'Disabled'; States = $null }
    }

    do {
        try {
            $states = Get-PairState -Deadline $Deadline
            $primaries = @($NodeVm | Where-Object { $states[$_].Replica.Role -eq 'PRIMARY' })
            if ($primaries.Count -eq 1 -and $primaries[0] -eq $OriginalPrimary) {
                return [pscustomobject]@{ Outcome = 'OriginalPrimary'; States = $states }
            }
            if ($primaries.Count -eq 1 -and $primaries[0] -eq $TargetSecondary -and
                (Test-PrimaryReady -State $states[$TargetSecondary] -ExpectedDatabases $ExpectedDatabases) -and
                (Test-TargetReady -State $states[$OriginalPrimary] -ExpectedDatabases $ExpectedDatabases)) {
                return [pscustomobject]@{ Outcome = 'TargetReady'; States = $states }
            }
        }
        catch {
            Write-TestLog "Reconciliation state pending: $($_.Exception.Message)"
        }
        $remaining = ($Deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min(2, [Math]::Max(1, [int]$remaining)))
    } while ((Get-Date) -lt $Deadline)

    return [pscustomobject]@{ Outcome = 'Unresolved'; States = $null }
}

function Test-FinalPrimaryPostcondition {
    param([string]$FinalPrimary, [string]$ExpectedPrimary)
    return [string]::Equals($FinalPrimary, $ExpectedPrimary, [StringComparison]::OrdinalIgnoreCase)
}

function Test-ClusterPrimaryOwnership {
    param([object]$ClusterState, [string]$PrimaryNode)
    return $ClusterState -and
        $ClusterState.NodesUp -and
        $ClusterState.GroupState -eq 'Online' -and
        $ClusterState.ResourceState -eq 'Online' -and
        [string]::Equals([string]$ClusterState.GroupOwner, $PrimaryNode, [StringComparison]::OrdinalIgnoreCase) -and
        @($ClusterState.PossibleOwners) -contains $PrimaryNode
}

function Wait-ForClusterPrimaryOwnership {
    param(
        [Parameter(Mandatory)][string]$PrimaryNode,
        [Parameter(Mandatory)][datetime]$Deadline
    )
    $lastState = $null
    do {
        try {
            $lastState = Invoke-NodeCommand -VmName $NodeVm[0] -ScriptBlock $clusterPreflightScript `
                -ArgumentList $AgName, ($NodeVm -join ',') -Deadline $Deadline
            if (Test-ClusterPrimaryOwnership -ClusterState $lastState -PrimaryNode $PrimaryNode) {
                return $lastState
            }
            Write-TestLog "WSFC owner state pending for '$PrimaryNode': group='$($lastState.GroupOwner)' groupState='$($lastState.GroupState)' resourceState='$($lastState.ResourceState)' possible=[$(@($lastState.PossibleOwners) -join ', ')]."
        }
        catch {
            Write-TestLog "WSFC owner state pending for '$PrimaryNode': $($_.Exception.Message)"
        }
        $remaining = ($Deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min(2, [Math]::Max(1, [int]$remaining)))
    } while ((Get-Date) -lt $Deadline)
    throw "WSFC owner state did not converge to current SQL primary '$PrimaryNode' within $TimeoutSeconds seconds. Last group='$($lastState.GroupOwner)' groupState='$($lastState.GroupState)' resourceState='$($lastState.ResourceState)' possible=[$(@($lastState.PossibleOwners) -join ', ')]."
}

function Confirm-FailoverPreconditions {
    param(
        [Parameter(Mandatory)][string]$ExpectedPrimary,
        [Parameter(Mandatory)][string]$ExpectedSecondary,
        [Parameter(Mandatory)][string[]]$ExpectedDatabases,
        [Parameter(Mandatory)][datetime]$Deadline
    )
    $states = Get-PairState -Deadline $Deadline
    if (-not (Test-PrimaryReady -State $states[$ExpectedPrimary] -ExpectedDatabases $ExpectedDatabases)) {
        throw "Expected primary '$ExpectedPrimary' is no longer healthy and online after the startup snapshot."
    }
    if (-not (Test-TargetReady -State $states[$ExpectedSecondary] -ExpectedDatabases $ExpectedDatabases)) {
        throw "Target '$ExpectedSecondary' is no longer synchronized and failover-ready after the startup snapshot."
    }
    $clusterState = Invoke-NodeCommand -VmName $NodeVm[0] -ScriptBlock $clusterPreflightScript `
        -ArgumentList $AgName, ($NodeVm -join ',') -Deadline $Deadline
    if (-not (Test-ClusterPrimaryOwnership -ClusterState $clusterState -PrimaryNode $ExpectedPrimary)) {
        throw "SQL/WSFC ownership changed after the startup snapshot. Expected primary='$ExpectedPrimary', group owner='$($clusterState.GroupOwner)', possible=[$(@($clusterState.PossibleOwners) -join ', ')]."
    }
    $expectedReplica = [string]$states[$ExpectedPrimary].Replica.ReplicaServer
    $listenerState = Invoke-NodeCommand -VmName $ExpectedPrimary -ScriptBlock $listenerScript `
        -ArgumentList $ListenerName, $ListenerPort, $Database, $AgName -Deadline $Deadline
    if (-not (Test-ListenerState -State $listenerState -ExpectedReplica $expectedReplica)) {
        throw "Listener state changed after the startup snapshot. Expected exact primary replica '$expectedReplica'."
    }
    return [pscustomobject]@{
        States = $states
        ClusterState = $clusterState
        ListenerState = $listenerState
    }
}

function Get-ExpectedFinalPrimary {
    param(
        [string]$OriginalPrimary,
        [string]$TargetSecondary,
        [bool]$FailoverConverged,
        [bool]$NoFailbackRequested
    )
    if ($NoFailbackRequested -and $FailoverConverged) { return $TargetSecondary }
    return $OriginalPrimary
}

foreach ($node in $NodeVm) {
    $vm = Get-VM -Name $node -ErrorAction Stop
    if ($vm.State -ne 'Running') { throw "VM '$node' is '$($vm.State)'; both replicas must be running." }
}

$preflightDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
$clusterPreflight = Invoke-NodeCommand -VmName $NodeVm[0] -ScriptBlock $clusterPreflightScript `
    -ArgumentList $AgName, ($NodeVm -join ',') -Deadline $preflightDeadline
if (-not $clusterPreflight.NodesUp) {
    throw "Cluster nodes are not all Up. Down/nonmember nodes: $(@($clusterPreflight.DownNodes) -join ', ')."
}
if ($clusterPreflight.GroupState -ne 'Online') {
    throw "Clustered role '$AgName' is '$($clusterPreflight.GroupState)', expected Online before planned failover."
}
if ($clusterPreflight.ResourceState -ne 'Online') {
    throw "AG resource '$AgName' is '$($clusterPreflight.ResourceState)', expected Online before planned failover."
}

$initialStates = Get-PairState -Deadline $preflightDeadline
$primaryNodes = @($NodeVm | Where-Object { $initialStates[$_].Replica.Role -eq 'PRIMARY' })
$secondaryNodes = @($NodeVm | Where-Object { $initialStates[$_].Replica.Role -eq 'SECONDARY' })
if ($primaryNodes.Count -ne 1 -or $secondaryNodes.Count -ne 1) {
    throw "Expected one PRIMARY and one SECONDARY; found primary=[$($primaryNodes -join ',')] secondary=[$($secondaryNodes -join ',')]."
}
$originalPrimary = $primaryNodes[0]
$targetSecondary = $secondaryNodes[0]
if (-not (Test-ClusterPrimaryOwnership -ClusterState $clusterPreflight -PrimaryNode $originalPrimary)) {
    throw "SQL/WSFC primary ownership is inconsistent. SQL primary='$originalPrimary', group owner='$($clusterPreflight.GroupOwner)', resource state='$($clusterPreflight.ResourceState)', possible=[$(@($clusterPreflight.PossibleOwners) -join ', ')]."
}
Write-TestLog "Cluster preflight passed. Quorum='$($clusterPreflight.QuorumType)' resource='$($clusterPreflight.QuorumResource)'; SQL-managed owners possible=[$(@($clusterPreflight.PossibleOwners) -join ', ')] preferred=[$(@($clusterPreflight.PreferredOwners) -join ', ')]."

$expectedDatabases = @($initialStates[$originalPrimary].Databases | ForEach-Object { [string]$_.Name } | Sort-Object)
if ($expectedDatabases.Count -eq 0 -or $Database -notin $expectedDatabases) {
    throw "Configured AG database set is [$($expectedDatabases -join ',')]; required listener test database '$Database' is not a member."
}
if (-not (Test-TargetReady -State $initialStates[$targetSecondary] -ExpectedDatabases $expectedDatabases)) {
    throw "Target '$targetSecondary' is not synchronized and failover-ready for every AG database."
}

$preflightListener = Invoke-NodeCommand -VmName $originalPrimary -ScriptBlock $listenerScript `
    -ArgumentList $ListenerName, $ListenerPort, $Database, $AgName -Deadline $preflightDeadline
$originalReplicaName = [string]$initialStates[$originalPrimary].Replica.ReplicaServer
if (-not (Test-ListenerState -State $preflightListener -ExpectedReplica $originalReplicaName)) {
    throw "Listener reports replica='$($preflightListener.ReplicaServer)' role='$($preflightListener.Role)' databaseInAg='$($preflightListener.DatabaseInAg)'; expected exact primary replica '$originalReplicaName'."
}

Write-TestLog "Preflight passed. Original primary='$originalPrimary'; target secondary='$targetSecondary'; listener replica='$($preflightListener.ReplicaServer)'."
$operation = "planned no-data-loss failover '$AgName' from '$originalPrimary' to '$targetSecondary'"
if (-not $PSCmdlet.ShouldProcess($operation, 'ALTER AVAILABILITY GROUP ... FAILOVER')) {
    Write-TestLog 'Failover canceled by ShouldProcess.'
    return
}

$firstFailoverAttempted = $false
$testError = $null
$finalPrimary = 'UNKNOWN'
$failoverConverged = $false
$postconditionFailures = [Collections.Generic.List[string]]::new()
try {
    Save-HealthSnapshot -Label 'startup' -Required
    $null = Confirm-FailoverPreconditions -ExpectedPrimary $originalPrimary -ExpectedSecondary $targetSecondary `
        -ExpectedDatabases $expectedDatabases -Deadline (Get-Date).AddSeconds($TimeoutSeconds)
    Write-TestLog 'Failover preconditions revalidated after the startup health snapshot.'
    $failoverDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-TestLog "Failing over to '$targetSecondary'."
    $firstFailoverAttempted = $true
    Invoke-NodeCommand -VmName $targetSecondary -ScriptBlock $failoverScript `
        -ArgumentList $AgName, $SqlInstanceName -Deadline $failoverDeadline
    $failedOverState = Wait-ForRoleConvergence -ExpectedPrimary $targetSecondary -ExpectedSecondary $originalPrimary `
        -ExpectedDatabases $expectedDatabases -Deadline $failoverDeadline
    $targetReplicaName = [string]$failedOverState[$targetSecondary].Replica.ReplicaServer
    $null = Wait-ForListener -ExpectedPrimary $targetSecondary -ExpectedReplica $targetReplicaName -Deadline $failoverDeadline
    $null = Wait-ForClusterPrimaryOwnership -PrimaryNode $targetSecondary -Deadline (Get-Date).AddSeconds($TimeoutSeconds)
    $failoverConverged = $true
    Save-HealthSnapshot -Label 'after-failover'
    Write-TestLog "Failover succeeded. Listener and database '$Database' are served by '$targetSecondary'."

    if ($NoFailback) {
        $finalPrimary = $targetSecondary
    }
    else {
        $failbackDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $beforeFailback = Get-PairState -Deadline $failbackDeadline
        if (-not (Test-TargetReady -State $beforeFailback[$originalPrimary] -ExpectedDatabases $expectedDatabases)) {
            throw "Original primary '$originalPrimary' did not become synchronized/failover-ready; refusing planned failback."
        }
        Write-TestLog "Failing back to '$originalPrimary'."
        Invoke-NodeCommand -VmName $originalPrimary -ScriptBlock $failoverScript `
            -ArgumentList $AgName, $SqlInstanceName -Deadline $failbackDeadline
        $failedBackState = Wait-ForRoleConvergence -ExpectedPrimary $originalPrimary -ExpectedSecondary $targetSecondary `
            -ExpectedDatabases $expectedDatabases -Deadline $failbackDeadline
        $originalReplicaName = [string]$failedBackState[$originalPrimary].Replica.ReplicaServer
        $null = Wait-ForListener -ExpectedPrimary $originalPrimary -ExpectedReplica $originalReplicaName -Deadline $failbackDeadline
        $null = Wait-ForClusterPrimaryOwnership -PrimaryNode $originalPrimary -Deadline (Get-Date).AddSeconds($TimeoutSeconds)
        Save-HealthSnapshot -Label 'after-failback'
        $finalPrimary = $originalPrimary
        Write-TestLog "Failback succeeded. Listener and database '$Database' are again served by '$originalPrimary'."
    }
}
catch {
    $testError = $_
    Write-TestLog "Planned failover test encountered an error: $($_.Exception.Message)"
}
finally {
    if ($firstFailoverAttempted) {
        try {
            $reconcileDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $reconciliation = Wait-ForReconciliationDecision -OriginalPrimary $originalPrimary -TargetSecondary $targetSecondary `
                -ExpectedDatabases $expectedDatabases -Deadline $reconcileDeadline -NoFailback:$NoFailback
            if ($reconciliation.Outcome -eq 'OriginalPrimary') {
                $finalPrimary = $originalPrimary
            }
            elseif ($reconciliation.Outcome -eq 'TargetReady') {
                Write-TestLog "Reconciliation: target '$targetSecondary' is primary after an error; evaluating safe return to '$originalPrimary'."
                $safeFailbackDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
                Write-TestLog "Reconciliation: performing planned failback to '$originalPrimary'."
                Invoke-NodeCommand -VmName $originalPrimary -ScriptBlock $failoverScript `
                    -ArgumentList $AgName, $SqlInstanceName -Deadline $safeFailbackDeadline
                $recoveredState = Wait-ForRoleConvergence -ExpectedPrimary $originalPrimary -ExpectedSecondary $targetSecondary `
                    -ExpectedDatabases $expectedDatabases -Deadline $safeFailbackDeadline
                $recoveredReplicaName = [string]$recoveredState[$originalPrimary].Replica.ReplicaServer
                $null = Wait-ForListener -ExpectedPrimary $originalPrimary -ExpectedReplica $recoveredReplicaName -Deadline $safeFailbackDeadline
                $finalPrimary = $originalPrimary
                Write-TestLog "Reconciliation: original primary '$originalPrimary' safely restored."
            }
            elseif ($reconciliation.Outcome -eq 'Unresolved') {
                Write-TestLog "Reconciliation did not observe a safe stable role/readiness state before its deadline; no failback command was issued."
            }
        }
        catch {
            Write-TestLog "Reconciliation could not safely restore the original primary: $($_.Exception.Message)"
        }
    }
    try {
        $finalObservationDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $finalStates = Get-PairState -Deadline $finalObservationDeadline
        $observedPrimaries = @($NodeVm | Where-Object { $finalStates[$_].Replica.Role -eq 'PRIMARY' })
        $finalPrimary = if ($observedPrimaries.Count -eq 1) {
            $observedPrimaries[0]
        }
        else {
            "AMBIGUOUS[$($observedPrimaries -join ',')]"
        }
    }
    catch {
        $finalPrimary = "UNKNOWN ($($_.Exception.Message))"
    }
    Write-TestLog "Authoritative final primary after test: '$finalPrimary'."
    foreach ($snapshotFailure in $script:healthSnapshotFailures) {
        $postconditionFailures.Add($snapshotFailure)
    }
    $expectedFinalPrimary = Get-ExpectedFinalPrimary -OriginalPrimary $originalPrimary -TargetSecondary $targetSecondary `
        -FailoverConverged $failoverConverged -NoFailbackRequested ([bool]$NoFailback)
    if (-not (Test-FinalPrimaryPostcondition -FinalPrimary $finalPrimary -ExpectedPrimary $expectedFinalPrimary)) {
        $postconditionFailures.Add("Final primary postcondition failed: expected '$expectedFinalPrimary', observed '$finalPrimary'.")
    }
    else {
        try {
            $finalOwnerDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $finalClusterState = Wait-ForClusterPrimaryOwnership -PrimaryNode $finalPrimary -Deadline $finalOwnerDeadline
            Write-TestLog "Authoritative final WSFC owner state: group='$($finalClusterState.GroupOwner)' possible=[$(@($finalClusterState.PossibleOwners) -join ', ')] preferred=[$(@($finalClusterState.PreferredOwners) -join ', ')]."
        }
        catch {
            $postconditionFailures.Add("Final WSFC owner postcondition failed for SQL primary '$finalPrimary': $($_.Exception.Message)")
        }
    }
    if ($postconditionFailures.Count -gt 0) {
        $finalStateFailure = $postconditionFailures -join ' '
        Write-TestLog $finalStateFailure
        if ($testError) {
            $originalErrorMessage = if ($testError.ErrorDetails -and $testError.ErrorDetails.Message) {
                $testError.ErrorDetails.Message
            }
            else {
                $testError.Exception.Message
            }
            $testError.ErrorDetails = [Management.Automation.ErrorDetails]::new("$originalErrorMessage $finalStateFailure")
        }
        else {
            $testError = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new($finalStateFailure),
                'SqlAoFinalPrimaryPostconditionFailed',
                [Management.Automation.ErrorCategory]::InvalidResult,
                $finalPrimary
            )
        }
    }
    if ($testError -and -not $NoFailback -and
        -not (Test-FinalPrimaryPostcondition -FinalPrimary $finalPrimary -ExpectedPrimary $originalPrimary)) {
        Write-TestLog "Manual action required: inspect both replica roles and database readiness before attempting a planned failback to '$originalPrimary'."
    }
}

if ($testError) {
    Write-TestLog "Planned SQLAO failover/failback test FAILED. Final primary='$finalPrimary'. Log: $logPath"
    $PSCmdlet.ThrowTerminatingError($testError)
}
if ($NoFailback) {
    Write-TestLog "Planned SQLAO failover test PASSED with NoFailback. Final primary='$finalPrimary'. Log: $logPath"
}
else {
    Write-TestLog "Planned SQLAO failover/failback test PASSED. Final primary='$finalPrimary'. Log: $logPath"
}
