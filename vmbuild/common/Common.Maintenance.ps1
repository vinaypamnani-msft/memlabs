# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.

function Start-Maintenance {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "If present, maintenance runs only for machines in DeployConfig")]
        [object]$DeployConfig
    )

    $freshDeployOnly = $false
    if ($DeployConfig) {
        Write-log "Start-Maintenance called with DeployConfig"
        $allVMs = $DeployConfig.virtualMachines | Where-Object { -not $_.hidden }
        $vmsNeedingMaintenance = @($allVMs | Sort-Object vmName)
        $freshDeployOnly = $true
    }
    else {
        Write-log -verbose "Start-Maintenance called without DeployConfig"
        $allVMs = Get-List -Type VM | Where-Object { $_.vmBuild -eq $true -and $_.inProgress -ne $true }
        $vmsNeedingMaintenance = @($allVMs | Sort-Object vmName)
    }

    Write-Log -Verbose "Latest Hotfix Version: $($Common.LatestHotfixVersion)"
    $countWorked = $countFailed = $countSkipped = 0
    # Filter in-progress. Also exclude offline StandaloneRootCA VMs - they are
    # intentionally powered off after issuing sub-CA certs and should not be
    # offered for maintenance or auto-started. Also exclude Linux VMs
    # (role=Proxy / osFamily=Linux / Ubuntu|Debian OS) which have no
    # Windows-side maintenance pipeline and would just be skipped downstream.
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object {
        $_.inProgress -ne $true -and
        -not ($_.Role -in @("OSDClient", "AADClient")) -and
        -not ($_.Role -eq "StandaloneRootCA" -and $_.State -ne "Running") -and
        -not ($_.Role -eq "Proxy") -and
        -not ($_.osFamily -eq "Linux") -and
        -not ($_.operatingSystem -like "Ubuntu*" -or $_.operatingSystem -like "Debian*" -or $_.operatingSystem -like "Linux*") -and
        -not ($_.deployedOS -like "Ubuntu*" -or $_.deployedOS -like "Debian*" -or $_.deployedOS -like "Linux*")
    }

    # Pre-filter: skip VMs where every fix is already recorded in appliedFixes.
    # This avoids starting a job/thread for VMs that have nothing to do.
    # Bulk-read all VM notes in a single Get-VM call (one CIM round-trip)
    # instead of per-VM Get-VMNote calls that serialize on vmms.exe.
    $allFixDefs = Get-VMFixes -ReturnDummyList
    $relevantFixes = if ($freshDeployOnly) {
        $allFixDefs | Where-Object { $_.NeededOnFreshDeploy -eq $true }
    } else {
        $allFixDefs | Where-Object { $_.AppliesToExisting -eq $true }
    }
    $vmNoteCache = @{}
    try {
        foreach ($hvm in (Get-VM -ErrorAction SilentlyContinue)) {
            if ($hvm.Notes -like "*lastUpdate*") {
                try { $vmNoteCache[$hvm.Name] = $hvm.Notes | ConvertFrom-Json } catch {}
            }
        }
    } catch {}

    $countUpToDate = 0
    $vmsNeedingMaintenance = @($vmsNeedingMaintenance | Where-Object {
        $note = $vmNoteCache[$_.vmName]
        if ($note -and $note.appliedFixes) {
            # Per-fix tracking: skip if every relevant fix is already recorded
            $missing = $false
            foreach ($fix in $relevantFixes) {
                if (-not (Test-VMFixApplied -VMNote $note -FixName $fix.FixName -FixVersion $fix.FixVersion)) {
                    $missing = $true
                    break
                }
            }
            if (-not $missing) {
                Write-Log "$($_.vmName): All fixes recorded, skipping." -Verbose
                $countUpToDate++
                return $false
            }
        }
        elseif ($note -and
                ($note.PSObject.Properties.Name -notcontains 'appliedFixes') -and
                $note.memLabsVersion -and
                (ConvertTo-MemLabsVersion $note.memLabsVersion) -ge (ConvertTo-MemLabsVersion $Common.LatestHotfixVersion)) {
            # Transitional: VM managed by old watermark system (no appliedFixes
            # property). Watermark is at or past the latest fix, so seed all fix
            # versions into appliedFixes and skip. This is a one-time migration;
            # subsequent runs use the per-fix check above.
            $seeded = @{}
            foreach ($fix in $allFixDefs) {
                if ($fix.PSObject.Properties.Name -contains 'DoNotSeedFromWatermark' -and $fix.DoNotSeedFromWatermark) {
                    continue
                }
                $seeded[$fix.FixName] = [string]$fix.FixVersion
            }
            $note | Add-Member -MemberType NoteProperty -Name "appliedFixes" -Value ([PSCustomObject]$seeded) -Force
            $note | Add-Member -MemberType NoteProperty -Name "lastUpdate" -Value (Get-Date -format "MM/dd/yyyy HH:mm") -Force
            $json = ($note | ConvertTo-Json) -replace "`r`n","" -replace "    "," " -replace "  "," "
            try { Set-VM -Name $_.vmName -Notes $json -ErrorAction SilentlyContinue } catch {}
            $unseededRelevant = @($relevantFixes | Where-Object {
                    $_.PSObject.Properties.Name -contains 'DoNotSeedFromWatermark' -and $_.DoNotSeedFromWatermark
                })
            if ($unseededRelevant.Count -gt 0) {
                Write-Log "$($_.vmName): Seeded legacy fixes from watermark ($($note.memLabsVersion)); running non-seedable compliance fix(es): $($unseededRelevant.FixName -join ', ')." -Verbose
                return $true
            }
            Write-Log "$($_.vmName): Seeded appliedFixes from watermark ($($note.memLabsVersion)), skipping." -Verbose
            $countUpToDate++
            return $false
        }
        return $true
    })

    $newVmsNeedingMaintenance = @()
    foreach ($vm in $vmsNeedingMaintenance) {
        Write-Log -Verbose "VM Name: $($vm.vmName)"
        $mutexName = $vm.vmName

        try {
            $Mutex = [System.Threading.Mutex]::OpenExisting($MutexName)
        }
        catch {
            Write-Log -Verbose "Mutex $mutexName does not exist.. VM not in use."
            #Mutex does not exist.
            $newVmsNeedingMaintenance = $newVmsNeedingMaintenance + $vm
            continue
        }
        if ($Mutex) {
            Write-Log -Verbose "Mutex $mutexName exists.. VM in use."
            $countSkipped++
            try {
                [void]$Mutex.ReleaseMutex()
            }
            catch {}
        }
    }
    $vmCount = ($newVmsNeedingMaintenance | Measure-Object).Count
    $countNotNeeded = $countUpToDate

    $text = "Performing maintenance"
    $maintenanceDoNotStart = $false
    Write-Log $text -Activity
    $stoppedCount = 0
    $stoppedVms = @()
    if ($freshDeployOnly -eq $false) {
        if ($vmCount -gt 0) {
            $response = Read-YesOrNoWithTimeout -Prompt "$($newVmsNeedingMaintenance.Count) VM(s) [$($newVmsNeedingMaintenance.vmName -join ",")] need memlabs maintenance. Run now? (y/N)" -HideHelp -Default "n" -timeout 15
            if ($response -eq "n") {
                return
            }
            foreach ($vm in $newVmsNeedingMaintenance) {
                if ($vm.State -ne "Running") {
                    $stoppedCount++
                    $stoppedVms += $vm.vmName                
                }
            }
            if ($stoppedCount -gt 0) {
                $response = Read-YesOrNoWithTimeout -Prompt "$stoppedCount VMs stopped. Start [$($stoppedVms-join ",")] for Maintenance (y/N)" -HideHelp -Default "n" -timeout 15
                if ($response -eq "y") {
                    Write-Log "$vmCount VMs need maintenance. VMs will be started (if stopped) and shut down post-maintenance."
                }
                else {
                    Write-Log "$vmCount VMs need maintenance. VMs will NOT be started (if stopped)."
                    $maintenanceDoNotStart = $true
                }
            }
        }
        else {
            Write-Log "No maintenance required." -Success
            return
        }
    }

    foreach ($vm in $newVmsNeedingMaintenance) {
        if ($maintenanceDoNotStart) {
            if ($vm.State -ne "Running") {
                $newVmsNeedingMaintenance = $newVmsNeedingMaintenance | Where-Object { $_.vmName -ne $vm.vmName }
                $countSkipped++
                continue
            }
        }
    }

    # PreferThreadJob: per-VM workers share parent's loaded Hyper-V /
    # DhcpServer / module set and skip a fresh powershell.exe per VM.
    # Phase10Job still dot-sources Common.ps1 -InJob -GetLatestHotfixVersion
    # internally; ThreadJob cuts the per-worker init cost meaningfully.
    $start = Start-NormalJobs -machines $newVmsNeedingMaintenance -ScriptBlock $global:Phase10Job -Phase "Maintenance" -argument1 '' -argument2 $false -argument3 $false -PreferThreadJob -MaintenanceDiagnostics

    $result = Wait-Phase -Phase "Maintenance" -Jobs $start.Jobs -AdditionalData $start.AdditionalData

    #foreach ($vm in $newVmsNeedingMaintenance | Where-Object { $_.role -eq "DC" }) {
    #    $i++
    #    Write-Progress2 -Id $progressId -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
    #    $worked = Start-VMMaintenance -VMName $vm.vmName -FreshDeployOnly:$freshDeployOnly
    #    if ($worked) { $countWorked++ } else {
    #        $failedDomains += $vm.domain
    #        $countFailed++
    #    }
    #}

    $countWorked = $result.Success
    $countFailed = $result.Failed
          

    Write-Host
    Write-Log "Finished maintenance. Success: $countWorked; Failures: $countFailed; Skipped: $countSkipped; Already up-to-date: $countNotNeeded" -SubActivity
    Start-Sleep -seconds 3
    clear-host

    if ($global:MaintenanceActivity) {
        Write-Progress2 -Activity $global:MaintenanceActivity -Completed
    }
}

function Show-FailedDomains {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Failed Domains")]
        [object] $failedDomains
    )

    $failedDCs = Get-List -Type VM | Where-Object { $_.role -eq "DC" -and $_.domain -in $failedDomains }
    $dcList = ($failedDCs | Select-Object vmName, domain, @{Name = "accountsToUpdate"; Expression = { @("vmbuildadmin", $_.adminName, "cm_svc") } }, @{ Name = "desiredPassword"; Expression = { $($Common.LocalAdmin.GetNetworkCredential().Password) } } | Out-String).Trim()
    $dcList = $dcList -split "`r`n"

    Write-Log "Displaying the failed domains message for ($($failedDomains -join ','))." -LogOnly

    $longest = 130
    $longestMinus1 = $longest - 1

    Write-Host
    Write-Host2 "  #".PadRight($longest, "#") -ForegroundColor Yellow
    Write-Host2 "  # DC Maintenance failed for below domains. This may be because the passwords for the required accounts (listed below) expired. #" -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForeGroundColor Yellow
    foreach ($line in $dcList) {
        $newLine = $line -replace '\x1b\[[0-9;]*m'
        Write-Host2 -ForegroundColor Yellow "  #" -NoNewLine
        #subtract the 3 chars displayed above
        $Len = $longestMinus1 - 3
        Write-Host2 " $newLine".PadRight($len, " ").Replace($newLine, $line) -ForegroundColor Turquoise -NoNewLine
        Write-Host2 -ForeGroundColor Yellow "#"
    }
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # Please perform manual remediation steps listed below to keep VMBuild functional.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 1. Logon to the affected DC's using Hyper-V console.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 2. Launch 'AD Users and Computers', and reset the account for the above listed accounts to the desiredPassword.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 3. Run 'VMBuild.cmd' again.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # If the password hasn't expired/changed, re-run VMBuild.cmd in case there was a transient issue.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # If the issue persists, please report it.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 "  #".PadRight($longest, "#") -ForegroundColor Yellow

}

function Write-VMMaintenanceIdentityDiagnostics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object] $Target,
        [Parameter(Mandatory = $true)] [ValidateSet('parent', 'worker')] [string] $Stage,
        [object] $ParentIdentity
    )

    $cached = @($global:vm_List | Where-Object { $_.vmName -eq $Target.vmName })
    $identity = [pscustomobject]@{
        requestedName = [string]$Target.vmName
        configuredId = [string]$Target.vmId
        hostName = $env:COMPUTERNAME
        processId = $PID
        stage = $Stage
        cacheLastUpdate = [string]$global:vm_List_LastUpdate
        cachedIdentities = @($cached | Select-Object vmName, vmId, domain, role, state)
        parentIdentity = $ParentIdentity
        resolvedIdentities = @()
    }
    Write-Log "$($Target.vmName): Maintenance identity input: $($identity | ConvertTo-Json -Depth 8 -Compress)" -LogOnly
    $queries = @([pscustomobject]@{ kind = 'name'; value = [string]$Target.vmName })
    $ids = @($Target.vmId) + @($cached.vmId)
    if ($ParentIdentity) {
        $ids += @($ParentIdentity.configuredId) + @($ParentIdentity.cachedIdentities.vmId) + @($ParentIdentity.resolvedIdentities.Id)
    }
    foreach ($id in @($ids | Where-Object { $_ } | Select-Object -Unique)) {
        $queries += [pscustomobject]@{ kind = 'id'; value = [string]$id }
    }
    foreach ($query in $queries) {
        try {
            $parameters = @{ ErrorAction = 'Stop' }
            if ($query.kind -eq 'id') { $parameters.Id = [guid]$query.value }
            else { $parameters.Name = $query.value }
            $found = @(Get-VM @parameters | Where-Object { $null -ne $_ })
            $resolved = @($found | Select-Object Name, Id, ComputerName, State)
            $identity.resolvedIdentities += $resolved
            Write-Log "$($Target.vmName): Maintenance identity lookup: stage=$Stage kind=$($query.kind) value='$($query.value)' count=$($found.Count) resolved=$($resolved | ConvertTo-Json -Depth 4 -Compress)" -LogOnly
            foreach ($vm in $found) {
                $notes = [string]$vm.Notes
                $hash = [Security.Cryptography.SHA256]::Create()
                try { $digest = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($notes))).Replace('-', '').ToLowerInvariant() }
                finally { $hash.Dispose() }
                $details = "stage=$Stage lookupKind=$($query.kind) registeredName='$($vm.Name)' vmId='$($vm.Id)' vmHost='$($vm.ComputerName)' notesLength=$($notes.Length) notesSha256=$digest"
                try {
                    $note = $notes | ConvertFrom-Json -ErrorAction Stop
                    if ($notes.TrimStart().StartsWith('{') -and $note -is [pscustomobject]) {
                        Write-VMMaintenanceNoteSnapshot -VMName $Target.vmName -Note $note -Details $details
                    }
                    else { Write-Log "$($Target.vmName): Maintenance identity Notes are not a JSON object: $details" -Warning }
                }
                catch {
                    Write-Log "$($Target.vmName): Maintenance identity Notes parse failed: $details errorId='$($_.FullyQualifiedErrorId)' exceptionType='$($_.Exception.GetType().FullName)'." -Warning
                }
            }
        }
        catch {
            Write-Log "$($Target.vmName): Maintenance identity lookup failed: stage=$Stage kind=$($query.kind) value='$($query.value)' host='$env:COMPUTERNAME' errorId='$($_.FullyQualifiedErrorId)' exceptionType='$($_.Exception.GetType().FullName)' hresult=$($_.Exception.HResult) category='$($_.CategoryInfo.Category)' message='$($_.Exception.Message -replace '[\r\n]+', ' ')'." -Warning
        }
    }
    return $identity
}

