. $PSScriptRoot\Common.ps1

$configDir = Join-Path $PSScriptRoot "config"

Write-Host -ForegroundColor Cyan ""
Write-Host -ForegroundColor Cyan "New-Lab Configuration generator:"
Write-Host -ForegroundColor Cyan "You can use this tool to customize most options.  Press Enter to skip a section"
Write-Host -ForegroundColor Cyan "Press Ctrl-C to exit without saving."
Write-Host -ForegroundColor Cyan ""
Write-Host -ForegroundColor Cyan "Known Limitations: (must be done via manual json editing)"
Write-Host -ForegroundColor Cyan " - Can not remove a prefix"
Write-Host -ForegroundColor Cyan " - Can not add/remove VMs"
Write-Host -ForegroundColor Cyan " - Can not add/remove Disks"
Write-Host -ForegroundColor Cyan ""
function Select-Config {
    $files = Get-ChildItem $configDir\*.json -Include "Standalone.json", "Hierarchy.json"| Sort-Object -Property Name -Descending
    $files += Get-ChildItem $configDir\*.json -Include "TechPreview.json"
    $files += Get-ChildItem $configDir\*.json -Include "AddToExisting.json"
    $files += Get-ChildItem $configDir\*.json -Exclude "_*", "Hierarchy.json", "Standalone.json", "AddToExisting.json", "TechPreview.json"
    $i = 0
    foreach ($file in $files) {
        $i = $i + 1
        write-Host "[$i] - $($file.Name)"
    }
    $responseValid = $false
    while ($responseValid -eq $false) {
        Write-Host
        $response = Read-Host2 -Prompt "Which config do you want to deploy"
        try {
            if ([int]$response -is [int]) {
                if ($response -le $i -and $response -gt 0 ) {
                    $responseValid = $true
                }
            }
        }
        catch {}  
    }
    $Global:configfile = $files[[int]$response - 1]
    $config = Get-Content $Global:configfile -Force | ConvertFrom-Json    
    return $config
}

function Read-Host2 {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $prompt,
        [Parameter()]
        [string]
        $currentValue        
    )

    Write-Host -ForegroundColor Cyan $prompt -NoNewline
    if ([bool]$currentValue)
    {
        Write-Host " [" -NoNewline
        Write-Host -ForegroundColor yellow $currentValue -NoNewline
        Write-Host "]" -NoNewline
    }
    Write-Host " : " -NoNewline
    $response = Read-Host
    return $response
}

function Get-SupportedVersion  {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $key,    
        [Parameter()]
        [string]
        $currentValue,
        [Parameter()]
        [string]
        $prompt
    )
  
    write-Host
    #  $Common.AzureFileList.ISO.id | Select-Object -Unique

    $i = 0
    foreach ($Supported in $Common.Supported."$key") {
        $i = $i + 1
        Write-Host "[$i] - $Supported"
    }
    $response = get-ValidResponse "$prompt [$currentValue]" $i
    
    if ([bool]$response) {
        $i = 0
        foreach ($Supported in $Common.Supported."$key") {
            $i = $i + 1
            if ($i -eq $response) {
                return $Supported
            }
        }
    }
    else {
        return $currentValue
    }

}

function get-ValidResponse {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Prompt,
        [Parameter()]
        [int]
        $max,
        [Parameter()]
        [string]
        $currentValue
    )

    $responseValid = $false
    while ($responseValid -eq $false) {
        #   Write-Host "Not Returning: $response out of $max"
        Write-Host
        $response = Read-Host2 -Prompt $prompt $currentValue
        try {
            if (![bool]$response) {
                $responseValid = $true
            }
            if ([int]$response -is [int]) {
                if ([int]$response -le [int]$max -and $response -gt 0 ) {
                    $responseValid = $true
                }
            }
            if ([bool]$currentValue){
                if ($currentValue.ToLowerInvariant() -eq "true" -or $currentValue.ToLowerInvariant() -eq "false"){
                    if ($response.ToLowerInvariant() -eq "true") {
                        $response = "True"
                        return $response
                    }
                    if ($response.ToLowerInvariant() -eq "false") {
                        $response = "False"
                        return $response
                    }
                    $responseValid = $false
                }
            }
        }
        catch {}      
    }
    #Write-Host "Returning: $response"
    return $response
}

