[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Used when calling from New-Lab")]
    [Switch] $InternalUseOnly
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
        [Parameter(Mandatory = $true, HelpMessage = "Option to display. Eg 1")]
        [string] $option,
        [Parameter(Mandatory = $true, HelpMessage = "Description of the option")]
        [string] $text,
        [Parameter(Mandatory = $false, HelpMessage = "Description Color")]
        [object] $color,
        [Parameter(Mandatory = $false, HelpMessage = "Option Color")]
        [object] $color2
    )

    if ($null -eq $color) {
        $color = [System.ConsoleColor]::Gray
    }
    if ($null -eq $color2) {
        $color2 = [System.ConsoleColor]::White
    }
    write-host "[" -NoNewline
    Write-Host -ForegroundColor $color2 $option -NoNewline
    Write-Host "] ".PadRight(4 - $option.Length) -NoNewLine
    Write-Host -ForegroundColor $color "$text"

}
function Select-ConfigMenu {
    while ($true) {
        $customOptions = [ordered]@{ "1" = "Create New Domain"; "2" = "Expand Existing Domain"; "3" = "Load Sample Configuration";
            "4" = "Load saved config from File"; "R" = "Regenerate Rdcman file from Hyper-V config" ; "D" = "Delete an existing domain%Red%Yellow"; 
        }
        $response = Get-Menu -Prompt "Select menu option" -AdditionalOptions $customOptions
        #write-host
        #write-Verbose "1 response $response"
        if (-not $response) {
            continue
        }
        $SelectedConfig = $null
        switch ($response.ToLowerInvariant()) {
            "1" { $SelectedConfig = Select-NewDomainConfig }
            "2" { $SelectedConfig = Show-ExistingNetwork }
            "3" { $SelectedConfig = Select-Config $sampleDir -NoMore }
            "4" { $SelectedConfig = Select-Config $configDir -NoMore }
            "r" { New-RDCManFileFromHyperV $Global:Common.RdcManFilePath }
            "d" { Select-DeleteDomain }
            Default {}
        }
        if ($SelectedConfig) {
            return $SelectedConfig
        }

    }
}

function Select-DeleteDomain {

    $domainList = @()
    foreach ($item in (Get-DomainList)) {
        $stats = Get-DomainStatsLine -DomainName $item

        $domainList += "$($item.PadRight(22," ")) $stats"
    }

    $domainExpanded = Get-Menu -Prompt "Select existing domain" -OptionArray $domainList
    if ([string]::isnullorwhitespace($domainExpanded)) {
        return $null
    }
    $domain = ($domainExpanded -Split " ")[0]
    Write-Host
    Write-Verbose "2 Select-DeleteDomain"
    Write-Host "Domain contains these resources:"
    get-list -Type VM -DomainName $domain | Format-Table | Out-Host

    Write-Host "Selecting 'Yes' will permantently delete all VMs and scopes."
    $response = Read-Host2 -Prompt "Are you sure? (y/N)" -HideHelp
    if (-not [String]::IsNullOrWhiteSpace($response)) {
        if ($response.ToLowerInvariant() -eq "y" -or $response.ToLowerInvariant() -eq "yes") {
            & "$($PSScriptRoot)\Remove-Lab.ps1" -DomainName $domain
            Get-List -type VM -ResetCache | Out-Null
        }
    }
}


function get-VMOptionsSummary {

    $options = $Global:Config.vmOptions
    $domainName = "[$($options.domainName)]".PadRight(21)
    $Output = "$domainName [Prefix $($options.prefix)] [Network $($options.network)] [Username $($options.domainAdminName)] [Location [$($options.basePath)]"
    return $Output
}

function get-CMOptionsSummary {

    $options = $Global:Config.cmOptions
    $ver = "[$($options.version)]".PadRight(21)
    $Output = "$ver [Install $($options.install)] [Update $($options.updateToLatest)] [DPMP $($options.installDPMPRoles)] [Push Clients $($options.pushClientToDomainMembers)]"
    return $Output
}

