function Test-VmNoInternetEligible {
    param([Parameter(Mandatory)]$VM)

    return $VM.role -in @('DomainMember', 'WorkgroupMember', 'CAS', 'Primary', 'Secondary',
        'SiteSystem', 'PassiveSite', 'SQLAO', 'WSUS', 'FileServer') -and
        $VM.osFamily -ne 'Linux' -and
        "$($VM.operatingSystem)$($VM.deployedOS)" -notmatch 'Ubuntu|Debian|Linux'
}

function Get-VmProxyEnforcementRules {
    $weight = 5099
    foreach ($cidr in @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')) {
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = $cidr; Weight = $weight }
        @{ Action = 'Allow'; Direction = 'Inbound'; RemoteIPAddress = $cidr; Weight = ($weight - 1) }
        $weight -= 2
    }
    @{ Action = 'Deny'; Direction = 'Outbound'; RemotePort = 80; Protocol = 'TCP'; Weight = 5004 }
    @{ Action = 'Deny'; Direction = 'Outbound'; RemotePort = 443; Protocol = 'TCP'; Weight = 5003 }
    @{ Action = 'Deny'; Direction = 'Outbound'; RemotePort = 443; Protocol = 'UDP'; Weight = 5002 }
    @{ Action = 'Deny'; Direction = 'Outbound'; RemotePort = 53; Protocol = 'UDP'; Weight = 5001 }
    @{ Action = 'Deny'; Direction = 'Outbound'; RemotePort = 53; Protocol = 'TCP'; Weight = 5000 }
}

function Get-MemLabsInternetAclKey {
    param([Parameter(Mandatory)]$Rule)

    $values = foreach ($field in @('Action', 'Direction', 'Weight', 'Protocol',
            'LocalIPAddress', 'RemoteIPAddress', 'LocalPort', 'RemotePort')) {
        $value = "$($Rule.$field)".ToUpperInvariant()
        if ($field -eq 'Protocol') {
            if ($value -eq '6') { $value = 'TCP' }
            elseif ($value -eq '17') { $value = 'UDP' }
        }
        if ($field -notin @('Action', 'Direction', 'Weight') -and $value -in @('', '*', '0', 'ANY')) {
            $value = 'ANY'
        }
        if ($field -in @('LocalIPAddress', 'RemoteIPAddress') -and $value -ne 'ANY') {
            $parts = $value.Split('/')
            $address = $null
            if ([Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
                $value = $address.ToString().ToUpperInvariant()
                if ($parts.Count -eq 2 -and [int]$parts[1] -ne $address.GetAddressBytes().Length * 8) { $value += "/$($parts[1])" }
            }
        }
        $value
    }
    return ($values -join '|')
}

function Test-VmInternetAclSet {
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [Parameter(Mandatory)][int]$MinimumWeight,
        [Parameter(Mandatory)][int]$MaximumWeight
    )

    $actual = @(Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $Adapter -ErrorAction Stop |
        Where-Object { $_.Weight -ge $MinimumWeight -and $_.Weight -le $MaximumWeight } |
        ForEach-Object { Get-MemLabsInternetAclKey -Rule $_ } | Sort-Object)
    $expected = @($Rules | ForEach-Object { Get-MemLabsInternetAclKey -Rule $_ } | Sort-Object)
    return $actual.Count -eq $expected.Count -and ($actual -join "`n") -ceq ($expected -join "`n")
}

function Get-MemLabsInternetStateRoot {
    return (Join-Path $env:ProgramData 'MemLabs\InternetPolicy')
}

function Initialize-MemLabsInternetStateRoot {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Internet policy installation requires an elevated host session.'
    }
    $root = Get-MemLabsInternetStateRoot
    $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = [Security.Principal.SecurityIdentifier]::new($sid)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl',
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $root -AclObject $acl -ErrorAction Stop
}

function Write-MemLabsInternetJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 10))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Invoke-MemLabsInternetStateLock {
    param([Parameter(Mandatory)][guid]$VMId, [Parameter(Mandatory)][scriptblock]$Operation)

    $mutex = [Threading.Mutex]::new($false, "Global\MemLabsInternet_$($VMId.ToString('N'))")
    $held = $false
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw "Timed out acquiring the Internet policy lock for VM $VMId." }
        & $Operation
    }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-MemLabsInternetStatePath {
    param([Parameter(Mandatory)][guid]$VMId)

    return (Join-Path (Get-MemLabsInternetStateRoot) "$($VMId.ToString('D')).json")
}

function Get-MemLabsInternetLeaseKey {
    $runspace = [Management.Automation.Runspaces.Runspace]::DefaultRunspace
    if ($runspace) { return "MemLabsInternetLease.$($runspace.InstanceId)" }
}

function Get-VmInternetExceptionHandle {
    $key = Get-MemLabsInternetLeaseKey
    if ($key) { return [AppDomain]::CurrentDomain.GetData($key) }
}

function Wait-MemLabsInternetOperation {
    param([Parameter(Mandatory)][ValidateRange(0, 86400)][double]$Seconds)

    if (-not (Get-VmInternetExceptionHandle)) {
        Start-Sleep -Seconds $Seconds
        return
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Update-VmInternetExceptionHeartbeat -Force
        $remaining = $Seconds - $watch.Elapsed.TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([int][Math]::Ceiling([Math]::Min(5, $remaining) * 1000))
    } while ($watch.Elapsed.TotalSeconds -lt $Seconds)
}

function Wait-MemLabsInternetHandle {
    param([Parameter(Mandatory)][Threading.WaitHandle]$Handle, [Parameter(Mandatory)][int]$TimeoutSeconds)

    if ($TimeoutSeconds -eq 0) { return $Handle.WaitOne(0) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Update-VmInternetExceptionHeartbeat -Force
        $remaining = $TimeoutSeconds - $watch.Elapsed.TotalSeconds
        if ($remaining -le 0) { return $false }
        if ($Handle.WaitOne([TimeSpan]::FromSeconds([Math]::Min(5, $remaining)))) { return $true }
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $false
}

function Wait-MemLabsInternetJob {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][int]$TimeoutSeconds)

    if (-not (Get-VmInternetExceptionHandle)) { return ($Job | Wait-Job -Timeout $TimeoutSeconds) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Update-VmInternetExceptionHeartbeat -Force
        $remaining = [Math]::Max(0, [int][Math]::Ceiling($TimeoutSeconds - $watch.Elapsed.TotalSeconds))
        $finished = Wait-Job -Job $Job -Timeout ([Math]::Min(5, $remaining))
        if ($finished) { return $finished }
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
}

