<#
.SYNOPSIS
Adds an error or warning message to the global GenConfigErrorMessages array.

.DESCRIPTION
The Add-ErrorMessage function is used to add an error or warning message to the global GenConfigErrorMessages array. It takes the message, property, and Warning parameters as input.

.PARAMETER message
Specifies the name of the Notefield to modify.

.PARAMETER property
Specifies the base property object.

.PARAMETER Warning
Specifies whether the message is a warning. If this switch is present, the message will be treated as a warning; otherwise, it will be treated as an error.

.EXAMPLE
Add-ErrorMessage -message "Invalid value" -property "SomeProperty" -Warning
Adds a warning message to the global GenConfigErrorMessages array with the specified message and property.

.EXAMPLE
Add-ErrorMessage -message "Error occurred" -property "AnotherProperty"
Adds an error message to the global GenConfigErrorMessages array with the specified message and property.
#>
function Add-ErrorMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Name of Notefield to Modify")]
        [string] $message,
        [Parameter(Mandatory = $false, HelpMessage = "Base Property Object")]
        [string] $property,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [switch] $Warning
    )

    $level = "ERROR"
    if ($Warning) {
        $level = "WARNING"
    }

    if (-not $global:GenConfigErrorMessages) {
        $global:GenConfigErrorMessages = @()
    }

    if ($global:GenConfigErrorMessages -is [PSCustomObject]) {
        $global:GenConfigErrorMessages = @($global:GenConfigErrorMessages)
    }

    $global:GenConfigErrorMessages += [PSCustomObject]@{
        property = $property
        Level    = $level
        Message  = $message
    }
    Write-Verbose "Add-ErrorMessage $message"
}


