########################
### Remove Functions ###
########################

function Remove-VirtualMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string] $VmName,
        [Parameter()]
        [switch] $WhatIf,
        [Parameter()]
        [switch] $Force,
        [Parameter()]
        [bool] $Migrate = $false
    )
    #{ "network": "10.0.1.0", "ClusterIPAddress": "10.250.250.135", "AGIPAddress": "10.250.250.136",
    $vmFromList = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VmName }
    if ($vmFromList.vmBuild -eq $false) {
        if (-not ($Force.IsPresent)) {
            Write-Log "VM '$VmName' exists, but it was not deployed via MemLabs. Skipping." -SubActivity
            return
        }
    }

    $vmTest = Get-VM2 -Name $VmName -Fallback

    if ($vmTest) {
        $parent = (get-item $($vmTest.Path)).Parent
        Write-Log "VM '$VmName' exists. Removing." -SubActivity

        if ($vmFromList.ClusterIPAddress) {
            Write-Log "$VmName`: Removing $($vmFromList.ClusterIPAddress) Exclusion..." -HostOnly
            Remove-DhcpServerv4ExclusionRange -ScopeId 10.250.250.0 -StartRange $vmFromList.ClusterIPAddress -EndRange $vmFromList.ClusterIPAddress -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }

        if ($vmFromList.AGIPAddress) {
            Write-Log "$VmName`: Removing $($vmFromList.AGIPAddress) Exclusion..." -HostOnly
            Remove-DhcpServerv4ExclusionRange -ScopeId 10.250.250.0 -StartRange $vmFromList.AGIPAddress -EndRange $vmFromList.AGIPAddress -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }

        $adapters = $vmTest | Get-VMNetworkAdapter
        foreach ($adapter in $adapters) {
            Remove-DHCPReservation -mac $adapter.MacAddress -vmName $currentItem.vmName                        
        }

        if ($vmTest.State -ne "Off") {
            $vmTest | Stop-VM -TurnOff -Force -WhatIf:$WhatIf -WarningAction SilentlyContinue
        }

        $cachediskFile = Join-Path $global:common.CachePath ($($vmTest.vmID).toString() + ".disk.json")
        if (Test-Path $cachediskFile) { Remove-Item -path $cachediskFile -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue| Out-Null }

        $cachenetFile = Join-Path $global:common.CachePath ($($vmTest.vmID).toString() + ".network.json")
        if (Test-Path $cachenetFile) { Remove-Item -path $cachenetFile -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue| Out-Null }

        $vmTest | Remove-VM -Force -WhatIf:$WhatIf
        if (-not $Migrate) {
            Write-Log "$VmName`: Purging $($vmTest.Path) folder..." -HostOnly
            Remove-Item -Path $($vmTest.Path) -Force -Recurse -WhatIf:$WhatIf -ProgressAction SilentlyContinue| Out-Null


            $count = (Get-ChildItem $parent | Measure-Object).Count
            if ($count -eq 0) {
                Remove-Item -Path $parent -ProgressAction SilentlyContinue
            }
        }
    }
    else {
        Write-Log "VM '$VmName' does not exist in Hyper-V." -Warning
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
            $response = Read-YesorNoWithTimeout -Prompt "  VM $($vm.VmName) may be orphaned. Delete? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
            }
        }
        else {
            if ($null -ne $vm.success -and $vm.success -eq $false) {
                Remove-VirtualMachine -VmName $vm.VmName -WhatIf:$WhatIf
            }
        }
        Write-Host
    }

    # Loop through vm's again (in case some were deleted above)
    $vmNetworksInUse = Get-List -Type UniqueSwitch -SmartUpdate
    $vmNetworksInUse2 = $vmNetworksInUse -replace "Internet", "172.31.250.0"

    Write-Log "Detecting orphaned DHCP Scopes" -Activity
    $scopes = Get-DhcpServerv4Scope
    foreach ($scope in $scopes) {
        $scopeId = $scope.ScopeId.ToString() # This requires us to replace "Internet" with subnet
        if ($vmNetworksInUse2 -notcontains $scopeId) {
            $response = Read-YesorNoWithTimeout -Prompt "  DHCP Scope '$($scope.Name) [$($scope.ScopeId)]' may be orphaned. Delete DHCP Scope? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-DhcpScope -ScopeId $scopeId -WhatIf:$WhatIf
            }
            Write-Host
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
            $response = Read-YesorNoWithTimeout -Prompt "  Hyper-V Switch '$($switch.Name)' may be orphaned. Delete Switch? [y/N]" -HideHelp -Default "n"
            if ($response -and $response.ToLowerInvariant() -eq "y") {
                Remove-VMSwitch2 -NetworkName $switch.Name
            }
            Write-Host
        }
    }
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