function Invoke-MemLabsInternetSessionProbe {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$VMName, [ValidateRange(1, 5)][int]$TimeoutSeconds = 5)

    $result = [pscustomobject]@{ Ready = $false; Error = ''; Abandoned = $false }
    if ($Session._InternetProbeAbandoned -eq $true) {
        $result.Error = 'Session readiness was already abandoned; a fresh session is required.'
        $result.Abandoned = $true
        return $result
    }
    $job = $null
    $completed = $false
    try {
        Update-VmInternetExceptionHeartbeat -Force
        $launchErrors = $null
        $job = Invoke-Command -Session $Session -ScriptBlock { 1 } -AsJob -ErrorAction SilentlyContinue -ErrorVariable launchErrors
        if (-not $job) { throw "Session readiness probe could not start: $(@($launchErrors) -join '; ')" }
        $null = Wait-MemLabsInternetJob -Job $job -TimeoutSeconds $TimeoutSeconds
        if ($job.State -ne 'Completed') { throw "Session readiness transport probe timed out or failed (state=$($job.State))." }
        $completed = $true
        $remoteErrors = @($job.ChildJobs | ForEach-Object { $_.Error } | Where-Object { $_ })
        $receiveErrors = $null
        $output = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable receiveErrors)
        $allErrors = @(@($launchErrors; $remoteErrors; $receiveErrors) | ForEach-Object { $_ } | Where-Object { $_ })
        if ($allErrors.Count) { $result.Error = $allErrors -join '; ' }
        elseif ($output.Count -eq 1 -and $output[0] -eq 1) { $result.Ready = $true }
        else { $result.Error = 'Session readiness probe did not return its expected value.' }
        Update-VmInternetExceptionHeartbeat -Force
    }
    catch {
        $result.Ready = $false
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($job -and $completed) { Remove-Job -Job $job -Force -ErrorAction Stop }
        elseif ($job) {
            $result.Abandoned = $true
            Stop-MemLabsInternetGuestJob -Job $job -Session $Session -VMName $VMName
        }
    }
    return $result
}

