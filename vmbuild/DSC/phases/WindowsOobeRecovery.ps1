function Get-MemLabsOobeRepairPolicyTargets {
    @(
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate' }
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DoNotConnectToWindowsUpdateInternetLocations' }
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DisableWindowsUpdateAccess' }
    )
}

function Test-MemLabsOobeRepairElevation {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return [Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

function Get-MemLabsOobeRepairGuestState {
    $setup = Get-MemLabsWindowsClientSetupState
    $systems = @(Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop)
    if ($systems.Count -ne 1) { throw 'The guest computer identity could not be established.' }
    $machineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' `
            -Name MachineGuid -ErrorAction Stop).MachineGuid
    $parsedGuid = [guid]::Empty
    if ($machineGuid -isnot [string] -or -not [guid]::TryParse($machineGuid, [ref]$parsedGuid)) {
        throw 'The guest machine GUID is unavailable.'
    }
    $policies = foreach ($target in Get-MemLabsOobeRepairPolicyTargets) {
        $present = $false; $kind = $null; $value = $null
        if (Test-Path -LiteralPath $target.Path -ErrorAction Stop) {
            $key = Get-Item -LiteralPath $target.Path -ErrorAction Stop
            try {
                $present = $target.Name -in $key.GetValueNames()
                if ($present) {
                    $kind = "$($key.GetValueKind($target.Name))"
                    $value = $key.GetValue($target.Name, $null,
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
            }
            finally { $key.Dispose() }
        }
        [pscustomobject]@{ Path = $target.Path; Name = $target.Name; Present = $present; Kind = $kind; Value = $value }
    }
    $service = Get-Service -Name wuauserv -ErrorAction Stop
    $startup = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' `
            -Name Start -ErrorAction Stop).Start
    [pscustomobject]@{
        Version = 1; Scope = 'OobeOnly'; MachineGuid = $machineGuid
        Elevated = (Test-MemLabsOobeRepairElevation)
        Setup = $setup; ComputerName = $systems[0].Name
        Domain = $systems[0].Domain; PartOfDomain = $systems[0].PartOfDomain
        Policies = @($policies); ServiceStartup = $startup; ServiceStatus = "$($service.Status)"
        IdentityRepairPerformed = $false
    }
}

function Assert-MemLabsOobeRepairSnapshot {
    param([Parameter(Mandatory)]$Snapshot, [switch]$AllowTransientService)

    $allowedStatuses = @('Running', 'Stopped')
    if ($AllowTransientService) { $allowedStatuses += @('StartPending', 'StopPending') }
    if ($Snapshot.Version -isnot [int] -or $Snapshot.Version -ne 1 -or $Snapshot.Scope -ne 'OobeOnly' -or
        $Snapshot.Elevated -isnot [bool] -or -not $Snapshot.Elevated -or
        $Snapshot.Setup.ProductType -isnot [int] -or $Snapshot.Setup.ProductType -ne 1 -or
        $Snapshot.Setup.Required -isnot [bool] -or -not $Snapshot.Setup.Required -or
        $Snapshot.ServiceStartup -isnot [int] -or $Snapshot.ServiceStartup -notin @(2, 3, 4) -or
        $Snapshot.ServiceStatus -notin $allowedStatuses) {
        throw 'Invalid or unelevated Windows-client repair snapshot.'
    }
    $parsedGuid = [guid]::Empty
    if ($Snapshot.MachineGuid -isnot [string] -or -not [guid]::TryParse($Snapshot.MachineGuid, [ref]$parsedGuid)) {
        throw 'Invalid repair snapshot machine GUID.'
    }
    $records = @($Snapshot.Policies)
    if ($records.Count -ne 3) { throw 'The repair snapshot must cover exactly the three allowed update policies.' }
    foreach ($target in Get-MemLabsOobeRepairPolicyTargets) {
        $policyMatches = @($records | Where-Object { $_.Path -eq $target.Path -and $_.Name -eq $target.Name })
        if ($policyMatches.Count -ne 1 -or $policyMatches[0].Present -isnot [bool]) { throw 'Invalid or duplicate update policy snapshot.' }
        $record = $policyMatches[0]
        if ($record.Present -and ($record.Kind -ne 'DWord' -or
                ($record.Value -isnot [int] -and $record.Value -isnot [uint32]) -or $record.Value -notin @(0, 1))) {
            throw "Unexpected policy type/value; refusing to change $($record.Name)."
        }
        if (-not $record.Present -and ($null -ne $record.Kind -or $null -ne $record.Value)) {
            throw 'An absent policy has inconsistent snapshot data.'
        }
    }
}

function Invoke-MemLabsWindowsOobeRecovery {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateSet('Inspect', 'Probe', 'Apply', 'Restore')][string]$Action,
        $Snapshot
    )

    $current = Get-MemLabsOobeRepairGuestState
    if ($Action -in @('Inspect', 'Probe')) { return $current }
    Assert-MemLabsOobeRepairSnapshot -Snapshot $Snapshot
    Assert-MemLabsOobeRepairSnapshot -Snapshot $current -AllowTransientService:($Action -eq 'Restore')
    if ($current.MachineGuid -ne $Snapshot.MachineGuid) { throw 'The guest identity changed; refusing repair/restoration.' }
    if (-not $PSCmdlet.ShouldProcess($current.ComputerName, "$Action the scoped OOBE Windows Update access trial")) { return }

    if ($Action -eq 'Apply') {
        if ($current.Setup.Ready -isnot [bool] -or $current.Setup.Ready -or
            $current.Setup.Reason -eq 'ProbeFailed' -or $current.Setup.OOBEInProgress -ne 1 -or
            $current.Setup.SystemSetupInProgress -ne 0 -or $current.Setup.SetupType -ne 2) {
            throw 'This trial requires readable, actively incomplete client OOBE; setup flags will not be bypassed.'
        }
        foreach ($record in $Snapshot.Policies) {
            $live = @($current.Policies | Where-Object { $_.Path -eq $record.Path -and $_.Name -eq $record.Name })[0]
            if ($live.Present -ne $record.Present -or $live.Kind -ne $record.Kind -or $live.Value -ne $record.Value) {
                throw "Policy $($record.Name) changed after inspection; no repair was started."
            }
        }
        if ($current.ServiceStartup -ne $Snapshot.ServiceStartup) { throw 'The update service startup policy changed after inspection.' }
        $blocked = @($Snapshot.Policies | Where-Object { $_.Present -and $_.Value -eq 1 })
        if ($blocked.Count -eq 0 -and $current.ServiceStartup -ne 4 -and $current.ServiceStatus -eq 'Running') {
            throw 'No known update-access blocker is present. No speculative OOBE repair was performed.'
        }
        try {
            foreach ($record in $blocked) {
                Remove-ItemProperty -LiteralPath $record.Path -Name $record.Name -ErrorAction Stop
            }
            if ($Snapshot.ServiceStartup -eq 4) {
                Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
            }
            $service = Get-Service -Name wuauserv -ErrorAction Stop
            if ("$($service.Status)" -ne 'Running') {
                Start-Service -Name wuauserv -ErrorAction Stop
                $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(10))
            }
            $after = Get-MemLabsOobeRepairGuestState
            foreach ($record in $blocked) {
                $live = @($after.Policies | Where-Object { $_.Path -eq $record.Path -and $_.Name -eq $record.Name })[0]
                if ($live.Present) { throw "Policy $($record.Name) was not cleared or was immediately reapplied." }
            }
            if ($after.ServiceStatus -ne 'Running') { throw 'The Windows Update service did not reach Running.' }
            return [pscustomobject]@{
                Version = 1; Status = 'Applied'; Scope = 'OobeOnly'; MachineGuid = $current.MachineGuid
                ClearedPolicies = @($blocked.Name); IdentityRepairPerformed = $false
            }
        }
        catch {
            $applyError = $_.Exception.Message
            try { $null = Invoke-MemLabsWindowsOobeRecovery -Action Restore -Snapshot $Snapshot -Confirm:$false }
            catch { throw "OOBE trial failed: $applyError Restoration also failed: $($_.Exception.Message)" }
            throw "OOBE trial failed and original settings were restored: $applyError"
        }
    }

    foreach ($record in $Snapshot.Policies | Where-Object { $_.Present -and $_.Value -eq 1 }) {
        $live = @($current.Policies | Where-Object { $_.Path -eq $record.Path -and $_.Name -eq $record.Name })[0]
        if ($live.Present) {
            if ($live.Kind -ne $record.Kind -or $live.Value -ne $record.Value) {
                throw "Policy $($record.Name) changed outside the trial; refusing to overwrite it."
            }
        }
        else {
            $null = New-Item -Path $record.Path -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $record.Path -Name $record.Name `
                -PropertyType DWord -Value $record.Value -Force -ErrorAction Stop
        }
    }
    $service = Get-Service -Name wuauserv -ErrorAction Stop
    if ($Snapshot.ServiceStatus -eq 'Stopped' -and "$($service.Status)" -ne 'Stopped') {
        Stop-Service -Name wuauserv -ErrorAction Stop
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
    }
    if ($Snapshot.ServiceStartup -eq 4 -and $current.ServiceStartup -eq 3) {
        Set-Service -Name wuauserv -StartupType Disabled -ErrorAction Stop
    }
    elseif ($current.ServiceStartup -ne $Snapshot.ServiceStartup) {
        throw 'The update service startup policy changed outside the trial; refusing to overwrite it.'
    }
    $after = Get-MemLabsOobeRepairGuestState
    foreach ($record in $Snapshot.Policies | Where-Object { $_.Present -and $_.Value -eq 1 }) {
        $live = @($after.Policies | Where-Object { $_.Path -eq $record.Path -and $_.Name -eq $record.Name })[0]
        if (-not $live.Present -or $live.Kind -ne $record.Kind -or $live.Value -ne $record.Value) {
            throw "Restoration of policy $($record.Name) could not be verified."
        }
    }
    if ($after.ServiceStartup -ne $Snapshot.ServiceStartup -or
        ($Snapshot.ServiceStatus -eq 'Stopped' -and $after.ServiceStatus -ne 'Stopped')) {
        throw 'Original update service settings could not be verified after restoration.'
    }
    return [pscustomobject]@{
        Version = 1; Status = 'Restored'; Scope = 'OobeOnly'; MachineGuid = $current.MachineGuid
        IdentityRepairPerformed = $false
    }
}
