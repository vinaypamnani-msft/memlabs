[CmdletBinding()]
param (
    [Parameter()]
    [Switch]
    $InternalUseOnly
)

$return = [PSCustomObject]@{
    ConfigFileName = $null
    DeployNow      = $false
    ForceNew       = $false
}

. $PSScriptRoot\Common.ps1

$configDir = Join-Path $PSScriptRoot "config"
$sampleDir = Join-Path $PSScriptRoot "config\samples"

Write-Host -ForegroundColor Cyan ""
Write-Host -ForegroundColor Cyan "New-Lab Configuration generator:"
Write-Host -ForegroundColor Cyan "You can use this tool to customize most options."
Write-Host -ForegroundColor Cyan "Press Ctrl-C to exit without saving."
Write-Host -ForegroundColor Cyan ""
Write-Host -ForegroundColor Cyan "Known Limitations: (must be done via manual json editing)"
Write-Host -ForegroundColor Cyan " - Can not add/remove Disks"
Write-Host -ForegroundColor Cyan ""

function write-help {
    $color = [System.ConsoleColor]::DarkGray
    Write-Host -ForegroundColor $color "Press " -NoNewline
    Write-Host -ForegroundColor Yellow "[Enter]" -NoNewline
    Write-Host -ForegroundColor $color " to skip a section Press " -NoNewline
    Write-Host -ForegroundColor Yellow "[Ctrl-C]" -NoNewline
    Write-Host -ForegroundColor $color " to exit without saving."
}

function Select-Config {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $ConfigPath,
        [Parameter()]
        [switch]
        $NoMore
    )
    $files = Get-ChildItem $ConfigPath\*.json -Include "Standalone.json", "Hierarchy.json" | Sort-Object -Property Name -Descending
    $files += Get-ChildItem $ConfigPath\*.json -Include "TechPreview.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "AddToExisting.json"
    $files += Get-ChildItem $ConfigPath\*.json -Exclude "_*", "Hierarchy.json", "Standalone.json", "AddToExisting.json", "TechPreview.json"
    $i = 0
    foreach ($file in $files) {
        $i = $i + 1
        write-Host "[$i] - $($file.Name)"
    }
    if (-Not $NoMore.IsPresent) {
        Write-Host "[M] - Show More (Custom and Previous config files)"
    }
    $responseValid = $false
    while ($responseValid -eq $false) {
        Write-Host
        $response = Read-Host2 -Prompt "Which config do you want to deploy"
        try {
            if ([int]$response -is [int]) {
                if ([int]$response -le [int]$i -and [int]$response -gt 0 ) {
                    $responseValid = $true
                }
            }
        }
        catch {}
        if (-Not $NoMore.IsPresent) {
            if ($response.ToLowerInvariant() -eq "m") {
                $config = Select-Config $configDir -NoMore
                if (-not $null -eq $config) {
                    return $config
                }
                $i = 0
                foreach ($file in $files) {
                    $i = $i + 1
                    write-Host "[$i] - $($file.Name)"
                }
                if (-Not $NoMore.IsPresent) {
                    Write-Host "[M] - Show More (Custom and Previous config files)"
                }
            }
        }
        else {
            if ($response -eq "") {
                return $null
            }
        }
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
    write-help
    Write-Host -ForegroundColor Cyan $prompt -NoNewline
    if ([bool]$currentValue) {
        Write-Host " [" -NoNewline
        Write-Host -ForegroundColor yellow $currentValue -NoNewline
        Write-Host "]" -NoNewline
    }
    Write-Host " : " -NoNewline
    $response = Read-Host
    return $response
}

