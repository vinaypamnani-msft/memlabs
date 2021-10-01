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

function write-help {
    $color = [System.ConsoleColor]::DarkGray
    Write-Host -ForegroundColor $color "Press " -NoNewline
    Write-Host -ForegroundColor Yellow "[Enter]" -NoNewline
    Write-Host -ForegroundColor $color " to skip a section Press " -NoNewline
    Write-Host -ForegroundColor Yellow "[Ctrl-C]" -NoNewline
    Write-Host -ForegroundColor $color " to exit without saving."
}

function Write-Option {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $option,
        [string]
        $text,
        [object]
        $color,
        [object]
        $color2
    )

    if ($null -eq $color) {
        $color = [System.ConsoleColor]::Gray
    }
    if ($null -eq $color2) {
        $color2 = [System.ConsoleColor]::White
    }
    write-host "[" -NoNewline
    Write-Host -ForegroundColor $color2 $option -NoNewline
    Write-Host "] " -NoNewLine
    Write-Host -ForegroundColor $color "$text"

}

function Select-ConfigMenu {
    while ($true) {
        $customOptions = [ordered]@{ "1" = "Create New Domain"; "2" = "Expand Existing Domain"; "3" = "Load Sample Configuration"; "4" = "Load saved config from File"; "D" = "Delete an existing domain" }
        $response = Get-Menu -Prompt "Select menu option" -AdditionalOptions $customOptions
        write-Verbose "response $response"
        if (-not $response) {
            continue
        }
        $SelectedConfig = $null
        switch ($response.ToLowerInvariant()) {
            "1" { $SelectedConfig = Select-NewDomainConfig }
            "2" { $SelectedConfig = Show-ExistingNetwork }
            "3" { $SelectedConfig = Select-Config $sampleDir -NoMore }
            "4" { $SelectedConfig = Select-Config $configDir -NoMore }
            "d" {}
            Default {}
        }
        if ($SelectedConfig) {
            return $SelectedConfig
        }

    }
}

function Select-MainMenu {
    while ($true) {
        $customOptions = [ordered]@{ "1" = "VM Options"; "2" = "CM Options"; "3" = "Virtual Machines"; "D" = "Deploy Config" }
        $response = Get-Menu -Prompt "Select menu option" -AdditionalOptions $customOptions
        write-Verbose "response $response"
        if (-not $response) {
            continue
        }
        switch ($response.ToLowerInvariant()) {
            "1" { Select-Options $($Global:Config.vmOptions) "Select Global Property to modify" }
            "2" { Select-Options $($Global:Config.cmOptions) "Select ConfigMgr Property to modify" }
            "3" { Select-VirtualMachines }
            "d" { return $true }
        }       
    }
}

function Get-ValidSubnets {


    $subnetlist = @()
    for ($i = 1; $i -lt 254; $i++) {
        $newSubnet = "192.168." + $i + ".0"
        $found = $false
        foreach ($subnet in (Get-SubnetList)) {
            if ($subnet.Subnet -eq $newSubnet) {
                $found = $true
                break
            }  
        }
        if (-not $found) {
            $subnetlist += $newSubnet
            if ($subnetlist.Count -gt 8) {
                break
            }
            
        }
    }

    return $subnetlist

}