function Stop-MemLabsInternetGuestJob {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$VMName)

    $Session | Add-Member -NotePropertyName '_InternetProbeAbandoned' -NotePropertyValue $true -Force
    try { $null = $Job.StopJobAsync() }
    catch { Write-Log "[NoInternet] $VMName`: Guest job could not be stopped asynchronously; retaining its live transport. $_" -Warning }
    $cached = @($global:ps_cache.Values | Where-Object { [object]::ReferenceEquals($_, $Session) })
    if ($cached.Count) { Remove-VmSessionFromCache -VmName $VMName -LeakSession -AbandonedJob $Job }
    else {
        Add-OrphanRunspace -Runspace $Session._OwnerRunspace -Session $Session -Job $Job `
            -Reason 'leased guest job abandoned' -VmName $VMName
    }
}

function Read-MemLabsInternetState {
    param([Parameter(Mandatory)][guid]$VMId)

    $path = Get-MemLabsInternetStatePath -VMId $VMId
    $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($state.SchemaVersion -ne 1 -or "$($state.VMId)" -ne "$VMId" -or
        $state.Status -notin @('Isolated', 'Prepared', 'ExceptionActive', 'Degraded') -or
        $state.PSObject.Properties.Name -notcontains 'Lease') {
        throw "Invalid Internet policy state for VM $VMId at '$path'. No new exception is permitted."
    }
    if ($state.RecoveryHold -and ($state.RecoveryHold.Action -notin @('Nothing', 'StartIfRunning', 'Start') -or
            ($state.RecoveryHold.Delay -isnot [long] -and $state.RecoveryHold.Delay -isnot [int]) -or
            $state.RecoveryHold.Delay -lt 0)) {
        throw "Invalid Internet policy startup recovery metadata for VM $VMId."
    }
    if (($state.Status -eq 'Isolated' -and ($state.Lease -or $state.RecoveryHold)) -or
        ($state.Status -in @('Prepared', 'ExceptionActive') -and (-not $state.Lease -or -not $state.RecoveryHold))) {
        throw "Inconsistent Internet policy status for VM $VMId."
    }
    if ($state.Lease -and (-not $state.RecoveryHold -or -not $state.Lease.Id -or
            -not $state.Lease.Owner.StartTicks -or -not $state.Lease.Owner.RunspaceId -or
            ($state.Lease.Owner.Id -isnot [long] -and $state.Lease.Owner.Id -isnot [int]) -or
            $state.Lease.Owner.Id -le 0 -or
            -not $state.Lease.BootId -or $state.Lease.HeartbeatTick -le 0 -or $state.Lease.ExpiresTick -le 0 -or
            $state.Lease.DeadlineTick -le 0 -or $null -eq $state.Lease.Rules -or
            $state.Lease.Rules -isnot [array] -or $state.Lease.Rules.Count -eq 0 -or $state.Lease.Rules.Count -gt 1000)) {
        throw "Invalid Internet exception lease for VM $VMId."
    }
    if ($state.Lease) {
        $parsedId = [guid]::Empty
        $startTicks = 0L
        if (-not [guid]::TryParse("$($state.Lease.Id)", [ref]$parsedId) -or
            -not [guid]::TryParse("$($state.Lease.Owner.RunspaceId)", [ref]$parsedId) -or
            -not [long]::TryParse("$($state.Lease.Owner.StartTicks)", [ref]$startTicks) -or $startTicks -le 0) {
            throw "Invalid Internet exception owner identity for VM $VMId."
        }
        foreach ($name in @('HeartbeatTick', 'ExpiresTick', 'DeadlineTick')) {
            $value = $state.Lease.$name
            if (($value -isnot [long] -and $value -isnot [int]) -or $value -le 0) {
                throw "Invalid Internet exception timer '$name' for VM $VMId."
            }
        }
        $weights = [Collections.Generic.HashSet[int]]::new()
        foreach ($rule in $state.Lease.Rules) {
            $address = $null
            if ($null -eq $rule -or $rule.Action -ne 'Allow' -or $rule.Direction -ne 'Outbound' -or
                $rule.Protocol -ne 'TCP' -or $rule.RemotePort -notin @(80, 443) -or
                $rule.Weight -lt 6000 -or $rule.Weight -gt 6999 -or -not $weights.Add([int]$rule.Weight) -or
                -not [Net.IPAddress]::TryParse("$($rule.RemoteIPAddress)", [ref]$address) -or
                "$address" -in @('0.0.0.0', '::')) {
                throw "Invalid temporary Internet ACL scope for VM $VMId."
            }
        }
    }
    return $state
}

function Write-MemLabsInternetEvent {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$Message,
        [switch]$Failure
    )

    $path = Join-Path (Get-MemLabsInternetStateRoot) "$($State.VMId).events.jsonl"
    $record = [ordered]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        VMId = "$($State.VMId)"; VMName = "$($State.VMName)"
        Event = $EventName; Status = "$($State.Status)"; Message = $Message
        LeaseId = "$($State.Lease.Id)"; Purpose = "$($State.Lease.Purpose)"
    }
    [IO.File]::AppendAllText($path, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
    $text = "[NoInternet] $($State.VMName): $EventName - $Message"
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $text -Failure:$Failure }
    elseif ($Failure) { Write-Warning $text }
    else { Write-Verbose $text }
}

function Assert-VmNoInternetPolicy {
    param([Parameter(Mandatory)][string]$VMName, [switch]$AllowException)

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $state = Read-MemLabsInternetState -VMId $vm.Id
    if ($state.Status -notin @('Isolated', 'ExceptionActive') -or ($state.Lease -and -not $AllowException)) {
        throw "$VMName Internet policy is $($state.Status); recovery is required before this operation."
    }
    if ($state.Lease) {
        $reason = Get-MemLabsInternetLeaseFailure -Lease $state.Lease -BootId (Get-MemLabsInternetBootId)
        if ($reason) { throw "$VMName Internet exception requires recovery: $reason." }
    }
    $adapters = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
    if ($adapters.Count -eq 0) { throw "$VMName has no network adapters to verify." }
    foreach ($adapter in $adapters) {
        if (-not (Test-VmInternetAclSet -Adapter $adapter -Rules @(Get-VmProxyEnforcementRules) -MinimumWeight 5000 -MaximumWeight 5099)) {
            throw "$VMName adapter '$($adapter.Name)' does not have the complete proxy-coverage baseline."
        }
        $temporary = @()
        if ($AllowException -and $state.Lease) { $temporary = @($state.Lease.Rules) }
        if (-not (Test-VmInternetAclSet -Adapter $adapter -Rules $temporary -MinimumWeight 6000 -MaximumWeight 6999)) {
            throw "$VMName adapter '$($adapter.Name)' has unverified temporary Internet permissions."
        }
    }
}

function Initialize-VmNoInternetPolicy {
    param([Parameter(Mandatory)][string]$VMName)

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ("$($vm.State)" -ne 'Off') { throw "$VMName must be stopped before initial noInternet enforcement." }
    $note = "$($vm.Notes)" | ConvertFrom-Json -ErrorAction Stop
    if ($note.noInternet -ne $true -or -not (Test-VmNoInternetEligible -VM $note) -or $note.useProxy) {
        throw "$VMName does not have eligible, proxy-free noInternet deployment metadata."
    }
    Initialize-MemLabsInternetStateRoot
    Invoke-MemLabsInternetStateLock -VMId $vm.Id -Operation {
        $path = Get-MemLabsInternetStatePath -VMId $vm.Id
        if (Test-Path -LiteralPath $path) { throw "Internet policy already exists for $VMName; refusing to replace its recovery state." }
        if (-not (Set-VmProxyEnforcement -VMName $VMName)) { throw "Could not enforce noInternet on $VMName before its first boot." }
        $state = [pscustomobject]@{
            SchemaVersion = 1; VMId = "$($vm.Id)"; VMName = $VMName
            Status = 'Isolated'; Lease = $null; RecoveryHold = $null
        }
        Write-MemLabsInternetJson -Path $path -Value $state
        Assert-VmNoInternetPolicy -VMName $VMName
        Write-MemLabsInternetEvent -State $state -EventName 'Initialized' -Message 'Existing proxy ACL coverage applied before first boot; no proxy configured.'
    }
}

function Get-MemLabsInternetBootId {
    return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().Ticks.ToString()
}

function Test-MemLabsInternetOwner {
    param([Parameter(Mandatory)]$Owner)

    $process = Get-Process -Id $Owner.Id -ErrorAction SilentlyContinue
    return $null -ne $process -and $process.StartTime.ToUniversalTime().Ticks.ToString() -eq "$($Owner.StartTicks)"
}

function Get-MemLabsInternetLeaseFailure {
    param([Parameter(Mandatory)]$Lease, [Parameter(Mandatory)][string]$BootId)

    if ("$($Lease.BootId)" -ne $BootId) { return 'Host boot changed' }
    if (-not (Test-MemLabsInternetOwner -Owner $Lease.Owner)) { return 'Owner process ended or was replaced' }
    $now = [Environment]::TickCount64
    if ($now -lt [long]$Lease.HeartbeatTick) { return 'Monotonic clock reset' }
    if ($now -ge [long]$Lease.DeadlineTick) { return 'Operation budget expired' }
    if ($now -ge [long]$Lease.ExpiresTick) { return 'Lease expired' }
    if ($now - [long]$Lease.HeartbeatTick -ge 45000) { return 'Owner heartbeat lost' }
    return $null
}

function Remove-MemLabsInternetTemporaryRules {
    param([Parameter(Mandatory)]$VM)

    $adapters = @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)
    if ($adapters.Count -eq 0) { throw "$($VM.Name) has no adapters; temporary permissions could not be verified." }
    foreach ($adapter in $adapters) {
        $rules = @(Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter -ErrorAction Stop |
            Where-Object { $_.Weight -ge 6000 -and $_.Weight -le 6999 })
        foreach ($rule in $rules) { $rule | Remove-VMNetworkAdapterExtendedAcl -ErrorAction Stop }
        if (-not (Test-VmInternetAclSet -Adapter $adapter -Rules @() -MinimumWeight 6000 -MaximumWeight 6999)) {
            throw "Temporary rules remain on adapter '$($adapter.Name)'."
        }
    }
}

function Close-MemLabsInternetLease {
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Reason)

    try {
        Remove-MemLabsInternetTemporaryRules -VM $VM
        foreach ($adapter in @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)) {
            if (-not (Test-VmInternetAclSet -Adapter $adapter -Rules @(Get-VmProxyEnforcementRules) -MinimumWeight 5000 -MaximumWeight 5099)) {
                throw "Baseline rules are incomplete on adapter '$($adapter.Name)'."
            }
        }
        if ($State.RecoveryHold) {
            Set-VM -VM $VM -AutomaticStartAction $State.RecoveryHold.Action -AutomaticStartDelay $State.RecoveryHold.Delay -ErrorAction Stop
            $verified = Get-VM -Id $VM.Id -ErrorAction Stop
            if ("$($verified.AutomaticStartAction)" -ne "$($State.RecoveryHold.Action)" -or
                $verified.AutomaticStartDelay -ne $State.RecoveryHold.Delay) { throw 'Automatic startup restoration was not retained.' }
        }
        $State.Status = 'Isolated'
        Write-MemLabsInternetEvent -State $State -EventName 'Revoked' -Message $Reason
        $State.Lease = $null
        $State.RecoveryHold = $null
        Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $VM.Id) -Value $State
    }
    catch {
        $State.Status = 'Degraded'
        Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $VM.Id) -Value $State
        Write-MemLabsInternetEvent -State $State -EventName 'RecoveryFailed' -Message "VM kept running; temporary connectivity may remain. $($_.Exception.Message)" -Failure
        throw
    }
}

function Repair-MemLabsInternetPolicies {
    $root = Get-MemLabsInternetStateRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    $bootId = Get-MemLabsInternetBootId
    $vms = @(Get-VM -ErrorAction Stop)
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction Stop |
            Where-Object { $_.BaseName -match '^[0-9a-f-]{36}$' })) {
        try {
            $id = [guid]$file.BaseName
            if ($id -in $vms.Id) { continue }
            Invoke-MemLabsInternetStateLock -VMId $id -Operation {
                if ($id -in @(Get-VM -ErrorAction Stop).Id) { return }
                Write-MemLabsInternetEvent -State ([pscustomobject]@{ VMId = "$id"; VMName = '(removed)'; Status = 'Retired'; Lease = $null }) `
                    -EventName 'Retired' -Message 'VM ID is no longer registered; its old recovery metadata cannot authorize another VM.'
                [IO.File]::Move($file.FullName, ($file.FullName + '.retired.' + [DateTime]::UtcNow.Ticks))
            }
        }
        catch { $failures.Add("Retiring '$($file.Name)' recovery metadata failed: $($_.Exception.Message)") }
    }
    foreach ($vm in $vms) {
        $path = Get-MemLabsInternetStatePath -VMId $vm.Id
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -and "$($vm.Notes)" -notmatch '"noInternet"\s*:\s*true') { continue }
        try {
            Invoke-MemLabsInternetStateLock -VMId $vm.Id -Operation {
                try { $state = Read-MemLabsInternetState -VMId $vm.Id }
                catch {
                    $stateFailure = $_
                    Remove-MemLabsInternetTemporaryRules -VM $vm
                    throw "Removed orphan temporary permits from '$($vm.Name)', but policy/startup metadata still requires repair: $($stateFailure.Exception.Message)"
                }
                if ($state.Lease -or $state.RecoveryHold -or $state.Status -eq 'Degraded') {
                    $reason = if ($state.Lease -and $state.Status -eq 'ExceptionActive') {
                        Get-MemLabsInternetLeaseFailure -Lease $state.Lease -BootId $bootId
                    }
                    else { 'Interrupted preparation or previously failed recovery' }
                    if ($reason) { Close-MemLabsInternetLease -VM $vm -State $state -Reason $reason }
                }
                else {
                    $orphaned = @(Get-VMNetworkAdapterExtendedAcl -VMName $vm.Name -ErrorAction Stop |
                        Where-Object { $_.Weight -ge 6000 -and $_.Weight -le 6999 })
                    if ($orphaned.Count) {
                        Close-MemLabsInternetLease -VM $vm -State $state -Reason 'Orphan permissions (for example, restored checkpoint)'
                    }
                }
            }
        }
        catch {
            $message = "$($vm.Name): $($_.Exception.Message)"
            $failures.Add($message)
            try {
                Write-MemLabsInternetJson -Path (Join-Path $root "$($vm.Id).failure.json") -Value @{
                    TimestampUtc = [DateTime]::UtcNow.ToString('o'); VMId = "$($vm.Id)"; Message = $message
                }
            }
            catch { $failures.Add("Could not retain '$($vm.Name)' recovery failure diagnostics: $($_.Exception.Message)") }
        }
    }
    if ($failures.Count) { throw ($failures -join '; ') }
}

