# Common.GenConfig.Existing.ps1
# Helpers used by genconfig.ps1 when working with existing networks,
# subnets, role lists, and existing/sample configs:
#   - domain stats / existing-network rendering
#   - role list builders (existing vs new)
#   - subnet selection helpers
#   - enhanced network / subnet list builders
#   - Select-ExistingSubnets / New-UserConfig / Get-ExistingConfig

Function Get-DomainStatsLine {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName
    )

    $stats = ""
    try {
        $ListCache = Get-List -Type VM -Domain $DomainName
        $ExistingCasCount = ($ListCache | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
        $ExistingPriCount = ($ListCache | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count
        $ExistingSecCount = ($ListCache | Where-Object { $_.Role -eq "Secondary" } | Measure-Object).Count
        #$ExistingDPMPCount = ($ListCache | Where-Object { $_.installDP -or $_.enablePullDP } | Measure-Object).Count
        $ExistingSQLCount = ($ListCache | Where-Object { $_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion } | Measure-Object).Count
        $ExistingSubnetCount = ($ListCache | Select-Object -Property Network -unique | measure-object).Count
        $TotalVMs = ($ListCache | Measure-Object).Count
        $TotalRunningVMs = ($ListCache | Where-Object { $_.State -ne "Off" } | Measure-Object).Count
        $TotalMem = [math]::Round(($ListCache | Measure-Object -Sum MemoryGB).Sum)
        $TotalMaxMem = [math]::Round(($ListCache | Measure-Object -Sum MemoryStartupGB).Sum)
        $TotalDiskUsed = [math]::Round(($ListCache | Measure-Object -Sum DiskUsedGB).Sum)

        $stats += "[$($TotalRunningVMs.ToString().PadLeft(2," "))/$($TotalVMs.ToString().PadLeft(2," ")) Running VMs, Mem: $($TotalMem.ToString().PadLeft(2," "))GB/$($TotalMaxMem)GB Disk: $([math]::Round($TotalDiskUsed,2))GB]"
        if ($ExistingCasCount -gt 0) {
            $stats += "[CAS VMs: $ExistingCasCount] "
        }
        if ($ExistingPriCount -gt 0) {
            $stats += "[PRI VMs: $ExistingPriCount] "
        }
        if ($ExistingSecCount -gt 0) {
            $stats += "[SEC VMs: $ExistingSecCount] "
        }
        if ($ExistingSQLCount -gt 0) {
            $stats += "[SQL VMs: $ExistingSQLCount] "
        }
        #if ($ExistingDPMPCount -gt 0) {
        #    $stats += "[DP VMs: $ExistingDPMPCount] "
        #}

        if ([string]::IsNullOrWhiteSpace($stats)) {
            $stats = "[No ConfigMgr Roles installed] "
        }

        if ($ExistingSubnetCount -gt 0) {
            $stats += "[Number of Networks: $ExistingSubnetCount] "
        }
    }
    catch {}
    return $stats
}

function Show-ExistingNetwork2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string]$DomainName = $null,
        [switch]$NewDomain
    )

    if ([string]::IsNullOrWhiteSpace($DomainName)) {

        $domainList = @()

        foreach ($item in (Get-DomainList)) {
            $stats = Get-DomainStatsLine -DomainName $item

            $domainList += "$($item.PadRight(22," ")) $stats"
        }

        if ($domainList.Count -eq 0) {
            return Select-NewDomainConfig
        }

        while ($true) {

            Write-log -Activity "Create new domain -or- modify existing domain"
            $customOptions = [ordered]@{ "*HF" = "Get-DomainHelpLine" }
            $customOptions += [ordered]@{"*B1" = ""; "*BREAK1" = "New Domain Wizard%$($Global:Common.Colors.GenConfigHeader)" }
            $customOptions += [ordered]@{ "N" = "Create New Domain%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)" }
            $customOptions += [ordered]@{ "HN" = "Use this option to configure and deploy a new domain.  You can have as many domains as you want!" }
            $customOptions += [ordered]@{"*B" = ""; "*BREAK" = "Modify Existing Domains%$($Global:Common.Colors.GenConfigHeader)" }
            $i = 0
            foreach ($domain in $domainList) {
                $i++
                $customOptions += [ordered]@{ "$i" = "$domain%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
                $domainshort = $domain -Split " " | Select-Object -First 1
                $customOptions += [ordered]@{ "H$i" = "Add additional VM's or change some settings in $domainshort" }

            }

            $response = Get-Menu2 -MenuName "Create new domain -or- modify existing domain" -Prompt "Select Existing Domain or select 'N' to create a new domain" -additionalOptions $customOptions -Split -test:$false -CurrentValue "N" -NoNewLine
            if ($response.ToLowerInvariant() -eq "!" -or $response.ToLowerInvariant() -eq "escape") {
                return
            }
            if ([string]::IsNullOrWhiteSpace($response) -or $response.ToLowerInvariant() -eq "n") {
                $result = Select-NewDomainConfig
                if ($result -eq "ESCAPE") {
                    continue
                }
                else {
                    return $result
                }
            }       

            $i = 0
            foreach ($domain in $domainList) {
                $i++
                if ($i -eq $response) {    
                    $domain = $domain -Split " " | Select-Object -First 1     
                    Write-Verbose "Setting Response to $domain"     
                    $response = $domain
                }
            }
            $list = get-list -Type VM -DomainName $response
            if ($list) {
                Write-Log -Activity "Modify $response"
                #get-list -Type VM -DomainName $response | Format-Table -Property vmname, Role, SiteCode, DeployedOS, MemoryStartupGB, @{Label = "DiskUsedGB"; Expression = { [Math]::Round($_.DiskUsedGB, 2) } }, State, Domain, Network, SQLVersion | Out-Host
            }
            else {
                Write-RedX "Could not find domain $response"
                start-sleep -seconds 5
                continue
            }
            $domain = $response

            break
            #$response = Read-YesOrNoWithTimeout -Prompt "Modify existing VMs, or Add new VMs to this domain? (Y/n)" -HideHelp -Default "y"
            #if (-not [String]::IsNullOrWhiteSpace($response)) {
            #    if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
            #        continue
            #    }
            #    else {
            #        break
            #    }
            #}
            #else { break }

        }
    }
    else {
        $domain = $DomainName
    }

    $TotalStoppedVMs = (Get-List -Type VM -Domain $domain | Where-Object { $_.State -ne "Running" -and ($_.Role -eq "CAS" -or $_.Role -eq "Primary" -or $_.Role -eq "DC") } | Measure-Object).Count
    if ($TotalStoppedVMs -gt 0) {
        $response = Read-YesOrNoWithTimeout -Prompt "$TotalStoppedVMs Critical VM's in this domain are not running. Do you wish to start them now? (Y/n)" -HideHelp -Default "y"
        if ($response -and ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no")) {
        }
        else {
            Select-StartDomain -domain $domain -response "C"
        }

    }

    [string]$subnet = (Get-List -type VM -DomainName $domain | Where-Object { $_.Role -eq "DC" } | Select-Object -First 1).network
    if (-not $subnet) {
        #if ($role -ne "InternetClient" -and $role -ne "AADClient" -and $role -ne "PassiveSite") {
        $subnet = Select-ExistingSubnets -Domain $domain -Role $role -SiteCode $SiteCode
        Write-verbose "[Show-ExistingNetwork] Subnet returned from Select-ExistingSubnets '$subnet'"
        if ([string]::IsNullOrWhiteSpace($subnet)) {
            return $null
        }
    }

    Write-verbose "[Show-ExistingNetwork] Calling Get-ExistingConfig '$domain' '$subnet' '$role' '$SiteCode'"
    $newConfig = Get-ExistingConfig -Domain $domain -Subnet $subnet -role $role -parentSiteCode $parentSiteCode -SiteCode $Sitecode
    return $newConfig
}