function Select-NewDomainConfig {

    #$ValidDomainNames = [System.Collections.ArrayList]("adatum.com", "adventure-works.com", "alpineskihouse.com", "bellowscollege.com", "bestforyouorganics.com", "contoso.com", "contososuites.com",
    #   "consolidatedmessenger.com", "fabrikam.com", "fabrikamresidences.com", "firstupconsultants.com", "fourthcoffee.com", "graphicdesigninstitute.com", "humongousinsurance.com",
    #   "lamnahealthcare.com", "libertysdelightfulsinfulbakeryandcafe.com", "lucernepublishing.com", "margiestravel.com", "munsonspicklesandpreservesfarm.com", "nodpublishers.com",
    #   "northwindtraders.com", "proseware.com", "relecloud.com", "fineartschool.net", "southridgevideo.com", "tailspintoys.com", "tailwindtraders.com", "treyresearch.net", "thephone-company.com",
    #  "vanarsdelltd.com", "wideworldimporters.com", "wingtiptoys.com", "woodgrovebank.com", "techpreview.com" )

    $ValidDomainNames = @{"adatum.com" = "ADA-" ; "adventure-works.com" = "ADV-" ; "alpineskihouse.com" = "ALP-" ; "bellowscollege.com" = "BLC-" ;  "contoso.com" = "CON-" ; "contososuites.com" = "COS-" ;
        "fabrikam.com" = "FAB-" ; "fourthcoffee.com" = "FOR-" ; 
        "lamnahealthcare.com" = "LAM-"  ;  "margiestravel.com" = "MGT-" ; "nodpublishers.com" = "NOD-" ;
        "proseware.com" = "PRO-" ; "relecloud.com" = "REL-" ; "fineartschool.net" = "FAS-" ; "southridgevideo.com" = "SRV-" ; "tailspintoys.com" = "TST-" ; "tailwindtraders.com" = "TWT-" ; "treyresearch.net" = "TRY-"; 
        "vanarsdelltd.com" = "VAN-" ;  "wingtiptoys.com" = "WTT-" ; "woodgrovebank.com" = "WGB-" ; "techpreview.com" = "TEC-" 
    }
    foreach ($domain in (Get-DomainList)) {
        $ValidDomainNames.Remove($domain.ToLowerInvariant())
    }

    $usedPrefixes = Get-List -Type UniquePrefix
    foreach ($dname in $ValidDomainNames.Keys) {
        foreach ($usedPrefix in $usedPrefixes) {
            if ($ValidDomainNames[$dname].ToLowerInvariant() -eq $usedPrefix.ToLowerInvariant()) {
                Write-Verbose ("Removing $dname")
                $ValidDomainNames.Remove($dname)
            }
        }    
    }
    $domain = $null
    while (-not $domain) {
        $domain = Get-Menu -Prompt "Select Domain" -OptionArray $ValidDomainNames.Keys
    }
    $prefix = $($ValidDomainNames[$domain])
    Write-Verbose "Prefix = $prefix"
    $subnetlist = Get-ValidSubnets
   
    while (-not $network) {
        $network = Get-Menu -Prompt "Select Network" -OptionArray $subnetlist
    }
 
    $customOptions = @{ "C" = "CAS and Primary"; "P" = "Primary Site only"; "N" = "No Configmgr" }
    $response = $null
    while (-not $response) {
        $response = Get-Menu -Prompt "Select ConfigMgr Options" -AdditionalOptions $customOptions
    }

    $CASJson = Join-Path $sampleDir "Hierarchy.json"
    $PRIJson = Join-Path $sampleDir "Standalone.json"
    $NoCMJson = Join-Path $sampleDir "NoConfigMgr.json"
    switch ($response.ToLowerInvariant()) {
        "c" { $newConfig = Get-Content $CASJson -Force | ConvertFrom-Json }
        "p" { $newConfig = Get-Content $PRIJson -Force | ConvertFrom-Json }    
        "n" { $newConfig = Get-Content $NoCMJson -Force | ConvertFrom-Json }     
    }

    $newConfig.vmOptions.domainName = $domain
    $newConfig.vmOptions.network = $network
    $newConfig.vmOptions.prefix = $prefix
    return $newConfig
}