function Test-MemLabsInternetRecoveryTask {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][string]$Arguments)

    if ($Task.Actions.Count -ne 1 -or $Task.Actions[0].Execute -ne $Engine -or
        $Task.Actions[0].Arguments -ne $Arguments -or
        $Task.Principal.UserId -notin @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18') -or
        "$($Task.Principal.RunLevel)" -ne 'Highest' -or "$($Task.Principal.LogonType)" -ne 'ServiceAccount') { return $false }
    $boot = @($Task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and $_.Enabled -eq $true })
    if ($boot.Count -eq 0 -or $Task.Settings.Enabled -ne $true -or
        $Task.Settings.AllowDemandStart -ne $true -or $Task.Settings.StartWhenAvailable -ne $true -or
        $Task.Settings.DisallowStartIfOnBatteries -ne $false -or $Task.Settings.StopIfGoingOnBatteries -ne $false -or
        "$($Task.Settings.MultipleInstances)" -ne 'IgnoreNew' -or $Task.Settings.RestartCount -lt 999) { return $false }
    try {
        return [Xml.XmlConvert]::ToTimeSpan("$($Task.Settings.ExecutionTimeLimit)") -eq [TimeSpan]::Zero -and
            [Xml.XmlConvert]::ToTimeSpan("$($Task.Settings.RestartInterval)") -eq [TimeSpan]::FromMinutes(1)
    }
    catch [FormatException] { return $false }
}

