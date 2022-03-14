########################
### RDCMan Functions ###
########################


function Install-RDCman {
    # ARM template installs sysinternal tools via choco
    $rdcmanpath = "C:\ProgramData\chocolatey\lib\sysinternals\tools"
    $Global:newrdcmanpath = "C:\tools"
    $rdcmanexe = "RDCMan.exe"

    # create C:\tools if not present
    if (-not (Test-Path $Global:newrdcmanpath)) {
        New-Item -Path $Global:newrdcmanpath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # Download rdcman, if not present
    if (-not (Test-Path "$rdcmanapath\$rdcmanexe")) {

        try {
            $ProgressPreference = 'SilentlyContinue'
            Start-BitsTransfer -Source "https://live.sysinternals.com/$rdcmanexe" -Destination "$Global:newrdcmanpath\$rdcmanexe" -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Could not download latest RDCMan.exe. $_" -Warning -LogOnly
        }
        finally {
            $ProgressPreference = 'Continue'
        }
    }
    else {
        Copy-Item -Path "$rdcmanpath\$rdcmanexe" -Destination "$Global:newrdcmanpath\$rdcmanexe" -Force -ErrorAction SilentlyContinue
    }
    # set file associations
    & cmd /c assoc .rdg=rdcman | Out-Null
    & cmd /c ftype rdcman=$Global:newrdcmanpath\$rdcmanexe | Out-Null

}


function Save-RdcManSettignsFile {
    param(
        [string]$rdcmanfile
    )
    $templatefile = Join-Path $PSScriptRoot "RDCMan.settings.template"
    $existingfile = Join-Path $env:LOCALAPPDATA "\Microsoft\Remote Desktop Connection Manager\RDCMan.settings"
    # Gets the blank template
    [xml]$template = Get-Content -Path $templatefile
    if ($null -eq $template) {
        Write-Log "Could not locate $templatefile" -Failure
        return
    }
    $modified = $false
    # Gets the blank template, or returns the existing settings xml if available.
    $file = $template
    Write-Verbose "Checking for $existingfile"
    if (Test-Path $existingfile) {
        [xml]$file = Get-Content -Path $existingfile
        write-verbose "Found existing file at $existingfile"
    }
    else {
        write-verbose "Using Template file at $templatefile"
        $modified = $true
    }

    $settings = $file.Settings
    $FilesToOpen = $settings.SelectSingleNode('./FilesToOpen')

    $FilesToOpenFromTemplate = $template.Settings.FilesToOpen

    $found = $false
    #Always update the template so we can use it.
    if ($FilesToOpenFromTemplate.Item -eq "TEMPLATE") {
        $FilesToOpenFromTemplate.Item = $rdcmanfile
        $itemTemplate = $template.Settings.FilesToOpen.SelectSingleNode('./item')
        if ($settings.DefaultGroupSettings.defaultSettings.logonCredentials.userName -ne $env:Username) {
            $settings.DefaultGroupSettings.defaultSettings.logonCredentials.userName = $env:Username
            $modified = $true
        }
        if ( $settings.DefaultGroupSettings.defaultSettings.logonCredentials.domain -ne $env:ComputerName) {
            $settings.DefaultGroupSettings.defaultSettings.logonCredentials.domain = $env:ComputerName
            $modified = $true
        }
        if ($settings.DefaultGroupSettings.defaultSettings.encryptionSettings.credentialName -ne ($($env:ComputerName) + "\" + $($env:Username))) {
            $settings.DefaultGroupSettings.defaultSettings.encryptionSettings.credentialName = ($($env:ComputerName) + "\" + $($env:Username))
            $modified = $true
        }
    }
    if ($settings.DefaultGroupSettings.defaultSettings.securitySettings.authentication -ne "None") {
        $settings.DefaultGroupSettings.defaultSettings.securitySettings.authentication = "None"
        $modified = $true
    }

    #FilesToOpen is missing!?
    if ($null -eq $FilesToOpen) {
        Write-Verbose "FilesToOpen is missing. Adding from Template"
        $newFiles = $FilesToOpenFromTemplate.Clone()
        $FilesToOpen = $file.ImportNode($newFiles, $true)
        $settings.AppendChild($FilesToOpen)
        $modified = $true
    }

    $FilesToOpenCount = 0
    if (-not ($FilesToOpen -is [string])) {
        foreach ($item in $FilesToOpen.SelectNodes('./item')) {
            #write-host "Inner: $($item.InnerText)"
            $FilesToOpenCount++
            if ($item.InnerText -eq $rdcmanfile) {
                $found = $true
                Write-Verbose "Found existing entry for $rdcmanfile"
                break
            }
        }
    }
    #$itemTemplate = $FilesToOpenFromTemplate.item
    #write-host "item: $($FilesToOpenFromTemplate.Item)"


    #Write-Host "Count: $FilesToOpenCount"
    #FilesToOpen is blank
    if (($FilesToOpenCount -eq 0) ) {
        Write-Verbose "[Save-RdcManSettignsFile] Copying FilesToOpen from template, since it was missing in existing file"
        $settings.RemoveChild($FilesToOpen)
        $newFiles = $FilesToOpenFromTemplate.Clone()
        $FilesToOpen = $file.ImportNode($newFiles, $true)

        $settings.AppendChild($FilesToOpen)
        $modified = $true
    }
    elseif (-not $found) {
        Write-Verbose ("Adding new entry")
        if ($itemTemplate) {
            $clonedNode = $file.ImportNode($itemTemplate, $true)
            $FilesToOpen.AppendChild($clonedNode)
            $modified = $true
            #$settings.AppendChild($FilesToOpen)
        }
        else {
            Write-Verbose "itemTemplate was null"
        }
    }

    if ($modified) {
        Write-Verbose "Stopping RDCMan and Saving $existingfile"
        $proc = Get-Process -Name rdcman -ea Ignore
        $killed = $false
        if ($proc) {
            $killed = $true
        }
        $proc | Stop-Process
        Start-Sleep 1

        If (-not (test-path $existingfile)) {
            $existingdir = Split-Path $existingfile
            if (-not (test-path $existingdir)) {
                New-Item -ItemType Directory -Force -Path $existingdir | Out-Null
            }
        }
        $file.Save($existingfile)
        return $killed
    }
    return $false
}
#
#function New-RDCManFile {
#    param(
#        [object]$DeployConfig,
#        [string]$rdcmanfile
#    )
#
#    Write-Log "Creating/Updating MEMLabs.RDG file on Desktop (RDCMan.exe is located in C:\tools)" -Activity
#
#    $templatefile = Join-Path $PSScriptRoot "template.rdg"
#
#    # Gets the blank template
#    [xml]$template = Get-Content -Path $templatefile
#    if ($null -eq $template) {
#        Write-Log "Could not locate $templatefile" -Failure
#        return
#    }
#
#    # Gets the blank template, or returns the existing rdg xml if available.
#    $existing = $template
#    if (Test-Path $rdcmanfile) {
#        [xml]$existing = Get-Content -Path $rdcmanfile
#    }
#
#    # This is the bulk of the data.
#    $file = $existing.RDCMan.file
#    if ($null -eq $file) {
#        Write-Log "Could not load File section from $rdcmanfile" -Failure
#        return
#    }
#
#    $group = $file.group
#    if ($null -eq $group) {
#        Write-Log "Could not load group section from $rdcmanfile" -Failure
#        return
#    }
#
#    $groupFromTemplate = $template.RDCMan.file.group
#    if ($null -eq $groupFromTemplate) {
#        Write-Log "Could not load group section from $templatefile" -Failure
#        return
#    }
#
#    Install-RDCman
#
#    if (Test-Path "$newrdcmanpath\$rdcmanexe") {
#        $encryptedPass = Get-RDCManPassword $newrdcmanpath
#        if ($null -eq $encryptedPass) {
#            Write-Log "Password was not generated correctly." -Failure
#            return
#        }
#    }
#    else {
#        Write-Log "Could not locate $rdcmanexe. Please copy $rdcmanexe to C:\tools directory, and try again." -Failure
#        return
#    }
#
#    # <RDCMan>
#    #   <file>
#    #     <group>
#    #        <logonCredentials>
#    #        <server>
#    #        <server>
#    #     <group>
#    #     ...
#
#    $domain = $DeployConfig.vmOptions.domainName
#    $findGroup = Get-RDCManGroupToModify $domain $group $findGroup $groupFromTemplate $existing
#    if ($findGroup -eq $false -or $null -eq $findGroup) {
#        Write-Log "Failed to find group to modify" -Failure
#        return
#    }
#
#    # Set user/pass on the group\
#    $pname = $findGroup.logonCredentials.profileName.'#text'
#    if ($pname -eq "Custom") {
#        #write-host "ProfileName is $($pname)"
#        $username = $DeployConfig.vmOptions.adminName
#        $findGroup.logonCredentials.password = $encryptedPass
#        if ($findGroup.logonCredentials.username -ne $username) {
#            $findGroup.logonCredentials.userName = $username
#            $shouldSave = $true
#        }
#    }
#
#    foreach ($vm in $DeployConfig.virtualMachines) {
#        $comment = $vm | ConvertTo-Json
#        $name = $vm.vmName
#        $displayName = $vm.vmName
#        if ((Add-RDCManServerToGroup -ServerName $name -DisplayName $displayName -findgroup $findgroup -groupfromtemplate $groupFromTemplate -existing $existing -comment $comment.ToString()) -eq $True) {
#            $shouldSave = $true
#        }
#    }
#
#
#    # Add new group
#    [void]$file.AppendChild($findgroup)
#
#
#    # If the original file was a template, remove the templated group.
#    if ($group.properties.Name -eq "VMASTEMPLATE") {
#        [void]$file.RemoveChild($group)
#    }
#    Save-RdcManSettignsFile -rdcmanfile $rdcmanfile
#    # Save to desired filename
#    if ($shouldSave) {
#        Write-Log "Killing RDCMan, if necessary and saving $rdcmanfile." -Success
#        Get-Process -Name rdcman -ea Ignore | Stop-Process
#        Start-Sleep 1
#        $existing.save($rdcmanfile) | Out-Null
#    }
#    else {
#        Write-Log "No Changes. Not updating $rdcmanfile" -Success
#    }
#}

function New-RDCManFileFromHyperV {
    [CmdletBinding()]
    param(
        [string]$rdcmanfile,
        [bool]$OverWrite = $false,
        [switch]$NoActivity,
        [switch]$WhatIf
    )

    if ($WhatIf.IsPresent) {
        Write-Log "[WhatIf] Will update MEMLabs.RDG file on Desktop, if needed."
        return
    }

    $Activity = -not $NoActivity.IsPresent
    Write-Log "Updating MEMLabs.RDG file on Desktop (RDCMan.exe is located in C:\tools)" -Activity:$Activity

    if ($OverWrite) {
        if (test-path $rdcmanfile) {
            Write-Log "Regenerating new MEMLabs.RDG: stopping RDCMan.exe, and Deleting $rdcmanfile."
            Get-Process -Name rdcman -ea Ignore | Stop-Process
            Start-Sleep 1
            Remove-Item $rdcmanfile | out-null
        }
    }
    try {
        $templatefile = Join-Path $PSScriptRoot "template.rdg"

        # Gets the blank template
        [xml]$template = Get-Content -Path $templatefile
        if ($null -eq $template) {
            Write-Log "Could not locate $templatefile" -Failure
            if ($OverWrite -eq $false) {
                return New-RDCManFileFromHyperV -rdcmanfile $rdcmanfile -OverWrite $true
            }
            else {
                return
            }
        }

        # Gets the blank template, or returns the existing rdg xml if available.
        if (-not (Test-Path $rdcmanfile)) {
            Copy-Item $templatefile $rdcmanfile
            Write-Verbose "Loading config from $rdcmanfile"
        }
        [xml]$existing = Get-Content -Path $rdcmanfile
        # This is the bulk of the data.
        $file = $existing.RDCMan.file
        if ($null -eq $file) {
            Write-Log "Could not load File section from $rdcmanfile" -Failure
            if ($OverWrite -eq $false) {
                return New-RDCManFileFromHyperV -rdcmanfile $rdcmanfile -OverWrite $true
            }
            else {
                return
            }
        }

        $group = $file.group
        if ($null -eq $group) {
            Write-Log "Could not load group section from $rdcmanfile" -Failure
            if ($OverWrite -eq $false) {
                return New-RDCManFileFromHyperV -rdcmanfile $rdcmanfile -OverWrite $true
            }
            else {
                return
            }
        }

        # If the original file was a template, remove the templated group.
        if ($group.properties.Name -eq "VMASTEMPLATE") {
            [void]$file.RemoveChild($group)
            $group = $null
        }

        $groupFromTemplate = $template.RDCMan.file.group
        if ($null -eq $groupFromTemplate) {
            Write-Log "Could not load group section from $templatefile" -Failure
            return
        }
    }
    catch {
        if ($OverWrite -eq $false) {
            return New-RDCManFileFromHyperV -rdcmanfile $rdcmanfile -OverWrite $true
        }
    }
    Install-RDCman
    $domainList = (Get-List -Type UniqueDomain -SmartUpdate)
    foreach ($domain in $domainList) {
        Write-Verbose "Adding all machines from Domain $domain"
        $findGroup = $null
        $findGroup = Get-RDCManGroupToModify $domain $group $findGroup $groupFromTemplate $existing
        if ($findGroup -eq $false -or $null -eq $findGroup) {
            Write-Log "Failed to find group to modify" -Failure
            return
        }
        if (Remove-MissingServersFromGroup -findgroup $findGroup) {
            $shouldSave = $true
        }
        # Set user/pass on the group
        $username = (Get-List -Type VM -domain $domain | Where-Object { $_.Role -eq 'DC' } | Select-Object -first 1).AdminName

        if ($null -eq $username) {
            Write-Log "Could not determine username from DC config for domain $domain. Assuming username is 'admin'"
            $username = "admin"
        }

        if (Test-Path "$Global:newrdcmanpath\$rdcmanexe") {
            $encryptedPass = Get-RDCManPassword $Global:newrdcmanpath
            if ($null -eq $encryptedPass) {
                Write-Log "Password was not generated correctly." -Failure
                return
            }
        }
        else {
            Write-Log "Could not located $rdcmanexe. Please copy $rdcmanexe to C:\tools directory, and try again." -Failure
            return
        }



        # Set user/pass on the group\
        $pname = $findGroup.logonCredentials.profileName.'#text'
        if ($pname -eq "Custom") {
            $findGroup.logonCredentials.password = $encryptedPass
            if ($findGroup.logonCredentials.username -ne $username) {
                $findGroup.logonCredentials.userName = $username
                $shouldSave = $true
            }
        }
        # $vmList = (Get-List -Type VM -domain $domain).VmName
        $vmListFull = (Get-List -Type VM -domain $domain)

        foreach ($vm in $vmListFull) {
            Write-Verbose "Adding VM $($vm.VmName)"
            $c = [PsCustomObject]@{}
            foreach ($item in $vm | get-member -memberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" } ) { $c | Add-Member -MemberType NoteProperty -Name "$($item.Name)" -Value $($vm."$($item.Name)") }

            if ($vm.Role -eq "DomainMember" -or $vm.Role -eq "WorkgroupMember") {
                if ( $null -eq $vm.SqlVersion -and $vm.deployedOS.Contains("Server")) {
                    $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberServer"
                }
                else {
                    if (-not ($vm.deployedOS.Contains("Server"))) {
                        $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberClient"
                    }
                }

            }

            $comment = $c | ConvertTo-Json

            $name = $($vm.VmName)
            $rolename = ""
            $ForceOverwrite = $false
            switch ($vm.Role) {
                "DomainMember" { if ($null -eq $vm.SqlVersion) { $rolename = "[AD] " } }
                "InternetClient" {
                    $ForceOverwrite = $true
                    $rolename = "[Internet] "
                }
                "AADClient" {
                    $ForceOverwrite = $true
                    $rolename = "[AAD] "
                }
                "WorkgroupMember" { $rolename = "[WG] " }
                Default {}
            }
            $displayName = $rolename + $($vm.VmName)
            if ($vm.SiteCode) {
                $displayName += " ($($vm.SiteCode)"
                if ($vm.ParentSiteCode) {
                    $displayName += "->$($vm.ParentSiteCode)"
                }
                $displayName += ")"
            }
            if ($vm.Role -eq "AADClient" -or $vm.Role -eq "InternetClient") {
                if (-not [string]::IsNullOrWhiteSpace($vm.LastKnownIP)) {
                    $name = $vm.LastKnownIP
                }
                else {
                    $IP = (get-vm2 -name $vm.Name | Get-VMNetworkAdapter).IPAddresses | Where-Object { $_ -notlike "*:*" } | Select-Object -First 1
                    if ($IP) {
                        $name = $IP
                    }
                    else {
                        $displayName = $displayName + "(Missing IP)"
                    }
                }
            }
            if ($vm.domainUser) {
                $displayName = $displayName + " ($($vm.domainUser))"
            }
            $ForceOverwrite = $true
            $vmID = $null
            if ($vm.Role -eq "OSDClient" -or $vm.Role -eq "AADClient") {
                $vmID = $vm.vmId
            }

            if ((Add-RDCManServerToGroup -ServerName $name -DisplayName $displayName -findgroup $findgroup -groupfromtemplate $groupFromTemplate -existing $existing -comment $comment.ToString() -ForceOverwrite:$ForceOverwrite -vmID $vmID -domain $vm.Domain -username $vm.domainUser) -eq $True) {
                $shouldSave = $true
            }
        }
        $CurrentSmartGroups = $findgroup.SelectNodes('smartGroup')
        foreach ($item in $CurrentSmartGroups) {
            #Write-Log $item.properties.name
            [void]$findGroup.RemoveChild($item)
        }

        foreach ($item in $groupFromTemplate.SelectNodes('smartGroup')) {
            #write-host "template: $($item.properties.name)"
            $clonedItem = $item.clone()
            $clonedItem = $existing.ImportNode($clonedItem, $true)
            [void]$findGroup.AppendChild($clonedItem)
        }
        $roles = $vmListFull | Select-Object -ExpandProperty role
        $SmartGroupToClone = $findgroup.SelectNodes('//smartGroup') | where-object { $_.properties.name -eq "Servers" } | Select-Object -First 1
        #write-host $SmartGroupToClone.properties.name
        #$ruleToClone = $SmartGroupToClone.ruleGroup.rule
        $clonedSG = $SmartGroupToClone.clone()
        if ($roles -contains "OSDClient" -or $roles -contains "AADClient") {
            $clonedSG = $SmartGroupToClone.clone()
            $clonedSG.properties.name = "OSD Clients"
            $clonedSG.ruleGroup.rule.value = "OSDClient"
            [void]$findgroup.AppendChild($clonedSG)
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowDefaultCredentialsDomain -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowSavedCredentialsDomain -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowDefaultCredentials -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowFreshCredentialsDomain -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowFreshCredentials -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowFreshCredentialsWhenNTLMOnly -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowFreshCredentialsWhenNTLMOnlyDomain -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowSavedCredentials -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
            New-ItemProperty -Path HKLM:SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults\AllowSavedCredentialsWhenNTLMOnly -Name Hyper-V -PropertyType String -Value "Microsoft Virtual Console Service/*" -Force | Out-Null
        }
        #if ($roles -contains "AADClient") {
        #    Write-Host "Adding SmartGroup AAD Clients"
        #    $clonedSG = $SmartGroupToClone.clone()
        #    $clonedSG.properties.name = "Members - AAD"
        #    $clonedSG.ruleGroup.rule.value = "AADClient"
        #    #    $findgroup.AppendChild($clonedSG)
        #}
        #if ($roles -contains "WorkgroupMember") {
        #    $clonedSG = $SmartGroupToClone.clone()
        #    $clonedSG.properties.name = "Members - Workgroup"
        #    $clonedSG.ruleGroup.rule.value = "WorkgroupMember"
        #    #    $findgroup.AppendChild($clonedSG)
        #}
        # Add new group
        [void]$file.AppendChild($findgroup)

    }

    if (Remove-MissingDomainsFromFile -file $file) {
        $shouldSave = $true
    }
    $unknownVMs = @()
    $unknownVMs += get-list -type vm | Where-Object { $null -eq $_.Domain -and $null -eq $_.InProgress }
    if ($unknownVMs.Count -gt 0) {
        Write-Verbose "New-RDCManFileFromHyperV: Adding Unknown VMs"
        $findGroup = $null
        $findGroup = Get-RDCManGroupToModify "UnknownVMs" $group $findGroup $groupFromTemplate $existing
        if ($findGroup -eq $false -or $null -eq $findGroup) {
            Write-Log "Failed to find group to modify" -Failure
            return
        }
        $findGroup.group.properties.expanded = "True"

        $smartGroups = $null
        $smartGroups = $findGroup.SelectNodes('/smartGroup')
        foreach ($smartGroup in $smartGroups) {
            [void]$findgroup.RemoveChild($smartGroup)
        }

        foreach ($vm in $unknownVMs) {
            Write-Verbose "New-RDCManFileFromHyperV: Adding VM $($vm.VmName)"
            $c = [PsCustomObject]@{}
            foreach ($item in $vm | get-member -memberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" } ) { $c | Add-Member -MemberType NoteProperty -Name "$($item.Name)" -Value $($vm."$($item.Name)") }
            $comment = $c | ConvertTo-Json
            $name = $($vm.VmName)
            $displayName = $($vm.VmName)
            if ((Add-RDCManServerToGroup -ServerName $name -DisplayName $displayName -findgroup $findgroup -groupfromtemplate $groupFromTemplate -existing $existing -comment $comment.ToString()) -eq $True) {
                $shouldSave = $true
            }
        }

        # Add new group
        [void]$file.AppendChild($findgroup)
    }

    $killed = Save-RdcManSettignsFile -rdcmanfile $rdcmanfile
    # Save to desired filename
    if ($shouldSave) {
        try {

            $proc = $null
            $proc = Get-Process -Name rdcman -ea Ignore | Select-Object -First 1
            if ($proc) {
                $killed = $true
                Get-Process -Name rdcman -ea Ignore | Stop-Process
            }
            Start-Sleep 1
            $existing.save($rdcmanfile) | Out-Null
            Write-GreenCheck "Updated $rdcmanfile. Restarting the process if possible" -ForegroundColor ForestGreen

        }
        catch {
            Write-RedX "Could not update $rdcmanfile. $_"
        }
    }
    else {
        Write-Log "No Changes. Not updating $rdcmanfile" -Success -Verbose
    }
    if ($killed) {

        #Write-GreenCheck "Calling Start-Process on C:\Tools\RDCMan.exe"
        Start-Process "C:\tools\RDCMan.exe" -WindowStyle Minimized -WorkingDirectory "C:\Temp" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }
}

function Remove-MissingServersFromGroup {
    [CmdletBinding()]
    param(
        [object]$findgroup
    )

    $return = $false

    $completeServerList = Get-List -Type VM | Select-Object -ExpandProperty vmName
    foreach ($item in $findgroup.group.server) {
        if ($item.properties.displayName -in $completeServerList -or $item.properties.name -in $completeServerList) {
            continue;
        }
        Write-Log ("Removing $($item.properties.displayName)") -LogOnly -Verbose
        $findGroup.group.RemoveChild($item) | out-null
        $return = $true
    }

    return $return
}
function Remove-MissingDomainsFromFile {
    [CmdletBinding()]
    param(
        [object]$file
    )
    $return = $false
    $domainList = (Get-List -Type UniqueDomain -SmartUpdate)
    Write-Verbose "[Remove-MissingDomainsFromFile] DomainList: $($domainList -join ",")"
    foreach ($group in $file.SelectNodes("group")) {
        if ($group.properties.name -in $domainList) {
            #Write-Verbose "[Remove-MissingDomainsFromFile] Not Deleting : $group.properties.name"
            continue;
        }
        Write-Verbose "[Remove-MissingDomainsFromFile] Deleting : $($group.properties.name)"
        $file.RemoveChild($group) | out-null
        $return = $true
    }

    return $return
}

function Add-RDCManServerToGroup {
    [CmdletBinding()]
    param(
        [string]$serverName,
        [string]$displayName,
        [object]$findgroup,
        [object]$groupFromTemplate,
        [object]$existing,
        [string]$comment,
        [string]$vmID = $null,
        [string]$username = $null,
        [string]$domain = $null,
        [bool]$ForceOverwrite
    )

    #<connectionType>VirtualMachineConsoleConnect</connectionType>
    #<vmId>TEMPLATE</vmId>

    if (-not [string]::IsNullOrWhiteSpace($vmID)) {
        $displayName = "[console] " + $displayName
    }

    if ($ForceOverwrite) {
        #Delete Old Records and let them be regenerated

        $findservers = $findgroup.group.server | Where-Object { $_.properties.displayName -eq $displayName -or $_.properties.displayName -eq $serverName -or $_.properties.name -eq $displayName -or $_.properties.name -eq $serverName }

        foreach ($item in $findservers) {
            Write-Log ("Removing $($item.properties.displayName)") -LogOnly -Verbose
            $findGroup.group.RemoveChild($item)
        }
    }

    $findserver = $findgroup.group.server | Where-Object { $_.properties.displayName -eq $displayName -or $_.properties.displayName -eq $serverName -or $_.properties.name -eq $displayName -or $_.properties.name -eq $serverName } | Select-Object -First 1
    if ($null -eq $findserver) {
        Write-Log "Added $displayName to RDG Group" -LogOnly -Verbose
        #$subgroup = $groupFromTemplate.group
        $server = $groupFromTemplate.SelectNodes('//server') | Select-Object -First 1
        $newserver = $server.clone()
        $newserver.properties.name = $serverName
        $newserver.properties.displayName = $displayName
        $newserver.properties.comment = $comment


        $clonedNode = $existing.ImportNode($newserver, $true)
        if (-not [string]::IsNullOrWhiteSpace($vmID)) {

            [xml]$logonCredsXml = @"
            <logonCredentials inherit="None">
             <profileName scope="Local">Custom</profileName>
             <userName>labadmin</userName>
             <password />
             <domain />
            </logonCredentials>
"@
            $clonedNode.AppendChild($existing.ImportNode($logonCredsXml.logonCredentials, $true))
            $clonedNode.logonCredentials.userName = $env:username
            $clonedNode.properties.name = $env:computername
            $e = $existing.CreateElement("connectionType")
            $e.set_InnerText("VirtualMachineConsoleConnect")
            $clonedNode2 = $existing.ImportNode($e, $true)
            [void]$clonedNode.properties.AppendChild($clonedNode2)
            $f = $existing.CreateElement("vmId")
            $f.set_InnerText($vmID)
            $clonedNode2 = $existing.ImportNode($f, $true)
            [void]$clonedNode.properties.AppendChild($clonedNode2)
        }

        if (-not [string]::IsNullOrWhiteSpace($username)) {

            [xml]$logonCredsXml = @"
            <logonCredentials inherit="None">
             <profileName scope="Local">Custom</profileName>
             <userName>labadmin</userName>
             <password>password</password>
             <domain>domain</domain>
            </logonCredentials>
"@
            $clonedNode.AppendChild($existing.ImportNode($logonCredsXml.logonCredentials, $true))
            $clonedNode.logonCredentials.userName = $username
            $clonedNode.logonCredentials.domain = $domain
            $encryptedPass = Get-RDCManPassword $Global:newrdcmanpath
            if ($null -eq $encryptedPass) {
                Write-Log "Password was not generated correctly." -Failure
                return
            }
            $clonedNode.logonCredentials.password = $encryptedPass
        }
        $findgroup.group.AppendChild($clonedNode)
        return $True
    }
    else {
        Write-Log "$serverName already exists in group. Skipped" -LogOnly
        return $False
    }
    return $False
}

# This gets the <Group> section from the template. Either makes a new one, or returns an existing one.
# If a new one is created, the <server> nodes will not exist.
function Get-RDCManGroupToModify {
    param(
        [string]$domain,
        $group,
        $findGroup,
        $groupFromTemplate,
        $existing
    )

    if ($null -ne $group) {
        $findGroup = $group | Where-Object { $_.properties.name -eq $domain } | Select-Object -First 1
    }
    if ($null -eq $findGroup) {
        Write-Log "Group entry named $domain not found in current xml. Creating new group." -LogOnly
        $findGroup = $groupFromTemplate.Clone()
        $findGroup.properties.name = $domain
        $findGroup.logonCredentials.domain = $domain
        $subgroup = $findGroup.group
        $ChildNodes = $subgroup.SelectNodes('//server')
        foreach ($Child in $ChildNodes) {
            [void]$Child.ParentNode.RemoveChild($Child)
        }
        $findGroup = $existing.ImportNode($findGroup, $true)
    }
    else {
        Write-Log "Found existing group entry named $domain in current xml." -LogOnly -Verbose
    }
    return $findGroup
}

function Get-RDCManPassword {
    param(
        [string]$rdcmanpath
    )

    if (-not(test-path "$($env:temp)\rdcman.dll")) {
        # Write-Log "Get-RDCManPassword: Rdcman.dll not found in $($env:temp). Copying."
        copy-item "$($rdcmanpath)\rdcman.exe" "$($env:temp)\rdcman.dll" -Force
        unblock-file "$($env:temp)\rdcman.dll"
    }


    if (-not(test-path "$($env:temp)\rdcman.dll")) {
        Write-Log "Rdcman.dll was not copied." -Failure
        return $null
    }

    #Write-Host "Get-RDCManPassword: Importing rdcman.dll"
    Import-Module "$($env:temp)\rdcman.dll"
    $EncryptionSettings = New-Object -TypeName RdcMan.EncryptionSettings
    return [RdcMan.Encryption]::EncryptString($Common.LocalAdmin.GetNetworkCredential().Password , $EncryptionSettings)
}
