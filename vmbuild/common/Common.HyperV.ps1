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

    $switch = Get-VMSwitch2 -NetworkName $NetworkName
    if ($switch) {
        Write-Log "Hyper-V VM Switch '$($switch.Name)' exists. Removing." -SubActivity
        $switch | Remove-VMSwitch -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
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

    $vm = Get-VM2 -Name $Name

    if ($vm) {
        $i = 0

        do {
            $i++
            if ($i -gt 1) {
                Start-Sleep -Seconds $RetrySeconds
            }
            Start-VM -VM $vm -ErrorVariable StopError -ErrorAction SilentlyContinue
        }

        until ($i -gt $retryCount -or $StopError.Count -eq 0)

        if ($StopError.Count -ne 0) {
            Write-Log "${$Name}: Failed to start the VM. $StopError" -Warning
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
        Write-Log "$Name`: VM was not found in Hyper-V." -Warning
        if ($Passthru.IsPresent) {
            return $false
        }
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
        [switch]$force
    )

    $vm = Get-VM2 -Name $Name
    Write-Log "${$Name}: Stopping VM" -HostOnly

    if ($vm) {
        $i = 0

        do {
            $i++
            if ($i -gt 1) {
                Start-Sleep -Seconds $RetrySeconds
            }
            Stop-VM -VM $vm -force:$force -ErrorVariable StopError -ErrorAction SilentlyContinue
        }
        until ($i -gt $retryCount -or $StopError.Count -eq 0)

        if ($StopError.Count -ne 0) {
            Write-Log "${$Name}: Failed to stop the VM. $StopError" -Warning
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


function Get-VMCheckpoint2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $false)]
        [string]$Name
    )

    $vm = Get-VM2 -Name $VMName

    if ($vm) {
        if ($name) {
        return Get-VMCheckpoint -VM $vm -Name $Name -ErrorAction SilentlyContinue
        }
        else{
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

    $vm = Get-VM2 -Name $VMName

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

    $vm = Get-VM2 -Name $Name

    if ($vm) {
        Checkpoint-VM -VM $vm -SnapshotName $SnapshotName -ErrorAction Stop
    }
    return [System.Management.Automation.Internal.AutomationNull]::Value
}