function get-VMSummary {

    $vms = $Global:Config.virtualMachines

    $numVMs = ($vms | Measure-Object).Count
    $numDCs = ($vms | Where-Object { $_.Role -eq "DC" } | Measure-Object).Count
    $numDPMP = ($vms | Where-Object { $_.Role -eq "DPMP" } | Measure-Object).Count
    $numPri = ($vms | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count
    $numCas = ($vms | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
    $numMember = ($vms | Where-Object { $_.Role -eq "DomainMember" } | Measure-Object).Count

    $RoleList = ""
    if ($numDCs -gt 0 ) {
        $RoleList += "[DC]"
    }
    if ($numCas -gt 0 ) {
        $RoleList += "[CAS]"
    }
    if ($numPri -gt 0 ) {
        $RoleList += "[Primary]"
    }
    if ($numDPMP -gt 0 ) {
        $RoleList += "[DPMP]"
    }
    if ($numMember -gt 0 ) {
        $RoleList += "[$numMember Members]"
    }
    $num = "[$numVMs VM(s)]".PadRight(21)
    $Output = "$num $RoleList"
    return $Output
}

function Select-MainMenu {
    while ($true) {
        $customOptions = [ordered]@{}
        $customOptions += @{"1" = "Global VM Options `t`t $(get-VMOptionsSummary)" }
        if ($Global:Config.cmOptions) {
            $customOptions += @{"2" = "Global CM Options `t`t $(get-CMOptionsSummary)" }
        }
        $customOptions += @{"3" = "Virtual Machines `t`t $(get-VMSummary)" }
        $customOptions += @{ "S" = "Save and Exit" }
        if ($InternalUseOnly.IsPresent) {
            $customOptions += @{ "D" = "Deploy Config%Green%Green" }
        }
        
        $response = Get-Menu -Prompt "Select menu option" -AdditionalOptions $customOptions -Test:$false
        write-Verbose "response $response"
        if (-not $response) {
            continue
        }
        switch ($response.ToLowerInvariant()) {
            "1" { Select-Options $($Global:Config.vmOptions) "Select Global Property to modify" }
            "2" { Select-Options $($Global:Config.cmOptions) "Select ConfigMgr Property to modify" }
            "3" { Select-VirtualMachines }
            "d" { return $true }
            "s" { return $false }
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
            if ($subnetlist.Count -gt 2) {
                break
            }

        }
        
    }

    for ($i = 1; $i -lt 254; $i++) {
        $newSubnet = "172.16." + $i + ".0"
        $found = $false
        foreach ($subnet in (Get-SubnetList)) {
            if ($subnet.Subnet -eq $newSubnet) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            $subnetlist += $newSubnet
            if ($subnetlist.Count -gt 5) {
                break
            }

        }
    }

    for ($i = 1; $i -lt 254; $i++) {
        $newSubnet = "10.0." + $i + ".0"
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

function Get-NewMachineName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Role of the new machine")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "OS of the new machine")]
        [String] $OS,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )
    $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Measure-Object).Count
    $ConfigCount = ($config.virtualMachines | Where-Object { $_.Role -eq $Role } | Measure-Object).count
    Write-Verbose "[Get-NewMachineName] found $RoleCount machines in HyperV with role $Role"
    $RoleName = $Role
    if ($Role -eq "DomainMember" -or [string]::IsNullOrWhiteSpace($Role)) {
        $RoleName = "Member"

        if ($OS -like "*Server*") {            
            $RoleName = "Server"
            $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object ($_.deployedOS -like "*Server*") | Measure-Object).Count
            $ConfigCount = ($config.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object ($_.OperatingSystem -like "*Server*") | Measure-Object).count
        }
        else {
            $RoleName = "Client"
            $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object (-not ($_.deployedOS -like "*Server*")) | Measure-Object).Count
            $ConfigCount = ($config.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object (-not ($_.OperatingSystem -like "*Server*")) | Measure-Object).count
            if ($OS -like "Windows 10*") {
                $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object ($_.deployedOS -like "Windows 10*") | Measure-Object).Count
                $ConfigCount = ($config.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object ($_.OperatingSystem -like "Windows 10*") | Measure-Object).count
                $RoleName = "W10Client"
            }
            if ($OS -like "Windows 11*") {
                $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object ($_.deployedOS -like "Windows 11*") | Measure-Object).Count
                $ConfigCount = ($config.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object ($_.OperatingSystem -like "Windows 11*") | Measure-Object).count
                $RoleName = "W11Client"
            }
        }

        switch ($OS) {
            "Server 2022" { 
                $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object ($_.deployedOS -eq "Server 2022") | Measure-Object).Count
                $ConfigCount = ($config.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object ($_.OperatingSystem -eq "Server 2022") | Measure-Object).count
                $RoleName = "W22Server" 
            }
            "Server 2019" { 
                $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object ($_.deployedOS -eq "Server 2019") | Measure-Object).Count
                $ConfigCount = ($config.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object ($_.OperatingSystem -eq "Server 2019") | Measure-Object).count
                $RoleName = "W19Server" 
            }
            "Server 2016" { 
                $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object ($_.deployedOS -eq "Server 2016") | Measure-Object).Count
                $ConfigCount = ($config.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object ($_.OperatingSystem -eq "Server 2016") | Measure-Object).count
                $RoleName = "W16Server" 
            }
            Default {}
        }



    }

    if (($role -eq "Primary") -or ($role -eq "CAS")) {
        $newSiteCode = Get-NewSiteCode $Domain -Role $Role
        return $newSiteCode + "SITE"
    }

    if ($role -eq "DPMP") {
        $PSVM = $ConfigToCheck.VirtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1
        if ($PSVM -and $PSVM.SiteCode) {
            return $($PSVM.SiteCode) + $role
        }
    }

   
    Write-Verbose "[Get-NewMachineName] found $ConfigCount machines in Config with role $Role"
    $TotalCount = [int]$RoleCount + [int]$ConfigCount

    [int]$i = 1
    while ($true) {
        $NewName = $RoleName + ($TotalCount + $i)
        if ($null -eq $ConfigToCheck) {
            break
        }
        if (($ConfigToCheck.virtualMachines | Where-Object { $_.vmName -eq $NewName } | Measure-Object).Count -eq 0) {
            break
        }
        $i++
    }
    return $NewName

}


function Get-NewSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Role of the machine CAS/Primary")]
        [String] $Role
    )

    if ($Role -eq "CAS") {
        $NumberOfCAS = (Get-ExistingForDomain -DomainName $Domain -Role CAS | Measure-Object).Count
        #     if ($NumberOfCAS -eq 0) {
        #         return "CAS"
        #     }
        #else {
        return "CS" + ($NumberOfCAS + 1)
        #}
    }
    $NumberOfPrimaries = (Get-ExistingForDomain -DomainName $Domain -Role Primary | Measure-Object).Count
    #$NumberOfCas = (Get-ExistingForDomain -DomainName $Domain -Role CAS | Measure-Object).Count

    return "PS" + ($NumberOfPrimaries + 1)

}

