function Get-VM2 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $vmFromList = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $Name }

    if ($vmFromList) {
        return (Get-VM -Id $vmFromList.vmId)
    }
    else {
        return [System.Management.Automation.Internal.AutomationNull]::Value
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
        [int]$RetryCount = 0,
        [Parameter(Mandatory = $false)]
        [int]$RetrySeconds = 0
    )

    $vm = Get-VM2 -Name $Name

    if ($vm) {
        $i = 0
        do {
            $i++
            Start-VM -VM $vm -ErrorVariable StopError -ErrorAction SilentlyContinue
            Start-Sleep -Seconds $RetrySeconds
        }
        until ($i -gt $retryCount -or $StopError.Count -eq 0)

        if ($StopError.Count -ne 0) {
            Write-Log "${$vm}: Failed to start the VM. $StopError" -Warning
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
function Stop-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Passthru,
        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 0,
        [Parameter(Mandatory = $false)]
        [int]$RetrySeconds = 0,
        [Parameter(Mandatory = $false)]
        [switch]$force
    )

    $vm = Get-VM2 -Name $Name
    write-host "stopping ${$Name}"
    if ($vm) {
        $i = 0
        do {
            $i++
            write-host "stopping ${$vm.Name}"
            Stop-VM -VM $vm -force:$force -ErrorVariable StopError -ErrorAction SilentlyContinue
            Start-Sleep -Seconds $RetrySeconds
        }
        until ($i -gt $retryCount -or $StopError.Count -eq 0)

        if ($StopError.Count -ne 0) {
            Write-Log "${$vm}: Failed to stop the VM. $StopError" -Warning
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
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $vm = Get-VM2 -Name $VMName

    if ($vm) {
        return Get-VMCheckpoint -VM $vm -Name $Name -ErrorAction SilentlyContinue
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