function Select-RolesForExistingList {
    $existingRoles = $Common.Supported.RolesForExisting | Where-Object { $_ -ne "PassiveSite" }
    return $existingRoles
}

function Select-RolesForNewList {
    $Roles = $Common.Supported.Roles | Where-Object { $_ -ne "PassiveSite" }
    return $Roles
}

function Format-Roles {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Roles Array")]
        [object]$Roles
    )

    $newRoles = @()

    $padding = 22
    foreach ($role in $Roles) {
        switch ($role) {
            "DC" { $newRoles += "$($role.PadRight($padding))`t[New Domain Controller.. Only 1 allowed per domain!]" }
            "BDC" { $newRoles += "$($role.PadRight($padding))`t[Backup Domain Controllers.  As many as you want per domain]" }
            "CAS" { $newRoles += "$($role.PadRight($padding))`t[New CAS.. Only 1 allowed per subnet!]" }
            "CAS and Primary" { $newRoles += "$($role.PadRight($padding))`t[New CAS and Primary Site]" }
            "Primary" { $newRoles += "$($role.PadRight($padding))`t[New Primary site (Standalone or join a CAS)]" }
            "Secondary" { $newRoles += "$($role.PadRight($padding))`t[New Secondary site (Attach to Primary)]" }
            "FileServer" { $newRoles += "$($role.PadRight($padding))`t[New File Server]" }
            "SiteSystem" { $newRoles += "$($role.PadRight($padding))`t[New Site System for a Site. Can be MP/DP/PullDP/SUP or Reporting Point]" }
            "DomainMember" { $newRoles += "$($role.PadRight($padding))`t[New VM joined to the domain. Can be a standalone SQL server on server OS]" }
            "SQLAO" { $newRoles += "$($role.PadRight($padding))`t[SQL High Availability Always On Cluster]" }
            "DomainMember (Server)" { $newRoles += "$($role.PadRight($padding))`t[New VM with Server OS joined to the domain. Can be a SQL Server]" }
            "DomainMember (Client)" { $newRoles += "$($role.PadRight($padding))`t[New VM with Client OS joined to the domain]" }
            "SqlServer" { $newRoles += "$($role.PadRight($padding))`t[New VM with Server OS and SQL that is joined to the domain.]" }
            "WorkgroupMember" { $newRoles += "$($role.PadRight($padding))`t[New VM in workgroup with Internet Access]" }
            "InternetClient" { $newRoles += "$($role.PadRight($padding))`t[New VM in workgroup with Internet Access, isolated from the domain]" }
            "AADClient" { $newRoles += "$($role.PadRight($padding))`t[New VM that boots to OOBE, allowing AAD join from OOBE]" }
            "OSDClient" { $newRoles += "$($role.PadRight($padding))`t[New bare VM without any OS]" }
            "WSUS" { $newRoles += "$($role.PadRight($padding))`t[Standalone WSUS Server]" }
            "StandaloneRootCA" { $newRoles += "$($role.PadRight($padding))`t[Offline Root CA for two-tier PKI (workgroup, powered off after setup)]" }
            default { $newRoles += $role }
        }
    }

    return $newRoles

}

