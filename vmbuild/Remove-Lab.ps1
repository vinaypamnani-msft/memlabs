[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, ParameterSetName="Domain")]
    [string] $DomainName,
    [Parameter(Mandatory = $true, ParameterSetName="Orphaned")]
    [switch] $Orphaned,
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
        Write-Log "Remove-Lab: $VmName`: Virtual machine exists.Removing." -HostOnly
        if ($vmTest.State -ne "Off") {
            Write-Log "Remove-Lab: $VmName`: Turning the VM off forcefully..." -HostOnly
            $vmTest | Stop-VM -TurnOff -Force -WhatIf:$WhatIf
        }
        $vmTest | Remove-VM -Force -WhatIf:$WhatIf
        Write-Log "Remove-Lab: $VmName`: Purging $($vmTest.Path) folder..." -HostOnly
        Remove-Item -Path $($vmTest.Path) -Force -Recurse -WhatIf:$WhatIf
        Write-Log "Remove-Lab: $VmName`: Purge complete." -HostOnly
    }
}

function Remove-DhcpScope {
    param (
        [Parameter()]
        [string] $ScopeId
    )

    $dhcpScope = Get-DhcpServerv4Scope -ScopeID $ScopeId -ErrorAction SilentlyContinue
    if ($dhcpScope) {
        Write-Log "Remove-Lab: $ScopeId`: Scope exists.Removing." -HostOnly
        $dhcpScope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf
    }
}

if ($Orphaned.IsPresent) {
    $virtualMachines = Get-VM
    foreach($vm in $virtualMachines) {
        $vmNote = $vm.Notes
        $vmNoteObject = $vmNote | ConvertFrom-Json
        if (-not $vmNoteObject) {
            # Prompt for delete
            $response = Read-Host -Prompt "$($vm.Name) may be orphaned. Delete? [y/N]"
            if ($response.ToLowerInvariant() -eq "y") {
                Remove-VirtualMachine -VmName $vm.Name
            }
        }
        else {
            if (-not $vmNoteObject.success) {
                Remove-VirtualMachine -VmName $vm.Name
            }
        }
    }

    # Loop through vm's again (in case some were deleted)
    $vmNetworksInUse = @()
    foreach($vm in (Get-VM)) {
        $vmnet = $vm | Get-VMNetworkAdapter
        $vmNetworksInUse += $vmnet.SwitchName
    }

    $scopes = Get-DhcpServerv4Scope
    foreach($scope in $scopes) {
        $scopeId = $scope.ScopeId.IPAddressToString
        if ($vmNetworksInUse -notcontains $scopeId) {
            $response = Read-Host -Prompt "'$scopeId' may be orphaned. Delete? [y/N]"
            if ($response.ToLowerInvariant() -eq "y") {
                Remove-DhcpScope -ScopeId $scopeId
            }
        }
    }

    return
}

if ($DomainName) {
    $vmsToDelete = Get-VMList -DomainName $DomainName
    $scopesToDelete = Get-SubnetList -DomainName $DomainName
}
else {
    $vmsToDelete = Get-VMList
    $scopesToDelete = Get-SubnetList -DomainName $DomainName
}

foreach ($vm in $vmsToDelete) {
    Remove-VirtualMachine -VmName $vm.VMName
}

foreach ($scope in $scopesToDelete) {
    Remove-DhcpScope -ScopeId $scope.Subnet
}