function Remove-ForestTrust {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter()]
        [switch] $IfBroken,
        [Parameter()]
        [switch] $WhatIf
        
    )    
    $TrustedForests = Get-List -Type ForestTrust | Where-Object { $_.ForestTrust -eq $DomainName -or $_.Domain -eq $DomainName }
    
    if ($TrustedForests) {
        foreach ($TrustedForest in $TrustedForests) {
                        
            $DC1 = get-list -type VM -DomainName $TrustedForest.ForestTrust | Where-Object { $_.Role -eq "DC" }
            $DC2 = get-list -type VM -DomainName $TrustedForest.domain | Where-Object { $_.Role -eq "DC" }

            if ($DC1) {
                $forestDomain = $TrustedForest.ForestTrust
                $domainName = $TrustedForest.domain
                start-vm2 -Name $DC1.vmName

                $scriptBlockTest = {
                    param(
                        [String]$forestDomain,
                        [String]$DomainName,
                        [String]$adminName,
                        [String]$adminName2,
                        [String]$pw
                    )
                    & netdom trust $($forestDomain) /d:$($DomainName) /userD:$adminName /passwordD:$pw /userO:$adminName2 /PasswordO:$pw /verify /twoway
                }
                $result = Invoke-VmCommand -VmName $DC1.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlockTest -ArgumentList @($forestDomain, $domainName, $DC1.AdminName, $DC2.AdminName, $($Common.LocalAdmin.GetNetworkCredential().Password)) -SuppressLog  

                write-host -verbose "Netdom results: $($result.ScriptBlockOutput)"
                if ($result.ScriptBlockOutput -and $result.ScriptBlockOutput -like "*has been successfully verified*") {

                    if ($IfBroken) {
                        Write-GreenCheck "Trust Verified Successfully"
                        return
                    } 
                    else {
                        Write-OrangePoint "Trust Verified Successfully. Deleting Anyway"
                    }
                }
                else {

                    Write-RedX "Trust is not working. Removing."
                    write-log $result.ScriptBlockOutput                
                }

                Write-Log "Removing Trust on $DC1 for '$otherDomain'" -Activity
             
                
                $scriptBlock1 = {
                    param(
                        [String]$forestDomain,
                        [String]$DomainName
                    )
                    write-host "Running on $env:ComputerName as $env:Username"
                    write-host "Netdom trust $forestDomain /Domain:$DomainName /Remove /Force"
                    Netdom trust $forestDomain /Domain:$DomainName /Remove /Force
                }
                $result = Invoke-VmCommand -VmName $DC1.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlock1 -ArgumentList @($forestDomain, $domainName) -SuppressLog
                $result = Invoke-VmCommand -VmName $DC1.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlock1 -ArgumentList @($domainName, $forestDomain) -SuppressLog
                write-log $result.ScriptBlockOutput
            }

            if ($DC2) {
                $forestDomain = $TrustedForest.domain
                $domainName = $TrustedForest.ForestTrust
                Write-Log "Removing Trust on $DC2 for '$otherDomain'" -Activity

                start-vm2 -Name $DC2.vmName
                $scriptBlock1 = {
                    param(
                        [String]$forestDomain,
                        [String]$DomainName
                    )
                    write-host "Running on $env:ComputerName as $env:Username"
                    write-host "Netdom trust $forestDomain /Domain:$DomainName /Remove /Force"
                    Netdom trust $forestDomain /Domain:$DomainName /Remove /Force
                }
                $result = Invoke-VmCommand -VmName $DC2.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlock1 -ArgumentList @($forestDomain, $domainName) -SuppressLog
                $result = Invoke-VmCommand -VmName $DC2.vmName -VmDomainName $forestDomain -ScriptBlock $scriptBlock1 -ArgumentList @($domainName, $forestDomain) -SuppressLog
                write-log $result.ScriptBlockOutput
            }

        }
    }
}