function Select-RolesForExisting {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Enhance Roles")]
        [bool]$enhance = $true
    )
    $existing = get-list -type vm -domain $global:config.vmOptions.domainName | Where-Object { $_.Role -eq "DC" }
    if ($existing) {
        $existingRoles = Select-RolesForExistingList | Where-Object { $_ -ne "DC" }
        $ha_Text = "Enable High Availability (HA) on an Existing Site Server"
    }
    else {        
        $existingRoles = Select-RolesForNewList
        $ha_Text = "Enable High Availability (HA) on a Site Server"
    }

    $DC = $global:config.VirtualMachines | Where-Object { $_.Role -eq "DC" } 
    if ($DC) {
        $existingRoles = Select-RolesForExistingList | Where-Object { $_ -ne "DC" }
    }
    $existingRoles2 = @()
    $CurrentValue = $null
    if ($enhance) {
        $CurrentValue = "DomainMember"
        foreach ($item in $existingRoles) {

            switch ($item) {
                "CAS" { $existingRoles2 += "CAS and Primary" }
                "DomainMember" {
                    $existingRoles2 += "DomainMember (Client)"
                    $existingRoles2 += "DomainMember (Server)"                    
                    $existingRoles2 += "Sqlserver"
                }
                "PassiveSite" {}
                Default { $existingRoles2 += $item }
            }
        }
    }
    else {
        $existingRoles2 = $existingRoles
    }
    $existingRoles2 = Format-Roles $existingRoles2

    $OptionArray = @{ "H" = $ha_Text }
    $OptionArray += @{  "L" = "Add Linux VM from Hyper-V Gallery" }
    $role = Get-Menu2 -MenuName "Add a VM to the domain - Role Selection" -Prompt "Select Role to Add" -OptionArray $($existingRoles2) -CurrentValue $CurrentValue -additionalOptions $OptionArray -test:$false

    if ($role -eq "ESCAPE") {
        return
    }
    $role = $role.Split("[")[0].Trim()
    if ($role -eq "CAS and Primary") {
        $role = "CAS"
    }

    return $role

}