function Write-VMMaintenanceHostDiagnostics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string] $VMName,
        [switch] $ContextOnly
    )

    $identity = $null
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $vmmsStatus = try { [string](Get-Service vmms -ErrorAction Stop).Status }
        catch { "unavailable: $($_.Exception.Message); errorId='$($_.FullyQualifiedErrorId)'" }
        $context = [ordered]@{
            hostName = $env:COMPUTERNAME
            identity = $identity.Name
            elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            processId = $PID
            psVersion = [string]$PSVersionTable.PSVersion
            osVersion = [Environment]::OSVersion.VersionString
            processIs64Bit = [Environment]::Is64BitProcess
            inJob = [bool]$Common.InJob
            runspaceId = [string][Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId
            connectionDefaults = @($PSDefaultParameterValues.GetEnumerator() | Where-Object { $_.Key -like '*:ComputerName' -or $_.Key -like '*:CimSession' } | ForEach-Object {
                [pscustomobject]@{
                    key = [string]$_.Key
                    value = if ($_.Value -is [string]) { $_.Value }
                    elseif ($_.Value -is [array] -and @($_.Value | Where-Object { $_ -isnot [string] }).Count -eq 0) { @($_.Value) }
                    elseif ($_.Key -like '*:CimSession' -and $_.Value -isnot [scriptblock]) { @($_.Value | Select-Object Name, ComputerName, InstanceId) }
                    else { 'unsupported value (not evaluated or logged)' }
                }
            })
            cimSessions = @(Get-CimSession | Select-Object Name, ComputerName, InstanceId)
            psSessions = @(Get-PSSession | Select-Object Name, ComputerName, InstanceId, State, ConfigurationName)
            vmCacheCount = @($global:vm_List | Where-Object { $null -ne $_ }).Count
            vmCacheTruncated = @($global:vm_List | Where-Object { $null -ne $_ }).Count -gt 100
            vmCacheLastUpdate = [string]$global:vm_List_LastUpdate
            vmCacheDirty = [bool]$global:vm_List_Dirty
            vmCache = @($global:vm_List | Select-Object -First 100 vmName, vmId, domain, role, state)
            vmms = $vmmsStatus
            hyperVModules = @(Get-Module Hyper-V | Select-Object Name, Version, Path)
            getVMCommands = @(Get-Command Get-VM -All -ErrorAction Stop | Select-Object Name, CommandType, Source, Version)
        }
        Write-Log "$VMName`: Maintenance host context: $($context | ConvertTo-Json -Depth 5 -Compress)" -LogOnly
    }
    catch {
        Write-Log "$VMName`: Maintenance host context capture failed: $($_.Exception.Message); errorId='$($_.FullyQualifiedErrorId)'." -Warning
    }
    finally {
        if ($identity) { $identity.Dispose() }
    }
    if ($ContextOnly) { return }

    # Isolate provider/event queries so diagnostic collection cannot hold up a failed phase indefinitely.
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            try {
                $service = Get-Service vmms -ErrorAction Stop
                [pscustomobject]@{ kind = 'vmms'; status = [string]$service.Status }
            }
            catch {
                [pscustomobject]@{ kind = 'vmms'; error = $_.Exception.Message; errorId = $_.FullyQualifiedErrorId }
            }
            try {
                $inventory = @(Get-VM -ErrorAction Stop)
                [pscustomobject]@{
                    kind = 'inventory'
                    count = $inventory.Count
                    truncated = $inventory.Count -gt 100
                    vms = @($inventory | Sort-Object Name | Select-Object -First 100 | ForEach-Object {
                        $entry = [ordered]@{ Name = $_.Name; Id = $_.Id; State = [string]$_.State; ComputerName = $_.ComputerName }
                        $notes = [string]$_.Notes
                        $entry.notesLength = $notes.Length
                        $hash = [Security.Cryptography.SHA256]::Create()
                        try { $entry.notesSha256 = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($notes))).Replace('-', '').ToLowerInvariant() }
                        finally { $hash.Dispose() }
                        try {
                            $note = $notes | ConvertFrom-Json -ErrorAction Stop
                            if ($notes.TrimStart().StartsWith('{') -and $note -is [pscustomobject]) {
                                foreach ($field in @('vmName', 'domain', 'role')) {
                                    $value = $note.$field
                                    if ($value -is [string]) { $entry["notes_$field"] = $value.Substring(0, [Math]::Min(256, $value.Length)) }
                                }
                            }
                            else { $entry.notesStatus = 'notJsonObject' }
                        }
                        catch {
                            $entry.notesStatus = 'parseFailed'
                            $entry.notesErrorId = $_.FullyQualifiedErrorId
                        }
                        [pscustomobject]$entry
                    })
                }
            }
            catch {
                [pscustomobject]@{ kind = 'inventory'; error = $_.Exception.Message; errorId = $_.FullyQualifiedErrorId }
            }
            foreach ($channel in @('Microsoft-Windows-Hyper-V-VMMS-Admin', 'Microsoft-Windows-Hyper-V-Worker-Admin', 'System')) {
                try {
                    $filter = @{ LogName = $channel; StartTime = (Get-Date).AddMinutes(-15); Level = @(1, 2, 3) }
                    if ($channel -eq 'System') { $filter.ProviderName = 'Service Control Manager' }
                    $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 20 -ErrorAction Stop)
                    # Do not export event payloads or rendered messages, which can contain guest data.
                    [pscustomobject]@{
                        kind = 'events'
                        channel = $channel
                        windowMinutes = 15
                        limit = 20
                        limitReached = $events.Count -eq 20
                        events = @($events | Select-Object TimeCreated, Id, RecordId, ProviderName, LevelDisplayName)
                    }
                }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                        [pscustomobject]@{ kind = 'events'; channel = $channel; count = 0 }
                    }
                    else {
                        [pscustomobject]@{ kind = 'events'; channel = $channel; error = $_.Exception.Message; errorId = $_.FullyQualifiedErrorId }
                    }
                }
            }
        } -ErrorAction Stop
        $completed = Wait-Job -Job $job -Timeout 20 -ErrorAction Stop
        Receive-Job -Job $job -ErrorAction Stop | ForEach-Object {
            Write-Log "$VMName`: Maintenance host evidence: $($_ | Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName | ConvertTo-Json -Depth 6 -Compress)" -LogOnly
        }
        if (-not $completed) {
            Write-Log "$VMName`: Maintenance host evidence capture timed out after 20 seconds; evidence may be incomplete." -Warning
        }
        elseif ($job.State -ne 'Completed') {
            Write-Log "$VMName`: Maintenance host evidence worker ended in state '$($job.State)'." -Warning
        }
    }
    catch {
        Write-Log "$VMName`: Maintenance host evidence capture failed: $($_.Exception.Message); errorId='$($_.FullyQualifiedErrorId)'." -Warning
    }
    finally {
        if ($job) {
            try {
                if ($job.State -in @('Running', 'NotStarted', 'Blocked')) { Stop-Job -Job $job -ErrorAction Stop }
                Remove-Job -Job $job -Force -ErrorAction Stop
            }
            catch {
                Write-Log "$VMName`: Maintenance diagnostic worker cleanup failed: $($_.Exception.Message)." -Warning
            }
        }
    }
}

function Write-VMMaintenanceNoteSnapshot {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string] $VMName,
        [Parameter(Mandatory = $true)] [object] $Note,
        [Parameter(Mandatory = $true)] [string] $Details
    )

    $snapshot = [ordered]@{}
    foreach ($field in @('vmName', 'role', 'domain', 'lastUpdate', 'vmBuild', 'inProgress', 'lastPhaseComplete', 'memLabsVersion', 'osFamily', 'operatingSystem', 'deployedOS')) {
        $property = $Note.PSObject.Properties[$field]
        if (-not $property) { continue }
        $value = $property.Value
        if ($value -is [string]) {
            $snapshot[$field] = $value.Substring(0, [Math]::Min($value.Length, 256))
        }
        elseif ($value -is [bool] -or $value -is [int] -or $value -is [long] -or $null -eq $value) {
            $snapshot[$field] = $value
        }
        else {
            $snapshot[$field] = [ordered]@{ invalidType = $value.GetType().FullName }
        }
    }
    $snapshot['fieldCount'] = @($Note.PSObject.Properties).Count
    if ($Note.PSObject.Properties['appliedFixes']) {
        $snapshot['appliedFixesType'] = if ($null -eq $Note.appliedFixes) { 'null' } else { $Note.appliedFixes.GetType().FullName }
        $snapshot['appliedFixesCount'] = if ($Note.appliedFixes -is [pscustomobject]) { @($Note.appliedFixes.PSObject.Properties).Count } else { 0 }
    }
    Write-Log "$VMName`: Maintenance VM Notes snapshot (allowlisted fields, strings limited to 256 characters): $Details $($snapshot | ConvertTo-Json -Depth 4 -Compress)" -LogOnly
}

function Get-VMMaintenanceNote {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)] [string] $VMName)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $details = "host='$env:COMPUTERNAME' attempt=$attempt/3"
        $stage = 'lookup'
        try {
            $vms = @(Get-VM -Name $VMName -ErrorAction Stop | Where-Object { $null -ne $_ })
            if ($vms.Count -ne 1) {
                $reason = "lookupMatchCount=$($vms.Count)"
            }
            else {
                $vm = $vms[0]
                $stage = 'notes'
                $notes = [string]$vm.Notes
                $details += " vmId='$($vm.Id)' state='$($vm.State)' vmHost='$($vm.ComputerName)' notesLength=$($notes.Length)"
                $hash = [Security.Cryptography.SHA256]::Create()
                try {
                    $digest = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($notes))).Replace('-', '').ToLowerInvariant()
                    $details += " notesSha256=$digest"
                }
                finally { $hash.Dispose() }
                if ([string]::IsNullOrWhiteSpace($notes)) {
                    $reason = 'notes=empty'
                }
                elseif ($notes -notlike '*lastUpdate*' -and -not $notes.TrimStart().StartsWith('{')) {
                    $reason = 'managedNoteMarker=missing'
                }
                else {
                    $stage = 'parse'
                    $note = $notes | ConvertFrom-Json -ErrorAction Stop
                    if ($notes.TrimStart().StartsWith('{') -and $note -is [pscustomobject]) {
                        Write-VMMaintenanceNoteSnapshot -VMName $VMName -Note $note -Details $details
                    }
                    if (-not $notes.TrimStart().StartsWith('{') -or $note -isnot [pscustomobject] -or -not $note.PSObject.Properties['lastUpdate']) {
                        $reason = 'managedNoteSchema=invalid expectedObjectWithLastUpdate=true'
                    }
                    else {
                        if (-not $note.adminName) {
                            $note | Add-Member -MemberType NoteProperty -Name adminName -Value $note.domainAdmin -Force
                        }
                        Write-Log "$VMName`: Maintenance metadata read succeeded: $details recovered=$($attempt -gt 1)." -LogOnly
                        return $note
                    }
                }
            }
        }
        catch {
            $reason = "stage=$stage errorId='$($_.FullyQualifiedErrorId)' exceptionType='$($_.Exception.GetType().FullName)' hresult=$($_.Exception.HResult) category='$($_.CategoryInfo.Category)'"
            # JSON parser messages can echo the Notes payload, including credentials.
            if ($stage -eq 'lookup') { $reason += " message='$($_.Exception.Message -replace '[\r\n]+', ' ')'" }
        }
        Write-Log "$VMName`: Maintenance metadata read failed: $details $reason." -Warning
        if ($attempt -eq 1) { Write-VMMaintenanceHostDiagnostics -VMName $VMName -ContextOnly }
        if ($attempt -lt 3) {
            $delay = 2 * $attempt
            Write-Log "$VMName`: Retrying maintenance metadata read in $delay seconds." -LogOnly
            Start-Sleep -Seconds $delay
        }
    }
    Write-Log "$VMName`: Maintenance metadata unavailable after 3 attempts; collecting host evidence. No fixes will be applied." -Warning
    Write-VMMaintenanceHostDiagnostics -VMName $VMName
    return $null
}

function Start-VMMaintenance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [object] $VMName,
        [Parameter(Mandatory = $false, HelpMessage = "Apply only fixes needed on fresh deploy")]
        [switch] $FreshDeployOnly
    )

    Write-Log "Starting maintenance for VM: $VMName"

    $vmNoteObject = Get-VMMaintenanceNote -VMName $VMName

    if (-not $vmNoteObject) {
        return $false
    }

    # Linux VMs (e.g. role=Proxy / osFamily=Linux) have no Windows-side
    # maintenance pipeline: no PSDirect, no C:\Staging, no Windows fixes.
    # Inline check (don't depend on Test-VmIsLinux load order).
    $isLinuxVm = $false
    if ($vmNoteObject.role -eq 'Proxy') { $isLinuxVm = $true }
    elseif ($vmNoteObject.PSObject.Properties.Name -contains 'osFamily' -and $vmNoteObject.osFamily -eq 'Linux') { $isLinuxVm = $true }
    elseif ($vmNoteObject.operatingSystem -and ($vmNoteObject.operatingSystem -like 'Ubuntu*' -or $vmNoteObject.operatingSystem -like 'Debian*' -or $vmNoteObject.operatingSystem -like 'Linux*')) { $isLinuxVm = $true }
    elseif ($vmNoteObject.deployedOS -and ($vmNoteObject.deployedOS -like 'Ubuntu*' -or $vmNoteObject.deployedOS -like 'Debian*' -or $vmNoteObject.deployedOS -like 'Linux*')) { $isLinuxVm = $true }

    if ($isLinuxVm) {
        Write-Log "$VMName`: Linux VM (role '$($vmNoteObject.role)'); Windows maintenance pipeline not applicable. Skipping." -Success
        return $true
    }

    # Offline Root CAs are intentionally powered off; skip if not running
    if ($vmNoteObject.role -eq "StandaloneRootCA") {
        $vmState = (Get-VM2 -Name $VMName -ErrorAction SilentlyContinue).State
        if ($vmState -ne "Running") {
            Write-Log "$VMName`: StandaloneRootCA is offline (expected). Skipping maintenance." -Success
            return $true
        }
    }

    $missingFields = @('role', 'domain' | Where-Object {
        $vmNoteObject.$_ -isnot [string] -or [string]::IsNullOrWhiteSpace($vmNoteObject.$_)
    })
    if ($missingFields.Count -gt 0) {
        Write-Log "$VMName`: Maintenance metadata missing or invalid required fields: $($missingFields -join ', '). No fixes will be applied." -Warning
        Write-VMMaintenanceHostDiagnostics -VMName $VMName
        return $false
    }

    $global:MaintenanceActivity = $VMName
    $inProgress = if ($vmNoteObject.inProgress) { $true } else { $false }

    # This should never happen, since parent filters these out. Leaving just-in-case.
    if ($inProgress) {
        Write-Log "$vmName`: VM Deployment State is in-progress. Skipping." -Warning
        return $false
    }

    if ($FreshDeployOnly.IsPresent) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "Performing maintenance on newly deployed VM..." -force
    }
    else {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "Performing maintenance..." -force
    }

    if ($FreshDeployOnly.IsPresent) {
        $vmFixes = Get-VMFixes -newVM $true -VMName $VMName -VMNote $vmNoteObject | Where-Object { $_.NeededOnFreshDeploy -eq $true }
    }
    else {
        $vmFixes = Get-VMFixes -newVM $false -VMName $VMName -VMNote $vmNoteObject | Where-Object { $_.AppliesToExisting -eq $true }
    }

    $worked = Start-VMFixes -VMName $VMName -VMFixes $vmFixes -VMNote $vmNoteObject -FreshDeployOnly:$FreshDeployOnly

    if ($worked) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "VM maintenance completed successfully." -force

        # If a user is logged in, start any AtLogOn scheduled tasks directly
        # so they run immediately instead of waiting for the next logon cycle.
        # This replaces the old approach of force-logging-off all users.
        $startLogonTasks = {
            $logonTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
                $_.State -ne 'Disabled' -and
                $_.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }
            }
            $started = @()
            foreach ($task in $logonTasks) {
                try {
                    $actions = $task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }
                    Start-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop
                    $started += "$($task.TaskName) [$($actions -join '; ')]"
                } catch {
                    $started += "$($task.TaskName) [FAILED: $($_.Exception.Message)]"
                }
            }
            return $started
        }
        try {
            if ($FreshDeployOnly.IsPresent) {
                $result = Invoke-VmCommand -VmName $VMName -VmDomainName $vmNoteObject.domain -ScriptBlock $startLogonTasks -DisplayName "Start logon tasks" -SuppressLog
                if ($result.ScriptBlockOutput) {
                    Write-Log "$VMName`: Started logon tasks: $($result.ScriptBlockOutput -join ', ')" -Verbose
                }
            }
        }
        catch {}
    }
    else {
        $domainLog = if ($vmNoteObject.domain) { "VMBuild.$($vmNoteObject.domain).log" } else { "VMBuild.log" }
        Write-Log "$VMName`: VM maintenance failed. Review $domainLog." -Failure
        Show-Notification -ToastText "$VMName`: VM maintenance failed. Review $domainLog." -ToastTag $VMName
    }

    return $worked
}

