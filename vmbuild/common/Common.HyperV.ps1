function Install-HyperV {
    if ((get-windowsFeature -name Hyper-V).InstallState -ne 'Installed') {  

        Install-WindowsFeature -Name 'Hyper-V', 'Hyper-V-Tools', 'Hyper-V-PowerShell' -IncludeAllSubFeature -IncludeManagementTools

        Install-WindowsFeature -Name 'DHCP', 'RSAT-DHCP' -IncludeAllSubFeature -IncludeManagementTools

        if ((get-windowsFeature -name Hyper-V).InstallState -eq 'Installed') {
            Write-Log "Hyper-V and management tools installed successfully." -Success
        }
        else {
            Write-Log "Failed to install Hyper-V and management tools." -Failure
        }
    }

    if ((get-service -name vmms).Status -ne "Running") {
        Start-Service vmms
        if ((get-service -name vmms).Status -eq "Running") {
            Write-Log "Hyper-V Virtual Machine Management Service started successfully." -Success
        }
        else {
            Write-Log "Failed to start Hyper-V Virtual Machine Management Service." -Failure
        }
    }
}

function Get-VM2 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Fallback
    )

    $vmFromList = Get-List -Type VM | Where-Object { $_.vmName -eq $Name }

    if ($vmFromList) {
        return (Get-VM -Id $vmFromList.vmId)
    }
    else {
        $vmFromList = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $Name }
        if ($vmFromList) {
            return (Get-VM -Id $vmFromList.vmId)
        }
        else {
            # VM may exist, without vmNotes object, try fallback if caller explicitly wants it.
            if ($Fallback.IsPresent) {
                return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
            }

            return [System.Management.Automation.Internal.AutomationNull]::Value
        }
    }
}

function Get-VMSwitch2 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$NetworkName
    )

    return (Get-VMSwitch -SwitchType Internal | Where-Object { $_.Name -like "*$NetworkName*" })
}

function Remove-VMSwitch2 {
    param (
        [Parameter(Mandatory = $true)]
        [string] $NetworkName,
        [Parameter()]
        [switch] $WhatIf
    )
    try {
        $switch = Get-VMSwitch2 -NetworkName $NetworkName
        if ($switch) {
            Write-Log "Hyper-V VM Switch '$($switch.Name)' exists. Removing." -SubActivity
            $switch | Remove-VMSwitch -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }
    }
    catch {
        # We tried..
    }
}