# Gets the json files from the config\samples directory, and offers them up for selection.
# if 'M' is selected, shows the json files from the config directory.
function Select-Config {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $ConfigPath,
        # -NoMore switch will hide the [M] More options when we go into the submenu
        [Parameter()]
        [switch]
        $NoMore
    )
    $files = @()
    $files += Get-ChildItem $ConfigPath\*.json -Include "Standalone.json", "Hierarchy.json" | Sort-Object -Property Name -Descending
    $files += Get-ChildItem $ConfigPath\*.json -Include "TechPreview.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "NoConfigMgr.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "AddToExisting.json"
    $files += Get-ChildItem $ConfigPath\*.json -Exclude "_*", "Hierarchy.json", "Standalone.json", "AddToExisting.json", "TechPreview.json", "NoConfigMgr.json"
    $responseValid = $false
    while ($responseValid -eq $false) {
        $i = 0
        foreach ($file in $files) {
            $i = $i + 1
            Write-Option $i $($file.Name)
        }
        if (-Not $NoMore.IsPresent) {
            Write-Option "M" "Show More (Custom and Previous config files)" -color DarkGreen -Color2 Green
            Write-Option "E" "Expand existing network" -color DarkGreen -Color2 Green

        }
        #    $responseValid = $false
        #    while ($responseValid -eq $false) {
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
                $configSelected = Select-Config $configDir -NoMore 
                if (-not $null -eq $configSelected) {
                    return $configSelected
                }
                $i = 0
                foreach ($file in $files) {
                    $i = $i + 1
                    write-Host "[$i] $($file.Name)"
                }
                if (-Not $NoMore.IsPresent) {
                    Write-Option "M" "Show More (Custom and Previous config files)" -color DarkGreen -Color2 Green
                    Write-Option "E" "Expand existing network" -color DarkGreen -Color2 Green
                }
            }
            if ($response.ToLowerInvariant() -eq "e") {
                $newConfig = Show-ExistingNetwork
                if ($newConfig) {
                    return $newConfig
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
    $configSelected = Get-Content $Global:configfile -Force | ConvertFrom-Json
    return $configSelected
}

function Show-ExistingNetwork {

    $domain = Get-Menu -Prompt "Select existing domain" -OptionArray (Get-DomainList)
    if ([string]::isnullorwhitespace($domain)) {
        return $null
    }
    $role = Select-RolesForExisting

    $subnet = Select-ExistingSubnets $domain $role
    if ([string]::IsNullOrWhiteSpace($subnet)) {
        return $null
    }

    return Generate-ExistingConfig $domain $subnet $role
}
function Select-RolesForExisting {

    $role = Get-Menu "Select Role" $($Common.Supported.RolesForExisting) $value

    return $role
    #   switch ($role) {
    #       "Primary" { }
    #       "DomainMember" { }
    #       "DPMP" {}
    #   }   
}

function Select-ExistingSubnets {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Domain,
        [Parameter()]
        [string]
        $Role
    )

    $valid = $false
    while ($valid -eq $false) {

        $customOptions = @{ "N" = "add New Subnet to domain" }
        $subnetList = Get-SubnetList -DomainName $Domain | Select -Expand Subnet | Get-Unique

        $subnetListNew = @()
        if ($Role -eq "Primary"){
            foreach ($subnet in $subnetList) {
                $existingPri = Get-ExistingForSubnet -Subnet $subnet -Role Primary
                if ($null -eq $existingPri){
                    $subnetListNew.Add($subnet)
                }                
            }
        }else{
            $subnetListNew = $subnetList
        }

        $response = Get-Menu -Prompt "Select existing subnet" -OptionArray $subnetListNew -AdditionalOptions $customOptions
        #write-host "response $response"
        if (-not $response) {
            return $null
        }
        #write-host "response $response"
        if ($response.ToLowerInvariant() -eq "n") { 

            $subnetlist = Get-ValidSubnets
   
            while (-not $network) {
                $network = Get-Menu -Prompt "Select Network" -OptionArray $subnetlist
            }
            $response = $network
            
        }
        $valid = Get-TestResult -Config (Generate-ExistingConfig -Domain $Domain -Subnet $response)
    }
    return $response
}