function Select-Subnet {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $configToCheck = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "CurrentNetworkIsValid")]
        [bool] $CurrentNetworkIsValid = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Current VM")]
        [object] $CurrentVM = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Current Value")]
        [object] $CurrentValue = $null
    )


    #Get-PSCallStack | out-host
    if (-not $configToCheck -or $configToCheck.virtualMachines.role -contains "DC") {
        if ($CurrentNetworkIsValid) {
            if ($CurrentVM) {
                $subnetlist = Get-ValidSubnets -ConfigToCheck $configToCheck -vmToCheck $CurrentVM
            }
            else {
                $subnetlist = Get-ValidSubnets
            }
        }
        else {
            if ($CurrentVM) {
                $subnetlist = Get-ValidSubnets -ConfigToCheck $configToCheck -vmToCheck $CurrentVM
            }
            else {
                $subnetlist = Get-ValidSubnets -ConfigToCheck $configToCheck -AllowExisting:$false
            }
        }
        $customOptions = @{ 
            "C"  = "Custom Subnet"
            "HC" = "You can select a custom network. Must be a /24 (eg 10.10.10.0)"
        }
        $network = $null
        if (-not $CurrentValue) {
            if ($CurrentNetworkIsValid) {
                $current = $configToCheck.vmOptions.network
            }
            else {
                $subnetList = $subnetList | where-object { $_ -ne $configToCheck.vmOptions.network }
                $current = $subnetlist[0]
            }
        }
        else {
            $current = $CurrentValue
        }
        while (-not $network) {
            $subnetlistEnhanced = Get-EnhancedSubnetList -subnetList $subnetlist -ConfigToCheck $configToCheck

            $menuName = "Select Subnet use C for custom"
            if ($CurrentVM) {
                if ($CurrentVM.VmName) {
                    $menuName = "Select Subnet for $($CurrentVM.VmName); use C for custom"
                }
                else {
                    if ($CurrentVM.Role) {
                        $menuName = "Select Subnet for New VM with role $($CurrentVM.Role); use C for custom"
                    }
                }

            }
            $network = Get-Menu2 -MenuName $menuName -Prompt "Select Network" -OptionArray $subnetlistEnhanced -additionalOptions $customOptions -Test:$false -CurrentValue $current -Split
            if ($network -and ($network.ToLowerInvariant() -eq "c")) {
                $network = Read-Host2 -Prompt "Enter Custom Subnet (eg 192.168.1.0):"
            }
            if ($network -eq "ESCAPE") {
                if ($current) {
                    write-log -verbose "Returning Current network $current"
                    $network = $current
                }
                else {
                    return
                }
            }
        }
        $response = [string]$network
        write-log -verbose "Returning network $response"
        return $response
    }
    else {
        $domain = $configToCheck.vmOptions.DomainName
        return Select-ExistingSubnets -Domain $domain -ConfigToCheck $configToCheck -CurrentNetworkIsValid:$CurrentNetworkIsValid -CurrentVM $CurrentVM
    }



}