function Start-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [string] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMFixes")]
        [object] $VMFixes,
        [Parameter(Mandatory = $false)]
        [object] $VMNote,
        [Parameter(Mandatory = $false, HelpMessage = "SkipVMShutdown")]
        [switch] $SkipVMShutdown,
        [Parameter(Mandatory = $false, HelpMessage = "Apply only fixes needed on fresh deploy")]
        [switch] $FreshDeployOnly
    )

    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Applying fixes to the virtual machine." -force

    $success = $false
    $toStop = @()

    $rootPath = Split-Path $PSScriptRoot -Parent

    if (-not $vmNote) { $vmNote = Get-VMNote -VMName $vmName }
    $vmDomain = $vmNote.domain

    if (-not $vmDomain) {
        Write-log "No domain found in VMNote for $vmName.. assuming unmanaged. Return true" -LogOnly
        return $true
    }

    $HashArguments = @{
        VmName       = $vmName
        VMDomainName = $vmDomain
        DisplayName  = "Testing for Memlabs files"
        ScriptBlock  = { Test-Path "C:\Staging" }
    }

    $result = Invoke-VmCommand @HashArguments -ShowVMSessionError -CommandReturnsBool
    if ($result.ScriptBlockOutput -eq $false) {
        Write-Log "C:\Staging not found in vm $VMName.  Machine may no longer be managed by MemLabs.  Returning success." -Success
        return $true
    }

    # Copy DSC content into the VM so fix bodies and helper scripts are available.
    # Output is intentionally discarded; failures surface inside Copy-ItemSafe.
    $null = Copy-ItemSafe -VmName $vmName -VMDomainName $vmDomain -Path "$rootPath\DSC" -Destination "C:\staging" -Recurse -Container -Force

    # Determine if we can use the batched fast-path (no fixes have DependentVMs)
    $sortedFixes = $VMFixes | Sort-Object { ConvertTo-MemLabsVersion $_.FixVersion }
    $hasDependentVMs = $sortedFixes | Where-Object { $_.DependentVMs -and $_.DependentVMs.Count -gt 0 -and $_.AppliesToThisVM }

    if (-not $hasDependentVMs) {
        # Fast path: batch all fixes into a single remote call per session type
        $batchResult = Start-VMFixesBatched -VMName $VMName -VMDomain $vmDomain -VMFixes $sortedFixes -FreshDeployOnly:$FreshDeployOnly
        $success = $batchResult.Success
        $toStop = $batchResult.VMsToStop
        $fixesAppliedCount = $batchResult.AppliedCount
        $fixesApplicableCount = $batchResult.ApplicableCount
    }
    else {
        # Slow path: sequential per-fix execution (needed when fixes have dependent VMs)
        $fixesAppliedCount = 0
        $fixesApplicableCount = 0
        foreach ($vmFix in $sortedFixes) {
            if ($vmFix.AppliesToThisVM) { $fixesApplicableCount++ }
            $status = Start-VMFix -vmName $VMName -vmFix $vmFix -FreshDeployOnly:$FreshDeployOnly
            $toStop += $status.VMsToStop
            $success = $status.Success
            if ($status.Applied) { $fixesAppliedCount++ }
            if (-not $success) {
                break
            }
        }
    }

    # If deploying a new VM and fixes were applicable but none actually ran
    # their script block, something is wrong — do not stamp the version.
    # (If zero were applicable, e.g. OSDClient/AADClient, that's expected.)
    if ($FreshDeployOnly.IsPresent -and $fixesApplicableCount -gt 0 -and $fixesAppliedCount -eq 0 -and $success) {
        Write-Log "$VMName`: WARNING - $fixesApplicableCount maintenance fixes were applicable but none were applied. Version will NOT be stamped." -Warning
        $success = $false
    }

    if ($toStop.Count -ne 0 -and -not $SkipVMShutdown.IsPresent) {
        foreach ($vm in $toStop) {
            if ([string]::IsNullOrWhiteSpace($vm)) {
                continue
            }
            $vmNote = Get-VMNote -VMName $vm
            if ($vmNote.role -ne "DC") {
                Write-Progress2 -Activity $global:MaintenanceActivity -Status  "Shutting down VM "
                Stop-Vm2 -Name $vm -retryCount 5 -retrySeconds 3
            }
        }
    }

    return $success
}