function Get-SupportedVersion {
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

    $i = 0
    foreach ($Supported in $Common.Supported."$key") {
        $i = $i + 1
        Write-Host "[$i] - $Supported"
    }
    $response = get-ValidResponse "$prompt [$currentValue]" $i $null

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

function Get-VMList {
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

    $i = 0

    $vms = Get-VM -ErrorAction SilentlyContinue | Select-Object -Expand Name

    foreach ($Supported in $vms) {
        $i = $i + 1
        Write-Host "[$i] - $Supported"
    }
    $response = get-ValidResponse "$prompt [$currentValue]" $i $null

    if ([bool]$response) {
        $i = 0
        foreach ($Supported in $vms) {
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
        $currentValue,
        [object]
        $alternatevalues
    )

    $responseValid = $false
    while ($responseValid -eq $false) {
        #Write-Host "Not Returning: $response out of $max $alternatevalues"
        Write-Host
        $response = Read-Host2 -Prompt $prompt $currentValue
        try {
            if (![bool]$response) {
                $responseValid = $true
            }
            else {
                try {
                    if ([int]$response -is [int]) {
                        if ([int]$response -le [int]$max -and [int]$response -gt 0 ) {
                            $responseValid = $true
                        }
                    }
                }
                catch {}
            }
            if ($responseValid -eq $false -and $null -ne $alternatevalues) {
                try {
                    if ($response.ToLowerInvariant() -eq $alternatevalues.ToLowerInvariant()) {
                        $responseValid = $true
                    }
                }
                catch {}

                foreach ($i in $($alternatevalues.keys)) {
                    if ($response.ToLowerInvariant() -eq $i.ToLowerInvariant()) {
                        $responseValid = $true
                    }
                }
            }
            if ($responseValid -eq $false -and [bool]$currentValue) {
                if ($currentValue.ToLowerInvariant() -eq "true" -or $currentValue.ToLowerInvariant() -eq "false") {
                    if ($response.ToLowerInvariant() -eq "true") {
                        $response = $true
                        return $response
                    }
                    if ($response.ToLowerInvariant() -eq "false") {
                        $response = $false
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
        $prompt,
        [Parameter(Mandatory = $false)]
        [PSCustomObject]
        $additionalOptions

    )

    while ($true) {
        Write-Host ""
        $i = 0
        #   Write-Host "Trying to get $property"
        if ($null -eq $property) {
            return $null
        }
        $property | Get-Member -MemberType NoteProperty | ForEach-Object {
            $i = $i + 1
            $value = $property."$($_.Name)"
            Write-Host [$i] $_.Name = $value
        }


        if ($null -ne $additionalOptions) {
            $additionalOptions.keys | ForEach-Object {
                $value = $additionalOptions."$($_)"
                Write-Host [$_] $value
                #$additional = $_
            }
        }


        $response = get-ValidResponse $prompt $i $null $additionalOptions
        if ([bool]$response) {
            $return = $null
            if ($null -ne $additionalOptions) {
                #write-Host "Returning $response"
                $additionalOptions.keys | ForEach-Object {
                    if ($response.ToLowerInvariant() -eq $_.ToLowerInvariant()) {
                        $return = $_

                    }
                }
            }
            if ($null -ne $return) {
                return $return
            }
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
                            return $null
                        }
                        "sqlVersion" {
                            $property."$name" = Get-SupportedVersion "SqlVersions" $value "Select SQL Version"
                            return $null
                        }
                        "role" {
                            if ($Global:AddToExisting -eq $true) {
                                $property."$name" = Get-SupportedVersion "RolesForExisting" $value "Select Role"
                            }
                            else {
                                $property."$name" = Get-SupportedVersion "Roles" $value "Select Role"
                            }
                            return $null
                        }
                        "version" {
                            $property."$name" = Get-SupportedVersion "CmVersions" $value "Select ConfigMgr Version"
                            return $null
                        }
                        "existingDCNameWithPrefix" {
                            $property."$name" = Get-VMList "ExistingDCs" $value "Select Existing DC"
                            return $null
                        }
                    }
                    if ($value -is [System.Management.Automation.PSCustomObject]) {
                        Select-Options $value "Select data to modify"
                    }
                    else {
                        $valid = $false
                        Write-Host
                        while ($valid -eq $false) {
                            $response2 = Read-Host2 -Prompt "Select new Value for $($_.Name)" $value
                            if ([bool]$response2) {
                                if ($property."$($_.Name)" -is [Int]) {
                                    $property."$($_.Name)" = [Int]$response2
                                }
                                else {
                                    if ($value -is [bool]) {
                                        if ($([string]$value).ToLowerInvariant() -eq "true" -or $([string]$value).ToLowerInvariant() -eq "false") {
                                            if ($response2.ToLowerInvariant() -eq "true") {
                                                $response2 = $true
                                            }
                                            else {
                                                if ($response2.ToLowerInvariant() -eq "false") {
                                                    $response2 = $false
                                                }
                                                else {
                                                    $response2 = $value
                                                }
                                            }

                                        }

                                    }
                                    $property."$($_.Name)" = $response2


                                }
                                $c = Test-Configuration -InputObject $Config
                                $valid = $c.Valid
                                if ($valid -eq $false) {
                                    Write-Host -ForegroundColor Red $c.Message
                                }
                                if ( $c.Failures -eq 0) {
                                    $valid = $true
                                }

                            }
                            else {
                                $property."$($_.Name)" = $value
                                $c = Test-Configuration -InputObject $Config
                                $valid = $c.Valid
                                if ($valid -eq $false) {
                                    Write-Host -ForegroundColor Red $c.Message
                                }
                                if ( $c.Failures -eq 0) {
                                    $valid = $true
                                }
                                $valid = $true
                            }
                        }
                    }

                }

            }
        }
        else { return $null }
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
        write-Host "[N] - New Virtual Machine"
        $response = get-ValidResponse "Which VM do you want to modify" $i $null "n"
        Write-Log -HostOnly -Verbose "response = $response"
        if ([bool]$response) {
            if ($response.ToLowerInvariant() -eq "n") {
                $Config.VirtualMachines += [PSCustomObject]@{
                    vmName          = "Member" + $([int]$i + 1)
                    role            = "DomainMember"
                    operatingSystem = "Windows 10 Latest (64-bit)"
                    memory          = "2GB"
                    virtualProcs    = 2
                }
                $response = $i + 1
            }
            $i = 0
            foreach ($virtualMachine in $Config.virtualMachines) {
                $i = $i + 1
                if ($i -eq $response) {
                    $newValue = "Start"
                    while ($newValue -ne "D" -and -not ([string]::IsNullOrWhiteSpace($($newValue)))) {
                        Write-Log -HostOnly -Verbose "NewValue = '$newvalue'"
                        $customOptions = @{ "A" = "Add Additional Disk" }
                        if ($null -eq $virtualMachine.additionalDisks) {
                            #$customOptions["A"] = "Add Additional Disk"
                        }
                        else {
                            #$customOptions["A"] = "Add Additional Disk"
                            $customOptions["R"] = "Remove Last Additional Disk"
                        }
                        if ($null -eq $virtualMachine.sqlVersion) {
                            $customOptions["S"] = "Add SQL"
                        }
                        else {
                            $customOptions["X"] = "Remove SQL"
                        }
                        $customOptions["D"] = "Delete this VM"
                        $newValue = Select-Options $virtualMachine "Which VM property to modify" $customOptions
                        if (([string]::IsNullOrEmpty($newValue))){
                            break
                        }
                        if ($newValue -eq "S") {
                            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
                            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "C:\SQL"
                        }
                        if ($newValue -eq "X") {
                            $virtualMachine.psobject.properties.remove('sqlversion')
                            $virtualMachine.psobject.properties.remove('sqlInstanceDir')
                        }
                        if ($newValue -eq "A") {
                            if ($null -eq $virtualMachine.additionalDisks) {
                                $disk = [PSCustomObject]@{"E" = "100GB" }
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
                            }
                            else {
                                $letters = 69
                                $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                    $letters++
                                }
                                if ($letters -lt 90) {
                                    $letter = $([char]$letters).ToString()
                                    $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name $letter -Value "100GB"
                                }
                            }
                        }
                        if ($newValue -eq "R") {
                            $diskscount = 0
                            #$savedDisks = $virtualMachine.additionalDisks | ConvertTo-Json | ConvertFrom-Json
                            $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                $diskscount++
                            }
                            if ($diskscount -eq 1) {
                                $virtualMachine.psobject.properties.remove('additionalDisks')
                            }
                            else {
                                $i = 0
                                $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                    $i = $i + 1
                                    if ($i -eq $diskscount) {
                                        $virtualMachine.additionalDisks.psobject.properties.remove($_.Name)
                                    }
                                }
                            }
                            if ($diskscount -eq 1) {
                                $virtualMachine.psobject.properties.remove('additionalDisks')
                            }
                        }
                    }
                }
            }
            if ($newValue -eq "D") {
                $newvm = $Config.virtualMachines | ConvertTo-Json | ConvertFrom-Json
                $Config.virtualMachines = @()
                $i = 0
                foreach ($virtualMachine in $newvm) {
                    $i = $i + 1
                    if ($i -ne $response) {
                        $Config.virtualMachines += $virtualMachine
                    }
                }
            }



        }
        else { return }
    }
}