function Remove-Domain {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [object]$VMList,
        [Parameter()]
        [switch] $WhatIf
    )

    $all = $false
    Write-Log "Removing virtual machines for '$DomainName' domain." -Activity
    if ($VMList) {
        $vmsToDelete = Get-List -Type VM -DomainName $DomainName | Where-Object { $_.vmName -in $VMList }
    }
    else {
        $vmsToDelete = Get-List -Type VM -DomainName $DomainName
        $all = $true
    }
    $DC = $vmsToDelete | Where-Object { $_.Role -eq "DC" }

    $scopesToDelete = Get-List -Type UniqueSwitch -DomainName $DomainName | Where-Object { $_ -ne "Internet" -and $_ -ne "Cluster" } # Internet subnet could be shared between multiple domains

    if ($DC) {
        Remove-ForestTrust -DomainName $DomainName
    }
    $DeleteVMs = {
    
        try {
            $global:ScriptBlockName = "Delete Domain"
            # Dot source common
            #try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    
            $rootPath = Split-Path $using:PSScriptRoot -Parent
            . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose -DevBranch:$using:Common.DevBranch

            $currentItem = $using:currentItem
            $Phase = $using:Phase
            $vm = $currentItem
            Remove-VirtualMachine -VmName $vm.VmName
            Write-Log "[Phase $Phase]: $($vm.vmName): Remove VM Successful" -OutputStream -Success
        }
        catch {
            Write-Log "[Phase $Phase]: $($vm.vmName): Failed to delete VM." -OutputStream -Failure
        }
    }


    if ($vmsToDelete) {        
        $start = Start-NormalJobs -machines $vmsToDelete -ScriptBlock $DeleteVMs -Phase "DomainRemove"

        $result = Wait-Phase -Phase "DomainRemove" -Jobs $start.Jobs -AdditionalData $start.AdditionalData           
        
    }


    if ($DC) {
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
    }

    if (-not $WhatIf.IsPresent) {
        Get-List -type VM -SmartUpdate | Out-Null
        New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
        Write-Host
    }
    
    if ($all) {
        if (Test-Path "E:\virtualMachines\$DomainName") {
            Write-Log "Removing $DomainName folder" -SubActivity
            Remove-Item -Path "E:\virtualMachines\$DomainName" -Recurse -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue
        }
    }

    Start-Sleep -seconds 3
    clear-host
}

function Remove-All {

    param (
        [Parameter()]
        [switch] $WhatIf
    )

    $vmsToDelete = Get-List -Type VM
    $scopesToDelete = Get-List -Type UniqueSwitch -DomainName $DomainName

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
    Remove-Item -Path $Global:Common.RdcManFilePath -Force -WhatIf:$WhatIf -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue| Out-Null

    # Get all the folders in E:\VirtualMachines and delete them
    $folders = Get-ChildItem -Path "E:\VirtualMachines" -Directory
    foreach ($folder in $folders) {
        Write-Log "Removing $($folder.Name) folder" -SubActivity
        Remove-Item -Path $folder.FullName -Recurse -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue
    }

    Write-Host

}