# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
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

    # Log every banner-visible validation message with caller context so we
    # can correlate the red X / yellow ! on screen with the exact emission
    # site and time. Without this we can't tell live failures from ghosts
    # carried over from prior save attempts.
    try {
        $stack = Get-PSCallStack
        # Skip frame 0 (this function). Prefer the first frame outside this
        # file so 'Convert-ValidationMessages' style funnels show their
        # caller too.
        $thisFile = $PSCommandPath
        $caller = $null
        for ($i = 1; $i -lt $stack.Count; $i++) {
            if (-not $thisFile -or $stack[$i].ScriptName -ne $thisFile) {
                $caller = $stack[$i]
                break
            }
        }
        if (-not $caller -and $stack.Count -gt 1) { $caller = $stack[1] }
        $callerName = if ($caller) { $caller.FunctionName } else { '<unknown>' }
        $callerLine = if ($caller) { $caller.ScriptLineNumber } else { 0 }
        Write-Log "[Add-ErrorMessage] $level $message  (from $callerName`:$callerLine)" -LogOnly
    } catch {
        Write-Log "[Add-ErrorMessage] $level $message" -LogOnly
    }
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
                else {
                    # Remove BitLocker property when TPM is disabled
                    $property.PsObject.Members.Remove("BitLocker")
                }
            }
            elseif ($value -eq $true) {
                # Add BitLocker property if BLM is enabled, VM doesn't already have it,
                # and VM is domain-joined (non-domain roles never receive BLM policy)
                if ($Global:Config.cmOptions -and $Global:Config.cmOptions.EnableBLM -and $property.role -notin 'InternetClient', 'WorkgroupMember', 'AADClient') {
                    if ($null -eq $property.BitLocker) {
                        $isClientOS = $property.operatingSystem -and $property.operatingSystem -like "Windows 1*"
                        $property | Add-Member -MemberType NoteProperty -Name "BitLocker" -Value ([bool]$isClientOS) -Force
                    }
                }
            }
        }

        "enableRDP" {
            # Proxy VM defaults are 1GB/1vCPU which is fine for headless Squid
            # but anaemic for an xfce4 + xrdp session. Bump to 4GB/2 when the
            # user opts in; leave alone if they've already raised the values.
            # Linux VMs are pinned to static memory in New-LinuxVirtualMachine
            # (Hyper-V Dynamic Memory on Linux is historically flaky), so
            # bumping dynamicMinRam wouldn't change runtime RAM -- we have to
            # raise the static 'memory' value itself.
            if ($value -eq $true) {
                if ($property.memory) {
                    $memBytes = 0
                    try { $memBytes = [int64]($property.memory / 1) } catch {}
                    if ($memBytes -gt 0 -and $memBytes -lt 4GB) {
                        $property.memory = "4GB"
                        Add-ErrorMessage -property $name -Warning "Raised memory to 4GB for xrdp + xfce4 session."
                    }
                }
                if ($property.virtualProcs -and [int]$property.virtualProcs -lt 2) {
                    $property.virtualProcs = 2
                    Add-ErrorMessage -property $name -Warning "Raised virtualProcs to 2 for xrdp + xfce4 session."
                }
            }
        }
        "joinDomain" {
            # Mirror the Windows client model for domain-joined Linux VMs: assign
            # a dedicated AD 'user<N>' account when the VM joins the domain. That
            # account is created in AD for free (Common.GenConfig.ps1 aggregates
            # every vm.domainUser into DomainAccountsUPN), granted sudo on the box
            # (realm-join.sh), and used as the default RDCMan/mRemoteNG login.
            # joinDomain only exists on Linux VMs (Windows uses role-based join),
            # so this cascade never touches a Windows VM.
            if ($value -eq $true) {
                if (-not $property.domainUser) {
                    $existingUsers = @(get-list2 -DeployConfig $Global:Config | Where-Object { $_.domainUser } | Select-Object -ExpandProperty domainUser -Unique)
                    $userPrefix = ($Global:Config.vmOptions.prefix).ToLower() + "user"
                    $userNoPrefix = "user"
                    [int]$i = 1
                    while ($true) {
                        $preferredUserName = $userPrefix + $i
                        $noPrefixUserName = $userNoPrefix + $i
                        if ($existingUsers -contains $preferredUserName -or $existingUsers -contains $noPrefixUserName) {
                            $i++
                        }
                        else {
                            $property | Add-Member -MemberType NoteProperty -Name 'domainUser' -Value $noPrefixUserName -Force
                            Add-ErrorMessage -property $name -Warning "Assigned domain user '$noPrefixUserName' (sudo on the VM; default SSH/RDP login)."
                            break
                        }
                    }
                }
            }
            else {
                # joinDomain turned off: drop the auto-assigned domainUser so the
                # standalone Linux VM doesn't carry an unused AD account/login.
                if ($property.PSObject.Properties.Name -contains 'domainUser') {
                    $property.PSObject.Properties.Remove('domainUser')
                }
            }
        }
        "vmGeneration" {
            if ($value -notin ("1", "2")) {
                $property.$name = "2"
            }
            if ($value -eq "1" -and $property.role -ne "OSDClient") {
                Add-ErrorMessage -property $name "Gen 1 is only supported for OSDClient (base images are GPT/UEFI and cannot boot on Gen 1). Changing to Gen 2."
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
        "EnableBLM" {
            if ($value -eq $true) {
                # Add BitLocker property to domain-joined VMs with TPM enabled
                foreach ($vm in $Global:Config.virtualMachines) {
                    if ($vm.tpmEnabled -and $null -eq $vm.BitLocker -and $vm.role -notin 'InternetClient', 'WorkgroupMember', 'AADClient') {
                        $isClientOS = $vm.operatingSystem -and $vm.operatingSystem -like "Windows 1*"
                        $vm | Add-Member -MemberType NoteProperty -Name "BitLocker" -Value ([bool]$isClientOS) -Force
                    }
                }
            }
            else {
                # Remove BitLocker property from all VMs
                foreach ($vm in $Global:Config.virtualMachines) {
                    $vm.PsObject.Members.Remove("BitLocker")
                }
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
        "wsusContentDir" {
            $invalidReason = $null
            $wsusLetter = $null
            if ("$value" -match '^([E-Y]):\\.+') {
                $wsusLetter = $Matches[1].ToUpperInvariant()
            }
            if ($property.ExistingVM) {
                $invalidReason = "WSUS content cannot be moved on an existing VM. Rebuild the VM to change its WSUS disk."
            }
            elseif (-not $wsusLetter -or $wsusLetter -eq 'S') {
                $invalidReason = "WSUS content on a fresh VM must use a dedicated additional disk (E: through Y:, excluding S:)."
            }
            elseif (-not $property.additionalDisks -or -not ($property.additionalDisks.PSObject.Properties.Name -contains $wsusLetter)) {
                $invalidReason = "WSUS content drive $wsusLetter`: is not present in additionalDisks."
            }
            elseif ("$($property.cmInstallDir)" -match "^$wsusLetter`:\\" -or "$($property.sqlInstanceDir)" -match "^$wsusLetter`:\\") {
                $invalidReason = "WSUS content drive $wsusLetter`: is already used by ConfigMgr or SQL. Select a dedicated disk."
            }
            elseif (($property.Role -in @('CAS', 'Primary', 'Secondary') -or $property.InstallDP) -and
                @($property.additionalDisks.PSObject.Properties.Name | Where-Object { $_ -ne $wsusLetter }).Count -eq 0) {
                $invalidReason = "WSUS content drive $wsusLetter`: would leave ConfigMgr without a separate data disk."
            }

            if ($invalidReason) {
                Add-ErrorMessage -property $name $invalidReason
                $property.$name = $CurrentValue
            }
        }
        "installSUP" {
            if ($value -eq $true) {
                if ($property.ExistingVM) {
                    Add-ErrorMessage -property $name "Adding a SUP to an existing VM requires a new VHD and is supported only when creating a fresh VM."
                    $property.installSUP = $CurrentValue
                    return
                }
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
                    if (-not $property.installSUP) {
                        return
                    }
                    if (-not (Set-WsusDedicatedContentDisk -VirtualMachine $property)) {
                        Add-ErrorMessage -property $name "No free data-drive letter is available for a dedicated 250GB WSUS content disk."
                        $property.installSUP = $CurrentValue
                        return
                    }
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
            if ($property.installMP) {
                # Expose the MP database replica toggle on a dedicated SiteSystem MP
                # attached to a Primary (standalone or child) site.
                if ($property.Role -eq "SiteSystem") {
                    $siteRole = get-RoleForSitecode -ConfigToCheck $Global:Config -siteCode $property.siteCode
                    if ($siteRole -notin "CAS", "Secondary") {
                        if ($null -eq $property.useDatabaseReplica) {
                            $property | Add-Member -MemberType NoteProperty -Name "useDatabaseReplica" -Value $false -Force
                        }
                    }
                }
            }
            else {
                # MP removed -> tear down any database replica configuration.
                Remove-MPReplicaLocalSql $property
                $property.PsObject.Members.Remove("replicaSqlServerVM")
                $property.PsObject.Members.Remove("replicaDbName")
                $property.PsObject.Members.Remove("useDatabaseReplica")
            }
            $newName = Rename-VirtualMachine -vm $property
        }
        "useDatabaseReplica" {
            if ($value -eq $true) {
                # Only valid on a dedicated SiteSystem MP attached to a Primary site.
                if ($property.Role -ne "SiteSystem" -or -not $property.installMP) {
                    Add-ErrorMessage -property $name -Warning "Database replica is only supported on a SiteSystem Management Point (installMP)."
                    $property.useDatabaseReplica = $false
                    return
                }
                $siteRole = get-RoleForSitecode -ConfigToCheck $Global:Config -siteCode $property.siteCode
                if ($siteRole -in "CAS", "Secondary") {
                    Add-ErrorMessage -property $name -Warning "Database replica is only supported for Management Points on a Primary site."
                    $property.useDatabaseReplica = $false
                    return
                }
                # Default: host the replica DB on local SQL added to this MP.
                Add-MPReplicaLocalSql $property
                if ([string]::IsNullOrWhiteSpace($property.replicaSqlServerVM)) {
                    $property | Add-Member -MemberType NoteProperty -Name "replicaSqlServerVM" -Value $property.vmName -Force
                }
                if ([string]::IsNullOrWhiteSpace($property.replicaDbName)) {
                    $property | Add-Member -MemberType NoteProperty -Name "replicaDbName" -Value ("CM_" + [string]$property.siteCode) -Force
                }
            }
            else {
                # Disable replica -> remove auto-added local SQL and replica props.
                Remove-MPReplicaLocalSql $property
                $property.PsObject.Members.Remove("replicaSqlServerVM")
                $property.PsObject.Members.Remove("replicaDbName")
            }
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
