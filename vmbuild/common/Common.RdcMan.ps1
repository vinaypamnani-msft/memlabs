# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
########################
### RDCMan Functions ###
########################


function Install-RDCman {
    # ARM template installs sysinternals tools via choco
    $rdcmanpath = "C:\ProgramData\chocolatey\lib\sysinternals\tools"
    $Global:newrdcmanpath = "C:\tools"
    $rdcmanexe = "RDCMan.exe"

    # create C:\tools if not present
    if (-not (Test-Path $Global:newrdcmanpath)) {
        New-Item -Path $Global:newrdcmanpath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # Download rdcman, if not present
    if (-not (Test-Path "$rdcmanpath\$rdcmanexe")) {

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


function Save-RdcManSettingsFile {
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

    # Ensure v3.12 securitySettings children exist (old templates omitted these)
    $secNode = $settings.DefaultGroupSettings.defaultSettings.securitySettings
    $v312SecDefaults = @{
        enableCredSspSupport = "True"
        enableRdsAadAuth    = "False"
        restrictedAdmin     = "False"
        remoteGuard         = "False"
    }
    foreach ($name in $v312SecDefaults.Keys) {
        if ($null -eq $secNode.SelectSingleNode($name)) {
            $elem = $file.CreateElement($name)
            $elem.InnerText = $v312SecDefaults[$name]
            [void]$secNode.AppendChild($elem)
            $modified = $true
        }
    }

    # Ensure v3.12 localResources children exist
    $lrNode = $settings.DefaultGroupSettings.defaultSettings.localResources
    if ($lrNode) {
        foreach ($name in @("redirectWebAuthn", "redirectLocation")) {
            if ($null -eq $lrNode.SelectSingleNode($name)) {
                $elem = $file.CreateElement($name)
                $elem.InnerText = "False"
                [void]$lrNode.AppendChild($elem)
                $modified = $true
            }
        }
    }

    # Ensure v3.12 displaySettings/dpiScaling exists
    $dsNode = $settings.DefaultGroupSettings.defaultSettings.displaySettings
    if ($dsNode -and $null -eq $dsNode.SelectSingleNode("dpiScaling")) {
        $elem = $file.CreateElement("dpiScaling")
        $elem.InnerText = "AsHost"
        [void]$dsNode.AppendChild($elem)
        $modified = $true
    }

    if ($settings.GroupSortOrder -ne "None") {
        $settings.GroupSortOrder = "None"
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
        Write-Verbose "[Save-RdcManSettingsFile] Copying FilesToOpen from template, since it was missing in existing file"
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
#    Save-RdcManSettingsFile -rdcmanfile $rdcmanfile
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

function Get-RDCManOSShortName {
    param([string]$deployedOS)
    if ([string]::IsNullOrWhiteSpace($deployedOS)) { return $null }
    switch -Wildcard ($deployedOS) {
        "Server 2025*"     { return "S25" }
        "Server 2022*"     { return "S22" }
        "Server 2019*"     { return "S19" }
        "Server 2016*"     { return "S16" }
        "Windows 11*"      { return "W11" }
        "Windows 10*"      { return "W10" }
        default            { return $null }
    }
}

function New-RDCManFileFromHyperV {
    [CmdletBinding()]
    param(
        [string]$rdcmanfile,
        [bool]$OverWrite = $false,
        [switch]$NoActivity,
        [switch]$UseIP,
        [switch]$WhatIf
    )

    if ($WhatIf.IsPresent) {
        Write-Log "[WhatIf] Will update MEMLabs.RDG file on Desktop, if needed."
        return
    }

    $Activity = -not $NoActivity.IsPresent
    Write-Log "Updating MEMLabs.RDG file on Desktop (RDCMan.exe is located in C:\tools)" -Activity:$Activity

    # Bulk-fetch all VM network adapters in one WMI call so per-VM cache
    # lookups during Get-VMFromHyperV are instant instead of ~3s each.
    Invoke-VMNetworkBulkWarmup

    if ($OverWrite) {
        if (test-path $rdcmanfile) {
            Write-Log "Stopping RDCMan.exe, deleting $rdcmanfile, and regenerating a new MEMLabs.RDG."
            $p = Get-Process -Name rdcman -ea Ignore
            if ($p) {
                $p | Stop-Process -force
                $killedAlready = $true
            }
            Start-Sleep 1
            Remove-Item $rdcmanfile -ProgressAction SilentlyContinue| out-null
        }
        $shouldSave = $true
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
            Get-Content -Path $rdcmanfile | Out-Host
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

        # Every server node is rebuilt from the template below, which is what has been
        # silently discarding trust the user clicked in RDCMan's dialog. Lift those hashes
        # out before that happens: a trust already in the file is authoritative evidence of
        # what the endpoint presents, and reading it needs no running guest -- so this also
        # back-fills the note for a VM that is powered off.
        $existingCerts = @{}
        foreach ($certNode in @($existing.SelectNodes('//server/trustedCertificates/certificate'))) {
            $ep = "$($certNode.GetAttribute('endpoint'))"
            $sha = "$($certNode.GetAttribute('sha256'))"
            if ($ep -and $sha) { $existingCerts[$ep.ToLowerInvariant()] = $sha }
        }
        if ($existingCerts.Count -gt 0) {
            Write-Log "Preserving $($existingCerts.Count) trusted certificate(s) already in $rdcmanfile." -LogOnly -Verbose
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

        $cmVersion = $null
        $dcVM = $vmListFull | Where-Object { $_.Role -eq 'DC' } | Select-Object -First 1
        if ($dcVM.domainDefaults.CMVersion) {
            $cmVersion = "CM" + $dcVM.domainDefaults.CMVersion
        }

        # Compute MECM site hierarchy for per-site group generation
        $siteHierarchy = Get-MECMSiteHierarchy -VmListFull $vmListFull

        # Build client→siteCode map: for each client VM, determine which
        # Primary site would push the ConfigMgr client to it (same logic
        # as Common.GenConfig.ps1 ClientPush — network affinity).
        $clientPushSiteMap = @{}
        if ($siteHierarchy -and $siteHierarchy.Sites.Count -gt 0) {
            $primaries = $vmListFull | Where-Object { $_.Role -eq "Primary" }
            foreach ($pri in $primaries) {
                $priNetwork = $pri.network
                $priSiteCode = $pri.SiteCode
                # Clients on the Primary's own network
                foreach ($vm in $vmListFull) {
                    if ($vm.network -eq $priNetwork -and -not $clientPushSiteMap.ContainsKey($vm.vmName)) {
                        $clientPushSiteMap[$vm.vmName] = $priSiteCode
                    }
                }
                # Clients on Secondary subnets under this Primary
                $secondaries = $vmListFull | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $priSiteCode }
                foreach ($sec in $secondaries) {
                    foreach ($vm in $vmListFull) {
                        if ($vm.network -eq $sec.network -and -not $clientPushSiteMap.ContainsKey($vm.vmName)) {
                            $clientPushSiteMap[$vm.vmName] = $priSiteCode
                        }
                    }
                }
            }
        }

        # --- Set up category groups (regular <group> elements, order preserved) ---
        # Clean up any leftover SmartGroups from previous runs
        $CurrentSmartGroups = $findgroup.SelectNodes('smartGroup')
        foreach ($item in $CurrentSmartGroups) {
            [void]$findGroup.RemoveChild($item)
        }

        # Migrate from old format: remove zAllVirtualMachines group (servers
        # will be re-added to the correct category groups by the VM loop)
        $oldAllVMs = $findGroup.SelectNodes('group') | Where-Object { $_.properties.name -eq "zAllVirtualMachines" } | Select-Object -First 1
        if ($oldAllVMs) {
            [void]$findGroup.RemoveChild($oldAllVMs)
            $shouldSave = $true
        }

        # On re-runs, clear all servers from category groups so they get
        # re-placed into the correct group (handles role/category changes).
        foreach ($childGroup in @($findGroup.SelectNodes('group'))) {
            foreach ($srv in @($childGroup.SelectNodes('server'))) {
                [void]$childGroup.RemoveChild($srv)
            }
        }

        # Ensure the standard category groups exist from the template.
        # Template order: Domain Servers, MECM Servers, Servers, Clients
        $categoryNames = @("Domain Servers", "MECM Servers", "Servers", "Clients")
        foreach ($catName in $categoryNames) {
            $existing_cat = $findGroup.SelectNodes('group') | Where-Object { $_.properties.name -eq $catName } | Select-Object -First 1
            if ($null -eq $existing_cat) {
                $templateCat = $groupFromTemplate.SelectNodes('group') | Where-Object { $_.properties.name -eq $catName } | Select-Object -First 1
                if ($templateCat) {
                    $clonedCat = $existing.ImportNode($templateCat.Clone(), $true)
                    # Remove any template server placeholders
                    foreach ($srv in @($clonedCat.SelectNodes('server'))) { [void]$clonedCat.RemoveChild($srv) }
                    [void]$findGroup.AppendChild($clonedCat)
                }
            }
        }

        # Replace "MECM Servers" placeholder with per-site groups if we have sites
        if ($siteHierarchy -and $siteHierarchy.Sites.Count -gt 0) {
            $mecmGroup = $findGroup.SelectNodes('group') | Where-Object { $_.properties.name -eq "MECM Servers" } | Select-Object -First 1
            if ($mecmGroup) {
                $insertBefore = $mecmGroup.NextSibling
                [void]$findGroup.RemoveChild($mecmGroup)

                foreach ($site in $siteHierarchy.Sites) {
                    $siteName = "$($site.RoleLabel) ($($site.SiteCode))"
                    # Check if this site group already exists
                    $existingSiteGroup = $findGroup.SelectNodes('group') | Where-Object { $_.properties.name -eq $siteName } | Select-Object -First 1
                    if ($null -eq $existingSiteGroup) {
                        [xml]$siteGroupXml = @"
<group>
    <properties>
        <expanded>True</expanded>
        <name>$siteName</name>
    </properties>
</group>
"@
                        $importedGroup = $existing.ImportNode($siteGroupXml.group, $true)
                        if ($insertBefore) {
                            [void]$findGroup.InsertBefore($importedGroup, $insertBefore)
                        }
                        else {
                            [void]$findGroup.AppendChild($importedGroup)
                        }
                    }
                }
                $shouldSave = $true
            }
        }

        # Also remove old per-site groups/smartGroups that no longer have a matching site
        if ($siteHierarchy) {
            $validSiteNames = @($siteHierarchy.Sites | ForEach-Object { "$($_.RoleLabel) ($($_.SiteCode))" })
        } else {
            $validSiteNames = @()
        }
        $sitePatterns = @("^CAS \(", "^PRI \(", "^SEC \(")
        foreach ($childGroup in @($findGroup.SelectNodes('group'))) {
            $gName = $childGroup.properties.name
            $isSiteGroup = $false
            foreach ($pat in $sitePatterns) {
                if ($gName -match $pat) { $isSiteGroup = $true; break }
            }
            if ($isSiteGroup -and $gName -notin $validSiteNames) {
                [void]$findGroup.RemoveChild($childGroup)
                $shouldSave = $true
            }
        }

        # Re-order category groups to match desired display order:
        # Domain Servers, [site groups: CAS→PRI→SEC], Servers, Clients
        # (Linux is added later during the VM loop and stays at the end)
        $desiredOrder = @("Domain Servers")
        if ($siteHierarchy) {
            $desiredOrder += @($siteHierarchy.Sites | ForEach-Object { "$($_.RoleLabel) ($($_.SiteCode))" })
        }
        $desiredOrder += @("Servers", "Clients")
        $allChildGroups = @($findGroup.SelectNodes('group'))
        foreach ($orderName in $desiredOrder) {
            $g = $allChildGroups | Where-Object { $_.properties.name -eq $orderName } | Select-Object -First 1
            if ($g) {
                [void]$findGroup.RemoveChild($g)
                [void]$findGroup.AppendChild($g)
            }
        }

        # Build a lookup of category group elements for the VM loop
        $catGroups = @{}
        foreach ($g in $findGroup.SelectNodes('group')) {
            $catGroups[$g.properties.name] = $g
        }

        # --- VM loop: route each VM into the correct category group ---
        $hasOsdOrAad = $false
        foreach ($vm in $vmListFull) {
            if (Test-VmIsLinux -Vm $vm) {
                $rdpOn = ($vm.PSObject.Properties.Name -contains 'enableRDP') -and [bool]$vm.enableRDP
                $isLinuxClient = $vm.Role -eq 'LinuxClient'
                $hasRdp = $rdpOn -or $isLinuxClient

                # Resolve IP (Ubuntu doesn't respond to LLMNR).
                # Prefer live IP from Hyper-V over cached LastKnownIP — DHCP
                # leases can change and LastKnownIP goes stale.
                $linuxIp = $null
                try {
                    $linuxIp = (Get-VMNetworkAdapter -VMName $vm.VmName -ErrorAction Stop).IPAddresses |
                        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
                } catch {}
                if ([string]::IsNullOrWhiteSpace($linuxIp)) { $linuxIp = $vm.LastKnownIP }
                $linuxName = if (-not [string]::IsNullOrWhiteSpace($linuxIp)) { $linuxIp } else { $vm.VmName }

                # Build display name
                if ($hasRdp) {
                    $linuxDisplay = "$($vm.VmName) [Linux RDP] (vmbuildadmin)"
                } else {
                    $linuxDisplay = "$($vm.VmName) [Linux SSH] (vmbuildadmin)"
                }
                if ($vm.SiteCode) { $linuxDisplay += " ($($vm.SiteCode))" }

                $cLinux = [PsCustomObject]@{}
                foreach ($item in $vm | Get-Member -MemberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" }) {
                    $cLinux | Add-Member -MemberType NoteProperty -Name "$($item.Name)" -Value $($vm."$($item.Name)") -Force
                }
                $cLinux | Add-Member -MemberType NoteProperty -Name "Comment" -Value "Linux" -Force
                $linuxComment = ($cLinux | ConvertTo-Json -Depth 4 -Compress)

                # Ensure Linux group exists (appended after Clients)
                if (-not $catGroups.ContainsKey("Linux")) {
                    [xml]$linuxGroupXml = '<group><properties><expanded>True</expanded><name>Linux</name></properties></group>'
                    $importedLinux = $existing.ImportNode($linuxGroupXml.group, $true)
                    [void]$findGroup.AppendChild($importedLinux)
                    $catGroups["Linux"] = $findGroup.SelectNodes('group') | Where-Object { $_.properties.name -eq "Linux" } | Select-Object -Last 1
                }

                # Remove legacy SSH subgroup (servers are now flat under Linux)
                $legacySsh = $catGroups["Linux"].SelectNodes('group') | Where-Object { $_.properties.name -eq "SSH" } | Select-Object -First 1
                if ($legacySsh) {
                    [void]$catGroups["Linux"].RemoveChild($legacySsh)
                    $shouldSave = $true
                }

                # RDP-capable and SSH-only VMs both go directly under Linux
                $linuxTarget = $catGroups["Linux"]

                if ((Add-RDCManServerToGroup -ServerName $linuxName -DisplayName $linuxDisplay `
                        -targetGroup $linuxTarget -groupfromtemplate $groupFromTemplate -existing $existing `
                        -comment $linuxComment -ForceOverwrite:$true `
                        -domain '' -username 'vmbuildadmin') -eq $True) {
                    $shouldSave = $true
                }
                continue
            }
            Write-Verbose "Adding VM $($vm.VmName)"
            $c = [PsCustomObject]@{}
            foreach ($item in $vm | get-member -memberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" } ) { $c | Add-Member -MemberType NoteProperty -Name "$($item.Name)" -Value $($vm."$($item.Name)") -force }

            if ($vm.Role -eq "DomainMember" -or $vm.Role -eq "WorkgroupMember") {
                $deployedOS = $vm.deployedOS
                $isServer = $deployedOS -match "Server"

                if ( $null -eq $vm.SqlVersion -and $isServer) {
                    if ($vm.InstallCA) {
                        $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "IssuingCA" -force
                    }
                    else {
                        $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberServer" -force
                    }
                }
                else {
                    if (-not $isServer) {
                        $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberClient" -force
                    }
                }

            }

            if ($vm.Role -eq "WSUS") {
                if ($vm.installSUP) {
                    $c | Add-Member -MemberType NoteProperty -Name "SUPForSiteServer" -Value "$($vm.SiteCode)" -force
                }
                else {
                    $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberServer" -force
                }
            }

            if ($vm.SqlVersion) {
                $PrimaryNode = $vm
                if ($vm.role -eq "SQLAO") {
                    if (-not $vm.OtherNode) {
                        $primaryNode = $vmListFull | Where-Object { $_.OtherNode -eq $vm.vmName }
                    }
                }
                $SiteServer = $vmListFull | Where-Object { $_.RemoteSQLVM -eq $PrimaryNode.vmName -and $_.Role -in "Primary", "CAS" }
                if ($SiteServer) {
                    $c | Add-Member -MemberType NoteProperty -Name "SQLForSiteServer" -Value "$($SiteServer.SiteCode)" -force
                }
                else {
                    if ($vm.Role -eq "DomainMember") {
                        $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberServer" -force
                    }
                }
            }

            # Tag MECM VMs with their owning site for identification
            if ($siteHierarchy -and $siteHierarchy.VmSiteMap[$vm.vmName]) {
                $c | Add-Member -MemberType NoteProperty -Name "SiteGroupTag" -Value "site_$($siteHierarchy.VmSiteMap[$vm.vmName])" -Force
            }

            $comment = $c | ConvertTo-Json
            if ($useIP) {
                $name = $($vm.LastKnownIP)
            }
            else {
                $name = $($vm.VmName)
            }            
            $ForceOverwrite = $false
            $roleTag = $null
            switch ($vm.Role) {
                "DC"              { $roleTag = "DC" }
                "BDC"             { $roleTag = "BDC" }
                "CAS"             { $roleTag = "CAS" }
                "Primary"         { $roleTag = "PRI" }
                "Secondary"       { $roleTag = "SEC" }
                "PassiveSite"     { $roleTag = "Passive" }
                "SQLAO"           { $roleTag = "SQLAO" }
                "WSUS"            { $roleTag = "WSUS" }
                "FileServer"      { $roleTag = "FS" }
                "OSDClient"       { $roleTag = "OSD" }
                "StandaloneRootCA" { $roleTag = "RootCA" }
                "InternetClient"  { $roleTag = "Internet"; $ForceOverwrite = $true }
                "AADClient"       { $roleTag = "AAD"; $ForceOverwrite = $true }
                "WorkgroupMember" { $roleTag = "WG" }
                Default {}
            }

            # SiteSystem: show actual installed roles instead of generic tag
            $siteRolesTag = $null
            if ($vm.Role -eq "SiteSystem") {
                $sr = @()
                if ($vm.installMP) { $sr += "MP" }
                if ($vm.installDP) { $sr += "DP" }
                if ($vm.installSUP -or $vm.InstallSUP) { $sr += "SUP" }
                if ($vm.InstallRP) { $sr += "RP" }
                if ($vm.InstallSMSProv) { $sr += "SMSProv" }
                if ($sr.Count -gt 0) { $siteRolesTag = $sr -join ',' }
            }

            # Certificate Authority tag (Issuing CA via InstallCA property)
            $caTag = $null
            if ($vm.InstallCA -and $vm.Role -ne "StandaloneRootCA") {
                $caTag = "CA"
            }

            # SUP/WSUS tag for non-SiteSystem VMs with installSUP
            $supTag = $null
            if (($vm.installSUP -or $vm.InstallSUP) -and $vm.Role -ne "SiteSystem") {
                $supTag = "WSUS"
            }

            # Reporting Point tag for non-SiteSystem VMs with installRP
            $rpTag = $null
            if ($vm.InstallRP -and $vm.Role -ne "SiteSystem") {
                $rpTag = "RP"
            }

            # Proxy-client tag: VM is opted in to route HTTP(S) through the
            # Linux Squid proxy (per-VM useProxy=true, set from genconfig).
            $proxyTag = $null
            if ($vm.useProxy) {
                $proxyTag = "Proxy"
            }

            # Dedup: skip role tag if VM name already contains it
            if ($roleTag -and $vm.VmName -match [regex]::Escape($roleTag)) {
                $roleTag = $null
            }

            # Build bracket tag: [ROLE OS CMver SiteRoles CA SUP Proxy]
            $tagParts = @()
            if ($roleTag) { $tagParts += $roleTag }
            if ($caTag) { $tagParts += $caTag }
            if ($rpTag) { $tagParts += $rpTag }
            if ($supTag) { $tagParts += $supTag }
            if ($proxyTag) { $tagParts += $proxyTag }

            $osShort = Get-RDCManOSShortName -deployedOS $vm.deployedOS
            # Dedup: skip OS tag if VM name already contains it
            if ($osShort -and -not ($vm.VmName -match [regex]::Escape($osShort))) {
                $tagParts += $osShort
            }

            # CM version for site server roles
            if ($cmVersion -and $vm.Role -in "CAS", "Primary", "Secondary", "SiteSystem", "PassiveSite") {
                $tagParts += $cmVersion
            }

            # Append site system role flags
            if ($siteRolesTag) { $tagParts += $siteRolesTag }

            $displayName = $vm.VmName
            if ($tagParts.Count -gt 0) {
                $displayName += " [$($tagParts -join ' ')]"
            }
            if ($vm.SiteCode) {
                $displayName += " ($($vm.SiteCode)"
                if ($vm.ParentSiteCode) {
                    $displayName += "->$($vm.ParentSiteCode)"
                }
                $displayName += ")"
            }
            elseif ($clientPushSiteMap.ContainsKey($vm.vmName)) {
                $displayName += " ($($clientPushSiteMap[$vm.vmName]))"
            }
            if ($vm.Role -eq "AADClient" -or $vm.Role -eq "InternetClient") {
                if (-not [string]::IsNullOrWhiteSpace($vm.LastKnownIP)) {
                    $name = $vm.LastKnownIP
                }
                else {
                    $IP = (get-vm2 -name $vm.vmName | Get-VMNetworkAdapter).IPAddresses | Where-Object { $_ -notlike "*:*" } | Select-Object -First 1
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
            if ($vm.Role -in ("OSDClient", "AADClient")) {
                $vmID = $vm.vmId
                $hasOsdOrAad = $true
            }

            # Determine which category group this VM belongs to
            $targetGroupName = "Servers"  # default
            if ($siteHierarchy -and $siteHierarchy.VmSiteMap[$vm.vmName]) {
                $vmSiteCode = $siteHierarchy.VmSiteMap[$vm.vmName]
                $vmSite = $siteHierarchy.Sites | Where-Object { $_.SiteCode -eq $vmSiteCode } | Select-Object -First 1
                if ($vmSite) {
                    $targetGroupName = "$($vmSite.RoleLabel) ($($vmSite.SiteCode))"
                }
            }
            elseif ($vm.Role -in "DC", "BDC", "FileServer", "StandaloneRootCA") {
                $targetGroupName = "Domain Servers"
            }
            elseif ($vm.Role -eq "DomainMember" -and $vm.InstallCA) {
                $targetGroupName = "Domain Servers"
            }
            elseif ($vm.Role -in "OSDClient", "AADClient", "InternetClient") {
                $targetGroupName = "Clients"
            }
            elseif (($vm.Role -in "DomainMember", "WorkgroupMember") -and $vm.deployedOS -and $vm.deployedOS -notmatch "Server") {
                $targetGroupName = "Clients"
            }

            $targetGroup = $catGroups[$targetGroupName]
            if ($null -eq $targetGroup) {
                # Fallback: use Servers group
                $targetGroup = $catGroups["Servers"]
            }

            # Phase 11 captures this. Precedence: the note, then a trust already in the .rdg
            # (either clicked in the dialog or written by a previous run), then a one-off
            # capture from a running guest. Anything recovered from the file is written back
            # to the note so it stops depending on the file surviving.
            $certSha256 = if ($vm.rdpCertSha256) { "$($vm.rdpCertSha256)" } else { $null }
            if (-not $certSha256 -and [string]::IsNullOrWhiteSpace($vmID)) {
                $carried = $existingCerts["$($name.ToLowerInvariant())"]
                if ($carried) {
                    $certSha256 = $carried
                    $null = Save-VmRdpCertNote -VmName $vm.vmName -Sha256 $carried
                }
                elseif ($vm.State -eq 'Running') {
                    $certSha256 = Update-VmRdpCertNote -VmName $vm.vmName -VmDomainName $vm.Domain
                }
            }

            if ((Add-RDCManServerToGroup -ServerName $name -DisplayName $displayName -targetGroup $targetGroup -groupfromtemplate $groupFromTemplate -existing $existing -comment $comment.ToString() -ForceOverwrite:$ForceOverwrite -vmID $vmID -domain $vm.Domain -username $vm.domainUser -certSha256 $certSha256) -eq $True) {
                $shouldSave = $true
            }
        }

        # Set CredSSP policy defaults when OSD/AAD console connections are present
        if ($hasOsdOrAad) {
            $policyDefaultsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Credssp\PolicyDefaults"
            $subKeys = @(
                "AllowDefaultCredentialsDomain",
                "AllowSavedCredentialsDomain",
                "AllowDefaultCredentials",
                "AllowFreshCredentialsDomain",
                "AllowFreshCredentials",
                "AllowFreshCredentialsWhenNTLMOnly",
                "AllowFreshCredentialsWhenNTLMOnlyDomain",
                "AllowSavedCredentials",
                "AllowSavedCredentialsWhenNTLMOnly"
            )
            foreach ($subKey in $subKeys) {
                $fullPath = Join-Path $policyDefaultsPath $subKey
                if (-not (Test-Path $fullPath)) {
                    New-Item -Path $fullPath -Force | Out-Null
                }
            }
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

        # Remove empty category groups (e.g., no MECM servers, no Linux VMs)
        foreach ($g in @($findGroup.SelectNodes('group'))) {
            if ($g.SelectNodes('server').Count -eq 0 -and $g.SelectNodes('group').Count -eq 0) {
                [void]$findGroup.RemoveChild($g)
            }
        }

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

        # Clean up any leftover SmartGroups
        foreach ($sg in @($findGroup.SelectNodes('smartGroup'))) {
            [void]$findgroup.RemoveChild($sg)
        }

        # Use "Servers" group for unknown VMs, or the first available child group
        $unknownTargetGroup = $findGroup.SelectNodes('group') | Where-Object { $_.properties.name -eq "Servers" } | Select-Object -First 1
        if ($null -eq $unknownTargetGroup) {
            $unknownTargetGroup = $findGroup.SelectNodes('group') | Select-Object -First 1
        }
        if ($null -eq $unknownTargetGroup) {
            # No child groups at all - create one
            [xml]$ugXml = '<group><properties><expanded>True</expanded><name>Servers</name></properties></group>'
            $importedUg = $existing.ImportNode($ugXml.group, $true)
            [void]$findGroup.AppendChild($importedUg)
            $unknownTargetGroup = $findGroup.SelectNodes('group') | Select-Object -Last 1
        }

        foreach ($vm in $unknownVMs) {
            if (Test-VmIsLinux -Vm $vm) {
                Write-Verbose "New-RDCManFileFromHyperV: Skipping Linux VM $($vm.VmName) (RDCMan is RDP-only)"
                continue
            }
            Write-Verbose "New-RDCManFileFromHyperV: Adding VM $($vm.VmName)"
            $c = [PsCustomObject]@{}
            foreach ($item in $vm | get-member -memberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" } ) { $c | Add-Member -MemberType NoteProperty -Name "$($item.Name)" -Value $($vm."$($item.Name)") -force }
            $comment = $c | ConvertTo-Json
            $name = $($vm.VmName)
            $displayName = $($vm.VmName)
            if ((Add-RDCManServerToGroup -ServerName $name -DisplayName $displayName -targetGroup $unknownTargetGroup -groupfromtemplate $groupFromTemplate -existing $existing -comment $comment.ToString()) -eq $True) {
                $shouldSave = $true
            }
        }

        # Remove empty category groups
        foreach ($g in @($findGroup.SelectNodes('group'))) {
            if ($g.SelectNodes('server').Count -eq 0) {
                [void]$findGroup.RemoveChild($g)
            }
        }

        # Add new group
        [void]$file.AppendChild($findgroup)
    }

    $killed = Save-RdcManSettingsFile -rdcmanfile $rdcmanfile
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
        }
        catch {
            Write-RedX "Could not update $rdcmanfile. $_"
        }
    }
    else {
        Write-Log "No Changes. Not updating $rdcmanfile" -Success -Verbose
    }
    if ($killed -or $killedAlready) {

        $rdcProc = Start-Process "C:\tools\RDCMan.exe" -ArgumentList "/reconnect" -WindowStyle Minimized -WorkingDirectory "C:\Temp" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -PassThru
        $i = 0
        while ($i -lt 3) {
            Set-RdcManMin
            start-sleep -Seconds 1
            $i++
        }
        Set-RdcManMin

        if ($rdcProc) {
            Write-GreenCheck "Updated $rdcmanfile. Restarted RDCMan (PID $($rdcProc.Id))" -ForegroundColor ForestGreen
        }
        else {
            Write-GreenCheck "Updated $rdcmanfile. RDCMan was stopped but failed to restart" -ForegroundColor ForestGreen
        }
    }
    else {
        Write-GreenCheck "Updated $rdcmanfile. RDCMan was not running" -ForegroundColor ForestGreen
    }
}

function Remove-MissingServersFromGroup {
    [CmdletBinding()]
    param(
        [object]$findgroup
    )

    $return = $false

    $completeServerList = Get-List -Type VM | Select-Object -ExpandProperty vmName
    # Search all child groups (and direct children) for servers to remove
    foreach ($item in @($findgroup.SelectNodes('.//server'))) {
        if ($item.properties.displayName -in $completeServerList -or $item.properties.name -in $completeServerList) {
            continue;
        }
        Write-Log ("Removing $($item.properties.displayName)") -LogOnly -Verbose
        $item.ParentNode.RemoveChild($item) | out-null
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
        [object]$targetGroup,
        [object]$groupFromTemplate,
        [object]$existing,
        [string]$comment,
        [string]$vmID = $null,
        [string]$username = $null,
        [string]$domain = $null,
        [string]$certSha256 = $null,
        [bool]$ForceOverwrite
    )

    #<connectionType>VirtualMachineConsoleConnect</connectionType>
    #<vmId>TEMPLATE</vmId>

    if (-not [string]::IsNullOrWhiteSpace($vmID)) {
        $displayName = "[console] " + $displayName
    }

    if ($ForceOverwrite) {
        #Delete Old Records and let them be regenerated

        $displayNameList = @($displayName, $serverName, ($displayName + " (Missing IP)"))
        if ($username) {
            $displayNameList += $displayName + "($username)"
        }

        $findservers = $targetGroup.server | Where-Object { $_.properties.displayName -in $displayNameList -or $_.properties.name -in $displayNameList }

        foreach ($item in $findservers) {
            Write-Log ("Removing $($item.properties.displayName)") -LogOnly -Verbose
            $targetGroup.RemoveChild($item)
        }
    }

    $findserver = $targetGroup.server | Where-Object { $_.properties.displayName -eq $displayName -or $_.properties.displayName -eq $serverName -or $_.properties.name -eq $displayName -or $_.properties.name -eq $serverName } | Select-Object -First 1
    if ($null -eq $findserver) {
        Write-Log "Added $displayName to RDG Group" -LogOnly -Verbose
        $server = $groupFromTemplate.SelectNodes('.//server') | Select-Object -First 1
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

        # RDCMan 3.12 keeps "Trust this certificate for this server" here, per server, so
        # rebuilding the node from the template is what discards a trust clicked in the UI.
        # Writing it from the VM note makes the trust survive every regeneration.
        # Skipped for console entries: those connect to the Hyper-V host, not the guest,
        # so the guest's certificate would never be the one presented.
        if ($certSha256 -and [string]::IsNullOrWhiteSpace($vmID)) {
            $certs = $existing.CreateElement("trustedCertificates")
            $cert = $existing.CreateElement("certificate")
            $cert.SetAttribute("endpointType", "SessionHost")
            $cert.SetAttribute("endpoint", $serverName.ToLowerInvariant())
            $cert.SetAttribute("sha256", $certSha256.ToUpperInvariant())
            [void]$certs.AppendChild($cert)
            [void]$clonedNode.AppendChild($certs)
        }

        $targetGroup.AppendChild($clonedNode)
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
        # Remove template server placeholders from all child groups
        foreach ($srv in @($findGroup.SelectNodes('.//server'))) {
            [void]$srv.ParentNode.RemoveChild($srv)
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

    $rdcmandllpath = "$($common.AzureFilesPath)\support\rdcman.dll"

    $rdcManFile = $Common.AzureFileList.SupportFiles | Where-Object { $_.id -eq "RdcManDLL" }
    $worked = Get-FileFromStorage -File $rdcManFile -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$false
    if (-not $worked) {
        Write-Log -Verbose "$rdcManFile Failed to download via Get-FileFromStorage"
    }
    unblock-file $rdcmandllpath

    if (-not(test-path $rdcmandllpath)) {
        Write-Log "Rdcman.dll was not copied." -Failure
        return $null
    }
 
    #Write-Host "Get-RDCManPassword: Importing rdcman.dll"
    Import-Module $rdcmandllpath
    $EncryptionSettings = New-Object -TypeName RdcMan.EncryptionSettings
    return [RdcMan.Encryption]::EncryptString($Common.LocalAdmin.GetNetworkCredential().Password , $EncryptionSettings)
}
