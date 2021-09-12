. $PSScriptRoot\Common.ps1
$userName = "admin"
$result = Test-Configuration -FilePath "E:\repos\memlabs\vmbuild\config\samples\Standalone.json"
#$result = Test-Configuration -FilePath "E:\repos\memlabs\vmbuild\config\samples\Hierarchy.json"
#$result = Test-Configuration -FilePath "E:\repos\memlabs\vmbuild\config\samples\AddToExisting.json"
if ($result.Valid) {
$deployConfig = $result.DeployConfig
}
function New-RDCManFile($rdcmanfile){

    $template = Get-RDCManTemplate ($rdcmanfile)

    #This is the bulk of the data.
    $file = $template.RDCMan.file
    $group = $file.group
    # <RDCMan>
    #   <file>         
    #     <group>
    #        <logonCredentials>
    #        <server>
    #        <server>
    #     <group>
    #     ...

    $domain = $deployConfig.vmOptions.domainName
    $findGroup = Get-RDCManGroupToModify
    if ($findGroup -eq $false -or $findGroup -eq $null)
    {
        Write-Error "Error in Get-RDCManPassword"
        return
    }
    foreach ($vm in $deployConfig.virtualMachines)
    {
        Add-RDCManServerToGroup ($vm.vmName)
    }
    
    #If the original file was a template, remove the templated group.
    if ($group.properties.Name -eq "VMASTEMPLATE"){
        [void]$file.RemoveChild($group)
    }
    [void]$file.AppendChild($findgroup)
    
    #Save to desired filename
    Write-Host "Saving resultant XML to $rdcmanfile"
    $template.save($rdcmanfile) | Out-Null
    
}

function Add-RDCManServerToGroup([string]$serverName){
    $findserver = $findgroup.server | Where-Object { $_.properties.name -eq $serverName} | Select-Object -First 1
    Write-Host "Adding $serverName to RDG Group ... " -NoNewline
    if ($null -eq $findserver){
      Write-Host "added"
      $server = $group.SelectNodes('//server') | Select-Object -First 1
      $newserver = $server.clone()
      $newserver.properties.name = $serverName
      $findgroup.AppendChild($newserver)   | Out-Null   
    }else{
        Write-Host "already exists in group. Skipping"
    }
}

#This gets the <Group> section from the template. Either makes a new one, or returns an existing one.
#If a new one is created, the <server> nodes will not exist.
function Get-RDCManGroupToModify(){
    Write-Host "Looking for group entry named $domain in current xml... " -NoNewline
    $findGroup = $group | Where-Object { $_.properties.name -eq $domain} | Select-Object -First 1
    
    if ($null -eq $findGroup){
        Write-Host "Not found.  Creating new group"
        $findGroup = $group.Clone()    
        $findGroup.properties.name = $domain
        $findGroup.logonCredentials.userName = $userName
        $password = Get-RDCManPassword
        if ($null -eq $password)
        {
            Write-Error ("Password was not generated correctly.")
            throw            
        }
        $findGroup.logonCredentials.password = $password
        $findGroup.logonCredentials.domain = $domain
        $ChildNodes = $findGroup.SelectNodes('//server')
        foreach($Child in $ChildNodes){
            [void]$Child.ParentNode.RemoveChild($Child)
        }    
    }else{
        Write-Host "Found!"
    }
    return $findGroup
}

#Gets the blank template, or returns the existing rdg xml if available.
function Get-RDCManTemplate($rdcmanfile){
    $templatefile = Join-Path $PSScriptRoot "template.rdg"
    
    if ((test-path "$rdcmanfile")) {
        $templatefile = $rdcmanfile
    }
    Write-Host "Loading existing XML from $templatefile"
    [xml]$template = Get-Content -Path $templatefile
    return $template
}

function Get-RDCManPassword(){
    $rdcmanpath = "C:\ProgramData\chocolatey\lib\sysinternals\tools"
    
    if (-not(test-path "$($env:temp)\rdcman.dll")) {
        Write-Host "Rdcman.dll not found in $($env:temp).  Copying."
        copy-item "$($rdcmanpath)\rdcman.exe" "$($env:temp)\rdcman.dll"
        unblock-file "$($env:temp)\rdcman.dll"
     }
    
     if (-not(test-path "$($env:temp)\rdcman.dll")) {
        Write-Error "Rdcman.dll was not copied. "
        copy-item "$($rdcmanpath)\rdcman.exe" "$($env:temp)\rdcman.dll"
        unblock-file "$($env:temp)\rdcman.dll"
     }
    Write-Host "Importing rdcman.dll"
    Import-Module "$($env:temp)\rdcman.dll"
    $EncryptionSettings = New-Object -TypeName RdcMan.EncryptionSettings
    return [RdcMan.Encryption]::EncryptString($Common.LocalAdmin.GetNetworkCredential().Password , $EncryptionSettings)
}
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$savepath = Join-Path $DesktopPath "memlabs.rdg"
New-RDCManFile $savepath