function Generate-ExistingConfig {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Domain,
        [Parameter()]
        [string]
        $Subnet,
        [string]
        $Role       
    )

    Write-Verbose "Generating $Domain $Subnet $role"

    $prefix = Get-List -Type UniquePrefix -Domain $Domain | select -First 1

    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = "CUSTOM-"
    }
    $vmOptions = [PSCustomObject]@{
        prefix          = $prefix
        basePath        = "E:\VirtualMachines"
        domainName      = $Domain
        domainAdminName = "admin"
        network         = $Subnet
    }


    

    $virtualMachines = @()
    if ([string]::IsNullOrWhiteSpace($role) -or $role -eq "DomainMember") {
        $virtualMachines += [PSCustomObject]@{
            vmName          = "NEWMember"
            role            = "DomainMember"
            operatingSystem = "Server 2022"
            memory          = "2GB"
            virtualProcs    = 2
        }
    }
    elseif ($role -eq "DPMP") {
        $virtualMachines += [PSCustomObject]@{
            vmName          = "NEWDPMP"
            role            = "DPMP"
            operatingSystem = "Server 2022"
            memory          = "3GB"
            virtualProcs    = 2
        }
    }
    elseif ($role -eq "Primary") {
       
        $newCmOptions = [PSCustomObject]@{
            version                   = "current-branch"
            install                   = $true
            updateToLatest            = $true
            installDPMPRoles          = $true
            pushClientToDomainMembers = $true
        }
        $virtualMachines += [PSCustomObject]@{
            vmName          = "NEWPRI"
            role            = "Primary"
            operatingSystem = "Server 2022"
            memory          = "12GB"
            sqlVersion      = "SQL Server 2019"
            sqlInstanceDir  = "C:\SQL"
            cmInstallDir    = "C:\ConfigMgr"
            siteCode        = "PS2"
            virtualProcs    = 4
        }         
        $configGenerated = [PSCustomObject]@{
            cmOptions       = $newCmOptions
            vmOptions       = $vmOptions
            virtualMachines = $virtualMachines        
        }                        
    }
    if (-not $role -eq "Primary") {
        $configGenerated = [PSCustomObject]@{
            #cmOptions       = $newCmOptions
            vmOptions       = $vmOptions
            virtualMachines = $virtualMachines        
        }
    }
    return $configGenerated
}

# Replacement for Read-Host that offers a colorized prompt
function Read-Host2 {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $prompt,
        [Parameter()]
        [string]
        $currentValue,
        [Parameter()]
        [switch]
        $HideHelp
    )
    if (-not $HideHelp.IsPresent) {
        write-help
    }
    Write-Host -ForegroundColor Cyan $prompt -NoNewline
    if (-not [String]::IsNullOrWhiteSpace($currentValue)) {
        Write-Host " [" -NoNewline
        Write-Host -ForegroundColor yellow $currentValue -NoNewline
        Write-Host "]" -NoNewline
    }
    Write-Host " : " -NoNewline
    $response = Read-Host
    return $response
}


# Offers a menu for any array passed in.
# This is used for Sql Versions, Roles, Etc
function Get-Menu {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Prompt,
        [Parameter()]
        [object]
        $OptionArray,
        [Parameter()]
        [string]
        $CurrentValue,
        [object]
        $additionalOptions
    )

    write-Host
    $i = 0

    foreach ($option in $OptionArray) {
        $i = $i + 1
        Write-Option $i $option
    }

    if ($null -ne $additionalOptions) {
        $additionalOptions.keys | ForEach-Object {
            $value = $additionalOptions."$($_)"
            #Write-Host -ForegroundColor DarkGreen [$_] $value
            Write-Option $_ $value -color DarkGreen -Color2 Green
        }
    }

    $response = get-ValidResponse $Prompt $i $CurrentValue -AdditionalOptions $additionalOptions -TestBeforeReturn

    if (-not [String]::IsNullOrWhiteSpace($response)) {
        $i = 0
        foreach ($option in $OptionArray) {
            $i = $i + 1
            if ($i -eq $response) {
                return $option
            }
        }
        return $response
    }
    else {
        return $CurrentValue
    }

}

#Checks if the response from the menu was valid.
# Prompt is the prompt to display
# Max is the max int allowed [1], [2], [3], etc
# The current value of the option
# additionalOptions , like [N] New VM, [S] Add SQL, either as a single letter in a string, or keys in a dictionary.
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
        $additionalOptions,
        [switch]
        $AnyString,
        [switch]
        $TestBeforeReturn

    )

    $responseValid = $false
    while ($responseValid -eq $false) {
        Write-Host
        $response = Read-Host2 -Prompt $prompt $currentValue
        try {
            if ([String]::IsNullOrWhiteSpace($response)) {
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
            if ($responseValid -eq $false -and $null -ne $additionalOptions) {
                try {
                    if ($response.ToLowerInvariant() -eq $additionalOptions.ToLowerInvariant()) {
                        $responseValid = $true
                    }
                }
                catch {}

                foreach ($i in $($additionalOptions.keys)) {
                    if ($response.ToLowerInvariant() -eq $i.ToLowerInvariant()) {
                        $responseValid = $true
                    }
                }
            }
            if ($responseValid -eq $false -and $currentValue -is [bool]) {
                if ($currentValue.ToLowerInvariant() -eq "true" -or $currentValue.ToLowerInvariant() -eq "false") {
                    $responseValid = $false
                    if ($response.ToLowerInvariant() -eq "true") {
                        $response = $true
                        $responseValid = $true
                    }
                    if ($response.ToLowerInvariant() -eq "false") {
                        $response = $false
                        $responseValid = $true
                    }
                }
            }
        }
        catch {}
        if ($TestBeforeReturn.IsPresent -and $responseValid) {
            $responseValid = Get-TestResult -SuccessOnError
        }
    }
    #Write-Host "Returning: $response"
    return $response
}