function Select-NewDomainConfig {

    # Old List.. Some have netbios portions longer than 15 chars
    #$ValidDomainNames = [System.Collections.ArrayList]("adatum.com", "adventure-works.com", "alpineskihouse.com", "bellowscollege.com", "bestforyouorganics.com", "contoso.com", "contososuites.com",
    #   "consolidatedmessenger.com", "fabrikam.com", "fabrikamresidences.com", "firstupconsultants.com", "fourthcoffee.com", "graphicdesigninstitute.com", "humongousinsurance.com",
    #   "lamnahealthcare.com", "libertysdelightfulsinfulbakeryandcafe.com", "lucernepublishing.com", "margiestravel.com", "munsonspicklesandpreservesfarm.com", "nodpublishers.com",
    #   "northwindtraders.com", "proseware.com", "relecloud.com", "fineartschool.net", "southridgevideo.com", "tailspintoys.com", "tailwindtraders.com", "treyresearch.net", "thephone-company.com",
    #  "vanarsdelltd.com", "wideworldimporters.com", "wingtiptoys.com", "woodgrovebank.com", "techpreview.com" )

    #Trimmed list, only showing domains with 15 chars or less in netbios portion
    $ValidDomainNames = @{"adatum.com" = "ADA-" ; "adventure-works.com" = "ADV-" ; "alpineskihouse.com" = "ALP-" ; "bellowscollege.com" = "BLC-" ; "contoso.com" = "CON-" ; "contososuites.com" = "COS-" ;
        "fabrikam.com" = "FAB-" ; "fourthcoffee.com" = "FOR-" ;
        "lamnahealthcare.com" = "LAM-"  ; "margiestravel.com" = "MGT-" ; "nodpublishers.com" = "NOD-" ;
        "proseware.com" = "PRO-" ; "relecloud.com" = "REL-" ; "fineartschool.net" = "FAS-" ; "southridgevideo.com" = "SRV-" ; "tailspintoys.com" = "TST-" ; "tailwindtraders.com" = "TWT-" ; "treyresearch.net" = "TRY-";
        "vanarsdelltd.com" = "VAN-" ; "wingtiptoys.com" = "WTT-" ; "woodgrovebank.com" = "WGB-" ; "techpreview.com" = "TEC-"
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
    $customOptions = @{ "C" = "Custom Domain" }
    while (-not $domain) {
        $domain = Get-Menu -Prompt "Select Domain" -OptionArray $($ValidDomainNames.Keys | Sort-Object { $_.length }) -additionalOptions $customOptions
        if ($domain.ToLowerInvariant() -eq "c") {
            $domain = Read-Host2 -Prompt "Enter Custom Domain Name:"
        }
    }
    $prefix = $($ValidDomainNames[$domain])
    Write-Verbose "Prefix = $prefix"
    $subnetlist = Get-ValidSubnets

    $valid = $false
    while ($valid -eq $false) {
        $customOptions = @{ "C" = "Custom Subnet" }
        $network = $null
        while (-not $network) {
            $network = Get-Menu -Prompt "Select Network" -OptionArray $subnetlist -additionalOptions $customOptions
            if ($network.ToLowerInvariant() -eq "c") {
                $network = Read-Host2 -Prompt "Enter Custom Subnet (eg 192.168.1.0):"
            }
        }
        

        $customOptions = [ordered]@{ "1" = "CAS and Primary"; "2" = "Primary Site only"; "3" = "Tech Preview (NO CAS)" ; "4" = "No ConfigMgr"; }
        $response = $null
        while (-not $response) {
            $response = Get-Menu -Prompt "Select ConfigMgr Options" -AdditionalOptions $customOptions
        }

        $CASJson = Join-Path $sampleDir "Hierarchy.json"
        $PRIJson = Join-Path $sampleDir "Standalone.json"
        $NoCMJson = Join-Path $sampleDir "NoConfigMgr.json"
        $TPJson = Join-Path $sampleDir "TechPreview.json"
        switch ($response.ToLowerInvariant()) {
            "1" { $newConfig = Get-Content $CASJson -Force | ConvertFrom-Json }
            "2" { $newConfig = Get-Content $PRIJson -Force | ConvertFrom-Json }
            "3" {
                $newConfig = Get-Content $TPJson -Force | ConvertFrom-Json
                $usedPrefixes = Get-List -Type UniquePrefix
                if ("CTP-" -notin $usedPrefixes) {
                    $prefix = "CTP-"
                }
            }
            "4" { $newConfig = Get-Content $NoCMJson -Force | ConvertFrom-Json }
        }

        $newConfig.vmOptions.domainName = $domain
        $newConfig.vmOptions.network = $network
        $newConfig.vmOptions.prefix = $prefix
        $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
    }
    return $newConfig
}

# Gets the json files from the config\samples directory, and offers them up for selection.
# if 'M' is selected, shows the json files from the config directory.
function Select-Config {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Directory to look for .json files")]
        [string] $ConfigPath,
        # -NoMore switch will hide the [M] More options when we go into the submenu
        [Parameter(Mandatory = $false, HelpMessage = "will hide the [M] More options when we go into the submenu")]
        [switch] $NoMore
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
        Write-Verbose "3 Select-Config"
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
                if (-not ($null -eq $configSelected)) {
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

Function Get-DomainStatsLine {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName
    )
    $stats = ""
    $ExistingCasCount = (Get-List -Type VM -Domain $DomainName | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
    $ExistingPriCount = (Get-List -Type VM -Domain $DomainName | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count
    $ExistingDPMPCount = (Get-List -Type VM -Domain $DomainName | Where-Object { $_.Role -eq "DPMP" } | Measure-Object).Count
    $ExistingSubnetCount = (Get-List -Type VM -Domain $DomainName | Select-Object -Property Subnet -unique | measure-object).Count
    $TotalVMs = (Get-List -Type VM -Domain $DomainName  | Measure-Object).Count
    $TotalMem = (Get-List -Type VM -Domain $DomainName | Measure-Object -Sum MemoryGB).Sum
    $stats += "[$TotalVMs VMs, $($TotalMem.ToString().PadLeft(2," "))GB]"
    if ($ExistingCasCount -gt 0) {
        $stats += "[CAS VMs: $ExistingCasCount] "
    }
    if ($ExistingPriCount -gt 0) {
        $stats += "[Primary VMs: $ExistingCasCount] "
    }
    if ($ExistingDPMPCount -gt 0) {
        $stats += "[DPMP Vms: $ExistingCasCount] "
    }

    if ([string]::IsNullOrWhiteSpace($stats)) {
        $stats = "[No ConfigMgr Roles installed] "
    }

    if ($ExistingSubnetCount -gt 0) {
        $stats += "[Number of Networks: $ExistingSubnetCount] "
    }
    return $stats
}



function Show-ExistingNetwork {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
    $Global:AddToExisting = $true

    $domainList = @()

    foreach ($item in (Get-DomainList)) {
        $stats = Get-DomainStatsLine -DomainName $item

        $domainList += "$($item.PadRight(22," ")) $stats"
    }

    while ($true) {
        $domainExpanded = Get-Menu -Prompt "Select existing domain" -OptionArray $domainList
        if ([string]::isnullorwhitespace($domainExpanded)) {
            return $null
        }
        $domain = ($domainExpanded -Split " ")[0]

        get-list -Type VM -DomainName $domain | Format-Table | Out-Host

        $response = Read-Host2 -Prompt "Add new VMs to this domain? (Y/n)" -HideHelp
        if (-not [String]::IsNullOrWhiteSpace($response)) {
            if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                continue
            }
            else {
                break
            }
        }
        else { break }

    }
    [string]$role = Select-RolesForExisting

    if ($role -eq "Primary") {
        $ExistingCasCount = (Get-List -Type VM -Domain $domain | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
        if ($ExistingCasCount -gt 0) {

            $existingSiteCodes = @()
            $existingSiteCodes += (Get-List -Type VM -Domain $domain | Where-Object { $_.Role -eq "CAS" }).SiteCode
            #$existingSiteCodes += ($global:config.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Select-Object -First 1).SiteCode  
            
            $additionalOptions = @{ "X" = "No Parent - Standalone Primary" }
            $result = Get-Menu -Prompt "Select CAS sitecode to connect primary to:" -OptionArray $existingSiteCodes -CurrentValue $value -additionalOptions $additionalOptions -Test $false
            if ($result.ToLowerInvariant() -eq "x") {
                $ParentSiteCode = $null
            }
            else {
                $ParentSiteCode = $result
            }
            Get-TestResult -SuccessOnError | out-null
        }
    }
    [string]$subnet = $null
    $subnet = Select-ExistingSubnets -Domain $domain -Role $role
    Write-verbose "[Show-ExistingNetwork] Subnet returned from Select-ExistingSubnets '$subnet'"
    if ([string]::IsNullOrWhiteSpace($subnet)) {
        return $null
    }

    Write-verbose "[Show-ExistingNetwork] Calling Generate-ExistingConfig '$domain' '$subnet' '$role'"
    return Generate-ExistingConfig $domain $subnet $role -ParentSiteCode $ParentSiteCode
}
function Select-RolesForExisting {
    $existingRoles = $Common.Supported.RolesForExisting | Where-Object { $_ -ne "DPMP" }

    $existingRoles2 = @()

    foreach ($item in $existingRoles) {
        
        switch ($item) {
            "CAS" { $existingRoles2 += "CAS and Primary" }
            "DomainMember" {
                $existingRoles2 += "DomainMember (Server)"
                $existingRoles2 += "DomainMember (Client)"
            }
            Default { $existingRoles2 += $item }
        }        
    }


    $role = Get-Menu -Prompt "Select Role to Add" -OptionArray $($existingRoles2) -CurrentValue "DomainMember"

    if ($role -eq "CAS and Primary") {
        $role = "CAS"
    }

    return $role

}


function Select-RolesForNew {
    $existingRoles = $Common.Supported.Roles
    $role = Get-Menu -Prompt "Select Role to Add" -OptionArray $($existingRoles) -CurrentValue "DomainMember"
    return $role
}

function Select-ExistingSubnets {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Role")]
        [String] $Role
    )

    $valid = $false
    while ($valid -eq $false) {

        $customOptions = @{ "N" = "add New Subnet to domain" }
        $subnetList = @()
        $subnetList += Get-SubnetList -DomainName $Domain | Select-Object -Expand Subnet | Get-Unique

        $subnetListNew = @()
        if ($Role -eq "Primary" -or $Role -eq "CAS") {
            foreach ($subnet in $subnetList) {
                # If a subnet has a Primary or a CAS in it.. we can not add either.
                $existingRolePri = Get-ExistingForSubnet -Subnet $subnet -Role Primary
                $existingRoleCAS = Get-ExistingForSubnet -Subnet $subnet -Role CAS
                if ($null -eq $existingRolePri -and $null -eq $existingRoleCAS) {
                    $subnetListNew += $subnet
                }
            }
        }
        else {
            $subnetListNew = $subnetList
        }
        
        $subnetListModified = @()
        foreach ($sb in $subnetListNew) {
            $SiteCodes = get-list -Type VM -Domain $domain | Where-Object { $null -ne $_.SiteCode } | Group-Object -Property Subnet | Select-Object Name, @{l = "SiteCode"; e = { $_.Group.SiteCode -join "," } } | Where-Object { $_.Name -eq $sb } | Select-Object -expand SiteCode
            if ([string]::IsNullOrWhiteSpace($SiteCodes)) {
                $subnetListModified += "$sb"    
            }
            else {
                $subnetListModified += "$sb ($SiteCodes)"    
            }            
        }

        while ($true) {
            [string]$response = $null
            $response = Get-Menu -Prompt "Select existing subnet" -OptionArray $subnetListModified -AdditionalOptions $customOptions -test:$false
            write-Verbose "[Select-ExistingSubnets] Get-menu response $response"
            if ([string]::IsNullOrWhiteSpace($response)) {
                Write-Verbose "[Select-ExistingSubnets] Subnet response = null"                
            }
            write-Verbose "response $response"
            $response = $response -Split " " | Select-Object -First 1
            write-Verbose "Sanitized response '$response'"
       
            if ($response.ToLowerInvariant() -eq "n") {

                $subnetlist = Get-ValidSubnets
                $customOptions = @{ "C" = "Custom Subnet" }
                $network = $null
                while (-not $network) {
                    $network = Get-Menu -Prompt "Select Network" -OptionArray $subnetlist -additionalOptions $customOptions -Test:$false
                    if ($network.ToLowerInvariant() -eq "c") {
                        $network = Read-Host2 -Prompt "Enter Custom Subnet (eg 192.168.1.0):"
                    }
                }
                $response = [string]$network
                break

            }
            else {
                write-Verbose "Sanitized response was not 'N' it was '$response'"
                break
            }
        }
        $valid = Get-TestResult -Config (Generate-ExistingConfig -Domain $Domain -Subnet $response -Role $Role) -SuccessOnWarning
    }
    Write-Verbose "[Select-ExistingSubnets] Subnet response = $response"
    return [string]$response
}




function Generate-ExistingConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string] $Subnet,
        [Parameter(Mandatory = $true, HelpMessage = "Role")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "Parent Side code, if we are deploying a primary in a heirarchy")]
        [string] $ParentSiteCode = $null
    )

    Write-Verbose "Generating $Domain $Subnet $role $ParentSiteCode"

    $prefix = Get-List -Type UniquePrefix -Domain $Domain | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = "NULL-"
    }
    $vmOptions = [PSCustomObject]@{
        prefix          = $prefix
        basePath        = "E:\VirtualMachines"
        domainName      = $Domain
        domainAdminName = "admin"
        network         = $Subnet
    }

    $configGenerated = $null
    $configGenerated = [PSCustomObject]@{
        #cmOptions       = $newCmOptions
        vmOptions       = $vmOptions
        virtualMachines = $()
    }

    $configGenerated = Add-NewVMForRole -Role $Role -Domain $Domain -ConfigToModify $configGenerated -ParentSiteCode $ParentSiteCode

    Write-Verbose "Config: $configGenerated"
    return $configGenerated
}

