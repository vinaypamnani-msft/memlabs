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
            Write-Log "New-RDCManFile: Could not download latest RDCMan.exe. $_" -Warning -LogOnly
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
        Write-Log "New-RDCManFile: Could not locate $templatefile" -Failure
        return
    }

    # Gets the blank template, or returns the existing settings xml if available.
    $file = $template
    $existingIsPresent = $false
    Write-Log "Checking for $existingfile" -HostOnly
    if (Test-Path $existingfile) {
        [xml]$file = Get-Content -Path $existingfile
        write-verbose "Found existing file at $existingfile"
        $existingIsPresent = $true
    }
    else {
        write-verbose "Using Template file at $templatefile"
    }

    $settings = $file.Settings
    $FilesToOpen = $settings.SelectSingleNode('./FilesToOpen')

    $FilesToOpenFromTemplate = $template.Settings.FilesToOpen

    $found = $false

    #Always update the template so we can use it.
    if ($FilesToOpenFromTemplate.Item -eq "TEMPLATE") {
        $FilesToOpenFromTemplate.Item = $rdcmanfile
        $itemTemplate = $template.Settings.FilesToOpen.SelectSingleNode('./item')
        $settings.DefaultGroupSettings.defaultSettings.logonCredentials.userName = $env:Username
        $settings.DefaultGroupSettings.defaultSettings.logonCredentials.domain = $env:ComputerName
        $settings.DefaultGroupSettings.defaultSettings.encryptionSettings.credentialName = ($($env:ComputerName) + "\" + $($env:Username))
    }
    $settings.DefaultGroupSettings.defaultSettings.securitySettings.authentication = "None"

    #FilesToOpen is missing!?
    if ($null -eq $FilesToOpen) {
        Write-Verbose "FilesToOpen is missing. Adding from Template"
        $newFiles = $FilesToOpenFromTemplate.Clone()
        $FilesToOpen = $file.ImportNode($newFiles, $true)
        $settings.AppendChild($FilesToOpen)
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
    }
    elseif (-not $found) {
        Write-Verbose ("Adding new entry")
        if ($itemTemplate) {
            $clonedNode = $file.ImportNode($itemTemplate, $true)
            $FilesToOpen.AppendChild($clonedNode)
            #$settings.AppendChild($FilesToOpen)
        }
        else {
            Write-Verbose "itemTemplate was null"
        }
    }

    Write-Log "Stopping RDCMan and Saving $existingfile" -HostOnly
    Get-Process -Name rdcman -ea Ignore | Stop-Process
    Start-Sleep 1

    If (-not (test-path $existingfile)) {
        $existingdir = Split-Path $existingfile
        if (-not (test-path $existingdir)) {
            New-Item -ItemType Directory -Force -Path $existingdir | Out-Null
        }
    }
    $file.Save($existingfile)

}