function Get-MemLabsInternetRuntimeSignature {
    param([Parameter(Mandatory)][string]$Library, [Parameter(Mandatory)][string]$EntryPoint)

    $text = (Get-FileHash -LiteralPath $Library -Algorithm SHA256 -ErrorAction Stop).Hash +
        (Get-FileHash -LiteralPath $EntryPoint -Algorithm SHA256 -ErrorAction Stop).Hash
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($text)))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Install-MemLabsInternetRecovery {
    $root = Get-MemLabsInternetStateRoot
    $mutex = [Threading.Mutex]::new($false, 'Global\MemLabsInternetRecoveryInstall')
    $held = $false
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Timed out preparing independent Internet exception recovery.' }
        Initialize-MemLabsInternetStateRoot
        $library = Join-Path $PSScriptRoot 'Common.Internet.ps1'
        $source = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Repair-VmInternetPolicy.ps1'
        $signature = Get-MemLabsInternetRuntimeSignature -Library $library -EntryPoint $source
        $runtime = Join-Path $root "runtime\$signature"
        $null = New-Item -ItemType Directory -Path $runtime -Force -ErrorAction Stop
        foreach ($entry in @(
                @{ Source = $library; Name = 'Common.Internet.ps1' },
                @{ Source = $source; Name = 'Repair-VmInternetPolicy.ps1' }
            )) {
            $destination = Join-Path $runtime $entry.Name
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                Copy-Item -LiteralPath $entry.Source -Destination $destination -ErrorAction Stop
            }
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne
                (Get-FileHash -LiteralPath $entry.Source -Algorithm SHA256 -ErrorAction Stop).Hash) {
                throw "Independent recovery runtime '$destination' does not match its source."
            }
        }
        $engine = (Get-Process -Id $PID -ErrorAction Stop).Path
        if ($PSVersionTable.PSVersion -lt [version]'7.4' -or $PSVersionTable.PSEdition -ne 'Core') {
            throw 'Internet exception recovery requires a PowerShell 7.4+ host.'
        }
        $arguments = "-NoLogo -NoProfile -NonInteractive -File `"$(Join-Path $runtime 'Repair-VmInternetPolicy.ps1')`" -Watch"
        $taskName = 'MemLabs-InternetExceptionRecovery'
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task -or -not (Test-MemLabsInternetRecoveryTask -Task $task -Engine $engine -Arguments $arguments)) {
            if ($task -and $task.State -eq 'Running') {
                $active = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction Stop |
                    Where-Object { $_.BaseName -match '^[0-9a-f-]{36}$' } |
                    ForEach-Object { Read-MemLabsInternetState -VMId ([guid]$_.BaseName) } |
                    Where-Object { $_.Lease -or $_.RecoveryHold -or $_.Status -ne 'Isolated' })
                if ($active.Count) { throw 'An older recovery runtime owns pending exceptions; recover them before upgrading its task.' }
                Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
            }
            $action = New-ScheduledTaskAction -Execute $engine -Argument $arguments
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force -ErrorAction Stop
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            if (-not (Test-MemLabsInternetRecoveryTask -Task $task -Engine $engine -Arguments $arguments)) {
                throw 'Independent recovery task did not retain its SYSTEM, startup and restart settings.'
            }
        }
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $requestedTick = [Environment]::TickCount64
        $bootId = Get-MemLabsInternetBootId
        $readyPath = Join-Path $root 'recovery.ready.json'
        $wait = [Diagnostics.Stopwatch]::StartNew()
        do {
            if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
                $ready = Get-Content -LiteralPath $readyPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($ready.Signature -eq $signature -and $ready.BootId -eq $bootId -and [long]$ready.Tick -ge $requestedTick -and
                    [Environment]::TickCount64 - [long]$ready.Tick -lt 15000 -and
                    (Test-MemLabsInternetOwner -Owner $ready.Owner)) { return }
            }
            Start-Sleep -Seconds 1
        } while ($wait.Elapsed.TotalSeconds -lt 30)
        throw 'Independent Internet recovery did not acknowledge a successful sweep within 30 seconds; no exception was opened.'
    }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Resolve-MemLabsInternetDestinations {
    param([string[]]$HostNames, [string[]]$Urls)

    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $HostNames) { $null = $names.Add($name) }
    foreach ($url in $Urls) {
        $uri = [uri]$url
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('https', 'http') -or $uri.UserInfo) {
            throw 'Internet exception URLs must be absolute HTTP(S) URLs without embedded credentials.'
        }
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        try {
            for ($redirect = 0; $redirect -le 10; $redirect++) {
                $null = $names.Add($uri.DnsSafeHost)
                $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Head, $uri)
                try { $response = $client.SendAsync($request).GetAwaiter().GetResult() }
                finally { $request.Dispose() }
                try {
                    if ([int]$response.StatusCode -notin @(301, 302, 303, 307, 308)) { break }
                    if (-not $response.Headers.Location -or $redirect -eq 10) { throw 'Internet exception redirect chain is invalid or too long.' }
                    $next = [uri]::new($uri, $response.Headers.Location)
                    if ($next.Scheme -notin @('http', 'https') -or $next.UserInfo -or
                        ($uri.Scheme -eq 'https' -and $next.Scheme -ne 'https')) { throw 'Unsafe Internet exception redirect.' }
                    $uri = $next
                }
                finally { $response.Dispose() }
            }
        }
        finally { $client.Dispose(); $handler.Dispose() }
    }
    if ($names.Count -eq 0) { throw 'An Internet exception must identify at least one destination.' }
    $addresses = foreach ($name in $names) {
        if ($name -notmatch '^(?=.{1,253}$)[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$') {
            throw "Invalid Internet exception destination '$name'."
        }
        $resolved = @(Resolve-DnsName -Name $name -Type A_AAAA -QuickTimeout -ErrorAction Stop |
            Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        if ($resolved.Count -eq 0) { throw "No addresses were resolved for Internet exception destination '$name'." }
        $resolved
    }
    return @($addresses | Sort-Object -Unique)
}

function Start-VmInternetException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][ValidateSet('DeploymentPrerequisites', 'ConfigMgrSetup', 'Download', 'Maintenance')][string]$Purpose,
        [string[]]$HostNames = @(),
        [string[]]$Urls = @(),
        [ValidateRange(1, 210)][int]$MaximumMinutes = 30
    )

    if (Get-VmInternetExceptionHandle) { throw 'This operation already owns an Internet exception; nested bypasses are not supported.' }
    $runspaceId = [Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId.ToString()
    if (-not (Get-MemLabsInternetLeaseKey)) { throw 'Internet exceptions require an identifiable owning runspace.' }
    Assert-VmNoInternetPolicy -VMName $VMName
    Install-MemLabsInternetRecovery
    $addresses = @(Resolve-MemLabsInternetDestinations -HostNames $HostNames -Urls $Urls)
    if ($addresses.Count -gt 500) { throw 'Internet exception exceeds the 500-address scope limit.' }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $leaseId = [guid]::NewGuid().ToString()
    $owner = Get-Process -Id $PID -ErrorAction Stop
    Invoke-MemLabsInternetStateLock -VMId $vm.Id -Operation {
        $vm = Get-VM -Id $vm.Id -ErrorAction Stop
        $state = Read-MemLabsInternetState -VMId $vm.Id
        if ($state.Status -ne 'Isolated' -or $state.Lease -or $state.RecoveryHold) { throw "$VMName already has an exception or unresolved recovery." }
        $tick = [Environment]::TickCount64
        $rules = @()
        $weight = 6000
        foreach ($address in $addresses) {
            foreach ($port in @(80, 443)) {
                $rules += [pscustomobject]@{
                    Action = 'Allow'; Direction = 'Outbound'; Protocol = 'TCP'
                    RemoteIPAddress = $address; RemotePort = $port; Weight = $weight
                }
                $weight++
            }
        }
        $state.Status = 'Prepared'
        $state.RecoveryHold = [pscustomobject]@{ Action = "$($vm.AutomaticStartAction)"; Delay = $vm.AutomaticStartDelay }
        $state.Lease = [pscustomobject]@{
            Id = $leaseId; Purpose = $Purpose; BootId = (Get-MemLabsInternetBootId)
            Owner = [pscustomobject]@{ Id = $PID; StartTicks = $owner.StartTime.ToUniversalTime().Ticks.ToString(); RunspaceId = $runspaceId }
            HeartbeatTick = $tick; ExpiresTick = ($tick + [Math]::Min(15, $MaximumMinutes) * 60000)
            DeadlineTick = ($tick + [long]$MaximumMinutes * 60000)
            ExpiresUtc = [DateTime]::UtcNow.AddMinutes([Math]::Min(15, $MaximumMinutes)).ToString('o')
            Rules = $rules
        }
        Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $vm.Id) -Value $state
        try {
            Write-MemLabsInternetEvent -State $state -EventName 'Prepared' -Message "$Purpose; TCP 80/443 only; $($addresses.Count) resolved address(es); maximum $MaximumMinutes minutes."
            Set-VM -VM $vm -AutomaticStartAction Nothing -ErrorAction Stop
            if ("$((Get-VM -Id $vm.Id -ErrorAction Stop).AutomaticStartAction)" -ne 'Nothing') { throw 'Could not establish the host-reboot startup interlock.' }
            foreach ($adapter in @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)) {
                foreach ($rule in $rules) {
                    Add-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter -Action Allow -Direction Outbound -Protocol TCP `
                        -RemoteIPAddress $rule.RemoteIPAddress -RemotePort $rule.RemotePort -Weight $rule.Weight -Stateful $false -ErrorAction Stop
                }
            }
            $state.Status = 'ExceptionActive'
            Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $vm.Id) -Value $state
            Assert-VmNoInternetPolicy -VMName $VMName -AllowException
            Write-MemLabsInternetEvent -State $state -EventName 'Granted' -Message "Lease $leaseId expires $($state.Lease.ExpiresUtc)."
        }
        catch {
            $grantFailure = $_
            Close-MemLabsInternetLease -VM $vm -State $state -Reason 'Grant failed; reverting partial permissions'
            throw $grantFailure
        }
    }
    $handle = [pscustomobject]@{ VMId = "$($vm.Id)"; VMName = $VMName; Id = $leaseId; RunspaceId = $runspaceId; LastHeartbeatTick = [Environment]::TickCount64 }
    [AppDomain]::CurrentDomain.SetData((Get-MemLabsInternetLeaseKey), $handle)
    return $handle
}

