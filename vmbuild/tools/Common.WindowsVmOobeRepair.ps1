function Wait-MemLabsOobeRepairJob {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$Operation
    )

    try {
        $completed = Wait-Job -Job $Job -Timeout $TimeoutSeconds -ErrorAction Stop
        if (-not $completed) {
            $exception = [TimeoutException]::new("$Operation exceeded ${TimeoutSeconds}s. Its outcome must be treated as unknown; no automatic retry is safe.")
            $exception.Data['OobeRepairIndeterminate'] = $true
            $exception.Data['JobId'] = $Job.Id
            try { $null = $Job.StopJobAsync() }
            catch { Write-Warning "$Operation cancellation could not be requested: $($_.Exception.Message)" }
            $stopped = Wait-Job -Job $Job -Timeout 5 -ErrorAction Stop
            if (-not $stopped) { Write-Warning "Owned job $($Job.Id) is still stopping and was not disposed." }
            throw $exception
        }
        if ("$($Job.State)" -ne 'Completed') {
            $null = Receive-Job -Job $Job -ErrorAction Stop
            throw "$Operation ended in job state $($Job.State)."
        }
        Receive-Job -Job $Job -ErrorAction Stop
    }
    catch {
        if ("$($Job.State)" -notin @('Completed', 'Failed', 'Stopped')) {
            $_.Exception.Data['OobeRepairIndeterminate'] = $true
            try { $null = $Job.StopJobAsync() }
            catch { Write-Warning "$Operation cancellation failed: $($_.Exception.Message)" }
        }
        throw
    }
    finally {
        if ("$($Job.State)" -in @('Completed', 'Failed', 'Stopped')) {
            try { Remove-Job -Job $Job -Force -ErrorAction Stop }
            catch { Write-Warning "$Operation job cleanup failed: $($_.Exception.Message)" }
        }
    }
}

function Get-MemLabsOobeRepairGuestBlock {
    $phaseRoot = Join-Path $PSScriptRoot '..\DSC\phases'
    $setup = Get-Content -LiteralPath (Join-Path $phaseRoot 'WindowsSetupReadiness.ps1') -Raw -ErrorAction Stop
    $repair = Get-Content -LiteralPath (Join-Path $phaseRoot 'WindowsOobeRecovery.ps1') -Raw -ErrorAction Stop
    return [scriptblock]::Create("param(`$Action, `$Snapshot)`n$setup`n$repair`nInvoke-MemLabsWindowsOobeRecovery -Action `$Action -Snapshot `$Snapshot -Confirm:`$false")
}