function New-RDCManFile {
    param(
        [object]$DeployConfig,
        [string]$rdcmanfile
    )

    $templatefile = Join-Path $PSScriptRoot "template.rdg"

    # Gets the blank template
    [xml]$template = Get-Content -Path $templatefile
    if ($null -eq $template) {
        Write-Log "New-RDCManFile: Could not locate $templatefile" -Failure
        return
    }

    # Gets the blank template, or returns the existing rdg xml if available.
    $existing = $template
    if (Test-Path $rdcmanfile) {
        [xml]$existing = Get-Content -Path $rdcmanfile
    }

    # This is the bulk of the data.
    $file = $existing.RDCMan.file
    if ($null -eq $file) {
        Write-Log "New-RDCManFile: Could not load File section from $rdcmanfile" -Failure
        return
    }

    $group = $file.group
    if ($null -eq $group) {
        Write-Log "New-RDCManFile: Could not load group section from $rdcmanfile" -Failure
        return
    }

    $groupFromTemplate = $template.RDCMan.file.group
    if ($null -eq $groupFromTemplate) {
        Write-Log "New-RDCManFile: Could not load group section from $templatefile" -Failure
        return
    }

    Install-RDCman

    if (Test-Path "$newrdcmanpath\$rdcmanexe") {
        $encryptedPass = Get-RDCManPassword $newrdcmanpath
        if ($null -eq $encryptedPass) {
            Write-Log "New-RDCManFile: Password was not generated correctly." -Failure
            return
        }
    }
    else {
        Write-Log "New-RDCManFile: Could not locate $rdcmanexe. Please copy $rdcmanexe to C:\tools directory, and try again." -Failure
        return
    }

    # <RDCMan>
    #   <file>
    #     <group>
    #        <logonCredentials>
    #        <server>
    #        <server>
    #     <group>
    #     ...

    $domain = $DeployConfig.vmOptions.domainName
    $findGroup = Get-RDCManGroupToModify $domain $group $findGroup $groupFromTemplate $existing
    if ($findGroup -eq $false -or $null -eq $findGroup) {
        Write-Log "New-RDCManFile: Failed to find group to modify" -Failure
        return
    }

    # Set user/pass on the group
    $username = $DeployConfig.vmOptions.adminName
    $findGroup.logonCredentials.password = $encryptedPass
    if ($findGroup.logonCredentials.username -ne $username) {
        $findGroup.logonCredentials.userName = $username
        $shouldSave = $true
    }

    foreach ($vm in $DeployConfig.virtualMachines) {
        $comment = $vm | ConvertTo-Json
        $name = $vm.vmName
        $displayName = $vm.vmName
        if ((Add-RDCManServerToGroup -ServerName $name -DisplayName $displayName -findgroup $findgroup -groupfromtemplate $groupFromTemplate -existing $existing -comment $comment.ToString()) -eq $True) {
            $shouldSave = $true
        }
    }


    # Add new group
    [void]$file.AppendChild($findgroup)


    # If the original file was a template, remove the templated group.
    if ($group.properties.Name -eq "VMASTEMPLATE") {
        [void]$file.RemoveChild($group)
    }
    Save-RdcManSettignsFile -rdcmanfile $rdcmanfile
    # Save to desired filename
    if ($shouldSave) {
        Write-Log "New-RDCManFile: Killing RDCMan, if necessary and saving resultant XML to $rdcmanfile." -Success
        Get-Process -Name rdcman -ea Ignore | Stop-Process
        Start-Sleep 1
        $existing.save($rdcmanfile) | Out-Null
    }
    else {
        Write-Log "New-RDCManFile: No Changes. Not Saving resultant XML to $rdcmanfile" -Success
    }
}