# Replacement for Read-Host that offers a colorized prompt
function Read-Host2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "shows current value in []")]
        [string] $currentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Dont display the help before the prompt")]
        [switch] $HideHelp
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
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "Array of objects to display a menu from")]
        [object] $OptionArray,
        [Parameter(Mandatory = $false, HelpMessage = "The default if enter is pressed")]
        [string] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Additional Menu options, in dictionary format.. X = Exit")]
        [object] $additionalOptions = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Run a configuration test. Default True")]
        [bool] $Test = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Supress newline")]
        [switch] $NoNewLine
    )

    if (!$NoNewLine) {
        write-Host
        Write-Verbose "4 Get-Menu"
    }
    $i = 0

    foreach ($option in $OptionArray) {
        $i = $i + 1
        if (-not [String]::IsNullOrWhiteSpace($option)) {
            Write-Option $i $option
        }
    }

    if ($null -ne $additionalOptions) {
        $additionalOptions.keys | ForEach-Object {

            $color1 = "DarkGreen"
            $color2 = "Green"

            $value = $additionalOptions."$($_)"
            #Write-Host -ForegroundColor DarkGreen [$_] $value
            if (-not [String]::IsNullOrWhiteSpace($_)) {
                $TextValue = $value -split "%"
                
                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $color1 = $TextValue[1]
                }
                if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                    $color2 = $TextValue[2]
                }
                Write-Option $_ $TextValue[0] -color $color1 -Color2 $color2
            }
        }
    }

    $response = get-ValidResponse -Prompt $Prompt -max $i -CurrentValue $CurrentValue -AdditionalOptions $additionalOptions -TestBeforeReturn:$Test

    if (-not [String]::IsNullOrWhiteSpace($response)) {
        $i = 0
        foreach ($option in $OptionArray) {
            $i = $i + 1
            if ($i -eq $response) {
                Write-Verbose "[Get-Menu] Returned (O) '$option'"
                return $option
            }
        }
        Write-Verbose "[Get-Menu] Returned (R) '$response'"
        return $response
    }
    else {
        Write-Verbose "[Get-Menu] Returned (CV) '$CurrentValue'"
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
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $true, HelpMessage = "Max # to be valid.  If your Menu is 1-5, 5 is the max. Higher numbers will fail")]
        [int] $max,
        [Parameter(Mandatory = $false, HelpMessage = "Current value will be returned if enter is pressed")]
        [string] $currentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Extra Valid entries that allow escape.. EG X = Exit")]
        [object] $additionalOptions,
        [switch]
        $AnyString,
        [Parameter(Mandatory = $false, HelpMessage = "Run a test-Configuration before exiting")]
        [switch] $TestBeforeReturn

    )

    $responseValid = $false
    while ($responseValid -eq $false) {
        Write-Host
        Write-Verbose "5 get-ValidResponse"
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

Function Get-OperatingSystemMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $property."$name" = Get-Menu "Select OS Version" $($Common.Supported.OperatingSystems) $CurrentValue -Test:$false
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}


