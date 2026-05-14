# Displays a Menu based on a property, offers options in [1], [2],[3] format
# With additional options passed in via additionalOptions
function Select-Options {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "MenuName")]
        [string] $MenuName,
        [Parameter(Mandatory = $false, HelpMessage = "Root of Property to Enumerate and automatically display a menu")]
        [object] $Rootproperty,
        [Parameter(Mandatory = $false, HelpMessage = "Property name")]
        [object] $propertyName,
        [Parameter(Mandatory = $false, HelpMessage = "Property to enumerate.. Can be used instead of RootProperty and propertyName")]
        [object] $propertyEnum,
        [Parameter(Mandatory = $false, HelpMessage = "If Property is an array.. find this element to work on (Base = 1).")]
        [object] $propertyNum,
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "Append additional Items to menu.. Eg X = Exit")]
        [PSCustomObject] $additionalOptions,
        [Parameter(Mandatory = $false, HelpMessage = "Let the prompt help show we will continue on enter")]
        [bool] $ContinueMode = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Run a configuration test. Default True")]
        [bool] $Test = $true,
        [string] $HelpFunction = $null
    )

    $property = $null
    $newName = $null
    :MainLoop
    while ($true) {
        $MenuItems = [System.Collections.ArrayList]@()
        if ($null -eq $property -and $null -ne $Rootproperty) {
            $property = $Rootproperty."$propertyName"
        }

        if ($null -ne $propertyNum) {
            $i = 0;
            while ($true) {
                if ($i -eq [int]($propertyNum - 1)) {
                    $property = $propertyEnum[$i]
                    break
                }
                $i = $i + 1
            }
        }

        if ($null -eq $property) {
            $property = $propertyEnum
        }

        Write-Host
        $i = 0
        #Write-Host "Trying to get $property"
        if ($null -eq $property) {
            return $null
        }
        $existingPropList = $Global:Common.Supported.UpdatablePropList
        $isVM = $false
        # Get the Property Names and Values.. Present as Options.
        foreach ($item in (Get-SortedProperties $property)) {
            $value = $property."$($item)"
            if ($item -eq "vmName") {
                $isVM = $true
            }
            if ($item -eq "network") {
                $isVM = $false
            }
            if ($item -eq "role" -and $value -eq "DC") {
                $isVM = $false
            }
            if ($item -eq "ExistingVM") {
                $isExisting = $true
            }
        }
        $fakeNetwork = $null
        $padding = 26
        $itemMap = @{}
        foreach ($item in (Get-SortedProperties $property)) {
            $value = $property."$($item)"
            if ($isExisting -and $item -eq "ExistingVM") {
                continue

            }
            if ($isExisting -and ($item -notin $existingPropList -or ($value -eq $true -and $null -eq $property."$($item + "-Original")") )) {
                $color = $Global:Common.Colors.GenConfigHidden
                $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName " " -ItemText "        $($($item).PadRight($padding," "")) = $value" -Color1 $color -selectable $false -HelpFunction $HelpFunction
                #Write-Option " " "$($($item).PadRight($padding," "")) = $value" -Color $color
                continue

            }

            $i = $i + 1

            if ($isVM -and $i -eq 2 -and -not $isExisting) {

                $fakeNetwork = $i
                $network = Get-EnhancedSubnetList -SubnetList $global:Config.vmOptions.Network -ConfigToCheck $global:Config
                #Write-Option $i "$($("network").PadRight($padding," "")) = <Default - $($global:Config.vmOptions.Network)>"
                $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName $i -ItemText "$($("network").PadRight($padding," "")) = $network" -selectable $true -HelpFunction $HelpFunction
                #Write-Option $i "$($("network").PadRight($padding," "")) = $network"
                write-log -verbose "Adding $network as element $i in itemmap"
                $itemMap[$i] = "network"
                $i++
            }
            $deletable = $false            
            #$padding = 27 - ($i.ToString().Length)
            $color = $null
            $TextToDisplay = Get-AdditionalInformation -item $item -data $value
            $color = Get-AdditionalInformationColor -item $item -data $value
            $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName $i -ItemText "$($($item).PadRight($padding," "")) = $TextToDisplay" -selectable $true -Color1 $color -HelpFunction $HelpFunction -Deletable $deletable
            write-log -verbose "Adding $item as element $i in itemmap with currentvalue $value"
            $itemMap[$i] = $item
            #Write-Option $i "$($($item).PadRight($padding," "")) = $TextToDisplay" -Color $color
        }

       
        if ($null -ne $additionalOptions) {
            $null = Get-MenuItems -MenuName $MenuName -ExistingMenuItems ([ref]$MenuItems) -additionalOptions $additionalOptions                  
        }

        #Show-GenConfigErrorMessages


        #if ($ContinueMode) {
        #    $response = get-ValidResponse $prompt $i $null $additionalOptions -ContinueMode:$ContinueMode
        #}
        #else {
        #    $response = get-ValidResponse $prompt $i $null $additionalOptions -return:$true
        #}
        $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName "*B" -ItemText "" -selectable $false -selected $false -Color1 $Global:Common.Colors.GenConfigHeader  
        $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName "*V" -ItemText "   ──────────────────────" -selectable $false -selected $false -Color1 "SlateGray"  
        $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName "!" -ItemText "Done with changes" -selectable $true -selected $true -Color1 $Global:Common.Colors.GenConfigHelpHighlight -HelpFunction $HelpFunction
        $response = Get-Menu2 -MenuName $MenuName -menuItems ([ref]$MenuItems) -Prompt $prompt -HideHelp:$true -test:$false  

        if ([String]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE") {
            return "ESCAPE"
        }
        if ($response -eq "!") {
            return
        }
        if ($response -is [bool]) {
            $test = $false
        }
        $return = $null
        if ($null -ne $additionalOptions) {
            foreach ($item in $($additionalOptions.keys)) {
                if (($response -and $item) -and ($response.ToLowerInvariant() -eq $item.ToLowerInvariant())) {
                    # Return fails here for some reason. If the values were the same, let the user escape, as no changes were made.
                    $return = $item
                }
            }
        }
        #Return here instead.
        if ($null -ne $return) {
            return $return
        }
        # We got the [1] Number pressed. Lets match that up to the actual value.
        $i = 0
        
        write-log -verbose "Select-Options for '$MenuName': response = $response"
        if (($response -as [int]) -is [int]) {
            $response = $response -as [int]
            $item = $itemMap[$response]
            if ($null -ne $item) {
                if ($isExisting) {
                    if ($null -eq $property."$($item + "-Original")") {
                        write-log -logonly "Adding $($item)-Original to $($property.vmName)"
                        $property |  Add-Member -MemberType NoteProperty -Name $("$item" + "-Original") -Value $property."$($item)" -force
                    }
                }
            
                $value = $property."$item"
                $name = $item
                write-log -verbose  "$name = $value (VM: $($property.vmName))"               
            } 
        }


        switch ($name) {
            "operatingSystem" {
                Get-OperatingSystemMenu -property $property -name $name -CurrentValue $value
                if ($property.role -eq "DomainMember") {
                    #if (-not $property.SqlVersion) {
                    $newName = Rename-VirtualMachine -vm $property
                    #}
                }
                continue MainLoop
            }
            "DefaultClientOS" {
                Get-OperatingSystemMenuClient -property $property -name $name -CurrentValue $value                    
                continue MainLoop
            }
            "DefaultServerOS" {
                Get-OperatingSystemMenuServer -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "remoteContentLibVM" {
                $result = select-FileServerMenu -HA:$true -CurrentValue $value
                if (-not [string]::IsNullOrWhiteSpace($result) -and $result -ne "ESCAPE") {
                    $property.remoteContentLibVM = $result
                }
                continue MainLoop
            }
            "patchMyPCFileServer" {
                $result = select-FileServerMenu -HA:$true -CurrentValue $value
                if (-not [string]::IsNullOrWhiteSpace($result) -and $result -ne "ESCAPE") {
                    $property.patchMyPCFileServer = $result
                }
                continue MainLoop
            }
            "pullDPSourceDP" {
                $property.pullDPSourceDP = select-PullDPMenu  -CurrentValue $value -CurrentVM $Property
                continue MainLoop
            }
            "fileServerVM" {
                $result = select-FileServerMenu -HA:$false -CurrentValue $value
                if (-not [string]::IsNullOrWhiteSpace($result) -and $result -ne "ESCAPE") {
                    $property.fileServerVM = $result
                }
                continue MainLoop
            }
            "domainName" {
                $domain = select-NewDomainName
                if (-not [string]::IsNullOrEmpty($domain) -and $domain -ne "ESCAPE") {    
                    $property.domainName = $domain
                    if ($property.prefix) {
                        $property.prefix = get-PrefixForDomain -Domain $domain
                    }
                    if ($property.domainNetBiosName) {
                        $netbiosName = $domain.Split(".")[0]
                        $property.domainNetBiosName = $netbiosName
                    
                        Get-TestResult -SuccessOnError | out-null
                    }
                }
                continue MainLoop
            }
            "timeZone" {
                $timezone = Select-TimeZone
                if (-not [string]::IsNullOrWhiteSpace($timezone) -and $timezone -ne "ESCAPE") {
                    $property.timeZone = $timezone
                    Get-TestResult -SuccessOnError | out-null
                }
                continue MainLoop
            }
            "locale" {
                $locale = Select-Locale
                $property.locale = $locale
                Get-TestResult -SuccessOnError | out-null
                continue MainLoop
            }
            "network" {
                if ($property.vmName) {
                    $network = Get-NetworkForVM -vm $property
                }
                else {
                    $network = Select-Subnet -CurrentValue $property.Network
                }

                if ($network -eq $global:config.vmOptions.network) {
                    if ($property.Network -and $property.vmName) {
                        $property.PsObject.Members.Remove("network")
                    }
                    #write-host2 -ForegroundColor Khaki "Not changing network as this is the default network."
                    continue MainLoop
                }
                if ($network) {
                    if ($fakeNetwork) {
                        $property | Add-Member -MemberType NoteProperty -Name "network" -Value $network -Force
                    }
                    else {
                        $property.network = $network
                    }
                }
                Get-AdditionalValidations -property $property -name $Name -CurrentValue $network
                Get-TestResult -SuccessOnError | out-null
                continue MainLoop
            }
            "parentSiteCode" {
                Set-ParentSiteCodeMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "ForestTrust" {
                Get-ForestTrustMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "externalDomainJoinSiteCode" {
                Get-TargetSitesForDomain -property $property -domain $property.ForestTrust
                continue MainLoop
            }
            "sqlVersion" {
                Get-SqlVersionMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "DeploymentType" {
                $dt = Select-DeploymentType
                if ($dt) {
                    $property.DeploymentType = $dt
                }
                continue MainLoop
            }
            "DefaultsqlVersion" {
                Get-SqlVersionMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "remoteSQLVM" {
                Get-remoteSQLVM -property $property -name $name -CurrentValue $value
                Continue MainLoop
                #return "REFRESH"
            }
            "domainUser" {
                Get-domainUser -property $property -name $name -CurrentValue $value
                Continue MainLoop
                #return "REFRESH"
            }
            "wsusDataBaseServer" {
                Get-WsusDBName -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "siteCode" {
                if ($property.role -eq "PassiveSite") {
                    Add-ErrorMessage -property $name "SiteCode cannot be manually modified on a Passive server. Please modify this on the Active node"
                    continue MainLoop
                }
                if ($property.role -in ("SiteSystem", "WSUS")) {
                    Get-SiteCodeMenu -property $property -name $name -CurrentValue $value
                    if (-not $($property.SiteCode)) {
                        Write-RedX "Could not determine sitecode for $($property.VmName)"
                        continue MainLoop
                    }
                    $SiteType = get-RoleForSitecode -siteCode $Property.SiteCode -config $Global:Config
                    if ($SiteType -eq "CAS") {
                        if ($property.InstallMP) {
                            Add-ErrorMessage -property $name "Cannot install an MP on a CAS site. Automatically disabled"
                            $property.InstallMP = $false
                        }
                        if ($property.InstallDP) {
                            Add-ErrorMessage -property $name "Cannot install a DP on a CAS site. Automatically disabled"
                            $property.InstallDP = $false
                            $property.PsObject.Members.Remove("enablePullDP")
                            $property.PsObject.Members.Remove("pullDPSourceDP")
                        }
                    }
                    $newName = Rename-VirtualMachine -vm $property
                    write-host
                    continue MainLoop
                }
            }
            "role" {
                if ($property.role -eq "PassiveSite") {
                    Add-ErrorMessage -property $name "Role cannot be manually modified on a Passive server. Please disable HA or delete the VM."
                    continue MainLoop
                }
                if (Get-RoleMenu -property $property -name $name -CurrentValue $value) {
                    Write-Host2 -ForegroundColor Khaki "VirtualMachine object was re-created with new role. Taking you back to VM Menu."
                    # VM was deleted.. Lets get outta here.
                    return
                }
                else {
                    #VM was not deleted.. We can still edit other properties.
                    continue MainLoop
                }
            }
            "CMVersion" {
                Get-CMVersionMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "version" {
                Get-CMVersionMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
        }
        # If the property is another PSCustomObject, recurse, and call this function again with the inner object.
        # This is currently only used for AdditionalDisks
        if ($value -is [System.Management.Automation.PSCustomObject]) {
            Select-Options -MenuName "$Name" -Rootproperty $property -PropertyName "$Name" -Prompt "Select data to modify" -HelpFunction "Get-GenericHelp" | out-null
        }
        else {
            #The option was not a known name with its own menu, and it wasn't another PSCustomObject.. We can edit it directly.
            $valid = $false
            Write-Host
            Write-Verbose "7 Select-Options"
            while ($valid -eq $false) {
                if ($value -is [bool]) {
                    if ($value -eq $true) {
                        $response2 = "false"
                    }
                    else {
                        $response2 = "true"
                    }
                    $test = $false
                    #$response2 = Get-Menu -Prompt "Select new Value for $($Name)" -CurrentValue $value -OptionArray @("True", "False") -NoNewLine -Test:$false
                }
                else {
                    if ($property.VmName) {
                        $outputName = "$($Name) for VM $($property.VmName)"
                    }
                    else {
                        $outputName = "$Name"
                    }
                    Write-Log -Activity -NoNewLine "Modify Property $outputName - Current Value: $value"
                    $response2 = Read-Host2 -Prompt "Select new Value for $($Name)" $value
                }
                if (-not [String]::IsNullOrWhiteSpace($response2)) {
                    if ($property."$($Name)" -is [Int]) {
                        try {
                            $property."$($Name)" = [Int]$response2
                        }
                        catch {
                            Add-ErrorMessage -property $name "$_"
                            #Write-host "Explosion $_"
                        }
                    }
                    else {
                        if ($value -is [bool]) {
                            if ($([string]$value).ToLowerInvariant() -eq "true" -or $([string]$value).ToLowerInvariant() -eq "false") {
                                if ($response2.ToLowerInvariant() -eq "true") {
                                    $response2 = $true
                                }
                                elseif ($response2.ToLowerInvariant() -eq "false") {
                                    $response2 = $false
                                }
                                else {
                                    $response2 = $value
                                }
                            }

                        }

                        Write-Verbose ("$_ name = $($_.Name) or $name = $response2 value = '$value'")
                        $property."$Name" = $response2
                    }
                    Get-AdditionalValidations -property $property -name $Name -CurrentValue $value
                    if ($Test) {
                        #$valid = Get-TestResult -SuccessOnWarning                        
                        $valid = $true
                    }
                    else {
                        $valid = $true
                    }
                    if ($response2 -eq $value) {
                        $valid = $true
                    }

                }
                else {
                    # Enter was pressed. Set the Default value, and test, but do not block.
                    $property."$($Name)" = $value
                    write-log -verbose "Revert : $response2 for $Name = $value setting as String"
                    $valid = Get-TestResult -SuccessOnError
                }
            }
            write-log -verbose "Select-Options new value: $name = $($property."$Name")"
            if ($name -eq "VmName" -and $($property."$Name") -ne $value ) {
                return "REFRESH"
            }
            if (-not [String]::IsNullOrWhiteSpace($newName)  ) {
                return "NEWNAME:$newName"
            }
        }
        
    }
}


function Select-VirtualMachines {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "pre supplied response")]
        [string] $response = $null,
        [Parameter(Mandatory = $false, HelpMessage = "pre supplies result")]
        [string] $result = $null
    )

    if (-not $response) {
        
        return
    }

    if ([string]::IsNullOrEmpty($result)) {
        Write-Log -Activity -NoNewLine "Select VirtualMachines"
    }
    #Write-Host
    Write-Verbose "8 Select-VirtualMachines"
    
    Write-Log -Verbose "Select VirtualMachines response = $response"
    if ([String]::IsNullOrWhiteSpace($response)) {
        return
    }
    if (-not [String]::IsNullOrWhiteSpace($response)) {
        if ($response.ToLowerInvariant() -eq "n") {
            $machineName = show-NewVMMenu
            write-log  -verbose "Got MachineName $machineName from show-NewVMMenu"

            if (-not $machineName) {
                return
            }
        }
        :VMLoop while ($true) {
            $i = 0

            if (-not $machineName) {
                $machineName = $response
            }
            foreach ($virtualMachine in $global:existingMachines) {
                $i = $i + 1
                if (($i -eq $response) -or ($machineName -and $machineName -eq $virtualMachine.vmName) ) {
                    $machineName = $virtualMachine.vmName
                    $response = $null
                    $existingVM = $true
                    $customOptions = [ordered] @{}
                    $customOptions += [ordered]@{
                        "Z"  = "Delete this VM from Hyper-V"
                        "HZ" = "Danger: This will permanently delete the VM from Hyper-V"
                    }
                    $customOptions += [ordered]@{
                        "*N2" = ""
                        "*BN" = "Add new Disk%$($Global:Common.Colors.GenConfigHeader)"
                        "N"   = "Add a new VHDX to this VM" 
                        "HN"  = "This will stop the VM, create a new drive, and add it to the vm, the start it."
                    }
                    if ($virtualMachine.OperatingSystem -and $virtualMachine.OperatingSystem.Contains("Server")) {


                        if ($virtualMachine.Role -in ("Primary", "CAS")) {
                            $existingPassive = Get-List2 -deployConfig $global:config | Where-Object { $_.SiteCode -eq $virtualMachine.SiteCode -and $_.Role -eq "PassiveSite" }
                            if (-not $existingPassive) {
                                
                                # No Passive Site for this sitecode.. We can offer it here.
                                $customOptions += [ordered]@{"*B2" = ""; "*BS" = "CM High Availability%$($Global:Common.Colors.GenConfigHeader)"; "H" = "Add a Passive Node for this Site Server" }

                            }
                        }

                        if ($virtualMachine.Role -notin ("DC", "BDC")) {
                            if ($null -eq $virtualMachine.sqlVersion) {
                                switch ($virtualMachine.Role) {
                                    "Secondary" {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "S" = "Use Full SQL for Secondary Site" }
                                    }
                                    "WSUS" {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "S" = "Configure WSUS SQL Server" }
                                    }
                                    Default {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "S" = "Add SQL" }
                                    }
                                }
                            }
                            else {

                                switch ($virtualMachine.Role) {
                                    "Secondary" {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "X" = "Remove Full SQL and use SQL Express for Secondary Site" }
                                    }
                                    "WSUS" {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "S" = "Configure WSUS SQL Server" }
                                    }
                                    Default {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "X" = "Remove SQL" }
                                    }
                                }
                            }
                        }
                    }

                    $newValue = "Start"
                    $virtualMachine  | Add-Member -MemberType NoteProperty -Name "ExistingVM" -Value $true -Force
                    if ($machineName) {
                        $machineName = $virtualMachine.vmName
                    }
                    if ([String]::IsNullOrEmpty($result)) {
                        $newValue = Select-Options -MenuName "Modify Properties for $($virtualMachine.VMName)" -propertyEnum $virtualMachine -PropertyNum 1 -prompt "Which VM property to modify" -additionalOptions $customOptions -Test:$true -HelpFunction "Get-GenericHelp"
                    }
                    else {
                        $newValue = $result
                    }
                    #$newValue = Select-Options -Property $clone -prompt "Which Existing VM property to modify" -additionalOptions $customOptions -Test:$true
                    if ([string]::IsNullOrEmpty($newValue) -or $newValue -eq "ESCAPE") {
                        return
                    }
                    if ($newValue -eq "REFRESH") {
                        continue VMLoop
                    }

                    if ($newValue -contains "NEWNAME:") {
                        if ($machineName) {
                            $machineName = $newValue.Split(":")[1]
                        }
                        continue VMLoop
                    }

                    write-log -logonly "Modify properties for '$($virtualMachine.vmName)' returned $newValue"
                    if ($newValue -eq "Z") {
                        $response2 = Read-YesOrNoWithTimeout -Prompt "Delete VM $($virtualMachine.vmName) from Hyper-V? (Y/n)" -HideHelp -timeout 180 -Default "y"

                        if ($response2 -and ($response2.ToLowerInvariant() -eq "n" -or $response2.ToLowerInvariant() -eq "no")) {
                            if ([string]::IsNullOrEmpty($result)) {
                                continue VMLoop
                            }
                            else {
                                return
                            }
                        }
                        else {
                            Remove-VirtualMachine -VmName $virtualMachine.vmName
                            if ($global:Config.existingVirtualMachines) {
                                $global:Config.existingVirtualMachines = $global:Config.existingVirtualMachines | where-object { $_.vmName -ne $virtualMachine.vmName }
                            }
                            if ($global:existingMachines) {
                                $global:existingMachines = $global:existingMachines | where-object { $_.vmName -ne $virtualMachine.vmName }
                            }
                            Get-List -type VM -SmartUpdate | Out-Null
                            New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
                            return
                        }                        
                    }
                    if ($newValue -eq "H") {
                        Write-Log -Verbose "Calling show-NewVMMenu to add passive node"
                        show-NewVMMenu -SiteCode $virtualMachine.SiteCode -role "PassiveSite"
                        return
                    }
                    if ($newValue -eq "N") {

                        $VmName = $virtualMachine.vmName
                        Write-Log -Verbose "$VmName`: Adding new disk to VM"
                        $count = 0
                        $vmObject = get-vm2 -name $VmName
                        Write-Log "Stopping $VmName"
                        $stopped = Stop-Vm2 -Name $VmName -Passthru
                        if (-not $stopped) {
                            Write-Log "$VmName`: VM Not Stopped." -Failure
                            return $false
                        }
                        while ($true) {
                            $count++

                            $Label = "NewDisk_$count"                        
                            $newDiskName = "$VmName`_$label.vhdx"
                            $newDiskPath = Join-Path $vmObject.Path $newDiskName
                            if (Test-Path $newDiskPath) {
                                continue
                            }
                            break
                        }
                        $size = "500GB"
                        Write-Log "$VmName`: Adding $newDiskPath"
                        if (-not $Migrate) {
                            try {
                                New-VHD -Path $newDiskPath -SizeBytes ($size / 1) -Dynamic -ErrorAction Stop | out-null
                            }
                            catch {
                                Write-Log "$VmName`: New-VHD failed for $newDiskPath`: $_" -Failure
                                return $false
                            }
                        }
                        if (-not (Test-Path $newDiskPath)) {
                            Write-Log "Failed to find $newDiskPath" -Failure
                            return
                        }
                        try {
                            Add-VMHardDiskDrive -VMName $VmName -Path $newDiskPath -ErrorAction Stop | out-null
                        }
                        catch {
                            Write-Log "$VmName`: Add-VMHardDiskDrive failed for $newDiskPath`: $_" -Failure
                            return $false
                        }
                        Write-Log "Starting $VmName"
                        $Started = Start-Vm2 -Name $VmName -Passthru
                        if (-not $Started) {
                            Write-Log "$VmName`: VM Not Started." -Failure
                            return $false
                        }
                        $connected = Wait-ForVM -VmName $VMname -PathToVerify "C:\Users" -VmDomainName $virtualMachine.Domain -TimeoutMinutes 2 -Quiet
                        if (-not $connected) {
                            #Write-Progress2 -Log -PercentComplete 0 -Activity "StartVM" -Status "Could not connect to the VM after waiting for 2 minutes."
                            Write-Log "$VmName`: Could not connect to the VM after waiting for 2 minutes." -Failure
                            return $false
                        }
                        Write-Log "Initializing disk.." -NoNewLine
                        $result = Invoke-VmCommand -VmName $VmName -VmDomainName $virtualMachine.Domain -ScriptBlock $global:Initialize_Disk -SuppressLog -ArgumentList @("AUTO", $size, $label)
                        if ($result.ScriptBlockFailed) {
                            Write-Log "Could not Initialize new disk" -Failure
                        }
                        else {
                            Write-Log "$VmName`: Disk $newDiskPath initialized"
                        }
                        return
                    }
                    return
                }
            }


            $found = $false
            if ($machineName) {
                foreach ($virtualMachine in $global:config.virtualMachines | Where-Object { -not $_.Hidden }) {
                    if ($machineName -eq $virtualMachine.vmName) {
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    return
                }
            }


            $ii = 0
            foreach ($virtualMachine in $global:config.virtualMachines | Where-Object { -not $_.Hidden }) {
                $i = $i + 1
                $ii++
                if ($i -eq $response -or ($machineName -and $machineName -eq $virtualMachine.vmName)) {
                    $newValue = "Start"
                    $machineName = $virtualMachine.vmName                    
                    while ($newValue -ne "D" -and -not ([string]::IsNullOrWhiteSpace($($newValue)))) {
                        Write-Log -HostOnly -Verbose "NewValue = '$newvalue'"
                        $customOptions = [ordered]@{ 
                            "*B1" = ""
                            "*B"  = "Disks%$($Global:Common.Colors.GenConfigHeader)"
                            "A"   = "Add Additional Disk"
                            "HA"  = "Add an additional VHDX to this VMs configuration"
                        }
                        if ($null -eq $virtualMachine.additionalDisks) {
                        }
                        else {
                            $customOptions += [ordered]@{
                                "R"  = "Remove Last Additional Disk"
                                "HR" = "The last disk added to this configuration will be removed"
                            }
                        }
                        if (($virtualMachine.Role -eq "Primary") -or ($virtualMachine.Role -eq "CAS")) {
                            $customOptions += [ordered]@{
                                "*B2" = ""
                                "*BS" = "ConfigMgr%$($Global:Common.Colors.GenConfigHeader)"
                                "S"   = "Configure SQL (Set local or remote [Standalone or Always-On] SQL)" 
                                "HS"  = "Opens the SQL configuration menu for this VM"
                            }
                            $PassiveNode = $global:config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $virtualMachine.siteCode }
                            if ($PassiveNode) {
                                $customOptions += [ordered]@{
                                    "H"  = "Remove High Availability (HA) - Removes the Passive Site Server" 
                                    "HH" = "Removes the PassiveSite VM from the configuration."
                                }
                            }
                            else {
                                $customOptions += [ordered]@{
                                    "H"  = "Enable High Availability (HA) - Adds a Passive Site Server"
                                    "HH" = "Adds a PassiveSite VM to configuration, when deployed will be automatically configured for High Availability"
                                }
                            }
                        }
                        else {
                            if ($virtualMachine.Role -eq "DomainMember") {
                                if (-not $virtualMachine.domainUser) {
                                    $customOptions += [ordered]@{
                                        "*U"   = ""
                                        "*BU2" = "Domain User (This account will be made a local admin)%$($Global:Common.Colors.GenConfigHeader)"
                                        "U"    = "Add domain user as admin on this machine" 
                                        "HU"   = "Create a new Active Directory user who will be configured as an admin on this VM"
                                    }
                                }
                                else {
                                    $customOptions += [ordered]@{"*U" = ""
                                        "*BU2"                        = "Domain User%$($Global:Common.Colors.GenConfigHeader)"
                                        "U"                           = "Remove domainUser from this machine"
                                        "HU"                          = "Do not add a admin user to this machine.  Only the domain admin account will be a local admin"
                                    }
                                }
                            }
                            if ($virtualMachine.OperatingSystem -and $virtualMachine.OperatingSystem.Contains("Server")) {


                                if ($virtualMachine.Role -notin ("DC", "BDC")) {
                                    if ($null -eq $virtualMachine.sqlVersion) {
                                        switch ($virtualMachine.Role) {
                                            "Secondary" {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "S"   = "Use Full SQL for Secondary Site" 
                                                    "HS"  = "Adds a SQL instance on this VM and uses it for the CM Secondary Database"
                                                }
                                            }
                                            "WSUS" {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "S"   = "Configure WSUS SQL Server" 
                                                    "HS"  = "Opens a menu to select the SQL instance WSUS will use"
                                                }
                                            }
                                            Default {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "S"   = "Add SQL" 
                                                    "HS"  = "Adds a SQL instance to this machine"
                                                }
                                            }
                                        }
                                    }
                                    else {

                                        switch ($virtualMachine.Role) {
                                            "Secondary" {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "X"   = "Remove Full SQL and use SQL Express for Secondary Site" 
                                                    "HX"  = "Remove the SQL configuration from this VM, and instruct the secondary site to install SQL Express"
                                                }
                                            }
                                            "WSUS" {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "S"   = "Configure WSUS SQL Server"
                                                    "HS"  = "Opens a menu to select the SQL instance WSUS will use" 
                                                }
                                            }
                                            Default {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "X"   = "Remove SQL" 
                                                    "HX"  = "Removes the SQL configuration from this VM"
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        $customOptions += [ordered]@{
                            "*B3" = ""
                            "*BD" = "VM Management%$($Global:Common.Colors.GenConfigHeader)"
                            "Z"   = "Remove this VM from config%$($Global:Common.Colors.GenConfigDangerous)%$($Global:Common.Colors.GenConfigDangerous)" 
                            "HZ"  = "Deletes this VM from the current configuration"
                        }
                        if ([String]::IsNullOrEmpty($result)) {
                            $newValue = Select-Options -MenuName "Modify Properties for $($virtualMachine.VMName)" -propertyEnum $global:config.virtualMachines -PropertyNum $ii -prompt "Which VM property to modify" -additionalOptions $customOptions -Test:$false -HelpFunction "Get-GenericHelp"
                        }
                        else {
                            $newValue = $result
                        }
                        if ([string]::IsNullOrEmpty($newValue) -or $newValue -eq "ESCAPE") {
                            return
                        }
                        if ($newValue -eq "REFRESH") {
                            if ($machineName) {
                                return
                            }
                            continue VMLoop
                        }
                        if ($null -ne $newValue -and $newValue -is [string]) {
                            $newValue = [string]$newValue.Trim()
                            #Write-Host "NewValue = '$newValue'"
                            $newValue = [string]$newValue.ToUpper()
                        }
                        if (([string]::IsNullOrEmpty($newValue))) {
                            break VMLoop
                        }
                        if ($newValue -eq "H") {
                            $PassiveNode = $global:config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $virtualMachine.siteCode }
                            if ($PassiveNode) {
                                $FSVM = $global:config.virtualMachines | Where-Object { $_.vmName -eq $PassiveNode.remoteContentLibVM }
                                if ($FSVM) {
                                    $OtherVMs = $global:config.virtualMachines | Where-Object { $_.fileServerVM -eq $FSVM.vmName } 
                                    $OtherVMs2 = $global:config.virtualMachines | Where-Object { $_.remoteContentLibVM -eq $FSVM.vmName -and $_.vmname -ne $PassiveNode.vmName } 
                                    if (-not $OtherVMs -and -not $OtherVMs2) {
                                        write-host
                                        Write-OrangePoint "$($FSVM.vmName) is not in use by any other VMs. Removing from config"
                                        Remove-VMFromConfig -vmName $FSVM.vmName -ConfigToModify $global:config
                                    }
                                }
                                #$virtualMachine.psobject.properties.remove('remoteContentLibVM')
                                Remove-VMFromConfig -vmName $PassiveNode.vmName -ConfigToModify $global:config
                            }
                            else {
                                Add-NewVMForRole -Role "PassiveSite" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $($virtualMachine.vmName + "-P")  -SiteCode $virtualMachine.siteCode -OperatingSystem $virtualMachine.OperatingSystem
                            }
                            continue VMLoop

                        }
                        if ($newValue -eq "U") {
                            if ($virtualMachine.domainUser) {
                                $virtualMachine.psobject.properties.remove('domainUser')
                            }
                            else {
                                Get-DomainUser -property $virtualMachine -name "domainUser"
                                #$virtualMachine | Add-Member -MemberType NoteProperty -Name 'domainUser' -Value "bob"
                            }
                        }
                        if ($newValue -eq "S") {
                            if ($virtualMachine.Role -in ("Primary", "CAS", "WSUS")) {
                                Get-remoteSQLVM -property $virtualMachine
                                continue VMLoop
                            }
                            else {
                                $SqlVersion = "SQL Server 2022"
                                if ($ConfigToModify.domainDefaults.DefaultSqlVersion) {
                                    $SqlVersion = $ConfigToModify.domainDefaults.DefaultSqlVersion
                                }
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value $SqlVersion -force
                                if ($virtualMachine.AdditionalDisks.E) {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "E:\SQL" -force
                                }
                                else {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "C:\SQL" -force
                                }
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlServiceAccount' -Value "LocalSystem" -force
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlAgentAccount' -Value "LocalSystem" -force
                                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $true -force
                                }
                                if ($virtualMachine.Role -ne "Secondary") {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlPort' -Value "1433" -force
                                }
                                $virtualMachine.virtualProcs = 4
                                if ($($virtualMachine.memory) / 1GB -lt "4GB" / 1GB) {
                                    $virtualMachine.memory = "4GB"
                                }
                                if ($virtualMachine.role -eq "Secondary") {
                                    if ($($virtualMachine.memory) / 1GB -lt "4GB" / 1GB) {
                                        $virtualMachine.memory = "4GB"
                                    }
                                }

                                $newName = Rename-VirtualMachine -vm $virtualMachine

                            }
                        }
                        if ($newValue -eq "X") {
                            $virtualMachine.psobject.properties.remove('sqlversion')
                            $virtualMachine.psobject.properties.remove('sqlInstanceDir')
                            $virtualMachine.psobject.properties.remove('sqlInstanceName')
                            $virtualMachine.psobject.properties.remove('sqlPort')
                            $virtualMachine.psobject.properties.remove('SqlServiceAccount')
                            $virtualMachine.psobject.properties.remove('SqlAgentAccount')
                            if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                            }
                            $newName = Rename-VirtualMachine -vm $virtualMachine
                        }
                        if ($newValue -eq "A") {
                            if ($null -eq $virtualMachine.additionalDisks) {
                                $disk = [PSCustomObject]@{"E" = "400GB" }
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
                            }
                            else {
                                $letters = 69
                                $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                    $letters++
                                }
                                if ($letters -lt 90) {
                                    $letter = $([char]$letters).ToString()
                                    $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name $letter -Value "250GB" -force
                                }
                            }
                        }
                        if ($newValue -eq "R") {
                            $diskscount = 0
                            $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                $diskscount++
                            }
                            if ($virtualMachine.Role -eq "FileServer") {
                                if ($diskscount -le 2) {
                                    write-host
                                    write-redx "FileServers must have at least 2 disks"
                                    Continue VMLoop
                                }
                            }
                            if ($virtualMachine.SqlInstanceDir) {
                                $neededDisks = 0
                                if ($virtualMachine.SqlInstanceDir.StartsWith("E:")) {
                                    $neededDisks = 1
                                }
                                if ($virtualMachine.SqlInstanceDir.StartsWith("F:")) {
                                    $neededDisks = 2
                                }
                                if ($virtualMachine.SqlInstanceDir.StartsWith("G:")) {
                                    $neededDisks = 3
                                }
                                if ($diskscount -le $neededDisks) {
                                    write-host
                                    write-redx "SQL is configured to install to the disk we are trying to remove. Cannot remove"
                                    Continue VMLoop
                                }
                            }

                            if ($virtualMachine.cmInstallDir) {
                                $neededDisks = 0
                                if ($virtualMachine.cmInstallDir.StartsWith("E:")) {
                                    $neededDisks = 1
                                }
                                if ($virtualMachine.cmInstallDir.StartsWith("F:")) {
                                    $neededDisks = 2
                                }
                                if ($virtualMachine.cmInstallDir.StartsWith("G:")) {
                                    $neededDisks = 3
                                }
                                if ($diskscount -le $neededDisks) {
                                    write-host
                                    write-redx "ConfigMgr is configured to install to the disk we are trying to remove. Cannot remove"
                                    Continue VMLoop
                                }
                            }

                            if ($virtualMachine.wsusContentDir) {
                                $neededDisks = 0
                                if ($virtualMachine.wsusContentDir.StartsWith("E:")) {
                                    $neededDisks = 1
                                }
                                if ($virtualMachine.wsusContentDir.StartsWith("F:")) {
                                    $neededDisks = 2
                                }
                                if ($virtualMachine.wsusContentDir.StartsWith("G:")) {
                                    $neededDisks = 3
                                }
                                if ($diskscount -le $neededDisks) {
                                    write-host
                                    write-redx "WSUS is configured to use the disk we are trying to remove. Cannot remove"
                                    Continue VMLoop
                                }
                            }
                            if ($diskscount -eq 1) {
                                $virtualMachine.psobject.properties.remove('additionalDisks')
                            }
                            else {
                                $i = 0
                                $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                    $i = $i + 1
                                    if ($i -eq $diskscount) {
                                        $virtualMachine.additionalDisks.psobject.properties.remove($_.Name)
                                    }
                                }
                            }
                            if ($diskscount -eq 1) {
                                $virtualMachine.psobject.properties.remove('additionalDisks')
                            }
                        }
                        if (-not ($newValue -eq "Z")) {
                            Get-TestResult -SuccessOnError | out-null
                        }
                        else {
                            break VMLoop
                        }
                    }
                    break VMLoop
                }
            }
        }
        if ($newValue -eq "Z") {
            $vmToRemove = if ($machineName) { $machineName } else { $response }
            write-log -verbose "Removing VM '$vmToRemove' from config"
            $i = 0
            $removeVM = $true
            foreach ($virtualMachine in $global:existingMachines) {
                $i = $i + 1
            }
            foreach ($virtualMachine in $global:config.virtualMachines) {
                $i = $i + 1
                if ($i -eq $response -or ($machineName -and $machineName -eq $virtualMachine.vmName)) {
                    #if ($i -eq $response) {
                    Write-Log -Activity -NoNewLine "Remove $($virtualMachine.vmName) from current config"
                    $response = Read-YesOrNoWithTimeout -Prompt "Are you sure you want to remove $($virtualMachine.vmName)? (Y/n)" -HideHelp -Default "y"
                    if ($response -and ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no")) {
                    }
                    else {
                        if ($virtualMachine.role -eq "FileServer") {

                            foreach ($testVM in $global:config.virtualMachine) {
                                if ($testVM.remoteContentLibVM -eq $virtualMachine.vmName) {
                                    Write-Host
                                    write-host2 -ForegroundColor Khaki "This VM is currently used as the RemoteContentLib for $($testVM.vmName) and cannot be deleted at this time."
                                    $removeVM = $false
                                }
                                if ($testVM.fileServerVM -eq $virtualMachine.vmName) {
                                    Write-Host
                                    write-host2 -ForegroundColor Khaki "This VM is currently used as the fileServerVM for $($testVM.vmName) and cannot be deleted at this time."
                                    $removeVM = $false
                                }
                            }

                            $SQLAOVMs = $global:config.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.fileServerVM }
                            if ($SQLAOVMs) {
                                foreach ($SQLAOVM in $SQLAOVMs) {
                                    if ($SQLAOVM.fileServerVM -eq $virtualMachine.vmName) {
                                        Write-Host
                                        write-host2 -ForegroundColor Khaki "This VM is currently used as the fileServerVM for $($SQLAOVM.vmName) and cannot be deleted at this time."
                                        $removeVM = $false
                                    }
                                }
                            }
                        }
                        if ($virtualMachine.role -eq "SQLAO") {
                            if (-not ($virtualMachine.OtherNode)) {
                                Write-Host
                                write-host2 -ForegroundColor Khaki "This VM is Secondary node in a SQLAO cluster. Please delete the Primary node to remove both VMs"
                                $removeVM = $false
                            }
                            else {
                                Remove-VMFromConfig -vmName $virtualMachine.OtherNode -ConfigToModify $global:config
                            }
                        }
                        if ($removeVM -eq $true) {
                            Remove-VMFromConfig -vmName $virtualMachine.vmName -ConfigToModify $global:config
                        }

                    }
                }
            }
            return
        }
    }
    else {
        Get-TestResult -SuccessOnError | Out-Null
        return
    }

}

function Remove-VMFromConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Name of VM to remove.")]
        [string] $vmName,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [object] $configToModify = $global:config
    )
    $DeletedVM = $null
    $newvm = $configToModify.virtualMachines | ConvertTo-Json | ConvertFrom-Json
    $configToModify.virtualMachines = @()
    foreach ($virtualMachine in $newvm) {

        if ($virtualMachine.vmName -ne $vmName) {
            $configToModify.virtualMachines += $virtualMachine
        }
        else {
            $DeletedVM = $virtualMachine
        }
    }
    if ($DeletedVM.Role -eq "CAS") {
        $children = ($ConfigToModify.virtualMachines | Where-Object { $_.ParentSiteCode -eq $DeletedVM.SiteCode })

        foreach ($child in $children ) {
            $child.parentSiteCode = $null
        }
    }
}