# Displays a Menu based on a property, offers options in [1], [2],[3] format
# With additional options passed in via additionalOptions
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
        #Write-Host "Trying to get $property"
        if ($null -eq $property) {
            return $null
        }
        $property | Get-Member -MemberType NoteProperty | ForEach-Object {
            $i = $i + 1
            $value = $property."$($_.Name)"
            $padding = 27 - ($i.ToString().Length)
            Write-Option $i "$($($_.Name).PadRight($padding," "")) = $value"
        }

        if ($null -ne $additionalOptions) {
            $additionalOptions.keys | ForEach-Object {
                $value = $additionalOptions."$($_)"
                #Write-Host -ForegroundColor DarkGreen [$_] $value
                Write-Option $_ $value -color DarkGreen -Color2 Green
            }
        }

        $response = get-ValidResponse $prompt $i $null $additionalOptions
        if (-not [String]::IsNullOrWhiteSpace($response)) {
            $return = $null
            if ($null -ne $additionalOptions) {
                foreach ($item in $($additionalOptions.keys)) {
                    if ($response.ToLowerInvariant() -eq $item.ToLowerInvariant()) {
                        $return = $item
                    }
                }
                #$additionalOptions.keys | ForEach-Object {
                #    if ($response.ToLowerInvariant() -eq $_.ToLowerInvariant()) {
                #        # HACK..  "return $_" doesnt work here.. acts like a continue.. Maybe because of the foreach-object?
                #        $return = $_

                #   }
                #}
            }
            #Return here instead
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
                            $valid = $false
                            while ($valid -eq $false) {
                                $property."$name" = Get-Menu "Select OS Version" $($Common.Supported.OperatingSystems) $value
                                if (Get-TestResult -SuccessOnWarning) {
                                    return
                                }
                                else {
                                    if ($property."$name" -eq $value) {
                                        return
                                    }
                                }
                            }

                        }
                        "sqlVersion" {
                            $valid = $false
                            while ($valid -eq $false) {
                                $property."$name" = Get-Menu "Select SQL Version" $($Common.Supported.SqlVersions) $value
                                if (Get-TestResult -SuccessOnWarning) {
                                    return
                                }
                                else {
                                    if ($property."$name" -eq $value) {
                                        return
                                    }
                                }
                            }
                        }
                        "role" {
                            $valid = $false
                            while ($valid -eq $false) {
                                if ($Global:AddToExisting -eq $true) {

                                    $role = Get-Menu "Select Role" $($Common.Supported.RolesForExisting) $value
                                    $property."$name" = $role                                    
                                }
                                else {
                                    $role = Get-Menu "Select Role" $($Common.Supported.Roles) $value
                                    $property."$name" = $role
                                }

                                if ($role -eq "Primary") {                                        
                                    if ($null -eq $($global:config.cmOptions)) {
                                        $newCmOptions = [PSCustomObject]@{
                                            version                   = "current-branch"
                                            install                   = $true
                                            updateToLatest            = $true
                                            installDPMPRoles          = $true
                                            pushClientToDomainMembers = $true
                                        }
                                        $global:config | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $newCmOptions                                        
                                    }
                                    if ($null -eq $($property.sqlVersion) ) {
                                        $property | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
                                    }
                                    if ($null -eq $($property.cmInstallDir) ) {
                                        $property | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value "C:\ConfigMgr"
                                    }
                                    if ($null -eq $($property.sqlInstanceDir) ) {
                                        $property | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "C:\SQL"
                                    }
                                    if ($null -eq $($property.siteCode) ) {
                                        $property | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value "PR2"
                                    }
                                    $property.Memory = "12GB"
                                    $property.operatingSystem = "Server 2022"
                                    Select-Options $($global:config.cmOptions) "Select ConfigMgr Property to modify"
                                }
                                


                                if (Get-TestResult -SuccessOnWarning) {
                                    return
                                }
                                else {
                                    if ($property."$name" -eq $value) {
                                        return
                                    }
                                }
                            }
                        }
                        "version" {
                            $valid = $false
                            while ($valid -eq $false) {
                                $property."$name" = Get-Menu "Select ConfigMgr Version" $($Common.Supported.CmVersions) $value
                                if (Get-TestResult -SuccessOnWarning) {
                                    return
                                }
                                else {
                                    if ($property."$name" -eq $value) {
                                        return
                                    }
                                }
                            }
                        }
                        "existingDCNameWithPrefix" {
                            $valid = $false
                            while ($valid -eq $false) {
                                $vms = Get-VM -ErrorAction SilentlyContinue | Select-Object -Expand Name
                                $property."$name" = Get-Menu "Select Existing DC" $vms $value
                                if (Get-TestResult -SuccessOnWarning) {
                                    return
                                }
                                else {
                                    if ($property."$name" -eq $value) {
                                        return
                                    }
                                }
                            }
                        }
                    }
                    if ($value -is [System.Management.Automation.PSCustomObject]) {
                        Select-Options $value "Select data to modify" | out-null
                    }
                    else {

                        $valid = $false
                        Write-Host
                        while ($valid -eq $false) {
                            if ($value -is [bool]) {
                                $response2 = Get-Menu -Prompt "Select new Value for $($_.Name)" -CurrentValue $value -OptionArray @("True", "False") 
                            }
                            else {
                                $response2 = Read-Host2 -Prompt "Select new Value for $($_.Name)" $value
                            }
                            if (-not [String]::IsNullOrWhiteSpace($response2)) {
                                if ($property."$($_.Name)" -is [Int]) {
                                    $property."$($_.Name)" = [Int]$response2
                                }
                                else {
                                    if ($value -is [bool]) {
                                        if ($([string]$value).ToLowerInvariant() -eq "true" -or $([string]$value).ToLowerInvariant() -eq "false") {
                                            if ($response2.ToLowerInvariant() -eq "true") {
                                                $response2 = $true
                                            }
                                            elseif ($response2.ToLowerInvariant() -eq "false") {
                                                $response2 = $false
                                            }
                                            else {
                                                $response2 = $value
                                            }
                                        }

                                    }
                                    $property."$($_.Name)" = $response2
                                }                                
                                $valid = Get-TestResult -SuccessOnWarning
                                if ($response2 -eq $value) {
                                    $valid = $true
                                }
                    
                            }
                            else {
                                # Enter was pressed. Set the Default value, and test, but dont block.
                                $property."$($_.Name)" = $value
                                $valid = Get-TestResult -SuccessOnError                                
                            }
                        }
                    }

                }

            }
        }
        else { 
            $valid = Get-TestResult -SuccessOnError
            return 
        }
    }
}