function Start-VMFixesBatched {
    <#
    .SYNOPSIS
        Executes all applicable maintenance fixes in a single remote call per session type.
        Eliminates per-fix Invoke-VmCommand round-trip overhead (~2-4s each).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $VMName,
        [Parameter(Mandatory = $true)]
        [string] $VMDomain,
        [Parameter(Mandatory = $true)]
        [object[]] $VMFixes,
        [Parameter(Mandatory = $false)]
        [switch] $FreshDeployOnly
    )

    $return = [PSCustomObject]@{
        Success         = $false
        AppliedCount    = 0
        ApplicableCount = 0
        VMsToStop       = @()
    }

    $vmNote = Get-VMNote -VMName $VMName

    # Classify each fix and build a status table
    $applicableFixes = @()
    $naFixes = @()
    $statusLines = @()
    foreach ($vmFix in $VMFixes) {
        $applied = Test-VMFixApplied -VMNote $vmNote -FixName $vmFix.FixName -FixVersion $vmFix.FixVersion
        $isNA = -not $vmFix.AppliesToThisVM
        if ($applied) {
            $label = if ($isNA) { "N/A" } else { "Applied" }
            $statusLines += "  {0,-25} {1,-12} $label" -f $vmFix.FixName, $vmFix.FixVersion
            continue
        }
        if ($isNA) {
            $statusLines += "  {0,-25} {1,-12} N/A" -f $vmFix.FixName, $vmFix.FixVersion
            $naFixes += $vmFix
            continue
        }
        $statusLines += "  {0,-25} {1,-12} PENDING" -f $vmFix.FixName, $vmFix.FixVersion
        $return.ApplicableCount++
        $applicableFixes += $vmFix
    }
    Write-Log "$VMName`: Fix status ($($applicableFixes.Count) pending, $($VMFixes.Count) total):" -LogOnly
    foreach ($line in $statusLines) { Write-Log "$VMName`: $line" -LogOnly }

    # Batch-stamp all N/A fixes in one CIM write instead of per-fix Set-VMNote calls
    if ($naFixes.Count -gt 0) {
        $vmNote = Set-VMNoteFixBatch -VMName $VMName -Fixes $naFixes
    }
    foreach ($line in $statusLines) { Write-Log "$VMName`: $line" -LogOnly }

    if ($applicableFixes.Count -eq 0) {
        $return.Success = $true
        return $return
    }

    # Start the VM
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Starting $VMName for batched maintenance." -force
    $status = Start-VMIfNotRunning -VMName $VMName -VMDomain $VMDomain -WaitForConnect -Quiet
    if ($status.StartedVM) { $return.VMsToStop += $VMName }
    if ($status.StartFailed) { return $return }

    # Copy all InjectFiles upfront in one session
    $allInjectFiles = $applicableFixes | Where-Object { $_.InjectFiles } | ForEach-Object { $_.InjectFiles } | Select-Object -Unique
    $allInjectTools = $applicableFixes | Where-Object { $_.InjectTools } | ForEach-Object { $_.InjectTools } | Select-Object -Unique
    if ($allInjectFiles -or $allInjectTools) {
        try {
            $ps = Get-VmSession -VmName $VMName -VmDomainName $VMDomain

            # Probe with content hash for InjectFiles so an updated fix script
            # on the host overwrites a stale copy on the VM (filename-only
            # check would let yesterday's broken Fix-*.sql persist forever).
            # Tool folders stay existence-only — they're large bundles
            # (SSMS etc.) that we don't version per build.
            $expectedFileHashes = @{}
            foreach ($file in $allInjectFiles) {
                $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
                if (Test-Path -LiteralPath $sourcePath) {
                    try {
                        $expectedFileHashes["C:\staging\$file"] = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA1 -ErrorAction Stop).Hash
                    }
                    catch { }
                }
            }
            $toolProbe = @()
            foreach ($toolFolder in $allInjectTools) { $toolProbe += "C:\tools\$toolFolder" }

            $matchingFiles = @()
            $existingTools = @()
            if ($expectedFileHashes.Count -gt 0 -or $toolProbe.Count -gt 0) {
                $fileItems = @($expectedFileHashes.GetEnumerator() | ForEach-Object {
                        [pscustomobject]@{ Path = $_.Key; Hash = $_.Value }
                    })
                try {
                    $probe = Invoke-Command -Session $ps -ScriptBlock {
                        param($files, $tools)
                        $matched = foreach ($i in $files) {
                            if (Test-Path -LiteralPath $i.Path) {
                                try {
                                    $h = (Get-FileHash -LiteralPath $i.Path -Algorithm SHA1 -ErrorAction Stop).Hash
                                    if ($h -eq $i.Hash) { $i.Path }
                                }
                                catch { }
                            }
                        }
                        $existing = foreach ($t in $tools) {
                            if (Test-Path -LiteralPath $t) { $t }
                        }
                        [pscustomobject]@{ MatchingFiles = @($matched); ExistingTools = @($existing) }
                    } -ArgumentList $fileItems, $toolProbe -ErrorAction Stop
                    if ($probe) {
                        $matchingFiles = @($probe.MatchingFiles)
                        $existingTools = @($probe.ExistingTools)
                    }
                }
                catch {
                    Write-Log "$VMName`: Could not probe existing files/tools; will copy all. $_" -LogOnly
                }
            }

            foreach ($file in $allInjectFiles) {
                $targetPathInVM = "C:\staging\$file"
                if ($targetPathInVM -in $matchingFiles) {
                    Write-Log "$VMName`: $file already present (hash match), skipping copy." -LogOnly
                    continue
                }
                $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
                Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying $file to the VM..." -force
                Copy-Item -ToSession $ps -Path $sourcePath -Destination $targetPathInVM -Force -ErrorAction Stop
            }
            foreach ($toolFolder in $allInjectTools) {
                $targetPathInVM = "C:\tools\$toolFolder"
                if ($targetPathInVM -in $existingTools) {
                    Write-Log "$VMName`: Tool '$toolFolder' already present on VM, skipping copy." -LogOnly
                    continue
                }
                $sourcePath = Join-Path $Common.StagingInjectPath "tools\$toolFolder"
                if (Test-Path $sourcePath) {
                    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying tool '$toolFolder' to the VM..." -force
                    $copyResult = Copy-ItemSafe -VMName $VMName -VmDomainName $VMDomain -Path $sourcePath -Destination "C:\tools" -Recurse -Container -Force
                    if ($copyResult -eq $false) {
                        throw "Copy-ItemSafe failed copying tool '$toolFolder' to VM"
                    }
                }
            }
        }
        catch {
            Write-Log "$VMName`: Failed to copy InjectFiles/InjectTools for batched maintenance." -Warning
            return $return
        }
    }

    # Group fixes by RunAsAccount (null/default vs specific account)
    $groups = @{}
    foreach ($fix in $applicableFixes) {
        $key = if ($fix.RunAsAccount) { $fix.RunAsAccount } else { "__default__" }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
        $groups[$key] += $fix
    }

    # Build and execute a batched scriptblock for each session group
    # Process groups in version order of their first fix
    $sortedKeys = @($groups.Keys) | Sort-Object { ConvertTo-MemLabsVersion ($groups[$_] | Select-Object -First 1).FixVersion }
    $providerRecoveryAttempted = $false

    foreach ($key in $sortedKeys) {
        $groupFixes = $groups[$key]

        # Build fix definitions array for transport into the VM.
        # We wrap each fix body in the standard transcript + structured-return wrapper.
        $fixDefs = @()
        foreach ($fix in $groupFixes) {
            $wrapped = New-VMFixScriptBlock -FixName $fix.FixName -Body $fix.ScriptBlock
            $def = @{
                Name   = $fix.FixName
                Script = $wrapped.ToString()
            }
            if ($fix.ArgumentList) {
                $def.Args = $fix.ArgumentList
            }
            $fixDefs += $def
        }

        $fixDefsJson = $fixDefs | ConvertTo-Json -Depth 4 -Compress
        if ($fixDefs.Count -eq 1) {
            # ConvertTo-Json doesn't wrap single items in array
            $fixDefsJson = "[$fixDefsJson]"
        }

        # The batch runner: executes all wrapped fixes sequentially inside the VM,
        # collects their structured results, and returns them as JSON. Fail-fast on
        # the first failure (subsequent fixes assume prior ones succeeded) EXCEPT on
        # the final attempt, where $continueOnFailure runs the rest anyway: by then
        # the failure has already survived a retry, and abandoning the remaining
        # fixes leaves them unstamped and therefore blocked on every future pass too.
        $batchRunner = {
            param($json, $continueOnFailure)
            $fixDefs = $json | ConvertFrom-Json
            $results = @()
            foreach ($def in $fixDefs) {
                $markerPath = "C:\staging\Fix\$($def.Name).result.json"
                # Pre-clean the marker so a crash that never reaches the wrapper's
                # finally{} write leaves NO marker (= failure).
                if (Test-Path $markerPath) { Remove-Item $markerPath -Force -ErrorAction SilentlyContinue }

                $sb = [scriptblock]::Create($def.Script)
                $threw = $null
                try {
                    # Pipeline output is deliberately DISCARDED ($null = ...): the
                    # verdict comes from the marker file, not the return value.
                    if ($def.Args) {
                        $fixArgs = @($def.Args)
                        $null = & $sb @fixArgs
                    }
                    else {
                        $null = & $sb
                    }
                }
                catch {
                    # The wrapper normally catches its own exceptions and records them
                    # in the marker; this catches only catastrophic failures (e.g.
                    # wrapper compilation).
                    $threw = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
                }

                # AUTHORITATIVE: derive the result from the marker file the wrapper
                # wrote, NOT from the pipeline return value. Cmdlet output leaking
                # onto the success stream can turn the pipeline value into an array,
                # which then coerces to Success=$true ([bool]@(...) is true) -- exactly
                # how a fix that never created its scheduled task got stamped
                # 'applied'. An explicit marker is REQUIRED to call a fix successful.
                $rec = $null
                if (Test-Path $markerPath) {
                    try { $rec = Get-Content -Path $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $rec = $null }
                }
                if ($rec -and ($rec.PSObject.Properties.Name -contains 'IsStructured')) {
                    $results += $rec
                }
                else {
                    $results += [pscustomobject]@{
                        FixName       = $def.Name
                        Success       = $false
                        Message       = $null
                        Errors        = @()
                        ExceptionInfo = $(if ($threw) { $threw } else { "No result marker produced ($markerPath missing/unreadable); treating as failure (no explicit success)." })
                        ComputerName  = $env:COMPUTERNAME
                        DurationSec   = 0
                        IsStructured  = $true
                    }
                }
                if (-not $results[-1].Success -and -not $continueOnFailure) { break }
            }
            return ($results | ConvertTo-Json -Depth 4 -Compress)
        }

        # Get session for this group
        $sessionArgs = @{ VmName = $VMName; VmDomainName = $VMDomain; ShowVMSessionError = $true }
        if ($key -ne "__default__") {
            $sessionArgs.VmDomainAccount = $key
        }
        $ps = Get-VmSession @sessionArgs
        if (-not $ps) {
            # Fallback: try default session
            $ps = Get-VmSession -VmName $VMName -VmDomainName $VMDomain -ShowVMSessionError
        }
        if (-not $ps) {
            Write-Log "$VMName`: Failed to get session for batched fixes (account: $key)." -Warning
            return $return
        }

        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Executing $($groupFixes.Count) fixes in batch (account: $(if ($key -eq '__default__') {'default'} else {$key}))..." -force

        # Run the in-guest batch, then read each fix's authoritative result marker.
        # If any fix did not report explicit success, retry the WHOLE group once:
        # fixes are idempotent and the group is fail-fast, so a re-run re-attempts
        # the one that failed (and continues past it). Only the final $results is
        # processed/stamped below, so there is no double-stamping.
        $maxGroupAttempts = 2
        $groupAttempt = 0
        $groupRecoveryFailed = $false
        $results = @()
        while ($groupAttempt -lt $maxGroupAttempts) {
            $groupAttempt++
            $batchErr = $null
            # Last time round: run every fix even after one fails, so the rest get
            # applied and stamped instead of being abandoned indefinitely.
            $continueOnFailure = ($groupAttempt -ge $maxGroupAttempts)

            try {
                $timeouts = @($groupFixes | ForEach-Object { Get-VMFixExecutionTimeout -FixName $_.FixName })
                if (@($timeouts | Where-Object { $_ -gt 0 }).Count) {
                    $timeout = ($timeouts | ForEach-Object { if ($_ -gt 0) { $_ } else { 300 } } | Measure-Object -Sum).Sum
                    $commandArguments = @{
                        VmName = $VMName; VmDomainName = $VMDomain
                        ScriptBlock = $batchRunner; ArgumentList = @($fixDefsJson, $continueOnFailure)
                        DisplayName = "Maintenance batch (attempt $groupAttempt)"
                        AsJob = $true; TimeoutSeconds = [int]$timeout; FailOnRemoteError = $true
                    }
                    if ($key -ne '__default__') { $commandArguments.VmDomainAccount = $key }
                    $commandResult = Invoke-VmCommand @commandArguments
                    if (-not $commandResult -or $commandResult.ScriptBlockFailed) {
                        Write-Log "$VMName`: Maintenance batch failed or timed out: $(Protect-VMFixDiagnosticText $commandResult.ErrorDetails)" -Warning
                        $rawOutput = $null
                    }
                    else { $rawOutput = $commandResult.ScriptBlockOutput }
                }
                else {
                    $rawOutput = Invoke-Command -Session $ps -ScriptBlock $batchRunner -ArgumentList $fixDefsJson, $continueOnFailure -ErrorVariable batchErr -ErrorAction SilentlyContinue
                }
            }
            catch {
                Write-Log "$VMName`: Batched fix execution failed with exception (attempt $groupAttempt): $_" -Warning
                $rawOutput = $null
            }

            if ($batchErr -and $batchErr.Count -ne 0) {
                Write-Log "$VMName`: Batched fix execution had errors (attempt $groupAttempt): $($batchErr[0].ToString().Trim())" -Warning
            }

            if (-not $rawOutput) {
                Write-Log "$VMName`: Batched fix returned no output (attempt $groupAttempt)." -Warning
                $results = @()
            }
            else {
                try {
                    $results = $rawOutput | ConvertFrom-Json
                    if ($results -isnot [array]) { $results = @($results) }
                }
                catch {
                    Write-Log "$VMName`: Failed to parse batched fix results (attempt $groupAttempt): $_" -Warning
                    $results = @()
                }
            }

            $allOk = ($results.Count -ge $groupFixes.Count) -and (@($results | Where-Object { -not $_.Success }).Count -eq 0)
            $consoleFailed = @($results | Where-Object { $_.FixName -eq 'Fix-Upgrade-Console' -and -not $_.Success }).Count -gt 0
            if ($allOk -or (($groupAttempt -ge $maxGroupAttempts) -and (-not $consoleFailed -or $providerRecoveryAttempted))) { break }

            $failedNames = @($results | Where-Object { -not $_.Success } | ForEach-Object { $_.FixName }) -join ', '
            if (-not $failedNames) { $failedNames = '(no/partial results)' }
            $retryDelay = 5
            foreach ($failedFix in @($results | Where-Object { -not $_.Success })) {
                if ((Get-VMFixExecutionTimeout -FixName $failedFix.FixName) -gt 0) {
                    $retryDelay = 60
                    Get-VMFixTranscript -VMName $VMName -VMDomain $VMDomain -FixName $failedFix.FixName `
                        -VMDomainAccount $(if ($key -eq '__default__') { $null } else { $key }) `
                        -CollectDiagnostics -Stage "before-batch-retry-$groupAttempt"
                }
                if (-not $results.Count) {
                    foreach ($fix in $groupFixes) {
                        if ((Get-VMFixExecutionTimeout -FixName $fix.FixName) -gt 0) {
                            $retryDelay = 60
                            Save-VMFixFailureEvidence -VMName $VMName -VMDomain $VMDomain -FixName $fix.FixName `
                                -VMDomainAccount $(if ($key -eq '__default__') { $null } else { $key }) -Stage 'before-empty-batch-retry'
                        }
                    }
                }
            }
            if ($consoleFailed -and -not $providerRecoveryAttempted) {
                $recovery = Repair-VMConsoleProvider -VMName $VMName -VMDomain $VMDomain `
                    -VMDomainAccount $(if ($key -eq '__default__') { $null } else { $key })
                if ($recovery.Attempted) {
                    $providerRecoveryAttempted = $true
                    if (-not $recovery.Recovered) { $groupRecoveryFailed = $true; break }
                    $ps = Get-VmSession @sessionArgs
                    if (-not $ps) {
                        Write-Log "$VMName`: Could not reconnect the maintenance account after console provider recovery." -Warning
                        $groupRecoveryFailed = $true
                        break
                    }
                    # A fail-fast sibling can defer the console's first execution until the final ordinary attempt.
                    $maxGroupAttempts = [Math]::Max($maxGroupAttempts, $groupAttempt + 1)
                    $retryDelay = 0
                }
            }
            if ($groupAttempt -ge $maxGroupAttempts) { break }
            Write-Log "$VMName`: Fix(es) did not report explicit success on attempt $groupAttempt [$failedNames]; retrying batch once in $retryDelay seconds." -Warning
            Start-Sleep -Seconds $retryDelay
        }

        if (-not $results -or $results.Count -eq 0) {
            Write-Log "$VMName`: Batched fixes produced no usable results after $groupAttempt attempt(s)." -Warning
            foreach ($fix in $groupFixes) {
                Save-VMFixFailureEvidence -VMName $VMName -VMDomain $VMDomain -FixName $fix.FixName `
                    -VMDomainAccount $(if ($key -eq '__default__') { $null } else { $key }) -Stage 'missing-batch-results'
            }
            return $return
        }

        $accountForTranscript = if ($key -eq "__default__") { $null } else { $key }
        $groupApplied = @()
        $groupFailedNames = @()

        foreach ($r in $results) {
            $matchingFix = $groupFixes | Where-Object { $_.FixName -eq $r.Name -or $_.FixName -eq $r.FixName } | Select-Object -First 1
            $fixDisplayName = if ($matchingFix) { $matchingFix.FixName } else { $r.FixName }

            # Log structured fields
            if ($r.PSObject.Properties.Name -contains 'Message' -and $r.Message) {
                Write-Log "$VMName`: [$fixDisplayName] $(Protect-VMFixDiagnosticText $r.Message 12000)" -Warning:([bool]$r.PreservedNewer)
            }
            if ($r.PSObject.Properties.Name -contains 'Errors' -and $r.Errors -and $r.Errors.Count -gt 0) {
                foreach ($e in @($r.Errors)) { Write-Log "$VMName`: [$fixDisplayName] ERROR: $e" -Warning }
            }
            if ($r.PSObject.Properties.Name -contains 'ExceptionInfo' -and $r.ExceptionInfo) {
                Write-Log "$VMName`: [$fixDisplayName] EXCEPTION on VM: $($r.ExceptionInfo)" -Warning
            }
            if ($r.PSObject.Properties.Name -contains 'DurationSec') {
                Write-Log -LogOnly "$VMName`: [$fixDisplayName] Success=$($r.Success) DurationSec=$($r.DurationSec)"
                # Also as a marker: the line above carried this all along, but every
                # analyzer keys off [StepTiming] and so scored Phase 10 as uninstrumented.
                Write-Log -LogOnly "[StepTiming] $VMName Fix:$fixDisplayName completed in $($r.DurationSec) seconds (ok=$($r.Success) batched=True)"
            }

            # Always pull transcript (LogOnly) so failures + slow fixes are diagnosable
            if (-not $groupRecoveryFailed) {
                Get-VMFixTranscript -VMName $VMName -VMDomain $VMDomain -FixName $fixDisplayName -VMDomainAccount $accountForTranscript `
                    -CollectDiagnostics:(!$r.Success) -Stage "batch-result-$groupAttempt"
            }

            if ($r.Success) {
                Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixDisplayName' ($($matchingFix.FixVersion)) applied." -force
                $groupApplied += $matchingFix
                $return.AppliedCount++
            }
            else {
                Write-Log "$VMName`: Fix '$fixDisplayName' ($($matchingFix.FixVersion)) failed in batch." -Warning
                $groupFailedNames += $fixDisplayName
            }
        }

        # A short result set now means the batch really did crash: the final attempt
        # runs every fix, so it is no longer just fail-fast stopping early.
        if ($results.Count -lt $groupFixes.Count) {
            $failedFix = $groupFixes[$results.Count]
            if ($groupRecoveryFailed) {
                Write-Log "$VMName`: Console provider recovery failed; batch could not continue to fix '$($failedFix.FixName)'." -Warning
            }
            else {
                Write-Log "$VMName`: Batch stopped before fix '$($failedFix.FixName)'. Possible crash in scriptblock." -Warning
                Get-VMFixTranscript -VMName $VMName -VMDomain $VMDomain -FixName $failedFix.FixName -VMDomainAccount $accountForTranscript
            }
            $groupFailedNames += $failedFix.FixName
        }

        # Stamp every fix that succeeded even when a sibling failed. Leaving them
        # unstamped is what let one broken fix re-block the whole tail on every pass.
        if ($groupApplied.Count -gt 0) {
            $vmNote = Set-VMNoteFixBatch -VMName $VMName -Fixes $groupApplied
        }

        if ($groupFailedNames.Count -gt 0) {
            Write-Log "$VMName`: $($groupFailedNames.Count) fix(es) failed [$($groupFailedNames -join ', ')]; $($groupApplied.Count) applied and stamped. Only the failed fix(es) remain pending." -Warning
            return $return
        }
    }

    $return.Success = $true
    return $return
}

function Start-VMFix {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "vmName")]
        [string] $vmName,
        [Parameter(Mandatory = $true, HelpMessage = "vmFix")]
        [object] $vmFix,
        [Parameter(Mandatory = $false, HelpMessage = "Apply only fixes needed on fresh deploy")]
        [switch] $FreshDeployOnly
    )

    $return = [PSCustomObject]@{
        Success   = $false
        Applied   = $false
        VMsToStop = @()
    }


    # Get current VM note to ensure we don't have outdated version
    $vmNote = Get-VMNote -VMName $vmName
    $vmDomain = $vmNote.domain

    if (-not $vmDomain) {
        Write-Log "$vmName`: No domain found in VMNote (vmNote=$($null -ne $vmNote)); assuming unmanaged. Skipping fix '$($vmFix.FixName)'." -LogOnly -Warning
        $return.Success = $true
        return $return
    }

    # Check applicability
    $fixName = $vmFix.FixName
    $fixVersion = $vmFix.FixVersion
    write-log -LogOnly "Applying Fix $fixName $fixVersion to $vmName"
    if (Test-VMFixApplied -VMNote $vmNote -FixName $fixName -FixVersion $fixVersion) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) has been applied already."
        $return.Success = $true
        return $return
    }

    if (-not $vmFix.AppliesToThisVM) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) is not applicable."
        Set-VMNote -VMName $vmName -FixApplied $fixName -FixAppliedVersion $fixVersion
        $return.Success = $true
        return $return
    }

    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) is applicable. Applying fix now." -force

    # Start dependent VM's
    if ($vmFix.DependentVMs) {
        $dependentVMs = $vmFix.DependentVMs
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) requires '$($dependentVMs -join ',')' to be running."
        foreach ($vm in $dependentVMs) {
            if ([string]::IsNullOrWhiteSpace($vm)) { continue }
            $note = Get-VMNote -VMName $vm
            if (-not $note -or [string]::IsNullOrWhiteSpace($note.domain)) {
                Write-Log "$VMName`: Dependent VM '$vm' has no resolvable domain (note=$($null -ne $note)); skipping start." -LogOnly -Warning
                continue
            }
            $status = Start-VMIfNotRunning -VMName $vm -VMDomain $note.domain -WaitForConnect -Quiet
            if ($status.StartedVM) {
                $return.VMsToStop += $vm
            }

            if ($status.StartFailed) {
                return $return
            }
        }
    }
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Starting $VMName." -force
    # Start VM to apply fix
    $status = Start-VMIfNotRunning -VMName $VMName -VMDomain $vmDomain -WaitForConnect -Quiet
    if ($status.StartedVM) {
        $return.VMsToStop += $VMName
    }

    if ($status.StartFailed) {
        return $return
    }
    
    # Apply Fix
    $HashArguments = @{
        VmName       = $VMName
        VMDomainName = $vmDomain
        DisplayName  = $fixName
        ScriptBlock  = $vmFix.ScriptBlock
    }

    if ($vmFix.ArgumentList) {
        $HashArguments.Add("ArgumentList", $vmFix.ArgumentList)
    }

    if ($vmFix.RunAsAccount) {
        $HashArguments.Add("VmDomainAccount", $vmFix.RunAsAccount)
    }

    start-sleep -Milliseconds 200
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Connecting to $VMName" -force
    if ($vmFix.InjectFiles -or $vmFix.InjectTools) {
        try {
            $ps = Get-VmSession -VmName $VMName -VmDomainName $vmDomain

            # Probe with content hash for InjectFiles so an updated fix script
            # on the host overwrites a stale copy on the VM (filename-only
            # check would let yesterday's broken Fix-*.sql persist forever).
            # Tool folders stay existence-only — they're large bundles
            # (SSMS etc.) that we don't version per build.
            $expectedFileHashes = @{}
            foreach ($file in $vmFix.InjectFiles) {
                $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
                if (Test-Path -LiteralPath $sourcePath) {
                    try {
                        $expectedFileHashes["C:\staging\$file"] = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA1 -ErrorAction Stop).Hash
                    }
                    catch { }
                }
            }
            $toolProbe = @()
            foreach ($toolFolder in $vmFix.InjectTools) { $toolProbe += "C:\tools\$toolFolder" }

            $matchingFiles = @()
            $existingTools = @()
            if ($expectedFileHashes.Count -gt 0 -or $toolProbe.Count -gt 0) {
                $fileItems = @($expectedFileHashes.GetEnumerator() | ForEach-Object {
                        [pscustomobject]@{ Path = $_.Key; Hash = $_.Value }
                    })
                try {
                    $probe = Invoke-Command -Session $ps -ScriptBlock {
                        param($files, $tools)
                        $matched = foreach ($i in $files) {
                            if (Test-Path -LiteralPath $i.Path) {
                                try {
                                    $h = (Get-FileHash -LiteralPath $i.Path -Algorithm SHA1 -ErrorAction Stop).Hash
                                    if ($h -eq $i.Hash) { $i.Path }
                                }
                                catch { }
                            }
                        }
                        $existing = foreach ($t in $tools) {
                            if (Test-Path -LiteralPath $t) { $t }
                        }
                        [pscustomobject]@{ MatchingFiles = @($matched); ExistingTools = @($existing) }
                    } -ArgumentList $fileItems, $toolProbe -ErrorAction Stop
                    if ($probe) {
                        $matchingFiles = @($probe.MatchingFiles)
                        $existingTools = @($probe.ExistingTools)
                    }
                }
                catch {
                    Write-Log "$VMName`: Could not probe existing files/tools; will copy all. $_" -LogOnly
                }
            }

            foreach ($file in $vmFix.InjectFiles) {
                $targetPathInVM = "C:\staging\$file"
                if ($targetPathInVM -in $matchingFiles) {
                    Write-Log "$VMName`: $file already present (hash match), skipping copy." -LogOnly
                    continue
                }
                $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
                Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying $file to the VM [$targetPathInVM]..." -force
                Copy-Item -ToSession $ps -Path $sourcePath -Destination $targetPathInVM -Force -ErrorAction Stop
            }
            foreach ($toolFolder in $vmFix.InjectTools) {
                $targetPathInVM = "C:\tools\$toolFolder"
                if ($targetPathInVM -in $existingTools) {
                    Write-Log "$VMName`: Tool '$toolFolder' already present on VM, skipping copy." -LogOnly
                    continue
                }
                $sourcePath = Join-Path $Common.StagingInjectPath "tools\$toolFolder"
                if (Test-Path $sourcePath) {
                    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying tool '$toolFolder' to the VM..." -force
                    $copyResult = Copy-ItemSafe -VMName $VMName -VmDomainName $vmDomain -Path $sourcePath -Destination "C:\tools" -Recurse -Container -Force
                    if ($copyResult -eq $false) {
                        throw "Copy-ItemSafe failed copying tool '$toolFolder' to VM"
                    }
                }
            }
        }
        catch {
            Write-Log "$VMName`: Failed to copy files for fix '$fixName' ($fixVersion)." -Warning
            $return.Success = $false
            return $return
        }
    }

    start-sleep -Milliseconds 200
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Starting ScriptBlock on $VMName" -force

    # Wrap the fix body so we get a structured return + transcript on the VM
    $HashArguments.ScriptBlock = New-VMFixScriptBlock -FixName $fixName -Body $vmFix.ScriptBlock
    $executionTimeout = Get-VMFixExecutionTimeout -FixName $fixName
    if ($executionTimeout -gt 0) {
        $HashArguments.AsJob = $true
        $HashArguments.TimeoutSeconds = $executionTimeout
        $HashArguments.FailOnRemoteError = $true
    }

    # Output is a structured PSCustomObject, but the AUTHORITATIVE success signal
    # is the marker file the wrapper writes (read below in a separate call), not
    # the pipeline return value -- cmdlet output leaking onto the success stream
    # can't be allowed to mask the real result. A fix is stamped 'applied' ONLY on
    # an explicit success marker, and a non-success result is retried once.
    $fixSucceeded = $false
    $rawOut = $null
    $isStructured = $false
    $maxFixAttempts = 2
    $providerRecoveryAttempted = $false
    for ($fixAttempt = 1; $fixAttempt -le $maxFixAttempts; $fixAttempt++) {
        $result = Invoke-VmCommand @HashArguments -ShowVMSessionError

        # Authoritative: read the marker file in a SEPARATE transaction.
        $marker = Get-VMFixResultMarker -VMName $VMName -VMDomain $vmDomain -FixName $fixName -VMDomainAccount $vmFix.RunAsAccount
        if ($marker -and ($marker.PSObject.Properties.Name -contains 'IsStructured')) {
            $rawOut = $marker
            $isStructured = $true
        }
        else {
            $rawOut = $null
            $isStructured = $false
        }

        if ($result.ScriptBlockFailed) {
            # Transport/session failure - body never ran (or failed catastrophically).
            $fixSucceeded = $false
        }
        elseif ($isStructured) {
            $fixSucceeded = [bool]$rawOut.Success
            if ($rawOut.Message) {
                Write-Log "$VMName`: [$fixName] $(Protect-VMFixDiagnosticText $rawOut.Message 12000)" -Warning:([bool]$rawOut.PreservedNewer)
            }
            if ($rawOut.Errors -and $rawOut.Errors.Count -gt 0) {
                foreach ($e in $rawOut.Errors) {
                    Write-Log "$VMName`: [$fixName] ERROR: $e" -Warning
                }
            }
            if ($rawOut.ExceptionInfo) {
                Write-Log "$VMName`: [$fixName] EXCEPTION on VM: $($rawOut.ExceptionInfo)" -Warning
            }
            Write-Log -LogOnly "$VMName`: [$fixName] Success=$($rawOut.Success) DurationSec=$($rawOut.DurationSec)"
            Write-Log -LogOnly "[StepTiming] $VMName Fix:$fixName completed in $($rawOut.DurationSec) seconds (ok=$($rawOut.Success) batched=False)"
        }
        else {
            # No explicit success marker -> NOT applied (legacy bool no longer trusted).
            $fixSucceeded = $false
            Write-Log "$VMName`: [$fixName] produced no explicit success marker (attempt $fixAttempt)." -Warning
        }

        # Always pull the on-VM transcript for this attempt (LogOnly).
        Get-VMFixTranscript -VMName $VMName -VMDomain $vmDomain -FixName $fixName -VMDomainAccount $vmFix.RunAsAccount `
            -CollectDiagnostics:(!$fixSucceeded) -Stage "attempt-$fixAttempt"

        if ($fixSucceeded) { break }
        $retryDelay = if ($executionTimeout -gt 0) { 60 } else { 5 }
        if ($fixName -eq 'Fix-Upgrade-Console' -and -not $providerRecoveryAttempted) {
            $recovery = Repair-VMConsoleProvider -VMName $VMName -VMDomain $vmDomain -VMDomainAccount $vmFix.RunAsAccount
            if ($recovery.Attempted) {
                $providerRecoveryAttempted = $true
                if (-not $recovery.Recovered) { break }
                $maxFixAttempts = [Math]::Max($maxFixAttempts, $fixAttempt + 1)
                $retryDelay = 0
            }
        }
        if ($fixAttempt -ge $maxFixAttempts) { break }
        Write-Log "$VMName`: Fix '$fixName' ($fixVersion) did not report success on attempt $fixAttempt; retrying once in $retryDelay seconds." -Warning
        Start-Sleep -Seconds $retryDelay
    }

    if (-not $fixSucceeded) {
        Write-Log "$VMName`: Fix '$fixName' ($fixVersion) failed to be applied." -Warning
        Write-Log "ScriptBlockFailed: $($result.ScriptBlockFailed) Output: $(if ($isStructured) { 'Success=' + $rawOut.Success } else { $rawOut })"
        Write-Log -LogOnly "ScriptBlock: $($vmFix.ScriptBlock)"
        $return.Success = $false
    }
    else {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) applied." -force
        Set-VMNote -vmName $VMName -FixApplied $fixName -FixAppliedVersion $fixVersion
        $return.Success = $true
        $return.Applied = $true
    }

    return $return
}

