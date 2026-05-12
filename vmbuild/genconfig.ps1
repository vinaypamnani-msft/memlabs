[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Used when calling from New-Lab")]
    [Switch] $InternalUseOnly
)

$return = [PSCustomObject]@{
    ConfigFileName = $null
    DeployNow      = $false
}

# Set Debug & Verbose
$enableVerbose = if ($PSBoundParameters.Verbose -eq $true) { $true } else { $false };
$enableDebug = if ($PSBoundParameters.Debug -eq $true) { $true } else { $false };
$DebugPreference = "SilentlyContinue"
if (-not $InternalUseOnly.IsPresent) {
    if ($Common.Initialized) {
        $Common.Initialized = $false
    }

    # Dot source common
    . $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose

    Write-Host2 -ForegroundColor Cyan ""
}

$configDir = Join-Path $PSScriptRoot "config"

Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigNotice "New-Lab Configuration generator:"
Write-Host2 -ForegroundColor DeepSkyBlue "You can use this tool to customize your MemLabs deployment."
Write-Host2 -ForegroundColor DeepSkyBlue "Press Ctrl-C to exit without saving."
Write-Host2 -ForegroundColor DeepSkyBlue ""
Write-Host2 -ForegroundColor Snow "Select the " -NoNewline
Write-Host2 -ForegroundColor Yellow "numbers or letters" -NoNewline
Write-Host2 -ForegroundColor Snow " on the left side of the options menu to navigate."


Function Show-Passwords {

    param (
        [Parameter(Mandatory = $false)]
        [switch] $LineCount
    )

    $DCs = get-list -type vm | Where-Object { $_.Role -eq "DC" }
    if ($LineCount) {
        return $DCs.Count + 3
    }
    Write-WhiteI "Default Password for all accounts is: " -NoNewline
    Write-Host2 -foregroundColor $Global:Common.Colors.GenConfigNotice "$($Global:Common.LocalAdmin.GetNetworkCredential().Password)"
    Write-Host
    $DCs | Format-Table domain, adminName , @{Name = "Password"; Expression = { $($Common.LocalAdmin.GetNetworkCredential().Password) } } | out-host
}

Function Select-PasswordMenu {
    $customOptions = [ordered]@{"*F" = "Show-Passwords" }
    $response = Get-Menu2 -MenuName "Show Passwords" -AdditionalOptions $customOptions -Prompt "Press Enter" -HideHelp:$true -test:$false               
}
Function Select-ToolsMenu {

    while ($true) {
        $customOptions = [ordered]@{
            "1"  = "Update Tools On Currently Running VMs (C:\Tools)%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" 
            "H1" = "Refresh or add tools that are usually installed at lab deployment to any running VMs"
        }
        $customOptions += [ordered]@{
            "2"  = "Copy Optional Tools (eg Windbg)%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" 
            "H2" = "Add additional tools, like windbg, Azure Data Studio, and others to a running VM"
        }

        $response = Get-Menu2 -MenuName "Tools Menu" -Prompt "Select tools option" -AdditionalOptions $customOptions -NoNewLine -test:$false -return

        if ([String]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE") {
            return
        }

        switch ($response.ToLowerInvariant()) {
            "1" {
                while ($true) {
                    #$customOptions2 = [ordered]@{"A" = "All Tools" }
                    $toolList = $Common.AzureFileList.Tools | Where-Object { $_.Optional -eq $false -and (-not $_.NoUpdate) } | Select-Object -ExpandProperty Name | Sort-Object
                    $tool = Get-Menu2 -MenuName "Tool Selection" -Prompt "Select tool to Install" -OptionArray $toolList -NoNewLine -test:$false -return -MultiSelect
                    if (-not $tool -or $tool -eq "ESCAPE" -or $tool -eq "NOITEMS") {
                        break
                    }
                    while ($true) {
                        #$customOptions2 = [ordered]@{"A" = "All VMs" }
                        $runningVMs = get-list -type vm | Where-Object { $_.State -eq "Running" } | Select-Object -ExpandProperty vmName | Sort-Object
                        $vmName = Get-Menu2 -MenuName "$($tool -join ",") deployment VM Selection" -Prompt "Select VM to deploy '$tool' to" -OptionArray $runningVMs -AdditionalOptions $customOptions2 -NoNewLine -test:$false -return -MultiSelect
                        if (-not $vmName -or $vmName -eq "ESCAPE" -or $vmName -eq "NOITEMS") {
                            break
                        }

                        Get-Tools -Inject -vmName $vmName -ToolName $tool                       
                    }            
                }

            }
            "2" {
                while ($true) {
                    $opt = $Common.AzureFileList.Tools | Where-Object { $_.Optional -eq $true } | Select-Object -ExpandProperty Name | Sort-Object
                    $tool = Get-Menu2 -MenuName "Optional Tool Selection" -Prompt "Select Optional tool to Copy" -OptionArray $opt -NoNewLine -test:$false -return -MultiSelect
                    if (-not $tool -or $tool -eq "ESCAPE" -or $tool -eq "NOITEMS") {
                        break
                    }
                    while ($true) {
                        #$customOptions2 = [ordered]@{"A" = "All VMs listed above" }
                        $runningVMs = get-list -type vm | Where-Object { $_.State -eq "Running" } | Select-Object -ExpandProperty vmName | Sort-Object
                        $vmName = Get-Menu2 -MenuName  "$($tool -join ",") Optional deployment VM Selection" -Prompt "Select VM to deploy '$tool' to" -OptionArray $runningVMs -AdditionalOptions $customOptions2 -NoNewLine -test:$false -MultiSelect
                        if (-not $vmName -or $vmName -eq "ESCAPE" -or $vmName -eq "NOITEMS") {
                            break
                        }
                        
                        Get-Tools -Inject -ToolName $tool -vmName $vmName
                        
                    }
                }

            }
            default { continue }
        }
    }
}