Function Get-TestResult {
    [CmdletBinding()]
    param (
        [Parameter()]
        [switch]
        $SuccessOnWarning,
        [Parameter()]
        [switch]
        $SuccessOnError,
        [Parameter()]
        [object]
        $config = $Global:Config
    )
    #If Config hasnt been generated yet.. Nothing to test
    if ($null -eq $config) {
        return $true
    }
    $c = Test-Configuration -InputObject $Config
    $valid = $c.Valid
    if ($valid -eq $false) {
        Write-Host -ForegroundColor Red $c.Message
    }
    if ($SuccessOnWarning.IsPresent) {
        if ( $c.Failures -eq 0) {
            $valid = $true
        }
    }
    if ($SuccessOnError.IsPresent) {
        $valid = $true
    }
    return $valid
}

function get-VMString {
    [CmdletBinding()]
    param (
        [Parameter()]
        [object]
        $virtualMachine
    )

    $machineName = $($($Global:Config.vmOptions.Prefix) + $($virtualMachine.vmName)).PadRight(15, " ")
    $name = "$machineName " + $("[" + $($virtualmachine.role) + "]").PadRight(15, " ")
    $mem = $($virtualMachine.memory).PadLEft(4, " ")
    $procs = $($virtualMachine.virtualProcs).ToString().PadLeft(2, " ")
    $name += "VM [$mem RAM,$procs CPU, $($virtualMachine.OperatingSystem)"

    if ($virtualMachine.additionalDisks) {
        $name += ", $($virtualMachine.additionalDisks.psobject.Properties.Value.count) Extra Disk(s)]"
    }
    else {
        $name += "]"
    }

    if ($virtualMachine.siteCode -and $virtualMachine.cmInstallDir) {
        $name += "`tCM [SiteCode $($virtualMachine.siteCode), "
        $name += "InstallDir $($virtualMachine.cmInstallDir)]"
    }

    if ($virtualMachine.siteCode -and -not $virtualMachine.cmInstallDir) {
        $name += "`tCM [SiteCode $($virtualMachine.siteCode)]"
    }

    if ($virtualMachine.sqlVersion -and -not $virtualMachine.sqlInstanceDir) {
        $name += "`tSQL [$($virtualMachine.sqlVersion)]"
    }

    if ($virtualMachine.sqlVersion -and $virtualMachine.sqlInstanceDir) {
        $name += "`tSQL [$($virtualMachine.sqlVersion), "
        $name += "SqlDir $($virtualMachine.sqlInstanceDir)]"
    }

    return $name
}

