########################
### Remove Functions ###
########################

function Remove-VirtualMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string] $VmName,
        [Parameter()]
        [switch] $WhatIf
    )
    #{ "network": "10.0.1.0", "ClusterIPAddress": "10.250.250.135", "AGIPAddress": "10.250.250.136",
    $vmFromList = Get-List -Type VM | Where-Object { $_.vmName -eq $VmName }
    if ($vmFromList.vmBuild -eq $false) {
        Write-Log "VM '$VmName' exists, but it was not deployed via MemLabs. Skipping." -SubActivity
        return
    }

    $vmTest = Get-VM2 -Name $VmName -Fallback

    if ($vmTest) {
        Write-Log "VM '$VmName' exists. Removing." -SubActivity

        if ($vmFromList.ClusterIPAddress) {
            Write-Log "$VmName`: Removing $($vmFromList.ClusterIPAddress) Exclusion..." -HostOnly
            Remove-DhcpServerv4ExclusionRange -ScopeId 10.250.250.0 -StartRange $vmFromList.ClusterIPAddress -EndRange $vmFromList.ClusterIPAddress -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }

        if ($vmFromList.AGIPAddress) {
            Write-Log "$VmName`: Removing $($vmFromList.AGIPAddress) Exclusion..." -HostOnly
            Remove-DhcpServerv4ExclusionRange -ScopeId 10.250.250.0 -StartRange $vmFromList.AGIPAddress -EndRange $vmFromList.AGIPAddress -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }

        $adapters = $vmTest  | Get-VMNetworkAdapter
        foreach ($adapter in $adapters) {
            if ($adapter.SwitchName -eq "cluster") {
                Remove-DhcpServerv4Reservation  -ScopeId 10.250.250.0 -ClientId $adapter.MacAddress -ErrorAction SilentlyContinue -WhatIf:$WhatIf
                Write-Log "$VmName`: Removing DHCP Reservation on cluster network..." -HostOnly
            }
            else {
                Remove-DhcpServerv4Reservation  -ScopeId $vmFromList.Network -ClientId $adapter.MacAddress -ErrorAction SilentlyContinue -WhatIf:$WhatIf

            }
        }

        if ($vmTest.State -ne "Off") {
            $vmTest | Stop-VM -TurnOff -Force -WhatIf:$WhatIf
        }

        $cachediskFile = Join-Path $global:common.CachePath ($($vm.vmID).toString() + ".disk.json")
        if (Test-Path $cachediskFile) { Remove-Item -path $cachediskFile -Force -WhatIf:$WhatIf | Out-Null }

        $cachenetFile = Join-Path $global:common.CachePath ($($vm.vmID).toString() + ".network.json")
        if (Test-Path $cachenetFile) { Remove-Item -path $cachenetFile -Force -WhatIf:$WhatIf | Out-Null }

        $vmTest | Remove-VM -Force -WhatIf:$WhatIf

        Write-Log "$VmName`: Purging $($vmTest.Path) folder..." -HostOnly
        Remove-Item -Path $($vmTest.Path) -Force -Recurse -WhatIf:$WhatIf
    }
    else {
        Write-Log "VM '$VmName' does not exist in Hyper-V." -SubActivity
    }
}

function Remove-DhcpScope {
    param (
        [Parameter(Mandatory = $true)]
        [string] $ScopeId,
        [Parameter()]
        [switch] $WhatIf
    )

    if ($ScopeId -eq "Internet") {
        $ScopeId = "172.31.250.0"
    }
    if ($ScopeId -eq "cluster") {
        $ScopeId = "10.250.250.0"
    }

    $dhcpScope = Get-DhcpServerv4Scope -ScopeID $ScopeId -ErrorAction SilentlyContinue
    if ($dhcpScope) {
        Write-Log "DHCP Scope '$($dhcpScope.Name)' exists. Removing." -SubActivity
        $dhcpScope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
    }
}