function Show-SubnetNote {
    #  $noteColor = $Global:Common.Colors.GenConfigTip
    $textColor = $Global:Common.Colors.GenConfigHelp
    #  $highlightColor = $Global:Common.Colors.GenConfigHelpHighlight
    #Get-PSCallStack | out-host

    #write-host2 -ForegroundColor $noteColor "Note: " -NoNewline
    #write-host2 -foregroundcolor $textColor "You can only have 1 " -NoNewLine
    #write-host2 -ForegroundColor $highlightColor "Primary" -NoNewLine
    #write-host2 -ForegroundColor $textColor " or " -NoNewline
    #write-host2 -ForegroundColor $highlightColor "Secondary" -NoNewLine
    #write-host2 -ForegroundColor $textColor " server per " -NoNewline
    #write-host2 -ForegroundColor $highlightColor "subnet" -NoNewline

    write-host2 -ForegroundColor $textColor "   MemLabs automatically configures this subnet as a Boundary Group for the specified SiteCode."
    write-host2 -ForegroundColor $textColor "   This limitation exists to prevent overlapping Boundary Groups."
    write-host2 -ForegroundColor $textColor "   Subnets without a siteserver do NOT automatically get added to any boundary groups."

}

function Get-EnhancedNetworkList {
    [CmdletBinding()]
    param (

    )
    $subnetList += Get-NetworkList | Select-Object -Expand Network | Sort-Object -Property { [System.Version]$_ } | Get-Unique
    $FullList = get-list -Type VM

    $rolesToShow = @("Primary", "CAS", "Secondary")

    $ListData = $fullList | Where-Object { $null -ne $_.SiteCode -and ($_.Role -in $rolesToShow ) } | Group-Object -Property network | Select-Object Name, @{l = "SiteCode"; e = { $_.Group.SiteCode -join "," } }

    $returnSubnetList = @()

    foreach ($sb in $SubnetList) {


        $subnet = [PSCustomObject]@{
            Network = $sb
        }


        if ($sb -eq "Internet" -or ($sb -eq "cluster")) {
            $returnSubnetList += $subnet
            continue
        }

        $SiteCodes = $ListData | Where-Object { $_.Name -eq $sb } | Select-Object -expand SiteCode

        $domainFromSubnet = (((Get-List -type network | Where-Object { $_.network -eq $sb }).domain) -join ",")
        if ($domainFromSubnet) {
            $subnet | Add-Member -MemberType NoteProperty -Name "Domain" -Value $domainFromSubnet -Force
        }


        if (-not [string]::IsNullOrWhiteSpace($SiteCodes)) {
            $subnet | Add-Member -MemberType NoteProperty -Name "SiteCodes" -Value "$($SiteCodes -join ", ")" -Force
        }

        $machines = @()
        $machines += $FullList | Where-Object { $_.Network -eq $sb }


        if ($machines) {
            $subnet | Add-Member -MemberType NoteProperty -Name "Virtual Machines" -Value $($machines.vmName -join ", ") -Force
        }
        $returnSubnetList += $subnet
    }

    return $returnSubnetList
}