function Invoke-MemLabsOobeRepairGuestCommand {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][scriptblock]$GuestBlock,
        [Parameter(Mandatory)][ValidateSet('Inspect', 'Probe', 'Apply', 'Restore')][string]$Action,
        $Snapshot,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 30
    )

    $live = Get-VM -Id $VM.Id -ErrorAction Stop
    if ($live.Name -ne $VM.Name -or "$($live.State)" -ne 'Running') { throw 'The selected VM is no longer the same running target.' }
    $job = Invoke-Command -VMId $VM.Id -Credential $GuestCredential -AsJob -ScriptBlock $GuestBlock `
        -ArgumentList @($Action, $Snapshot) -ErrorAction Stop
    try { $results = @(Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds $TimeoutSeconds -Operation "PowerShell Direct $Action") }
    catch {
        if ($Action -in @('Apply', 'Restore') -and
            "$($_.FullyQualifiedErrorId) $($_.Exception.GetType().FullName)" -match 'PSRemotingTransport|PSSessionStateBroken|RunspaceStateBroken') {
            $_.Exception.Data['OobeRepairIndeterminate'] = $true
        }
        throw
    }
    if ($results.Count -ne 1 -or $results[0].Version -isnot [int] -or $results[0].Version -ne 1 -or
        $results[0].Scope -ne 'OobeOnly' -or $results[0].IdentityRepairPerformed -isnot [bool] -or
        $results[0].IdentityRepairPerformed) {
        throw "Invalid PowerShell Direct $Action result. No identity repair is permitted."
    }
    return $results[0]
}

function Start-MemLabsOobeRepairVm {
    param([Parameter(Mandatory)]$VM)

    $live = Get-VM -Id $VM.Id -ErrorAction Stop
    if ($live.Name -ne $VM.Name -or "$($live.State)" -ne 'Off') { throw 'Repair startup requires the exact selected VM to be Off.' }
    $job = Start-VM -VM $live -AsJob -Confirm:$false -ErrorAction Stop
    $null = Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds 60 -Operation 'VM startup'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $live = Get-VM -Id $VM.Id -ErrorAction Stop
        if ($live.Name -ne $VM.Name) { throw 'The selected VM name changed during startup.' }
        if ("$($live.State)" -eq 'Running' -and "$($live.Heartbeat)" -like 'Ok*') { return }
        Start-Sleep -Seconds 2
    } while ($watch.Elapsed.TotalSeconds -lt 120)
    throw 'The selected VM did not reach a running, heartbeat-responsive state within 120 seconds.'
}

function Wait-MemLabsOobeRepairCompletion {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][scriptblock]$GuestBlock,
        [Parameter(Mandatory)][string]$MachineGuid,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [int]$StableSeconds = 0,
        [string]$ExpectedName
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $readyAt = $null
    $lastDetail = 'No state received.'
    $lastLog = -30
    try {
        do {
            $remaining = $TimeoutSeconds - $watch.Elapsed.TotalSeconds
            if ($remaining -le 0) { break }
            $state = Invoke-MemLabsOobeRepairGuestCommand -VM $VM -GuestCredential $GuestCredential `
                -GuestBlock $GuestBlock -Action Probe -TimeoutSeconds ([Math]::Max(1, [Math]::Min(30, [int][Math]::Floor($remaining))))
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            if ($state.MachineGuid -ne $MachineGuid -or $state.Setup.Ready -isnot [bool] -or
                $state.Setup.Version -isnot [int] -or $state.Setup.Version -ne 1 -or
                $state.Setup.ProductType -isnot [int] -or $state.Setup.ProductType -ne 1) {
                throw 'The guest identity or setup result changed during the repair trial.'
            }
            $lastDetail = $state.Setup.Detail
            if ($state.Setup.Ready) {
                if ($state.Setup.NativeOobeComplete -isnot [bool] -or -not $state.Setup.NativeOobeComplete -or
                    $state.Setup.Reason -ne 'Complete' -or
                    $state.Setup.ImageState -isnot [string] -or $state.Setup.ImageState -ne 'IMAGE_STATE_COMPLETE' -or
                    $state.Setup.ActiveName -isnot [string] -or [string]::IsNullOrWhiteSpace($state.Setup.ActiveName) -or
                    $state.Setup.PendingName -isnot [string] -or [string]::IsNullOrWhiteSpace($state.Setup.PendingName)) {
                    throw 'Inconsistent native/machine OOBE completion result.'
                }
                foreach ($name in @('SetupType', 'OOBEInProgress', 'SystemSetupInProgress')) {
                    if (($state.Setup.$name -isnot [int] -and $state.Setup.$name -isnot [uint32]) -or $state.Setup.$name -ne 0) {
                        throw 'Inconsistent machine OOBE completion flags.'
                    }
                }
                if ($ExpectedName -and ($state.Setup.ActiveName -ne $ExpectedName -or $state.Setup.PendingName -ne $ExpectedName)) {
                    throw 'Windows changed the computer name during post-repair verification; this OOBE-only trial will not rename it.'
                }
                if ($null -eq $readyAt) { $readyAt = $watch.Elapsed.TotalSeconds }
                if ($watch.Elapsed.TotalSeconds - $readyAt -ge $StableSeconds) { return $state }
            }
            elseif ($null -ne $readyAt) { throw "Windows re-entered incomplete OOBE during verification. $lastDetail" }
            if ($watch.Elapsed.TotalSeconds - $lastLog -ge 30) {
                Write-Host "$($VM.Name): OOBE trial elapsed=$([int]$watch.Elapsed.TotalSeconds)s stableRequired=${StableSeconds}s. $lastDetail"
                $lastLog = $watch.Elapsed.TotalSeconds
            }
            Write-Progress -Activity "$($VM.Name): OOBE recovery trial" -Status $lastDetail
            Start-Sleep -Seconds ([Math]::Min(5, [Math]::Max(1, [int]($TimeoutSeconds - $watch.Elapsed.TotalSeconds))))
        } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    }
    finally { $watch.Stop(); Write-Progress -Activity "$($VM.Name): OOBE recovery trial" -Completed }
    throw "Native OOBE completion/stability was not verified within ${TimeoutSeconds}s. $lastDetail"
}