function Select-ConfigMenu {
    $Global:EnterKey = $true
    clear-host
    # Pre-populate Quick Stats cache so the first menu render is instant.
    # Subsequent redraws (every keystroke) reuse this cache for ~20s.
    try { Get-HealthStats -Force | Out-Null } catch {}
    while ($true) {
        
        $customOptions = [ordered]@{}

        $customOptions += [ordered]@{ "*C9" = "   ┌─────────       Quick Stats      ────────┒%MediumPurple" }
        $customOptions += [ordered]@{ "*F0" = "Check-OverallHealth" }
        $customOptions += [ordered]@{ "*HELP" = "Update-HelpText" }
        $customOptions += [ordered]@{ "*BT" = "" }
        $customOptions += [ordered]@{ "*B0" = "Create or Modify domain configs%$($Global:Common.Colors.GenConfigHeader)" }
        #if ($domainCount -gt 0) {
        #    $customOptions += [ordered]@{ "C" = "Create New Domain or Edit Existing Domain [$($domainCount) existing domain(s)] %$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)" }
        #    $customOptions += [ordered]@{ "HC" = "This option allows you to create a new domain, or edit one you previously created." }
  
        #}
        #else {
        $customOptions += [ordered]@{ "C" = "Create New Domain%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)" }
        $customOptions += [ordered]@{ "HC" = "Use this option to create a new domain!" }
        #}

        $domainMap = @{}
        $i = 0
        foreach ($item in (Get-DomainList)) {
            $i++
            $stats = Get-DomainStatsLine -DomainName $item

            $domainList += "$($item.PadRight(22," ")) $stats"
            $customOptions += [ordered]@{"-D$i" = "$($item.PadRight(22," ")) $stats%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)" }
            $customOptions += [ordered]@{ "H$($i)" = "Manage or edit $item" }
            $domainMap[$i] = $item
        }

        if ($null -ne $Global:SavedConfig) {
            $customOptions += [ordered]@{"!" = "Restore In-Progress configuration [$($Global:SavedConfig.VmOptions.DomainName)]%Yellow" }
            $customOptions += [ordered]@{ "H!" = "You have a configuration in progress. Use this to go back and edit it." }
        }
        $customOptions += [ordered]@{"*B" = ""; "*BREAK" = "Load Config ($configDir)%$($Global:Common.Colors.GenConfigHeader)" }
        $customOptions += [ordered]@{"L" = "Load saved config from file %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "HL" = "You can find all your previously saved configuration files here" }
        if ($Global:common.Devbranch) {
            $customOptions += [ordered]@{"X" = "Load TEST config from file (develop branch only)%$($Global:Common.Colors.GenConfigHidden)%$($Global:Common.Colors.GenConfigHiddenNumber)"; }
            $customOptions += [ordered]@{ "HX" = "Here you can find some pre-configured test configuration files." }
        }


        $customOptions += [ordered]@{"*B3" = ""; }
       
        $customOptions += [ordered]@{"*BREAK2" = "Manage Lab%$($Global:Common.Colors.GenConfigHeader)" }
        #$customOptions += [ordered]@{"D" = "Manage Domains%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        #$customOptions += [ordered]@{ "HD" = "This allows you to manage virtual machines in a domain [Start/Stop/Snapshot/Delete/...]" }
        $customOptions += [ordered]@{"T" = "Update Tools or Copy Optional Tools to VMs%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "HT" = "Use this to refresh tools on a VM, or add new ones, like Azure Data Studio!" }
        


        $customOptions += [ordered]@{"*B4" = ""; "*BREAK4" = "List Resources%$($Global:Common.Colors.GenConfigHeader)" }
        $customOptions += [ordered]@{"V" = "Show Virtual Machines%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "HV" = "Show stats about currently deployed Virtual Machines" }
        $customOptions += [ordered]@{"N" = "Show Networks%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "HN" = "Show network subnets currently in use by your VMs" }

        $customOptions += [ordered]@{"P" = "Show Passwords" }
        $customOptions += [ordered]@{ "HP" = "Show the default passwords for all accounts in all domains" }
        $customOptions += [ordered]@{"*B5" = ""; "*BREAK5" = "Other%$($Global:Common.Colors.GenConfigHeader)" }
        $customOptions += [ordered]@{"R" = "Regenerate Rdcman file (memlabs.rdg) from Hyper-V config %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "HR" = "In case your memlabs.rdg file is broken, you can force it to get re-created" }
        if ($common.DevBranch) {
            #$customOptions += [ordered]@{"*B6" = ""; "*BREAK6" = "Currently on Dev Branch%$($Global:Common.Colors.GenConfigHeader)" }
            $customOptions += [ordered]@{"#" = "Switch to Main branch%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
            $customOptions += [ordered]@{ "H#" = "You are currently on the develop branch. This will exit the script and change back to the official branch" }
        }
        else {
            #$customOptions += [ordered]@{"*B6" = ""; "*BREAK6" = "Currently on Main Branch $breakPrefix%$($Global:Common.Colors.GenConfigHeader)" }
            $customOptions += [ordered]@{"#" = "[Experimental] Switch to develop branch%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
            $customOptions += [ordered]@{ "H#" = "Like the bleeding edge? Try testing out the new features in the development branch" }
        }
        $pendingCount = (Get-HealthStats).PendingCount

        if ($pendingCount -gt 0 ) {
            $customOptions += @{"F" = "Delete ($($pendingCount)) Failed/In-Progress VMs (These may have been orphaned by a cancelled deployment)%$($Global:Common.Colors.GenConfigFailedVM)%$($Global:Common.Colors.GenConfigFailedVMNumber)" }
            $customOptions += [ordered]@{ "HF" = "Uh oh.. Looks like a deployment may have failed.  Delete the failed VMs and start over!" }
        }
        $customOptions += [ordered]@{"^" = "Exit script" }
        $customOptions += [ordered]@{ "H^" = "Same as Ctrl-C, Exits the script without saving." }
        if ([Environment]::OSVersion.Version -ge [System.version]"10.0.26100.0") {
            #Do nothing as we are on server 2025
        }
        else {
            if ($Global:Common.IsAzureVM) {
                $customOptions += [ordered]@{"*BU" = ""; "*UBREAK" = "Host machine needs to be on server 2025 to activate Server 2025 VMs" }
                $customOptions += [ordered]@{ "U" = "Upgrade HOST to server 2025%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)" }
                $customOptions += [ordered]@{ "HU" = "Your host machine is not 2025.  You should upgrade!" }
            }
        }
       
        #$pendingCount = (get-list -type VM | Where-Object { $_.InProgress -eq "True" } | Measure-Object).Count
        
        if ($global:GoBack) {
            $SelectedConfig = Select-DomainMenu -DomainName $global:SavedConfig.VmOptions.DomainName | Out-Null
            $response = "!"   
            $global:GoBack = $false        
        }
        else {
            $response = Get-Menu2 -MenuName "MemLabs Main Menu" -Prompt "Select menu option" -AdditionalOptions $customOptions -NoNewLine -test:$false -AcceptsDelete
        }

        write-Verbose "1 response $response"
        if (-not $response) {
            continue
        }
        if (-not $response -is [string]) {
            continue
        }

        if ($response -eq "ESCAPE") {
            $response = "!"
        }
        $SelectedConfig = $null
        switch ($response.ToLowerInvariant()) {
            #"1" { $SelectedConfig = Select-NewDomainConfig }
            #"2" { $SelectedConfig = Show-ExistingNetwork }
            #"C" { $SelectedConfig = Show-ExistingNetwork2 }
            "^" { exit 0 }
            "C" { $SelectedConfig = Select-NewDomainConfig }
            #"3" { $SelectedConfig = Select-Config $sampleDir -NoMore }
           
            "l" { $SelectedConfig = Select-Config $configDir -NoMore }           
            "x" {
                $testPath = Join-Path $configDir "tests"
                $SelectedConfig = Select-Config $testPath -NoMore
            }
            "!" {
                if ($Global:SavedConfig) {
                    $SelectedConfig = $Global:SavedConfig
                    $Global:SavedConfig = $null
                }
                else {
                    continue
                }
            }
            "e" {
                if ($Global:EnterKey -eq $true) {
                    $Global:EnterKey = $false
                }
                else {
                    $Global:EnterKey = $true
                }
            }
            "v" { Select-VMMenu }
            "r" { 
                $response = Read-YesOrNoWithTimeout -Prompt "This will delete your current memlabs.rdg and re-create it. Are you Sure? (Y/n)" -HideHelp -Default "y" -timeout 10
                if ($response -eq "y") {
                    New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$true 
                }               
            }
            "f" { Select-DeletePending; Clear-HealthStatsCache }
            "d" { 
                $SelectedConfig = Select-DomainMenu
                if (-not $SelectedConfig) {
                    continue
                }
            }
            "n" { Select-NetworkMenu }
            "t" { Select-ToolsMenu }
            "P" { Select-PasswordMenu }
            "u" { Install-HostToServer2025 }
            "#" {
                if ($common.DevBranch) {
                    & git checkout main
                    Write-Host "Your branch is now main. Please close this window and restart the shortcut."
                    exit 0
                }
                else {
                    & git checkout develop
                    Write-Host "Your branch is now develop. Please close this window and restart the shortcut."
                    exit 0
                }
            }
            Default {
                write-log -verbose "Response $response"
                $deleteDomain = $false
                if ($response.StartsWith("-D") -and $response.Length -gt 2) {
                    $response = $response.SubString(2)
                    $deleteDomain = $true
                }
                if ($response -as [int] -is [int]) {
                    if ($domainMap[([int]$response)]) {
                        $domain = $domainMap[([int]$response)]
                        if ($deleteDomain) {
                            Write-Host "Do you want to delete $domain permanently?"
                            $response2 = Read-YesOrNoWithTimeout -Prompt "Are you sure? (Y/n)" -HideHelp -timeout 45 -Default "y"
                            if (-not [String]::IsNullOrWhiteSpace($response)) {
                                if ($response2.ToLowerInvariant() -eq "y" -or $response2.ToLowerInvariant() -eq "yes") {
                                    Remove-Domain -DomainName $domain
                                    Clear-HealthStatsCache
                                    continue
                                }
                            }
                        }
                        else {
                            $SelectedConfig = Select-DomainMenu -DomainName $domainMap[([int]$response)]
                        }
                    }
                }
                
            }
        }
        if ($SelectedConfig -and $SelectedConfig -ne "ESCAPE") {
            Write-Verbose "SelectedConfig : $SelectedConfig"
            $global:existingMachines = $null
            if (-not $SelectedConfig.vmOptions) {

                Add-ErrorMessage -Warning "Config is invalid, as it does not contains vmOptions"

                continue
            }
            else {
                return $SelectedConfig
            }
        }
    }
}

function Show-Networks {
    param(
        [Parameter(Mandatory = $false)]
        [switch] $LineCount
    )
    
    $networks = Get-EnhancedNetworkList
    if ($LineCount) {
        return $networks.Count
    }
    ($networks | Select-Object Network, Domain, SiteCodes, "Virtual Machines" | Format-Table | Out-String).Trim() | out-host
}
function  Select-NetworkMenu {
    #get-list -type network | out-host
    
    $customOptions = [ordered]@{"*F" = "Show-Networks" }
    $response = Get-Menu2 -MenuName "Display Networks" -Prompt "Press Enter" -OptionArray $subnetlistEnhanced -AdditionalOptions $customOptions -HideHelp:$true -test:$false
    if (-not $response) {
        return
    }
}

function Show-VMS {

    param(
        [Parameter(Mandatory = $false)]
        [switch] $LineCount
    )
    $vms = get-list -type vm
    if ($LineCount) {
        return $vms.Count
    }
    if (-not $vms) {
        Write-RedX "No VMs currently deployed"
        return
    }

    ($vms | Select-Object VmName, Domain, State, Role, SiteCode, DeployedOS, @{E = { "$($_.DynamicMinRam)-$($_.Memory)" }; L = "Memory" }, DiskUsedGB, SqlVersion, LastKnownIP | Sort-Object -property VmName | Format-Table | Out-String).Trim() | out-host
}
function Select-VMMenu {

    Write-Verbose "2 Select-VMMenu"
    while ($true) {
        $customOptions = [ordered]@{"*F" = "Get-LabVMs" }
        $response = Get-Menu2 -MenuName "Currently Deployed VMs" -Prompt "Press Enter" -AdditionalOptions $customOptions -HideHelp:$true -test:$false

        write-Verbose "1 response $response"
        if (-not $response -or $response -eq "ESCAPE" -or $response -eq "NOITEMS") {
            return
        }
      
    }
}
function Select-DomainMenu {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string] $DomainName
    )

   
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($DomainName)) {

            $domainList = @()
            foreach ($item in (Get-DomainList)) {
                $stats = Get-DomainStatsLine -DomainName $item

                $domainList += "$($item.PadRight(22," ")) $stats"
            }

            if ($domainList.Count -eq 0) {
                Write-Host
                Write-Host2 -ForegroundColor FireBrick "No Domains found. Please delete VM's manually from hyper-v"

                return
            }

            $domain = Get-Menu2 -MenuName "Domain Management Menu" -Prompt "Select existing domain" -OptionArray $domainList -split -test:$false -return
            if ($domain -eq "ESCAPE") {
                return
            }
            if ([string]::IsNullOrWhiteSpace($domain)) {
                continue
            }
        }
        else {
            $domain = $DomainName            
        }

        $vms = get-list -type vm -DomainName $domain -SmartUpdate
        if (-not $vms) {
            return
        }

        Write-Verbose "2 Select-DomainMenu"
        while ($true) {

       
            $vms = get-list -type vm -DomainName $domain -SmartUpdate
            if (-not $vms) { break }
            $CustomOptions = [ordered]@{}

            $notRunning = ($vms | Where-Object { $_.State -ne "Running" }).Count
            $running = ($vms | Where-Object { $_.State -eq "Running" }).Count


            $checkPoint = $null
            $DC = $vms | Where-Object { $_.role -eq "DC" }
            if ($DC) {
                $checkPoint = (Get-VMCheckpoint2 -vmname $DC.vmName | where-object { $_.Name -like '*MemLabs*' }).Count
            }
       

            $customOptions = [ordered]@{
                "*F1"   = "Get-LabVMs -DomainName $domain"     
                "*BZ"   = "";       
                "*HELP" = "Update-HelpText"
                "*B0"   = "";
                "*B1"   = "VM Management%$($Global:Common.Colors.GenConfigHeader)";
                "M"     = "Modify - Edit or Add VMs to this domain%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)"
                "HM"    = "Use this option to modify the domain, adding new roles, or new VMs"
                "1"     = "Start VMs in domain [$notRunning VMs are not started]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)";
                "H1"    = "Select any stopped VMs to start.  List will be empty if nothing is stopped."
                "2"     = "Stop VMs in domain  [$running VMs are running]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)";
                "H2"    = "Select any running VMs to stop.  List will be empty if nothing is running."
                "3"     = "Compact VHDX's in domain%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)";
                "H3"    = "Select any VMs to optimize. This will run Optimize-VHD, and will stop the VM"
                "*S"    = ""
                "*B2"   = "Snapshot Management%$($Global:Common.Colors.GenConfigHeader)"
                "S"     = "Snapshot all VM's in domain%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
                "HS"    = "Create a Hyper-V snapshot/checkpoint of the domain.  All VMs will be stopped, then restarted"
            }
              
            if ($checkPoint) {
                $customOptions += [ordered]@{ 
                    "R"  = "Restore all VM's to a snapshot%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
                    "HR" = "Restore a domain checkpoint/snapshot taken by this script. All VMs in the snapshot will be restored"
                    "X"  = "Delete (merge) domain Snapshots [$checkPoint Snapshot(s)]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)" 
                    "HX" = "Merges snapshots back into the VHDX file, effectively 'deleting' them.  This can help with performance and disk usage"
                }
            }
            $enabled = ($vms | Where-Object { ($_.Memory / 1 ) -gt ($_.DynamicMinRam / 1) }).Count
            $disabled = ($vms | Where-Object { ($_.Memory / 1 ) -le ($_.DynamicMinRam / 1) }).Count

            $CustomOptions += [ordered]@{
                "*E"  = ""
                "*B4" = "Dynamic Memory%$($Global:Common.Colors.GenConfigHeader)"
            }
            if ($disabled -ge 1) {
                $CustomOptions += [ordered]@{   
                    "E"  = "Enable Dynamic Memory  [$disabled VMs eligible]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
                    "HE" = "Select VMs to enable dynamic memory on"
                }
            }
            if ($enabled -ge 1) {
                $CustomOptions += [ordered]@{
                    "F"  = "Disable Dynamic Memory [$enabled VMs eligible]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
                    "HF" = "Select VMs to disable dynamic memory on"
                }
            }
            $customOptions += [ordered]@{
                "*Z"  = ""
                "*B3" = "Danger Zone%$($Global:Common.Colors.GenConfigHeader)"
                "D"   = "Delete VMs in Domain%$($Global:Common.Colors.GenConfigDangerous)%$($Global:Common.Colors.GenConfigDangerous)" 
                "HD"  = "Delete selected VM's from Hyper-V. This can be used to remove your entire domain, or individual VMs" 
            }
            $response = Get-Menu2 -MenuName "$domain Management Menu" -Prompt "Select domain options" -AdditionalOptions $customOptions -test:$false -return

            write-Verbose "1 response $response"
            if (-not $response -or $response -eq "ESCAPE") {
                if ($global:GoBack) { 
                    return $global:SavedConfig 
                }
                else {
                    return
                }
            }

            switch ($response.ToLowerInvariant()) {
                "2" { Select-StopDomain -domain $domain }
                "1" { Select-StartDomain -domain $domain }
                "3" { select-OptimizeDomain -domain $domain }
                "d" {
                    Select-DeleteDomain -domain $domain                
                }
                "s" { select-SnapshotDomain -domain $domain }
                "r" { select-RestoreSnapshotDomain -domain $domain }
                "x" { select-DeleteSnapshotDomain -domain $domain }
                "e" { select-ChangeDynamicMemory -domain $domain -Enable }
                "f" { select-ChangeDynamicMemory -domain $domain -Disable }
                "m" {
                    if ($global:GoBack) { 
                        return $global:SavedConfig 
                    }
                    else {
                        return Show-ExistingNetwork2 -domainName $domain 
                    }
                }
                Default {}
            }
        }
    }
}


function Get-ExistingVMs {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $config = $global:Config
    )
    write-Log -Verbose "Refreshing existing VMs"
    $existingMachines = get-list -type vm -domain $config.vmOptions.DomainName | Where-Object { $_.vmName }

    foreach ($vm in $config.virtualMachines) {
        # if ($vm.modified -and $vm.vmName -in $existingMachines.vmName) {
        $vmName = $config.vmOptions.Prefix + $($vm.vmName)
        Write-Log -Verbose "Checking if $($vmName) is in ExistingMachines"
        if ($vmName -in $existingMachines.vmName) {
            $existingMachines = @($existingMachines | Where-Object { $_.vmName -ne $vmName })
        }
    }

    # Transient/runtime-only properties that should not appear in the edit-existing-VM
    # view (they come from get-list but are not part of the saved deployment config).
    $propsToStrip = @(
        'memLabsDeployVersion', 'memLabsVersion', 'domainDefaults', 'success',
        'vmBuild', 'deployedOS', 'switch', 'source', 'memoryGB', 'memoryStartupGB',
        'inProgress', 'lastUpdate', 'DiskUsedGB'
    )
    foreach ($evm in $existingMachines) {
        foreach ($prop in $propsToStrip) {
            if ($null -ne $evm.$prop) {
                $evm.PsObject.Members.Remove($prop)
            }
        }
        if ($evm.SqlVersion -and $null -eq $evm.sqlInstanceName) {
            $evm | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
        }
    }



    return $existingMachines
}

function Get-GenericHelp {
    param(
        $text       
    )

    switch (($text -split "=")[0].Trim()) {
        "DeploymentType" { "Selects the default type of deployment, Primary or Hierarchy" }
        "DomainName" { "Change the FQDN of the domain" }
        "CMVersion" { "Select which version of ConfigMgr to install.  Will not be used if not installing CM" }
        "Network" { "Select the Network VMs will join.  Only /24 ranges are acceptable. " }
        "DefaultServerOS" { "When adding new server VMs, they will default to this OS. Can be changed on individual VMs." }
        "DefaultClientOS" { "When adding new client VMs, they will default to this OS. Can be changed on individual VMs." }
        "DefaultSqlVersion" { "When adding new SQL instances, they will default to this version. Can be changed on individual VMs." }
        "UseDynamicMemory" { "Enable Dynamic Memory on each new VM.  Can be turned off in the settings for each VM, using dynamicMinRam" }
        "IncludeClients" { "Disabling this will prevent the 2 automatic client VMs from appearing in a new domain config" }
        "IncludeSSMSOnNONSQL" { "Disabling this will prevent SQL Management Studio from getting installed on NON-SQL servers" }
        "Done with changes" { "All the settings look good.  Move onto next menu" }

        # Global VM

        "Prefix" { "Change the prefix of all machines in the domain.  This is used to ensure unique machine names across all domains." }
        "AdminName" { "Change the default administrator name for all machines and domains. Not recommended to change." }
        "BasePath" { "Change the location to save hyper-v VHDX and other files. Not recommended to change." }
        "domainNetBiosName" { "Change the netbios name of the domain.  This will result in a disjoined namespace if it does not match the FQDN" }
        "locale" { "If you have configured _localconfig.json, you can change the default language of your VM via language packs" }
        "timeZone" { "Change the timezone of all new VMs deployed in this session." }

        # Global CM

        "Version" { "Change the version of CM to install. By default, we select the newest baseline version." }
        "Install" { "Disable this setting to prevent CM from installing.  This is useful to pre-stage your VMs, but perform a custom installation by hand" }
        "EVALVersion" { "Install the EVAL license for ConfigMgr.  This will expire in 6 months." }
        "UsePKI" { "Automatically setup a complete PKI infrastructure, and use HTTPS all CM Roles, include DP/MP/SUP/RP." }
        "OfflineSCP" { "Install the SCP role in Offline mode.  This will prevent CM from updating. Useful for offline repros" }
        "OfflineSUP" { "Install the SUP role in Offline mode.  This will prevent WSUS from talking to Microsoft Update to get patch information" }
        "PushClientToDomainMembers" { "Disable this setting to prevent client push from CM.  Clients will not be installed automatically" }
        "PrePopulateObjects" { "This setting will pre populate a number of objects in the CM database, such as packages, scripts, OSD TS's, Baselines, etc" }

        # VM

        "vmName" { "Change the name of the VM" }
        "Role" { "Change the role of the VM. Not recommended to change." }
        "Memory" { "Change the starting and Maximum memory for this VM." }
        "DynamicMinRam" { "Enables Dynamic Memory.  Sets the Minimum amount of RAM." }
        "VirtualProcs" { "Change the number of virtual processors assigned to this VM" }
        "OperatingSystem" { "Change the Operating System that will be installed on this VM" }
        "tpmEnabled" { "Enable the virtual TPM on this VM." }
        "InstallCA" { "Installs and configures a Certificate Authority on this VM" }
        "ForestTrust" { "This option allows you to create a Forest Trust between this domain, and another already deployed domain." }
        "Add Additional Disk" { "Adds another VHDX to this VM" }
        "Remove Last Additional Disk" { "Removes the last VHDX added to this machine" }
        "Remove this VM from config" { "'Deletes' the VM. Since its not actually deployed yet, just prevents it from being deployed." }
        "SiteCode" { "Changes the sitecode for this site" }
        "InstallSSMS" { "SQL Server Management Studio will be installed on this VM" }
        "InstallDP" { "Install the Distribution Point role on this VM" }
        "InstallMP" { "Install the Management Point role on this VM" }
        "InstallRP" { "Install SSRS and the Reporting point role on this VM" }
        "InstallSUP" { "Install WSUS and the Software Update Point role on this VM" }
        "InstallSMSProv" { "Install an additional SMS Provider on this machine (Along with the ADK)" }
        "wsusContentDir" { "Change the location where WSUS will store its content" }
        "wsusDataBaseServer" { "Change the database WSUS will use.  Can be WID, or a local or remote SQL Server" }
        "Add SQL" { "Adds a SQL Instance to this VM" }
        "Remove SQL" { "Removes SQL from this VM" }
        "sqlVersion" { "Change the version of SQL installed on this VM" }
        "sqlInstanceName" { "Change the instance name that SQL will use when installing" }
        "sqlInstanceDir" { "Change the location where this instance of SQL will be installed" }
        "sqlPort" { "Change the port number this instance of SQL will use" }
        "SqlAgentAccount" { "Change the account sql will use for the SQL Agent service. Account will be created in the domain." }
        "SqlServiceAccount" { "Change the account sql will use for the SQL Server service. Account and SPNs will be created in the domain." } 
        "useFakeWSUSServer" { "Adds a fake WSUS server to the registry, which will prevent the machine from automatically updating from windows update" } 
        "Add domain user as admin on this machine" { "Creates an Active Directory user, and assigns it as the primary admin of this machine" }
        "Remove domainUser from this machine" { "Removes the Active Directory user assigned as admin to this machine" }
        "DomainUser" { "Change the name of the domain user assigned as admin on this machine" }
        "RemoteContentLibVM" { "This is the FileServer VM that will be used for the remote ContentLib" }
        "cmInstallDir" { "This is the location in the VM where CM will be installed" }
        "AdditionalDisks" { "This is the list of additional disks created during deployment. You can configure their sizes here." }
        "SiteName" { "This is the display name of the site in configuration manager" }
        "RemoteSQLVM" { "This is the name of the SQL VM that will host databases used by roles on this VM" }
        "AlwaysOnGroupName" { "Display name for the SQL AO Availability Group" }
        "AlwaysOnListenerName" { "DNS Name of the listener used by SQL AO. This would be the name you use to connect to SQL" }
        "ClusterName" { "Internal name used by Clustering to setup the SQL AO cluster. Must be unique" }
        "fileServerVM" { "FileServer VM used by SQL AO for its quorum data" }
        "OtherNode" { "This is a link to the other node of the SQL AO cluster. Not recommended to change" }
        "vmGeneration" { "Sets the Hyper-V VM generation. Only available on OSD clients, all other VMs are gen 2" }
        "ParentSiteCode" { "Sets the parent site code for siteservers or sitesystems" }
        "pullDPSourceDP" { "Sets the source Distribution point for this PullDP" }
        "InstallPatchMyPC" { "Installs the PatchMyPC service on this VM. Must be installed on the Top-Level SUP" }
        "PatchMyPCFileServer" { "Sets the FileServer that PatchMyPC will use to store its updates" }

        default { "Help Missing for $text" }
    }
    
}

# Push any in-memory edits to existing (already-deployed) VMs back into the
# deploy config as hidden VM entries, so Test-Configuration / deployment can
# see them. No-op if nothing was edited.
function Add-ModifiedExistingVMsToConfig {
    foreach ($virtualMachine in $global:existingMachines) {
        if (get-IsExistingVMModified -virtualMachine $virtualMachine) {
            Add-ModifiedExistingVMToDeployConfig -vm $virtualMachine -configToModify $global:config -hidden:$true
        }
    }
}

# Returns $true if any already-deployed VM has been edited in this session.
function Test-AnyExistingVMModified {
    foreach ($virtualMachine in $global:existingMachines) {
        if (get-IsExistingVMModified -virtualMachine $virtualMachine) {
            return $true
        }
    }
    return $false
}

function Select-MainMenu {
    if (-not $global:existingMachines) {   
        Set-Variable -Scope "Global" -Name "DisableSmartUpdate" -Value $false 
        $global:existingMachines = Get-ExistingVMs -config $global:config        
    }
   
    $VMNameToNumberMap = @{}
    while ($true) {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:StartOver = $false
        $global:GoBack = $false
        Set-Variable -Scope "Global" -Name "DisableSmartUpdate" -Value $true
        $global:GenConfigErrorMessages = @()
        $tc = Test-Configuration -InputObject $Global:Config -fast
        Convert-ValidationMessages -TestObject $tc
        $preOptions = [ordered]@{}
        $preOptions += [ordered]@{ "*F1" = "Show-GenConfigErrorMessages" }
        $preOptions += [ordered]@{ "*B" = "Global Options%$($Global:Common.Colors.GenConfigHeader)" }
        $preOptions += [ordered]@{ "V" = "Global VM Options `t $(get-VMOptionsSummary) %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigHelpHighlight)" }
        $preOptions += [ordered]@{ "HV" = "Change Global Options, such as domain name, netbios name, timezone, etc" }
        if ($Global:Config.cmOptions) {
            $preOptions += [ordered]@{"C" = "ConfigMgr Options `t $(get-CMOptionsSummary) %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigHelpHighlight)" }
            $preOptions += [ordered]@{ "HC" = "Change Global Config Manager Options, such as PKI, Version, licensing, etc" }
        }
        
        $customOptions = [ordered]@{}

        $i = 0
        $virtualMachines = @()

      


        if ($global:existingMachines) {
            $preOptions += [ordered]@{ "*B1" = ""; "*B2" = "Existing Virtual Machines%$($Global:Common.Colors.GenConfigHeader)" }
            foreach ($existingVM in $global:existingMachines) {
                $i = $i + 1
                $name = Get-VMString -config $global:config -virtualMachine $existingVM -colors
                $customOptions += [ordered]@{"-D$i" = "$name" }
                $customOptions += [ordered]@{"H$i" = "Modify the properties of the already deployed VM named $($existingVM.vmName). Press [Del] to delete from Hyper-V. Only some properties can be adjusted." }
                $VMNameToNumberMap[$i.ToString()] = $existingVM.vmName
            }
        }
        $customOptions += [ordered]@{"*V2" = "" }
        $customOptions += [ordered]@{"*B3" = "Virtual Machines to be deployed%$($Global:Common.Colors.GenConfigHeader)" }
        try {
            if ($global:Config.virtualMachines) {
                $virtualMachines = @($global:Config.virtualMachines | Where-Object { $_.role -in "DC", "BDC" })
                $virtualMachines += @($global:Config.virtualMachines | Where-Object { $_.role -notin "DC", "BDC" } | Sort-Object { $_.vmName })

                if ($virtualMachines -and $global:Config.virtualMachines) {
                    $global:Config.virtualMachines = $virtualMachines
                }
            }
        }
        catch {
            if (-not $global:Config) {
                Write-RedX "Global:Config is missing.  Please restart the script."
                exit 1
            }
            write-Log "Exception from global:Config.virtualMachines: $($global:Config | ConvertTo-Json -Depth 3 -Compress -ErrorAction SilentlyContinue)" -Failure

            $global:Config.virtualMachines = @()
        }
        if ($global:config.virtualMachines) {
            foreach ($virtualMachine in $global:config.virtualMachines | Where-Object { -not $_.Hidden }) {
                if ($null -eq $virtualMachine) {
                    #$global:config.virtualMachines | convertTo-Json -Depth 5 | out-host
                    continue
                }
                $i = $i + 1
                $name = Get-VMString -config $global:config -virtualMachine $virtualMachine -colors
                $customOptions += [ordered]@{"-D$i" = "$name" }
                $customOptions += [ordered]@{"H$i" = "Modify the installation properties for $($virtualMachine.Vmname). Press [Del] to remove. This is a new VM that has not yet deployed." }
                $VMNameToNumberMap[$i.ToString()] = $virtualMachine.vmName
                #write-Option "$i" "$($name)"
            }
        }

        $customOptions += [ordered]@{ "N" = "Add New Virtual Machine%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVMNumber)" }
        $customOptions += [ordered]@{ "HN" = "Adds a new VM to this deployment. You can add clients, servers, or even new siteservers." }
        $customOptions += [ordered]@{ "*D1" = ""; "*BD" = "Deployment Actions%$($Global:Common.Colors.GenConfigHeader)" }
        $customOptions += [ordered]@{ "!" = "Return to main menu %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "H!" = "Saves the current configuration, and returns to the main menu.  You can return to this deployment from the main menu." }
        $customOptions += [ordered]@{ "S" = "Save Configuration and Exit %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "HS" = "Saves the current configuration to your config folder, but does not deploy. You can load it from the main menu" }
        if ($InternalUseOnly.IsPresent) {
            $customOptions += [ordered]@{ "Q" = "Quit Without Saving!%$($Global:Common.Colors.GenConfigDangerous)%$($Global:Common.Colors.GenConfigDangerous)" }
            $customOptions += [ordered]@{ "HQ" = "Exits the script. Warning: Does not save." }
            $customOptions += [ordered]@{ "D" = "Deploy And Save Config%$($Global:Common.Colors.GenConfigDeploy)%$($Global:Common.Colors.GenConfigDeployNumber)" }
            $customOptions += [ordered]@{ "HD" = "Saves the current configuration to your config folder, and will start creation of the VMs" }            
        }
        if ($enableDebug) {
            $customOptions += [ordered]@{ "R" = "Return deployConfig" }
            $customOptions += [ordered]@{ "HR" = "Debug option to return `$deployconfig" }
            $customOptions += [ordered]@{ "Z" = "Generate DSC.Zip" }
            $customOptions += [ordered]@{ "HZ" = "Debug option to regenerate DSC.ZIP" }
        }


        $MenuName = "VM Deployment Menu - $($Global:Config.vmOptions.DomainName)"
        if ($Global:configfile) {
            $ShortName = [io.path]::GetFileNameWithoutExtension($global:configfile)
            $MenuName += " - $ShortName"
        }
        $response = Get-Menu2 -MenuName $MenuName -Prompt "Select menu option" -OptionArray $optionArray -AdditionalOptions $customOptions -preOptions $preOptions -Test:$false -AcceptsDelete
        write-Verbose "response $response"
        if ($response -eq "ESCAPE") {
            if (-not $global:existingMachines) {
                $response = "!"
            }
            else {
                $response = "*"
            }
        }
        if (-not $response -or $response -eq "ESCAPE") {
            continue
        }
        if (-not ($response -is [string])) {
            continue
        }
        switch ($response.ToLowerInvariant()) {
            "q" {
                $global:DisableSmartUpdate = $false
                exit(0)
            }
            "v" { 
                Select-Options -MenuName "Global VM Options Menu" -Rootproperty $($Global:Config) -PropertyName vmOptions -prompt "Select Global Property to modify" -HelpFunction "Get-GenericHelp"
            }
            "c" { 
                Select-Options -MenuName "Global Configuration Manager Menu"  -Rootproperty $($Global:Config) -PropertyName cmOptions -prompt "Select ConfigMgr Property to modify" -HelpFunction "Get-GenericHelp"
            }
            "d" {
                Add-ModifiedExistingVMsToConfig
                $global:DisableSmartUpdate = $false
                return $true
            }
            "s" {
                $global:DisableSmartUpdate = $false
                return $false 
            }
            "r" {
                Add-ModifiedExistingVMsToConfig
                $c = Test-Configuration -InputObject $Global:Config
                $global:DebugConfig = $c.DeployConfig
                write-Host 'Debug Config stored in $global:DebugConfig'
                $global:DisableSmartUpdate = $false
                return $global:DebugConfig
            }
            "!" {
                $modified = Test-AnyExistingVMModified
                $response = "y"
                if ($modified) {
                    $response = Read-YesOrNoWithTimeout -Prompt "One or more modified existing machines found. These changes will not be saved. Continue?" -HideHelp -Default "y" -timeout 15
                    if ($response -eq "y") {
                        return
                    }
                }
                if ($response -eq "y") {
                    $global:StartOver = $true
                    $global:DisableSmartUpdate = $false
                    Get-List -FlushCache
                    return $false
                }                
            }
            "*" {                                              
                $modified = Test-AnyExistingVMModified
                $response = "y"
                if ($modified) {
                    $response = Read-YesOrNoWithTimeout -Prompt "One or more modified existing machines found. These changes will not be saved. Continue?" -HideHelp -Default "y" -timeout 15
                    if ($response -eq "y") {
                        return
                    }
                }
                if ($response -eq "y") {
                    $global:GoBack = $true
                    $global:SavedConfig = $global:Config                              
                    $global:DisableSmartUpdate = $false
                    Get-List -FlushCache
                    return $false
                }                
            }
            "z" {
                $i = 0
                $filename = Save-Config $Global:Config
                #$creds = New-Object System.Management.Automation.PSCredential ($Global:Config.vmOptions.adminName, $Global:Common.LocalAdmin.GetNetworkCredential().Password)
                $t = Test-Configuration -InputObject $Global:Config
                $response = Get-Menu2 -MenuName "Generate DSC.Zip" -Prompt "Select menu option" -OptionArray $($t.DeployConfig.virtualMachines.vmName) -Test:$false -
                if ($response -eq "ESCAPE") {
                    continue
                }
                $vmName = $response                

                $params = @{configName = $filename; vmName = $vmName; Debug = $false }

                write-host "& .\dsc\createGuestDscZip.ps1 -configName ""$fileName"" -vmName $vmName"    
                Add-CmdHistory ".\dsc\createGuestDscZip.ps1 -configName `"$fileName`" -vmName $vmName"
                #Invoke-Expression  ".\dsc\createGuestDscZip.ps1 -configName ""$fileName"" -vmName $vmName -confirm:$false"
                & ".\dsc\createGuestDscZip.ps1" @params | Out-Host
                Set-Location $PSScriptRoot | Out-Null
            }
            "n" {
                Select-VirtualMachines $response
            }
            default { 
                # This will be a VM number, or 'N' for new VM

                if ($response.StartsWith("-D")) {
                    $response = $response.SubString(2)
                    write-log -verbose "Deleting VM '$response' from config"
                    Select-VirtualMachines $vmNameToNumberMap[$response] "Z"
                }
                else {
                    Select-VirtualMachines $vmNameToNumberMap[$response] 
                }
            }
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



    $file = "$($config.vmOptions.domainName)"
    if ($config.vmOptions.existingDCNameWithPrefix) {
        $file += "-ADD-"
    }
    elseif (-not $config.cmOptions) {
        $file += "-NOSCCM-"
    }
    elseif ($Config.virtualMachines | Where-Object { $_.Role -eq "CAS" }) {
        $file += "-CAS-$($config.cmOptions.version)-"
    }
    elseif ($Config.virtualMachines | Where-Object { $_.Role -eq "Primary" }) {
        $file += "-PRI-$($config.cmOptions.version)-"
    }

    $file += "$($config.virtualMachines.Count)VMs"
    #$date = Get-Date -Format "yyyy-MM-dd"
    #$file = $date + "-" + $file

    $filename = Join-Path $configDir $file
    $fullFileName = $null
    if ($Global:configfile) {
        write-host $Global:configfile
        $filename = [System.Io.Path]::GetFileNameWithoutExtension(($Global:configfile))
        #if ($filename.StartsWith("PSTest") -or $filename.StartsWith("CSTest")) {
        #return Split-Path -Path $fileName -Leaf
        #    return $fileName
        #}
        #$filename = Join-Path $configDir $filename
        $fullFilename = $Global:configfile
        $contentEqual = (Get-Content $fullFileName | ConvertFrom-Json | ConvertTo-Json -Depth 5 -Compress) -eq
        ($config | ConvertTo-Json -Depth 5 -Compress)
        if ($contentEqual) {
            #return Split-Path -Path $fileName -Leaf
            Write-Log -HostOnly -Verbose "(2)Returning File: $fileName"
            return $fileName
        }
        else {
            # Write-Host "Content Not Equal"
            # (Get-Content $fullFilename | ConvertFrom-Json| ConvertTo-Json -Depth 5) | out-host
            # ($config | ConvertTo-Json -Depth 5) | out-host
        }
    }
    if ($fileName.contains(":")) {
        $fileName = Split-Path -Path $fileName -Leaf
    }
    $response = Read-Single -Prompt "Save Filename" -currentValue $filename -HideHelp -Timeout 30 -useReadHost

    if ($fullFileName -and (-not $response)) {
        try {
            $config | ConvertTo-Json -Depth 5 | Out-File $fullfilename -ErrorAction Stop
            Write-Host "Saved to $fullfilename"
        }
        catch {
            Write-Log "Failed to save config to '$fullfilename': $_" -Failure
        }
        Write-Log -HostOnly -Verbose "(3)Returning File: $fileName -> $fullFileName"
        return $filename
    }

    if (-not [String]::IsNullOrWhiteSpace($response)) {
        $filename = Join-Path $configDir $response
    }
    else {
        $filename = Join-Path $configDir $filename
    }

    if (!$filename.ToLowerInvariant().EndsWith(".json")) {
        $filename += ".json"
    }

    try {
        $config | ConvertTo-Json -Depth 5 | Out-File $filename -ErrorAction Stop
        #$return.ConfigFileName = Split-Path -Path $fileName -Leaf
        Write-Host "Saved to $filename"
    }
    catch {
        Write-Log "Failed to save config to '$filename': $_" -Failure
    }
    Write-Host
    Write-Verbose "11"
    $filename = Split-Path -Path $fileName -Leaf
    Write-Log -HostOnly -Verbose "Returning File: $fileName"
    return $filename
}

$Global:SavedConfig = $null
do {
    $Global:Config = $null
    $Global:configfile = $null
    $global:StartOver = $false
    $global:GoBack = $false
    $Global:Config = Select-ConfigMenu


    # $DeployConfig = (Test-Configuration -InputObject $Global:Config).DeployConfig

    $valid = $false
    while ($valid -eq $false) {
      

        $return.DeployNow = Select-MainMenu
       
        if ($Global:GoBack -eq $true) {
            
            $Global:SavedConfig = $global:Config
            $Global:Config = Select-ConfigMenu
            Write-Host "Configuration restored to previous state."            
            $Global:GoBack = $false
            $global:SavedConfig = $null
            continue
        }

        if ($global:StartOver -eq $true) {
            Write-Host2 -ForegroundColor MediumAquamarine "Saving Configuration... use ""!"" to return."
            $Global:SavedConfig = $global:Config
            Write-Host
            break
        }
        if ($return.DeployNow -is [PSCustomObject]) {
            return $return.DeployNow
        }
        $c = Test-Configuration -InputObject $Global:Config
        Convert-ValidationMessages -TestObject $c
        Write-Host
        Write-Verbose "12"

        if ($c.Valid) {
            $valid = $true
        }
        else {
            if ($return.DeployNow -eq $false) {
                write-host2 -ForegroundColor $Global:Common.Colors.GenConfigError1 "Configuration is not valid. Saving is not advised. Proceed with caution. Hit CTRL-C to exit.`r`n"
                Write-ValidationMessages -TestObject $c
                $valid = $true
                break
            }
            else {
                Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigError2 "Config file is not valid:`r`n"
                Write-ValidationMessages -TestObject $c
                Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigError2 "`r`nPlease fix the problem(s), or hit CTRL-C to exit."
            }
        }

        if ($valid) {
            Show-Summary ($c.DeployConfig)
            Write-Host
            Write-verbose "13"
            if ($return.DeployNow -eq $true) {
                Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigNotice "Please save and exit any RDCMan sessions you have open, as deployment will make modifications to the memlabs.rdg file on the desktop"
            }
            Write-Host "Answering 'no' below will take you back to the previous menu to allow you to make modifications"
            $response = Read-YesOrNoWithTimeout -Prompt "Everything correct? (Y/n)" -HideHelp -timeout 180 -Default "y"
            if (-not [String]::IsNullOrWhiteSpace($response)) {
                if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                    $valid = $false
                }
                else {
                    break
                }
            }
            else {
                break
            }
        }
    }
} while ($null -ne $Global:SavedConfig -and (($global:StartOver -eq $true) -or ($global:GoBack -eq $true)))

$return.ConfigFileName = Save-Config $Global:Config


if (-not $InternalUseOnly.IsPresent) {
    Write-Host "You may deploy this configuration by running the following command:"
    Write-Host "$($PSScriptRoot)\New-Lab.ps1 -Configuration ""$($return.ConfigFileName)"""
    Add-CmdHistory "$($PSScriptRoot)\New-Lab.ps1 -Configuration ""$($return.ConfigFileName)"""
}

#================================= NEW LAB SCENARIO ============================================
if ($InternalUseOnly.IsPresent) {
    $domainExists = Get-List -Type VM -DomainName $Global:Config.vmOptions.domainName
    if ($domainExists -and ($return.DeployNow)) {
        write-host2 -ForegroundColor $Global:Common.Colors.GenConfigNotice "This configuration will make modifications to $($Global:Config.vmOptions.DomainName)"
        Write-OrangePoint -NoIndent "Without a snapshot, if something fails it may not be possible to recover"
        $response = Read-YesOrNoWithTimeout -Prompt "Do you wish to take a Hyper-V snapshot of the domain now? (y/N)" -HideHelp -Default "n" -timeout 30
        if (-not [String]::IsNullOrWhiteSpace($response) -and $response.ToLowerInvariant() -eq "y") {
            $result = Select-StopDomain -domain $Global:Config.vmOptions.DomainName -response "C"
            $filename = $splitpath = Split-Path -Path $return.ConfigFileName -Leaf
            $comment = [System.Io.Path]::GetFileNameWithoutExtension($filename)
            if ($comment -ne $splitpath) {
                get-SnapshotDomain -domain $Global:Config.vmOptions.DomainName -comment $comment
            }
            else {
                get-SnapshotDomain -domain $Global:Config.vmOptions.DomainName
            }
            Select-StartDomain -domain $Global:Config.vmOptions.DomainName -response "C"
        }
    }
    return $return
}