function Get-VMConsoleProviderHealthScriptBlock {
    $sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'DSC\phases\Upgrade-Console.ps1'
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Console provider probe source does not parse: $($parseErrors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ConsoleSetupInfo'
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one Get-ConsoleSetupInfo definition in $sourcePath" }

    $probe = {
        $identification = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -ErrorAction Stop
        $siteCode = "$($identification.'Site Code')"
        if (-not $siteCode) { throw 'Console provider probe found no installed Site Code.' }
        $setup = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction Stop
        $directory = "$($setup.'Installation Directory')"
        if (-not $directory) { throw 'Console provider probe found no site installation directory.' }
        $providerLog = Join-Path $directory 'Logs\SMSProv.log'
        $state = [pscustomobject]@{
            Ready = $false; ShutdownDetected = $false; Error = ''; Evidence = ''; Diagnostics = @()
        }
        $previousLines = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $canCompareLog = $true
        try {
            if (Test-Path -LiteralPath $providerLog -PathType Leaf -ErrorAction Stop) {
                foreach ($line in @(Get-Content -LiteralPath $providerLog -Tail 120 -ErrorAction Stop)) {
                    [void]$previousLines.Add("$line")
                }
            }
        }
        catch {
            $canCompareLog = $false
            $state.Diagnostics += "Could not snapshot ${providerLog}: $($_.Exception.Message)"
        }
        try {
            $info = Get-ConsoleSetupInfo -SiteCode $siteCode
            [version]$version = $null
            if (-not [version]::TryParse("$($info.FileVersion)".Trim(), [ref]$version) -or $version.Build -le 0) {
                throw 'SMS_ConsoleSetupInfo returned no valid console extension version.'
            }
            $state.Ready = $true
        }
        catch {
            $failure = $_
            $state.Error = $failure.Exception.Message
            $pattern = '(?i)\b(0x80041033|WBEM_E_SHUTTING_DOWN)\b'
            $state.ShutdownDetected = $failure.FullyQualifiedErrorId -match $pattern -or
                "$($failure.ErrorDetails)" -match $pattern
            $exception = $failure.Exception
            while ($exception) {
                if ($exception.HResult -eq -2147217357 -or $exception.Message -match $pattern) {
                    $state.ShutdownDetected = $true
                }
                $exception = $exception.InnerException
            }
            if ($state.ShutdownDetected) {
                $state.Evidence = 'SMS_ConsoleSetupInfo query returned WBEM_E_SHUTTING_DOWN (0x80041033).'
            }
            elseif ($canCompareLog) {
                try {
                    # CIM can expose only E_FAIL; require a new, class-specific provider-log error.
                    $newErrors = @(Get-Content -LiteralPath $providerLog -Tail 120 -ErrorAction Stop |
                        Where-Object {
                            -not $previousLines.Contains("$_") -and
                            $_ -match '(?i)\bSMS_ConsoleSetupInfo\b.*\b0x80041033\b'
                        })
                    if ($newErrors.Count) {
                        $state.ShutdownDetected = $true
                        $state.Evidence = "$($newErrors[-1])"
                    }
                }
                catch {
                    $state.Diagnostics += "Could not inspect fresh ${providerLog} evidence: $($_.Exception.Message)"
                }
            }
        }
        return $state
    }
    return [scriptblock]::Create("$($definitions[0].Extent.Text)`n$probe")
}

function Repair-VMConsoleProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$VMDomain,
        [string]$VMDomainAccount,
        [ValidateRange(1, 600)][int]$ReadyTimeoutSeconds = 300
    )

    $recovery = [pscustomobject]@{ Attempted = $false; Recovered = $false }
    try { $probeBlock = Get-VMConsoleProviderHealthScriptBlock }
    catch {
        Write-Log "$VMName`: Cannot prepare console provider recovery probe: $($_.Exception.Message)" -Warning
        return $recovery
    }
    $probeArguments = @{
        VmName = $VMName; VmDomainName = $VMDomain; ScriptBlock = $probeBlock
        DisplayName = 'Probe console SMS Provider'; AsJob = $true; TimeoutSeconds = 45
        SessionMaxRetries = 1; SuppressLog = $true; FailOnRemoteError = $true
    }
    if ($VMDomainAccount) { $probeArguments.VmDomainAccount = $VMDomainAccount }
    $readyWatch = $null
    $lastError = ''
    while ($true) {
        if ($readyWatch) {
            $remaining = $ReadyTimeoutSeconds - $readyWatch.Elapsed.TotalSeconds
            if ($remaining -le 0) { break }
            $probeArguments.TimeoutSeconds = [int][Math]::Min(45, [Math]::Ceiling($remaining))
        }
        $probe = Invoke-VmCommand @probeArguments
        $states = @($probe.ScriptBlockOutput)
        $state = $null
        if (-not $probe -or $probe.ScriptBlockFailed) {
            $lastError = "Console provider probe failed: $($probe.ErrorDetails -join '; ')"
        }
        elseif ($states.Count -ne 1 -or $states[0].Ready -isnot [bool] -or
            $states[0].ShutdownDetected -isnot [bool] -or ($states[0].Ready -and $states[0].ShutdownDetected) -or
            (-not $states[0].Ready -and [string]::IsNullOrWhiteSpace("$($states[0].Error)")) -or
            ($states[0].ShutdownDetected -and [string]::IsNullOrWhiteSpace("$($states[0].Evidence)"))) {
            $lastError = 'Console provider probe returned an invalid health result.'
            Write-Log "$VMName`: Console provider probe returned an invalid health result; refusing further recovery." -Warning
            break
        }
        else {
            $state = $states[0]
            foreach ($diagnostic in @($state.Diagnostics)) {
                Write-Log "$VMName`: $(Protect-VMFixDiagnosticText $diagnostic)" -Warning -LogOnly
            }
            if ($state.Ready) {
                if ($recovery.Attempted) {
                    $recovery.Recovered = $true
                    Write-Log "$VMName`: Console provider recovered after one graceful reboot; SMS_ConsoleSetupInfo returned a valid extension version. Retrying the console fix." -Success
                }
                return $recovery
            }
            $lastError = "$($state.Error)"
        }
        if (-not $recovery.Attempted) {
            if (-not $state -or -not $state.ShutdownDetected) {
                Write-Log "$VMName`: Console provider shutdown was not confirmed; retaining the normal maintenance retry. $(Protect-VMFixDiagnosticText $lastError)" -Warning
                return $recovery
            }
            $recovery.Attempted = $true
            Write-Log "$VMName`: Confirmed console provider shutdown: $(Protect-VMFixDiagnosticText $state.Evidence). Requesting the single permitted graceful reboot; hard power-off is prohibited." -Warning
            Save-VMFixFailureEvidence -VMName $VMName -VMDomain $VMDomain -FixName 'Fix-Upgrade-Console' `
                -VMDomainAccount $VMDomainAccount -Stage 'provider-recovery-before-reboot'
            $restartWatch = [Diagnostics.Stopwatch]::StartNew()
            $restartBudget = [TimeSpan]::FromSeconds(180 + $ReadyTimeoutSeconds)
            try {
                $restarted = Restart-VM2Smart -Name $VMName -Reason 'Console provider WBEM_E_SHUTTING_DOWN recovery' `
                    -GracefulTimeoutSeconds 180 -ShutdownNoProgressSeconds 300 -Stopwatch $restartWatch -Timespan $restartBudget
            }
            catch {
                Write-Log "$VMName`: Console provider graceful recovery restart failed: $(Protect-VMFixDiagnosticText $_.Exception.Message). No hard power-off or second reboot will be attempted." -Warning
                return $recovery
            }
            if (-not $restarted) {
                Write-Log "$VMName`: Console provider recovery could not gracefully restart the VM; no hard power-off or second reboot will be attempted." -Warning
                return $recovery
            }
            $readyWatch = [Diagnostics.Stopwatch]::StartNew()
            continue
        }
        Write-Log "$VMName`: Waiting for console provider readiness after reboot: $(Protect-VMFixDiagnosticText $lastError)" -LogOnly
        $delay = [int][Math]::Min(5, [Math]::Ceiling($ReadyTimeoutSeconds - $readyWatch.Elapsed.TotalSeconds))
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
    }
    if ($recovery.Attempted) {
        Write-Log "$VMName`: Console provider recovery failed after one reboot (readiness budget ${ReadyTimeoutSeconds}s); no further reboot will be attempted. $(Protect-VMFixDiagnosticText $lastError)" -Warning
        Save-VMFixFailureEvidence -VMName $VMName -VMDomain $VMDomain -FixName 'Fix-Upgrade-Console' `
            -VMDomainAccount $VMDomainAccount -Stage 'provider-recovery-failed'
    }
    return $recovery
}

function Start-VMIfNotRunning {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VM Domain")]
        [string] $VMDomain,
        [Parameter(Mandatory = $false, HelpMessage = "Wait for VM to be connectable")]
        [switch] $WaitForConnect,
        [Parameter(Mandatory = $false, HelpMessage = "Quiet - No logging when VM is already running")]
        [switch] $Quiet
    )

    $return = [PSCustomObject]@{
        StartedVM     = $false
        StartFailed   = $false
        ConnectFailed = $false
    }


    $vm = Get-VM2 -Name $VMName -ErrorAction SilentlyContinue

    Write-Log -verbose "Starting $vmName if not running"

    if (-not $vm) {
        Write-Log "$VMName`: Failed to get VM from Hyper-V. Error: $_" -Warning
        $return.StartFailed = $true
        $return.ConnectFailed = $true
        return $return
    }

    if ($vm.State -ne "Running") {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Starting VM for maintenance and waiting for it to be ready to connect." -force
        $started = Start-VM2 -Name $VMName -Passthru
        if ($started) {
            $return.StartedVM = $true
            if ($WaitForConnect.IsPresent) {
                Write-Log -verbose "Waiting to connect to $vmName"
                $connected = Wait-ForVM -VmName $VMname -PathToVerify "C:\Users" -VmDomainName $VMDomain -TimeoutMinutes 2 -Quiet
                if (-not $connected) {
                    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Could not connect to the VM after waiting for 2 minutes."
                    $return.ConnectFailed = $true
                }
            }
        }
        else {
            $return.StartFailed = $true
            $return.ConnectFailed = $true
        }
    }
    else {
        if (-not $Quiet.IsPresent) { Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "VM is already running." }
    }
    Write-Log -verbose "Starting $vmName Completed. $return"
    return $return
}

