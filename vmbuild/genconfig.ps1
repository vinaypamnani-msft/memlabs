. $PSScriptRoot\Common.ps1

$configDir = Join-Path $PSScriptRoot "config"

Write-Host -ForegroundColor Cyan ""
Write-Host -ForegroundColor Cyan "New-Lab Configuration generator:"
Write-Host -ForegroundColor Cyan "You can use this tool to customize most options.  Press Enter to skip a section"
Write-Host -ForegroundColor Cyan "Press Ctrl-C to exit without saving."
Write-Host -ForegroundColor Cyan ""

function Select-Config {
    $files = Get-ChildItem $configDir\*.json -Exclude "_*"
    $i = 0
    foreach ($file in $files) {
        $i = $i + 1
        write-Host "[$i] - $($file.Name)"
    }
    $responseValid = $false
    while ($responseValid -eq $false) {
        Write-Host
        $response = Read-Host -Prompt "Which config do you want to deploy"
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


function Select-OSFromList {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $currentValue
    )
  
    write-Host
    #  $Common.AzureFileList.ISO.id | Select-Object -Unique

    $i = 0
    foreach ($os in $Common.AzureFileList.OS.id | Where-Object { $_ -ne "vmbuildadmin" }) {
        $i = $i + 1
        Write-Host "[$i] - $os"
    }
    $response = get-ValidResponse "Select OS [$currentValue]" $i
    
    if ([bool]$response) {
        $i = 0
        foreach ($os in $Common.AzureFileList.OS.id | Where-Object { $_ -ne "vmbuildadmin" }) {
            $i = $i + 1
            if ($i -eq $response) {
                return $os
            }
        }
    }
    else {
        return $currentValue
    }

}

function Select-SQLFromList {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $currentValue
    )
  
    write-Host
    #  $Common.AzureFileList.ISO.id | Select-Object -Unique

    $i = 0
    foreach ($sql in $Common.AzureFileList.ISO.id | Select-Object -Unique) {
        $i = $i + 1
        Write-Host "[$i] - $sql"
    }
    $response = get-ValidResponse "Select SQL Version [$currentValue]" $i
    
    if ([bool]$response) {
        $i = 0
        foreach ($sql in $Common.AzureFileList.ISO.id | Select-Object -Unique) {
            $i = $i + 1
            if ($i -eq $response) {
                return $sql
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
        $max
    )

    $responseValid = $false
    while ($responseValid -eq $false) {
        #   Write-Host "Not Returning: $response out of $max"
        Write-Host
        $response = Read-Host -Prompt $prompt
        try {
            if (![bool]$response) {
                $responseValid = $true
            }
            if ([int]$response -is [int]) {
                if ([int]$response -le [int]$max -and $response -gt 0 ) {
                    $responseValid = $true
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
        $response = get-ValidResponse $prompt $i
        if ([bool]$response) {
            $i = 0
            $property | Get-Member -MemberType NoteProperty | ForEach-Object {
                $i = $i + 1
                $value = $property."$($_.Name)"
              
                    
                if ($response -eq $i) {
                    $name = $($_.Name)
                    switch ($name) {
                        "operatingSystem" {
                            $property."$name" = Select-OsFromList $value
                            return
                        }  
                        "sqlVersion" {
                            $property."$name" = Select-SQLFromList $value
                            return
                        }
                    }                   
                    if ($value -is [System.Management.Automation.PSCustomObject]) {
                        Select-Options $value "Select data to modify"
                    }
                    else {
                        Write-Host
                        $response = Read-Host -Prompt "Select new Value for $($_.Name) [$value]"
                        if ([bool]$response) {
                            if ($property."$($_.Name)" -is [Int]) {
                                $property."$($_.Name)" = [Int]$response
                            }
                            $property."$($_.Name)" = $response
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
        $response = get-ValidResponse "Which VM do you want to modify" $i
        
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
$response = Read-Host -Prompt "Save Filename [$filename]"
if ([bool]$response) {
    $filename = $response
}
$config | ConvertTo-Json -Depth 3 | Out-File $filename

$response = Read-Host -Prompt "Deploy Now? (y/N)"
if ([bool]$response) {
    if ($response.ToLowerInvariant() -eq "y") {
        $response = Read-Host -Prompt "Delete old VMs? (y/N)"
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