Function Get-ParentSideCodeMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $valid = $false
    while ($valid -eq $false) {
        $casSiteCodes = Get-ValidCASSiteCodes -config $global:config

        $additionalOptions = @{ "X" = "No Parent - Standalone Primary" }
        $result = Get-Menu -Prompt "Select CAS sitecode to connect primary to:" -OptionArray $casSiteCodes -CurrentValue $CurrentValue -additionalOptions $additionalOptions -Test:$false
        if ($result.ToLowerInvariant() -eq "x") {
            $property."$name" = $null
        }
        else {
            $property."$name" = $result
        }
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}

Function Get-SqlVersionMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $property."$name" = Get-Menu "Select SQL Version" $($Common.Supported.SqlVersions) $CurrentValue -Test:$false
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $CurrentValue) {
                return
            }
        }
    }
}

Function Get-CMVersionMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $property."$name" = Get-Menu "Select ConfigMgr Version" $($Common.Supported.CmVersions) $CurrentValue -Test:$false
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}
Function Get-RoleMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        if ($Global:AddToExisting -eq $true) {
            $role = Get-Menu "Select Role" $($Common.Supported.RolesForExisting) $CurrentValue -Test:$false
            $property."$name" = $role
        }
        else {
            $role = Get-Menu "Select Role" $($Common.Supported.Roles) $CurrentValue -Test:$false
            $property."$name" = $role
        }

        # If the value is the same.. Dont delete and re-create the VM
        if ($property."$name" -eq $value) {
            # return false if the VM object is still viable.
            return $false
        }

        # In order to make sure the default params like SQLVersion, CMVersion are correctly applied.  Delete the VM and re-create with the same name.
        Remove-VMFromConfig -vmName $property.vmName -ConfigToModify $global:config
        $global:config = Add-NewVMForRole -Role $Role -Domain $Global:Config.vmOptions.domainName -ConfigToModify $global:config -Name $property.vmName
        
        # We cant do anything with the test result, as our underlying object is no longer in config.
        Get-TestResult -config $global:config -SuccessOnWarning -NoNewLine | out-null
        
        # return true if the VM is deleted.
        return $true
    }
}