function Protect-VMFixDiagnosticText {
    param([AllowNull()][string]$Text, [int]$MaximumLength = 2000)

    $safe = "$Text" -replace '(?i)(-Token\s+)(?:"[^"]*"|\S+)', '$1[REDACTED]'
    $safe = $safe -replace '(?i)([?&](?:sig|token|password|secret|access_token)=)[^&\s"]+', '$1[REDACTED]'
    $safe = $safe -replace '(?i)(\b(?:password|pwd|access_token|client_secret)\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^;\s,]+)', '$1[REDACTED]'
    $safe = $safe -replace '([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s]+@', '$1[REDACTED]@'
    if ($safe.Length -gt $MaximumLength) { return $safe.Substring(0, $MaximumLength) + ' [truncated]' }
    return $safe
}

function Get-VMFixExecutionTimeout {
    param([string]$FixName)
    switch ($FixName) {
        'Fix-ODBC18' { return 1800 }
        'Fix-EdgeServicing' { return 1200 }
        'Fix-Upgrade-Console' { return 3600 }
        'Fix-CMFullAdmin' { return 600 }
        default { return 0 }
    }
}

function Get-VMFixDiagnosticScriptBlock {
    $redactor = ${function:Protect-VMFixDiagnosticText}.ToString()
    $collector = {
        $ErrorActionPreference = 'Stop'
        $errors = [System.Collections.Generic.List[string]]::new()
        function Read-DiagnosticRegistry {
            param([string]$Path, [string[]]$Names)
            $values = [ordered]@{}
            try {
                if (-not (Test-Path -LiteralPath $Path)) {
                    return [pscustomobject]@{ Path = $Path; Exists = $false; Values = $values }
                }
                $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
                foreach ($name in $Names) {
                    if ($item.PSObject.Properties[$name]) {
                        $values[$name] = Protect-VMFixDiagnosticText -Text "$($item.$name)" -MaximumLength 500
                    }
                }
            }
            catch { $errors.Add("Registry $Path`: $($_.Exception.Message)") }
            [pscustomobject]@{ Path = $Path; Exists = $true; Values = $values }
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $snapshot = [ordered]@{
            SchemaVersion = 1
            CapturedUtc = [datetime]::UtcNow.ToString('o')
            FixName = $FixName
            Stage = $Stage
            ComputerName = $env:COMPUTERNAME
            Identity = $identity.Name
            Elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            UserDomain = $env:USERDOMAIN
            UserDnsDomain = $env:USERDNSDOMAIN
            PowerShellVersion = "$($PSVersionTable.PSVersion)"
            Is64BitProcess = [Environment]::Is64BitProcess
            TempPath = [IO.Path]::GetTempPath()
            FreeDisk = @()
            Services = @()
            Processes = @()
            Registry = @()
            OdbcProducts = @()
            Modules = @()
            InstallerEvents = @()
            Logs = @()
        }
        try {
            $snapshot.FreeDisk = @(Get-PSDrive -PSProvider FileSystem | Select-Object -First 8 Name, Free, Used)
            $snapshot.Services = @(Get-Service | Where-Object {
                    $_.Name -in @('msiserver', 'Winmgmt', 'SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER', 'MSSQLSERVER') -or
                    $_.Name -like 'MSSQL$*'
                } | Select-Object -First 15 Name, @{ Name = 'Status'; Expression = { "$($_.Status)" } })
            $snapshot.Processes = @(Get-Process | Where-Object {
                    $_.ProcessName -in @('msiexec', 'ConsoleSetup', 'mmc', 'SMS_EXECUTIVE')
                } | Select-Object -First 20 Id, ProcessName, CPU)
            $snapshot.Modules = @(Get-Module -ListAvailable TemplateHelpDSC, ConfigurationManager |
                Select-Object -First 5 Name, @{ Name = 'Version'; Expression = { "$($_.Version)" } }, Path)
        }
        catch { $errors.Add("Host state: $($_.Exception.Message)") }
        foreach ($root in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
            foreach ($major in @(17, 18)) {
                $snapshot.Registry += Read-DiagnosticRegistry "$root\Microsoft\MSODBCSQL$major" @('InstalledVersion')
                $driver = Read-DiagnosticRegistry "$root\ODBC\ODBCINST.INI\ODBC Driver $major for SQL Server" @('Driver', 'Setup', 'Version')
                $snapshot.Registry += $driver
                if ($driver.Values.Driver) {
                    try {
                        $file = Get-Item -LiteralPath $driver.Values.Driver -ErrorAction Stop
                        $snapshot.Registry += [pscustomobject]@{
                            Path = $file.FullName; Exists = $true
                            Values = @{ FileVersion = "$($file.VersionInfo.FileVersion)"; Bytes = $file.Length }
                        }
                    }
                    catch { $errors.Add("Driver DLL $($driver.Values.Driver): $($_.Exception.Message)") }
                }
            }
        }
        $snapshot.Registry += Read-DiagnosticRegistry 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' @('Site Code', 'Site Name', 'Version')
        $siteSetup = Read-DiagnosticRegistry 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' @('Installation Directory', 'UI Installation Directory', 'Version', 'Full Version')
        $snapshot.Registry += $siteSetup
        $snapshot.Registry += Read-DiagnosticRegistry 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\Setup' @('UI Installation Directory', 'AdminConsoleVersion', 'RequiredExtensionVersion')
        $snapshot.Registry += Read-DiagnosticRegistry 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64' @('Installed', 'Major', 'Minor', 'Bld', 'Version')
        $snapshot.Registry += Read-DiagnosticRegistry 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' @('PendingFileRenameOperations')
        try {
            $configPath = 'C:\staging\DSC\deployConfig.json'
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $configuredMachine = "$($config.Parameters.ThisMachineName)"
                $matches = @($config.virtualMachines | Where-Object { $_.vmName -ieq $configuredMachine -or $_.vmName -ieq $env:COMPUTERNAME })
                $snapshot.Config = [ordered]@{
                    Sha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
                    ConfiguredMachine = $configuredMachine
                    GlobalVersion = "$($config.cmOptions.Version)"
                    LocalEntries = @($matches | Select-Object -First 3 | ForEach-Object {
                            [pscustomobject]@{
                                VmName = $_.vmName; Role = $_.role; SiteCode = $_.siteCode
                                ParentSiteCode = $_.parentSiteCode; Version = "$($_.cmOptions.Version)"
                                MediaBaseline = "$($_.thisParams.cmDownloadVersion.baselineVersion)"
                                MediaVersions = @($_.thisParams.cmDownloadVersion.versions | Select-Object -First 10)
                            }
                        })
                }
            }
            else { $errors.Add("Deployment metadata missing: $configPath") }
        }
        catch { $errors.Add("Deployment metadata: $($_.Exception.Message)") }
        $installer = $null
        $related = $null
        try {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $related = $installer.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @('{ADA68B65-BFF8-4E6A-B082-CC6682D425B8}'))
            $productCount = 0
            foreach ($code in $related) {
                if ($productCount++ -ge 16) { $errors.Add('ODBC product inventory limited to 16 entries'); break }
                $entry = [ordered]@{ ProductCode = "$code" }
                foreach ($property in @('ProductState', 'FeatureState', 'PackageCode', 'PackageName', 'Language', 'Version', 'LocalPackage')) {
                    try {
                        $entry[$property] = switch ($property) {
                            'ProductState' { $installer.GetType().InvokeMember('ProductState', 'GetProperty', $null, $installer, @($code)) }
                            'FeatureState' { $installer.GetType().InvokeMember('FeatureState', 'GetProperty', $null, $installer, @($code, 'SQL_SQLODBC_CORE')) }
                            default { $installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, $property)) }
                        }
                    }
                    catch { $entry["${property}Error"] = Protect-VMFixDiagnosticText $_.Exception.Message 300 }
                }
                if ($entry.LocalPackage) { $entry.CacheExists = Test-Path -LiteralPath "$($entry.LocalPackage)" -PathType Leaf }
                $snapshot.OdbcProducts += [pscustomobject]$entry
            }
        }
        catch { $errors.Add("Windows Installer inventory: $($_.Exception.Message)") }
        finally {
            foreach ($item in @($related, $installer)) {
                if ($item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item)
                }
            }
        }
        try {
            $snapshot.InstallerEvents = @(Get-WinEvent -FilterHashtable @{
                    LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = (Get-Date).AddMinutes(-30)
                } -MaxEvents 10 -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{ TimeCreated = "$($_.TimeCreated)"; Id = $_.Id; Message = Protect-VMFixDiagnosticText $_.Message 800 }
                })
        }
        catch {
            if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
                $errors.Add("Installer events: $($_.Exception.Message)")
            }
        }
        $paths = [System.Collections.Generic.List[string]]::new()
        $fixedLogs = @("C:\staging\Fix\$FixName.result.json", 'C:\staging\DSC\DSC_Log.log')
        if ($FixName -ne 'Fix-ODBC18') { $fixedLogs += @('C:\ConfigMgrAdminUISetup.log', 'C:\ConfigMgrAdminUISetupVerbose.log') }
        foreach ($path in $fixedLogs) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { $paths.Add($path) }
        }
        $tempPaths = @([IO.Path]::GetTempPath(), 'C:\Windows\Temp')
        $tempPaths += @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -Filter 'vmbuildadmin*' -ErrorAction SilentlyContinue |
            Select-Object -First 4 | ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' })
        $msiLogs = @(foreach ($tempPath in @($tempPaths | Select-Object -Unique)) {
                if (Test-Path -LiteralPath $tempPath) {
                    Get-ChildItem -LiteralPath $tempPath -File -Filter 'memlabs-msodbcsql-*.log' -ErrorAction SilentlyContinue
                }
            })
        if ($FixName -eq 'Fix-ODBC18') {
            foreach ($file in @($msiLogs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 7)) { $paths.Add($file.FullName) }
        }
        $installDirectory = $siteSetup.Values.'Installation Directory'
        if ($installDirectory -and $FixName -ne 'Fix-ODBC18') {
            foreach ($name in @('SMSProv.log', 'hman.log', 'sitecomp.log')) {
                $path = Join-Path $installDirectory "Logs\$name"
                if (Test-Path -LiteralPath $path -PathType Leaf) { $paths.Add($path) }
            }
        }
        foreach ($path in @($paths | Select-Object -Unique | Select-Object -First 10)) {
            try {
                $file = Get-Item -LiteralPath $path -ErrorAction Stop
                $lines = @(Get-Content -LiteralPath $path -Tail 60 -ErrorAction Stop |
                    ForEach-Object { Protect-VMFixDiagnosticText -Text "$_" -MaximumLength 500 })
                $snapshot.Logs += [pscustomobject]@{
                    Path = $file.FullName; Bytes = $file.Length; LastWriteTimeUtc = "$($file.LastWriteTimeUtc)"
                    Tail = $lines; TailLimit = 60
                }
            }
            catch { $errors.Add("Log $path`: $($_.Exception.Message)") }
        }
        $snapshot.CollectionErrors = @($errors | Select-Object -First 30 |
            ForEach-Object { Protect-VMFixDiagnosticText $_ 600 })
        $json = $snapshot | ConvertTo-Json -Depth 9 -Compress
        if ($json.Length -gt 512KB) {
            foreach ($log in $snapshot.Logs) {
                $log.Tail = @($log.Tail | Select-Object -Last 10 | ForEach-Object { Protect-VMFixDiagnosticText $_ 200 })
                $log.TailLimit = 10
            }
            $snapshot.TransferTruncated = $true
            $snapshot.CollectionErrors += 'Log tails reduced to fit the 512 KB transfer limit.'
            $json = $snapshot | ConvertTo-Json -Depth 9 -Compress
            if ($json.Length -gt 512KB) { throw 'Maintenance diagnostic context exceeded the 512 KB transfer limit.' }
        }
        return $json
    }
    return [scriptblock]::Create("param([string]`$FixName, [string]`$Stage)`nfunction Protect-VMFixDiagnosticText {`n$redactor`n}`n$($collector.ToString())")
}