function Get-AdditionalValidations {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $value = $property."$($Name)"
    #$name = $($item.Name)
    Write-Verbose "[Get-AdditionalValidations] Prop:'$property' Name:'$name' Current:'$CurrentValue' New:'$value'"
    switch ($name) {
        "E" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            $property.$name = $value.ToUpperInvariant()
        }
        "F" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            $property.$name = $value.ToUpperInvariant()
        }
        "G" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            $property.$name = $value.ToUpperInvariant()
        }
        "dynamicMinRam" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            if (($value / 1) -lt 50MB) {
                Add-ErrorMessage -property $name -Warning "Cannot set $name to less than 50MB"
                $value = $CurrentValue
            }
            if (($value / 1) -gt 64GB) {
                Add-ErrorMessage -property $name -Warning "Cannot set $name to more than 64GB"
                $value = $CurrentValue
            }
            if (($value / 1) -ge $property.memory / 1 ) {
                Add-ErrorMessage -property $name -Warning "If $name is larger than Memory, dynamic ram will be disabled"
            }
            $property.$name = $value.ToUpperInvariant()
        }
        "memory" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            if (($value / 1) -lt 50MB) {
                Add-ErrorMessage -property $name -Warning "Cannot set $name to less than 50MB"
                
                $value = $CurrentValue
            }
            if (($value / 1) -gt 64GB) {
                Add-ErrorMessage -property $name -Warning "Cannot set $name to more than 64GB"
                $value = $CurrentValue
            }
            $property.$name = $value.ToUpperInvariant()

            if (-not $Global:Config.domainDefaults.UseDynamicMemory) {
                if ($property.dynamicMinRam) {
                    $property.dynamicMinRam = $value.ToUpperInvariant()
                }
            }
            
        }

        "tpmEnabled" {
            if ($value -eq $false) {
                if ($property.OperatingSystem -like "*Windows 11*") {
                    Add-ErrorMessage -property $name "Windows 11 must include TPM support"
                    $property.$name = $true
                }
            }
        }

        "vmGeneration" {
            if ($value -notin ("1", "2")) {
                $property.$name = "2"
            }
            if ($value -eq "1" -and ($property.tpmEnabled -eq $true)) {
                Add-ErrorMessage -property $name -Warning "Setting generation to 1 will disable TPM support."
            }
        }
        "virtualProcs" {            
            if ($value -le "0" -or $value -gt 16) {
                Add-ErrorMessage -property $name -Warning "Valid values for $name are 1-16"
                $property.$name = 4
            }
        }
        "SqlServiceAccount" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }

                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                }
            }
        }
        "SqlAgentAccount" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                }
            }
        }
        "sqlVersion" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                }
            }
        }
        "sqlInstanceName" {
            if ($CurrentValue -eq "MSSQLSERVER") {
                if ($Value -ne "MSSQLSERVER") {
                    $property.sqlPort = "2433"
                }
            }
            else {
                if ($Value -eq "MSSQLSERVER") {
                    $property.sqlPort = "1433"
                }
            }

            if ($property.Role -eq "SQLAO") {
                $property.sqlPort = "1433"
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                    $sql.sqlPort = $property.sqlPort
                }
            }

        }
        "sqlPort" {
            if ($property.Role -eq "SQLAO") {
                Add-ErrorMessage -property $name  "Sorry. When using SQLAO, port must remain 1433 due to a bug in SqlServerDSC issue #329."
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = 1433
                }
            }

        }
        "sqlInstanceDir" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                }
            }

        }
        "OtherNode" {
            Add-ErrorMessage -property $name  "OtherNode cannot be set manually. Please rename the 2nd node of the cluster to change this property."
            $property.$name = $currentValue
        }
        "network" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    if ($sql.$name) {
                        $sql.$name = $value
                    }
                    else {
                        $sql | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
                    }
                }
            }

        }
        "vmName" {

            if (($value.Length + $Global:Config.VmOptions.Prefix.Length) -gt 15) {
                Add-ErrorMessage -property $name  "VMName + Prefix cannot be longer than 15 chars"
                $property.$name = $currentValue
            }
            
            foreach ($existing in $Global:Config.virtualMachines) {
    
                if ($existing.RemoteSQLVM -eq $CurrentValue) {
                    $existing.RemoteSQLVM = $value
                }
                if ($existing.remoteContentLibVM -eq $CurrentValue) {
                    $existing.remoteContentLibVM = $value
                }
                if ($existing.FileServerVM -eq $CurrentValue) {
                    $existing.FileServerVM = $value
                }
                if ($existing.pullDPSourceDP -eq $CurrentValue) {
                    $existing.pullDPSourceDP = $value
                }
            }
        }
       
        "InstallPatchMyPC" {
            if ($value -eq $true) {
                if ($property.Role -notin ("CAS", "Primary")) {
                    if (-not $Global:Config.cmOptions.UsePKI) {
                        Add-ErrorMessage -property $name "PatchMyPC must be installed on the site server if not using PKI for ConfigMgr"
                        $property.$name = $false
                        $property.PsObject.Members.Remove("PatchMyPCFileServer")
                        return
                    }
                }
                $result = select-FileServerMenu
                if (-not [string]::IsNullOrWhiteSpace($result) -and $result -ne "ESCAPE") {
                    $property | Add-Member -MemberType NoteProperty -Name "PatchMyPCFileServer" -Value $result -Force
                }
                else {
                    $property.PsObject.Members.Remove("PatchMyPCFileServer")
                }

            }
            else {
                $property.PsObject.Members.Remove("PatchMyPCFileServer")
            }
        }
        "UsePKI" {
            # Cascade: when UsePKI is toggled from the CM Options menu, sync pkiOptions
            if ($Global:Config.pkiOptions) {
                if ($value -eq $true) {
                    if (-not $Global:Config.pkiOptions.EnablePKI) {
                        $Global:Config.pkiOptions.EnablePKI = $true
                    }
                    if (-not $Global:Config.pkiOptions.IssuingCAVM) {
                        $firstDC = $Global:Config.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
                        if ($firstDC) {
                            $Global:Config.pkiOptions.IssuingCAVM = $firstDC.vmName
                        }
                    }
                }
            }
        }
        "installSUP" {
            if ($value -eq $true) {
                if (-not $property.siteCode) {
                    Get-SiteCodeMenu -property $property -name "siteCode" -ConfigToCheck $Global:Config
                }
                if (-not $property.siteCode) {
                    $property.installSUP = $false
                    $property.PsObject.Members.Remove("wsusContentDir")
                    $property.PsObject.Members.Remove("wsusDataBaseServer")
                    $property.PsObject.Members.Remove("InstallPatchMyPC")
                    $property.PsObject.Members.Remove("PatchMyPCFileServer")
                }

                if ($property.ParentSiteCode -or $property.SiteCode) {
                    
                    $sitecode = $property.SiteCode
                 
                    if ($sitecode) {
                        $Parent = Get-ParentSiteServerForSiteCode -deployConfig $Global:Config -siteCode $sitecode -type VM -SmartUpdate:$false
                        if ($Parent.SiteCode) {
                            $list2 = Get-List2 -deployConfig $Global:Config
                            $existingSUP = $list2 | Where-Object { $_.InstallSUP -and $_.SiteCode -eq $Parent.SiteCode }
                            if (-not $existingSUP) {
                                $property.installSUP = $false
                                $property.PsObject.Members.Remove("wsusContentDir")
                                $property.PsObject.Members.Remove("wsusDataBaseServer")
                                $property.PsObject.Members.Remove("InstallPatchMyPC")
                                $property.PsObject.Members.Remove("PatchMyPCFileServer")
                                Add-ErrorMessage -property $name "SUP role cannot be installed on downlevel sites until the parent site ($($Parent.SiteCode)) has a SUP"
                            }
                        }
                        else {
                            $property | Add-Member -MemberType NoteProperty -Name "InstallPatchMyPC" -Value $false -Force
                        }
                    }

                }

                if ($property.Role -ne "WSUS") {
                    $DataBase = "WID"
                    if ($property.SqlVersion) {
                        $Database = $property.VMName                        
                    }
                    else {
                        $ActiveVM = Get-ActiveSiteServerForSiteCode -deployConfig $Global:Config -SiteCode $property.siteCode -type VM

                        $sql = Get-SqlServerForSiteCode -siteCode $property.SiteCode -deployConfig $Global:Config -type VM
                        if (-not $ActiveVM.InstallSUP) {
                            if (-not $sql.InstallSUP) {
                                $database = $($sql.vmName)
                            }
                        }
                    }
                    $property | Add-Member -MemberType NoteProperty -Name "wsusDataBaseServer" -Value $database -Force
                    $property | Add-Member -MemberType NoteProperty -Name "wsusContentDir" -Value "E:\WSUS" -Force
                    if ($null -eq $property.additionalDisks) {
                        $disk = [PSCustomObject]@{"E" = "600GB" }
                        $property | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
                    }
                    else {

                        if ($null -eq $property.additionalDisks.E) {
                            $property.additionalDisks | Add-Member -MemberType NoteProperty -Name "E" -Value "600GB" -force
                        }
                    }

                    $value = $property.Memory
                    if (($value / 1) -lt 5GB) {
                        $property.Memory = "5GB"
                    }
                }

                $newName = Rename-VirtualMachine -vm $property


            }
            else {
                if ($property.Role -ne "WSUS") {
                    $property.PsObject.Members.Remove("wsusContentDir")
                    $property.PsObject.Members.Remove("wsusDataBaseServer")
                    $property.PsObject.Members.Remove("InstallPatchMyPC")
                    $property.PsObject.Members.Remove("PatchMyPCFileServer")

                }
                $newName = Rename-VirtualMachine -vm $property
            }

            #$validSiteCodes = Get-ValidSiteCodesForWSUS -config $Global:Config -CurrentVM $property
            #if ($property.sitecode -in $validSiteCodes) {
            #
            #    $newName = Get-NewMachineName -vm $property
            #    if ($($property.vmName) -ne $newName) {
            #        $rename = $true
            #        $response = Read-YesOrNoWithTimeout -Prompt "Rename $($property.vmName) to $($newName)? (Y/n)" -HideHelp -Default "y"
            #        if (-not [String]::IsNullOrWhiteSpace($response)) {
            #            if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
            #                $rename = $false
            #            }
            #        }
            #        if ($rename -eq $true) {
            #            $property.vmName = $newName
            #        }
            #    }
            #    else {
            #        $property.InstallSUP = $false
            #    }
            #}


        }
        "installMP" {
            if ((get-RoleForSitecode -ConfigToCheck $Global:Config -siteCode $property.siteCode) -in "Secondary", "CAS") {
                Add-ErrorMessage -property $name -Warning "Cannot install an MP on a CAS or secondary site"
                $property.installMP = $false
            }
            $newName = Rename-VirtualMachine -vm $property
        }
        "enablePullDP" {
            if ($value -eq $true) {
                $server = select-PullDPMenu -CurrentVM $property
                $property | Add-Member -MemberType NoteProperty -Name "pullDPSourceDP" -Value $server -Force

            }
            else {
                $property.PsObject.Members.Remove("pullDPSourceDP")
            }
            $newName = Rename-VirtualMachine -vm $property
        }
        "installCA" {
            if ($value -eq $true) {
                # Show UseOfflineRoot option when InstallCA is enabled
                if ($null -eq $property.UseOfflineRoot) {
                    $property | Add-Member -MemberType NoteProperty -Name 'UseOfflineRoot' -Value $false -Force
                }
            }
            else {
                # Remove UseOfflineRoot when InstallCA is disabled
                $property.PsObject.Members.Remove("UseOfflineRoot")
            }
            if ($property.ForestTrust -and $property.ForestTrust -ne "NONE") {
                $remoteCA = (get-list -type vm -DomainName $property.ForestTrust | Where-Object { $_.InstallCA })
                if ($remoteCA) {
                    Add-ErrorMessage -property $name -Warning "Domain $($property.ForestTrust) already has a CA. Disabling CA in this domain"
                    $property.InstallCA = $false
                    $property.PsObject.Members.Remove("UseOfflineRoot")
                }
            }
        }
        "installDP" {

            if ((get-RoleForSitecode -ConfigToCheck $Global:Config -siteCode $property.siteCode) -eq "CAS") {
                Add-ErrorMessage -property $name -Warning "Cannot install a DP for a CAS site"
                $property.installDP = $false
            }

            if ($value -eq $false) {
                $pullDPs = $Global:Config.virtualMachines | Where-Object { $_.pullDPSourceDP -eq $property.VmName }
                if ($pullDPs) {
                    Add-ErrorMessage -property $name -Warning "$($pullDPs.vmName) is using this as a source.  Please remove before removing this DP"
                    $property.InstallDP = $true
                    return
                }
                else {
                    $property.PsObject.Members.Remove("enablePullDP")
                    $property.PsObject.Members.Remove("pullDPSourceDP")
                }
            }
            else {
                $property | Add-Member -MemberType NoteProperty -Name "enablePullDP" -Value $false -Force
            }
            $newName = Rename-VirtualMachine -vm $property
        }
        "installRP" {

            $validSiteCodes = Get-ValidSiteCodesForRP -config $Global:Config -CurrentVM $property

            $sitecode = $property.sitecode
            if (-not $sitecode) {
                $SiteVM = $global:config.virtualMachines | where-object { $_.remoteSQLVM -eq $property.vmName -and $_.role -in ("CAS", "Primary") }
                $sitecode = $siteVM.sitecode
            }

            if (-not $sitecode) {
                $SiteVM = @(get-list -type VM -domain $global:config.VmOptions.DomainName | Where-Object { $_.remoteSQLVM -eq $property.vmName -and $_.role -in ("CAS", "Primary") })
                $sitecode = $siteVM.sitecode
            }
            if ($sitecode -in $validSiteCodes) {
                $newName = Rename-VirtualMachine -vm $property
            }
            else {
                Add-ErrorMessage -property $name -Warning "Site code $sitecode is not a valid target for a new Reporting Point. Only 1 RP can exist per site."
                $property.InstallRP = $false
            }
        }
        "siteCode" {
            if ($property.siteCode.Length -ne 3) {
                Add-ErrorMessage -property $name -Warning "SiteCode must be exactly 3 characters long. Unable to change sitecode."                
                $property.siteCode = $CurrentValue
                return
            }
            if ($property.RemoteSQLVM) {
                $newSQLName = $value + "SQL"
                #Check if the new name is already in use:
                $NewSQLVM = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $newSQLName }
                if ($NewSQLVM) {
                    Add-ErrorMessage -property $name -Warning "Changing Sitecode would rename SQL VM to $($NewSQLVM.vmName) which already exists. Unable to change sitecode."    
                    write-host
                    write-host2 -ForegroundColor OrangeRed "Changing Sitecode would rename SQL VM to " -NoNewline
                    write-host2 -ForegroundColor Gold $($NewSQLVM.vmName) -NoNewline
                    write-host2 -ForegroundColor OrangeRed " which already exists. Unable to change sitecode."
                    $property.siteCode = $CurrentValue
                    return
                }
            }

            $newName = Get-NewMachineName -vm $property
            $NewSSName = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $newName }
            if ($NewSSName) {
                write-host
                Add-ErrorMessage -property $name -Warning "Changing Sitecode would rename SQL VM to $($NewSSName.vmName) which already exists. Unable to change sitecode." 
                write-host2 -ForegroundColor OrangeRed "Changing Sitecode would rename VM to " -NoNewline
                write-host2 -ForegroundColor Gold $($NewSSName.vmName) -NoNewline
                write-host2 -ForegroundColor OrangeRed " which already exists. Unable to change sitecode."
                $property.siteCode = $CurrentValue
                return
            }
            #Set the SQL Name after all checks are done.
            if ($property.RemoteSQLVM) {
                $RemoteSQLVM = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $($property.RemoteSQLVM) }
                if ($RemoteSQLVM.OtherNode) {
                    #This is SQLAO
                    $newSQLName = $($property.SiteCode) + "SQLAO1"
                }
                $rename = $true
                $response = Read-YesOrNoWithTimeout -Prompt "Rename $($property.RemoteSQLVM) to $($newSQLName)? (Y/n)" -HideHelp -Default "y"
                if (-not [String]::IsNullOrWhiteSpace($response)) {
                    if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                        $rename = $false
                    }
                }
                if ($rename -eq $true) {


                    if ($RemoteSQLVM.OtherNode) {
                        $name2 = $($property.SiteCode) + "SQLAO2"
                        $OtherNode = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $($RemoteSQLVM.OtherNode) }
                        $OtherNode.vmName = $name2
                        $RemoteSQLVM.OtherNode = $name2
                    }
                    $RemoteSQLVM.vmName = $newSQLName
                    $property.RemoteSQLVM = $newSQLName
                }
            }
            if ($($property.vmName) -ne $newName) {
                $rename = $true
                $response = Read-YesOrNoWithTimeout -Prompt "Rename $($property.vmName) to $($newName)? (Y/n)" -HideHelp -Default "y"
                if (-not [String]::IsNullOrWhiteSpace($response)) {
                    if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                        $rename = $false
                    }
                }
                if ($rename -eq $true) {
                    $property.vmName = $newName
                }
            }
            Write-Verbose "New Name: $newName"
            if ($property.role -eq "CAS") {
                $PRIVMs = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Primary" }
                if ($PRIVMs) {
                    foreach ($PRIVM in $PRIVMs) {
                        if ($PRIVM.ParentSiteCode -eq $CurrentValue ) {
                            $PRIVM.ParentSiteCode = $value
                        }
                    }
                }
                $VMs = @()
                $VMs += $Global:Config.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" }
                if ($VMs) {
                    foreach ($VM in $VMS) {
                        if ($VM.siteCode -eq $CurrentValue ) {
                            $VM.SiteCode = $value
                            Get-AdditionalValidations -property $VM -name "SiteCode" -CurrentValue $CurrentValue
                        }
                    }
                }
            }
            if ($property.role -eq "Primary") {
                $VMs = @()
                $VMs += $Global:Config.virtualMachines | Where-Object { $_.installDP -or $_.enablePullDP }
                $VMs += $Global:Config.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" }
                $SecVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Secondary" }
                if ($VMs) {
                    foreach ($VM in $VMS) {
                        if ($VM.siteCode -eq $CurrentValue ) {
                            $VM.SiteCode = $value
                            Get-AdditionalValidations -property $VM -name "SiteCode" -CurrentValue $CurrentValue
                        }
                    }
                }
                if ($SecVM) {
                    $SecVM.parentSiteCode = $value
                }
            }

            if ($property.role -eq "Secondary") {
                $VMs = $Global:Config.virtualMachines | Where-Object { $_.installDP -or $_.enablePullDP }
                if ($VMs) {
                    foreach ($VM in $VMS) {
                        if ($VM.siteCode -eq $CurrentValue ) {
                            $VM.SiteCode = $value
                        }
                    }
                }
            }
        }
    }
}