function New-RDCManFileFromHyperV {
    [CmdletBinding()]
    param(
        [string]$rdcmanfile,
        [bool]$OverWrite = $false
    )

    if ($OverWrite) {
        if (test-path $rdcmanfile) {
            Write-Log "New-RDCManFile: Killing RDCMan, and Deleting $rdcmanfile."
            Get-Process -Name rdcman -ea Ignore | Stop-Process
            Start-Sleep 1
            Remove-Item $rdcmanfile | out-null
        }
    }
    $templatefile = Join-Path $PSScriptRoot "template.rdg"

    # Gets the blank template
    [xml]$template = Get-Content -Path $templatefile
    if ($null -eq $template) {
        Write-Log "New-RDCManFile: Could not locate $templatefile" -Failure
        return
    }

    # Gets the blank template, or returns the existing rdg xml if available.
    if (-not (Test-Path $rdcmanfile)) {
        Copy-Item $templatefile $rdcmanfile
        Write-Verbose "[New-RDCManFileFromHyperV] Loading config from $rdcmanfile"
    }
    [xml]$existing = Get-Content -Path $rdcmanfile
    # This is the bulk of the data.
    $file = $existing.RDCMan.file
    if ($null -eq $file) {
        Write-Log "New-RDCManFile: Could not load File section from $rdcmanfile" -Failure
        return
    }

    $group = $file.group
    if ($null -eq $group) {
        Write-Log "New-RDCManFile: Could not load group section from $rdcmanfile" -Failure
        return
    }

    # If the original file was a template, remove the templated group.
    if ($group.properties.Name -eq "VMASTEMPLATE") {
        [void]$file.RemoveChild($group)
        $group = $null
    }

    $groupFromTemplate = $template.RDCMan.file.group
    if ($null -eq $groupFromTemplate) {
        Write-Log "New-RDCManFile: Could not load group section from $templatefile" -Failure
        return
    }

    Install-RDCman
    foreach ($domain in (Get-List -Type UniqueDomain -ResetCache)) {
        Write-Verbose "[New-RDCManFileFromHyperV] Adding all machines from Domain $domain"
        $findGroup = $null
        $findGroup = Get-RDCManGroupToModify $domain $group $findGroup $groupFromTemplate $existing
        if ($findGroup -eq $false -or $null -eq $findGroup) {
            Write-Log "New-RDCManFile: Failed to find group to modify" -Failure
            return
        }
        Remove-MissingServersFromGroup -findgroup $findGroup
        # Set user/pass on the group
        $username = (Get-List -Type VM -domain $domain | Where-Object { $_.Role -eq 'DC' } | Select-Object -first 1).AdminName

        if (Test-Path "$Global:newrdcmanpath\$rdcmanexe") {
            $encryptedPass = Get-RDCManPassword $Global:newrdcmanpath
            if ($null -eq $encryptedPass) {
                Write-Log "New-RDCManFile: Password was not generated correctly." -Failure
                return
            }
        }
        else {
            Write-Log "New-RDCManFile: Cound not located $rdcmanexe. Please copy $rdcmanexe to C:\tools directory, and try again." -Failure
            return
        }

        $findGroup.logonCredentials.password = $encryptedPass
        if ($findGroup.logonCredentials.username -ne $username) {
            $findGroup.logonCredentials.userName = $username
            $shouldSave = $true
        }

        # $vmList = (Get-List -Type VM -domain $domain).VmName
        $vmListFull = (Get-List -Type VM -domain $domain)

        foreach ($vm in $vmListFull) {
            Write-Verbose "Adding VM $($vm.VmName)"
            $c = [PsCustomObject]@{}
            foreach ($item in $vm | get-member -memberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" } ) { $c | Add-Member -MemberType NoteProperty -Name "$($item.Name)" -Value $($vm."$($item.Name)") }
            if ($vm.Role -eq "DomainMember" -and $null -eq $vm.SqlVersion) {
                $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberServer"
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
                    $displayName = $displayName + "(Missing IP)"
                }
            }
            $ForceOverwrite = $true
            if ((Add-RDCManServerToGroup -ServerName $name -DisplayName $displayName -findgroup $findgroup -groupfromtemplate $groupFromTemplate -existing $existing -comment $comment.ToString() -ForceOverwrite:$ForceOverwrite) -eq $True) {
                $shouldSave = $true
            }
        }
        $CurrentSmartGroups = $findgroup.SelectNodes('smartGroup')
        foreach ($item in $CurrentSmartGroups){
            #Write-Log $item.properties.name
            [void]$findGroup.RemoveChild($item)
        }

        foreach ($item in $groupFromTemplate.SelectNodes('smartGroup')){
            #write-host "template: $($item.properties.name)"
            $clonedItem = $item.clone()
            $clonedItem = $existing.ImportNode($clonedItem, $true)
            [void]$findGroup.AppendChild($clonedItem)
        }
        #$roles = $vmListFull | Select-Object -ExpandProperty role
        #$SmartGroupToClone = $findgroup.SelectNodes('//smartGroup') | Select-Object -First 1
        #$ruleToClone = $SmartGroupToClone.ruleGroup.rule
        #$clonedSG = $SmartGroupToClone.clone()
        #if ($roles -contains "InternetClient") {
        #    $clonedSG = $SmartGroupToClone.clone()
        #    $clonedSG.properties.name = "Members - Internet"
        #    $clonedSG.ruleGroup.rule.value = "InternetClient"
        #    #    $findgroup.AppendChild($clonedSG)
        #}
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

    Remove-MissingDomainsFromFile -file $file
    $unknownVMs = @()
    $unknownVMs += get-list -type vm  | Where-Object { $null -eq $_.Domain -and $null -eq $_.InProgress }
    if ($unknownVMs.Count -gt 0) {
        Write-Verbose "[New-RDCManFileFromHyperV] Adding Unknown VMs"
        $findGroup = $null
        $findGroup = Get-RDCManGroupToModify "UnknownVMs" $group $findGroup $groupFromTemplate $existing
        if ($findGroup -eq $false -or $null -eq $findGroup) {
            Write-Log "New-RDCManFile: Failed to find group to modify" -Failure
            return
        }
        $findGroup.group.properties.expanded = "True"

        $smartGroups = $null
        $smartGroups = $findGroup.SelectNodes('/smartGroup')
        foreach ($smartGroup in $smartGroups) {
            $findgroup.RemoveChild($smartGroup)
        }

        foreach ($vm in $unknownVMs) {
            Write-Verbose "Adding VM $($vm.VmName)"
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

    Save-RdcManSettignsFile -rdcmanfile $rdcmanfile
    # Save to desired filename
    if ($shouldSave) {
        Write-Log "New-RDCManFile: Killing RDCMan, if necessary and saving resultant XML to $rdcmanfile." -Success
        Get-Process -Name rdcman -ea Ignore | Stop-Process
        Start-Sleep 1
        $existing.save($rdcmanfile) | Out-Null
    }
    else {
        Write-Log "New-RDCManFile: No Changes. Not Saving resultant XML to $rdcmanfile" -Success
    }
}

function Remove-MissingServersFromGroup {
    [CmdletBinding()]
    param(
        [object]$findgroup
    )

    $completeServerList = Get-List -Type VM | Select-Object -ExpandProperty vmName
    foreach ($item in $findgroup.group.server) {
        if ($item.properties.displayName -in $completeServerList -or $item.properties.name -in $completeServerList) {
            continue;
        }
        Write-Log ("[Remove-MissingServersFromGroup] Removing $($item.properties.displayName)") -LogOnly
        $findGroup.group.RemoveChild($item) | out-null
    }

}
function Remove-MissingDomainsFromFile {
    [CmdletBinding()]
    param(
        [object]$file
    )
    $domainList = (Get-List -Type UniqueDomain -ResetCache)
    Write-Verbose "[Remove-MissingDomainsFromFile] DomainList: $($domainList -join ",")"
    foreach ($group in $file.SelectNodes("group")) {
        if ($group.properties.name -in $domainList) {
            Write-Verbose "[Remove-MissingDomainsFromFile] Not Deleting : $group.properties.name"
            continue;
        }
        $file.RemoveChild($group) | out-null
    }

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
        [bool]$ForceOverwrite
    )

    if ($ForceOverwrite) {
        #Delete Old Records and let them be regenerated

        $findservers = $findgroup.group.server | Where-Object { $_.properties.displayName -eq $displayName -or $_.properties.displayName -eq $serverName -or $_.properties.name -eq $displayName -or $_.properties.name -eq $serverName }

        foreach ($item in $findservers) {
            Write-Log ("Removing $($item.properties.displayName)") -LogOnly
            $findGroup.group.RemoveChild($item)
        }
    }

    $findserver = $findgroup.group.server | Where-Object { $_.properties.displayName -eq $displayName -or $_.properties.displayName -eq $serverName -or $_.properties.name -eq $displayName -or $_.properties.name -eq $serverName } | Select-Object -First 1
    if ($null -eq $findserver) {
        Write-Log "Add-RDCManServerToGroup: Added $displayName to RDG Group" -LogOnly
        $subgroup = $groupFromTemplate.group
        $server = $groupFromTemplate.SelectNodes('//server') | Select-Object -First 1
        $newserver = $server.clone()
        $newserver.properties.name = $serverName
        $newserver.properties.displayName = $displayName
        $newserver.properties.comment = $comment
        $clonedNode = $existing.ImportNode($newserver, $true)
        $findgroup.group.AppendChild($clonedNode)
        return $True
    }
    else {
        Write-Log "Add-RDCManServerToGroup: $serverName already exists in group. Skipped" -LogOnly
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
        Write-Log "Get-RDCManGroupToModify: Group entry named $domain not found in current xml. Creating new group." -LogOnly
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
        Write-Log "Get-RDCManGroupToModify: Found existing group entry named $domain in current xml." -LogOnly
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
        Write-Log "Get-RDCManPassword: Rdcman.dll was not copied." -Failure
        return $null
    }

    #Write-Host "Get-RDCManPassword: Importing rdcman.dll"
    Import-Module "$($env:temp)\rdcman.dll"
    $EncryptionSettings = New-Object -TypeName RdcMan.EncryptionSettings
    return [RdcMan.Encryption]::EncryptString($Common.LocalAdmin.GetNetworkCredential().Password , $EncryptionSettings)
}