function Get-EnhancedSubnetList {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Subnet List")]
        [String[]] $SubnetList,
        [Parameter(Mandatory = $false, HelpMessage = "config object. Overrides -domain")]
        [object] $ConfigToCheck,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [String] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "padding")]
        [object] $Padding = 20
    )

    $subnetListModified = @()
    $rolesToShow = @("Primary", "CAS", "Secondary")

    if ($configToCheck) {
        $FullList = get-list2 -deployConfig $ConfigToCheck
        $domain = $ConfigToCheck.vmoptions.DomainName
    }
    else {
        if ($domain) {
            $FullList = get-list -Type VM -Domain $domain
        }
        else {
            $FullList = get-list -Type VM
        }
    }

    $ListData = $fullList | Where-Object { $null -ne $_.SiteCode -and ($_.Role -in $rolesToShow ) } | Group-Object -Property network | Select-Object Name, @{l = "SiteCode"; e = { $_.Group.SiteCode -join "," } }


    foreach ($sb in $SubnetList) {
        if ($sb -eq "Internet" -or ($sb -eq "cluster")) {
            $subnetListModified += $sb
            continue
        }

        $entry = ""
        $SiteCodes = $ListData | Where-Object { $_.Name -eq $sb } | Select-Object -expand SiteCode


        if (-not $domain) {
            $domainFromSubnet = (((Get-List -type network | Where-Object { $_.network -eq $sb }).domain) -join ",")
            if ($domainFromSubnet) {
                $entry += " [$domainFromSubnet]"
            }
        }

        if ([string]::IsNullOrWhiteSpace($SiteCodes)) {
            #$subnetListModified += "$sb"
            #$validEntryFound = $true
        }
        else {
            if ($SiteCodes) {
                $entry = $entry + " [$($SiteCodes -join ",")]"
            }
            #$subnetListModified += "$($sb.PadRight($padding))$($SiteCodes -join ",")"
        }
        $machines = @()
        $machines += $FullList | Where-Object { $_.Network -eq $sb }

        if ($ConfigToCheck) {
            if ($ConfigToCheck.vmOptions.Network -eq $sb) {
                $entry = $entry + " <Current Default Network>"
            }
        }
        if ($machines) {
            if ($machines.vmName) {
                $entry = $entry + " [$($machines.vmName -join ", ")]"
                $MaxWidth = ($host.UI.RawUI.WindowSize.Width - 58)
                if ($entry.Length -ge $MaxWidth) {
                    $entry = $entry.Substring(0, $MaxWidth - 3) + "..."
                }
            }
        }
        if ($entry) {
            $subnetListModified += "$($sb.PadRight($padding))$entry"
        }
        else {
            $subnetListModified += $sb
        }
    }

    return $subnetListModified
}