function Select-VirtualMachines {
    while ($true) {
        Write-Host ""
        $i = 0
        $valid = Get-TestResult -SuccessOnError
        foreach ($virtualMachine in $global:config.virtualMachines) {
            $i = $i + 1
            $name = Get-VMString $virtualMachine
            write-Option "$i" "$($name)"
        }
        write-Option -color DarkGreen -Color2 Green "N" "New Virtual Machine"
        $response = get-ValidResponse "Which VM do you want to modify" $i $null "n"
        Write-Log -HostOnly -Verbose "response = $response"
        if (-not [String]::IsNullOrWhiteSpace($response)) {
            if ($response.ToLowerInvariant() -eq "n") {
                $global:config.virtualMachines += [PSCustomObject]@{
                    vmName          = "Member" + $([int]$i + 1)
                    role            = "DomainMember"
                    operatingSystem = "Server 2022"
                    memory          = "2GB"
                    virtualProcs    = 2
                }
                $response = $i + 1
            }
            $i = 0
            foreach ($virtualMachine in $global:config.virtualMachines) {
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
                        if (([string]::IsNullOrEmpty($newValue))) {
                            break
                        }
                        if ($null -ne $newValue -and $newValue -is [string]) {
                            $newValue = [string]$newValue.Trim()
                            #Write-Host "NewValue = '$newValue'"
                            $newValue = [string]$newValue.ToUpper()
                        }
                        if (([string]::IsNullOrEmpty($newValue))) {
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
                        Get-TestResult -SuccessOnError | out-null
                    }
                }
            }
            if ($newValue -eq "D") {
                $newvm = $global:config.virtualMachines | ConvertTo-Json | ConvertFrom-Json
                $global:config.virtualMachines = @()
                $i = 0
                foreach ($virtualMachine in $newvm) {
                    $i = $i + 1
                    if ($i -ne $response) {
                        $global:config.virtualMachines += $virtualMachine
                    }
                }
            }



        }
        else {
            $valid = Get-TestResult -SuccessOnError
            return 
        }
    }
}

