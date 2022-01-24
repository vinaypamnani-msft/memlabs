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
        return (Get-VM -Name "blah" -ErrorAction silentlycontinue)
    }
}