function Save-VMFixFailureEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$VMDomain,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,80}$')][string]$FixName,
        [string]$VMDomainAccount,
        [string]$Stage = 'failure'
    )
    if ((Get-VMFixExecutionTimeout -FixName $FixName) -eq 0) { return }
    $arguments = @{
        VmName = $VMName; VmDomainName = $VMDomain
        ScriptBlock = Get-VMFixDiagnosticScriptBlock
        ArgumentList = @($FixName, $Stage)
        DisplayName = "Maintenance evidence: $FixName ($Stage)"
        AsJob = $true; TimeoutSeconds = 60; SessionMaxRetries = 1
        SuppressLog = $true; FailOnRemoteError = $true
    }
    if ($VMDomainAccount) { $arguments.VmDomainAccount = $VMDomainAccount }
    try {
        $result = Invoke-VmCommand @arguments
        if (-not $result -or $result.ScriptBlockFailed -or -not $result.ScriptBlockOutput) {
            throw "Guest evidence unavailable or timed out: $($result.ErrorDetails)"
        }
        $raw = @($result.ScriptBlockOutput) -join "`n"
        if ($raw.Length -gt 512KB) { throw 'Guest evidence exceeds the 512 KB limit.' }
        $snapshot = $raw | ConvertFrom-Json -ErrorAction Stop
        $root = Split-Path $PSScriptRoot -Parent
        $source = [ordered]@{ ActiveVersion = "$($Common.MemLabsVersion)"; ActiveHotfixVersion = "$($Common.LatestHotfixVersion)" }
        foreach ($name in @('version.json', 'DSC\DSC.build.json')) {
            $file = Join-Path $root $name
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $source[$name] = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
        }
        $fixFile = Join-Path $root "Fixes\$FixName.ps1"
        if (Test-Path -LiteralPath $fixFile -PathType Leaf) { $source.FixSha256 = (Get-FileHash -LiteralPath $fixFile -Algorithm SHA256).Hash }
        $snapshot | Add-Member -NotePropertyName HostSource -NotePropertyValue $source -Force
        $raw = $snapshot | ConvertTo-Json -Depth 10 -Compress
        $directory = Split-Path $Common.LogPath -Parent
        if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw 'The host log directory is unavailable.'
        }
        $path = Join-Path $directory "$VMName-$FixName-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid().ToString('N').Substring(0,8)).diagnostics.log"
        $raw | Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
        $context = $snapshot | Select-Object -Property * -ExcludeProperty Logs, InstallerEvents
        Write-Log "$VMName`: [$FixName] $Stage evidence saved to $path. Context: $(Protect-VMFixDiagnosticText ($context | ConvertTo-Json -Depth 8 -Compress) 12000)" -Warning -LogOnly
        foreach ($log in @($snapshot.Logs)) {
            Write-Log "$VMName`: [$FixName] Evidence log '$($log.Path)' ($($log.Bytes) bytes); tail: $(Protect-VMFixDiagnosticText (@($log.Tail | Select-Object -Last 8) -join ' | ') 3000)" -LogOnly
        }
    }
    catch {
        Write-Log "$VMName`: [$FixName] $Stage evidence collection failed: $(Protect-VMFixDiagnosticText $_.Exception.Message)" -Warning
    }
}

function New-VMFixScriptBlock {
    <#
    .SYNOPSIS
        Wraps a fix body scriptblock with a standard transcript + structured-return
        wrapper that runs on the VM.
    .DESCRIPTION
        The wrapper:
          - Starts Start-Transcript to C:\staging\Fix\<FixName>.txt
          - Exposes a Write-FixLog helper to the body (Info/Warning/Failure/Success)
          - Runs the body in try/catch; captures exceptions
          - Returns a PSCustomObject:
              FixName, Success, Message, Errors[], ExceptionInfo, ComputerName,
              StartedAt, DurationSec, IsStructured = $true
        Body return value handling (back-compat):
          - $null              -> Success = $true
          - [bool]             -> Success = value
          - PSCustomObject     -> If it has .Success, copy Success/Message/Errors
          - other              -> Cast last item to bool
        The body's own param(...) block is preserved; ArgumentList from
        Invoke-VmCommand is forwarded into the body via $args.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_-]{1,80}$')][string]$FixName,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $bodyText = $Body.ToString()
    $redactor = ${function:Protect-VMFixDiagnosticText}.ToString()
    # Escape any backticks/$ in the FixName for safe embedding in a here-string.
    $safeName = $FixName -replace "'", "''"

    $wrapperText = @"
# Auto-generated wrapper for fix '$safeName'
`$__FixName = '$safeName'
if (-not (Test-Path 'C:\staging\Fix')) {
    New-Item -Path 'C:\staging\Fix' -ItemType Directory -Force | Out-Null
}
`$__transcriptPath = "C:\staging\Fix\`$__FixName.txt"
`$__resultPath = "C:\staging\Fix\`$__FixName.result.json"
`$__attemptId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
`$__historyPath = "C:\staging\Fix\history\`$__FixName"
# Clear any stale result marker up front. A catastrophic failure that prevents
# the finally{} write then leaves NO marker, and the host treats 'no marker' as
# 'the fix did NOT succeed' -- an explicit success marker is REQUIRED to stamp a
# fix as applied (so cmdlet output leaking onto the pipeline can never mask it).
try { if (Test-Path `$__resultPath) { Remove-Item `$__resultPath -Force -ErrorAction SilentlyContinue } } catch { }
`$__result = [pscustomobject]@{
    FixName       = `$__FixName
    Success       = `$false
    Message       = `$null
    Errors        = @()
    ExceptionInfo = `$null
    ComputerName  = `$env:COMPUTERNAME
    StartedAt     = (Get-Date).ToString('o')
    DurationSec   = 0
    IsStructured  = `$true
    AttemptId     = `$__attemptId
    Identity      = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    HistoryPath   = `$__historyPath
    DiagnosticWarnings = @()
}
`$__sw = [System.Diagnostics.Stopwatch]::StartNew()
function Protect-VMFixDiagnosticText {
$redactor
}
try { Start-Transcript -Path `$__transcriptPath -Force -ErrorAction Stop | Out-Null }
catch {
    `$__warning = "Could not start transcript: `$(Protect-VMFixDiagnosticText `$_.Exception.Message)"
    `$__result.DiagnosticWarnings += `$__warning
    Write-Warning `$__warning
}
try {
    Write-Host "[`$__FixName] Starting on `$env:COMPUTERNAME at `$(Get-Date -Format 'u')"
    function Write-FixLog {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline = `$true, Position = 0)][string]`$Message,
            [ValidateSet('Info','Warning','Failure','Success')][string]`$Level = 'Info'
        )
        process {
            `$ts = (Get-Date).ToString('HH:mm:ss.fff')
            Write-Host "[`$ts][`$Level] `$(Protect-VMFixDiagnosticText -Text `$Message -MaximumLength 8000)"
        }
    }
    # --- BEGIN FIX BODY ---
    `$__bodyOut = & {
$bodyText
    } @args
    # --- END FIX BODY ---
    `$__records = @(`$__bodyOut | Where-Object { `$null -ne `$_ -and `$_.PSObject.Properties['Success'] })
    if (`$__records.Count -gt 1) {
        throw "Fix body returned multiple explicit success records; refusing an ambiguous maintenance verdict."
    }
    if (`$__records.Count -eq 1) {
        `$__record = `$__records[0]
        if (`$__record.Success -isnot [bool]) { throw "Fix body returned a non-Boolean Success property." }
        `$__terminal = @(`$__bodyOut) | Select-Object -Last 1
        `$__result.Success = `$__record.Success -and -not (`$__terminal -is [bool] -and -not `$__terminal)
        if (`$__record.PSObject.Properties['Message']) { `$__result.Message = `$__record.Message }
        if (`$__record.PSObject.Properties['Errors']) { `$__result.Errors = @(`$__record.Errors) }
        foreach (`$__property in @('State', 'PreservedNewer', 'Attempts', 'VersionSource')) {
            if (`$__record.PSObject.Properties[`$__property]) {
                `$__result | Add-Member -NotePropertyName `$__property -NotePropertyValue `$__record.`$__property -Force
            }
        }
    }
    elseif (`$null -eq `$__bodyOut) {
        `$__result.Success = `$true
    }
    else {
        # Take last emitted value (back-compat with fixes that return `$true/`$false at the end)
        `$__last = @(`$__bodyOut) | Select-Object -Last 1
        `$__result.Success = [bool]`$__last
    }
}
catch {
    `$__result.Success = `$false
    `$__result.ExceptionInfo = "`$(`$_.Exception.Message)``n`$(`$_.ScriptStackTrace)"
    `$__result | Add-Member -NotePropertyName FailureCategory -NotePropertyValue (Protect-VMFixDiagnosticText `$_.FullyQualifiedErrorId 1200) -Force
    Write-Host "[`$__FixName] EXCEPTION: `$(Protect-VMFixDiagnosticText `$_.Exception.Message 12000)"
    Write-Host "[`$__FixName] `$(Protect-VMFixDiagnosticText `$_.ScriptStackTrace 12000)"
}
finally {
    `$__sw.Stop()
    `$__result.DurationSec = [math]::Round(`$__sw.Elapsed.TotalSeconds, 2)
    try { Stop-Transcript | Out-Null }
    catch {
        `$__warning = "Could not stop transcript: `$(Protect-VMFixDiagnosticText `$_.Exception.Message)"
        `$__result.DiagnosticWarnings += `$__warning
        Write-Warning `$__warning
    }
    if (`$__result.Message) { `$__result.Message = Protect-VMFixDiagnosticText `$__result.Message 12000 }
    if (`$__result.ExceptionInfo) { `$__result.ExceptionInfo = Protect-VMFixDiagnosticText `$__result.ExceptionInfo 12000 }
    `$__result.Errors = @(`$__result.Errors | ForEach-Object { Protect-VMFixDiagnosticText "`$_" 8000 })
    # Authoritative result marker: the batch runner / host read THIS file (in a
    # separate step), not the scriptblock's pipeline return value. Written last so
    # it reflects the final Success/Message/Errors after the body + catch ran.
    try {
        if (-not (Test-Path 'C:\staging\Fix')) { New-Item -Path 'C:\staging\Fix' -ItemType Directory -Force | Out-Null }
        `$__result | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path `$__resultPath -Encoding UTF8 -Force
        New-Item -Path `$__historyPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        `$__result | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath (Join-Path `$__historyPath "`$__attemptId.result.json") -Encoding UTF8 -ErrorAction Stop
        if (Test-Path -LiteralPath `$__transcriptPath) {
            `$__lines = @(Get-Content -LiteralPath `$__transcriptPath -ErrorAction Stop |
                ForEach-Object { Protect-VMFixDiagnosticText "`$_" 8000 })
            `$__lines | Set-Content -LiteralPath `$__transcriptPath -Encoding UTF8 -ErrorAction Stop
            `$__lines | Set-Content -LiteralPath (Join-Path `$__historyPath "`$__attemptId.txt") -Encoding UTF8 -ErrorAction Stop
        }
    } catch { Write-Warning "Could not persist fix result/history: `$(`$_.Exception.Message)" }
}
`$__result
"@

    return [scriptblock]::Create($wrapperText)
}

function Get-VMFixTranscript {
    <#
    .SYNOPSIS
        Pulls the C:\staging\Fix\<FixName>.txt transcript from a VM and writes
        each line to the host log with a TR/FixName prefix.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$VMDomain,
        [Parameter(Mandatory = $true)][string]$FixName,
        [string]$VMDomainAccount,
        [switch]$CollectDiagnostics,
        [string]$Stage = 'failure'
    )
    $sb = {
        param($name)
        $p = "C:\staging\Fix\$name.txt"
        if (Test-Path $p) { Get-Content -Path $p -Tail 400 -ErrorAction Stop }
        else { throw "Transcript not found: $p" }
    }
    $args = @{
        VmName       = $VMName
        VMDomainName = $VMDomain
        ScriptBlock  = $sb
        ArgumentList = @($FixName)
        DisplayName  = "Pull transcript: $FixName"
        SuppressLog  = $true
        AsJob        = $true
        TimeoutSeconds = 30
        SessionMaxRetries = 1
        FailOnRemoteError = $true
    }
    if ($VMDomainAccount) { $args.VmDomainAccount = $VMDomainAccount }
    try {
        $r = Invoke-VmCommand @args
        if ($r -and $r.ScriptBlockOutput) {
            Write-Log "$VMName`: ===== Transcript [$FixName] BEGIN =====" -LogOnly
            foreach ($line in @($r.ScriptBlockOutput)) {
                if ($null -ne $line -and "$line" -ne "") {
                    Write-Log -LogOnly "$VMName`: [$FixName] $(Protect-VMFixDiagnosticText -Text "$line")"
                }
                else {
                    Write-Log "$VMName`: [$FixName] Transcript unavailable, empty, or timed out: $($r.ErrorDetails)" -LogOnly -Warning
                }
            }
            Write-Log "$VMName`: ===== Transcript [$FixName] END =====" -LogOnly
        }
        if ($CollectDiagnostics) {
            Save-VMFixFailureEvidence -VMName $VMName -VMDomain $VMDomain -FixName $FixName -VMDomainAccount $VMDomainAccount -Stage $Stage
        }
    }
    catch {
        Write-Log "$VMName`: Failed to pull transcript for [$FixName]: $_" -LogOnly -Warning
    }
}

function Get-VMFixResultMarker {
    <#
    .SYNOPSIS
        Reads C:\staging\Fix\<FixName>.result.json from a VM (written by the
        New-VMFixScriptBlock wrapper) and returns the parsed structured result,
        or $null if the marker is missing/unreadable.
    .DESCRIPTION
        This is the AUTHORITATIVE success signal for a fix. It is read in a
        SEPARATE call from the fix execution so that pipeline-stream leakage from
        the fix body (cmdlet output that turns the scriptblock's return value into
        an array and coerces to a bogus Success=$true) can never affect the
        verdict. No marker == the fix did NOT report explicit success.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$VMDomain,
        [Parameter(Mandatory = $true)][string]$FixName,
        [string]$VMDomainAccount
    )
    $sb = {
        param($name)
        $p = "C:\staging\Fix\$name.result.json"
        if (Test-Path $p) { Get-Content -Path $p -Raw -ErrorAction SilentlyContinue }
    }
    $args = @{
        VmName       = $VMName
        VMDomainName = $VMDomain
        ScriptBlock  = $sb
        ArgumentList = @($FixName)
        DisplayName  = "Pull result marker: $FixName"
        SuppressLog  = $true
        AsJob = $true
        TimeoutSeconds = 30
        SessionMaxRetries = 1
        FailOnRemoteError = $true
    }
    if ($VMDomainAccount) { $args.VmDomainAccount = $VMDomainAccount }
    try {
        $r = Invoke-VmCommand @args
        if ($r -and $r.ScriptBlockOutput) {
            $raw = (@($r.ScriptBlockOutput) -join "`n")
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                return ($raw | ConvertFrom-Json)
            }
        }
    }
    catch {
        Write-Log "$VMName`: Failed to read result marker for [$FixName]: $_" -LogOnly -Warning
    }
    return $null
}