function Save-Config {
    [CmdletBinding()]
    param (
        [Parameter()]
        [object]
        $config
    )
    Write-Host

    $file = "$($config.vmOptions.prefix)$($config.vmOptions.domainName)"
    if ($config.vmOptions.existingDCNameWithPrefix) {
        $file += "-ADD"
    }
    elseif (-not $config.cmOptions) {
        $file += "-NOSCCM"
    }
    elseif ($Config.virtualMachines | Where-Object { $_.Role.ToLowerInvariant() -eq "cas" }) {
        $file += "-CAS-$($config.cmOptions.version)-"
    }
    elseif ($Config.virtualMachines | Where-Object { $_.Role.ToLowerInvariant() -eq "primary" }) {
        $file += "-PRI-$($config.cmOptions.version)-"
    }

    $file += "($($config.virtualMachines.Count)VMs)-"
    $date = Get-Date -Format "MM-dd-yyyy"
    $file += $date

    $filename = Join-Path $configDir $file

    $splitpath = Split-Path -Path $fileName -Leaf
    $response = Read-Host2 -Prompt "Save Filename" $splitpath

    if (-not [String]::IsNullOrWhiteSpace($response)) {
        $filename = Join-Path $configDir $response
    }

    if (!$filename.EndsWith("json")) {
        $filename += ".json"
    }

    $config | ConvertTo-Json -Depth 3 | Out-File $filename
    $return.ConfigFileName = Split-Path -Path $fileName -Leaf
    Write-Host "Saved to $filename"
    Write-Host
}
$Global:Config = $null
#$Global:Config = Select-Config $sampleDir
$Global:Config = Select-ConfigMenu
$Global:DeployConfig = (Test-Configuration -InputObject $Global:Config).DeployConfig
$Global:AddToExisting = $false
#if ($($deployConfig.parameters.existingDCName)) {
#    $Global:AddToExisting = $true
#}
$valid = $false
while ($valid -eq $false) {
    #Select-Options $($Global:Config.vmOptions) "Select Global Property to modify"
    #Select-Options $($Global:Config.cmOptions) "Select ConfigMgr Property to modify"
    #Select-VirtualMachines
    $valid = Select-MainMenu
    $c = Test-Configuration -InputObject $Config
    Write-Host

    if ($c.Valid) {
        $valid = $true
    }
    else {
        Write-Host -ForegroundColor Red "Config file is not valid: `r`n$($c.Message)"
        Write-Host -ForegroundColor Red "Please fix the problem(s), or hit CTRL-C to exit."
    }

    if ($valid) {
        Show-Summary ($c.DeployConfig)
        Write-Host
        Write-Host "Answering 'no' below will take you back to previous menus to allow you to correct mistakes"
        $response = Read-Host2 -Prompt "Everything correct? (Y/n)" -HideHelp
        if (-not [String]::IsNullOrWhiteSpace($response)) {
            if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                $valid = $false
            }           
        }
    }
}

#Show-Summary ($c.DeployConfig)
Save-Config $Global:Config
#Write-Host
#$date = Get-Date -Format "MM-dd-yyyy"
#if ($($Global:configfile.Name).StartsWith("xGen")) {
#    $postfix = $($Global:configfile.Name).SubString(16)
#    $filename = Join-Path $configDir "xGen-$date-$postfix"
#}
#else {
#    $filename = Join-Path $configDir "xGen-$date-$($Global:configfile.Name)"
#}
#$splitpath = Split-Path -Path $fileName -Leaf
#$response = Read-Host2 -Prompt "Save Filename" $splitpath
#if (-not [String]::IsNullOrWhiteSpace($response)) {
#    if (!$response.EndsWith("json")) {
#        $response += ".json"
#    }
#    $filename = Join-Path $configDir $response
#}
#$config | ConvertTo-Json -Depth 3 | Out-File $filename
#$return.ConfigFileName = Split-Path -Path $fileName -Leaf
#Write-Host "Saved to $filename"
#Write-Host

if (-not $InternalUseOnly.IsPresent) {
    Write-Host "You can deploy this configuration by running the following command:"
    Write-Host "$($PSScriptRoot)\New-Lab.ps1 -Configuration $($return.ConfigFileName)"
}


#================================= NEW LAB SCENERIO ============================================
if ($InternalUseOnly.IsPresent) {
    $response = Read-Host2 -Prompt "Deploy Now? (y/N)" $null
    if (-not [String]::IsNullOrWhiteSpace($response)) {
        if ($response.ToLowerInvariant() -eq "y") {
            Write-Host
            Write-Host "Deleting VM's will remove the existing VM's with the same names as the VM's we are deploying. Disks and all artifacts will be destroyed"
            $response = Read-Host2 -Prompt "Delete old VMs? (y/N)"
            if (-not [String]::IsNullOrWhiteSpace($response)) {
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