function Start-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Passthru,
        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 1,
        [Parameter(Mandatory = $false)]
        [int]$RetrySeconds = 60
    )

    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'SilentlyContinue'
    try {
        $vm = Get-VM2 -Name $Name -Fallback

        if ($vm.State -eq "Running") {
            Write-Log "${Name}: VM is already running." -LogOnly
            if ($Passthru) {
                return $true
            }
            return
        }

        if ($vm) {
            $i = 0
            $running = $false
            do {
                $i++
                if ($i -gt 1) {
                    write-progress2 "Start VM" -Status "Retry Start VM $Name"  -force
                    Start-Sleep -Seconds $RetrySeconds
                }
                else {
                    write-progress2 "Start VM" -Status "Starting VM $Name"  -force
                }
                $StopError = $null
                Start-VM -VM $vm -ErrorVariable StopError -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                if (($StopError -ne $null) -and ($StopError.Exception.Message.contains("authentication tag"))) {
                    write-progress2 "Start VM" -Status "Removing saved state for $Name"  -force
                    try {
                        Remove-VMSavedState -vm $vm -ErrorAction Stop
                    }
                    catch {
                        start-sleep -seconds 3
                        Remove-VMSavedState -vm $vm -ErrorAction SilentlyContinue 

                        stop-vm -vm $vm -TurnOff -force:$true -WarningAction SilentlyContinue   
                        start-sleep -seconds 3
                        Remove-VMSavedState -vm $vm -ErrorAction SilentlyContinue 
                    }                                        
                    Start-VM -VM $vm -ErrorVariable StopError -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
                $vm = Get-VM2 -Name $Name -Fallback
                if ($vm.State -eq "Running") {
                    $running = $true
                }
            }

            until ($i -gt $retryCount -or $running)

            if ($running) {
                Write-Log "${Name}: VM was started." -LogOnly
                if ($Passthru.IsPresent) {
                    return $true
                }
            }

            if ($StopError.Count -ne 0) {
                Write-Log "${Name}: Failed to start the VM. $StopError" -Warning
                if ($Passthru.IsPresent) {
                    return $false
                }
            }
            else {
                $vm = Get-VM2 -Name $Name -Fallback
                if ($vm.State -eq "Running") {
                    Write-Log "${Name}: VM was started." -LogOnly
                    if ($Passthru.IsPresent) {
                        return $true
                    }
                }
                else {
                    Write-Log "${Name}: VM was not started. Current State $($vm.State)" -Warning
                    if ($Passthru.IsPresent) {
                        return $false
                    }
                }
            }
        }
        else {
            Write-Log "$Name`: VM was not found in Hyper-V." -Warning
            if ($Passthru.IsPresent) {
                return $false
            }
        }
    }
    catch {
        Write-Exception -ExceptionInfo $_
    }
    finally {
        write-progress2 "Start VM" -Status "Started VM $Name" -force -Completed
        $Global:ProgressPreference = $OriginalProgressPreference
    }
}
function Test-VmResponsive {
    param(
        [string]$VmName,
        [int]$TimeoutSeconds = 30
    )
    
    try {
        # Check if VM is running
        $vm = Get-VM2 -Name $VmName -ErrorAction Stop
        if ($vm.State -ne 'Running') {
            Write-Log "VM $VmName is not running (State: $($vm.State))" -Warning
            return $false
        }
        
        # Test heartbeat integration service
        $heartbeat = $vm | Get-VMIntegrationService | Where-Object { $_.Name -eq 'Heartbeat' }
        if ($heartbeat -and $heartbeat.Enabled -and $heartbeat.PrimaryStatusDescription -ne 'OK') {
            Write-Log "VM $VmName heartbeat status: $($heartbeat.PrimaryStatusDescription)" -Warning
            return $false
        }
        
        # Test basic ping with timeout
        $pingTest = Test-Connection -ComputerName $VmName -Count 2 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingTest) {
            Write-Log "VM $VmName not responding to ping" -Warning
            return $false
        }
        
        # Test RDP port with timeout using job
        $job = Start-Job -ScriptBlock {
            param($computerName)
            Test-NetConnection -ComputerName $computerName -Port 3389 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationLevel Quiet
        } -ArgumentList $VmName
        
        $testNet = Wait-Job -Job $job -Timeout $TimeoutSeconds | Receive-Job
        Remove-Job -Job $job -Force
        
        if ($null -eq $testNet -or -not $testNet) {
            Write-Log "VM $VmName RDP port test failed or timed out" -Warning
            return $false
        }
        
        return $true
    }
    catch {
        Write-Log "Error testing VM $VmName responsiveness: $_" -Warning
        return $false
    }
}

function Restart-UnresponsiveVm {
    param(
        [string]$VmName,
        [int]$MaxRetries = 2,
        [int]$WaitTimeSeconds = 60
    )
    
    Write-Log "Attempting to restart unresponsive VM: $VmName" -Warning
    
    try {
        # Try graceful shutdown first
        Write-Log "Attempting graceful shutdown of $VmName..."
        Stop-VM2 -Name $VmName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Start-Sleep -Seconds 10
        
        # Force stop if still running
        $vm = Get-VM2 -Name $VmName
        if ($vm.State -ne 'Off') {
            Write-Log "Forcing stop of $VmName..."
            Stop-VM2 -Name $VmName -Force -TurnOff
            Start-Sleep -Seconds 5
        }
        
        # Start the VM
        Write-Log "Starting $VmName..."
        Start-VM2 -Name $VmName
        
        # Wait for VM to boot and become responsive
        Write-Log "Waiting for $VmName to become responsive (up to $WaitTimeSeconds seconds)..."
        $startTime = Get-Date
        $isResponsive = $false
        
        while (((Get-Date) - $startTime).TotalSeconds -lt $WaitTimeSeconds) {
            Start-Sleep -Seconds 10
            
            if (Test-VmResponsive -VmName $VmName -TimeoutSeconds 15) {
                $isResponsive = $true
                Write-Log "$VmName is now responsive"
                break
            }
            
            Write-Log "Still waiting for $VmName to respond..."
        }
        
        return $isResponsive
    }
    catch {
        Write-Log "Error restarting VM ${VmName}: $_" -Error
        return $false
    }
}

