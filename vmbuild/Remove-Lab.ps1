[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $DomainName,
    [Parameter()]
    [switch] $WhatIf
)

# Tell common to re-init
if ($Common.Initialized) {
    $Common.Initialized = $false
}

# Dot source common
. $PSScriptRoot\Common.ps1

if ($DomainName) {
    $vmsToDelete = Get-VMList -DomainName $DomainName
    $scopesToDelete = Get-SubnetList -DomainName $DomainName
}
else {
    $vmsToDelete = Get-VMList
    $scopesToDelete = Get-SubnetList -DomainName $DomainName
}

foreach ($vm in $vmsToDelete) {
    $VmName = $vm.VMName
    $vmTest = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vmTest) {
        Write-Log "Remove-Lab: $VmName`: Virtual machine exists.Removing."
        if ($vmTest.State -ne "Off") {
            Write-Log "Remove-Lab: $VmName`: Turning the VM off forcefully..."
            $vmTest | Stop-VM -TurnOff -Force -WhatIf:$WhatIf
        }
        $vmTest | Remove-VM -Force -WhatIf:$WhatIf
        Write-Log "Remove-Lab: $VmName`: Purging $($vmTest.Path) folder..."
        Remove-Item -Path $($vmTest.Path) -Force -Recurse -WhatIf:$WhatIf
        Write-Log "Remove-Lab: $VmName`: Purge complete."
    }
}

foreach ($scope in $scopesToDelete) {
    $scopeId = $scope.Subnet
    $dhcpScope = Get-DhcpServerv4Scope -ScopeID $scopeId -ErrorAction SilentlyContinue
    if ($dhcpScope) {
        Write-Log "Remove-Lab: $scopeId`: Scope exists.Removing."
        $dhcpScope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
    }
}