# Displays a Menu based on a property, offers options in [1], [2],[3] format
# With additional options passed in via additionalOptions
function Select-Options {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Property to Enumerate and automatically display a menu")]
        [object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "Append additional Items to menu.. Eg X = Exit")]
        [PSCustomObject] $additionalOptions,
        [Parameter(Mandatory = $false, HelpMessage = "Run a configuration test. Default True")]
        [bool] $Test = $true
    )

    :MainLoop   while ($true) {
        Write-Host
        Write-Verbose "6 Select-Options"
        $i = 0
        #Write-Host "Trying to get $property"
        if ($null -eq $property) {
            return $null
        }
        

        # Get the Property Names and Values.. Present as Options.
        $property | Get-Member -MemberType NoteProperty | ForEach-Object {
            $i = $i + 1
            $value = $property."$($_.Name)"
            #$padding = 27 - ($i.ToString().Length)
            $padding = 26
            Write-Option $i "$($($_.Name).PadRight($padding," "")) = $value"
        }

        if ($null -ne $additionalOptions) {
            $additionalOptions.keys | ForEach-Object {
                $value = $additionalOptions."$($_)"
                Write-Option $_ $value -color DarkGreen -Color2 Green
            }
        }

        $response = get-ValidResponse $prompt $i $null $additionalOptions
        if ([String]::IsNullOrWhiteSpace($response)) {   
            return      
        }
    
        $return = $null
        if ($null -ne $additionalOptions) {
            foreach ($item in $($additionalOptions.keys)) {
                if ($response.ToLowerInvariant() -eq $item.ToLowerInvariant()) {
                    # Return fails here for some reason. If the values were the same, let the user escape, as no changes were made.
                    $return = $item
                }
            }               
        }
        #Return here instead.
        if ($null -ne $return) {
            return $return
        }
        # We got the [1] Number pressed. Lets match that up to the actual value.
        $i = 0
        foreach ($item in ($property | Get-Member -MemberType NoteProperty)) {

            $i = $i + 1

            if (-not ($response -eq $i)) {
                continue
            }

            $value = $property."$($item.Name)"
            $name = $($item.Name)

            switch ($name) {
                "operatingSystem" {
                    Get-OperatingSystemMenu -property $property -name $name -CurrentValue $value
                    if ($property.role -eq "DomainMember") {
                        $property.vmName = Get-NewMachineName -Domain $Global:Config.vmOptions.DomainName -Role $property.role -OS $property.operatingSystem -ConfigToCheck $Global:Config
                    }
                    continue MainLoop
                }
                "ParentSiteCode" {
                    Get-ParentSideCodeMenu -property $property -name $name -CurrentValue $value
                    continue MainLoop
                }
                "sqlVersion" {
                    Get-SqlVersionMenu -property $property -name $name -CurrentValue $value
                    continue MainLoop
                }
                "role" {                           
                    if (Get-RoleMenu -property $property -name $name -CurrentValue $value) {
                        Write-Host -ForegroundColor Yellow "VirtualMachine object was re-created with new role. Taking you back to VM Menu."
                        # VM was deleted.. Lets get outta here.
                        return
                    }
                    else {
                        #VM was not deleted.. We can still edit other properties.
                        continue MainLoop
                    }
                }
                "version" {                          
                    Get-CMVersionMenu -property $property -name $name -CurrentValue $value
                    continue MainLoop
                }                     
            }
            # If the property is another PSCustomObject, recurse, and call this function again with the inner object.
            # This is currently only used for AdditionalDisks
            if ($value -is [System.Management.Automation.PSCustomObject]) {
                Select-Options $value "Select data to modify" | out-null
            }
            else {
                #The option was not a known name with its own menu, and it wasnt another PSCustomObject.. We can edit it directly.   
                $valid = $false
                Write-Host
                Write-Verbose "7 Select-Options"
                while ($valid -eq $false) {
                    if ($value -is [bool]) {
                        $response2 = Get-Menu -Prompt "Select new Value for $($Name)" -CurrentValue $value -OptionArray @("True", "False") -NoNewLine
                    }
                    else {
                        $response2 = Read-Host2 -Prompt "Select new Value for $($Name)" $value
                    }
                    if (-not [String]::IsNullOrWhiteSpace($response2)) {
                        if ($property."$($Name)" -is [Int]) {
                            $property."$($Name)" = [Int]$response2
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

                            Write-Verbose ("$_ name = $($_.Name) or $name = $response2")
                            $property."$($Name)" = $response2
                        }
                        if ($Test) {
                            $valid = Get-TestResult -SuccessOnWarning
                        }
                        else {
                            $valid = $true
                        }
                        if ($response2 -eq $value) {
                            $valid = $true
                        }

                    }
                    else {
                        # Enter was pressed. Set the Default value, and test, but dont block.
                        $property."$($Name)" = $value
                        $valid = Get-TestResult -SuccessOnError
                    }
                }
            }
        }     
    }
}

