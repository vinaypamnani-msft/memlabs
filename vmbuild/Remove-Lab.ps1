[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, ParameterSetName = "Domain")]
    [Parameter(Mandatory = $false, ParameterSetName = "InProgress")]
    [string] $DomainName,
    [Parameter(Mandatory = $true, ParameterSetName = "Orphaned")]
    [switch] $Orphaned,
    [Parameter(Mandatory = $true, ParameterSetName = "InProgress")]
    [switch] $InProgress,
    [Parameter(Mandatory = $true, ParameterSetName = "VmName")]
    [string] $VmName,
    [Parameter(Mandatory = $true, ParameterSetName = "All")]
    [switch] $All,
    [Parameter()]
    [switch] $WhatIf
)

# Tell common to re-init
if ($Common.Initialized) {
    $Common.Initialized = $false
}

# Dot source common
. $PSScriptRoot\Common.ps1

function Remove-VirtualMachine {
    param (
        [Parameter()]
        [string] $VmName
    )

    $vmTest = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vmTest) {
        Write-Log "Remove-Lab: VM '$VmName' exists. Removing." -SubActivity -HostOnly
        if ($vmTest.State -ne "Off") {
            $vmTest | Stop-VM -TurnOff -Force -WhatIf:$WhatIf
        }
        $vmTest | Remove-VM -Force -WhatIf:$WhatIf
        Write-Log "Remove-Lab: $VmName`: Purging $($vmTest.Path) folder..." -HostOnly
        Remove-Item -Path $($vmTest.Path) -Force -Recurse -WhatIf:$WhatIf
    }
}

function Remove-DhcpScope {
    param (
        [Parameter()]
        [string] $ScopeId
    )

    $dhcpScope = Get-DhcpServerv4Scope -ScopeID $ScopeId -ErrorAction SilentlyContinue
    if ($dhcpScope) {
        Write-Log "Remove-Lab: DHCP Scope '$ScopeId' exists. Removing." -SubActivity -HostOnly
        $dhcpScope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
    }
}

if ($Orphaned.IsPresent) {
    Write-Log "Main: Remove Lab called for Orphaned objects." -Activity -HostOnly
    $virtualMachines = Get-List -Type VM
    foreach ($vm in $virtualMachines) {

        if (-not $vm.Domain) {
            # Prompt for delete, likely no json object in vm notes
            Write-Host
            $response = Read-Host -Prompt "VM $($vm.VmName) may be orphaned. Delete? [y/N]"
            if ($response.ToLowerInvariant() -eq "y") {
                Remove-VirtualMachine -VmName $vm.VmName
            }
        }
        else {
            if ($null -ne $vm.success -and $vm.success -eq $false) {
                Remove-VirtualMachine -VmName $vm.VmName
            }
        }
    }

    # Loop through vm's again (in case some were deleted)
    $vmNetworksInUse = @()
    foreach ($vm in (Get-VM)) {
        $vmnet = Get-VMNetworkAdapter -VmName $vm.Name
        $vmNetworksInUse += $vmnet.SwitchName
    }

    $scopes = Get-DhcpServerv4Scope
    foreach ($scope in $scopes) {
        $scopeId = $scope.ScopeId.IPAddressToString
        if ($vmNetworksInUse -notcontains $scopeId) {
            Write-Host
            $response = Read-Host -Prompt "DHCP Scope '$scopeId' may be orphaned. Delete? [y/N]"
            if ($response.ToLowerInvariant() -eq "y") {
                Remove-DhcpScope -ScopeId $scopeId
            }
        }
    }

    Write-Host
    return
}

if ($InProgress.IsPresent) {

    Write-Log "Main: Remove Lab called for InProgress objects." -Activity -HostOnly

    if ($DomainName) {
        $virtualMachines = Get-List -Type VM -DomainName $DomainName
    }
    else {
        $virtualMachines = Get-List -Type VM
    }
    foreach ($vm in $virtualMachines) {
        if ($vm.inProgress) {
            Remove-VirtualMachine -VmName $vm.VmName
        }
    }

    Write-Host
    return
}

if ($VmName.IsPresent) {
    Write-Log "Main: Remove Lab called for VM $VmName." -Activity -HostOnly
    $vmTest = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vmTest) {
        Remove-VirtualMachine -VmName $VmName
    }

    Write-Host
    return
}

if ($All.IsPresent) {
    Write-Log "Main: Remove Lab called for 'ALL' VM's." -Activity -HostOnly
    $vmsToDelete = Get-List -Type VM
    $scopesToDelete = Get-SubnetList
}


if ($DomainName.IsPresent) {
    Write-Log "Main: Remove Lab called for '$DomainName' domain." -Activity -HostOnly
    $vmsToDelete = Get-List -Type VM -DomainName $DomainName
    $scopesToDelete = Get-SubnetList -DomainName $DomainName
}

if ($vmsToDelete) {
    foreach ($vm in $vmsToDelete) {
        Remove-VirtualMachine -VmName $vm.VmName
    }
}

if ($scopesToDelete) {
    foreach ($scope in $scopesToDelete) {
        Remove-DhcpScope -ScopeId $scope.Subnet
    }
}

Write-Host