$Global:Config = Select-Config $sampleDir
$Global:AddToExisting = $false
if ($($null -ne $config.vmOptions.existingDCNameWithPrefix)) {
    $Global:AddToExisting = $true
}
$valid = $false
while ($valid -eq $false) {
    Select-Options $($config.vmOptions) "Select Global Property to modify"
    Select-Options $($config.cmOptions) "Select ConfigMgr Property to modify"
    Select-VirtualMachines
    #$config | ConvertTo-Json -Depth 3 | Out-File $configDir
    $c = Test-Configuration -InputObject $Config
    Write-Host
    # Write-Host "-----------------------------------------------------------------------------"
    # Write-Host
    if ($c.Valid) {
        $valid = $true
    }
    else {
        Write-Host -ForegroundColor Red "Config file is not valid: `r`n$($c.Message)"
        Write-Host -ForegroundColor Red "Please fix the problem(s), or hit CTRL-C to exit."
    }
}
# $($file.Name)
#Write-Host
Show-Summary ($c.DeployConfig)
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
    if (!$response.EndsWith("json")) {
        $response += ".json"
    }
    $filename = Join-Path $configDir $response
}
$config | ConvertTo-Json -Depth 3 | Out-File $filename
$return.ConfigFileName = Split-Path -Path $fileName -Leaf
Write-Host "Saved to $filename"
Write-Host

if (-not $InternalUseOnly.IsPresent) {
    Write-Host "You can deploy this configuration by running the following command:"
    Write-Host "$($PSScriptRoot)\New-Lab.ps1 -Configuration $($return.ConfigFileName)"
}


#================================= NEW LAB SCENERIO ============================================
if ($InternalUseOnly.IsPresent) {
    $response = Read-Host2 -Prompt "Deploy Now? (y/N)" $null
    if ([bool]$response) {
        if ($response.ToLowerInvariant() -eq "y") {
            Write-Host
            $response = Read-Host2 -Prompt "Delete old VMs? (y/N)"
            if ([bool]$response) {
                if ($response.ToLowerInvariant() -eq "y") {
                    $return.ForceNew = $true
                    $return.DeployNow = $true
                    # Write-Host "Starting new-lab with delete VM options"
                }
                else {
                    $return.DeployNow = $true
                    # Write-Host "Starting new-lab without delete VM options"
                }
            }
            else {
                $return.DeployNow = $true
                # Write-Host "Starting new-lab without delete VM options"
            }
        }
        else {
            # Write-Host "Not Deploying."
        }

    }
    else {
        # Write-Host "Not Deploying."
    }
    return $return
}

