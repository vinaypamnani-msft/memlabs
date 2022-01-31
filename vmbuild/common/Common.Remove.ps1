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

    $vmTest = Get-VM2 -Name $VmName -Fallback
    if ($vmTest) {
        Write-Log "VM '$VmName' exists. Removing." -SubActivity
        if ($vmTest.State -ne "Off") {
            $vmTest | Stop-VM -TurnOff -Force -WhatIf:$WhatIf
        }
        $jsondiskFile = $($vm.vmID).toString() + ".disk.json"
        $cachediskFile = Join-Path $global:common.CachePath $jsondiskFile
        remove-item -path $cachediskFile -Force
        $jsonnetFile = $($vm.vmID).toString() + ".network.json"
        $cachenetFile = Join-Path $global:common.CachePath $jsonnetFile
        remove-item -path $cachenetFile -Force

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

    $dhcpScope = Get-DhcpServerv4Scope -ScopeID $ScopeId -ErrorAction SilentlyContinue
    if ($dhcpScope) {
        Write-Log "DHCP Scope '$ScopeId' exists. Removing." -SubActivity
        $dhcpScope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
    }
}

function Remove-Orphaned {

    param (
        [Parameter()]
        [switch] $WhatIf
    )

    Write-Log "Removing orphaned virtual machines called" -Activity
    $virtualMachines = Get-List -Type VM
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

    # Loop through vm's again (in case some were deleted)
    $vmNetworksInUse = @("172.31.250.0") # add internet subnet
    foreach ($vm in (Get-VM)) {
        $vmnet = ($vm | Get-VMNetworkAdapter)
        $vmNetworksInUse += $vmnet.SwitchName
    }

    $scopes = Get-DhcpServerv4Scope
    foreach ($scope in $scopes) {
        $scopeId = $scope.ScopeId.IPAddressToString
        if ($vmNetworksInUse -notcontains $scopeId) {
            Write-Host
            $response = Read-Host -Prompt "DHCP Scope '$scopeId' may be orphaned. Delete? [y/N]"
            if ($response.ToLowerInvariant() -eq "y") {
                Remove-DhcpScope -ScopeId $scopeId -WhatIf:$WhatIf
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
    $scopesToDelete = Get-SubnetList -DomainName $DomainName

    if ($vmsToDelete) {
        foreach ($vm in $vmsToDelete) {
            Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
        }
    }

    if ($scopesToDelete) {
        foreach ($scope in $scopesToDelete) {
            Remove-DhcpScope -ScopeId $scope.Subnet -WhatIf:$WhatIf
        }
    }
    New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
    Write-Host

}

function Remove-All {

    param (
        [Parameter()]
        [switch] $WhatIf
    )

    Write-Log "Removing ALL virtual machines" -Activity
    $vmsToDelete = Get-List -Type VM
    $scopesToDelete = Get-SubnetList

    if ($vmsToDelete) {
        foreach ($vm in $vmsToDelete) {
            Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
        }
    }

    if ($scopesToDelete) {
        foreach ($scope in $scopesToDelete) {
            Remove-DhcpScope -ScopeId $scope.Subnet -WhatIf:$WhatIf
        }
    }

    Remove-DhcpScope -ScopeId "172.31.250.0" -WhatIf:$WhatIf

    Write-Host

}