function Update-VmInternetExceptionHeartbeat {
    param([switch]$Force)

    $handle = Get-VmInternetExceptionHandle
    if (-not $handle -or (-not $Force -and [Environment]::TickCount64 - [long]$handle.LastHeartbeatTick -lt 30000)) { return }
    Invoke-MemLabsInternetStateLock -VMId $handle.VMId -Operation {
        $state = Read-MemLabsInternetState -VMId $handle.VMId
        if ($state.Status -ne 'ExceptionActive' -or "$($state.Lease.Id)" -ne $handle.Id -or
            "$($state.Lease.Owner.RunspaceId)" -ne $handle.RunspaceId) {
            throw "$($handle.VMName) Internet exception was revoked or degraded; the operation cannot continue as successful."
        }
        $reason = Get-MemLabsInternetLeaseFailure -Lease $state.Lease -BootId (Get-MemLabsInternetBootId)
        if ($reason) { throw "$($handle.VMName) Internet exception cannot be renewed: $reason." }
        $tick = [Environment]::TickCount64
        $state.Lease.HeartbeatTick = $tick
        $state.Lease.ExpiresTick = [Math]::Min(($tick + 900000), [long]$state.Lease.DeadlineTick)
        $remaining = $state.Lease.ExpiresTick - $tick
        $state.Lease.ExpiresUtc = [DateTime]::UtcNow.AddMilliseconds($remaining).ToString('o')
        Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $handle.VMId) -Value $state
        Write-MemLabsInternetEvent -State $state -EventName 'Renewed' -Message "Lease expires $($state.Lease.ExpiresUtc); original operation budget unchanged."
        $handle.LastHeartbeatTick = $tick
    }
}

