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
            "1" { Invoke-ToolDeployment -Optional:$false }
            "2" { Invoke-ToolDeployment -Optional:$true }
            default { continue }
        }
    }
}

# Inner loop for Select-ToolsMenu option "1" (default tools) and "2" (optional
# tools). Both repeatedly prompt for a tool, then a target VM, then call
# Get-Tools -Inject. The only differences captured by -Optional are:
#   - which tools the user can pick from (Optional eq $true/$false; default
#     also filters out NoUpdate-marked entries).
#   - menu titles / prompt text.
function Invoke-ToolDeployment {
    param(
        [switch] $Optional
    )

    if ($Optional) {
        $toolFilter      = { $_.Optional -eq $true }
        $toolMenuName    = "Optional Tool Selection"
        $toolPrompt      = "Select Optional tool to Copy"
        $vmMenuSuffix    = "Optional deployment VM Selection"
        $vmMenuReturn    = $false
    }
    else {
        $toolFilter      = { $_.Optional -eq $false -and (-not $_.NoUpdate) }
        $toolMenuName    = "Tool Selection"
        $toolPrompt      = "Select tool to Install"
        $vmMenuSuffix    = "deployment VM Selection"
        $vmMenuReturn    = $true
    }

    while ($true) {
        $toolList = $Common.AzureFileList.Tools | Where-Object $toolFilter | Select-Object -ExpandProperty Name | Sort-Object
        $tool = Get-Menu2 -MenuName $toolMenuName -Prompt $toolPrompt -OptionArray $toolList -NoNewLine -test:$false -return -MultiSelect
        if (-not $tool -or $tool -eq "ESCAPE" -or $tool -eq "NOITEMS") {
            break
        }
        while ($true) {
            $runningVMs = get-list -type vm | Where-Object { $_.State -eq "Running" } | Select-Object -ExpandProperty vmName | Sort-Object
            $vmName = Get-Menu2 -MenuName "$($tool -join ',') $vmMenuSuffix" -Prompt "Select VM to deploy '$tool' to" -OptionArray $runningVMs -AdditionalOptions $customOptions2 -NoNewLine -test:$false -return:$vmMenuReturn -MultiSelect
            if (-not $vmName -or $vmName -eq "ESCAPE" -or $vmName -eq "NOITEMS") {
                break
            }

            Get-Tools -Inject -vmName $vmName -ToolName $tool
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

        $built = Build-ConfigMenuOptions
        $customOptions = $built.Options
        $domainMap = $built.DomainMap

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

# Builds the MemLabs Main Menu (Select-ConfigMenu's top-level menu): Create
# New Domain / per-domain entries / Load Config / Manage Lab / List Resources
# / Other / etc. Returns @{ Options = <ordered hashtable>; DomainMap = <int->name> }.
# DomainMap is used by the caller's default-case dispatch to translate the
# numeric domain shortcuts back to domain names.
function Build-ConfigMenuOptions {
    $customOptions = [ordered]@{}

    $customOptions += [ordered]@{ "*C9" = "   ┌─────────       Quick Stats      ────────┒%MediumPurple" }
    $customOptions += [ordered]@{ "*F0" = "Check-OverallHealth" }
    $customOptions += [ordered]@{ "*HELP" = "Update-HelpText" }
    $customOptions += [ordered]@{ "*BT" = "" }
    $customOptions += [ordered]@{ "*B0" = "Create or Modify domain configs%$($Global:Common.Colors.GenConfigHeader)" }
    $customOptions += [ordered]@{ "C" = "Create New Domain%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)" }
    $customOptions += [ordered]@{ "HC" = "Use this option to create a new domain!" }

    $domainMap = @{}
    $i = 0
    foreach ($item in (Get-DomainList)) {
        $i++
        $stats = Get-DomainStatsLine -DomainName $item

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
        $customOptions += [ordered]@{"#" = "Switch to Main branch%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "H#" = "You are currently on the develop branch. This will exit the script and change back to the official branch" }
    }
    else {
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
        # No-op: host is already on Server 2025+ so no upgrade option is shown.
    }
    else {
        if ($Global:Common.IsAzureVM) {
            $customOptions += [ordered]@{"*BU" = ""; "*UBREAK" = "Host machine needs to be on server 2025 to activate Server 2025 VMs" }
            $customOptions += [ordered]@{ "U" = "Upgrade HOST to server 2025%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)" }
            $customOptions += [ordered]@{ "HU" = "Your host machine is not 2025.  You should upgrade!" }
        }
    }

    return @{ Options = $customOptions; DomainMap = $domainMap }
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

            $customOptions = Build-DomainSubMenuOptions -domain $domain -vms $vms
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
                "d" { Select-DeleteDomain -domain $domain }
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

# Builds the per-domain submenu (VM start/stop, snapshots, dynamic memory,
# danger zone) for Select-DomainMenu. Option visibility depends on current
# VM state and whether any MemLabs snapshots exist.
function Build-DomainSubMenuOptions {
    param(
        [Parameter(Mandatory = $true)] [string] $domain,
        [Parameter(Mandatory = $true)] $vms
    )

    $notRunning = ($vms | Where-Object { $_.State -ne "Running" }).Count
    $running = ($vms | Where-Object { $_.State -eq "Running" }).Count

    $checkPoint = $null
    $DC = $vms | Where-Object { $_.role -eq "DC" }
    if ($DC) {
        $checkPoint = (Get-VMCheckpoint2 -vmname $DC.vmName | where-object { $_.Name -like '*MemLabs*' }).Count
    }

    $customOptions = [ordered]@{
        "*F1"   = "Get-LabVMs -DomainName $domain"
        "*BZ"   = ""
        "*HELP" = "Update-HelpText"
        "*B0"   = ""
        "*B1"   = "VM Management%$($Global:Common.Colors.GenConfigHeader)"
        "M"     = "Modify - Edit or Add VMs to this domain%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)"
        "HM"    = "Use this option to modify the domain, adding new roles, or new VMs"
        "1"     = "Start VMs in domain [$notRunning VMs are not started]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
        "H1"    = "Select any stopped VMs to start.  List will be empty if nothing is stopped."
        "2"     = "Stop VMs in domain  [$running VMs are running]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
        "H2"    = "Select any running VMs to stop.  List will be empty if nothing is running."
        "3"     = "Compact VHDX's in domain%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
        "H3"    = "Select VMs to optimize. Running VMs are cleaned in-guest, then all selected VMs are stopped, checkpoints merged, VHDX free-space zeroed, and Optimize-VHD runs in parallel in a WPF window. VMs that were running at start are auto-restarted when compaction finishes."
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

    $customOptions += [ordered]@{
        "*E"  = ""
        "*B4" = "Dynamic Memory%$($Global:Common.Colors.GenConfigHeader)"
    }
    if ($disabled -ge 1) {
        $customOptions += [ordered]@{
            "E"  = "Enable Dynamic Memory  [$disabled VMs eligible]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
            "HE" = "Select VMs to enable dynamic memory on"
        }
    }
    if ($enabled -ge 1) {
        $customOptions += [ordered]@{
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

    return $customOptions
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

# Shared exit handler for the '!' (return-to-main-menu) and '*' (go-back) paths
# in Select-MainMenu. Both prompt to confirm losing unsaved edits to existing
# VMs, flush the VM cache, and signal the outer loop via a global flag.
#   Mode = 'StartOver' -> sets $global:StartOver (used by '!')
#   Mode = 'GoBack'    -> sets $global:GoBack and stashes $global:SavedConfig (used by '*')
# Returns:
#   $null  - caller should not return; just continue the menu loop
#   $false - caller should "return $false" to leave the menu
function Invoke-MainMenuExit {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('StartOver', 'GoBack')]
        [string] $Mode
    )

    if (Test-AnyExistingVMModified) {
        $response = Read-YesOrNoWithTimeout -Prompt "One or more modified existing machines found. These changes will not be saved. Continue?" -HideHelp -Default "y" -timeout 15
        # NOTE: the existing semantics are inverted vs. what the prompt suggests:
        # answering "y" cancels the exit (caller returns from Select-MainMenu),
        # and answering anything else (incl. "n") *also* cancels but falls back
        # to the menu loop. Either way, when modified, we do NOT proceed to the
        # flag-setting exit path below. We preserve that here.
        if ($response -eq "y") {
            # Signal caller to plain-return (exits Select-MainMenu entirely).
            return 'PlainReturn'
        }
        # Non-"y" -> caller should continue the menu loop without setting flags.
        return $null
    }

    if ($Mode -eq 'StartOver') {
        $global:StartOver = $true
    }
    else {
        $global:GoBack = $true
        $global:SavedConfig = $global:Config
    }
    $global:DisableSmartUpdate = $false
    Get-List -FlushCache
    return $false
}

function Select-MainMenu {
    if (-not $global:existingMachines) {   
        Set-Variable -Scope "Global" -Name "DisableSmartUpdate" -Value $false 
        $global:existingMachines = Get-ExistingVMs -config $global:config        
    }

    while ($true) {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:StartOver = $false
        $global:GoBack = $false
        Set-Variable -Scope "Global" -Name "DisableSmartUpdate" -Value $true
        $global:GenConfigErrorMessages = @()
        # Auto-add a StandaloneRootCA VM if UseOfflineRootCA was enabled but
        # one doesn't exist in this config or in the target domain. Conversely,
        # if UseOfflineRootCA is now disabled, auto-remove any StandaloneRootCA
        # VM that we previously auto-added (user-created ones are preserved).
        try { Add-OfflineRootCAVMIfMissing -ConfigToModify $Global:Config } catch { Write-Log "Add-OfflineRootCAVMIfMissing failed: $_" -LogOnly }
        try { Remove-OfflineRootCAVMIfAutoAdded -ConfigToModify $Global:Config } catch { Write-Log "Remove-OfflineRootCAVMIfAutoAdded failed: $_" -LogOnly }
        $tc = Test-Configuration -InputObject $Global:Config -fast
        Convert-ValidationMessages -TestObject $tc

        # Sort virtualMachines so DC/BDC come first, then everything else by
        # name. Modifies $global:Config in-place. Wrapped in try/catch because
        # very early in startup $global:Config may still be missing.
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

        $built = Build-MainMenuOptions
        $preOptions = $built.PreOptions
        $customOptions = $built.Options
        $vmNameToNumberMap = $built.VMNameToNumberMap

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
                $r = Invoke-MainMenuExit -Mode StartOver
                if ($r -eq 'PlainReturn') { return }
                if ($r -eq $false) { return $false }
            }
            "*" {
                $r = Invoke-MainMenuExit -Mode GoBack
                if ($r -eq 'PlainReturn') { return }
                if ($r -eq $false) { return $false }
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

# Builds the VM Deployment Menu (Select-MainMenu's menu): Global Options pre-list,
# Existing VMs (already deployed), VMs to be deployed, then Add VM / Save /
# Deploy / Quit / debug actions. Returns:
#   @{ PreOptions = <ordered>; Options = <ordered>; VMNameToNumberMap = <string->name> }
# VMNameToNumberMap lets the caller's default-case dispatch translate the
# numbered VM shortcuts back into VM names.
#
# Reads $global:Config, $global:existingMachines, $InternalUseOnly, $enableDebug.
function Build-MainMenuOptions {
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
    $VMNameToNumberMap = @{}
    $i = 0

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

    if ($global:config.virtualMachines) {
        foreach ($virtualMachine in $global:config.virtualMachines | Where-Object { -not $_.Hidden }) {
            if ($null -eq $virtualMachine) {
                continue
            }
            $i = $i + 1
            $name = Get-VMString -config $global:config -virtualMachine $virtualMachine -colors
            $customOptions += [ordered]@{"-D$i" = "$name" }
            $customOptions += [ordered]@{"H$i" = "Modify the installation properties for $($virtualMachine.Vmname). Press [Del] to remove. This is a new VM that has not yet deployed." }
            $VMNameToNumberMap[$i.ToString()] = $virtualMachine.vmName
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

    return @{
        PreOptions        = $preOptions
        Options           = $customOptions
        VMNameToNumberMap = $VMNameToNumberMap
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

