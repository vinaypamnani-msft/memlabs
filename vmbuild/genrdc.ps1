. $PSScriptRoot\Common.ps1
$userName = "admin"
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$savepath = Join-Path $DesktopPath "memlabs.rdg"
$templatefile = Join-Path $PSScriptRoot "template.rdg"

$result = Test-Configuration -FilePath "E:\repos\memlabs\vmbuild\config\samples\Standalone.json"
#$result = Test-Configuration -FilePath "E:\repos\memlabs\vmbuild\config\samples\Hierarchy.json"
#$result = Test-Configuration -FilePath "E:\repos\memlabs\vmbuild\test.json"
#$result = Test-Configuration -FilePath "E:\repos\memlabs\vmbuild\config\samples\AddToExisting.json"


if ($result.Valid) {
    $deployConfig = $result.DeployConfig
}else{
    Write-Host "Config file is not valid"
    return
}

function New-RDCManFile {
    param(
        [string]$rdcmanfile
    )
    $template = Get-RDCManTemplate $templatefile
    if ($null -eq $template){
        Write-Host "Could not locate $templatefile"
        return
    }
    $existing = Get-RDCManTemplateorExisting $rdcmanfile
    if ($null -eq $template){
        Write-Host "Could not locate $rdcmanfile"
        return
    }
    #This is the bulk of the data.
    $file = $existing.RDCMan.file
    $group = $file.group

    $groupFromTemplate = $template.RDCMan.file.group

    # <RDCMan>
    #   <file>
    #     <group>
    #        <logonCredentials>
    #        <server>
    #        <server>
    #     <group>
    #     ...

    $findGroup = Get-RDCManGroupToModify $group $findGroup $groupFromTemplate $existing
    if ($findGroup -eq $false -or $null -eq $findGroup) {
        Write-Error "Error in Get-RDCManPassword"
        return
    }
    $shouldSave = $False
    foreach ($vm in $deployConfig.virtualMachines) {
        if (Add-RDCManServerToGroup $vm.vmName $group $findgroup $groupFromTemplate $existing -eq $True)
        {
            $shouldSave = $True
        }
    }

    #If the original file was a template, remove the templated group.
    if ($group.properties.Name -eq "VMASTEMPLATE") {
        [void]$file.RemoveChild($group)
    }
    [void]$file.AppendChild($findgroup)

    #Save to desired filename
    if ($shouldSave -eq $True){
        Get-Process -Name rdcman -ea Ignore | Stop-Process
        Start-Sleep 1
        Write-Host "Saving resultant XML to $rdcmanfile"
        $existing.save($rdcmanfile) | Out-Null
    } else{
        Write-Host "No Changes. Not Saving resultant XML to $rdcmanfile"
    }

}

function Add-RDCManServerToGroup {

    param(
        [string]$serverName,
        $group,
        $findgroup,
        $groupFromTemplate,
        $existing
    )

    $findserver = $findgroup.server | Where-Object { $_.properties.name -eq $serverName } | Select-Object -First 1
    Write-Host "Adding $serverName to RDG Group ... " -NoNewline
    if ($null -eq $findserver) {
        Write-Host "added"
        $server = $groupFromTemplate.SelectNodes('//server') | Select-Object -First 1
        $newserver = $server.clone()
        $newserver.properties.name = $serverName 
        $clonedNode = $existing.ImportNode($newserver, $true)
        $findgroup.AppendChild($clonedNode) 
        return $True       
    }
    else {
        Write-Host "already exists in group. Skipping"
        return $False
    }
    return $False
}

#This gets the <Group> section from the template. Either makes a new one, or returns an existing one.
#If a new one is created, the <server> nodes will not exist.
function Get-RDCManGroupToModify {
    param(
        $group,
        $groupFromTemplate
    )
    $domain = $deployConfig.vmOptions.domainName
    Write-Host "Looking for group entry named $domain in current xml... " -NoNewline
    $findGroup = $group | Where-Object { $_.properties.name -eq $domain } | Select-Object -First 1

    if ($null -eq $findGroup) {
        Write-Host "Not found.  Creating new group"
        $findGroup = $groupFromTemplate.Clone()
        $findGroup.properties.name = $domain
        $findGroup.logonCredentials.userName = $userName
        $password = Get-RDCManPassword
        if ($null -eq $password) {
            Write-Error ("Password was not generated correctly.")
            throw
        }
        $findGroup.logonCredentials.password = $password
        $findGroup.logonCredentials.domain = $domain
        $ChildNodes = $findGroup.SelectNodes('//server')
        foreach ($Child in $ChildNodes) {
            [void]$Child.ParentNode.RemoveChild($Child)
        }
        $findGroup = $existing.ImportNode($findGroup, $true)
    }
    else {
        Write-Host "Found!"
    }
    return $findGroup
}

#Gets the blank template, or returns the existing rdg xml if available.
function Get-RDCManTemplate {
    param(
        [string]$templatefile
    )
    Write-Host "Loading template XML from $templatefile"
    [xml]$template = Get-Content -Path $templatefile
    return $template
}

#Gets the blank template, or returns the existing rdg xml if available.
function Get-RDCManTemplateorExisting {
    param(
        [string]$rdcmanfile
    )
    $existingfile = Join-Path $PSScriptRoot "template.rdg"

    if ((test-path "$rdcmanfile")) {
        $existingfile = $rdcmanfile
    }
    Write-Host "Loading existing XML from $existingfile"
    [xml]$existing = Get-Content -Path $existingfile
    return $existing
}

function Get-RDCManPassword() {
    $rdcmanpath = "C:\ProgramData\chocolatey\lib\sysinternals\tools"

    if (-not(test-path "$($env:temp)\rdcman.dll")) {
        Write-Host "Rdcman.dll not found in $($env:temp).  Copying."
        copy-item "$($rdcmanpath)\rdcman.exe" "$($env:temp)\rdcman.dll"
        unblock-file "$($env:temp)\rdcman.dll"
    }

    if (-not(test-path "$($env:temp)\rdcman.dll")) {
        Write-Error "Rdcman.dll was not copied. "
        throw
    }
    Write-Host "Importing rdcman.dll"
    Import-Module "$($env:temp)\rdcman.dll"
    $EncryptionSettings = New-Object -TypeName RdcMan.EncryptionSettings
    return [RdcMan.Encryption]::EncryptString($Common.LocalAdmin.GetNetworkCredential().Password , $EncryptionSettings)
}

New-RDCManFile $savepath