function Stop-VmInternetException {
    param([Parameter(Mandatory)]$Handle)

    $owned = Get-VmInternetExceptionHandle
    if (-not $owned -or $owned.Id -ne $Handle.Id -or $owned.RunspaceId -ne $Handle.RunspaceId) {
        throw 'Internet exception closure must run in its owning operation/runspace.'
    }
    try {
        Invoke-MemLabsInternetStateLock -VMId $Handle.VMId -Operation {
            $vm = Get-VM -Id $Handle.VMId -ErrorAction Stop
            $state = Read-MemLabsInternetState -VMId $Handle.VMId
            if (-not $state.Lease -or "$($state.Lease.Id)" -ne $Handle.Id) {
                throw "$($Handle.VMName) exception ownership changed or recovery already revoked it; this operation must report failure."
            }
            $expiryFailure = if ($state.Status -ne 'ExceptionActive') { 'Enforcement/recovery degraded during the operation' }
            else { Get-MemLabsInternetLeaseFailure -Lease $state.Lease -BootId (Get-MemLabsInternetBootId) }
            Close-MemLabsInternetLease -VM $vm -State $state -Reason 'Operation finished'
            if ($expiryFailure) { throw "$($Handle.VMName) completed after its Internet exception became invalid: $expiryFailure." }
        }
    }
    finally {
        $current = Get-VmInternetExceptionHandle
        if ($current -and $current.Id -eq $Handle.Id) {
            [AppDomain]::CurrentDomain.SetData((Get-MemLabsInternetLeaseKey), $null)
        }
    }
}

function Invoke-WithVmInternetException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][ValidateSet('DeploymentPrerequisites', 'ConfigMgrSetup', 'Download', 'Maintenance')][string]$Purpose,
        [string[]]$HostNames = @(),
        [string[]]$Urls = @(),
        [ValidateRange(1, 210)][int]$MaximumMinutes = 30,
        [Parameter(Mandatory)][scriptblock]$Operation
    )

    $handle = Start-VmInternetException -VMName $VMName -Purpose $Purpose -HostNames $HostNames -Urls $Urls -MaximumMinutes $MaximumMinutes
    try { & $Operation }
    finally { Stop-VmInternetException -Handle $handle }
}

function Get-MemLabsInternetCacheProbe {
    # Read the cache DVD contract without importing DSC or changing its session.
    return {
        param([string[]]$Urls, [scriptblock]$Registry32Reader)
        $cached = [Collections.Generic.List[string]]::new()
        $issues = [Collections.Generic.List[string]]::new()
        $netPath = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
        $netRelease = 0
        if (Test-Path -LiteralPath $netPath -ErrorAction Stop) {
            $netRelease = [int](Get-ItemProperty -LiteralPath $netPath -ErrorAction Stop).Release
        }
        if (-not $Registry32Reader) {
            $Registry32Reader = {
                $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
                $subKey = $null
                try {
                    $subKey = $key.OpenSubKey('SOFTWARE\Microsoft\Windows Kits\Installed Roots')
                    if ($subKey) { return "$($subKey.GetValue('KitsRoot10'))" }
                    return ''
                }
                finally { if ($subKey) { $subKey.Dispose() }; $key.Dispose() }
            }
        }
        $kitsRoot = & $Registry32Reader
        $kits = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
        $adkReady = [bool]($kitsRoot -and
            (Test-Path -LiteralPath "$kits\Deployment Tools" -PathType Container -ErrorAction Stop) -and
            (Test-Path -LiteralPath "$kits\Windows Preinstallation Environment" -PathType Container -ErrorAction Stop) -and
            (Test-Path -LiteralPath "$kits\User State Migration Tool" -PathType Container -ErrorAction Stop))
        $ssms = Get-ChildItem -Path @(
            'C:\Program Files\Microsoft SQL Server Management Studio *\Release\Common7\IDE\Ssms.exe',
            'C:\Program Files\Microsoft SQL Server Management Studio *\Common7\IDE\Ssms.exe',
            'C:\Program Files (x86)\Microsoft SQL Server Management Studio *\Common7\IDE\ssms.exe'
        ) -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 } | Select-Object -First 1
        $pbirsReady = Test-Path -LiteralPath 'C:\PBIRS\PBIRS\ReportServer\RSReportServer.config' -ErrorAction Stop
        $discs = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction Stop |
            Where-Object { $_.VolumeName -eq 'MEMLABSCACHE' -and $_.DeviceID })
        foreach ($disc in $discs) {
            $manifestPath = Join-Path "$($disc.DeviceID)\" 'manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf -ErrorAction Stop)) { continue }
            try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
            catch { $issues.Add("Cache manifest could not be verified: $($_.Exception.Message)"); continue }
            foreach ($url in $Urls) {
                $entry = $manifest.files.PSObject.Properties | Where-Object { $_.Name.Trim() -ieq $url.Trim() } | Select-Object -First 1
                if (-not $entry -or -not $entry.Value.file) { continue }
                $payload = Join-Path "$($disc.DeviceID)\" $entry.Value.file
                if (-not (Test-Path -LiteralPath $payload -PathType Leaf -ErrorAction Stop)) { continue }
                $item = Get-Item -LiteralPath $payload -ErrorAction Stop
                if (-not $entry.Value.sha1 -or $item.Length -ne [long]$entry.Value.size -or
                    (Get-FileHash -LiteralPath $payload -Algorithm SHA1 -ErrorAction Stop).Hash -ine $entry.Value.sha1) {
                    $issues.Add("Cache payload '$($item.Name)' did not match its size/hash manifest.")
                    continue
                }
                if (-not $cached.Contains($url)) { $cached.Add($url) }
            }
        }
        [pscustomobject]@{
            CachedUrls = $cached.ToArray(); DotNetReady = ($netRelease -ge 528040)
            AdkReady = $adkReady; SsmsReady = [bool]$ssms; PbirsReady = [bool]$pbirsReady; Issues = $issues.ToArray()
        }
    }
}

