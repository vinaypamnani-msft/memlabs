function Get-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $vmFromList = Get-List -Type VM | Where-Object { $_.vmName -eq $Name }

    if ($vmFromList) {
        return (Get-VM -Id $vmFromList.vmId)
    }
    else {
        # Update List, and try again
        $vmFromList = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $Name }
        if ($vmFromList) {
            return (Get-VM -Id $vmFromList.vmId)
        }
        return $null

    }
}

function Start-VM2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Passthru
    )

    $vm = Get-VM2 -Name $Name

    if ($vm) {
        try {
            Start-VM -VM $vm -ErrorAction Stop
            if ($Passthru) {
                return $true
            }
        }
        catch {
            Write-Log "$Name`: Failed to start VM. $($_.Exception.Message)" -Failure
            if ($Passthru) {
                return $false
            }
        }
    }
    else {
        if ($Passthru.IsPresent) {
            Write-Log "$Name`: VM was not found in Hyper-V." -Warning
        }
    }
}