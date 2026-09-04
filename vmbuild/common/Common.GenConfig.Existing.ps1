# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
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
        $ListCache = Get-List -Type VM -Domain $DomainName -SmartUpdate
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

        # ANSI color codes for value highlighting
        $esc = [char]27
        $cBracket = "$esc[38;2;105;105;105m"   # DimGray - brackets
        $cLabel   = "$esc[38;2;176;196;222m"   # LightSteelBlue - labels
        $cValue   = "$esc[38;2;0;206;209m"     # DarkTurquoise - numeric values
        $cWarn    = "$esc[38;2;255;255;0m"     # Yellow - partial anomaly
        $cBad     = "$esc[38;2;255;69;0m"      # OrangeRed - zero/down
        $cReset   = "$esc[0m"

        # Conditional color for running VM count
        if ($TotalRunningVMs -eq 0) {
            $cRunning = $cBad
        }
        elseif ($TotalRunningVMs -lt $TotalVMs) {
            $cRunning = $cWarn
        }
        else {
            $cRunning = $cValue
        }

        # Available width for the stats portion.
        # Menu overhead: 3 (arrow) + 5 ([N]  ) + 22 (domain pad) + 1 (space) = 31
        # Extra margin for scrollbar/padding/cursor that reported width doesn't account for.
        $termWidth = try { [Console]::WindowWidth } catch { 0 }
        if ($termWidth -le 0) { $termWidth = $host.UI.RawUI.WindowSize.Width }
        if ($termWidth -le 0) { $termWidth = 120 }
        $maxWidth = $termWidth - 40

        # Build parts with both plain (for measuring) and colorized versions
        $corePlain = "[$($TotalRunningVMs.ToString().PadLeft(2))/$($TotalVMs.ToString().PadLeft(2)) Running VMs, Mem: $($TotalMem.ToString().PadLeft(2))GB/${TotalMaxMem}GB Disk: $([math]::Round($TotalDiskUsed,2))GB]"
        $coreColor = "${cBracket}[${cRunning}$($TotalRunningVMs.ToString().PadLeft(2))${cLabel}/${cValue}$($TotalVMs.ToString().PadLeft(2)) ${cLabel}Running VMs, Mem: ${cValue}$($TotalMem.ToString().PadLeft(2))${cLabel}GB/${cValue}${TotalMaxMem}${cLabel}GB Disk: ${cValue}$([math]::Round($TotalDiskUsed,2))${cLabel}GB${cBracket}]${cReset}"

        $rolePlain = @()
        $roleColor = @()
        if ($ExistingCasCount -gt 0) {
            $rolePlain += "[CAS VMs: $ExistingCasCount]"
            $roleColor += "${cBracket}[${cLabel}CAS VMs: ${cValue}$ExistingCasCount${cBracket}]${cReset}"
        }
        if ($ExistingPriCount -gt 0) {
            $rolePlain += "[PRI VMs: $ExistingPriCount]"
            $roleColor += "${cBracket}[${cLabel}PRI VMs: ${cValue}$ExistingPriCount${cBracket}]${cReset}"
        }
        if ($ExistingSecCount -gt 0) {
            $rolePlain += "[SEC VMs: $ExistingSecCount]"
            $roleColor += "${cBracket}[${cLabel}SEC VMs: ${cValue}$ExistingSecCount${cBracket}]${cReset}"
        }
        if ($ExistingSQLCount -gt 0) {
            $rolePlain += "[SQL VMs: $ExistingSQLCount]"
            $roleColor += "${cBracket}[${cLabel}SQL VMs: ${cValue}$ExistingSQLCount${cBracket}]${cReset}"
        }

        $networkPlain = ""
        $networkColor = ""
        if ($ExistingSubnetCount -gt 0) {
            $networkPlain = "[Networks: $ExistingSubnetCount]"
            $networkColor = "${cBracket}[${cLabel}Networks: ${cValue}$ExistingSubnetCount${cBracket}]${cReset}"
        }

        # Assemble with truncation - add parts only if they fit
        $plainLen = $corePlain.Length
        $stats = $coreColor

        for ($i = 0; $i -lt $rolePlain.Count; $i++) {
            if ($plainLen + 1 + $rolePlain[$i].Length -le $maxWidth) {
                $stats += " $($roleColor[$i])"
                $plainLen += 1 + $rolePlain[$i].Length
            }
            else { break }
        }

        if ($networkPlain -and ($plainLen + 1 + $networkPlain.Length -le $maxWidth)) {
            $stats += " $networkColor"
        }

        if ([string]::IsNullOrWhiteSpace($stats)) {
            $stats = "${cBracket}[${cLabel}No ConfigMgr Roles installed${cBracket}]${cReset}"
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

        # Regex pattern to strip ANSI CSI sequences (using literal ESC char)
        $ansiPattern = [char]27 + '\[[0-9;]*m'
        $domainNames = Get-DomainList

        if (-not $domainNames -or $domainNames.Count -eq 0) {
            return Select-NewDomainConfig
        }

        while ($true) {

            # Recalculate terminal width and domain list on each iteration
            # so resizing the window takes effect immediately.
            $termWidth = try { [Console]::WindowWidth } catch { 0 }
            if ($termWidth -le 0) { $termWidth = $host.UI.RawUI.WindowSize.Width }
            if ($termWidth -le 0) { $termWidth = 120 }
            $lineMaxWidth = $termWidth - 14

            $domainList = @()
            foreach ($item in $domainNames) {
                $stats = Get-DomainStatsLine -DomainName $item

                $line = "$($item.PadRight(22," ")) $stats"
                # Measure visible width by stripping ANSI escape sequences
                $plainLine = [regex]::Replace($line, $ansiPattern, '')
                if ($plainLine.Length -gt $lineMaxWidth) {
                    # Too wide - strip trailing [...] segments until it fits
                    while ($plainLine.Length -gt $lineMaxWidth) {
                        $lastBracket = $plainLine.LastIndexOf(' [')
                        if ($lastBracket -le 23) { break }
                        $plainLine = $plainLine.Substring(0, $lastBracket)
                    }
                    # Truncate the ANSI-colored line to match the same visible length
                    $targetLen = $plainLine.Length
                    $visCount = 0
                    $cutIdx = $line.Length
                    $inEsc = $false
                    for ($ci = 0; $ci -lt $line.Length; $ci++) {
                        if ($line[$ci] -eq [char]27) { $inEsc = $true }
                        if ($inEsc) {
                            if ($line[$ci] -eq 'm') { $inEsc = $false }
                            continue
                        }
                        $visCount++
                        if ($visCount -ge $targetLen) {
                            $cutIdx = $ci + 1
                            break
                        }
                    }
                    $line = $line.Substring(0, $cutIdx) + "$([char]27)[0m"
                }
                $domainList += $line
            }

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
                $customOptions += [ordered]@{ "H$i" = "Add additional VMs or change some settings in $domainshort" }

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
        $response = Read-YesOrNoWithTimeout -Prompt "$TotalStoppedVMs Critical VMs in this domain are not running. Do you wish to start them now? (Y/n)" -HideHelp -Default "y"
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
            "DC" { $newRoles += "$($role.PadRight($padding)) [New Domain Controller.. Only 1 allowed per domain!]" }
            "BDC" { $newRoles += "$($role.PadRight($padding)) [Backup Domain Controllers.  As many as you want per domain]" }
            "CAS" { $newRoles += "$($role.PadRight($padding)) [New CAS.. Only 1 allowed per subnet!]" }
            "CAS and Primary" { $newRoles += "$($role.PadRight($padding)) [New CAS and Primary Site]" }
            "Primary" { $newRoles += "$($role.PadRight($padding)) [New Primary site (Standalone or join a CAS)]" }
            "Secondary" { $newRoles += "$($role.PadRight($padding)) [New Secondary site (Attach to Primary)]" }
            "FileServer" { $newRoles += "$($role.PadRight($padding)) [New File Server]" }
            "SiteSystem" { $newRoles += "$($role.PadRight($padding)) [New Site System for a Site. Can be MP/DP/PullDP/SUP or Reporting Point]" }
            "DomainMember" { $newRoles += "$($role.PadRight($padding)) [New VM joined to the domain. Can be a standalone SQL server on server OS]" }
            "SQLAO" { $newRoles += "$($role.PadRight($padding)) [SQL High Availability Always On Cluster]" }
            "DomainMember (Server)" { $newRoles += "$($role.PadRight($padding)) [New VM with Server OS joined to the domain. Can be a SQL Server]" }
            "DomainMember (Client)" { $newRoles += "$($role.PadRight($padding)) [New VM with Client OS joined to the domain]" }
            "SqlServer" { $newRoles += "$($role.PadRight($padding)) [New VM with Server OS and SQL that is joined to the domain.]" }
            "WorkgroupMember" { $newRoles += "$($role.PadRight($padding)) [New VM in workgroup with Internet Access]" }
            "InternetClient" { $newRoles += "$($role.PadRight($padding)) [New VM in workgroup with Internet Access, isolated from the domain]" }
            "AADClient" { $newRoles += "$($role.PadRight($padding)) [New VM that boots to OOBE, allowing AAD join from OOBE]" }
            "OSDClient" { $newRoles += "$($role.PadRight($padding)) [New bare VM without any OS]" }
            "WSUS" { $newRoles += "$($role.PadRight($padding)) [Standalone WSUS Server]" }
            "StandaloneRootCA" { $newRoles += "$($role.PadRight($padding)) [Offline Root CA for two-tier PKI (workgroup, powered off after setup)]" }
            "Proxy" { $newRoles += "$($role.PadRight($padding)) [Linux Squid forward proxy (1 per domain, Ubuntu Server 24.04)]" }
            "LinuxServer" { $newRoles += "$($role.PadRight($padding)) [Generic Ubuntu Server 24.04 VM (DHCP, optional domain join)]" }
            "LinuxClient" { $newRoles += "$($role.PadRight($padding)) [Ubuntu Desktop 24.04 workstation for MDM/EDR testing (GNOME, xrdp, optional domain join)]" }
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

    # Only one Proxy is allowed per domain (config + existing combined).
    $proxyInConfig = @($global:config.VirtualMachines | Where-Object { $_.Role -eq "Proxy" }).Count -gt 0
    $proxyInDomain = $false
    if (-not $proxyInConfig -and $global:config.vmOptions.domainName) {
        try {
            $proxyInDomain = @(Get-List -Type VM -DomainName $global:config.vmOptions.domainName -ErrorAction SilentlyContinue |
                    Where-Object { $_.Role -eq "Proxy" }).Count -gt 0
        }
        catch { $proxyInDomain = $false }
    }
    if ($proxyInConfig -or $proxyInDomain) {
        $existingRoles = $existingRoles | Where-Object { $_ -ne "Proxy" }
    }

    $existingRoles2 = @()
    if ($enhance) {
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

    # Group roles into sections so the picker has visual headers. Order within
    # each group is preserved from $existingRoles2 (case-insensitive match).
    $roleGroups = @(
        @{ Name = "Domain Members"        ; Roles = @("DomainMember (Client)", "DomainMember (Server)") }
        @{ Name = "SQL Servers"           ; Roles = @("SqlServer", "SQLAO") }
        @{ Name = "Workgroup / Isolated"  ; Roles = @("WorkgroupMember", "InternetClient", "AADClient", "OSDClient", "LinuxClient") }
        @{ Name = "Configuration Manager" ; Roles = @("CAS", "CAS and Primary", "Primary", "Secondary", "SiteSystem") }
        @{ Name = "Infrastructure"        ; Roles = @("DC", "BDC", "FileServer", "WSUS", "StandaloneRootCA", "Proxy", "LinuxServer") }
    )

    # Build an ordered list of roles bucketed by group, plus an "Other" bucket
    # for anything not explicitly classified (defensive against new roles).
    $orderedRoles = @()
    $orderedGroupForRole = @{}
    $remaining = [System.Collections.ArrayList]@($existingRoles2)
    foreach ($group in $roleGroups) {
        foreach ($role in $group.Roles) {
            $match = $remaining | Where-Object { $_ -ieq $role } | Select-Object -First 1
            if ($match) {
                $orderedRoles += $match
                $orderedGroupForRole[$match] = $group.Name
                $remaining.Remove($match) | Out-Null
            }
        }
    }
    foreach ($leftover in $remaining) {
        $orderedRoles += $leftover
        $orderedGroupForRole[$leftover] = "Other"
    }

    # Format role labels (adds the [description] suffix used by Get-Menu2).
    $orderedRolesFormatted = Format-Roles $orderedRoles

    # Pre-build menuItems with *B header rows interleaved between groups.
    $menuItems = [System.Collections.ArrayList]@()
    $currentGroup = $null
    $headerIndex = 0
    for ($i = 0; $i -lt $orderedRoles.Count; $i++) {
        $role = $orderedRoles[$i]
        $formatted = $orderedRolesFormatted[$i]
        $group = $orderedGroupForRole[$role]
        if ($group -ne $currentGroup) {
            $headerIndex++
            $null = New-MenuItem -MenuItems ([ref]$menuItems) -ItemName "*B$headerIndex" `
                -Text "$group%$($Global:Common.Colors.GenConfigHeader)"
            $currentGroup = $group
        }
        $itemNumber = $i + 1
        $null = New-MenuItem -MenuItems ([ref]$menuItems) -ItemName "$itemNumber" `
            -Text $formatted -Selectable `
            -Color1 $Global:Common.Colors.GenConfigNormal `
            -Color2 $Global:Common.Colors.GenConfigDefaultNumber
    }

    # Default selection: first selectable item (matches prior behavior, since
    # CurrentValue="DomainMember" never matched the "(Client)/(Server)" labels).
    $firstSelectable = $menuItems | Where-Object { $_.Selectable } | Select-Object -First 1
    if ($firstSelectable) { $firstSelectable.Selected = $true }

    $OptionArray = @{ "H" = $ha_Text }
    $role = Get-Menu2 -MenuName "Add a VM to the domain - Role Selection" -Prompt "Select Role to Add" -OptionArray $($orderedRolesFormatted) -menuItems $menuItems -additionalOptions $OptionArray -test:$false

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


        if ($sb -eq "Internet" -or ($sb -eq "cluster") -or ($sb -eq "ClusterV2")) {
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
        if ($sb -eq "Internet" -or ($sb -eq "cluster") -or ($sb -eq "ClusterV2")) {
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
                    $response = Get-Menu2 -MenuName "Existing Network Selection" -Prompt "Select existing network" -OptionArray $subnetListModified -AdditionalOptions $customOptions -test:$false -CurrentValue $CurrentValue -Split
                }
                else {
                    $response = Get-Menu2 -MenuName "Existing Network Selection" -Prompt "Select existing network" -OptionArray $subnetListModified -AdditionalOptions $customOptions -test:$false -Split
                }
            }
            write-Verbose "[Select-ExistingSubnets] Get-menu response $response"
            if ([string]::IsNullOrWhiteSpace($response)) {
                Write-Verbose "[Select-ExistingSubnets] Subnet response = null"
                continue
            }
            if ($response -eq "ESCAPE") {
                return $null
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
                    $network = Get-Menu2 -MenuName "New Network Selection" -Prompt "Select New Network" -OptionArray $subnetlistEnhanced -additionalOptions $customOptions -Test:$false -CurrentValue $($subnetList | Select-Object -First 1) -Split
                    if ($network -eq "ESCAPE") {
                        $network = $null
                        break
                    }
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
    $existingPkiOptions = $DC.pkiOptions

    # Import cmOptions from existing top-level site server (CAS or standalone Primary)
    $allDomainVMs = Get-List -Type VM -DomainName $Domain
    $topLevelSite = $allDomainVMs | Where-Object {
        $_.role -in @('CAS', 'Primary') -and -not $_.parentSiteCode -and $_.cmOptions
    } | Select-Object -First 1
    $existingCmOptions = $topLevelSite.cmOptions
    # Also locate any CAS/Primary regardless of cmOptions presence, for the
    # synthesis fallback below when cmOptions was never persisted.
    if (-not $topLevelSite) {
        $topLevelSite = $allDomainVMs | Where-Object {
            $_.role -in @('CAS', 'Primary') -and -not $_.parentSiteCode
        } | Select-Object -First 1
    }

    if ([string]::IsNullOrWhiteSpace($adminUser)) {
        $adminUser = "admin"
    }
    # An existing domain may have been deployed with no prefix at all; keep it blank
    # rather than inventing one, or VMs added to it would be named for a prefix the
    # lab does not use.
    $prefix = "$(get-PrefixForDomain -Domain $Domain)"
    $netbiosName = $Domain.Split(".")[0]
    $vmOptions = [PSCustomObject]@{
        prefix            = $prefix
        basePath          = (Get-MemlabsVmStorageRoot)
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
        pkiOptions      = [PSCustomObject]@{
            EnablePKI       = $false
            IssuingCAVM     = ""
            UseOfflineRoot  = $false
            OfflineRootCAVM = ""
        }
        virtualMachines = $()

    }

    if ($domainDefaults) {
        $configGenerated | Add-Member -MemberType NoteProperty -Name "domainDefaults" -Value $domainDefaults -force
    }

    # Import cmOptions from existing site server so new VMs inherit EnableBLM, UsePKI, etc.
    if ($existingCmOptions) {
        $configGenerated | Add-Member -MemberType NoteProperty -Name "cmOptions" -Value $existingCmOptions -force
    }
    elseif ($topLevelSite) {
        # CAS/Primary exists but has no cmOptions in its VM note (deployed before
        # cmOptions was persisted). Synthesize from domainDefaults and defaults so
        # validation and new-VM deployment have a usable block.
        $inferredVersion = if ($domainDefaults -and $domainDefaults.CMVersion) { $domainDefaults.CMVersion } else { Get-CMLatestBaselineVersion }
        $inferredUsePKI = if ($existingPkiOptions -and $existingPkiOptions.EnablePKI) { $true } else { $false }
        $synthesized = [PSCustomObject]@{
            Version            = $inferredVersion
            Install             = $true
            PrePopulateObjects = $true
            EVALVersion        = $false
            OfflineSCP         = $false
            OfflineSUP         = $false
            UsePKI             = $inferredUsePKI
            EnableBLM          = $false
            WsusImportBaseline = $true
        }
        $configGenerated | Add-Member -MemberType NoteProperty -Name "cmOptions" -Value $synthesized -force
        Write-Log "New-UserConfig: Synthesized cmOptions from defaults (Version=$inferredVersion, UsePKI=$inferredUsePKI) for domain $Domain - existing site server $($topLevelSite.vmName) had no cmOptions in VM note." -Verbose
    }

    # Import PKI settings from existing DC so new VMs inherit CA configuration
    if ($existingPkiOptions -and $existingPkiOptions.EnablePKI) {
        $configGenerated.pkiOptions = $existingPkiOptions
    }
    else {
        # Fallback for labs deployed before pkiOptions was stored on DC note:
        # Derive from per-VM InstallCA property (same logic as Common.Config.ps1 migration)
        $caVM = $allDomainVMs | Where-Object { $_.InstallCA -eq $true } | Select-Object -First 1
        if ($caVM) {
            $configGenerated.pkiOptions.EnablePKI = $true
            $configGenerated.pkiOptions.IssuingCAVM = $caVM.vmName
        }
        # Detect offline root from UseOfflineRoot property OR existence of StandaloneRootCA VM
        $offlineRoot = $allDomainVMs | Where-Object { $_.role -eq "StandaloneRootCA" } | Select-Object -First 1
        if ($offlineRoot -or ($caVM -and $caVM.UseOfflineRoot)) {
            $configGenerated.pkiOptions.UseOfflineRoot = $true
            if ($offlineRoot) {
                $configGenerated.pkiOptions.OfflineRootCAVM = $offlineRoot.vmName
            }
        }
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