function Select-Options {   
    [CmdletBinding()]
    param (
        [Parameter()]
        [object]
        $property,
        [Parameter()]
        [string]
        $prompt
 
    )
    while ($true) {
        Write-Host ""
        $i = 0
        #   Write-Host "Trying to get $property"
        if ($null -eq $property) {
            return
        }
        $property | Get-Member -MemberType NoteProperty | ForEach-Object {
            $i = $i + 1
            $value = $property."$($_.Name)"
            Write-Host [$i] $_.Name = $value
        }
        $response = get-ValidResponse $prompt $i $null
        if ([bool]$response) {
            $i = 0
            $property | Get-Member -MemberType NoteProperty | ForEach-Object {
                $i = $i + 1
                $value = $property."$($_.Name)"
              
                    
                if ($response -eq $i) {
                    $name = $($_.Name)
                    switch ($name) {
                        "operatingSystem" {
                            $property."$name" = Get-SupportedVersion "OperatingSystems" $value "Select OS Version"
                            #Select-OsFromList $value
                            return
                        }  
                        "sqlVersion" {
                            $property."$name" = Get-SupportedVersion "SqlVersions" $value "Select SQL Version"
                            return
                        }
                        "role" {
                            $property."$name" = Get-SupportedVersion "Roles" $value "Select Role"
                            return
                        }
                        "version" {
                            $property."$name" = Get-SupportedVersion "CmVersions" $value "Select ConfigMgr Version"
                            return
                        }
                    }                   
                    if ($value -is [System.Management.Automation.PSCustomObject]) {
                        Select-Options $value "Select data to modify"
                    }
                    else {
                        Write-Host
                        $response2 = Read-Host2 -Prompt "Select new Value for $($_.Name)" $value
                        if ([bool]$response2) {
                            if ($property."$($_.Name)" -is [Int]) {
                                $property."$($_.Name)" = [Int]$response2
                                return
                            }
                            if ([bool]$value){
                                if ($([string]$value).ToLowerInvariant() -eq "true" -or $([string]$value).ToLowerInvariant() -eq "false"){
                                    if ($response2.ToLowerInvariant() -eq "true") {
                                        $response2 = "True"
                                    }else{
                                        if ($response2.ToLowerInvariant() -eq "false") {
                                            $response2 = "False"
                                        }
                                        else{
                                            $response2 = $value
                                            }
                                    }
                                    
                                }
                            }
                            $property."$($_.Name)" = $response2
                            return
                        }
                    }
                    
                }
                    
            }
        }
        else { return }
    }  
}

function Select-VirtualMachines {


    while ($true) {
        Write-Host ""
        $i = 0
        foreach ($virtualMachine in $Config.virtualMachines) {
            $i = $i + 1
            write-Host "[$i] - $($virtualMachine)"
        }
        $response = get-ValidResponse "Which VM do you want to modify" $i $null
        
        if ([bool]$response) {
            $i = 0
            foreach ($virtualMachine in $Config.virtualMachines) {
                $i = $i + 1
                if ($i -eq $response) {
                    Select-Options $virtualMachine "Which VM property to modify"
                }
            }            
        }
        else { return }
    }
}

$Global:Config = Select-Config

Select-Options $($config.vmOptions) "Select Global Property to modify"
Select-Options $($config.cmOptions) "Select ConfigMgr Property to modify"
Select-VirtualMachines
#$config | ConvertTo-Json -Depth 3 | Out-File $configDir
$c = Test-Configuration -InputObject $Config
Write-Host
Write-Host "-----------------------------------------------------------------------------"
Write-Host
if ($c.Valid) {       
    
    Write-Host -ForegroundColor Green "Config is valid"
}
else {
    Write-Host -ForegroundColor Red "Config file is not valid: $($c.Message)"
    return
}
# $($file.Name)
Write-Host
$date = Get-Date -Format "MM-dd-yyyy"
if ($($Global:configfile.Name).StartsWith("xGen")) {
    $postfix = $($Global:configfile.Name).SubString(16)
    $filename = Join-Path $configDir "xGen-$date-$postfix"
}
else {
    $filename = Join-Path $configDir "xGen-$date-$($Global:configfile.Name)"
}
$splitpath = Split-Path -Path $fileName -Leaf
$response = Read-Host2 -Prompt "Save Filename" $splitpath
if ([bool]$response) {
    if (!$response.EndsWith("json")){
        $response+=".json"
    }
    $filename = Join-Path $configDir $response
}
$config | ConvertTo-Json -Depth 3 | Out-File $filename
Write-Host "Saved to $filename"
Write-Host
$response = Read-Host2 -Prompt "Deploy Now? (y/N)" $null
if ([bool]$response) {
    if ($response.ToLowerInvariant() -eq "y") {
        $response = Read-Host2 -Prompt "Delete old VMs? (y/N)"
        if ([bool]$response) {
            if ($response.ToLowerInvariant() -eq "y") {
                Write-Host "Starting new-lab with delete VM options"
            }
            else {
                Write-Host "Starting new-lab without delete VM options"
            }
        }
        else {
            Write-Host "Starting new-lab without delete VM options"
        }
    }
    else {
        Write-Host "Not Deploying."
    }

}
else {
    Write-Host "Not Deploying."
}


#$Config.virtualMachines | ft
