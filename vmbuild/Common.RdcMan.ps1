########################
### RDCMan Functions ###
########################

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

    # ARM template installs sysinternal tools via choco
    $rdcmanpath = "C:\ProgramData\chocolatey\lib\sysinternals\tools"
    $newrdcmanpath = "C:\tools"
    $rdcmanexe = "RDCMan.exe"

    # create C:\tools if not present
    if (-not (Test-Path $newrdcmanpath)) {
        New-Item -Path $newrdcmanpath -ItemType Directory -Force -ErrorAction SilentlyContinue
    }

    # Download rdcman, if not present
    if (-not (Test-Path "$rdcmanapath\$rdcmanexe")) {
        $ProgressPreference = 'SilentlyContinue'
        Start-BitsTransfer -Source "https://live.sysinternals.com/$rdcmanexe" -Destination "$newrdcmanpath\$rdcmanexe" -ErrorAction SilentlyContinue
        $ProgressPreference = 'Continue'
    }
    else {
        Copy-Item -Path "$rdcmanpath\$rdcmanexe" -Destination "$newrdcmanpath\$rdcmanexe" -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path "$newrdcmanpath\$rdcmanexe") {
        $encryptedPass = Get-RDCManPassword $newrdcmanpath
        if ($null -eq $encryptedPass) {
            Write-Log "New-RDCManFile: Password was not generated correctly." -Failure
            return
        }
    }
    else {
        Write-Log "New-RDCManFile: Cound not located $rdcmanexe. Please copy $rdcmanexe to C:\tools directory, and try again." -Failure
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
    $username = $DeployConfig.vmOptions.domainAdminName
    $findGroup.logonCredentials.password = $encryptedPass
    if ($findGroup.logonCredentials.username -ne $username) {
        $findGroup.logonCredentials.userName = $username
        $shouldSave = $true
    }

    foreach ($vm in $DeployConfig.virtualMachines) {
        if (Add-RDCManServerToGroup $vm.vmName $findgroup $groupFromTemplate $existing -eq $True) {
            $shouldSave = $true
        }
    }

    # If the original file was a template, remove the templated group.
    if ($group.properties.Name -eq "VMASTEMPLATE") {
        [void]$file.RemoveChild($group)
    }

    # Add new group
    [void]$file.AppendChild($findgroup)

    # Save to desired filename
    if ($shouldSave) {
        Write-Log "New-RDCManFile: Killing RDCMan, if necessary and saving resultant XML to $rdcmanfile." -Success
        Write-Log "RDCMan.exe is located in $newrdcmanpath" -Success
        Get-Process -Name rdcman -ea Ignore | Stop-Process
        Start-Sleep 1
        $existing.save($rdcmanfile) | Out-Null
    }
    else {
        Write-Log "New-RDCManFile: No Changes. Not Saving resultant XML to $rdcmanfile" -Success
        Write-Log "RDCMan.exe is located in $newrdcmanpath" -Success
    }
}

function Add-RDCManServerToGroup {

    param(
        [string]$serverName,
        $findgroup,
        $groupFromTemplate,
        $existing
    )

    $findserver = $findgroup.server | Where-Object { $_.properties.name -eq $serverName } | Select-Object -First 1

    if ($null -eq $findserver) {
        Write-Log "Add-RDCManServerToGroup: Added $serverName to RDG Group" -LogOnly
        $server = $groupFromTemplate.SelectNodes('//server') | Select-Object -First 1
        $newserver = $server.clone()
        $newserver.properties.name = $serverName
        $clonedNode = $existing.ImportNode($newserver, $true)
        $findgroup.AppendChild($clonedNode)
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
        $domain,
        $group,
        $findGroup,
        $groupFromTemplate,
        $existing
    )

    $findGroup = $group | Where-Object { $_.properties.name -eq $domain } | Select-Object -First 1

    if ($null -eq $findGroup) {
        Write-Log "Get-RDCManGroupToModify: Group entry named $domain not found in current xml. Creating new group." -LogOnly
        $findGroup = $groupFromTemplate.Clone()
        $findGroup.properties.name = $domain
        $findGroup.logonCredentials.domain = $domain
        $ChildNodes = $findGroup.SelectNodes('//server')
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