function Get-VmInternetCacheFacts {
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$VMDomain, [string[]]$Urls)

    $result = Invoke-VmCommand -VMName $VMName -VMDomainName $VMDomain -AsJob -TimeoutSeconds 180 -FailOnRemoteError `
        -ScriptBlock (Get-MemLabsInternetCacheProbe) -ArgumentList (, @($Urls)) -DisplayName 'Verify noInternet cached prerequisites'
    if (-not $result -or $result.ScriptBlockFailed) { throw "$VMName prerequisite cache availability could not be measured; no exception was opened." }
    $facts = $result.ScriptBlockOutput
    if ($null -eq $facts -or $facts.DotNetReady -isnot [bool] -or $facts.AdkReady -isnot [bool] -or
        $facts.SsmsReady -isnot [bool] -or $facts.PbirsReady -isnot [bool] -or
        $facts.PSObject.Properties.Name -notcontains 'CachedUrls') { throw "$VMName returned invalid prerequisite cache facts." }
    foreach ($issue in @($facts.Issues | Where-Object { $_ })) { Write-Log "[NoInternet] $VMName`: $issue" -Warning }
    return $facts
}

function Get-VmDeploymentInternetException {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$DeployConfig,
        [Parameter(Mandatory)][int]$Phase,
        [string]$VMDomain
    )

    if ($VM.noInternet -ne $true -or $Phase -notin @(2, 3, 4, 7, 8, 9)) { return }
    $keys = @()
    $needsAdk = $false
    $needsSsms = $false
    $needsCm = $false
    $needsSync = $false
    $cmo = if ($VM.cmOptions) { $VM.cmOptions } else { $DeployConfig.cmOptions }
    switch ($Phase) {
        2 {
            if ($VM.role -eq 'WorkgroupMember') { $keys = @('DotNet') }
        }
        3 {
            $keys = @('DotNet', 'ODBC', 'OleDB', 'SQLClient', 'VCredist', 'VCredistX86')
            $needsSsms = $VM.installSSMS -eq $true -or ($null -eq $VM.installSSMS -and $VM.sqlVersion)
            if ($needsSsms) { $keys += 'SSMS' }
            $needsAdk = $VM.role -in @('CAS', 'Primary', 'PassiveSite') -or $VM.installSMSProv -eq $true
        }
        4 {
            if (-not $VM.sqlVersion) { return }
        }
        7 {
            if ($VM.installRP -eq $true) { $keys += 'PBIRS' }
            $needsSync = ($VM.installSUP -eq $true -or $VM.role -eq 'WSUS') -and $cmo.OfflineSUP -ne $true
        }
        { $_ -in @(8, 9) } {
            if ($VM.role -notin @('CAS', 'Primary', 'Secondary', 'PassiveSite', 'SiteSystem', 'WSUS') -and
                -not $VM.installRP -and -not $VM.installSUP) { return }
            $keys = @('ODBC', 'ReportBuilder')
            if ($VM.InstallPatchMyPC -eq $true) { $keys += 'PMPC' }
            $needsAdk = $VM.role -in @('CAS', 'Primary', 'Secondary', 'PassiveSite') -or $VM.installSMSProv -eq $true
            $needsCm = $VM.role -in @('CAS', 'Primary')
            $needsSync = ($VM.installSUP -eq $true -or $VM.role -eq 'WSUS') -and $cmo.OfflineSUP -ne $true
        }
    }
    if ($needsAdk) { $keys += @('ADK', 'ADKPE') }
    $urls = @(
        foreach ($key in $keys) { if ($DeployConfig.URLS.$key) { [string]$DeployConfig.URLS.$key } }
        if ($Phase -in @(3, 8, 9) -and $VM.thisParams.cmDownloadVersion.downloadUrl) { [string]$VM.thisParams.cmDownloadVersion.downloadUrl }
        if ($Phase -eq 4) {
            if ($VM.thisParams.sqlCUURL) { [string]$VM.thisParams.sqlCUURL }
            if ($VM.sqlVersion -notmatch '201[0-6]' -and $VM.thisParams.backupSolutionURL) { [string]$VM.thisParams.backupSolutionURL }
        }
    )
    if ($urls.Count -eq 0 -and -not $needsAdk -and -not $needsCm -and -not $needsSync) { return }
    if (-not $VMDomain) { $VMDomain = if ($VM.domain) { $VM.domain } else { $DeployConfig.vmOptions.domainName } }
    $facts = Get-VmInternetCacheFacts -VMName $VM.vmName -VMDomain $VMDomain -Urls $urls
    if ($facts.DotNetReady) { $urls = @($urls | Where-Object { $_ -ne $DeployConfig.URLS.DotNet }) }
    if ($facts.AdkReady) {
        $needsAdk = $false
        $urls = @($urls | Where-Object { $_ -notin @($DeployConfig.URLS.ADK, $DeployConfig.URLS.ADKPE) })
    }
    if ($facts.SsmsReady) {
        $needsSsms = $false
        $urls = @($urls | Where-Object { $_ -ne $DeployConfig.URLS.SSMS })
    }
    if ($facts.PbirsReady) { $urls = @($urls | Where-Object { $_ -ne $DeployConfig.URLS.PBIRS }) }
    $missing = @($urls | Where-Object { $_ -notin $facts.CachedUrls } | Sort-Object -Unique)
    if ($needsSsms -and $DeployConfig.URLS.SSMS) { $missing = @($missing + $DeployConfig.URLS.SSMS | Sort-Object -Unique) }
    $hosts = @()
    if ($needsAdk -or $needsCm -or $needsSsms) { $hosts += 'download.microsoft.com' }
    if ($needsSync) { $hosts += @('download.windowsupdate.com', 'catalog.s.download.windowsupdate.com', 'sws.update.microsoft.com') }
    if ($missing.Count -eq 0 -and $hosts.Count -eq 0) {
        Write-Log "[NoInternet] $($VM.vmName): Required prerequisite payloads are cached/installed; no Internet exception requested."
        return
    }
    return @{
        VMName = $VM.vmName
        Purpose = $(if ($Phase -in @(8, 9)) { 'ConfigMgrSetup' } else { 'DeploymentPrerequisites' })
        Urls = $missing; HostNames = $hosts
        MaximumMinutes = $(if ($Phase -in @(4, 8, 9)) { 210 } elseif ($Phase -eq 3) { 180 } else { 60 })
    }
}