function Stop-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Passthru,
        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 1,
        [Parameter(Mandatory = $false)]
        [int]$RetrySeconds = 10,
        [Parameter(Mandatory = $false)]
        [switch]$TurnOff
    )

    try {
        $force = $true
        $vm = Get-VM2 -Name $Name -Fallback

        if ($vm.State -eq "Off") {
            Write-Log "${Name}: VM is already stopped." -LogOnly
            if ($Passthru) {
                return $true
            }
            return
        }

        Write-Log "${Name}: Stopping VM" -LogOnly

        if ($vm) {
            $i = 0
            if ($TurnOff) {
                Stop-VM -VM $vm -TurnOff -force:$force -WarningAction SilentlyContinue
                start-sleep -seconds 5
            }
            do {
                $i++
                if ($i -gt 1) {
                    Start-Sleep -Seconds $RetrySeconds
                }
                Stop-VM -VM $vm -force:$force -ErrorVariable StopError -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            }
            until ($i -gt $retryCount -or $StopError.Count -eq 0)

            if ($StopError.Count -ne 0) {
                
                Stop-VM -VM $vm -TurnOff -force:$true -WarningAction SilentlyContinue
                Start-Sleep -Seconds $RetrySeconds
                $vm = Get-VM2 -Name $Name -Fallback
                if ($vm.State -eq "Off") {
                    return $true
                }
                
                Write-Log "${Name}: Failed to stop the VM. $StopError" -Warning
                
                if ($Passthru.IsPresent) {
                    return $false
                }
            }
            else {
                if ($Passthru.IsPresent) {
                    return $true
                }
            }
        }
        else {
            if ($Passthru.IsPresent) {
                Write-Log "$Name`: VM was not found in Hyper-V." -Warning
                return $false
            }
        }
    }
    catch {
        if ($Passthru) {
            Write-Log "$Name`: Exception stopping VM $_" -Failure
            return $false
        }
        else {
            Write-Log "$Name`: Exception stopping VM $_" -Failure -LogOnly
        }
    }
}


function Get-VMCheckpoint2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $false)]
        [string]$Name
    )

    $vm = Get-VM2 -Name $VMName -Fallback

    if ($vm) {
        if ($name) {
            return Get-VMCheckpoint -VM $vm -Name $Name -ErrorAction SilentlyContinue
        }
        else {
            return Get-VMCheckpoint -VM $vm  -ErrorAction SilentlyContinue
        }
    }
    return [System.Management.Automation.Internal.AutomationNull]::Value
}

function Remove-VMCheckpoint2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $vm = Get-VM2 -Name $VMName -Fallback

    if ($vm) {
        return Remove-VMCheckpoint -VM $vm -Name $Name -ErrorAction SilentlyContinue
    }
    return [System.Management.Automation.Internal.AutomationNull]::Value
}

function Checkpoint-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$SnapshotName
    )

    $vm = Get-VM2 -Name $Name -Fallback

    if ($vm) {
        $json = $SnapshotName + ".json"
        $notesFile = Join-Path ($vm).Path $json
        $vm.notes | Out-File $notesFile
        try {
            Checkpoint-VM -VM $vm -SnapshotName $SnapshotName -ErrorAction Stop
        }
        catch {
            start-sleep -Seconds 20
            $snapshots = Get-VMSnapshot -VM $vm
            foreach ($snapshot in $snapshots) {
                if ($snapshot.Name -eq $SnapshotName) {
                    return [System.Management.Automation.Internal.AutomationNull]::Value
                }
            }
            throw
        }
    }
    return [System.Management.Automation.Internal.AutomationNull]::Value
}