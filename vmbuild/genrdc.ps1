. $PSScriptRoot\Common.ps1
$userName = "admin"
Write-Warning "UserName is $userName"
Write-Warning "Password is $($Common.LocalAdmin.Password)"
function New-RDCManFile($rdcmanfile){
    $templatefile = Join-Path $PSScriptRoot "template.rdg"
    
    if ((test-path "$rdcmanfile")) {
        $templatefile = $rdcmanfile
    }

    [xml]$template = Get-Content -Path $templatefile
    
    $file = $template.RDCMan.file
    
    $group = $file.group
    
    $domain = "fabrikam.com"
    $servername1 = "PS-DC1"
    $servername2 = "PS-PRI1"
    
    $findGroup = $group | Where-Object { $_.properties.name -eq $domain} | Select-Object -First 1
    
    if ($null -eq $findGroup){
        $findGroup = $group.Clone()    
        $findGroup.properties.name = $domain
        $findGroup.logonCredentials.userName = $userName
        $findGroup.logonCredentials.password = Get-RDCManPassword
        $findGroup.logonCredentials.domain = $domain
        $ChildNodes = $findGroup.SelectNodes('//server')
        Write-Host $ChildNodes
        foreach($Child in $ChildNodes){
            Write-Host Removing $Child
            [void]$Child.ParentNode.RemoveChild($Child)
        }    
    }
    $server = $group.SelectNodes('//server') | Select-Object -First 1
    $findserver = $group.server | Where-Object { $_.properties.name -eq $servername1} | Select-Object -First 1
    if ($null -eq $findserver){
    $newserver = $server.clone()
    $newserver.properties.name = $servername1
    $findGroup.AppendChild($newserver)
    }
    
    $findserver = $group.server | Where-Object { $_.properties.name -eq $servername2} | Select-Object -First 1
    if ($null -eq $findserver){
    $newserver = $server.clone()
    $newserver.properties.name = $servername2
    $findGroup.AppendChild($newserver)
    }
    if ($group.properties.Name -eq "VMASTEMPLATE"){
        [void]$file.RemoveChild($group)
    }
    [void]$file.AppendChild($findgroup)
    
    
    $template.save($rdcmanfile)
    
}

function Get-RDCManPassword(){
    $rdcmanpath = "C:\tools\"
    if (-not(test-path "$($env:temp)\rdcman.dll")) {
        copy-item "$($rdcmanpath)\rdcman.exe" "$($env:temp)\rdcman.dll"
        unblock-file "$($env:temp)\rdcman.dll"
     }
    
    Import-Module "$($env:temp)\rdcman.dll"
    $EncryptionSettings = New-Object -TypeName RdcMan.EncryptionSettings
    return [RdcMan.Encryption]::EncryptString($Common.LocalAdmin.Password , $EncryptionSettings)
}


New-RDCManFile "C:\Tools\new4.rdg"