Function Get-TestResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Returns true even if warnings are present")]
        [switch] $SuccessOnWarning,
        [Parameter(Mandatory = $false, HelpMessage = "Returns true even if errors are present")]
        [switch] $SuccessOnError,
        [Parameter(Mandatory = $false, HelpMessage = "Config to check")]
        [object] $config = $Global:Config,
        [Parameter(Mandatory = $false, HelpMessage = "Supress newline")]
        [switch] $NoNewLine
    )
    #If Config hasnt been generated yet.. Nothing to test
    if ($null -eq $config) {
        return $true
    }
    $c = Test-Configuration -InputObject $Config
    $valid = $c.Valid
    if ($valid -eq $false) {
        Write-Host -ForegroundColor Red "`r`n$($c.Message)"
        if (!$NoNewLine) {
            write-host
        }
        # $MyInvocation | Out-Host

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
        [Parameter(Mandatory = $true, HelpMessage = "VirtualMachine Object from config")]
        [object] $virtualMachine
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
        $SiteCode = $virtualMachine.siteCode
        if ($virtualMachine.ParentSiteCode) {
            $SiteCode += "->$($virtualMachine.ParentSiteCode)"
        }
        $name += "  CM [SiteCode $SiteCode ($($virtualMachine.cmInstallDir))]"
    }

    if ($virtualMachine.siteCode -and -not $virtualMachine.cmInstallDir) {
        $SiteCode = $virtualMachine.siteCode
        if ($virtualMachine.ParentSiteCode) {
            $SiteCode += "->$($virtualMachine.ParentSiteCode)"
        }
        $name += "  CM [SiteCode $SiteCode]"
    }

    if ($virtualMachine.sqlVersion -and -not $virtualMachine.sqlInstanceDir) {
        $name += "  SQL [$($virtualMachine.sqlVersion)]"
    }

    if ($virtualMachine.sqlVersion -and $virtualMachine.sqlInstanceDir) {
        $name += "  SQL [$($virtualMachine.sqlVersion), "
        $name += "$($virtualMachine.sqlInstanceName) ($($virtualMachine.sqlInstanceDir))]"
    }

    return $name
}

function Add-NewVMForRole {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Role")]
        [String] $Role,
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "Force VM Name. Otherwise auto-generated")]
        [string] $Name = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Parent Side Code if this is a Primary in a Heirarchy")]
        [string] $ParentSiteCode = $null
    )

    Write-Verbose "[Add-NewVMForRole] Start Role: $Role Domain: $Domain Config: $ConfigToModify"
   

    $virtualMachine = [PSCustomObject]@{
        vmName          = $null
        role            = ($Role -split " ")[0]
        operatingSystem = "Server 2022"
        memory          = "2GB"
        virtualProcs    = 2
    }
    $existingPrimary = $null
    $existingDPMP = $null
    switch ($Role) {
        "CAS" {
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "C:\SQL"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value "E:\ConfigMgr"
            $disk = [PSCustomObject]@{"E" = "250GB"; "F" = "100GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
            $newSiteCode = Get-NewSiteCode $Domain -Role $role
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $newSiteCode
            $virtualMachine.Memory = "12GB"
            $virtualMachine.operatingSystem = "Server 2022"
            $existingPrimary = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count          
            
        }
        "Primary" {
            $existingCAS = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
            if ([string]::IsNullOrWhiteSpace($ParentSiteCode)) {
                $ParentSiteCode = $null
                if ($existingCAS -eq 1) {
                    $ParentSiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Select-Object -First 1).SiteCode                
                }
            }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'ParentSiteCode' -Value $ParentSiteCode
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "F:\SQL"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value "E:\ConfigMgr"
            $disk = [PSCustomObject]@{"E" = "250GB"; "F" = "100GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
            $newSiteCode = Get-NewSiteCode $Domain -Role $role
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $newSiteCode
            $virtualMachine.Memory = "12GB"
            $virtualMachine.operatingSystem = "Server 2022"
            $existingDPMP = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "DPMP" } | Measure-Object).Count            
            
        }
        "DomainMember" { }
        "DomainMember (Server)" { }
        "DomainMember (Client)" {
            $virtualMachine.operatingSystem = "Windows 10 Latest (64-bit)"
        }
        "DPMP" {
            $virtualMachine.memory = "3GB"
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
        }
        "DC" { }
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $machineName = Get-NewMachineName $Domain ($Role -split " ")[0] -OS $virtualMachine.OperatingSystem
        Write-Verbose "Machine Name Generated $machineName"
    }
    else {
        $machineName = $Name
    }
    $virtualMachine.vmName = $machineName

    if ($null -eq $ConfigToModify.VirtualMachines) {
        $ConfigToModify.virtualMachines = @()
    }

    $ConfigToModify.virtualMachines += $virtualMachine

    if ($role -eq "Primary" -or $role -eq "CAS") {
        if ($null -eq $ConfigToModify.cmOptions) {
            $newCmOptions = [PSCustomObject]@{
                version                   = "current-branch"
                install                   = $true
                updateToLatest            = $false
                installDPMPRoles          = $true
                pushClientToDomainMembers = $true
            }
            $ConfigToModify | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $newCmOptions
        }
    }

    if ($existingPrimary -eq 0) {
        $ConfigToModify = Add-NewVMForRole -Role Primary -Domain $Domain -ConfigToModify $ConfigToModify -Op
    }

    if ($existingPrimary -gt 0) {
        ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).ParentSiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Select-Object -First 1).SiteCode
    }

    if ($existingDPMP -eq 0) {
        $ConfigToModify = Add-NewVMForRole -Role DPMP -Domain $Domain -ConfigToModify $ConfigToModify
    }

    Write-verbose "[Add-NewVMForRole] Config: $ConfigToModify"
    return $ConfigToModify
}