function Get-MaintenanceInjectPaths {
    <#
    .SYNOPSIS
        Scans all Fix*.ps1 files and returns the unique InjectFiles and
        InjectTools declared across every fix. Used by Copy-ToolToVM to
        pre-stage maintenance files during Phase 2 so Phase 10 can skip
        the redundant (and potentially stalling) PSDirect copy.
    #>
    $fixesDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'Fixes'
    $injectFiles = @()
    $injectTools = @()
    if (Test-Path $fixesDir) {
        $fixesToPerform = @()
        # Dummy variables so fix scripts can dot-source without errors
        $vmNote = $null; $dc = $null; $NewVM = $true
        Get-ChildItem -Path $fixesDir -Filter 'Fix*.ps1' -File | ForEach-Object {
            . $_.FullName
        }
        foreach ($fix in $fixesToPerform) {
            if ($fix.InjectFiles) { $injectFiles += $fix.InjectFiles }
            if ($fix.InjectTools) { $injectTools += $fix.InjectTools }
        }
    }
    [PSCustomObject]@{
        Files = @($injectFiles | Select-Object -Unique)
        Tools = @($injectTools | Select-Object -Unique)
    }
}

function Test-VMFixApplied {
    <#
    .SYNOPSIS
        Checks whether a specific fix has already been applied to a VM by
        inspecting the per-fix tracking dictionary in the VM notes.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VMNote,
        [Parameter(Mandatory = $true)]
        [string] $FixName,
        [Parameter(Mandatory = $true)]
        [string] $FixVersion
    )

    if (-not $VMNote -or
        -not ($VMNote.PSObject.Properties.Name -contains 'appliedFixes') -or
        -not $VMNote.appliedFixes) {
        return $false
    }
    if (-not ($VMNote.appliedFixes.PSObject.Properties.Name -contains $FixName)) {
        return $false
    }
    return ((ConvertTo-MemLabsVersion $VMNote.appliedFixes.$FixName) -ge (ConvertTo-MemLabsVersion $FixVersion))
}

function Set-VMNoteFixBatch {
    <#
    .SYNOPSIS
        Stamps multiple fixes into appliedFixes in a single CIM read+write.
        Returns the updated VM note object so the caller can reuse it.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $VMName,
        [Parameter(Mandatory = $true)]
        [object[]] $Fixes
    )

    $vmNote = Get-VMNote -VMName $VMName
    if (-not $vmNote) { return $null }

    $appliedFixes = @{}
    if ($vmNote.PSObject.Properties.Name -contains 'appliedFixes' -and $vmNote.appliedFixes) {
        foreach ($prop in $vmNote.appliedFixes.PSObject.Properties) {
            $appliedFixes[$prop.Name] = $prop.Value
        }
    }
    foreach ($fix in $Fixes) {
        $appliedFixes[$fix.FixName] = [string]$fix.FixVersion
    }
    $vmNote | Add-Member -MemberType NoteProperty -Name "appliedFixes" -Value ([PSCustomObject]$appliedFixes) -Force
    Set-VMNote -vmName $VMName -vmNote $vmNote
    return $vmNote
}

function Get-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName", ParameterSetName = "Real")]
        [object] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMName", ParameterSetName = "Dummy")]
        [switch] $ReturnDummyList,
        [Parameter(Mandatory = $false, ParameterSetName = "Real")]
        [object] $VMNote,
        [bool] $NewVM = $true
    )

    if ($ReturnDummyList.IsPresent) {
        $vmNote = $null
    }
    else {
        if (-not $vmNote) { $vmNote = Get-VMNote -VMName $VMName }
        if ($Common.InJob) {
            # In job workers, skip Get-List (triggers expensive Get-VM +
            # Get-VMNetworkAdapter -All bulk warmup that serializes on vmms.exe
            # across all parallel workers). Instead, do a single targeted
            # Get-VM enumeration and resolve the DC by reading notes
            # (role=DC + matching domain). DC names are user-chosen in
            # genconfig and are NOT guaranteed to follow a "<prefix>-DC"
            # convention -- guessing by name produces phantom dependent VMs
            # whose Get-VMNote returns null and crashes Start-VMIfNotRunning
            # with "Cannot bind argument ... empty string". Only Fix-CMFullAdmin
            # consumes $dc.vmName today.
            $dc = $null
            if ($vmNote.domain) {
                $dcMatches = @()
                try {
                    foreach ($hvm in (Get-VM -ErrorAction SilentlyContinue)) {
                        if ($hvm.Notes -like "*lastUpdate*" -and $hvm.Notes -like "*`"role`":*`"DC`"*") {
                            try {
                                $hvmNote = $hvm.Notes | ConvertFrom-Json
                                if ($hvmNote.role -eq 'DC' -and $hvmNote.domain -eq $vmNote.domain) {
                                    $dcMatches += [PSCustomObject]@{ vmName = $hvm.Name; role = 'DC'; domain = $hvmNote.domain }
                                }
                            } catch {}
                        }
                    }
                } catch {}
                if ($dcMatches.Count -gt 0) { $dc = $dcMatches }
            }
        }
        else {
            $dc = Get-List -Type VM | Where-Object { $_.role -eq "DC" -and $_.domain -eq $vmNote.domain }
        }
    }

    $fixesToPerform = @()

    # Load each fix from the vmbuild\Fixes folder. Each file appends a
    # descriptor object to $fixesToPerform. Available variables in fix scope:
    #   $vmNote, $dc, $Common, $NewVM, $fixesToPerform
    $fixesDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'Fixes'
    if (Test-Path $fixesDir) {
        Get-ChildItem -Path $fixesDir -Filter 'Fix*.ps1' -File | Sort-Object Name | ForEach-Object {
            . $_.FullName
        }
    }
    else {
        Write-Log "Get-VMFixes: Fixes directory not found at $fixesDir" -Warning
    }

    # ========================
    # Determine applicability
    # ========================
    foreach ($vmFix in $fixesToPerform) {
        $applicable = $false
        $applicableRoles = $vmFix.AppliesToRoles
        if (-not $applicableRoles) {
            # Empty AppliesToRoles means "all roles". Use AllRoles list if available,
            # otherwise treat as universally applicable (covers InJob where
            # Set-SupportedOptions is skipped).
            $applicableRoles = $Common.Supported.AllRoles
        }
        if ($vmFix.NotAppliesToRoles -and $vmNote.role -in $vmFix.NotAppliesToRoles) {
            $applicable = $false
        }
        elseif (-not $applicableRoles -or $vmNote.role -in $applicableRoles) {
            $applicable = $true
        }
        else {
            $topLevelSite = $vmNote.role -eq "CAS" -or ($vmNote.role -eq "Primary" -and (-not $vmNote.parentSiteCode))
            if ($applicableRoles -contains "CASorStandalonePrimary" -and $topLevelSite) {
                $applicable = $true
            }
        }

        $vmfix | Add-Member -MemberType NoteProperty -Name AppliesToThisVM -Value $applicable -force

        # Filter out null's'
        $vmFix.DependentVMs = $vmFix.DependentVMs | Where-Object { $_ -and $_.Trim() }
    }

    return $fixesToPerform
}

function Start-CompactDisksUI {
    <#
    .SYNOPSIS
        Launches the WPF VHD-compaction worker as a detached process.

    .DESCRIPTION
        Spawns Compact-Disks.ps1 in a separate hidden PowerShell process. The
        worker shows a WPF progress window and runs Optimize-VHD in parallel
        for every VHD owned by the given VMs. The worker dot-sources
        Common.ps1 itself to pick up $Common.LocalAdmin for in-guest cleanup,
        so no credential plumbing is needed here. Returns immediately so the
        caller (genconfig) stays interactive.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]] $VMNames,

        [ValidateSet('Quick', 'Full', 'Retrim', 'Prezeroed')]
        [string] $Mode = 'Full',

        [ValidateRange(1, 16)]
        [int] $MaxConcurrentJobs = 8,

        [string] $DomainLabel
    )

    $scriptPath = Join-Path $PSScriptRoot '..\Compact-Disks.ps1'
    if (-not (Test-Path $scriptPath)) {
        Write-RedX "Compact-Disks.ps1 not found at $scriptPath"
        return
    }
    $scriptPath = (Resolve-Path $scriptPath).Path

    $vmListQuoted = ($VMNames | ForEach-Object { "'{0}'" -f ($_ -replace "'", "''") }) -join ','
    # NOTE: -DomainLabel is passed via env var (_COMPACT_DISKS_DOMAINLABEL),
    # not via -Command, because powershell.exe -Command's quoting around an
    # embedded -DomainLabel '...' argument was unreliable in practice (the
    # parent process ended up with $DomainLabel empty and the worker title
    # fell back to '<count> VM(s)'). Env vars are inherited verbatim by the
    # child process so there's no shell-quoting layer to fight.
    $command = "& '$scriptPath' -Mode $Mode -MaxConcurrentJobs $MaxConcurrentJobs -VMNames @($vmListQuoted)"

    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command', $command
    )

    Write-WhiteI -indent 0 "Launching Compact-Disks UI for $($VMNames.Count) VM(s)..."
    if ($DomainLabel) {
        $env:_COMPACT_DISKS_DOMAINLABEL = $DomainLabel
    }
    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Normal -UseNewEnvironment:$false | Out-Null
        Write-GreenCheck "Compact-Disks worker launched. A WPF progress window will appear shortly."
    }
    catch {
        Write-RedX "Failed to launch Compact-Disks.ps1: $($_.Exception.Message)"
    }
    finally {
        Remove-Item Env:\_COMPACT_DISKS_DOMAINLABEL -ErrorAction SilentlyContinue
    }
}

function Merge-VMCheckpointsForCompact {
    <#
    .SYNOPSIS
        Deprecated - the WPF worker (Compact-Disks.ps1) now performs per-VM
        prep (stop + checkpoint merge) in parallel with compaction.
    #>
    [CmdletBinding()]
    param ([object[]] $VMs)
    Write-Log "Merge-VMCheckpointsForCompact is deprecated; stop and merge now run inside the Compact-Disks WPF worker." -LogOnly
}

function select-OptimizeDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Optimize")]
        [string] $domain
    )

    $CustomOptions = @{}
    $vms = get-list -type vm -DomainName $domain -SmartUpdate

    $vmsname = $vms | Select-Object -ExpandProperty vmName

    $response = Get-Menu2 -MenuName "Select VMs to Optimize in $domain" -Prompt "Select VMs to Compact" -additionalOptions $CustomOptions -OptionArray $vmsname -test:$false -MultiSelect -AllSelected

    if ($response -eq "ESCAPE" -or $response -eq "NOITEMS") {
        return "ESCAPE"
    }

    $selectedVMs = @($vms | Where-Object { $_.VmName -in $response })
    if (-not $selectedVMs -or $selectedVMs.Count -eq 0) {
        Write-RedX "No VMs selected."
        return
    }

    # The WPF worker does everything per-VM in parallel:
    #   online cleanup (if Running) -> graceful shutdown (with hard-stop
    #   fallback) -> merge checkpoints -> mount/cleanup/zero-fill/defrag ->
    #   Optimize-VHD. As each VM finishes its prep its disks join the compact
    #   queue, so slow-stopping VMs don't block fast ones. The worker dot-
    #   sources Common.ps1 itself to pick up $Common.LocalAdmin.
    Start-CompactDisksUI -VMNames ($selectedVMs | Select-Object -ExpandProperty VmName) -DomainLabel $domain

    Write-Host
    Write-Host "VHD compaction is running in a separate WPF window." -ForegroundColor Green
    Write-Host "The worker will stop, merge checkpoints, and compact each VM in parallel. VMs that were running at start will be auto-restarted when compaction finishes." -ForegroundColor DarkGray
    Start-Sleep -Seconds 3
}






function Select-DeletePending {


    Write-Log -Activity "These VMs are currently 'in progress', if there is no deployment running, you should delete them and redeploy"
    get-list -Type VM -SmartUpdate | Where-Object { $_.InProgress -eq "True" } | Format-Table -Property vmname, Role, SiteCode, DeployedOS, @{E = { "$($_.DynamicMinRam)-$($_.Memory)" }; L = "Memory" }, @{Label = "DiskUsedGB"; Expression = { [Math]::Round($_.DiskUsedGB, 2) } }, State, Domain, Network, SQLVersion | Out-Host
    Write-WhiteI "Please confirm these VMs are not currently in the process of being deployed."
    Write-OrangePoint "Selecting 'Yes' will permanently delete all VMs and scopes."
    $response = Read-YesOrNoWithTimeout -Prompt "Are you sure? (y/N)" -HideHelp -timeout 180 -Default "n"
    if (-not [String]::IsNullOrWhiteSpace($response)) {
        if ($response.ToLowerInvariant() -eq "y" -or $response.ToLowerInvariant() -eq "yes") {
            Remove-InProgress
            Get-List -type VM -SmartUpdate | Out-Null
        }
    }
}