function Get-ValidNetworksForVM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Current VM")]
        [object] $CurrentVM,
        [Parameter(Mandatory = $true, HelpMessage = "config")]
        [object] $ConfigToCheck

    )

    $Domain = $ConfigToCheck.vmOptions.DomainName
    #All Existing Subnets
    $subnetList = @()
    $subnetList += Get-NetworkList -DomainName $Domain | Select-Object -Expand Network | Sort-Object | Get-Unique

    foreach ($vm in $configToCheck.virtualMachines) {
        if ($vm.Network) {
            $subnetList += $vm.Network
        }
    }
    $subnetList += $ConfigToCheck.vmOptions.network

    $subnetList = $subnetList | Sort-Object -Property { [System.Version]$_ } | Get-Unique

    $rolesToCheck = @("Primary", "CAS", "Secondary")

    if ($CurrentVM.Role -notin $rolesToCheck) {
        Write-Verbose "Current VM $($CurrentVm.Role) returning all subnets"
        return $subnetList
    }


    $vmList = Get-List2 -DeployConfig $ConfigToCheck

    $currentVMNetwork = $CurrentVM.network
    if (-not $currentVMNetwork) {
        $currentVMNetwork = $configToCheck.vmOptions.network
    }
    $return = @()

    foreach ($subnet in $subnetList) {
        $found = $false
        foreach ($vm in $vmList | Where-Object { $_.Network -eq $subnet }) {
            if ($found) {
                continue
            }
            if ($vm.vmName -eq $currentVM.VmName) {
                continue
            }
            switch ($vm.Role) {
                "Primary" {
                    if ($CurrentVM.Role -eq "CAS" -and $vm.ParentSiteCode -eq $CurrentVM.SiteCode) {
                        continue
                    }
                    else {
                        $found = $true
                    }

                }
                "CAS" {
                    if ($CurrentVM.Role -eq "Primary" -and $vm.SiteCode -eq $CurrentVM.ParentSiteCode) {
                        continue
                    }
                    else {
                        $found = $true
                    }

                }
                "Secondary" {
                    $found = $true

                }
                Default {

                }
            }
        }
        if (-not $found) {
            $return += $subnet
        }
    }


    return $return

}
function Select-ExistingSubnets {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $false, HelpMessage = "Role")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [String] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "config")]
        [object] $ConfigToCheck,
        [Parameter(Mandatory = $false, HelpMessage = "Is the default network a valid choice?")]
        [bool] $CurrentNetworkIsValid = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Current VM")]
        [object] $CurrentVM = $null
    )

    $valid = $false
    if ($ConfigToCheck) {
        $Role = "DomainMember"
        if ($configToCheck.virtualMachines.role -contains "Primary") {
            $Role = "Primary"
        }
        if ($configToCheck.virtualMachines.role -contains "CAS") {
            $Role = "CAS"
        }
        if ($configToCheck.virtualMachines.role -contains "Secondary") {
            $Role = "Secondary"
        }
    }

    if ($CurrentVM.Role) {
        $Role = $currentVM.Role
    }

    $rolesToCheck = @("Primary", "CAS", "Secondary")
    while ($valid -eq $false) {
        $customOptions = @{ "N" = "add New Subnet to domain" }
        $subnetList = @()
        $subnetList += Get-NetworkList -DomainName $Domain | Select-Object -Expand Network | Sort-Object | Get-Unique
        if ($ConfigToCheck) {
            foreach ($vm in $configToCheck.virtualMachines) {
                if ($vm.Network) {
                    $subnetList += $vm.Network
                }
            }
            $subnetList += $ConfigToCheck.vmOptions.network
        }

        #if ($CurrentNetworkIsValid -and $configToCheck) {
        #    $subnetList += $ConfigToCheck.vmOptions.network
        #}
        $subnetListNew = @()
        if ($Role -in $rolesToCheck) {
            $SiteServerRole = $true
            foreach ($subnet in $subnetList) {
                # If a subnet has a Primary or a CAS in it.. we can not add either.
                $existingRolePri = Get-ExistingForNetwork -Network $subnet -Role Primary -config $configToCheck
                $existingRoleCAS = Get-ExistingForNetwork -Network $subnet -Role CAS -config $configToCheck
                $existingRoleSec = Get-ExistingForNetwork -Network $subnet -Role Secondary -config $configToCheck
                if ($null -eq $existingRolePri -and $null -eq $existingRoleCAS -and $null -eq $existingRoleSec) {
                    $subnetListNew += $subnet
                }
            }
        }
        else {
            $subnetListNew = $subnetList
        }

        $subnetListNew = $subnetListNew | Sort-Object -Property { [System.Version]$_ } | Get-Unique

        if ($currentVM -and $configToCheck) {
            $subnetListNew = Get-ValidNetworksForVM -CurrentVM $currentVM -ConfigToCheck $ConfigToCheck
        }
        if ($configToCheck) {
            $subnetListModified = Get-EnhancedSubnetList -subnetList $subnetListNew -ConfigToCheck $ConfigToCheck
        }
        else {
            $subnetListModified = Get-EnhancedSubnetList -subnetList $subnetListNew  -Domain $domain
        }

        Show-SubnetNote

        while ($true) {
            [string]$response = $null

            $CurrentValue = $null
            if ($configToCheck) {
                $Currentvalue = $configToCheck.vmOptions.network
            }
            if ($subnetListModified.Length -eq 0) {
                Write-Host
                Write-Host2 -ForegroundColor Goldenrod "No valid subnets for the selected role exists in the domain. Please create a new subnet"

                $response = "n"
            }
            else {
                Write-Log -Activity -NoNewLine "Select a network"
                if ($CurrentNetworkIsValid) {
                    $response = Get-Menu -Prompt "Select existing network" -OptionArray $subnetListModified -AdditionalOptions $customOptions -test:$false -CurrentValue $CurrentValue -Split
                }
                else {
                    $response = Get-Menu -Prompt "Select existing network" -OptionArray $subnetListModified -AdditionalOptions $customOptions -test:$false -Split
                }
            }
            write-Verbose "[Select-ExistingSubnets] Get-menu response $response"
            if ([string]::IsNullOrWhiteSpace($response)) {
                Write-Verbose "[Select-ExistingSubnets] Subnet response = null"
                continue
            }
            write-Verbose "response $response"

            if ($response -and ($response.ToLowerInvariant() -eq "n")) {
                if ($SiteServerRole -and $ConfigToCheck) {
                    if ($currentVM) {
                        $subnetList = Get-ValidSubnets -configToCheck $ConfigToCheck -excludeList $subnetList -vmToCheck $currentVM
                    }
                    else {
                        $subnetList = Get-ValidSubnets -configToCheck $ConfigToCheck -excludeList $subnetList
                    }
                }
                else {
                    $subnetlist = Get-ValidSubnets
                }
                $customOptions = @{ "C" = "Custom Subnet" }
                $network = $null
                while (-not $network) {
                    if ($ConfigToCheck) {
                        $subnetlistEnhanced = Get-EnhancedSubnetList -subnetList $subnetList -ConfigToCheck $configToCheck
                    }
                    else {
                        $subnetlistEnhanced = Get-EnhancedSubnetList -subnetList $subnetList -Domain $domain
                    }
                    Write-Log -Activity -NoNewLine "New Network menu"
                    $network = Get-Menu -Prompt "Select New Network" -OptionArray $subnetlistEnhanced -additionalOptions $customOptions -Test:$false -CurrentValue $($subnetList | Select-Object -First 1) -Split
                    if ($network -and ($network.ToLowerInvariant() -eq "c")) {
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
        $valid = $true
        #$valid = Get-TestResult -Config (Get-ExistingConfig -Domain $Domain -Subnet $response -Role $Role -SiteCode $sitecode -test:$true) -SuccessOnWarning
    }
    Write-Verbose "[Select-ExistingSubnets] Subnet response = $response"
    return [string]$response
}


function New-UserConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Subnet Name")]
        [string] $Subnet
    )

    $DC = Get-List -Type VM -DomainName $Domain | Where-Object { $_.Role -eq "DC" }

    $adminUser = $DC.adminName

    $domainDefaults = $DC.domainDefaults

    if ([string]::IsNullOrWhiteSpace($adminUser)) {
        $adminUser = "admin"
    }
    $prefix = get-PrefixForDomain -Domain $Domain
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = "NULL-"
    }
    $netbiosName = $Domain.Split(".")[0]
    $vmOptions = [PSCustomObject]@{
        prefix            = $prefix
        basePath          = "E:\VirtualMachines"
        domainName        = $Domain
        domainNetBiosName = $netbiosName
        adminName         = $adminUser
        network           = $Subnet
    }
    Write-Verbose "[Get-ExistingConfig] vmOptions: $vmOptions"

    $configGenerated = $null
    $configGenerated = [PSCustomObject]@{
        #cmOptions       = $newCmOptions
        vmOptions       = $vmOptions
        virtualMachines = $()

    }

    if ($domainDefaults) {
        $configGenerated | Add-Member -MemberType NoteProperty -Name "domainDefaults" -Value $domainDefaults -force
    }
    return $configGenerated
}
function Get-ExistingConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Subnet Name")]
        [string] $Subnet,
        [Parameter(Mandatory = $false, HelpMessage = "Role")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "Parent Site code, if we are deploying a primary in a Hierarchy")]
        [string] $parentSiteCode = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Site code, if we are deploying PassiveSite")]
        [string] $SiteCode = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Site code, if we are deploying PassiveSite")]
        [bool] $test = $false

    )

    Write-Verbose "[Get-ExistingConfig] Generating $Domain $Subnet $role $parentSiteCode"

    $configGenerated = New-UserConfig -Domain $Domain -Subnet $Subnet


    Write-Verbose "[Get-ExistingConfig] Config: $configGenerated $($configGenerated.vmOptions.domainName)"
    if ($Role) {
        Add-NewVMForRole -Role $Role -Domain $Domain -ConfigToModify $configGenerated -parentSiteCode $parentSiteCode -SiteCode $SiteCode -Quiet:$true -test:$test
    }
    Write-Verbose "[Get-ExistingConfig] Config: $configGenerated"
    return $configGenerated
}