function Remove-Orphaned {

    param (
        [Parameter()]
        [switch] $WhatIf
    )

    Write-Log "Detecting orphaned Virtual Machines" -Activity
    $virtualMachines = Get-List -Type VM -SmartUpdate
    foreach ($vm in $virtualMachines) {

        if (-not $vm.Domain) {
            # Prompt for delete, likely no json object in vm notes
            Write-Host
            $response = Read-Host -Prompt "VM $($vm.VmName) may be orphaned. Delete? [y/N]"
            if ($response.ToLowerInvariant() -eq "y") {
                Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
            }
        }
        else {
            if ($null -ne $vm.success -and $vm.success -eq $false) {
                Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
            }
        }
    }

    # Loop through vm's again (in case some were deleted above)
    $vmNetworksInUse = Get-List -Type UniqueSubnet -SmartUpdate
    $vmNetworksInUse2 = $vmNetworksInUse -replace "Internet", "172.31.250.0"

    Write-Log "Detecting orphaned DHCP Scopes" -Activity
    $scopes = Get-DhcpServerv4Scope
    foreach ($scope in $scopes) {
        $scopeId = $scope.ScopeId.IPAddressToString # This requires us to replace "Internet" with subnet
        if ($vmNetworksInUse2 -notcontains $scopeId) {
            Write-Host
            $response = Read-Host -Prompt "DHCP Scope '$($scope.Name)' may be orphaned. Delete DHCP Scope? [y/N]"
            if ($response.ToLowerInvariant() -eq "y") {
                Remove-DhcpScope -ScopeId $scopeId -WhatIf:$WhatIf
            }
        }
    }

    Write-Log "Detecting orphaned Hyper-V Switches" -Activity
    $switches = Get-VMSwitch -SwitchType Internal
    foreach ($switch in $switches) {
        $inUse = $false
        foreach ($network in $vmNetworksInUse) {
            if ($switch.Name -like "*$network*") {
                $inUse = $true
                break
            }
        }

        if (-not $inUse) {
            Write-Host
            $response = Read-Host -Prompt "Hyper-V Switch '$($switch.Name)' may be orphaned. Delete Switch? [y/N]"
            if ($response.ToLowerInvariant() -eq "y") {
                Remove-VMSwitch2 -NetworkName $switch.Name
            }
        }
    }

    Write-Host
}

function Remove-InProgress {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter()]
        [switch] $WhatIf
    )

    Write-Log "Removing In-Progress Virtual Machines" -Activity

    if ($DomainName) {
        $virtualMachines = Get-List -Type VM -DomainName $DomainName
    }
    else {
        $virtualMachines = Get-List -Type VM
    }

    foreach ($vm in $virtualMachines) {
        if ($vm.inProgress) {
            Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
        }
    }

    Write-Host
}

function Remove-Domain {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter()]
        [switch] $WhatIf
    )

    Write-Log "Removing virtual machines for '$DomainName' domain." -Activity
    $vmsToDelete = Get-List -Type VM -DomainName $DomainName
    $scopesToDelete = Get-List -Type UniqueSubnet -DomainName $DomainName | Where-Object { $_ -ne "Internet" } # Internet subnet could be shared between multiple domains

    if ($vmsToDelete) {
        foreach ($vm in $vmsToDelete) {
            Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
        }
    }

    if ($scopesToDelete) {
        Write-Log "Removing ALL DHCP Scopes for '$DomainName'" -Activity
        foreach ($scope in $scopesToDelete) {
            Remove-DhcpScope -ScopeId $scope -WhatIf:$WhatIf
        }

        Write-Log "Removing ALL Hyper-V Switches for '$DomainName'" -Activity
        foreach ($scope in $scopesToDelete) {
            Remove-VMSwitch2 -NetworkName $scope -WhatIf:$WhatIf
        }
    }

    if (-not $WhatIf.IsPresent) {
        New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
    }

    Write-Host

}

function Remove-All {

    param (
        [Parameter()]
        [switch] $WhatIf
    )

    $vmsToDelete = Get-List -Type VM
    $scopesToDelete = Get-List -Type UniqueSubnet -DomainName $DomainName

    if ($vmsToDelete) {
        Write-Log "Removing ALL virtual machines" -Activity
        foreach ($vm in $vmsToDelete) {
            Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
        }
    }

    if ($scopesToDelete) {
        Write-Log "Removing ALL DHCP Scopes" -Activity
        foreach ($scope in $scopesToDelete) {
            Remove-DhcpScope -ScopeId $scope -WhatIf:$WhatIf
        }

        Write-Log "Removing ALL Hyper-V Switches" -Activity
        foreach ($scope in $scopesToDelete) {
            Remove-VMSwitch2 -NetworkName $scope -WhatIf:$WhatIf
        }
    }

    Remove-Orphaned -WhatIf:$WhatIf

    Write-Host

}