Function Get-TestResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Returns true even if warnings are present")]
        [switch] $SuccessOnWarning,
        [Parameter(Mandatory = $false, HelpMessage = "Returns true even if errors are present")]
        [switch] $SuccessOnError,
        [Parameter(Mandatory = $false, HelpMessage = "Config to check")]
        [object] $config = $Global:Config
    )

    #Get-PSCallStack | out-host
    #If Config hasn't been generated yet.. Nothing to test
    if ($null -eq $config) {
        return $true
    }
    try {
        $c = Test-Configuration -InputObject $Config -Fast
        $valid = $c.Valid
        if ($valid -eq $false) {
            $messages = $($c.Message) -split "\r\n"
            foreach ($msg in $messages.Trim()) {
                #Write-RedX $msg
                $global:GenConfigErrorMessages += [PSCustomObject]@{
                    property = $null
                    Level    = "ERROR"
                    Message  = $msg
                }
                Write-Verbose "GenConfig Get-TestResult $msg"
            }
            #Write-ValidationMessages -TestObject $c
            #$MyInvocation | Out-Host
            if ($enableVerbose) {
                Get-PSCallStack | out-host
            }
        }
        if ($SuccessOnWarning.IsPresent) {
            if ( $c.Failures -eq 0) {
                $valid = $true
            }
        }
        if ($SuccessOnError.IsPresent) {
            $valid = $true
        }
    }
    catch {
        return $true
    }
    return $valid
}

function get-IsExistingVMModified {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VirtualMachine Object from config")]
        [object] $virtualMachine
    )

    $modified = $false
    if ($virtualMachine.ExistingVM) {
        foreach ($prop in $virtualMachine.PSObject.Properties) {
            if ($prop.Name.EndsWith("-Original")) {
                $propName = $prop.Name.Replace("-Original", "")
                if ($prop.Value -ne $virtualMachine."$propName") {
                    $modified = $true
                    break
                }
            }
        }
    }
    return $modified
}
