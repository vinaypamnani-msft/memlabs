. $PSScriptRoot\Common.ps1

$configDir = Join-Path $PSScriptRoot "config"

Write-Host "New-Lab Configuration generator:"
Write-Host ""

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
    $Global:configfile=$files[[int]$response - 1]
    $config = Get-Content $Global:configfile -Force | ConvertFrom-Json
    #$config = Test-Configuration -FilePath $files[[int]$response - 1]
    #if ($config.Valid) {
    #    $Config = $config.Config
    #    #Write-Host "Config is valid"
    #}
    #else {
    #    Write-Host "Config file is not valid"
    #    return
    #}
    return $config
}

function Select-Options2 {   
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
        Write-Host "Trying to get $property"
        $property| Get-Member -MemberType NoteProperty | ForEach-Object {
            $i = $i + 1
            $value = $property."$($_.Name)"
            Write-Host [$i] $_.Name = $value
        }
        $responseValid = $false
        while ($responseValid -eq $false) {
            Write-Host
            $response = Read-Host -Prompt $prompt
            try {
                if (![bool]$response) {
                    $responseValid = $true
                }
                if ([int]$response -is [int]) {
                    if ($response -le $i -and $response -gt 0 ) {
                        $responseValid = $true
                    }
                }
            }
            catch {}      
        }
    
        if ([bool]$response) {
            $i = 0
            $property | Get-Member -MemberType NoteProperty | ForEach-Object {
                $i = $i + 1
                $value = $property."$($_.Name)"


                if ($response -eq $i) {
                    if ($value -is [System.Management.Automation.PSCustomObject])
                    {
                        Select-Options2 $value "Select data to modify"
                    }   else{
                    $response = Read-Host -Prompt "Select new Value for $($_.Name) [$value]"
                    if ([bool]$response) {
                        if ($property."$($_.Name)" -is [Int]){
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
        $responseValid = $false
        while ($responseValid -eq $false) {
            Write-Host
            $response = Read-Host -Prompt "Which VM do you want to modify [none]"
            try {
                if (![bool]$response) {
                    $responseValid = $true
                }
                if ([int]$response -is [int]) {
                    if ($response -le $i -and $response -gt 0 ) {
                        $responseValid = $true
                    }
                }
            }
            catch {}  
        }
    
        if ([bool]$response) {
            $i = 0
            foreach ($virtualMachine in $Config.virtualMachines) {
                $i = $i + 1
                if ($i -eq $response){
                    Select-Options2 $virtualMachine "Which VM property to modify"
                }
            }            
        }
        else { return }
    }
}

$Global:Config = Select-Config

Select-Options2 $($config.vmOptions) "Select Global Property to modify"
Select-Options2 $($config.cmOptions) "Select ConfigMgr Property to modify"
Select-VirtualMachines
#$config | ConvertTo-Json -Depth 3 | Out-File $configDir
 $c = Test-Configuration -InputObject $Config
    if ($c.Valid) {       
        Write-Host "Config is valid"
    }
    else {
        Write-Host "Config file is not valid: $($c.Message)"
        return
    }
 # $($file.Name)
    Write-Host
    $date = Get-Date -Format "MM-dd-yyyy"
    if ($($Global:configfile.Name).StartsWith("xGen"))
    {
        $postfix = $($Global:configfile.Name).SubString(16)
        $filename = Join-Path $configDir "xGen-$date-$postfix"
    }
    else
    {
    $filename = Join-Path $configDir "xGen-$date-$($Global:configfile.Name)"
    }
    $response = Read-Host -Prompt "Save Filename [$filename]"
    if ([bool]$response){
        $filename = $response
    }
$config | ConvertTo-Json -Depth 3 | Out-File $filename

$response = Read-Host -Prompt "Deploy Now? (y/N)"
if ([bool]$response){
    if ($response.ToLowerInvariant() -eq "y") {
        $response = Read-Host -Prompt "Delete old VMs? (y/N)"
        if ([bool]$response){
            if ($response.ToLowerInvariant() -eq "y") {
                Write-Host "Starting new-lab with delete VM options"
            }
            else{
                Write-Host "Starting new-lab without delete VM options"
            }
        }
        else{
            Write-Host "Starting new-lab without delete VM options"
        }
    }

}


#$Config.virtualMachines | ft