function Select-VirtualMachines {
    while ($true) {
        Write-Host
        Write-Verbose "8 Select-VirtualMachines"
        $i = 0
        #$valid = Get-TestResult -SuccessOnError
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
                $role = Select-RolesForNew
                $global:config = Add-NewVMForRole -Role $Role -Domain $Global:Config.vmOptions.domainName -ConfigToModify $global:config
                Get-TestResult -SuccessOnError | out-null               
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
                        }
                        else {
                            $customOptions["R"] = "Remove Last Additional Disk"
                        }
                        if ($null -eq $virtualMachine.sqlVersion) {
                            $customOptions["S"] = "Add SQL"
                        }
                        else {
                            $customOptions["X"] = "Remove SQL"
                        }
                        $customOptions["D"] = "Delete this VM"
                        $newValue = Select-Options $virtualMachine "Which VM property to modify" $customOptions -Test:$false
                        if (([string]::IsNullOrEmpty($newValue))) {
                            break
                        }
                        if ($newValue -eq "DELETED") {
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
                            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"
                        }
                        if ($newValue -eq "X") {
                            $virtualMachine.psobject.properties.remove('sqlversion')
                            $virtualMachine.psobject.properties.remove('sqlInstanceDir')
                            $virtualMachine.psobject.properties.remove('sqlInstanceName')
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
                        if (-not ($newValue -eq "D")) {
                            Get-TestResult -SuccessOnError | out-null
                        }
                    }
                }
            }
            if ($newValue -eq "D") {                
                $i = 0
                foreach ($virtualMachine in $global:config.virtualMachines) {
                    $i = $i + 1
                    if ($i -eq $response) {
                        Remove-VMFromConfig -vmName $virtualMachine.vmName -ConfigToModify $global:config
                    }
                }
            }
        }
        else {
            Get-TestResult -SuccessOnError | Out-Null
            return
        }
    }
}

function Remove-VMFromConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Name of VM to remove.")]
        [string] $vmName,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [object] $configToModify = $global:config
    )
    $DeletedVM = $null
    $newvm = $configToModify.virtualMachines | ConvertTo-Json | ConvertFrom-Json
    $configToModify.virtualMachines = @()
    foreach ($virtualMachine in $newvm) {

        if ($virtualMachine.vmName -ne $vmName) {
            $configToModify.virtualMachines += $virtualMachine
        }
        else {
            $DeletedVM = $virtualMachine
        }
    }
    if ($DeletedVM.Role -eq "CAS") {
        $primaryParentSideCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).ParentSiteCode
        if ($primaryParentSideCode -eq $DeletedVM.SiteCode) {
            ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).ParentSiteCode = $null
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
    Write-Verbose "9 Save-Config"

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
    $response = Read-Host2 -Prompt "Save Filename" $splitpath -HideHelp

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
    Write-Verbose "11"
}
$Global:Config = $null
$Global:Config = Select-ConfigMenu
$Global:DeployConfig = (Test-Configuration -InputObject $Global:Config).DeployConfig
$Global:AddToExisting = $false
$existingDCName = $deployConfig.parameters.existingDCName
if (-not [string]::IsNullOrWhiteSpace($existingDCName)) {
    $Global:AddToExisting = $true
}
$valid = $false
while ($valid -eq $false) {

    $return.DeployNow = Select-MainMenu
    $c = Test-Configuration -InputObject $Config
    Write-Host
    Write-Verbose "12"

    if ($c.Valid) {
        $valid = $true
    }
    else {
        Write-Host -ForegroundColor Red "Config file is not valid: `r`n$($c.Message)`r`n"
        Write-Host -ForegroundColor Red "Please fix the problem(s), or hit CTRL-C to exit."
    }

    if ($valid) {
        Show-Summary ($c.DeployConfig)
        Write-Host
        Write-verbose "13"
        Write-Host "Answering 'no' below will take you back to the previous menu to allow you to make modifications"
        $response = Read-Host2 -Prompt "Everything correct? (Y/n)" -HideHelp
        if (-not [String]::IsNullOrWhiteSpace($response)) {
            if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                $valid = $false
            }
        }
    }
}

Save-Config $Global:Config

if (-not $InternalUseOnly.IsPresent) {
    Write-Host "You can deploy this configuration by running the following command:"
    Write-Host "$($PSScriptRoot)\New-Lab.ps1 -Configuration $($return.ConfigFileName)"
}

#================================= NEW LAB SCENERIO ============================================
if ($InternalUseOnly.IsPresent) {
 
    return $return
}