function Write-MemLabsOobeRepairReport {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Report)

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop } }
}

function Test-MemLabsOobeRepairExport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][guid]$VMId,
        [Parameter(Mandatory)][int]$DiskCount
    )

    $job = Start-Job -ArgumentList @($Path, "$VMId", $DiskCount) -ScriptBlock {
        param($root, $id, $minimumDisks)
        $ErrorActionPreference = 'Stop'
        $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        $items = [Collections.Generic.List[object]]::new()
        $pending = [Collections.Generic.Queue[object]]::new()
        $pending.Enqueue((Get-Item -LiteralPath $root -Force -ErrorAction Stop))
        while ($pending.Count) {
            $item = $pending.Dequeue()
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A repair backup must not contain reparse points.' }
            if ($item.FullName.TrimEnd('\') -ne $prefix.TrimEnd('\') -and
                -not $item.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'An exported item escaped the backup directory.'
            }
            $items.Add($item)
            if ($item.PSIsContainer) {
                foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop) { $pending.Enqueue($child) }
            }
        }
        $files = @($items | Where-Object { -not $_.PSIsContainer })
        $configs = @($files | Where-Object { $_.Extension -eq '.vmcx' -and $_.BaseName -eq $id })
        if ($configs.Count -ne 1 -or $configs[0].Length -le 0) { throw 'The export does not contain the selected VM configuration.' }
        $disks = @($files |
            Where-Object { $_.Extension -in @('.vhd', '.vhdx', '.avhd', '.avhdx') })
        if ($disks.Count -lt $minimumDisks) { throw 'The export does not contain all attached disks.' }
        foreach ($disk in $disks) {
            if ($disk.Length -le 0 -or (Test-VHD -Path $disk.FullName -ErrorAction Stop) -ne $true) {
                throw "An exported disk is empty or invalid: $($disk.FullName)"
            }
            $info = Get-VHD -Path $disk.FullName -ErrorAction Stop
            if ($info.ParentPath) {
                $parent = if ([IO.Path]::IsPathRooted($info.ParentPath)) { $info.ParentPath } else { Join-Path $disk.DirectoryName $info.ParentPath }
                if (-not [IO.Path]::GetFullPath($parent).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "An exported disk still depends on a parent outside the backup: $($disk.FullName)"
                }
            }
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { $caller = $identity.User }
            finally { $identity.Dispose() }
            $sids = @($caller, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            foreach ($item in $items) {
                $security = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
                $security.SetAccessRuleProtection($true, $false)
                $inheritance = if ($item.PSIsContainer) {
                    [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
                } else { [Security.AccessControl.InheritanceFlags]::None }
                foreach ($sid in $sids) {
                    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,
                        [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
                        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
                    $security.AddAccessRule($rule)
                }
                Set-Acl -LiteralPath $item.FullName -AclObject $security -ErrorAction Stop
            }
        }
        [pscustomobject]@{ Version = 1; VMId = $id; DiskCount = $disks.Count; Verified = $true }
    }
    $results = @(Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds 300 -Operation 'Export validation')
    if ($results.Count -ne 1 -or $results[0].Verified -isnot [bool] -or -not $results[0].Verified -or
        $results[0].VMId -ne "$VMId") { throw 'The full VM export could not be verified.' }
    return $results[0]
}

function Invoke-MemLabsWindowsOobeRepair {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [ValidateRange(60, 3600)][int]$RepairTimeoutSeconds = 900,
        [ValidateRange(60, 7200)][int]$BackupTimeoutSeconds = 3600,
        [ValidateRange(5, 600)][int]$StopTimeoutSeconds = 90,
        [switch]$AllowTurnOff
    )

    if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($VmName)) { throw 'Repair requires one exact VM name.' }
    $vmMatches = @(Get-VM -Name $VmName -ErrorAction Stop)
    if ($vmMatches.Count -ne 1 -or $vmMatches[0].Name -ne $VmName) { throw 'Repair requires exactly one matching VM.' }
    $vm = $vmMatches[0]
    if (-not $PSCmdlet.ShouldProcess("$VmName [$($vm.Id)]",
            'Export a full backup; trial temporary OOBE update access; restore original settings; verify two graceful reboots. No rename/domain repair.')) { return }
    $destinationRoot = Resolve-MemLabsSetupDiagnosticPath -Path $Destination
    $backupRoot = Resolve-MemLabsSetupDiagnosticPath -Path $BackupPath
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)
    if (-not $drives.Count -or @($drives | Where-Object {
                -not $_.Path -or $_.Path -notmatch '\.(?:a?vhdx?)$' -or
                ($_.PSObject.Properties['SupportPersistentReservations'] -and $_.SupportPersistentReservations)
            }).Count) {
        throw 'A full repair backup requires ordinary file-backed VHD/VHDX disks; pass-through/shared-disk repair is not supported.'
    }
    foreach ($drive in $drives) {
        $sourceDirectory = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($drive.Path)).TrimEnd('\') + '\'
        if (($backupRoot.TrimEnd('\') + '\').StartsWith($sourceDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The repair backup must be outside the VM disk directory.'
        }
    }
    foreach ($property in @('Path', 'ConfigurationLocation', 'SnapshotFileLocation', 'SmartPagingFilePath')) {
        if ($vm.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace($vm.$property)) {
            $sourceDirectory = [IO.Path]::GetFullPath($vm.$property).TrimEnd('\') + '\'
            if (($backupRoot.TrimEnd('\') + '\').StartsWith($sourceDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The repair backup must be outside the VM configuration/checkpoint directories.'
            }
        }
    }
    $runName = ($VmName -replace '[\\/:*?"<>|]', '_') + "-OobeRepair-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $runRoot = Join-Path $destinationRoot $runName
    $backup = Join-Path $backupRoot $runName
    New-MemLabsPrivateDiagnosticDirectory -Path $runRoot
    $bundle = Join-Path $runRoot 'Bundle'
    $null = New-Item -Path $bundle -ItemType Directory
    $reportPath = Join-Path $bundle 'RepairResult.json'
    $report = [ordered]@{
        Version = 1; VMName = $vm.Name; VMId = "$($vm.Id)"; Scope = 'OobeOnly'
        Status = 'Preparing'; BackupPath = $backup; BackupVerified = $false
        IdentityRepairPerformed = $false; FullDeploymentReadinessVerified = $false
        OobeRecovered = $false; VerifiedReboots = 0; FinalState = ''
        Export = $null; Apply = $null; FinalGuestState = $null; FailureStage = ''
        GuestChangesAttempted = $false
        OriginalSettingsRestored = $false; Errors = [Collections.Generic.List[string]]::new()
    }
    $failure = $null; $snapshot = $null; $applyAttempted = $false; $restored = $false; $indeterminate = $false
    $guestBlock = Get-MemLabsOobeRepairGuestBlock
    . (Join-Path $PSScriptRoot '..\DSC\phases\WindowsOobeRecovery.ps1')
    try {
        Write-MemLabsOobeRepairReport -Path $reportPath -Report $report
        $before = Invoke-MemLabsWindowsSetupDiagnostics -VmName $VmName -Destination $Destination `
            -StopTimeoutSeconds $StopTimeoutSeconds -AllowTurnOff:$AllowTurnOff -Confirm:$false
        Copy-Item -LiteralPath $before.ArchivePath -Destination (Join-Path $bundle 'Before.zip') -ErrorAction Stop
        $offlinePath = Join-Path (Split-Path $before.ArchivePath -Parent) 'Bundle\WindowsSetupState.json'
        $offline = Get-Content -LiteralPath $offlinePath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($offline.SOFTWARE.WindowsVersion.Values.InstallationType -ne 'Client' -or
            $offline.SYSTEM.Setup.Values.OOBEInProgress -ne 1 -or
            $offline.SYSTEM.Setup.Values.SystemSetupInProgress -ne 0 -or
            $offline.SYSTEM.ChildCompletion.Values.'setup.exe' -ne 3) {
            throw 'Offline evidence does not match the supported post-setup OOBE failure. No repair will be attempted.'
        }
        $live = Get-VM -Id $vm.Id -ErrorAction Stop
        if ($live.Name -ne $vm.Name -or "$($live.State)" -ne 'Off') { throw 'The selected VM changed before export.' }
        New-MemLabsPrivateDiagnosticDirectory -Path $backup
        Write-Host "$VmName`: exporting a full VM backup to '$backup'. This backup contains guest data and must remain private."
        $job = Export-VM -VM $live -Path $backup -AsJob -Confirm:$false -ErrorAction Stop
        $null = Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds $BackupTimeoutSeconds -Operation 'Full VM export'
        $report.Export = Test-MemLabsOobeRepairExport -Path $backup -VMId $vm.Id -DiskCount $drives.Count
        $report.BackupVerified = $true
        $report.Status = 'Inspecting'
        Write-MemLabsOobeRepairReport -Path $reportPath -Report $report
        Start-MemLabsOobeRepairVm -VM $vm
        $snapshot = Invoke-MemLabsOobeRepairGuestCommand -VM $vm -GuestCredential $GuestCredential -GuestBlock $guestBlock -Action Inspect
        Assert-MemLabsOobeRepairSnapshot -Snapshot $snapshot
        $snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $bundle 'OriginalSettings.json') -Encoding UTF8 -ErrorAction Stop
        if ($snapshot.Setup.Ready -isnot [bool] -or $snapshot.Setup.Reason -eq 'ProbeFailed') {
            throw "Live OOBE state is unreadable. $($snapshot.Setup.Detail)"
        }
        if (-not $snapshot.Setup.Ready) {
            $report.Status = 'ApplyingUpdateAccessTrial'
            Write-MemLabsOobeRepairReport -Path $reportPath -Report $report
            $applyAttempted = $true
            $report.GuestChangesAttempted = $true
            $receipt = Invoke-MemLabsOobeRepairGuestCommand -VM $vm -GuestCredential $GuestCredential `
                -GuestBlock $guestBlock -Action Apply -Snapshot $snapshot -TimeoutSeconds 60
            if ($receipt.Status -ne 'Applied' -or $receipt.MachineGuid -ne $snapshot.MachineGuid) { throw 'Invalid update-access trial acknowledgement.' }
            $report.Apply = $receipt
            Write-Warning 'Update access is temporarily enabled. If the failure page is visible in VMConnect, click Next to let Windows retry. Do not change setup flags or rename the computer.'
        }
        $complete = Wait-MemLabsOobeRepairCompletion -VM $vm -GuestCredential $GuestCredential -GuestBlock $guestBlock `
            -MachineGuid $snapshot.MachineGuid -TimeoutSeconds $RepairTimeoutSeconds
        if ($applyAttempted) {
            $receipt = Invoke-MemLabsOobeRepairGuestCommand -VM $vm -GuestCredential $GuestCredential `
                -GuestBlock $guestBlock -Action Restore -Snapshot $snapshot -TimeoutSeconds 60
            if ($receipt.Status -ne 'Restored' -or $receipt.MachineGuid -ne $snapshot.MachineGuid) { throw 'Original settings restoration was not acknowledged.' }
        }
        $restored = $true
        $report.OriginalSettingsRestored = $true
        $expectedName = $complete.Setup.PendingName
        for ($boot = 1; $boot -le 2; $boot++) {
            $report.Status = "VerifyingReboot$boot"
            Write-MemLabsOobeRepairReport -Path $reportPath -Report $report
            $null = Stop-MemLabsVmForSetupDiagnostics -VM (Get-VM -Id $vm.Id -ErrorAction Stop) -TimeoutSeconds $StopTimeoutSeconds
            Start-MemLabsOobeRepairVm -VM $vm
            $complete = Wait-MemLabsOobeRepairCompletion -VM $vm -GuestCredential $GuestCredential -GuestBlock $guestBlock `
                -MachineGuid $snapshot.MachineGuid -ExpectedName $expectedName -TimeoutSeconds ($RepairTimeoutSeconds + 190) -StableSeconds 190
            $report.VerifiedReboots = $boot
        }
        $report.FinalGuestState = $complete
        $report.OobeRecovered = $true
        $report.Status = 'OobeRecoveredIdentityUnchanged'
    }
    catch {
        $failure = $_
        $report.FailureStage = $report.Status
        $indeterminate = [bool]$_.Exception.Data['OobeRepairIndeterminate']
        $report.Status = if ($indeterminate) { 'Indeterminate' } else { 'Failed' }
        $report.Errors.Add($_.Exception.Message)
    }
    finally {
        if ($applyAttempted -and -not $restored -and -not $indeterminate) {
            try {
                $receipt = Invoke-MemLabsOobeRepairGuestCommand -VM $vm -GuestCredential $GuestCredential `
                    -GuestBlock $guestBlock -Action Restore -Snapshot $snapshot -TimeoutSeconds 60
                if ($receipt.Status -ne 'Restored') { throw 'Restoration was not acknowledged.' }
                $report.OriginalSettingsRestored = $true
            }
            catch {
                $report.Errors.Add("Original settings restoration failed: $($_.Exception.Message)")
                $report.Status = 'Indeterminate'
                $indeterminate = $true
                if (-not $failure) { $failure = $_ }
            }
        }
        if (-not $indeterminate) {
            try {
                $null = Stop-MemLabsVmForSetupDiagnostics -VM (Get-VM -Id $vm.Id -ErrorAction Stop) -TimeoutSeconds $StopTimeoutSeconds
                $after = Invoke-MemLabsWindowsSetupDiagnostics -VmName $VmName -Destination $Destination -StopTimeoutSeconds $StopTimeoutSeconds -Confirm:$false
                Copy-Item -LiteralPath $after.ArchivePath -Destination (Join-Path $bundle 'After.zip') -ErrorAction Stop
                if ($report.OobeRecovered) {
                    $afterStatePath = Join-Path (Split-Path $after.ArchivePath -Parent) 'Bundle\WindowsSetupState.json'
                    $afterState = Get-Content -LiteralPath $afterStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($afterState.SOFTWARE.ImageState.Values.ImageState -ne 'IMAGE_STATE_COMPLETE' -or
                        $afterState.SYSTEM.Setup.Values.SetupType -ne 0 -or
                        $afterState.SYSTEM.Setup.Values.OOBEInProgress -ne 0 -or
                        $afterState.SYSTEM.Setup.Values.SystemSetupInProgress -ne 0) {
                        throw 'OOBE completion did not persist in the shutdown registry state.'
                    }
                }
            }
            catch {
                $report.Errors.Add("Post-trial shutdown/diagnostics failed: $($_.Exception.Message)")
                $report.Status = 'Failed'
                if (-not $failure) { $failure = $_ }
            }
        }
        try { $report.FinalState = "$((Get-VM -Id $vm.Id -ErrorAction Stop).State)" }
        catch { $report.Errors.Add("Final VM state could not be read: $($_.Exception.Message)"); if (-not $failure) { $failure = $_ } }
        Write-MemLabsOobeRepairReport -Path $reportPath -Report $report
    }
    $archive = Join-Path $runRoot "$runName.zip"
    try { Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive -ErrorAction Stop }
    catch { throw "Repair report archiving failed: $($_.Exception.Message). Unarchived evidence is preserved in '$bundle'; backup='$backup'." }
    Write-Host "OOBE-only trial: status=$($report.Status); VM=$($report.FinalState); report=$archive; backup=$backup"
    if ($indeterminate) { Write-Warning 'A remote action or restoration outcome is unknown. Do not retry, reboot, or discard the backup; inspect the report and original-settings receipt first.' }
    if ($failure) { throw "OOBE-only recovery was not verified: $($failure.Exception.Message). Evidence: $archive" }
    [pscustomobject]@{ Scope = 'OobeOnly'; Status = $report.Status; ArchivePath = $archive; BackupPath = $backup; FinalState = $report.FinalState }
}
