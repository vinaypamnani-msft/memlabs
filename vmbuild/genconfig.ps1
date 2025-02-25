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
    Write-WhiteI "Default Password for all accounts is: " -NoNewline
    Write-Host2 -foregroundColor $Global:Common.Colors.GenConfigNotice "$($Global:Common.LocalAdmin.GetNetworkCredential().Password)"
    Write-Host
    get-list -type vm | Where-Object { $_.Role -eq "DC" } | Format-Table domain, adminName , @{Name = "Password"; Expression = { $($Common.LocalAdmin.GetNetworkCredential().Password) } } | out-host
}

Function Select-PasswordMenu {
    #Write-Log -Activity "Show Passwords"    
    $customOptions = [ordered]@{"*F" = "Show-Passwords" }
    $response = Get-Menu2 -MenuName "Show Passwords" -AdditionalOptions $customOptions -Prompt "Press Enter" -HideHelp:$true -test:$false               
}
Function Select-ToolsMenu {

    while ($true) {
        #Write-Log -Activity "Tools Menu"
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
                    #Write-Log -SubActivity "Tool Selection"
                    $tool = Get-Menu2 -MenuName "Tool Selection" -Prompt "Select tool to Install" -OptionArray $toolList -NoNewLine -test:$false -return -MultiSelect
                    if (-not $tool -or $tool -eq "ESCAPE" -or $tool -eq "NOITEMS") {
                        break
                    }
                    while ($true) {
                        #$customOptions2 = [ordered]@{"A" = "All VMs" }
                        $runningVMs = get-list -type vm | Where-Object { $_.State -eq "Running" } | Select-Object -ExpandProperty vmName | Sort-Object
                        #Write-Log -SubActivity "Tool deployment VM Selection"
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
                    #Write-Log -SubActivity "Optional Tool Selection"
                    $tool = Get-Menu2 -MenuName "Optional Tool Selection" -Prompt "Select Optional tool to Copy" -OptionArray $opt -NoNewLine -test:$false -return -MultiSelect
                    if (-not $tool -or $tool -eq "ESCAPE" -or $tool -eq "NOITEMS") {
                        break
                    }
                    while ($true) {
                        #$customOptions2 = [ordered]@{"A" = "All VMs listed above" }
                        $runningVMs = get-list -type vm | Where-Object { $_.State -eq "Running" } | Select-Object -ExpandProperty vmName | Sort-Object
                        #Write-Log -SubActivity "Optional Tool deployment VM Selection"
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

function Get-PendingVMs {

    $pending = get-list -type VM | Where-Object { $_.InProgress -eq "True" }
    $actualPending = @()
    foreach ($vm in $pending) {
        $mtx = New-Object System.Threading.Mutex($false, $vm.vmName)
        write-log -Verbose "Created Mutex $($vm.vmName)"
        if ($mtx.WaitOne(1)) {
            try {
                [void]$mtx.ReleaseMutex()
            }
            catch {}
            try {
                [void]$mtx.Dispose()
            }
            catch {}            
            write-log -Verbose "Acquired Mutex $($vm.vmName)"
            $actualPending += $vm
        }               
    }
    return $actualPending
}


function Check-OverallHealth {

    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'Continue'

    $Indent = 3
    $disk = Get-Volume -DriveLetter E
    $diskTotalGB = $([math]::Round($($disk.Size / 1GB), 0))
    $diskFreeGB = $([math]::Round($($disk.SizeRemaining / 1GB), 0))

    $vmList = Get-List -Type VM
    $vmsRunning = ($vmList | Where-Object { $_.State -eq "Running" } | Measure-Object).Count
    $vmsTotal = ($vmList | Measure-Object).Count
    
    # Running VMs
    if ($vmsTotal -eq 0) {
        Write-OrangePoint2 -indent $Indent "No VMs are currently deployed"
    }
    else {

        if ($vmsRunning -eq 0) {
            Write-RedX -indent $Indent "No VMs are currently running. $vmsRunning/$vmsTotal total"
        }
        else {
            if ($vmsRunning -eq $vmsTotal) {
                Write-GreenCheck -indent $Indent "All $vmsTotal VMs are running"
            }
            else {
                Write-OrangePoint2 -indent $Indent "$vmsRunning/$vmsTotal VMs are running"
            }    
        }
    }
    # Available Disk

    if ($diskFreeGB -ge 700) {
        Write-GreenCheck -indent $Indent "Drive E: free space is $($diskFreeGB)GB/$($diskTotalGB)GB"
    }
    else {
        if ($diskFreeGB -ge 300) {
            Write-OrangePoint2 -indent $Indent "Drive E: free space is $($diskFreeGB)GB/$($diskTotalGB)GB"
        }
        else {
            Write-RedX -indent $Indent "Drive E: free space is $($diskFreeGB)GB/$($diskTotalGB)GB"
        }
    }

    #Available Memory

    $os = Get-Ciminstance Win32_OperatingSystem | Select-Object @{Name = "FreeGB"; Expression = { [math]::Round($_.FreePhysicalMemory / 1mb, 0) } }, @{Name = "TotalGB"; Expression = { [int]($_.TotalVisibleMemorySize / 1mb) } }
    $availableMemory = $os.FreeGB

    if ($availableMemory -ge 40) {
        Write-GreenCheck -indent $Indent "Available memory: $($availableMemory)GB/$($os.TotalGB)GB"
    }
    else {
        if ($availableMemory -ge 20) {
            Write-OrangePoint2 -indent $Indent "Available memory: $($availableMemory)GB/$($os.TotalGB)GB"
        }
        else {
            Write-RedX -indent $Indent "Available memory: $($availableMemory)GB/$($os.TotalGB)GB"
        }
    }
    
    $today = Get-Date
    $firstDayOfMonth = Get-Date -Year $today.Year -Month $today.Month -Day 1
    $firstTuesday = $firstDayOfMonth.AddDays((([int][DayOfWeek]::Tuesday) - [int]$firstDayOfMonth.DayOfWeek + 7) % 7)
    $secondTuesday = $firstTuesday.AddDays(7)
    
    if ($today.Date -eq $secondTuesday.Date) {

        $rebootedInLast12Hours = $false
        $timeSinceLastReboot = (get-uptime).hours

        if ($timeSinceLastReboot -le 12) {
            $rebootedInLast12Hours = $true
        }
   
        if ($rebootedInLast12Hours) {
            #$hotfixCount = (Get-HotFix | Where-Object { $_.InstalledOn -eq (Get-Date).Date }).Count           
            Write-GreenCheck -indent $Indent "It's patch Tuesday, Machine was rebooted $($timeSinceLastReboot) hours ago."           
        }
        else {
            Write-RedX -indent $Indent "It's patch Tuesday, your machine will likely reboot today at 2-3 PM EST."
        }

    }

    Write-Host
    $Global:ProgressPreference = $OriginalProgressPreference

}

function Select-ConfigMenu {
    $Global:EnterKey = $true
    clear-host
    while ($true) {
  
        $domainCount = (get-list -Type UniqueDomain | Measure-Object).Count
        $customOptions = [ordered]@{}

        $customOptions += [ordered]@{ "*C9" = "   ┌─────────       Quick Stats      ────────┒%MediumPurple" }
        $customOptions += [ordered]@{ "*F0" = "Check-OverallHealth" }
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
            $customOptions += [ordered]@{"$i" = "$($item.PadRight(22," ")) $stats%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)" }
            $customOptions += [ordered]@{ "H$($i)" = "Manage or edit $item" }
            $domainMap[$i] = $item
        }

        if ($null -ne $Global:SavedConfig) {
            $customOptions += [ordered]@{"!" = "Restore In-Progress configuration [$($Global:SavedConfig.VmOptions.DomainName)]%Yellow" }
            $customOptions += [ordered]@{ "H!" = "You have a configuration in progress. Use this to go back and edit it." }
        }
        $customOptions += [ordered]@{"*B" = ""; "*BREAK" = "Load Config ($configDir)%$($Global:Common.Colors.GenConfigHeader)" }
        $customOptions += [ordered]@{"L" = "Load saved config from File %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        $customOptions += [ordered]@{ "HL" = "You can find all your previously saved configuration files here" }
        if ($Global:common.Devbranch) {
            $customOptions += [ordered]@{"X" = "Load TEST config from File (develop branch only)%$($Global:Common.Colors.GenConfigHidden)%$($Global:Common.Colors.GenConfigHiddenNumber)"; }
            $customOptions += [ordered]@{ "HX" = "Here you can find some preconfigured test configuration files." }
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
            $customOptions += [ordered]@{ "H#" = "Like the bleeding edge? Try testing out the new featues in the development branch" }
        }
        $pendingCount = (Get-PendingVMs | Measure-Object).Count

        if ($pendingCount -gt 0 ) {
            $customOptions += @{"F" = "Delete ($($pendingCount)) Failed/In-Progress VMs (These may have been orphaned by a cancelled deployment)%$($Global:Common.Colors.GenConfigFailedVM)%$($Global:Common.Colors.GenConfigFailedVMNumber)" }
            $customOptions += [ordered]@{ "HF" = "Uh oh.. Looks like a deployment may have failed.  Delete the failed VMs and start over!" }
        }

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
        
        $response = Get-Menu2 -MenuName "MemLabs Main Menu" -Prompt "Select menu option" -AdditionalOptions $customOptions -NoNewLine -test:$false

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
            "r" { New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$true }
            "f" { Select-DeletePending }
            "d" { 
                $SelectedConfig = Select-DomainMenu
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
                if ($response -as [int] -is [int]) {
                    if ($domainMap[([int]$response)]) {
                        $SelectedConfig = Select-DomainMenu -DomainName $domainMap[([int]$response)]
                    }
                }
                
            }
        }
        if ($SelectedConfig -and $SelectedConfig -ne "ESCAPE") {
            Write-Verbose "SelectedConfig : $SelectedConfig"
            $global:existingMachines = $null
            if (-not $SelectedConfig.VirtualMachines) {

                #Add-ErrorMessage -Warning "Config is invalid, as it does not contain any new or modified virtual machines."

                return $SelectedConfig
            }
            else {
                return $SelectedConfig
            }
        }
    }
}

function Show-Networks {
    $networks = Get-EnhancedNetworkList
    ($networks | Select-Object Network, Domain, SiteCodes, "Virtual Machines" | Format-Table | Out-String).Trim() | out-host
}
function  Select-NetworkMenu {
    #get-list -type network | out-host
    #Write-Log -Activity "Display Networks"
    
    $customOptions = [ordered]@{"*F" = "Show-Networks" }
    $response = Get-Menu2 -MenuName "Display Networks" -Prompt "Press Enter" -OptionArray $subnetlistEnhanced -AdditionalOptions $customOptions -HideHelp:$true -test:$false
    if (-not $response) {
        return
    }
}

function Show-VMS {

    $vms = get-list -type vm
    if (-not $vms) {
        Write-RedX "No VMs currently deployed"
        return
    }

    #Write-Log -Activity "Currently Deployed VMs"
    ($vms | Select-Object VmName, Domain, State, Role, SiteCode, DeployedOS, @{E = { "$($_.DynamicMinRam)-$($_.Memory)" }; L = "Memory" }, DiskUsedGB, SqlVersion, LastKnownIP | Sort-Object -property VmName | Format-Table | Out-String).Trim() | out-host
}
function Select-VMMenu {

    Write-Verbose "2 Select-VMMenu"
    while ($true) {
       
       
        $customOptions = [ordered]@{"*F" = "Show-VMS" }
        $response = Get-Menu2 -MenuName "Currently Deployed VMs" -Prompt "Press Enter" -AdditionalOptions $customOptions -HideHelp:$true -test:$false

        write-Verbose "1 response $response"
        if (-not $response -or $response -eq "ESCAPE") {
            return
        }
      
    }
}
function List-VMsInDomain {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string] $DomainName
    )
    #Write-Log -Activity "$domain Resources"
    $vmsInDomain = get-list -type vm  -DomainName $domain
    if (-not $vmsInDomain) {
        return
    }
    ($vmsInDomain | Select-Object VmName, State, Role, SiteCode, DeployedOS, @{E = { "$($_.DynamicMinRam)-$($_.Memory)" }; L = "Memory" }, DiskUsedGB, SqlVersion | Format-Table | Out-String).Trim() | out-host
}
function Select-DomainMenu {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string] $DomainName
    )

   
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($DomainName)) {
            # Write-Log -Activity "Domain Management Menu" -NoNewLine
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
            if ([string]::isnullorwhitespace($domain)) {
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
                "*F1" = "List-VMsInDomain -DomainName $domain" 
                "*B1" = "VM Management%$($Global:Common.Colors.GenConfigHeader)";
                "M"   = "Modify - Edit or Add VMs to this domain%$($Global:Common.Colors.GenConfigNewVM)%$($Global:Common.Colors.GenConfigNewVM)"
                "HM"  = "Use this option to modify the domain, adding new roles, or new VMs"
                "1"   = "Start VMs in domain [$notRunning VMs are not started]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)";
                "H1"  = "Select any stopped VMs to start.  List will be empty if nothing is stopped."
                "2"   = "Stop VMs in domain  [$running VMs are running]%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)";
                "H2"  = "Select any running VMs to stop.  List will be empty if nothing is running."
                "3"   = "Compact VHDX's in domain%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)";
                "H3"  = "Select any VMs to optimize. This will run Optimize-VHD, and will stop the VM"
                "*S"  = ""
                "*B2" = "Snapshot Management%$($Global:Common.Colors.GenConfigHeader)"
                "S"   = "Snapshot all VM's in domain%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
                "HS"  = "Create a Hyper-V snapshot/checkpoint of the domain.  All VMs will be stopped, then restarted"
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
            $customOptions += [ordered]@{"*Z" = ""; "*B3" = "Danger Zone%$($Global:Common.Colors.GenConfigHeader)"; "D" = "Delete VMs in Domain%$($Global:Common.Colors.GenConfigDangerous)%$($Global:Common.Colors.GenConfigDangerous)" }
            $response = Get-Menu2 -MenuName "$domain Management Menu" -Prompt "Select domain options" -AdditionalOptions $customOptions -test:$false -return

            write-Verbose "1 response $response"
            if (-not $response -or $response -eq "ESCAPE") {
                return
            }

            switch ($response.ToLowerInvariant()) {
                "2" { $result = Select-StopDomain -domain $domain }
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
                "m" { return Show-ExistingNetwork2 -domainName $domain }
                Default {}
            }
        }
    }
}




function Optimize-VHDX {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Optimize")]
        [object] $VMs
    )

    foreach ($vm in $VMs) {
        stop-vm2 -name $vm.vmName 
        foreach ($hd in Get-VHD -VMId $vm.VmId) {
            #    Mount-VHD -Path $hd.Path
            try {
                Mount-VHD -Path $hd.Path -ReadOnly -ErrorAction Stop
                Optimize-VHD -Path $hd.Path -Mode Full -ErrorAction Continue
            }
            finally {
                Dismount-VHD -Path $hd.Path
            }
        }
    }
}



function select-OptimizeDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Optimize")]
        [string] $domain
    )

    $CustomOptions = @{}
    $vms = get-list -type vm -DomainName $domain -SmartUpdate

    $vmsname = $vms | Select-Object -ExpandProperty vmName
    #$customOptions = [ordered]@{"A" = "Stop All VMs" ; "N" = "Stop non-critical VMs (All except: DC/SiteServers/SQL)"; "C" = "Stop Critical VMs (DC/SiteServers/SQL)" }
    
    $response = Get-Menu2 -MenuName "Select VMs to Optimize in $domain" -Prompt "Select VM to Stop" -additionalOptions $CustomOptions -OptionArray $vmsname -test:$false -MultiSelect
        
    if ($response -eq "ESCAPE" -or $response -eq "NOITEMS") {
        return "ESCAPE"
    }
    $sizeBefore = (Get-List -type vm -domain $domain | measure-object -sum DiskUsedGB).sum
    write-Host "Total size of VMs in $domain before optimize: $([math]::Round($sizeBefore,2))GB"
    $VmList = $vms | Where-Object { $_.VmName -in $response }
    Optimize-VHDX -VMs $VmList
    
    Remove-Item -Path $common.CachePath -include "*.Json" -Recurse    
    get-list -type VM -SmartUpdate -ResetCache | out-null
    $sizeAfter = (Get-List -type vm -domain $domain | measure-object -sum DiskUsedGB).sum
    write-Host "Total size of VMs in $domain after optimize: $([math]::Round($sizeAfter,2))GB"
    write-host
    Write-Host "$domain has been stopped and optimized. Make sure to restart the domain if neccessary."

}






function Select-DeletePending {


    Write-Log -Activity "These VMs are currently 'in progress', if there is no deployment running, you should delete them and redeploy"
    get-list -Type VM -SmartUpdate | Where-Object { $_.InProgress -eq "True" } | Format-Table -Property vmname, Role, SiteCode, DeployedOS, @{E = { "$($_.DynamicMinRam)-$($_.Memory)" }; L = "Memory" }, @{Label = "DiskUsedGB"; Expression = { [Math]::Round($_.DiskUsedGB, 2) } }, State, Domain, Network, SQLVersion | Out-Host
    Write-WhiteI "Please confirm these VM's are not currently in process of being deployed."
    Write-OrangePoint "Selecting 'Yes' will permantently delete all VMs and scopes."
    $response = Read-YesorNoWithTimeout -Prompt "Are you sure? (y/N)" -HideHelp -timeout 180 -Default "n"
    if (-not [String]::IsNullOrWhiteSpace($response)) {
        if ($response.ToLowerInvariant() -eq "y" -or $response.ToLowerInvariant() -eq "yes") {
            Remove-InProgress
            Get-List -type VM -SmartUpdate | Out-Null
        }
    }
}
function get-VMOptionsSummary {

    $options = $Global:Config.vmOptions
    if ($null -eq $options.timeZone) {
        $currentTimeZone = (Get-TimeZone).Id
        $options | Add-Member -MemberType NoteProperty -Name "timeZone" -Value $currentTimeZone -Force
    }
    if ($null -eq $options.locale) {
        $options | Add-Member -MemberType NoteProperty -Name "locale" -Value "en-US" -Force
    }
    $domainName = "[$($options.domainName)]".PadRight(21)
    $Output = "$domainName [Prefix $($options.prefix)] [Network $($options.network)] [Username $($options.adminName)] [Location $($options.basePath)] [TZ $($options.timeZone)] [Locale $($options.locale)]"
    $MaxWidth = ($host.UI.RawUI.WindowSize.Width - 34)
    if ($Output.Length -ge $MaxWidth) {
        $Output = $Output.Substring(0, $MaxWidth - 3) + "..."
    }
    return $Output
}

function get-CMOptionsSummary {
    $fixedConfig = $Global:Config.virtualMachines | Where-Object { -not $_.hidden }
    $options = $Global:Config.cmOptions
    $ver = "[$($options.version)]".PadRight(21)
    $license = "[Licensed]"
    if ($options.EVALVersion -or $options.version -eq "tech-preview") {
        $license = "[EVAL]"
    }
    $pki = "[EHTTP]"
    if ($options.UsePKI) {
        $pki = "[PKI]"
    }
    if ($options.OfflineSCP) {
        $scp = "Offline"
        $baselineVersion = (Get-CMBaselineVersion -CMVersion $options.version).baselineVersion
        $ver = "[$($baselineVersion )]".PadRight(21)
    }
    else {
        $scp = "Online"
    }
    $offlineSUP = ""
    $testSystem = $fixedConfig | Where-Object { $_.installSUP }
    if ($testSystem) {
        if ($options.OfflineSUP) {
            $offlineSUP = "[SUP: Offline]"
        }
    }
    $Output = "$ver [Install $($options.install)] [Push Clients $($options.pushClientToDomainMembers)] $license $pki [SCP: $scp] $offlineSUP"
    return $Output
}

function get-VMSummary {

    $vms = $Global:Config.virtualMachines

    $numVMs = ($vms | Measure-Object).Count
    $numDCs = ($vms | Where-Object { $_.Role -in ("DC", "BDC") } | Measure-Object).Count
    $numDPMP = ($vms | Where-Object { $_.installDP -or $_.enablePullDP } | Measure-Object).Count
    $numPri = ($vms | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count
    $numSec = ($vms | Where-Object { $_.Role -eq "Secondary" } | Measure-Object).Count
    $numCas = ($vms | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
    $numMember = ($vms | Where-Object { $_.Role -eq "WorkgroupMember" -or $_.Role -eq "AADClient" -or $_.Role -eq "InternetClient" -or ($_.Role -eq "DomainMember" -and $null -eq $_.SqlVersion) } | Measure-Object).Count
    $numSQL = ($vms | Where-Object { $_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion } | Measure-Object).Count
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
    if ($numSec -gt 0 ) {
        $RoleList += "[Secondary]"
    }
    if ($numDPMP -gt 0 ) {
        $RoleList += "[DPMP]"
    }
    if ($numSQL -gt 0 ) {
        $RoleList += "[$numSQL SQL]"
    }
    if ($numMember -gt 0 ) {
        $RoleList += "[$numMember Member(s)]"
    }
    $num = "[$numVMs VM(s)]".PadRight(21)
    $Output = "$num $RoleList"
    if ($numVMs -lt 4) {
        $Output += " {$(($vms | Select-Object -ExpandProperty vmName) -join ",")}"
    }
    return $Output
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
        Write-Log -Verbose "Checking if $($vmName) is in ExistingMahcines"
        if ($vmName -in $existingMachines.vmName) {
            $existingMachines = @($existingMachines | Where-Object { $_.vmName -ne $vmName })
        }
    }

    foreach ($evm in $existingMachines) {
        
        if ($null -ne $evm.memLabsDeployVersion) {
            $evm.PsObject.Members.Remove("memLabsDeployVersion")
        }
        if ($null -ne $evm.memLabsVersion) {
            $evm.PsObject.Members.Remove("memLabsVersion")
        }
        if ($null -ne $evm.domainDefaults) {
            $evm.PsObject.Members.Remove("domainDefaults")
        }
        if ($null -ne $evm.success) {
            $evm.PsObject.Members.Remove("success")
        }
        if ($null -ne $evm.vmBuild) {
            $evm.PsObject.Members.Remove("vmBuild")
        }
        if ($null -ne $evm.deployedOS) {
            $evm.PsObject.Members.Remove("deployedOS")
        }
        if ($null -ne $evm.switch) {
            $evm.PsObject.Members.Remove("switch")
        }
        if ($null -ne $evm.vmBuild) {
            $evm.PsObject.Members.Remove("vmBuild")
        }
        if ($null -ne $evm.success) {
            $evm.PsObject.Members.Remove("success")
        }
        if ($null -ne $evm.source) {
            $evm.PsObject.Members.Remove("source")
        }
        if ($null -ne $evm.memoryGB) {
            $evm.PsObject.Members.Remove("memoryGB")
        }
        if ($null -ne $evm.memoryStartupGB) {
            $evm.PsObject.Members.Remove("memoryStartupGB")
        }
        if ($null -ne $evm.memLabsDeployVersion) {
            $evm.PsObject.Members.Remove("memLabsDeployVersion")
        }
        if ($null -ne $evm.inProgress) {
            $evm.PsObject.Members.Remove("inProgress")
        }
        if ($null -ne $evm.lastUpdate) {
            $evm.PsObject.Members.Remove("lastUpdate")
        }
        if ($null -ne $evm.DiskUsedGB) {
            $evm.PsObject.Members.Remove("DiskUsedGB")
        }
        if ($evm.SqlVersion -and $null -eq $evm.sqlInstanceName) {
            $evm | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"  -force
        }
    }



    return $existingMachines
}

function Get-GenericHelp {
    param(
        $text       
    )

    switch (($text -split "=")[0].Trim()) {
        "DeploymentType" { "Selects the default type of deployment, Primary, Heirarchy, or Technical Preview" }
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
        "AdminName" { "Change the default administrator name for all machines and domains. Not reccommended to change." }
        "BasePath" { "Change the location to save hyper-v VHDX and other files. Not reccommended to change." }
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
        "Role" { "Change the role of the VM. Not reccommended to change." }
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
        "InstallSMSProv" { "Install an additonal SMS Provider on this machine (Along with the ADK)" }
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
        "AdditionalDisks" { "This is the list of additional disks created during deployment. You can configure thier sizes here." }
        "SiteName" { "This is the display name of the site in configuration manager" }
        "RemoteSQLVM" { "This is the name of the SQL VM that will host databases used by roles on this VM" }
        "AlwaysOnGroupName" { "Display name for the SQL AO Availability Group" }
        "AlwaysOnListenerName" { "DNS Name of the listener used by SQL AO. This would be the name you use to connect to SQL" }
        "ClusterName" { "Intenal name used by Clustering to setup the SQL AO cluster. Must be unique" }
        "fileServerVM" { "FileServer VM used by SQL AO for its quorum data" }
        "OtherNode" { "This is a link to the other node of the SQL AO cluster. Not reccommended to change" }
        "vmGeneration" { "Sets the Hyper-V VM generation. Only available on OSD clients, all other VMs are gen 2" }
        "ParentSiteCode" { "Sets the parent site code for siteservers or sitesystems" }
        "pullDPSourceDP" { "Sets the source Distribution point for this PullDP" }
        default { "Help Missing for $text" }
    }
    
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
        Set-Variable -Scope "Global" -Name "DisableSmartUpdate" -Value $true
        $tc = Test-Configuration -InputObject $Global:Config -fast
        Convert-ValidationMessages -TestObject $tc
        $preOptions = [ordered]@{}
        #$preOptions += [ordered]@{ "*F0" = "$null = Test-Configuration -InputObject $Global:Config" }
        $preOptions += [ordered]@{ "*F1" = "Show-GenConfigErrorMessages" }
        $preOptions += [ordered]@{ "*B" = "Global Options%$($Global:Common.Colors.GenConfigHeader)" }
        $preOptions += [ordered]@{ "V" = "Global VM Options `t $(get-VMOptionsSummary) %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigHelpHighlight)" }
        $preOptions += [ordered]@{ "HV" = "Change Global Options, such as domain name, netbios name, timezone, etc" }
        if ($Global:Config.cmOptions) {
            $preOptions += [ordered]@{"C" = "Global ConfigMgr Options `t $(get-CMOptionsSummary) %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigHelpHighlight)" }
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
                $customOptions += [ordered]@{"$i" = "$name" }
                $customOptions += [ordered]@{"H$i" = "Modify the properties of the already deployed VM named $($existingVM.vmName). Only some properties can be adjusted." }
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
            write-Log "Exception from global:Config.virtualMachines: $($global.Config)"

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
                $customOptions += [ordered]@{"$i" = "$name" }
                $customOptions += [ordered]@{"H$i" = "Modify the installation properties for $($virtualMachine.Vmname). This is a new VM that has not yet deployed." }
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
        $response = Get-Menu2 -MenuName $MenuName -Prompt "Select menu option" -OptionArray $optionArray -AdditionalOptions $customOptions -preOptions $preOptions -Test:$false -
        write-Verbose "response $response"
        if ($response -eq "ESCAPE") {
            $response = "!"
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
                #Write-Log -Activity -NoNewLine "Global VM Options Menu"
                Select-Options -MenuName "Global VM Options Menu" -Rootproperty $($Global:Config) -PropertyName vmOptions -prompt "Select Global Property to modify" -HelpFunction "Get-GenericHelp"
            }
            "c" { 
                #Write-Log -Activity -NoNewLine "Global Configuration Manager Menu"
                Select-Options -MenuName "Global Configuration Manager Menu"  -Rootproperty $($Global:Config) -PropertyName cmOptions -prompt "Select ConfigMgr Property to modify" -HelpFunction "Get-GenericHelp"
            }
            "d" {
                foreach ($virtualMachine in $global:existingMachines) {
                    if (get-IsExistingVMModified -virtualMachine $virtualMachine) {
                        Add-ModifiedExistingVMToDeployConfig -vm $virtualMachine -configToModify $global:config -hidden:$true
                    }
                }
                $global:DisableSmartUpdate = $false
                return $true
            }
            "s" {
                $global:DisableSmartUpdate = $false
                return $false 
            }
            "r" {
                foreach ($virtualMachine in $global:existingMachines) {
                    if (get-IsExistingVMModified -virtualMachine $virtualMachine) {
                        Add-ModifiedExistingVMToDeployConfig -vm $virtualMachine -configToModify $global:config -hidden:$true
                    }
                }
                $c = Test-Configuration -InputObject $Global:Config
                $global:DebugConfig = $c.DeployConfig
                write-Host 'Debug Config stored in $global:DebugConfig'
                $global:DisableSmartUpdate = $false
                return $global:DebugConfig
            }
            "!" {
                $modified = $false
                foreach ($virtualMachine in $global:existingMachines) {
                    if (get-IsExistingVMModified -virtualMachine $virtualMachine) {
                        $modified = $true
                    }
                }
                $response = "y"
                if ($modified) {
                    $response = Read-YesorNoWithTimeout -Prompt "One or more modified existing machines found. These changes will not be saved. Continue?" -HideHelp -Default "y" -timeout 15
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
            "n" { Select-VirtualMachines $response }
            default { 
                # This will be a VM number, or 'N' for new VM

                Select-VirtualMachines $vmNameToNumberMap[$response] 
            }
        }
    }
}



function Get-NewMachineName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM to rename")]
        [object] $vm,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "ClusterName")]
        [switch] $ClusterName,
        [Parameter(Mandatory = $false, HelpMessage = "AlwaysOnName")]
        [switch] $AOName,
        [Parameter(Mandatory = $false, HelpMessage = "Skip 1 in machine name")]
        [switch] $SkipOne
    )

    #Get-PSCallStack | Out-Host

    $Domain = $vm.vmOptions.DomainName
    $OS = $vm.OperatingSystem
    $SiteCode = $vm.SiteCode
    $CurrentName = $vm.vmName
    $Role = $vm.Role
    $RoleName = $vm.Role
    if ($Role -eq "OSDClient") {
        $RoleName = "OSD"
    }
    if ($Role -eq "BDC") {
        $RoleName = "DC"
    }
    if ($Role -eq "DomainMember" -or [string]::IsNullOrWhiteSpace($Role) -or $Role -eq "WorkgroupMember" -or $Role -eq "AADClient" -or $role -eq "InternetClient") {
        if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
            $RoleName = "Mem"
        }
        else {
            $RoleName = "Member"
        }

        if ($OS -like "*Server*") {
            if ($vm.SqlVersion) {
                $RoleName = "SQL"
            }
            else {
                if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
                    $RoleName = "Srv"
                }
                else {
                    $RoleName = "Server"
                }
            }

        }
        else {
            if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
                $RoleName = "Cli"
            }
            else {
                $RoleName = "Client"
            }


        }


        if ($Role -eq "WorkgroupMember") {
            $RoleName = "WG"
        }
        if ($Role -eq "InternetClient") {
            $RoleName = "INT"
        }
        if ($Role -eq "AADClient") {
            $RoleName = "AAD"
        }
        if ($Role -eq "FileServer") {
            $RoleName = "FS"
        }
        Write-Verbose "Rolename is now $RoleName"

        if ($OS -like "Windows 10*") {

            $RoleName = "W10" + $RoleName
        }
        if ($OS -like "Windows 11*") {

            $RoleName = "W11" + $RoleName
        }

        switch ($OS) {
            "Server 2025" {

                $RoleName = "W25" + $RoleName
            }
            "Server 2022" {

                $RoleName = "W22" + $RoleName
            }
            "Server 2019" {

                $RoleName = "W19" + $RoleName
            }
            "Server 2016" {

                $RoleName = "W16" + $RoleName
            }
            Default {}
        }
    }

    if (($role -eq "Primary") -or ($role -eq "CAS") -or ($role -eq "PassiveSite") -or ($role -eq "Secondary")) {
        if ([String]::IsNullOrWhiteSpace($SiteCode)) {
            $newSiteCode = Get-NewSiteCode $Domain -Role $Role -ConfigToCheck $ConfigToCheck
        }
        else {
            $newSiteCode = $SiteCode
        }
        $NewName = $newSiteCode + "SITE"
        if ($role -eq "PassiveSite") {
            $NewName = $NewName + "-P"
        }
        return $NewName
    }

    if ($role -eq "DomainMember" -and $vm.SQLVersion) {
        foreach ($existing in $configToCheck.VirtualMachines) {
            if ($existing.RemoteSQLVM -eq $vm.vmName -and $existing.Role -in "CAS", "Primary") {
                $RoleName = $existing.SiteCode + "SQL"
                $SkipOne = $true
            }
        }
    }

    if ($role -eq "WSUS") {
        if ($vm.installSUP) {
            $RoleName = $siteCode + "SUP"
        }
        else {
            $RoleName = $role
        }
    }

    if ($role -eq "SiteSystem") {
        $RoleName = ""

        if ($vm.installDP -or $vm.enablePullDP) {

            if ($vm.enablePullDP) {
                $RoleName = $RoleName + "PDP"
            }
            else {
                $RoleName = $RoleName + "DP"
            }
        }
        if ($vm.installMP) {
            $RoleName = $RoleName + "MP"
        }

        if ($vm.installRP) {
            $RoleName = $RoleName + "RP"
        }

        if ($vm.installSUP) {
            $RoleName = $RoleName + "SUP"
        }

        if ($RoleName -eq "") {
            $RoleName = "SITESYS"
        }

        $RoleName = $siteCode + $RoleName

        if ((($($ConfigToCheck.vmOptions.Prefix) + $RoleName).Length) -gt 14) {
            $RoleName = $SiteCode + "SITESYS"
        }

    }
    if ($Role -eq "FileServer") {
        $RoleName = "FS"

    }

    if ($Role -eq "SQLAO") {
        if ($ClusterName) {
            $RoleName = "SqlCluster"
        }
        if ($AoName) {
            $RoleName = "AlwaysOn"
        }
    }

    [int]$i = 1
    while ($true) {
        if ($SkipOne -and $i -eq 1) {
            $NewName = $RoleName
        }
        else {
            $NewName = $RoleName + ($i)
        }

        if ($NewName -eq $vm.vmName) {
            break
        }
        if ($null -eq $ConfigToCheck) {
            write-log "Config is NULL..  Machine names will not be checked. Please notify someone of this bug."
            #break
        }
        if (($ConfigToCheck.virtualMachines | Where-Object { ($_.vmName -eq $NewName -or $_.AlwaysOnListenerName -eq $NewName -or $_.ClusterName -eq $NewName) -and $NewName -ne $CurrentName } | Measure-Object).Count -eq 0) {

            $newNameWithPrefix = ($ConfigToCheck.vmOptions.prefix) + $NewName
            if ((Get-List -Type VM | Where-Object { $_.vmName -eq $newNameWithPrefix -or $_.ClusterName -eq $newNameWithPrefix -or $_.AlwaysOnListenerName -eq $newNameWithPrefix } | Measure-Object).Count -eq 0) {
                break
            }
        }
        write-log -verbose "$newName already exists [$CurrentName].. Trying next"
        $i++
    }
    return $NewName.ToUpper()
}

function Get-NewSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Role of the machine CAS/Primary")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )

    $usedSiteCodes = @()
    $usedSiteCodes += (get-list -type VM -domain $Domain | Where-Object { $_.SiteCode }).SiteCode
    if ($ConfigToCheck.VirtualMachines) {
        $usedSiteCodes += ($ConfigToCheck.VirtualMachines | Where-Object { $_.SiteCode }).Sitecode
    }

    if ($Role -eq "CAS") {
        $siteCodePrefix = "CS"
        $siteCodePrefix2 = "C"
    }
    if ($role -eq "Primary") {
        $siteCodePrefix = "PS"
        $siteCodePrefix2 = "P"
    }

    if ($role -eq "Secondary") {
        $siteCodePrefix = "SS"
        $siteCodePrefix2 = "S"
    }

    for ($i = 1; $i -lt 10; $i++) {
        if ($i -ge 10) {
            $desiredSiteCode = $siteCodePrefix2 + $i
        }
        else {
            $desiredSiteCode = $siteCodePrefix + $i
        }
        if ($desiredSiteCode -in $usedSiteCodes) {
            continue
        }
        return $desiredSiteCode
    }

}


function get-PrefixForDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain
    )

    $existingDomains = get-list -Type UniqueDomain
    if ($existingDomains -contains $Domain) {
        $existingPrefix = (Get-List -type VM -DomainName $domain | Where-Object { $_.Role -eq "DC" }).Prefix

        if (-not [string]::IsNullOrWhiteSpace($existingPrefix)) {
            return $existingPrefix
        }
    }
    $ValidDomainNames = Get-ValidDomainNames
    $prefix = $($ValidDomainNames[$domain])
    if ([String]::IsNullOrWhiteSpace($prefix)) {
        $prefix = ($domain.ToUpper().SubString(0, 3) + "-") -replace "\.", ""
    }
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = "NULL-"
    }
    return $prefix

}


function select-timezone {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )

    $commonTimeZones = @()
    $commonTimeZones += $((Get-TimeZone).Id)
    $commonTimeZones += "Pacific Standard Time"
    $commonTimeZones += "Central Standard Time"
    $commonTimeZones += "Eastern Standard Time"
    $commonTimeZones += "Mountain Standard Time"
    $commonTimeZones += "UTC"
    $commonTimeZones += "Central Europe Standard Time"
    $commonTimeZones += "China Standard Time"
    $commonTimeZones += "Tokyo Standard Time"
    $commonTimeZones += "India Standard Time"
    $commonTimeZones += "Russian Standard Time"

    $commonTimeZones = $commonTimeZones | Select-Object -Unique
    #Write-Log -Activity "Timezone Selection" -NoNewLine
    $timezone = Get-Menu2 -MenuName "Timezone Selection" -Prompt "Select Timezone" -OptionArray $commonTimeZones -CurrentValue $($ConfigToCheck.vmOptions.timezone) -additionalOptions @{"F" = "Display Full List" }
    if ($timezone -eq "F") {
        Write-Log -Activity "Full Timezone Selection" -NoNewLine
        $timezone = Get-Menu -Prompt "Select Timezone" -OptionArray $((Get-TimeZone -ListAvailable).Id) -CurrentValue $($ConfigToCheck.vmOptions.timezone) -test:$false
    }
    return $timezone
}
function Select-Locale {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )

    # default locale is en-US
    $commonLocales = @()
    $commonLocales += "en-US"

    # add selection if locale configuration file exists
    $localeConfigPath = Join-Path $Common.ConfigPath "_localeConfig.json"
    if (Test-Path $localeConfigPath) {
        try {
            $localeConfig = Get-Content -Path $localeConfigPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $localeConfig.psobject.Properties | ForEach-Object {
                $commonLocales += $_.Name
            }
        }
        catch {
            Write-Log "Something wrong with _localeConfig.json. Only en-US is available."
        }
    }

    $commonLanguages = $commonLanguages | Select-Object -Unique
    #Write-Log -Activity "Locale Menu using _localeConfig.json" -NoNewLine
    $locale = Get-Menu2 -MenuName "Locale Menu using _localeConfig.json"  -Prompt "Select Locale" -OptionArray $commonLocales -CurrentValue $($ConfigToCheck.vmOptions.locale)
    if ($null -eq $locale -or $locale -eq "ESCAPE") {
        $locale = $($ConfigToCheck.vmOptions.locale)
    }
    return $locale
}
function select-NewDomainName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )

    #Write-Log -Activity "Select a pre-approved domain name from the list, or use 'C' for a custom name." -NoNewLine
    if (-not $ConfigToCheck -or $ConfigToCheck.virtualMachines.role -contains "DC") {
        while ($true) {
            $ValidDomainNames = Get-ValidDomainNames
            $CurrentValue = (($ValidDomainNames).Keys | sort-object { $_.Length } | Select-Object -first 1) 
            if ($ConfigToCheck.domainDefaults.DomainName) {
                $CurrentValue = $ConfigToCheck.domainDefaults.DomainName
                if (-not ($($ConfigToCheck.domainDefaults.DomainName) -in ($ValidDomainNames.Keys))) {
                    $prefix = get-PrefixForDomain -Domain $ConfigToCheck.domainDefaults.DomainName
                    $ValidDomainNames.Add($ConfigToCheck.domainDefaults.DomainName, $prefix)
                }                        
            }
            if ($ConfigToCheck.vmOptions.DomainName) {
                $CurrentValue = $ConfigToCheck.vmOptions.DomainName
                if (-not ($($ConfigToCheck.vmoptions.DomainName) -in ($ValidDomainNames.Keys))) {
                    $ValidDomainNames.Add($ConfigToCheck.vmOptions.DomainName, $ConfigToCheck.vmOptions.Prefix)
                }                        
            }

                    
            $domain = $null
            $customOptions = @{ "C" = "Custom Domain" }

            while (-not $domain -and $domain -ne "ESCAPE") {
                $domain = Get-Menu2 -MenuName "Select a pre-approved domain name from the list, or use 'C' for a custom name." -Prompt "Select Domain" -OptionArray $($ValidDomainNames.Keys | Sort-Object { $_.length }) -additionalOptions $customOptions -CurrentValue $CurrentValue -Test:$false

                if ($domain -eq "ESCAPE") {
                    return
                }
                if ($domain -and ($domain.ToLowerInvariant() -eq "c")) {
                    write-host
                    write-host
                    $domain = Read-Host2 -Prompt "Enter Custom Domain Name (eg test.com):"
                    if (-not $domain.Contains(".")) {
                        Write-Host
                        Write-RedX -ForegroundColor FireBrick "domainName value [$($domain)] is invalid. You must specify the Full Domain name. For example: contoso.com"
                        $domain = $null
                        continue
                    }

                    # valid domain name
                    $pattern = "^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,6}$"
                    if (-not ($domain -match $pattern)) {
                        Write-Host
                        Write-RedX -ForegroundColor FireBrick "domainName value [$($domain)] contains invalid characters, is too long, or too short. You must specify a valid Domain name. For example: contoso.com."
                        $domain = $null
                        continue
                    }
                }
                if ($domain.Length -lt 3) {
                    $domain = $null
                }
            }
            if ($domain -and $domain -ne "ESCAPE") {
                if ((get-list -Type UniqueDomain) -contains $domain.ToLowerInvariant()) {
                    Write-Host
                    Write-RedX -ForegroundColor FireBrick "Domain is already in use. Please use the Expand option to expand the domain"
                    continue
                }
            }
            if ($domain -eq "ESCAPE") {
                if ($ConfigToCheck.vmOptions.DomainName) {
                    return $ConfigToCheck.vmOptions.DomainName
                }                
            }

            return $domain
        }
    }
    else {
        $existingDomains = @()
        $existingDomains += get-list -Type UniqueDomain
        if ($existingDomains.count -eq 0) {
            Write-Host
            Write-Host "No DC configured, and no existing domains found. Please Ctrl-C to start over and create a new domain"
            return
        }
        $domain = $null
        while (-not $domain -and $domain -ne "ESCAPE") {
            #Write-Log -Activity "Existing Domains Selection" -NoNewLine
            $domain = Get-Menu2 -MenuName "Existing Domains Selection" -Prompt "Select Domain" -OptionArray $existingDomains -CurrentValue $ConfigToCheck.vmoptions.domainName -test:$false
        }
        return $domain
    }
}

function Show-NewDomainTip {
    Write-Host
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigTip "  Tip: You can enable Configuration Manager High Availability by editing the properties of a CAS or Primary VM, and selecting ""H"""
}
function Select-DeploymentType {
    $response = $null

    $customOptions = [ordered]@{"*F1" = "Show-NewDomainTip" }
    $customOptions += [ordered]@{"*B1" = ""; "*BREAK1" = "DeploymentType%$($Global:Common.Colors.GenConfigHeader)" }
    $customOptions += [ordered]@{ 
        "1"  = "CAS and Primary %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" 
        "H1" = "Inital VM list will contain a CAS and Primary server for Configuration Manager"
    }
    $customOptions += [ordered]@{ 
        "2"  = "Primary Site only %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)"
        "H2" = "Inital VM list will contain only a Primary server for Configuration Manager"
    }
    $customOptions += [ordered]@{
        "3"  = "Tech Preview (NO CAS)%$($Global:Common.Colors.GenConfigTechPreview)"
        "H3" = "Inital VM list will contain only Tech Preview Primary server for Configuration Manager"
    }
    $customOptions += [ordered]@{ 
        "4"  = "No ConfigMgr%$($Global:Common.Colors.GenConfigNoCM)" 
        "H4" = "Inital VM list will not contain any ConfigMgr components"
    }


    $response = $null
    while (-not $response) {       

        $response = Get-Menu2 -MenuName "New Domain Wizard - Change Deployment type" -Prompt "Select type of deployment" -AdditionalOptions $customOptions -test:$false -return
        if ([string]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE") {
            return
        }      
        switch ($response.ToLowerInvariant()) {
            "1" {
                return "CAS and Primary"
            }     
            "2" {
                return "Primary Site only"
            }     
            "3" {
                return "Tech Preview (NO CAS)"
            }     
            "4" {
                return "No ConfigMgr"
            } 
        }    
                
    }
    
}

function Get-NewDomainConfigHelp {
    param(
        $text       
    )

    switch (($text -split "=")[0].Trim()) {
        "DeploymentType" { "Selects the default type of deployment, Primary, Heirarchy, or Technical Preview" }
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
        default { "Help Missing for $text" }
    }
    
}

function Select-NewDomainConfig {


    $valid = $false


    $templateDomain = "TEMPLATE2222.com"
    $newconfig = New-UserConfig -Domain $templateDomain -Subnet "10.234.241.0"
    $subnetlist = Get-ValidSubnets

    $Latestversion = Get-CMLatestBaselineVersion
    $domainDefaults = [PSCustomObject]@{
        DeploymentType      = "Primary Site only"
        CMVersion           = $Latestversion
        DomainName          = ((Get-ValidDomainNames).Keys | sort-object { $_.Length } | Select-Object -first 1)
        Network             = ($subnetList | Select-Object -First 1)
        DefaultClientOS     = "Windows 11 Latest"
        DefaultServerOS     = "Server 2022"
        DefaultSqlVersion   = "Sql Server 2022"
        UseDynamicMemory    = $true
        IncludeClients      = $true
        IncludeSSMSOnNONSQL = $true
    }
    $newconfig | Add-Member -MemberType NoteProperty -name "domainDefaults" -Value $domainDefaults -Force


    #write-log -Activity "New Domain Wizard - Default Settings"
    #Select-Options -Rootproperty $($Global:Config) -PropertyName vmOptions -prompt "Select Global Property to modify" 
    #$additionalOptions = [ordered]@{"*HF" = "Get-NewDomainConfigHelp"}
    $result = Select-Options -MenuName "New Domain Wizard - Default Settings" -Rootproperty $newConfig -PropertyName domainDefaults -prompt "Select Default Property to modify" -ContinueMode:$true -additionalOptions $additionalOptions -HelpFunction "Get-NewDomainConfigHelp"

    if ($result -eq "ESCAPE") {
        return $result
    }
    
    #write-log -Activity "New Domain Wizard"
 

    $valid = $false
    while ($valid -eq $false) {
        

        $test = $false
        $version = $null
        write-log -verbose "Deploying type: $($newconfig.domainDefaults.DeploymentType)"
        switch ($newconfig.domainDefaults.DeploymentType) {
            "CAS and Primary" {
                Add-NewVMForRole -Role "DC" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -Quiet:$true -test:$test
                Add-NewVMForRole -Role "CAS" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -SiteCode "CS1" -Quiet:$true -test:$test
                if ($newconfig.domainDefaults.CMVersion -eq "tech-preview") {
                    $newconfig.domainDefaults.CMVersion = $Latestversion
                }
            }

            "Primary Site only" {
                Add-NewVMForRole -Role "DC" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -Quiet:$true -test:$test
                Add-NewVMForRole -Role "Primary" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -SiteCode "PS1" -Quiet:$true -test:$test
                if ($newconfig.domainDefaults.CMVersion -eq "tech-preview") {
                    $newconfig.domainDefaults.CMVersion = $Latestversion
                }                

            }
            "Tech Preview (NO CAS)" {
                if ($newconfig.domainDefaults.CMVersion -ne "tech-preview") {
                    $newconfig.domainDefaults.CMVersion = "tech-preview"
                }

                $usedPrefixes = Get-List -Type UniquePrefix
                if ("CTP-" -notin $usedPrefixes) {
                    $prefix = "CTP-"
                    $newconfig.domainDefaults.DomainName = "techpreview.com"
                }
                Add-NewVMForRole -Role "DC" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -Quiet:$true -test:$test
                Add-NewVMForRole -Role "Primary" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -SiteCode "CTP" -Quiet:$true -test:$test
                                              
            }
            "No ConfigMgr" {
                Add-NewVMForRole -Role "DC" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -Quiet:$true -test:$test
            }
        }
        $valid = $true
        if ($test) {
            $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
        }

        if ($valid) {
            $valid = $false
            while ($valid -eq $false) {
                if (-not $newconfig.domainDefaults.DomainName) {
                    $result = select-NewDomainName -ConfigToCheck $newConfig
                    if (-not [string]::IsNullOrEmpty($result) -and $result -ne "ESCAPE") {                        
                        $newconfig.domainDefaults.DomainName = $result
                    }
                    else {
                        continue
                    }
                }
                if (-not $prefix) {
                    $prefix = get-PrefixForDomain -Domain $newconfig.domainDefaults.DomainName
                }
                Write-Verbose "Prefix = $prefix"
                $newConfig.vmOptions.domainName = $newconfig.domainDefaults.DomainName
                $newConfig.vmOptions.prefix = $prefix
                $netbiosName = $newconfig.domainDefaults.DomainName.Split(".")[0]
                $newConfig.vmOptions.DomainNetBiosName = $netbiosName
                if ($newconfig.domainDefaults.CMVersion -and $newConfig.cmOptions.version) {
                    $newConfig.cmOptions.version = $newconfig.domainDefaults.CMVersion
                }
                if ($domain -in ((Get-ValidDomainNames).Keys)) {
                    $valid = $true
                }
                else {
                    $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
                }
                if (-not $valid) {
                    $domain = $null
                }
            }
        }

        if ($newconfig.domainDefaults.IncludeClients) {
            Add-NewVMForRole -Role "DomainMember" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultClientOS -Quiet:$true -test:$test
            Add-NewVMForRole -Role "DomainMember" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultClientOS -Quiet:$true -test:$test
        }


        if ($valid) {
           
            $newConfig.vmOptions.network = $newconfig.domainDefaults.network
            $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
        }
        
    }
    return $newConfig
}

Function Get-ConfigFiles {
    param(
        [string] $ConfigPath,
        [switch] $SortByName
    )
  
    if (-not (Test-Path $ConfigPath)) {
        write-log "No files found in $configPath"
        return
    }
   
    $files = @()
    $files += Get-ChildItem $ConfigPath\*.json -Include "Standalone.json", "Hierarchy.json" | Sort-Object -Property Name -Descending
    $files += Get-ChildItem $ConfigPath\*.json -Include "TechPreview.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "NoConfigMgr.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "AddToExisting.json"
    $files += Get-ChildItem $ConfigPath\*.json -Exclude "_*", "Hierarchy.json", "Standalone.json", "AddToExisting.json", "TechPreview.json", "NoConfigMgr.json" | Sort-Object -Descending -Property LastWriteTime


    if ($SortByName) {
        $files = $files | sort-Object -Property Name
    }
    return $files
}

function Show-ConfigLegend {
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigJsonGood "  == Green  - Fully Deployed"
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigJsonBad  "  == Red    - Partially Deployed"
    Write-Host2 -ForegroundColor  $Global:Common.Colors.GenConfigNoCM    "  == Brown  - Not Deployed - New Domain"
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigNormal   "  == Normal - Not Deployed - Needs existing domain" 
    Write-Host2
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


    #Write-Log -Activity "Select Config File to load"
    $SortByName = $false
    if ($ConfigPath.EndsWith("tests")) {
        $SortByName = $true
    }    
        
    $responseValid = $false
    while ($responseValid -eq $false) {
        $optionArray = @()


        If ($SortByName) {
            Write-Log -SubActivity "Viewing config files located in $ConfigPath -- Sorted by Name"
            $files = Get-ConfigFiles -ConfigPath $ConfigPath -SortByName
        }
        Else {
            Write-Log -SubActivity "Viewing config files located in $ConfigPath -- Sorted by date"
            $files = Get-ConfigFiles -ConfigPath $ConfigPath
        }

        $i = 0
        $currentVMs = Get-List -type VM
        $maxLength = 40
        $MaxWidth = ($host.UI.RawUI.WindowSize.Width - $maxLength - 9)
        
        foreach ($file in $files) {
            $filename = [System.Io.Path]::GetFileNameWithoutExtension($file.Name)
            $len = $filename.Length

            if ($len -gt $maxLength) {
                $maxLength = $len
            }
        }
        foreach ($file in $files) {
            $i = $i + 1
            $savedConfigJson = $null
            $savedNotes = ""
            $color = $Global:Common.Colors.GenConfigNormal
            try {
                $savedConfigJson = Get-Content $file | ConvertFrom-Json
            }
            catch {
                $savedNotes = $_
            }

            $savedNotes = "[" + $file.LastWriteTime.GetDateTimeFormats()[2].PadLeft(8) + "]"

            if ($savedConfigJson) {
                $Found = 0
                $notFound = 0
                foreach ($vm in $savedConfigJson.virtualMachines) {
                    $vmName = $savedConfigJson.vmOptions.Prefix + $vm.vmName
                    if ($currentVms.VmName -contains $vmName) {
                        $Found++
                    }
                    else {
                        $notFound++
                    }
                }
                $hasDC = $savedConfigJson.virtualMachines | Where-Object { $_.role -eq "DC" }
                

                if ($hasDC) {
                    $savedNotes += " [New Domain: $($savedConfigJson.vmoptions.domainName)]"
                    $color = $Global:Common.Colors.GenConfigNoCM
                }
                else {
                    $savedNotes += " [Existing Domain: $($savedConfigJson.vmoptions.domainName)]"
                }
                if ($found -gt 0) {
                    $color = $Global:Common.Colors.GenConfigJsonGood
                    if ($notFound -gt 0) {
                        $color = $Global:Common.Colors.GenConfigJsonBad
                    }
                }
                $savedNotes += "[Deployed: $($Found.ToString().PadRight(2))] [Missing: $($notFound.ToString().PadRight(2))] "
                $savedNotes += "$($savedConfigJson.virtualMachines.VmName -join ", ")"
                
                if ($savedNotes.Length -ge $MaxWidth) {
                    $savedNotes = $savedNotes.Substring(0, $MaxWidth - 3) + "..."
                }
               
            }
            $filename = [System.Io.Path]::GetFileNameWithoutExtension($file.Name)
            $optionArray += $($filename.PadRight($maxLength) + " " + $savedNotes) + "%$color"

        }
        $preOptionsArray = [ordered]@{"*F5" = "Show-ConfigLegend" }

        if ($SortByName) {
            $preOptionsArray += [ordered]@{"S" = "Sort by Date%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        }
        else {
            $preOptionsArray += [ordered]@{"S" = "Sort by Name%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        }
        $customOptions = [ordered]@{}        
        $menuName = "Select Config File to load"

        if ($ConfigPath -like "*tests*") {
            $menuName = "Select TEST Config File to load"
        }
        $response = Get-Menu2 -MenuName $menuName -prompt "Which config do you want to load" -preOptions $preOptionsArray -OptionArray $optionArray -additionalOptions $customOptions -split -test:$false -return

        if ($response.ToLowerInvariant() -eq "s") {
            $SortByName = !$SortByName
            continue
        }

        $responseValid = $true
        if (-not $response -or $response -eq "ESCAPE") {
            return
        }
    }
    $UserConfig = Get-UserConfiguration -Configuration $response
    if ($userConfig.Loaded) {
        Write-GreenCheck "Loaded Configuration: $response" -NoIndent
    }
    else {
        Write-Redx "Failed to load Configuration: $($UserConfig.ConfigPath)" -NoIndent
        return
    }
    $Global:configfile = $UserConfig.ConfigPath


    $configSelected = $UserConfig.config
    #$configSelected = Get-Content $Global:configfile -Force | ConvertFrom-Json

    if ($null -ne $configSelected.vmOptions.domainAdminName) {
        if ($null -eq ($configSelected.vmOptions.adminName)) {
            $configSelected.vmOptions | Add-Member -MemberType NoteProperty -Name "adminName" -Value $configSelected.vmOptions.domainAdminName
        }
        $configSelected.vmOptions.PsObject.properties.Remove('domainAdminName')
    }
    if ($null -ne $configSelected.cmOptions.installDPMPRoles) {
        $configSelected.cmOptions.PsObject.properties.Remove('installDPMPRoles')
        foreach ($vm in $configSelected.virtualMachines) {
            if ($vm.Role -eq "SiteSystem") {
                $vm | Add-Member -MemberType NoteProperty -Name "installDP" -Value $true -Force
                $vm | Add-Member -MemberType NoteProperty -Name "installMP" -Value $true -Force
            }
        }
    }
    if ($vm.Role -eq "SiteSystem") {
        if (-not $vm.InstallSMSProv) {
            $vm | Add-Member -MemberType NoteProperty -Name "InstallSMSProv" -Value $false -Force
        }
    }
    return $configSelected
}

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
        $ExistingDPMPCount = ($ListCache | Where-Object { $_.installDP -or $_.enablePullDP } | Measure-Object).Count
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
            if ([string]::isnullorwhitespace($response) -or $response.ToLowerInvariant() -eq "n") {
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
            #Write-Log -Activity -NoNewLine "Confirm selection of domain $response"
            #$response = Read-YesorNoWithTimeout -Prompt "Modify existing VMs, or Add new VMs to this domain? (Y/n)" -HideHelp -Default "y"
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
        $response = Read-YesorNoWithTimeout -Prompt "$TotalStoppedVMs Critical VM's in this domain are not running. Do you wish to start them now? (Y/n)" -HideHelp -Default "y"
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
    #Write-Log -Activity -NoNewLine "Add roles to Existing domain"
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

# Replacement for Read-Host that offers a colorized prompt









Function Get-SupportedOperatingSystemsForRole {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "role")]
        [string] $role,
        [Parameter(Mandatory = $false, HelpMessage = "vm")]
        [object] $vm = $null
    )

    $ServerList = $Common.Supported.OperatingSystems | Where-Object { $_ -like 'Server*' }
    $ClientList = $Common.Supported.OperatingSystems | Where-Object { $_ -notlike 'Server*' }
    $AllList = $Common.Supported.OperatingSystems
    switch ($role) {
        "DC" { return $ServerList }
        "BDC" { return $ServerList }
        "CAS" { return $ServerList }
        "CAS and Primary" { return $ServerList }
        "Primary" { return $ServerList }
        "Secondary" { return $ServerList }
        "FileServer" { return $ServerList }
        "Sqlserver" { return $ServerList }
        "SiteSystem" { return $ServerList }
        "WSUS" { return $ServerList }
        "SQLAO" { return $ServerList }
        "PassiveSite" { return $ServerList }
        "DomainMember" {
            if ($vm -and $vm.SqlVersion) {
                return $ServerList
            }
            else {
                return $AllList
            }
        }
        "DomainMember (Server)" { return $ServerList }
        "DomainMember (Client)" { return $ClientList }
        "WorkgroupMember" { return $AllList }
        "InternetClient" { return $ClientList }
        "AADClient" { return $ClientList }
        "OSDClient" { return $null }
        "Linux" { Return (Get-LinuxImages).name }
        default {
            return $AllList
        }
    }
    return $AllList
}


Function Get-OperatingSystemMenuClient {
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
        $OSList = Get-SupportedOperatingSystemsForRole -role "DomainMember (Client)" 
        if ($null -eq $OSList ) {
            return
        }

        #Write-Log -Activity -NoNewLine "Operating System Selection"

        $OSName = Get-Menu2 -MenuName "Operating System Selection" -Prompt "Select OS Version" -OptionArray $OSList -CurrentValue $CurrentValue -Test:$false -NoClear
        if ($OSName -eq "ESCAPE") {
            return
        }
        $property."$name" = $OSName
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

Function Get-OperatingSystemMenuServer {
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
        $OSList = Get-SupportedOperatingSystemsForRole -role "DomainMember (Server)" 
        if ($null -eq $OSList ) {
            return
        }

        #Write-Log -Activity -NoNewLine "Operating System Selection"

        $OSName = Get-Menu2 -MenuName "Operating System Selection" -Prompt "Select OS Version" -OptionArray $OSList -CurrentValue $CurrentValue -Test:$false -NoClear
        if ($OSName -eq "ESCAPE") {
            return
        }
        $property."$name" = $OSName
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
        $OSList = Get-SupportedOperatingSystemsForRole -role $property.Role -vm $CurrentValue
        if ($null -eq $OSList ) {
            return
        }

        Write-Log -Activity -NoNewLine "Operating System Selection"

        $OSName = Get-Menu2 -MenuName "Operating System Selection" -Prompt "Select OS Version" -OptionArray $OSList -CurrentValue $CurrentValue -Test:$false -NoClear
        if ($OSName -eq "ESCAPE") {
            return
        }
        $property."$name" = $OSName
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

Function Get-ParentSiteCodeMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [String] $role,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [Object] $ConfigToCheck = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "Domain")]
        [string] $Domain
    )

    if ($Role -eq "Primary") {
        $casSiteCodes = Get-ValidCASSiteCodes -config $global:config -domain $Domain

        $additionalOptions = @{ 
            "X"  = "No Parent - Standalone Primary" 
            "HX" = "Configure this VM to be a standalone primary. Not part of a Heirarchy"
        }
        do {
            #Write-Log -Activity -NoNewLine "Primary Server Parent Selection"
            $result = Get-Menu2 -MenuName "Primary Server Parent Selection" -Prompt "Select CAS sitecode to connect primary to" -OptionArray $casSiteCodes -CurrentValue $CurrentValue -additionalOptions $additionalOptions -Test:$false
        } while (-not $result)
        if ($result -and ($result.ToLowerInvariant() -eq "x") -or ($result.ToLowerInvariant() -eq "escape")) {
            return $null
        }
        else {
            return $result
        }
    }
    if ($Role -eq "Secondary") {
        $priSiteCodes = Get-ValidPRISiteCodes -config $global:config -domain $Domain
        if (($priSiteCodes | Measure-Object).Count -eq 0) {
            write-Host "No valid primaries available to connect secondary to."
            return $null
        }
        do {
            Write-Log -Activity -NoNewLine "Secondary Server Parent Selection"
            $result = Get-Menu2 -MenuName "Secondary Server Parent Selection" -Prompt "Select Primary sitecode to connect secondary to" -OptionArray $priSiteCodes -CurrentValue $CurrentValue -Test:$false
        } while (-not $result)
        if ($result -and ($result.ToLowerInvariant() -eq "escape")) {
            return $null
        }
        
        return $result
    }
    return $null
}
Function Set-ParentSiteCodeMenu {
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


        $value = Get-ParentSiteCodeMenu -role $property.role -CurrentValue $CurrentValue -domain $global:config.vmOptions.domainName
        if (-not $value) {
            return
        }
        if ($value.Trim()) {
            $property."$name" = $value
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

Function Get-ValidSiteCodesForRP {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config")]
        [Object] $Config,
        [Parameter(Mandatory = $false, HelpMessage = "Current VM")]
        [Object] $CurrentVM
    )

    $allSiteCodes = @()

    $list2 = Get-List2 -deployConfig $Config

    $allSiteCodes = ($list2 | where-object { $_.role -in ("CAS", "Primary", "SiteSystem") }).SiteCode

    $currentRPs = ($list2 | Where-Object { $_.installRP -and $_.vmName -ne $CurrentVM.vmName } )

    $invalidSiteCodes = @()
    foreach ($rp in $currentRPs) {
        if ($rp.sitecode) {
            $invalidSiteCodes += $rp.siteCode
        }
        else {
            # No SiteCode prop means this is a remoteSQLVM for an existing or new primary/cas
            $SiteServer = $list2 | Where-Object ($_.RemoteSQLVM -eq $rp.vmName -and $_.Role -in "CAS", "Primary")
            if ($SiteServer) {
                if ($SiteServer.SiteCode) {
                    $invalidSiteCodes += $SiteServer.SiteCode
                }
            }
        }
    }

    foreach ($siteCode in $invalidSiteCodes | where-object { $_ }) {
        #write-host "Removing $sitecode"
        $allSiteCodes = $allSiteCodes | where-object { $_ -ne $siteCode }
    }

    return $allSiteCodes
}

Function Get-ValidSiteCodesForWSUS {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config")]
        [Object] $Config,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [Object] $CurrentVM
    )

    $siteCodes = @()

    $list2 = Get-List2 -deployConfig $Config

    $topLevelSiteServers = ($list2 | where-object { $_.role -in ("CAS", "Primary") -and -not $_.ParentSiteCode })


    foreach ($item in $topLevelSiteServers) {

        $existingSUP = $list2 | Where-Object { $_.InstallSUP -and $_.SiteCode -eq $item.SiteCode -and $_.VmName -ne $CurrentVM.VmName }

        if ($existingSUP) {
            if ($item.role -ne "CAS") {
                # If we have an existingSUP on the top level, add the site code only if its a Primary Top Level Site
                $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
            }
            # We have an existingSUP on the top level.. Add all children of the top level site
            $childSiteServers = ($list2 | where-object { $_.role -in ("CAS", "Primary") -and $_.ParentSiteCode -eq $item.SiteCode })
            foreach ($item2 in $childSiteServers) {
                $sitecodes += "$($item2.SiteCode) ($($item2.vmName), $($item2.Network) Parent: $($item.SiteCode))"
            }
        }
        else {
            # We dont have an existing SUP on the top level.. Only add the TopLevel as options. No Children Allowed.
            $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
        }
    }

    return $sitecodes

}
Function Get-SiteCodeForWSUS {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $true, HelpMessage = "Config")]
        [Object] $Config

    )

    $siteCodes = Get-ValidSiteCodesForWSUS

    $result = $null
    $Options = [ordered]@{ "X" = "StandAlone WSUS" }
    while (-not $result) {
        $result = Get-Menu2 -MenuName "Site Code selection for SUP" -Prompt "Select sitecode to connect SUP to" -OptionArray $siteCodes -CurrentValue $CurrentValue -AdditionalOptions $options -Test:$false -Split
    }
    if ($result -and ($result.ToLowerInvariant() -eq "x") -or ($result.ToLowerInvariant() -eq "escape")) {
        return $null
    }
    else {
        return $result
    }

}
#   #Get-PSCallStack | out-host
#   while ($valid -eq $false) {
#       $siteCodes = @()
#       $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "Primary" } )
#       if ($tempSiteCodes) {
#           foreach ($tempSiteCode in $tempSiteCodes) {
#               $siteCodes += "$($tempSiteCode.SiteCode) (New Primary Server - $($tempSiteCode.vmName))"
#           }
#       }
#
#       $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "CAS" })
#       if ($tempSiteCodes) {
#           foreach ($tempSiteCode in $tempSiteCodes) {
#               if (-not [String]::IsNullOrWhiteSpace($tempSiteCode)) {
#                   $siteCodes += "$($tempSiteCode.SiteCode) (New CAS Server - $($tempSiteCode.vmName))"
#               }
#           }
#       }
#       if ($Domain) {
#
#           foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "Primary" | Select-Object SiteCode, Network, VmName -Unique)) {
#               $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
#           }
#
#           foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "CAS" | Select-Object SiteCode, Network, VmName -Unique)) {
#               $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
#           }
#           if ($siteCodes.Length -eq 0) {
#               Write-Host
#               write-host "No valid site codes are eligible to accept this SUP"
#               return $null
#           }
#           else {
#               #write-host $siteCodes
#           }
#           $result = $null
#           $Options = [ordered]@{ "X" = "StandAlone WSUS" }
#           while (-not $result) {
#               $result = Get-Menu -Prompt "Select sitecode to connect SUP to" -OptionArray $siteCodes -CurrentValue $CurrentValue -AdditionalOptions $options -Test:$false -Split
#           }
#           if ($result -and ($result.ToLowerInvariant() -eq "x")) {
#               return $null
#           }
#           else {
#               return $result
#           }
#       }
#   }
#}

Function Get-SiteCodeForDPMP {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [string] $Domain
    )
    $valid = $false
    $ConfigToCheck = $Global:Config
    #Get-PSCallStack | out-host
    while ($valid -eq $false) {
        $siteCodes = @()
        $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "CAS" } )
        if ($tempSiteCodes) {
            foreach ($tempSiteCode in $tempSiteCodes) {
                $siteCodes += "$($tempSiteCode.SiteCode) (New CAS VM - $($tempSiteCode.vmName))"
            }
        }
        $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "Primary" } )
        if ($tempSiteCodes) {
            foreach ($tempSiteCode in $tempSiteCodes) {
                $siteCodes += "$($tempSiteCode.SiteCode) (New Primary VM - $($tempSiteCode.vmName))"
            }
        }
        $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "Secondary" })
        if ($tempSiteCodes) {
            foreach ($tempSiteCode in $tempSiteCodes) {
                if (-not [String]::IsNullOrWhiteSpace($tempSiteCode)) {
                    $siteCodes += "$($tempSiteCode.SiteCode) (New Secondary VM - $($tempSiteCode.vmName))"
                }
            }
        }
        if ($Domain) {
            #$siteCodes += Get-ExistingSiteServer -DomainName $Domain -Role "Primary" | Select-Object -ExpandProperty SiteCode -Unique
            #$siteCodes += Get-ExistingSiteServer -DomainName $Domain -Role "Secondary" | Select-Object -ExpandProperty SiteCode -Unique
            foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "Primary" | Select-Object SiteCode, Network, VmName -Unique)) {
                $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
            }
            foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "Secondary" | Select-Object SiteCode, Network, VmName -Unique)) {
                $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
            }

            foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "CAS" | Select-Object SiteCode, Network, VmName -Unique)) {
                $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
            }
            $siteCodes = $siteCodes | Get-Unique

            if ($siteCodes.Length -eq 0) {
                Write-Host
                write-host "No valid site codes are eligible to accept this Site System"
                return $null
            }
            else {
                #write-host $siteCodes
            }
            $result = $null
            while (-not $result) {
                #Write-Log -Activity -NoNewLine "Site System SiteCode Selection"
                $result = Get-Menu2 -MenuName "Site System SiteCode Selection" -Prompt "Select sitecode to connect Site System to" -OptionArray $siteCodes -CurrentValue $CurrentValue -Test:$false -Split
            }
            if ($result -and ($result.ToLowerInvariant() -eq "x") -or ($result.ToLowerInvariant() -eq "escape")) {
                return $null
            }
            else {
                return $result
            }
        }
    }
}
Function Get-SiteCodeMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [Object] $ConfigToCheck = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [bool] $test = $true
    )

    if ($property.Role -eq "SiteSystem") {
        #Get-PSCallStack | out-host
        $result = Get-SiteCodeForDPMP -CurrentValue $CurrentValue -Domain $configToCheck.vmoptions.domainName
    }

    if ($property.Role -eq "WSUS") {
        $result = Get-SiteCodeForWSUS -CurrentValue $CurrentValue -Config $configToCheck
    }

    if (-not $result) {
        return
    }
    if ($result.ToLowerInvariant() -eq "x") {
        $property.PsObject.Members.Remove($name)
    }
    else {
        $property | Add-Member -MemberType NoteProperty -Name $name -Value $result -Force
        #$property."$name" = $result
    }
    try {
        if ($test -and (Get-TestResult -config $configToCheck -SuccessOnWarning)) {
            return
        }
        else {
            if ($property."$name" -eq $CurrentValue) {
                return
            }
        }
    }
    catch {
        return
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
        #Write-Log -Activity -NoNewLine "Sql Server Version Selection for $($property.VmName)"
        $SQLVer = Get-Menu2 -MenuName "Sql Server Version Selection for $($property.VmName)" "Select SQL Version" $($Common.Supported.SqlVersions) $CurrentValue -Test:$false
        if ($SQLVer -eq "ESCAPE") {
            return
        }
        $property."$name" = $SQLVer
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $CurrentValue) {
                return
            }
        }
    }
}

Function Get-ForestTrustMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )


    $domains = @(Get-List -Type UniqueDomain)
    $domains += "NONE"
    $valid = $false
    while ($valid -eq $false) {
        #Write-Log -Activity "Forest Trust Menu for domain $($global:Config.vmoptions.DomainName)" -NoNewLine
        $result = Get-Menu2 -MenuName "Forest Trust Menu for domain $($global:Config.vmoptions.DomainName)" "Select Forest to Trust" $($domains) $CurrentValue -Test:$false
        if ($result -eq "ESCAPE") {
            return
        }
        $property."$name" = $result

        if ($result -ne "NONE") {
            $remoteCA = (get-list -type vm -DomainName $result | Where-Object { $_.Role -eq "DC" } | Select-Object InstallCA).InstallCA
            if ($remoteCA) {
                Write-OrangePoint "Domain $result already has a CA. Disabling CA in this domain"
                $property.InstallCA = $false
            }
            Get-TargetSitesForDomain $property $result
        }
        else {
            $property.psobject.properties.remove('externalDomainJoinSiteCode')
            $property.InstallCA = $true
        }
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $CurrentValue) {
                return
            }
        }
    }
}

Function Get-TargetSitesForDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Domain To get Target Sites")]
        [string] $Domain
    )

    $targetPrimaries = @((Get-list -type vm -DomainName $Domain | Where-Object { $_.Role -eq "Primary" -or $_.Role -eq "Secondary" } ).SiteCode)

    if ($targetPrimaries) {
        $targetPrimaries += "NONE"
        $valid = $false
        while ($valid -eq $false) {
            #$property.externalDomainJoinSiteCode
            #Write-Log -Activity -NoNewLine "Remote domain Management Server for this domains clients"
            $result = Get-Menu2 -MenuName "Remote domain Management Server for this domains clients" -Prompt "Select Target site code in $Domain to configure to manage clients in this domain" -OptionArray $($targetPrimaries) -CurrentValue "NONE" -Test:$false
            if ($result -eq "ESCAPE") {
                if ($property.externalDomainJoinSiteCode) {
                    $result = $property.externalDomainJoinSiteCode
                }
                else {
                    $result = "NONE"
                }
                $property | Add-Member -MemberType NoteProperty -Name "externalDomainJoinSiteCode" -Value $result -Force
                return
            }   
            $property | Add-Member -MemberType NoteProperty -Name "externalDomainJoinSiteCode" -Value $result -Force

            if (Get-TestResult -SuccessOnWarning) {
                return
            }
        }
    }
}

Function Set-SiteServerLocalSql {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Site Server VM Object")]
        [Object] $virtualMachine
    )

    if ($null -eq $virtualMachine.sqlVersion) {

        $SqlVersion = "SQL Server 2022"
        if ($ConfigToModify.domainDefaults.DefaultSqlVersion) {
            $SqlVersion = $ConfigToModify.domainDefaults.DefaultSqlVersion
        }
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value $SqlVersion -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "F:\SQL" -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlPort' -Value "1433" -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $true -force
        
    }
    if ($virtualMachine.Role -eq "WSUS" -or $virtualMachine.Role -eq "SiteSystem") {
        $virtualMachine.virtualProcs = 4
        $virtualMachine.memory = "6GB"
    }
    else {
        $virtualMachine.virtualProcs = 8
        $virtualMachine.memory = "10GB"
    }


    if ($null -eq $virtualMachine.additionalDisks) {
        $disk = [PSCustomObject]@{"E" = "600GB"; "F" = "100GB" }
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
    }
    else {

        if ($null -eq $virtualMachine.additionalDisks.E) {
            $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name "E" -Value "600GB" -force
        }
        if ($null -eq $virtualMachine.additionalDisks.F) {
            $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name "F" -Value "200GB" -force
        }
    }

    if ($null -ne $virtualMachine.remoteSQLVM) {
        $SQLVM = $virtualMachine.remoteSQLVM
        $virtualMachine.PsObject.Members.Remove('remoteSQLVM')
        if ($SQLVM.OtherNode) {
            Remove-VMFromConfig -vmName $SQLVM.OtherNode -Config $global:config
        }
        Remove-VMFromConfig -vmName $SQLVM -Config $global:config

    }

}

Function Set-SiteServerRemoteSQL {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Site Server VM Object")]
        [Object] $virtualMachine,
        [Parameter(Mandatory = $true, HelpMessage = "VmName")]
        [string] $vmName
    )

    if ($null -ne $virtualMachine.sqlVersion) {
        $virtualMachine.PsObject.Members.Remove('sqlVersion')
        $virtualMachine.PsObject.Members.Remove('sqlInstanceName')
        $virtualMachine.PsObject.Members.Remove('sqlInstanceDir')
        $virtualMachine.PsObject.Members.Remove('sqlPort')
        if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
        }
    }
    $virtualMachine.memory = "4GB"
    $virtualMachine.dynamicMinRam = "4GB"
    if ($global:Config.domainDefaults.UseDynamicMemory) {
        $virtualMachine.dynamicMinRam = "1GB"
    }

    $virtualMachine.virtualProcs = 4
    if ($null -ne $virtualMachine.additionalDisks.F) {
        $virtualMachine.additionalDisks.PsObject.Members.Remove('F')
    }
    if ($null -ne $virtualMachine.remoteSQLVM) {
        $oldSQLVM = $global:Config.VirtualMachines | Where-Object { $_.vmName -eq $virtualMachine.remoteSQLVM }
        {
            if ($oldSQLVM) {
                $oldSQLVM.PsObject.Members.Remove('installRP')
            }
        }
        $virtualMachine.PsObject.Members.Remove('remoteSQLVM')
    }
    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'remoteSQLVM' -Value $vmName -force
    $newSQLVM = $global:Config.VirtualMachines | Where-Object { $_.vmName -eq $vmName }
    if ($newSQLVM) {
        if (-not $newSQLVM.InstallRP) {
            if ($newSQLVM.role -ne "SQLAO") {
                $newSQLVM | Add-Member -MemberType NoteProperty -Name 'installRP' -Value $false -force
                $newSQLVM | Add-Member -MemberType NoteProperty -Name 'InstallSMSProv' -Value $false -force
            }
        }
    }
}
Function Get-WsusDBName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $false, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $valid = $false
    while ($valid -eq $false) {
        $additionalOptions = [ordered]@{ 
            "L"  = "Local SQL (Installed on this Server)" 
            "HL" = "Add a SQL instance to this VM that WSUS will use"
        }
        $additionalOptions += [ordered] @{ 
            "N"  = "Remote SQL (Create a new SQL VM)" 
            "HN" = "Add a new VM with SQL installed that WSUS will use"
        }
        $additionalOptions += [ordered] @{ 
            "W"  = "Use Local WID for SQL"
            "HW" = "WSUS will use WID (Windows Internal Database) for its database"
        }



        $validVMs = @($Global:Config.virtualMachines | Where-Object { ($_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion) } | Select-Object -ExpandProperty vmName)

        $ActiveVM = Get-ActiveSiteServerForSiteCode -deployConfig $Global:Config -SiteCode $property.siteCode -type VM

        $sql = Get-SqlServerForSiteCode -siteCode $property.SiteCode -deployConfig $Global:Config -type VM
        if (-not $ActiveVM.InstallSUP) {
            if (-not $sql.InstallSUP) {
                $validVMs += $($sql.vmName)
            }
        }
        $validVMs = $validVMs | Get-Unique

        $result = Get-Menu2 -MenuName "Select WSUS SQL" -Prompt "Select SQL Options" -OptionArray $($validVMs) -CurrentValue $CurrentValue -Test:$false -additionalOptions $additionalOptions -return

        if (-not $result -or $result -eq "ESCAPE") {
            return "REFRESH"
        }
        switch ($result.ToLowerInvariant()) {
            "l" {
                Set-SiteServerLocalSql $property
                $property."$name" = $property.VmName
                $valid = $true
            }
            "n" {
                $VMname = $($property.SiteCode) + "WSUSSQL"
                Add-NewVMForRole -Role "SqlServer" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $VMname -network:$property.network
                $property."$name" = $VMname
                $valid = $true
                #Set-SiteServerRemoteSQL $property $name
                $property.psobject.properties.remove('sqlversion')
                $property.psobject.properties.remove('sqlInstanceDir')
                $property.psobject.properties.remove('sqlInstanceName')
                $property.psobject.properties.remove('sqlPort')
                $property.psobject.properties.remove('SqlServiceAccount')
                $property.psobject.properties.remove('SqlAgentAccount')
                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                    $property | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                }
            }
            "w" {
                $property.psobject.properties.remove('sqlversion')
                $property.psobject.properties.remove('sqlInstanceDir')
                $property.psobject.properties.remove('sqlInstanceName')
                $property.psobject.properties.remove('sqlPort')
                $property.psobject.properties.remove('SqlServiceAccount')
                $property.psobject.properties.remove('SqlAgentAccount')
                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                    $property | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                }
                $property."$name" = "WID"
                $valid = $true
            }
            Default {
                if ([string]::IsNullOrWhiteSpace($result)) {
                    continue
                }
                $property."$name" = $result
                $valid = $true
                $property.psobject.properties.remove('sqlversion')
                $property.psobject.properties.remove('sqlInstanceDir')
                $property.psobject.properties.remove('sqlInstanceName')
                $property.psobject.properties.remove('sqlPort')
                $property.psobject.properties.remove('SqlServiceAccount')
                $property.psobject.properties.remove('SqlAgentAccount')
                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                    $property | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                }
            }
        }

    }
}
Function Get-remoteSQLVM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $false, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $additionalOptions = [ordered]@{ 
            "L"  = "Local SQL (Installed on this Server)"
            "HL" = "Add a SQL instance to this VM"
        }

        $validVMs = $Global:Config.virtualMachines | Where-Object { ($_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion) -or ($_.Role -eq "SQLAO" -and $_.OtherNode ) } | Select-Object -ExpandProperty vmName

        $CASVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "CAS" }
        $PRIVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Primary" }

        if ($Property.Role -eq "CAS") {
            if ($null -ne $PRIVM.remoteSQLVM) {
                #Write-Verbose "Checking "
                $validVMs = $validVMs | Where-Object { $_ -ne $PRIVM.remoteSQLVM }
            }
        }
        if ($Property.Role -eq "Primary") {
            if ($null -ne $CASVM.remoteSQLVM) {
                $validVMs = $validVMs | Where-Object { $_ -ne $CASVM.remoteSQLVM }
            }
        }

        #if (($validVMs | Measure-Object).Count -eq 0) {

        if ($property.Role -eq "WSUS") {
            $additionalOptions += [ordered] @{ 
                "R"  = "Remote SQL"
                "HR" = "Opens a menu to select a Remote SQL VM to use"
            }
            $additionalOptions += [ordered] @{ 
                "W"  = "Use Local WID for SQL"
                "HW" = "WSUS will use WID (Windows Internal Database) as its database"
            }
            Write-Log -Activity -NoNewLine "WSUS SQL Server Options"
        }
        else {
            $additionalOptions += [ordered] @{ 
                "N"  = "Remote SQL (Create a new SQL VM)"
                "HN" = "A new VM with SQL installed will be added to the configuration"
            }
            $additionalOptions += [ordered] @{ 
                "A"  = "Remote SQL Always On Cluster (Create a new SQL Cluster)" 
                "HA" = "A pair of SQLAO VMs will be added to the configuration"
            }
            Write-Log -Activity -NoNewLine "CM SQL Server Options"
        }
        #}
       
        $result = Get-Menu2 -MenuName "Select SQL" -Prompt "Select SQL Options" -OptionArray $($validVMs) -CurrentValue $CurrentValue -Test:$false -additionalOptions $additionalOptions -return

        if (-not $result -or $result -eq "ESCAPE") {
            return
        }
        switch ($result.ToLowerInvariant()) {
            "l" {
                Set-SiteServerLocalSql $property
            }
            "n" {
                $name = $($property.SiteCode) + "SQL"
                Add-NewVMForRole -Role "SqlServer" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $name -network:$property.network
                Set-SiteServerRemoteSQL $property $name
            }
            "r" {
                $sqlVMName = select-RemoteSQLMenu -ConfigToModify $global:config -currentValue $property.remoteSQLVM
                if ($sqlVMName -eq "ESCAPE") {
                    return
                }
                #$name = $($property.SiteCode) + "SQL"
                #Add-NewVMForRole -Role "SqlServer" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $name -network:$property.network
                Set-SiteServerRemoteSQL $property $sqlVMName
            }
            "a" {
                $name1 = $($property.SiteCode) + "SQLAO1"
                $name2 = $($property.SiteCode) + "SQLAO2"
                Add-NewVMForRole -Role "SQLAO" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $name1 -Name2 $Name2 -network:$property.network -SiteCode $($property.SiteCode)
                Set-SiteServerRemoteSQL $property $name1
            }
            "w" {
                $virtualMachine.PsObject.Members.Remove('sqlVersion')
                $virtualMachine.PsObject.Members.Remove('sqlInstanceName')
                $virtualMachine.PsObject.Members.Remove('sqlPort')
                $virtualMachine.PsObject.Members.Remove('sqlInstanceDir')
                $virtualMachine.PsObject.Members.Remove('remoteSQLVM')
                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                }

            }
            Default {
                if ([string]::IsNullOrWhiteSpace($result)) {
                    continue
                }
                Set-SiteServerRemoteSQL $property $result
            }
        }
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($null -ne $name) {
                if ($property."$name" -eq $CurrentValue) {
                    return
                }
            }
        }
    }
}

Function Get-domainUser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $users = get-list2 -DeployConfig $Global:Config | Where-Object { $_.domainUser } | Select-Object -ExpandProperty domainUser -Unique
    $valid = $false
    while ($valid -eq $false) {
        $additionalOptions = @{ "N" = "New User" }


        $result = Get-Menu2 -MenuName "Domain User Selection" -Prompt "Select User" -OptionArray $($users) -CurrentValue $CurrentValue -Test:$false -additionalOptions $additionalOptions -return

        if (-not $result -or $result -eq "ESCAPE") {
            return
        }
        switch ($result.ToLowerInvariant()) {
            "n" {
                $result = Read-Host2 -Prompt "Enter desired Username"
            }

            Default {
                if ([string]::IsNullOrWhiteSpace($result)) {
                    if (-not $CurrentValue) {
                        $property.psobject.properties.remove($name)
                    }
                    else {
                        $property | Add-Member -MemberType NoteProperty -Name $name -Value $CurrentValue -force
                    }
                    return
                }
            }
        }
        if ($null -ne $name) {
            $property | Add-Member -MemberType NoteProperty -Name $name -Value $result -force
        }
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($null -ne $name) {
                if ($property."$name" -eq $CurrentValue) {
                    return
                }
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
    $noteColor = $Global:Common.Colors.GenConfigTip

    if ($Global:Config.cmOptions.OfflineSCP) {   
        write-host2 -ForegroundColor $noteColor "Note: "-NoNewLine
        write-host2 "SCP is in OFFLINE mode. Only baseline versions will be shown"
    }


    $cmVersions = @()
    foreach ($cmVersion in $($Common.Supported.CmVersions)) {

        switch ($cmVersion) {
            "current-branch" {
                $latest = Get-CMLatestBaselineVersion
                $cmVersions += "$cmVersion (Installs $latest [Latest Baseline])"
            }

            "Tech-preview" {
                $cmVersions += "$cmVersion (Installs the latest tech preview version of CM)"
            }

            default {
                $baselineVersion = (Get-CMBaselineVersion -CMVersion $cmVersion).baselineVersion
                if ($Global:Config.cmOptions.OfflineSCP) {                    
                    if ($baselineVersion -eq $cmVersion) {
                        $cmVersions += "$cmVersion (baseline)"
                    }
                }
                else {
                    if ($baselineVersion -eq $cmVersion) {
                        $cmVersions += "$cmVersion (baseline)"
                    }
                    else {
                        $cmVersions += "$cmVersion (Upgrade from $baselineVersion)"
                    }
                }
            }
        }

    }

    while ($valid -eq $false) {
        $CMVer = Get-Menu2 -MenuName "CM Version" -Prompt "Select ConfigMgr Version" -optionArray $($cmVersions) -CurrentValue $CurrentValue -Test:$false -split
        if ($CMVer -eq "ESCAPE") {
            return
        }
        $property."$name" = $CMVer
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
        $DC = Get-List -type VM -domain $global:config.vmOptions.domainName | Where-Object { $_.Role -eq "DC" }
        if ($DC) {
            #Write-Log -Activity -NoNewLine "VM role Selection menu for $($property.VmName)"
            $role = Get-Menu2 -MenuName "VM role Selection menu for $($property.VmName)" -prompt "Select Role" -optionArray $(Select-RolesForExistingList) -currentValue $CurrentValue -Test:$false
            if ($role -eq "ESCAPE") {
                return
            }
            $property."$name" = $role
        }
        else {
            Write-Log -Activity -NoNewLine "Role Selection menu for $($property.VmName)"
            $role = Get-Menu2 -MenuName "Role Selection menu for $($property.VmName)" -prompt "Select Role" -optionArray $(Select-RolesForNewList) -currentValue $CurrentValue -Test:$false
            if ($role -eq "ESCAPE") {
                return
            }
            $property."$name" = $role
        }

        # If the value is the same.. Dont delete and re-create the VM
        if ($property."$name" -eq $value) {
            # return false if the VM object is still viable.
            return $false
        }

        # In order to make sure the default params like SQLVersion, CMVersion are correctly applied.  Delete the VM and re-create with the same name.
        Remove-VMFromConfig -vmName $property.vmName -ConfigToModify $global:config
        Add-NewVMForRole -Role $Role -Domain $Global:Config.vmOptions.domainName -ConfigToModify $global:config -Name $property.vmName -Quiet:$true

        # We cant do anything with the test result, as our underlying object is no longer in config.
        Get-TestResult -config $global:config -SuccessOnWarning | out-null

        # return true if the VM is deleted.
        return $true
    }
}

function Rename-VirtualMachine {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $vm,
        [Parameter(Mandatory = $false, HelpMessage = "NewName - AutoGenerated if blank")]
        [string] $newName
    )

    if ($vm.ExistingVM) {
        return
    }
    $rename = $true
    if (-not $newName) {
        $rename = $false
        $newName = Get-NewMachineName -vm $vm
        if ($($vm.vmName) -ne $newName) {
            $rename = $true
            Write-Log -Activity "Proposing to rename $($vm.vmName) to $($newName) due to configuration changes" -NoNewLine
            $response = Read-YesorNoWithTimeout -Prompt "Rename $($vm.vmName) to $($newName)? (Y/n)" -HideHelp -Default "y"
            if (-not [String]::IsNullOrWhiteSpace($response)) {
                if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                    $rename = $false
                }
            }
        }
    }

    if ($rename -eq $true) {

        foreach ($existing in $Global:Config.virtualMachines) {
            if ($existing.RemoteSQLVM -eq $vm.vmName) {
                $existing.RemoteSQLVM = $newName
            }
            if ($existing.remoteContentLibVM -eq $vm.vmName) {
                $existing.remoteContentLibVM = $newName
            }
            if ($existing.FileServerVM -eq $vm.vmName) {
                $existing.FileServerVM = $newName
            }
            if ($existing.pullDPSourceDP -eq $vm.vmName) {
                $existing.pullDPSourceDP = $newName
            }

        }
        $vm.vmName = $newName
        return $newName
    }

}

<#
.SYNOPSIS
Adds an error or warning message to the global GenConfigErrorMessages array.

.DESCRIPTION
The Add-ErrorMessage function is used to add an error or warning message to the global GenConfigErrorMessages array. It takes the message, property, and Warning parameters as input.

.PARAMETER message
Specifies the name of the Notefield to modify.

.PARAMETER property
Specifies the base property object.

.PARAMETER Warning
Specifies whether the message is a warning. If this switch is present, the message will be treated as a warning; otherwise, it will be treated as an error.

.EXAMPLE
Add-ErrorMessage -message "Invalid value" -property "SomeProperty" -Warning
Adds a warning message to the global GenConfigErrorMessages array with the specified message and property.

.EXAMPLE
Add-ErrorMessage -message "Error occurred" -property "AnotherProperty"
Adds an error message to the global GenConfigErrorMessages array with the specified message and property.
#>
function Add-ErrorMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Name of Notefield to Modify")]
        [string] $message,
        [Parameter(Mandatory = $false, HelpMessage = "Base Property Object")]
        [string] $property,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [switch] $Warning
    )

    $level = "ERROR"
    if ($Warning) {
        $level = "WARNING"
    }

    if (-not $global:GenConfigErrorMessages) {
        $global:GenConfigErrorMessages = @()
    }

    if ($global:GenConfigErrorMessages -is [PSCustomObject]) {
        $global:GenConfigErrorMessages = @($global:GenConfigErrorMessages)
    }

    $global:GenConfigErrorMessages += [PSCustomObject]@{
        property = $property
        Level    = $level
        Message  = $message
    }
    Write-Verbose "Add-ErrorMessage $message"
}


function Get-AdditionalValidations {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $value = $property."$($Name)"
    #$name = $($item.Name)
    Write-Verbose "[Get-AdditionalValidations] Prop:'$property' Name:'$name' Current:'$CurrentValue' New:'$value'"
    switch ($name) {
        "E" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            $property.$name = $value.ToUpperInvariant()
        }
        "F" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            $property.$name = $value.ToUpperInvariant()
        }
        "G" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            $property.$name = $value.ToUpperInvariant()
        }
        "dynamicMinRam" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            if (($value / 1) -lt 50MB) {
                #Write-Log "Can not set Memory to less than 50MB"
                Add-ErrorMessage -property $name -Warning "Can not set $name to less than 50MB"
                $value = $CurrentValue
            }
            if (($value / 1) -gt 64GB) {
                Add-ErrorMessage -property $name -Warning "Can not set $name to more than 64GB"
                $value = $CurrentValue
            }
            if (($value / 1) -ge $property.memory / 1 ) {
                Add-ErrorMessage -property $name -Warning "If $name is larger than Memory, dynamic ram will be disabled"
            }
            $property.$name = $value.ToUpperInvariant()
        }
        "memory" {
            if (-not ($value.ToUpper().EndsWith("GB")) -and (-not ($value.ToUpper().EndsWith("MB")))) {
                if ($CurrentValue.ToUpper().EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.ToUpper().EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
            $value = $property."$($Name)"
            if (($value / 1) -lt 50MB) {
                Add-ErrorMessage -property $name -Warning "Can not set $name to less than 50MB"
                
                $value = $CurrentValue
            }
            if (($value / 1) -gt 64GB) {
                Add-ErrorMessage -property $name -Warning "Can not set $name to more than 64GB"
                $value = $CurrentValue
            }
            $property.$name = $value.ToUpperInvariant()

            if (-not $Global:Config.domainDefaults.UseDynamicMemory) {
                if ($property.dynamicMinRam) {
                    $property.dynamicMinRam = $value.ToUpperInvariant()
                }
            }
            
        }

        "tpmEnabled" {
            if ($value -eq $false) {
                if ($property.OperatingSystem -like "*Windows 11*") {
                    Add-ErrorMessage -property $name "Windows 11 must include TPM support"
                    $property.$name = $true
                }
            }
        }

        "vmGeneration" {
            if ($value -notin ("1", "2")) {
                $property.$name = "2"
            }
            if ($value -eq "1" -and ($property.tpmEnabled -eq $true)) {
                Add-ErrorMessage -property $name -Warning "Setting generation to 1 will disable TPM support."
            }
        }
        "virtualProcs" {            
            if ($value -le "0" -or $value -gt 16) {
                Add-ErrorMessage -property $name -Warning "Valid values for $name is 1-16"
                $property.$name = 4
            }
        }
        "SqlServiceAccount" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }

                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                }
            }
        }
        "SqlAgentAccount" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                }
            }
        }
        "sqlVersion" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                }
            }
        }
        "sqlInstanceName" {
            if ($CurrentValue -eq "MSSQLSERVER") {
                if ($Value -ne "MSSQLSERVER") {
                    $property.sqlPort = "2433"
                }
            }
            else {
                if ($Value -eq "MSSQLSERVER") {
                    $property.sqlPort = "1433"
                }
            }

            if ($property.Role -eq "SQLAO") {
                $property.sqlPort = "1433"
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                    $sql.sqlPort = $property.sqlPort
                }
            }

        }
        "sqlPort" {
            if ($property.Role -eq "SQLAO") {
                Add-ErrorMessage -property $name  "Sorry. When using SQLAO, port must remain 1433 due to a bug in SqlServerDSC issue #329."
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = 1433
                }
            }

        }
        "sqlInstanceDir" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    $sql.$name = $value
                }
            }

        }
        "OtherNode" {
            Add-ErrorMessage -property $name  "OtherNode can not be set manually. Please rename the 2nd node of the cluster to change this property."
            $property.$name = $currentValue
        }
        "network" {
            if ($property.Role -eq "SQLAO") {
                $SQLAO = @($property)
                if ($property.OtherNode) {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $property.OtherNode }
                }
                else {
                    $SQLAO += $Global:Config.virtualMachines | Where-Object { $_.OtherNode -eq $property.vmName }
                }
                foreach ($sql in $SQLAO) {
                    if ($sql.$name) {
                        $sql.$name = $value
                    }
                    else {
                        $sql | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
                    }
                }
            }

        }
        "vmName" {

            if (($value.Length + $Global:Config.VmOptions.Prefix.Length) -gt 15) {
                Add-ErrorMessage -property $name  "VMName + Prefix can not be longer than 15 chars"
                $property.$name = $currentValue
            }
            
            foreach ($existing in $Global:Config.virtualMachines) {
    
                if ($existing.RemoteSQLVM -eq $CurrentValue) {
                    $existing.RemoteSQLVM = $value
                }
                if ($existing.remoteContentLibVM -eq $CurrentValue) {
                    $existing.remoteContentLibVM = $value
                }
                if ($existing.FileServerVM -eq $CurrentValue) {
                    $existing.FileServerVM = $value
                }
                if ($existing.pullDPSourceDP -eq $CurrentValue) {
                    $existing.pullDPSourceDP = $value
                }
            }
        }
       
        "installSUP" {
            if ($value -eq $true) {
                if (-not $property.siteCode) {
                    Get-SiteCodeMenu -property $property -name "siteCode" -ConfigToCheck $Global:Config
                }
                if (-not $property.siteCode) {
                    $property.installSUP = $false
                    $property.PsObject.Members.Remove("wsusContentDir")
                    $property.PsObject.Members.Remove("wsusDataBaseServer")
                }

                if ($property.ParentSiteCode -or $property.SiteCode) {
                    
                    $sitecode = $property.SiteCode
                 
                    if ($sitecode) {
                        $Parent = Get-ParentSiteServerForSiteCode -deployConfig $Global:Config -siteCode $sitecode -type VM -SmartUpdate:$false
                        if ($Parent.SiteCode) {
                            $list2 = Get-List2 -deployConfig $Global:Config
                            $existingSUP = $list2 | Where-Object { $_.InstallSUP -and $_.SiteCode -eq $Parent.SiteCode }
                            if (-not $existingSUP) {
                                $property.installSUP = $false
                                $property.PsObject.Members.Remove("wsusContentDir")
                                $property.PsObject.Members.Remove("wsusDataBaseServer")
                                Add-ErrorMessage -property $name "SUP role can not be installed on downlevel sites until the parent site ($($Parent.SiteCode)) has a SUP"
                            }
                        }
                    }

                }

                if ($property.Role -ne "WSUS") {
                    $DataBase = "WID"
                    if ($property.SqlVersion) {
                        $Database = $property.VMName                        
                    }
                    else {
                        $ActiveVM = Get-ActiveSiteServerForSiteCode -deployConfig $Global:Config -SiteCode $property.siteCode -type VM

                        $sql = Get-SqlServerForSiteCode -siteCode $property.SiteCode -deployConfig $Global:Config -type VM
                        if (-not $ActiveVM.InstallSUP) {
                            if (-not $sql.InstallSUP) {
                                $database = $($sql.vmName)
                            }
                        }
                    }
                    $property | Add-Member -MemberType NoteProperty -Name "wsusDataBaseServer" -Value $database -Force
                    $property | Add-Member -MemberType NoteProperty -Name "wsusContentDir" -Value "E:\WSUS" -Force
                    if ($null -eq $property.additionalDisks) {
                        $disk = [PSCustomObject]@{"E" = "600GB" }
                        $property | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
                    }
                    else {

                        if ($null -eq $property.additionalDisks.E) {
                            $property.additionalDisks | Add-Member -MemberType NoteProperty -Name "E" -Value "600GB" -force
                        }
                    }
                }

                $newName = Rename-VirtualMachine -vm $property


            }
            else {
                if ($property.Role -ne "WSUS") {
                    $property.PsObject.Members.Remove("wsusContentDir")
                    $property.PsObject.Members.Remove("wsusDataBaseServer")

                }
            }

            #$validSiteCodes = Get-ValidSiteCodesForWSUS -config $Global:Config -CurrentVM $property
            #if ($property.sitecode -in $validSiteCodes) {
            #
            #    $newName = Get-NewMachineName -vm $property
            #    if ($($property.vmName) -ne $newName) {
            #        $rename = $true
            #        $response = Read-YesorNoWithTimeout -Prompt "Rename $($property.vmName) to $($newName)? (Y/n)" -HideHelp -Default "y"
            #        if (-not [String]::IsNullOrWhiteSpace($response)) {
            #            if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
            #                $rename = $false
            #            }
            #        }
            #        if ($rename -eq $true) {
            #            $property.vmName = $newName
            #        }
            #    }
            #    else {
            #        Write-log "Current site code is not a valid target for a new SUP. Only 1 sup can exist on a CAS site, and 1 must exist on a CAS site before adding one to a Primary or Secondary site"
            #        $property.InstallSUP = $false
            #    }
            #}


        }
        "installMP" {
            if ((get-RoleForSitecode -ConfigToCheck $Global:Config -siteCode $property.siteCode) -in "Secondary", "CAS") {
                Add-ErrorMessage -property $name -Warning "Can not install an MP on a CAS or secondary site"
                $property.installMP = $false
            }
            $newName = Rename-VirtualMachine -vm $property
        }
        "enablePullDP" {
            if ($value -eq $true) {
                $server = select-PullDPMenu -CurrentVM $property
                $property | Add-Member -MemberType NoteProperty -Name "pullDPSourceDP" -Value $server -Force

            }
            else {
                $property.PsObject.Members.Remove("pullDPSourceDP")
            }
            $newName = Rename-VirtualMachine -vm $property
        }
        "installCA" {
            if ($property.ForestTrust -and $property.ForestTrust -ne "NONE") {
                $remoteCA = (get-list -type vm -DomainName $property.ForestTrust | Where-Object { $_.Role -eq "DC" } | Select-Object InstallCA).InstallCA
                if ($remoteCA) {
                    Add-ErrorMessage -property $name -Warning "Domain $($property.ForestTrust) already has a CA. Disabling CA in this domain"
                    $property.InstallCA = $false
                }
            }
        }
        "installDP" {

            if ((get-RoleForSitecode -ConfigToCheck $Global:Config -siteCode $property.siteCode) -eq "CAS") {
                Add-ErrorMessage -property $name -Warning "Can not install an DP for a CAS site"
                $property.installDP = $false
            }

            if ($value -eq $false) {
                $pullDPs = $Global:Config.virtualMachines | Where-Object { $_.pullDPSourceDP -eq $property.VmName }
                if ($pullDPs) {
                    Add-ErrorMessage -property $name -Warning "$($pullDPs.vmName) is using this as a source.  Please remove before removing this DP"
                    $property.InstallDP = $true
                    return
                }
                else {
                    $property.PsObject.Members.Remove("enablePullDP")
                    $property.PsObject.Members.Remove("pullDPSourceDP")
                }
            }
            else {
                $property | Add-Member -MemberType NoteProperty -Name "enablePullDP" -Value $false -Force
            }
            $newName = Rename-VirtualMachine -vm $property
        }
        "installRP" {

            $validSiteCodes = Get-ValidSiteCodesForRP -config $Global:Config -CurrentVM $property

            $sitecode = $property.sitecode
            if (-not $sitecode) {
                $SiteVM = $global:config.virtualMachines | where-object { $_.remoteSQLVM -eq $property.vmName -and $_.role -in ("CAS", "Primary") }
                $sitecode = $siteVM.sitecode
            }

            if (-not $sitecode) {
                $SiteVM = @(get-list -type VM -domain $global:config.VmOptions.DomainName | Where-Object { $_.remoteSQLVM -eq $property.vmName -and $_.role -in ("CAS", "Primary") })
                $sitecode = $siteVM.sitecode
            }
            if ($sitecode -in $validSiteCodes) {
                $newName = Rename-VirtualMachine -vm $property
            }
            else {
                Add-ErrorMessage -property $name -Warning "Site code $sitecode is not a valid target for a new Reporting Point. Only 1 RP can exist per site."
                $property.InstallRP = $false
            }
        }
        "siteCode" {
            if ($property.siteCode.Length -ne 3) {
                Add-ErrorMessage -property $name -Warning "SiteCode must be exactly 3 characters long. Unable to change sitecode."                
                $property.siteCode = $CurrentValue
                return
            }
            if ($property.RemoteSQLVM) {
                $newSQLName = $value + "SQL"
                #Check if the new name is already in use:
                $NewSQLVM = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $newSQLName }
                if ($NewSQLVM) {
                    Add-ErrorMessage -property $name -Warning "Changing Sitecode would rename SQL VM to $($NewSQLVM.vmName) which already exists. Unable to change sitecode."    
                    write-host
                    write-host2 -ForegroundColor OrangeRed "Changing Sitecode would rename SQL VM to " -NoNewline
                    write-host2 -ForegroundColor Gold $($NewSQLVM.vmName) -NoNewline
                    write-host2 -ForegroundColor OrangeRed " which already exists. Unable to change sitecode."
                    $property.siteCode = $CurrentValue
                    return
                }
            }

            $newName = Get-NewMachineName -vm $property
            $NewSSName = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $newName }
            if ($NewSSName) {
                write-host
                Add-ErrorMessage -property $name -Warning "Changing Sitecode would rename SQL VM to $($NewSSName.vmName) which already exists. Unable to change sitecode." 
                write-host2 -ForegroundColor OrangeRed "Changing Sitecode would rename VM to " -NoNewline
                write-host2 -ForegroundColor Gold $($NewSSName.vmName) -NoNewline
                write-host2 -ForegroundColor OrangeRed " which already exists. Unable to change sitecode."
                $property.siteCode = $CurrentValue
                return
            }
            #Set the SQL Name after all checks are done.
            if ($property.RemoteSQLVM) {
                $RemoteSQLVM = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $($property.RemoteSQLVM) }
                if ($RemoteSQLVM.OtherNode) {
                    #This is SQLAO
                    $newSQLName = $($property.SiteCode) + "SQLAO1"
                }
                $rename = $true
                $response = Read-YesorNoWithTimeout -Prompt "Rename $($property.RemoteSQLVM) to $($newSQLName)? (Y/n)" -HideHelp -Default "y"
                if (-not [String]::IsNullOrWhiteSpace($response)) {
                    if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                        $rename = $false
                    }
                }
                if ($rename -eq $true) {


                    if ($RemoteSQLVM.OtherNode) {
                        $name2 = $($property.SiteCode) + "SQLAO2"
                        $OtherNode = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $($RemoteSQLVM.OtherNode) }
                        $OtherNode.vmName = $name2
                        $RemoteSQLVM.OtherNode = $name2
                    }
                    $RemoteSQLVM.vmName = $newSQLName
                    $property.RemoteSQLVM = $newSQLName
                }
            }
            if ($($property.vmName) -ne $newName) {
                $rename = $true
                $response = Read-YesorNoWithTimeout -Prompt "Rename $($property.vmName) to $($newName)? (Y/n)" -HideHelp -Default "y"
                if (-not [String]::IsNullOrWhiteSpace($response)) {
                    if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                        $rename = $false
                    }
                }
                if ($rename -eq $true) {
                    $property.vmName = $newName
                }
            }
            Write-Verbose "New Name: $newName"
            if ($property.role -eq "CAS") {
                $PRIVMs = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Primary" }
                if ($PRIVMs) {
                    foreach ($PRIVM in $PRIVMs) {
                        if ($PRIVM.ParentSiteCode -eq $CurrentValue ) {
                            $PRIVM.ParentSiteCode = $value
                        }
                    }
                }
                $VMs = @()
                $VMs += $Global:Config.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" }
                if ($VMs) {
                    foreach ($VM in $VMS) {
                        if ($VM.siteCode -eq $CurrentValue ) {
                            $VM.SiteCode = $value
                            Get-AdditionalValidations -property $VM -name "SiteCode" -CurrentValue $CurrentValue
                        }
                    }
                }
            }
            if ($property.role -eq "Primary") {
                $VMs = @()
                $VMs += $Global:Config.virtualMachines | Where-Object { $_.installDP -or $_.enablePullDP }
                $VMs += $Global:Config.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" }
                $SecVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Secondary" }
                if ($VMs) {
                    foreach ($VM in $VMS) {
                        if ($VM.siteCode -eq $CurrentValue ) {
                            $VM.SiteCode = $value
                            Get-AdditionalValidations -property $VM -name "SiteCode" -CurrentValue $CurrentValue
                        }
                    }
                }
                if ($SecVM) {
                    $SecVM.parentSiteCode = $value
                }
            }

            if ($property.role -eq "Secondary") {
                $VMs = $Global:Config.virtualMachines | Where-Object { $_.installDP -or $_.enablePullDP }
                if ($VMs) {
                    foreach ($VM in $VMS) {
                        if ($VM.siteCode -eq $CurrentValue ) {
                            $VM.SiteCode = $value
                        }
                    }
                }
            }
        }
    }
}


function Get-SortedProperties {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Property to Sort")]
        [object] $property
    )

    $Sorted = @()
    $members = $property | Get-Member -MemberType NoteProperty
    if ($members.Name -contains "vmName") {
        $sorted += "vmName"
    }
    if ($members.Name -contains "DeploymentType") {
        $sorted += "DeploymentType"
    }
    if ($members.Name -contains "domainName") {
        $sorted += "DomainName"
    }
    if ($members.Name -contains "CMVersion") {
        $sorted += "CMVersion"
    }
    if ($members.Name -contains "prefix") {
        $sorted += "Prefix"
    }
    if ($members.Name -contains "network") {
        $sorted += "Network"
    }
    if ($members.Name -contains "DefaultServerOS") {
        $sorted += "DefaultServerOS"
    }
    if ($members.Name -contains "DefaultClientOS") {
        $sorted += "DefaultClientOS"
    }
    if ($members.Name -contains "DefaultSqlVersion") {
        $sorted += "DefaultSqlVersion"
    }
    if ($members.Name -contains "UseDynamicMemory") {
        $sorted += "UseDynamicMemory"
    }
    if ($members.Name -contains "IncludeClients") {
        $sorted += "IncludeClients"
    }
    if ($members.Name -contains "IncludeSSMSOnNONSQL") {
        $sorted += "IncludeSSMSOnNONSQL"
    }
    if ($members.Name -contains "adminName") {
        $sorted += "AdminName"
    }
    if ($members.Name -contains "basePath") {
        $sorted += "BasePath"
    }
    if ($members.Name -contains "domainUser") {
        $sorted += "DomainUser"
    }
    if ($members.Name -contains "role") {
        $sorted += "Role"
    }
    if ($members.Name -contains "memory") {
        $sorted += "Memory"
    }
    if ($members.Name -contains "dynamicMinRam") {
        $sorted += "DynamicMinRam"
    }
    if ($members.Name -contains "virtualProcs") {
        $sorted += "VirtualProcs"
    }
    if ($members.Name -contains "operatingSystem") {
        $sorted += "OperatingSystem"
    }
    if ($members.Name -contains "sqlVersion") {
        $sorted += "sqlVersion"
    }
    if ($members.Name -contains "sqlInstanceName") {
        $sorted += "sqlInstanceName"
    }
    if ($members.Name -contains "sqlInstanceDir") {
        $sorted += "sqlInstanceDir"
    }
    if ($members.Name -contains "sqlPort") {
        $sorted += "sqlPort"
    }
    if ($members.Name -contains "SqlAgentAccount") {
        $sorted += "SqlAgentAccount"
    }
    if ($members.Name -contains "SqlServiceAccount") {
        $sorted += "SqlServiceAccount"
    }    
    if ($members.Name -contains "remoteSQLVM") {
        $sorted += "RemoteSQLVM"
    }
    if ($members.Name -contains "cmInstallDir") {
        $sorted += "cmInstallDir"
    }
    if ($members.Name -contains "parentSiteCode") {
        $sorted += "ParentSiteCode"
    }
    if ($members.Name -contains "siteCode") {
        $sorted += "SiteCode"
    }
    if ($members.Name -contains "siteName") {
        $sorted += "SiteName"
    }
    if ($members.Name -contains "remoteContentLibVM") {
        $sorted += "RemoteContentLibVM"
    }
    if ($members.Name -contains "tpmEnabled") {
        $sorted += "tpmEnabled"
    }
    if ($members.Name -contains "InstallSSMS") {
        $sorted += "InstallSSMS"
    }
    if ($members.Name -contains "InstallCA") {
        $sorted += "InstallCA"
    }

    if ($members.Name -contains "additionalDisks") {
        $sorted += "AdditionalDisks"
    }
    if ($members.Name -contains "installDP") {
        $sorted += "InstallDP"
    }
    if ($members.Name -contains "enablePullDP") {
        $sorted += "EnablePullDP"
    }
    if ($members.Name -contains "installMP") {
        $sorted += "InstallMP"
    }
    if ($members.Name -contains "installRP") {
        $sorted += "InstallRP"
    }
    if ($members.Name -contains "installSUP") {
        $sorted += "InstallSUP"
    }
    if ($members.Name -contains "installSMSProv") {
        $sorted += "InstallSMSProv"
    }
    if ($members.Name -contains "Version") {
        $sorted += "Version"
    }
    if ($members.Name -contains "Install") {
        $sorted += "Install"
    }
    if ($members.Name -contains "EVALVersion") {
        $sorted += "EVALVersion"
    }
    if ($members.Name -contains "UsePKI") {
        $sorted += "UsePKI"
    }
    if ($members.Name -contains "OfflineSCP") {
        $sorted += "OfflineSCP"
    }
    if ($members.Name -contains "OfflineSUP") {
        $sorted += "OfflineSUP"
    }
    if ($members.Name -contains "PushClientToDomainMembers") {
        $sorted += "PushClientToDomainMembers"
    }
    if ($members.Name -contains "PrePopulateObjects") {
        $sorted += "PrePopulateObjects"
    }
  
    switch ($members.Name) {
        "vmName" {  }
        "role" {  }
        "memory" { }
        "dynamicMinRam" { }
        "domainUser" {}
        "virtualProcs" { }
        "operatingSystem" {  }
        "siteCode" { }
        "siteName" { }
        "parentSiteCode" { }
        "sqlVersion" { }
        "sqlInstanceName" {  }
        "sqlInstanceDir" { }
        "sqlPort" { }
        "SqlAgentAccount" { }
        "SqlServiceAccount" { }
        "additionalDisks" { }
        "cmInstallDir" { }
        "DeploymentType" { }
        "domainName" { }
        "prefix" { }
        "CMVersion" { }
        "network" { }
        "DefaultServerOS" { }
        "DefaultClientOS" { }
        "DefaultSqlVersion" { }
        "UseDynamicMemory" {}
        "IncludeClients" { }
        "IncludeSSMSOnNONSQL" { }  
        "adminName" { }
        "basePath" { }
        "remoteSQLVM" {}
        "remoteContentLibVM" {}
        "tpmEnabled" {}
        "installSSMS" {}
        "installCA" {}
        "enablePullDP" {}
        "installSUP" {}
        "installDP" {}
        "installMP" {}
        "installRP" {}
        "installSMSProv" {}
        "version" {}
        "install" {}
        "EVALVersion" {}
        "UsePKI" {}
        "OfflineSCP" {}
        "OfflineSUP" {}
        "pushClientToDomainMembers" {}
        "PrePopulateObjects" {}


        Default { $sorted += $_ }
    }
    return $sorted
}


#$TextToDisplay = Get-AdditionalInformation -item $item -data $TextValue[0]
function Get-AdditionalInformationColor {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Item Name")]
        [string] $item,
        [Parameter(Mandatory = $false, HelpMessage = "Raw value")]
        [string] $data
    )
    switch ($item) {
        "vmName" {
            $color = $Global:Common.Colors.GenConfigVMName
        }
        "Role" {
            $color = $Global:Common.Colors.GenConfigVMRole
        }
        "RemoteSQLVM" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "remoteContentLibVM" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "OtherNode" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "FileServerVM" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "SiteCode" {
            $color = $Global:Common.Colors.GenConfigSiteCode
        }
        "siteName" {
            $color = $Global:Common.Colors.GenConfigSiteCode
        }
        "ParentSiteCode" {
            $color = $Global:Common.Colors.GenConfigSiteCode
        }
        "SqlVersion" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "SqlInstanceName" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "SqlInstanceDir" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "sqlPort" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "SqlAgentAccount" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "SqlServiceAccount" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }        

    }
    switch ($value) {
        "True" {
            $color = $Global:Common.Colors.GenConfigTrue
        }
        "False" {
            $color = $Global:Common.Colors.GenConfigFalse
        }
    }
    return $color
}

function Get-AdditionalInformation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Item Name")]
        [string] $item,
        [Parameter(Mandatory = $false, HelpMessage = "Raw value")]
        [string] $data
    )
    #$global:config

    $origData = $data

    switch ($item) {

        "RemoteSQLVM" {
            $remoteSQL = $global:config.virtualMachines | Where-Object { $_.vmName -eq $data }
            $name = $($global:config.vmOptions.Prefix + $data)
            if ($remoteSQL) {
                if ($remoteSQL.OtherNode) {
                    $data = $data.PadRight(21) + "($name) [SQL Always On Cluster]"
                }
                else {
                    $data = $data.PadRight(21) + "($name)"
                }
            }
        }
        "ClusterName" {
            $data = $data.PadRight(21) + "($($global:config.vmOptions.Prefix+$data))"
        }

        "AlwaysOnListenerName" {
            $data = $data.PadRight(21) + "($($global:config.vmOptions.Prefix+$data))"
        }

        "vmName" {
            if (-not $data.StartsWith($global:config.vmOptions.Prefix)) {
                $data = $data.PadRight(21) + "($($global:config.vmOptions.Prefix+$data))"
            }
        }

        "domainUser" {
            $prefixLower = $global:config.vmOptions.Prefix.ToLower()
            if (-not $data.StartsWith($prefixLower)) {
                $data = $data.PadRight(21) + "($($prefixLower+$data))"
            }
        }

        "memory" {
            #add Available memory
        }
        "parentSiteCode" {
            #list serverName/role
        }
        "network" {
            $data = Get-EnhancedSubnetList -SubnetList $data -ConfigToCheck $global:config | Select-Object -First 1
        }
        default { }
    }

    foreach ($err in $global:GenConfigErrorMessages) {
        if ($err.property -eq $item) {
            $data = $origData.PadRight(21) + "[x] " + $err.message
            $global:GenConfigErrorMessages = @($global:GenConfigErrorMessages | where-object { $_.message -ne $err.message })
            break
        }
    }

    return $data
}
# Displays a Menu based on a property, offers options in [1], [2],[3] format
# With additional options passed in via additionalOptions
function Select-Options {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "MenuName")]
        [string] $MenuName,
        [Parameter(Mandatory = $false, HelpMessage = "Root of Property to Enumerate and automatically display a menu")]
        [object] $Rootproperty,
        [Parameter(Mandatory = $false, HelpMessage = "Property name")]
        [object] $propertyName,
        [Parameter(Mandatory = $false, HelpMessage = "Property to enumerate.. Can be used instead of RootProperty and propertyName")]
        [object] $propertyEnum,
        [Parameter(Mandatory = $false, HelpMessage = "If Property is an array.. find this element to work on (Base = 1).")]
        [object] $propertyNum,
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "Append additional Items to menu.. Eg X = Exit")]
        [PSCustomObject] $additionalOptions,
        [Parameter(Mandatory = $false, HelpMessage = "Let the prompt help show we will continue on enter")]
        [bool] $ContinueMode = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Run a configuration test. Default True")]
        [bool] $Test = $true,
        [string] $HelpFunction = $null
    )

    $property = $null
    $newName = $null
    :MainLoop
    while ($true) {
        $MenuItems = [System.Collections.ArrayList]@()
        if ($null -eq $property -and $null -ne $Rootproperty) {
            $property = $Rootproperty."$propertyName"
        }

        if ($null -ne $propertyNum) {
            $i = 0;
            while ($true) {
                if ($i -eq [int]($propertyNum - 1)) {
                    $property = $propertyEnum[$i]
                    break
                }
                $i = $i + 1
            }
        }

        if ($null -eq $property) {
            $property = $propertyEnum
        }

        Write-Host
        Write-Log -Verbose "6 Select-Options '$property' Root: '$Rootproperty' Name: '$propertyName' Enum: '$propertyEnum' Num '$propertyNum'"
        $i = 0
        #Write-Host "Trying to get $property"
        if ($null -eq $property) {
            return $null
        }
        $existingPropList = $Global:Common.Supported.UpdateablePropList
        $isVM = $false
        # Get the Property Names and Values.. Present as Options.
        foreach ($item in (Get-SortedProperties $property)) {
            $value = $property."$($item)"
            if ($item -eq "vmName") {
                $isVM = $true
            }
            if ($item -eq "network") {
                $isVM = $false
            }
            if ($item -eq "role" -and $value -eq "DC") {
                $isVM = $false
            }
            if ($item -eq "ExistingVM") {
                $isExisting = $true
            }
        }
        $fakeNetwork = $null
        $padding = 26
        $itemMap = @{}
        foreach ($item in (Get-SortedProperties $property)) {
            $value = $property."$($item)"
            if ($isExisting -and $item -eq "ExistingVM") {
                continue

            }
            if ($isExisting -and ($item -notin $existingPropList -or ($value -eq $true -and $null -eq $property."$($item + "-Original")") )) {
                $color = $Global:Common.Colors.GenConfigHidden
                $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName " " -ItemText "        $($($item).PadRight($padding," "")) = $value" -Color1 $color -selectable $false -HelpFunction $HelpFunction
                #Write-Option " " "$($($item).PadRight($padding," "")) = $value" -Color $color
                continue

            }

            $i = $i + 1

            if ($isVM -and $i -eq 2 -and -not $isExisting) {

                $fakeNetwork = $i
                $network = Get-EnhancedSubnetList -SubnetList $global:Config.vmOptions.Network -ConfigToCheck $global:Config
                #Write-Option $i "$($("network").PadRight($padding," "")) = <Default - $($global:Config.vmOptions.Network)>"
                $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName $i -ItemText "$($("network").PadRight($padding," "")) = $network" -selectable $true -HelpFunction $HelpFunction
                #Write-Option $i "$($("network").PadRight($padding," "")) = $network"
                write-log -verbose "Adding $network as element $i in itemmap"
                $itemMap[$i] = "network"
                $i++
            }
            #$padding = 27 - ($i.ToString().Length)
            $color = $null
            #write-log "Get-AdditionalInformation $item $value"
            $TextToDisplay = Get-AdditionalInformation -item $item -data $value
            $color = Get-AdditionalInformationColor -item $item -data $value
            $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName $i -ItemText "$($($item).PadRight($padding," "")) = $TextToDisplay" -selectable $true -Color1 $color -HelpFunction $HelpFunction
            write-log -verbose "Adding $item as element $i in itemmap with currentvalue $value"
            $itemMap[$i] = $item
            #Write-Option $i "$($($item).PadRight($padding," "")) = $TextToDisplay" -Color $color
        }

       
        if ($null -ne $additionalOptions) {
            $null = Get-MenuItems -MenuName $MenuName -ExistingMenuItems ([ref]$MenuItems) -additionalOptions $additionalOptions                  
        }

        #Show-GenConfigErrorMessages


        #if ($ContinueMode) {
        #    $response = get-ValidResponse $prompt $i $null $additionalOptions -ContinueMode:$ContinueMode
        #}
        #else {
        #    $response = get-ValidResponse $prompt $i $null $additionalOptions -return:$true
        #}
        $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName "*B" -ItemText "" -selectable $false -selected $false -Color1 $Global:Common.Colors.GenConfigHeader  
        $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName "*V" -ItemText "   ──────────────────────" -selectable $false -selected $false -Color1 "SlateGray"  
        $MenuItem = Add-MenuItem -MenuName $MenuName -MenuItems ([ref]$MenuItems) -ItemName "!" -ItemText "Done with changes" -selectable $true -selected $true -Color1 $Global:Common.Colors.GenConfigHelpHighlight -HelpFunction $HelpFunction
        $response = Get-Menu2 -MenuName $MenuName -menuItems ([ref]$MenuItems) -Prompt $prompt -HideHelp:$true -test:$false  

        if ([String]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE") {
            return "ESCAPE"
        }
        if ($response -eq "!") {
            return
        }
        if ($response -is [bool]) {
            $test = $false
        }
        $return = $null
        if ($null -ne $additionalOptions) {
            foreach ($item in $($additionalOptions.keys)) {
                if (($response -and $item) -and ($response.ToLowerInvariant() -eq $item.ToLowerInvariant())) {
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
        $done = $false
        
        write-log -verbose "Response is $response"
        if (($response -as [int]) -is [int]) {
            $response = $response -as [int]
            write-log -verbose "Response is $response int"
            $item = $itemMap[$response]
            if ($null -ne $item) {
                if ($isExisting) {
                    if ($null -eq $property."$($item + "-Original")") {
                        write-log -logonly "Adding $($item)-Original to $($property.vmName)"
                        $property |  Add-Member -MemberType NoteProperty -Name $("$item" + "-Original") -Value $property."$($item)" -force
                    }
                }
            
                $value = $property."$item"
                $name = $item
                write-log -verbose  "$name = $value"               
            } 
        }

        <#
        # { foreach ($item in (Get-SortedProperties $property)) {
            $value = $property."$($item)"
            if ($isExisting -and ($item -notin $existingPropList -or ($value -eq $true -and $null -eq $property."$($item + "-Original")") )) {
                continue
            }

            if ($done) {
                break
            }
            $i = $i + 1

            if ($fakeNetwork -and $response -eq $fakeNetwork) {
                $name = "network"
                $done = $true
            }
            else {
                if ($fakeNetwork -and ($i -eq $fakeNetwork)) {
                    $i++
                }
                if (-not ($response -eq $i)) {
                    continue
                }
                if ($isExisting) {
                    if ($null -eq $property."$($item + "-Original")") {
                        write-log -logonly "Adding $($item)-Original to $($property.vmName)"
                        $property |  Add-Member -MemberType NoteProperty -Name $("$item" + "-Original") -Value $property."$($item)" -force
                    }
                }
                $value = $property."$($item)"
                $name = $($item)

            }
:Enter a comment or description}
       #>
        switch ($name) {
            "operatingSystem" {
                Get-OperatingSystemMenu -property $property -name $name -CurrentValue $value
                if ($property.role -eq "DomainMember") {
                    #if (-not $property.SqlVersion) {
                    $newName = Rename-VirtualMachine -vm $property
                    #}
                }
                continue MainLoop
            }
            "DefaultClientOS" {
                Get-OperatingSystemMenuClient -property $property -name $name -CurrentValue $value                    
                continue MainLoop
            }
            "DefaultServerOS" {
                Get-OperatingSystemMenuServer -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "remoteContentLibVM" {
                $result = select-FileServerMenu -HA:$true -CurrentValue $value
                if (-not [string]::IsNullOrWhiteSpace($result) -and $result -ne "ESCAPE") {
                    $property.remoteContentLibVM = $result
                }
                continue MainLoop
            }
            "pullDPSourceDP" {
                $property.pullDPSourceDP = select-PullDPMenu  -CurrentValue $value -CurrentVM $Property
                continue MainLoop
            }
            "fileServerVM" {
                $result = select-FileServerMenu -HA:$false -CurrentValue $value
                if (-not [string]::IsNullOrWhiteSpace($result) -and $result -ne "ESCAPE") {
                    $property.fileServerVM = $result
                }
                continue MainLoop
            }
            "domainName" {
                $domain = select-NewDomainName
                if (-not [string]::IsNullOrEmpty($domain) -and $domain -ne "ESCAPE") {    
                    $property.domainName = $domain
                    if ($property.prefix) {
                        $property.prefix = get-PrefixForDomain -Domain $domain
                    }
                    if ($property.domainNetBiosName) {
                        $netbiosName = $domain.Split(".")[0]
                        $property.domainNetBiosName = $netbiosName
                    
                        Get-TestResult -SuccessOnError | out-null
                    }
                }
                continue MainLoop
            }
            "timeZone" {
                $timezone = Select-TimeZone
                if (-not [string]::isnullorwhitespace($timezone) -and $timezone -ne "ESCAPE") {
                    $property.timeZone = $timezone
                    Get-TestResult -SuccessOnError | out-null
                }
                continue MainLoop
            }
            "locale" {
                $locale = Select-Locale
                $property.locale = $locale
                Get-TestResult -SuccessOnError | out-null
                continue MainLoop
            }
            "network" {
                if ($property.vmName) {
                    $network = Get-NetworkForVM -vm $property
                }
                else {
                    $network = Select-Subnet -CurrentValue $property.Network
                }

                if ($network -eq $global:config.vmOptions.network) {
                    if ($property.Network -and $property.vmName) {
                        $property.PsObject.Members.Remove("network")
                    }
                    #write-host2 -ForegroundColor Khaki "Not changing network as this is the default network."
                    continue MainLoop
                }
                if ($network) {
                    if ($fakeNetwork) {
                        $property | Add-Member -MemberType NoteProperty -Name "network" -Value $network -Force
                    }
                    else {
                        $property.network = $network
                    }
                }
                Get-AdditionalValidations -property $property -name $Name -CurrentValue $network
                Get-TestResult -SuccessOnError | out-null
                continue MainLoop
            }
            "parentSiteCode" {
                Set-ParentSiteCodeMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "ForestTrust" {
                Get-ForestTrustMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "externalDomainJoinSiteCode" {
                Get-TargetSitesForDomain -property $property -domain $property.ForestTrust
                continue MainLoop
            }
            "sqlVersion" {
                Get-SqlVersionMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "DeploymentType" {
                $dt = Select-DeploymentType
                if ($dt) {
                    $property.DeploymentType = $dt
                }
                continue MainLoop
            }
            "DefaultsqlVersion" {
                Get-SqlVersionMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "remoteSQLVM" {
                Get-remoteSQLVM -property $property -name $name -CurrentValue $value
                Continue MainLoop
                #return "REFRESH"
            }
            "domainUser" {
                Get-domainUser -property $property -name $name -CurrentValue $value
                Continue MainLoop
                #return "REFRESH"
            }
            "wsusDataBaseServer" {
                Get-WsusDBName -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "siteCode" {
                if ($property.role -eq "PassiveSite") {
                    Add-ErrorMessage -property $name "SiteCode can not be manually modified on a Passive server. Please modify this on the Active node"
                    continue MainLoop
                }
                if ($property.role -in ("SiteSystem", "WSUS")) {
                    Get-SiteCodeMenu -property $property -name $name -CurrentValue $value
                    if (-not $($property.SiteCode)) {
                        Write-RedX "Could not determine sitecode for $($property.VmName)"
                        continue MainLoop
                    }
                    $SiteType = get-RoleForSitecode -siteCode $Property.SiteCode -config $Global:Config
                    if ($SiteType -eq "CAS") {
                        if ($property.InstallMP) {
                            Add-ErrorMessage -property $name "Can not install an MP on a CAS site. Automatically disabled"
                            $property.InstallMP = $false
                        }
                        if ($property.InstallDP) {
                            Add-ErrorMessage -property $name "Can not install a DP on a CAS site. Automatically disabled"
                            $property.InstallDP = $false
                            $property.PsObject.Members.Remove("enablePullDP")
                            $property.PsObject.Members.Remove("pullDPSourceDP")
                        }
                    }
                    $newName = Rename-VirtualMachine -vm $property
                    write-host
                    continue MainLoop
                }
            }
            "role" {
                if ($property.role -eq "PassiveSite") {
                    Add-ErrorMessage -property $name "role can not be manually modified on a Passive server. Please disable HA or delete the VM."
                    continue MainLoop
                }
                if (Get-RoleMenu -property $property -name $name -CurrentValue $value) {
                    Write-Host2 -ForegroundColor Khaki "VirtualMachine object was re-created with new role. Taking you back to VM Menu."
                    # VM was deleted.. Lets get outta here.
                    return
                }
                else {
                    #VM was not deleted.. We can still edit other properties.
                    continue MainLoop
                }
            }
            "CMVersion" {
                Get-CMVersionMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
            "version" {
                Get-CMVersionMenu -property $property -name $name -CurrentValue $value
                continue MainLoop
            }
        }
        # If the property is another PSCustomObject, recurse, and call this function again with the inner object.
        # This is currently only used for AdditionalDisks
        if ($value -is [System.Management.Automation.PSCustomObject]) {
            Select-Options -MenuName "$Name" -Rootproperty $property -PropertyName "$Name" -Prompt "Select data to modify" -HelpFunction "Get-GenericHelp" | out-null
        }
        else {
            #The option was not a known name with its own menu, and it wasnt another PSCustomObject.. We can edit it directly.
            $valid = $false
            Write-Host
            Write-Verbose "7 Select-Options"
            while ($valid -eq $false) {
                write-log -verbose "Read new Value5: $name = $($property."$Name")"
                if ($value -is [bool]) {
                    if ($value -eq $true) {
                        $response2 = "false"
                    }
                    else {
                        $response2 = "true"
                    }
                    $test = $false
                    #$response2 = Get-Menu -Prompt "Select new Value for $($Name)" -CurrentValue $value -OptionArray @("True", "False") -NoNewLine -Test:$false
                }
                else {
                    if ($property.VmName) {
                        $outputName = "$($Name) for VM $($property.VmName)"
                    }
                    else {
                        $outputName = "$Name"
                    }
                    Write-Log -Activity -NoNewLine "Modify Property $outputName - Current Value: $value"
                    $response2 = Read-Host2 -Prompt "Select new Value for $($Name)" $value
                    write-log -verbose "Got new value : $response2 for $Name"
                }
                if (-not [String]::IsNullOrWhiteSpace($response2)) {
                    if ($property."$($Name)" -is [Int]) {
                        try {
                            $property."$($Name)" = [Int]$response2
                            write-log -verbose "Got new value : $response2 for $Name Setting as INT"
                        }
                        catch {
                            Add-ErrorMessage -property $name "$_"
                            #Write-host "Explosion $_"
                        }
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

                        Write-Verbose ("$_ name = $($_.Name) or $name = $response2 value = '$value'")
                        write-log -verbose "Got new value : $response2 for $Name setting as String"
                        $property."$Name" = $response2
                        write-log -verbose "Read new Value: $name = $($property."$Name")"
                    }
                    Get-AdditionalValidations -property $property -name $Name -CurrentValue $value
                    if ($Test) {
                        write-log -verbose "Read new Value3: $name = $($property."$Name")"
                        #$valid = Get-TestResult -SuccessOnWarning                        
                        $valid = $true
                        write-log -verbose "Read new Value4: $name = $($property."$Name")"
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
                    write-log -verbose "Revert : $response2 for $Name = $value setting as String"
                    $valid = Get-TestResult -SuccessOnError
                }
            }
            write-log -verbose "Read new Value2: $name = $($property."$Name")"
            if ($name -eq "VmName" -and $($property."$Name") -ne $value ) {
                return "REFRESH"
            }
            if (-not [String]::IsNullOrWhiteSpace($newName)  ) {
                return "NEWNAME:$newName"
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
        [object] $config = $Global:Config
    )

    #Get-PSCallStack | out-host
    #If Config hasnt been generated yet.. Nothing to test
    if ($null -eq $config) {
        return $true
    }
    try {
        $c = Test-Configuration -InputObject $Config -Fast
        $valid = $c.Valid
        if ($valid -eq $false) {
            $messages = $($c.Message) -split "\r\n"
            foreach ($msg in $messages.Trim()) {
                #Write-RedX $msg
                $global:GenConfigErrorMessages += [PSCustomObject]@{
                    property = $null
                    Level    = "ERROR"
                    Message  = $msg
                }
                Write-Verbose "GenConfig Get-TestResult $msg"
            }
            #Write-ValidationMessages -TestObject $c
            #$MyInvocation | Out-Host
            if ($enableVerbose) {
                Get-PSCallStack | out-host
            }
        }
        if ($SuccessOnWarning.IsPresent) {
            if ( $c.Failures -eq 0) {
                $valid = $true
            }
        }
        if ($SuccessOnError.IsPresent) {
            $valid = $true
        }
    }
    catch {
        return $true
    }
    return $valid
}

function get-IsExistingVMModified {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VirtualMachine Object from config")]
        [object] $virtualMachine
    )

    $modified = $false
    if ($virtualMachine.ExistingVM) {
        foreach ($prop in $virtualMachine.PSObject.Properties) {
            if ($prop.Name.EndsWith("-Original")) {
                $propName = $prop.Name.Replace("-Original", "")
                if ($prop.Value -ne $virtualMachine."$propName") {
                    $modified = $true
                    break
                }
            }
        }
    }
    return $modified
}

function get-VMString {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "config")]
        [object] $config,
        [Parameter(Mandatory = $true, HelpMessage = "VirtualMachine Object from config")]
        [object] $virtualMachine,
        [switch] $colors

    )

    $name = $null
    $temp = $null
    $SiteCode = $null
    $modified = get-IsExistingVMModified -virtualMachine $virtualMachine


    if ($virtualMachine.source -eq "hyperv" -or $virtualMachine.vmId) {
        $machineName = $($virtualMachine.vmName).PadRight(19, " ")
    }
    else {
        $machineName = $($($Global:Config.vmOptions.Prefix) + $($virtualMachine.vmName)).PadRight(19, " ")
    }

    $name = "$machineName " + $("[" + $($virtualmachine.role) + "]").PadRight(17, " ")
    if ($virtualMachine.memory) {
        if ($virtualMachine.dynamicMinRam -and ($($virtualMachine.dynamicMinRam) / 1) -lt ($($virtualMachine.memory) / 1)) {
            $mem = $($($virtualMachine.dynamicMinRam) + "-" + $($virtualMachine.memory)).PadLeft(4, " ") 
        }
        else {
            $mem = $($virtualMachine.memory).PadLeft(4, " ")
        }
    }
    else { $mem = "n/a" }
    if ($virtualMachine.virtualProcs) {
        $procs = $($virtualMachine.virtualProcs).ToString().PadLeft(2, " ")
    }
    $Network = $config.vmOptions.Network
    if ($virtualMachine.Network) {
        $Network = $virtualMachine.Network
    }
    $name += " [$network]".PadRight(17, " ")
    if ($modified) {
        $name = $name + "(Modified)"
    }
    $name += " VM [$mem RAM,$procs CPU, $($virtualMachine.OperatingSystem)]"

    # if ($virtualMachine.additionalDisks) {
    #     $name += ", $($virtualMachine.additionalDisks.psobject.Properties.Value.count) Extra Disk(s)]"
    # }
    # else {
    #     $name += "]"
    # }

    if ($virtualMachine.siteCode -and $virtualMachine.cmInstallDir) {
        $SiteCode = $virtualMachine.siteCode
        if ($virtualMachine.parentSiteCode) {
            $SiteCode += "->$($virtualMachine.parentSiteCode)"
        }
        $name += "  CM  [SiteCode $SiteCode ($($virtualMachine.cmInstallDir))]"
        if ($virtualMachine.installSUP) {
            $name += " [SUP]"
        }
        if ($virtualMachine.installRP) {
            $name += " [RP]"
        }
        if ($virtualMachine.InstallSMSProv) {
            $name += " [PROV]"
        }
        $name = $name.PadRight(39, " ")
    }

    if ($virtualMachine.siteCode -and -not $virtualMachine.cmInstallDir) {
        $SiteCode = $virtualMachine.siteCode
        if ($virtualMachine.parentSiteCode) {
            $SiteCode += "->$($virtualMachine.parentSiteCode)"
        }
        $temp = "  CM  [SiteCode $SiteCode]"
        if ($virtualMachine.installDP -or $virtualMachine.enablePullDP) {
            if ($virtualMachine.installMP) {
                $temp += " [MP]"
            }
            if ($virtualMachine.installDP) {
                if ($virtualMachine.pullDPSourceDP) {
                    $temp += " [Pull DP]"
                }
                else {
                    $temp += " [DP]"
                }
            }
        }
        if ($virtualMachine.installSUP) {
            if (-not ($name.Contains("[SUP]"))) {
                $temp += " [SUP]"
            }
        }
        if ($virtualMachine.installRP) {
            if (-not ($name.Contains("[RP]"))) {
                $temp += " [RP]"
            }
        }
        if ($virtualMachine.InstallSMSProv) {
            if (-not ($name.Contains("[PROV]"))) {
                $temp += " [PROV]"
            }
        }
        $name += $temp.PadRight(39, " ")
    }

    if ($virtualMachine.remoteSQLVM) {
        $sqlVM = Get-List2 -DeployConfig $config | Where-Object { $_.vmName -eq $virtualMachine.remoteSQLVM }
        if ($sqlVM.OtherNode) { $name += "  SQL AO [$($sqlVM.vmName),$($sqlVM.OtherNode)]" }
        else { $name += "  Remote SQL [$($virtualMachine.remoteSQLVM)]" }
    }

    if ($virtualMachine.sqlVersion -and -not $virtualMachine.sqlInstanceDir) {
        $name += "  SQL [$($virtualMachine.sqlVersion)]"
    }

    if ($virtualMachine.sqlVersion -and $virtualMachine.sqlInstanceDir) {
        $name += "  SQL [$($virtualMachine.sqlVersion), "
        $name += "$($virtualMachine.sqlInstanceName) ($($virtualMachine.sqlInstanceDir))]"
    }

    if ($virtualMachine.sqlVersion) {
        if ($virtualMachine.installSUP) {
            if (-not ($name.Contains("[SUP]"))) {
                $name += " [SUP]"
            }
        }
        if ($virtualMachine.installRP) {
            if (-not ($name.Contains("[RP]"))) {
                $name += " [RP]"
            }
        }
        if ($virtualMachine.InstallSMSProv) {
            if (-not ($name.Contains("[PROV]"))) {
                $name += " [PROV]"
            }
        }
    }

    if ($virtualMachine.InstallCA) {
        $name += " [CA]"
    }

    if ($virtualMachine.ForestTrust -and $virtualMachine.ForestTrust -ne "NONE") {
        $name += " Trust [$($virtualMachine.ForestTrust)"
        if ($virtualMachine.externalDomainJoinSiteCode) {
            $name += "-->$($virtualMachine.externalDomainJoinSiteCode)"
        }
        $name += "]"
    }

    write-log "Name is $name $virtualMachine" -verbose
    $MaxWidth = ($host.UI.RawUI.WindowSize.Width - 8)
    if ($name.Length -ge $MaxWidth) {
        $name = $name.Substring(0, $MaxWidth - 3) + "..."
    }
  

    $CASColors = @("%PaleGreen", "%YellowGreen", "%SeaGreen", "%MediumSeaGreen", "%SpringGreen", "%Lime", "%LimeGreen")
    $PRIColors = @("%LightSkyBlue", "%CornflowerBlue", "%SlateBlue", "%DeepSkyBlue", "%Turquoise", "%Cyan", "%MediumTurquoise", "%Aquamarine", "%SteelBlue", "%Blue")
    $SECColors = @("%SandyBrown", "%Chocolate", "%Peru", "%DarkGoldenRod", "%Orange", "%RosyBrown", "%SaddleBrown", "%Tan", "%DarkSalmon", "%GoldenRod")


    $ColorMap = New-Object System.Collections.Generic.Dictionary"[String,String]"


    $casCount = 0
    $priCount = 0
    $secCount = 0
    $allVMs = get-list2 -deployConfig $config
    foreach ($vm in $allVMs) {
        switch ($vm.Role) {
            "CAS" {
                try {
                    $ColorMap.Add($vm.SiteCode, $CASColors[$casCount])
                }
                catch {
                    break
                    #$ColorMap.Add($vm.SiteCode, "HotPink")
                }
                $casCount++
            }
            "Primary" {
                #write-log "Adding color $($PRIColors[$priCount]) for $($vm.VmName)"
                try {
                    $ColorMap.Add($vm.SiteCode, $PRIColors[$priCount])
                }
                catch {
                    break
                    #$ColorMap.Add($vm.SiteCode, "HotPink")
                }
                $priCount++
            }
            "Secondary" {
                try {
                    $ColorMap.Add($vm.SiteCode, $SECColors[$secCount])
                }
                catch {
                    #$ColorMap.Add($vm.SiteCode, "HotPink")
                    break
                }
                $secCount++
            }
        }
    }
    if ($colors) {
        switch ($virtualMachine.Role) {
            "DC" {
                $color = "%Tomato"
            }
            "BDC" {
                $color = "%Tomato"
            }
            "CAS" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]
            }
            "Primary" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]

            }
            "Secondary" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]

            }
            "PassiveSite" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]
            }
            "SiteSystem" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]
            }
            "WSUS" {
                if ($virtualMachine.SiteCode) {
                    try {
                        $color = $ColorMap[$($virtualMachine.SiteCode)]
                    }
                    catch {}
                }
            }
            "SQLAO" {
                $color = "%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
                if (-not $virtualMachine.Othernode) {
                    $primaryNode = $allVMs | Where-Object { $_.OtherNode -eq $virtualMachine.vmName }
                }
                else {
                    $primaryNode = $virtualMachine
                }

                $siteVM = $allVMs | Where-Object { $_.RemoteSQLVM -eq $primaryNode.vmName }
                if ($siteVM) {
                    $color = $ColorMap[$($siteVM.SiteCode)]
                }

            }
            "DomainMember" {
                $color = "%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
                $siteVM = $allVMs | Where-Object { $_.RemoteSQLVM -eq $virtualMachine.vmName -and $_.role -in ("CAS", "Primary", "Secondary") } | Select-Object -First 1

                if ($siteVM -and $siteVM.SiteCode) {
                    try {
                        $color = $ColorMap[$($siteVM.SiteCode)]
                    }
                    catch {}
                }

            }
            default {
                $color = "%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
            }
        }
        Write-log "Setting $name to $color for $($virtualMachine.Role)" -verbose
        $name = $name.TrimEnd() + $color
    }

    Write-log "Color for $($virtualMachine.Role) is $name" -verbose
    return "$name"
}



function Get-NetworkForVM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Object")]
        [object] $vm,
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "If a new network isnt needed, return null")]
        [bool] $ReturnIfNotNeeded = $false
    )

    $currentNetwork = $ConfigToModify.vmOptions.Network
    if ($currentNetwork -eq "10.234.241.0") {
        return
    }
    if ($vm.Network) {
        $currentNetwork = $vm.Network
    }
    $SiteServers = get-list2 -deployConfig $ConfigToModify | Where-Object { ($_.Role -eq "Primary" -or $_.Role -eq "Secondary") -and $_.vmName -ne $vm.vmName }
    #$SiteServers | convertto-Json | Out-Host
    #$ConfigToModify  |convertto-Json | Out-Host
    #$Secondaries = get-list2 -deployConfig $ConfigToModify  | Where-Object {$_.Role -eq "Secondary"}
    switch ($vm.role) {
        "Secondary" {
            if ($currentNetwork -in $SiteServers.network) {
                #Write-host "$CurrentNetwork is in $($SiteServers.network)"

                return Select-Subnet -config $configToModify -CurrentNetworkIsValid:$false -CurrentVM $vm
            }
            else {
                if (-not $ReturnIfNotNeeded) {
                    return Select-Subnet -config $configToModify -CurrentNetworkIsValid:$true -CurrentVM $vm
                }
            }
        }
        "Primary" {
            if ($currentNetwork -in $SiteServers.network) {
                #Write-host "$CurrentNetwork is in $($SiteServers.network)"

                return Select-Subnet -config $configToModify -CurrentNetworkIsValid:$false -CurrentVM $vm
            }
            else {
                if (-not $ReturnIfNotNeeded) {
                    return Select-Subnet -config $configToModify -CurrentNetworkIsValid:$true -CurrentVM $vm
                }
            }
        }
        "CAS" {
            $SiteServers = get-list2 -deployConfig $ConfigToModify | Where-Object { ($_.Role -eq "Primary" -or $_.Role -eq "Secondary" -or $_.Role -eq "CAS") -and $_.vmName -ne $vm.vmName }
            $SiteServers = $SiteServers | Where-Object { -not ($_.Role -eq "Primary" -and $_.ParentSiteCode -eq $vm.SiteCode) }
            if ($currentNetwork -in $SiteServers.network) {
                #Write-host "$CurrentNetwork is in $($SiteServers.network)"

                return Select-Subnet -config $configToModify -CurrentNetworkIsValid:$false -CurrentVM $vm
            }
            else {
                if (-not $ReturnIfNotNeeded) {
                    return Select-Subnet -config $configToModify -CurrentNetworkIsValid:$true -CurrentVM $vm
                }
            }
        }
        "PassiveSite" {
            $SS = Get-SiteServerForSiteCode -siteCode $vm.SiteCode -deployConfig $ConfigToModify -type VM
            if ($ss.network -ne $currentNetwork) {
                return $ss.Network
            }
        }
        Default {
            if (-not $ReturnIfNotNeeded) {
                return Select-Subnet -config $configToModify -CurrentNetworkIsValid:$true -CurrentVM $vm

            }
        }
    }

    return $null
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
        [Parameter(Mandatory = $false, HelpMessage = "Force VM Name for 2nd Node. Otherwise auto-generated")]
        [string] $Name2 = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Parent Side Code if this is a Primary or Secondary in a Hierarchy")]
        [string] $parentSiteCode = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Override Network")]
        [string] $network = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Site Code if this is a PassiveSite or a DPMP")]
        [string] $SiteCode = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Override default OS")]
        [string] $OperatingSystem = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Return Created Machine Name")]
        [bool] $ReturnMachineName = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Quiet Mode")]
        [bool] $Quiet = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Test Mode")]
        [bool] $test = $false,
        [Parameter(Mandatory = $false, HelpMessage = "True if this is the Secondary SQLAO Node")]
        [bool] $secondSQLAO = $false
    )


    $oldConfig = $configToModify | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    Write-Verbose "[Add-NewVMForRole] Start Role: $Role Domain: $Domain Config: $ConfigToModify OS: $OperatingSystem SiteCode: $SiteCode ParentSiteCode: $parentSiteCode Network: $network"

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) {
        if ($role -eq "WorkgroupMember" -or $role -eq "AADClient" -or $role -eq "InternetClient") {
            $OSList = Get-SupportedOperatingSystemsForRole -role $role
            $operatingSystem = "Windows 10 Latest (64-bit)"
            if ($ConfigToModify.domainDefaults.DefaultClientOS) {
                $operatingSystem = $ConfigToModify.domainDefaults.DefaultClientOS
            }
            else {          
                Write-Log -Verbose "No Default OS defined" 
                #Write-Log -Activity "OS Version selection for new '$role' VM" -NoNewLine
                $OperatingSystem = Get-Menu2 -MenuName "OS Version selection for new '$role' VM"  -prompt "Select OS Version for new $role VM" -optionArray $OSList -Test:$false -CurrentValue $operatingSystem
                if ($OperatingSystem -eq "ESCAPE") {
                    return
                }
            }
        }
        else {
            if ($role -eq "Linux") {
                $OSList = Get-SupportedOperatingSystemsForRole -role $role
                if ($null -eq $OSList ) {
                    $OperatingSystem = "Linux Unknown"
                }
                else {
                    Write-Log -Activity "OS Version selection for new '$role' VM" -NoNewLine
                    $OperatingSystem = Get-Menu2 -MenuName "OS Version selection for new '$role' VM" -prompt "Select OS Version for new $role VM" -optionArray $OSList -Test:$false
                    if ($OperatingSystem -eq "ESCAPE") {
                        return
                    }
                }
            }
            else {
                $OSList = Get-SupportedOperatingSystemsForRole -role $role
                if ($role.Contains("Client")) {
                    $DefaultOperatingSystem = "Windows 10 Latest (64-bit)"
                    if ($ConfigToModify.domainDefaults.DefaultClientOS) {
                        $operatingSystem = $ConfigToModify.domainDefaults.DefaultClientOS
                    }
                }
                else {
                    $DefaultOperatingSystem = "Server 2022"
                    if ($ConfigToModify.domainDefaults.DefaultClientOS) {
                        $operatingSystem = $ConfigToModify.domainDefaults.DefaultServerOS
                    }
                }
                if ($null -ne $OSList) {
                    if (-not $OperatingSystem) {                        
                        Write-Log -Verbose "No Default OS defined" 
                        Write-Log -Activity "OS Version selection for new '$role' VM" -NoNewLine
                        $OperatingSystem = Get-Menu2 -MenuName "OS Version selection for new '$role' VM" -prompt "Select OS Version for new $role VM" -optionArray $OSList -Test:$false -CurrentValue $DefaultOperatingSystem
                        if ($OperatingSystem -eq "ESCAPE") {
                            $OperatingSystem = $DefaultOperatingSystem
                            return
                        }
                    }
                }
            }
        }
    }


    $actualRoleName = ($Role -split " ")[0]

    if ($role -eq "SqlServer") {
        $actualRoleName = "DomainMember"
    }

    $memory = "2GB"
    $vprocs = 2

    $installSSMS = $false
    if ($OperatingSystem.Contains("Server") -and ($role -notin ("DC", "BDC"))) {
        $memory = "3GB"
        $vprocs = 4
        $installSSMS = $true
        if ($ConfigToModify.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
            $installSSMS = $false
            if ($role -eq "SqlServer") {
                $installSSMS = $true
            }
        }
    }
    if ($OperatingSystem.Contains("Windows 11") -and ($role -notin ("DC", "BDC"))) {
        $memory = "4GB"
        
        $installSSMS = $false
    }

    if ($role -eq "Linux") {
        $virtualMachine = [PSCustomObject]@{
            vmName          = $null
            role            = $actualRoleName
            operatingSystem = $OperatingSystem
            memory          = $memory
            virtualProcs    = $vprocs
            vmGeneration    = 1
        }
    }
    else {
        $virtualMachine = [PSCustomObject]@{
            vmName          = $null
            role            = $actualRoleName
            operatingSystem = $OperatingSystem
            memory          = $memory
            virtualProcs    = $vprocs
            tpmEnabled      = $true
        }
    }

    if ($network) {
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'network' -Value $network -force
    }
    if ($role -notin ("OSDCLient", "AADClient", "DC", "BDC", "Linux")) {
        #Match Windows 10 or 11
        if ($operatingSystem.Contains("Windows 1")) {
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'useFakeWSUSServer' -Value $false -force
        }
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $installSSMS -force
    }

   

    $existingDPMP = $null
    $NewFSServer = $null
    switch ($Role) {
        "WSUS" {
            $virtualMachine.Memory = "6GB"
            #$virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSUP' -Value $true
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'wsusContentDir' -Value "E:\WSUS" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
            #if (-not $SiteCode) {
            #    $SiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).SiteCode
            #    if ($test) {
            #        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $SiteCode -Force
            #    }
            #    else {
            #        Get-SiteCodeMenu -property $virtualMachine -name "siteCode" -CurrentValue $SiteCode -ConfigToCheck $configToModify
            #        if (-not $virtualMachine.SiteCode) {
            #            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSUP' -Value $false -force
            #        }
            #    }
            #}
            #else {
            #    #write-log "Adding new DPMP for sitecode $newSiteCode"
            #    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $SiteCode -Force
            #}

        }
        "SqlServer" {
            $SqlVersion = "SQL Server 2022"

            if ($ConfigToModify.domainDefaults.DefaultSqlVersion) {
                $SqlVersion = $ConfigToModify.domainDefaults.DefaultSqlVersion
            }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value $SqlVersion  -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "E:\SQL" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlPort' -Value "1433" -force
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
            $virtualMachine.Memory = "7GB"
            $virtualMachine.virtualProcs = 8
            $virtualMachine.operatingSystem = $OperatingSystem
            $virtualMachine.tpmEnabled = $false
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlServiceAccount' -Value "LocalSystem" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlAgentAccount' -Value "LocalSystem" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $true -force
        }
        "SQLAO" {
            $SqlVersion = "SQL Server 2022"

            if ($ConfigToModify.domainDefaults.DefaultSqlVersion) {
                $SqlVersion = $ConfigToModify.domainDefaults.DefaultSqlVersion
            }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value $SqlVersion -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "E:\SQL" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlPort' -Value "1433" -force
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
            $virtualMachine.Memory = "7GB"
            $virtualMachine.virtualProcs = 8
            $virtualMachine.operatingSystem = $OperatingSystem
            $virtualMachine.tpmEnabled = $false
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $true -force

        }
        "CAS" {
            $SqlVersion = "SQL Server 2022"

            if ($ConfigToModify.domainDefaults.DefaultSqlVersion) {
                $SqlVersion = $ConfigToModify.domainDefaults.DefaultSqlVersion
            }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value $SqlVersion -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "F:\SQL" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $true -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlPort' -Value "1433" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value "E:\ConfigMgr" -force
            $disk = [PSCustomObject]@{"E" = "250GB"; "F" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
            $newSiteCode = Get-NewSiteCode $Domain -Role $actualRoleName -ConfigToCheck $ConfigToModify
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $newSiteCode -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSUP' -Value $false -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installRP' -Value $false -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteName' -Value "ConfigMgr CAS" -force
            $virtualMachine.Memory = "10GB"
            $virtualMachine.virtualProcs = 8
            $virtualMachine.operatingSystem = $OperatingSystem   
            if (-not $test) {
                $network = Get-NetworkForVM -vm $virtualMachine -ConfigToModify $oldConfig -ReturnIfNotNeeded:$true
                if ($network) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'network' -Value $network -force
                }                
            }
        }
        "Primary" {
            if ($parentSiteCode) {
                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'parentSiteCode' -Value $parentSiteCode
            }
            $SqlVersion = "SQL Server 2022"

            if ($ConfigToModify.domainDefaults.DefaultSqlVersion) {
                $SqlVersion = $ConfigToModify.domainDefaults.DefaultSqlVersion
            }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value $SqlVersion -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "F:\SQL" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlPort' -Value "1433" -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $true -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value "E:\ConfigMgr" -force
            $disk = [PSCustomObject]@{"E" = "600GB"; "F" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
            $newSiteCode = Get-NewSiteCode $Domain -Role $actualRoleName -ConfigToCheck $ConfigToModify
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $newSiteCode -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSUP' -Value $false -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installRP' -Value $false -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteName' -Value "ConfigMgr Primary Site" -force

            $virtualMachine.Memory = "10GB"
            $virtualMachine.virtualProcs = 8
            $virtualMachine.operatingSystem = $OperatingSystem
            $existingDPMP = ($ConfigToModify.virtualMachines | Where-Object { $_.installDP -or $_.enablePullDP } | Measure-Object).Count
            if (-not $test -and (-not $network)) {
                $network = Get-NetworkForVM -vm $virtualMachine -ConfigToModify $oldConfig  -ReturnIfNotNeeded:$true
                if ($network) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'network' -Value $network -force
                }
            }

        }
        "Secondary" {
            $virtualMachine.memory = "3GB"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'parentSiteCode' -Value $parentSiteCode -force
            $virtualMachine.operatingSystem = $OperatingSystem
            $newSiteCode = Get-NewSiteCode $Domain -Role $actualRoleName -ConfigToCheck $ConfigToModify
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $newSiteCode -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value 'E:\ConfigMgr' -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSUP' -Value $false -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteName' -Value "ConfigMgr Secondary Site" -force
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
            if (-not $test -and (-not $network)) {
                $network = Get-NetworkForVM -vm $virtualMachine -ConfigToModify $oldConfig  -ReturnIfNotNeeded:$true
                if ($network) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'network' -Value $network -force
                }
            }

        }
        "PassiveSite" {
            $virtualMachine.memory = "3GB"
            $NewFSServer = $true
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $SiteCode -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value 'E:\ConfigMgr' -force
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force

            if (-not $test -and (-not $network)) {
                $network = Get-NetworkForVM -vm $virtualMachine -ConfigToModify $oldConfig  -ReturnIfNotNeeded:$true
                if ($network) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'network' -Value $network -force
                }
            }
        }
        "WorkgroupMember" {}
        "InternetClient" {}
        "AADClient" {}
        "DomainMember" {
            if ($OperatingSystem -notlike "*Server*") {
                $users = get-list2 -DeployConfig $oldConfig | Where-Object { $_.domainUser } | Select-Object -ExpandProperty domainUser -Unique
                [int]$i = 1
                $userPrefix = $oldConfig.vmOptions.prefix.toLower() + "user"
                $userNoPrefix = "user"
                while ($true) {
                    $preferredUserName = $userPrefix + $i
                    $noPrefixUserName = $userNoPrefix + $i
                    if ($users -contains $preferredUserName -or $users -contains $noPrefixUserName) {
                        write-log -verbose "$preferredUserName already exists Trying next"
                        $i++
                    }
                    else {
                        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'domainUser' -Value $noPrefixUserName -force
                        break
                    }
                }
            }
        }
        "DomainMember (Server)" {}
        "DomainMember (Client)" {
            if ($OperatingSystem -like "*Server*") {
                if ($ConfigToModify.domainDefaults.DefaultClientOS) {
                    $virtualMachine.operatingSystem = $ConfigToModify.domainDefaults.DefaultClientOS
                }
                else {
                    $virtualMachine.operatingSystem = "Windows 10 Latest (64-bit)"
                }
                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'useFakeWSUSServer' -Value $false -force
            }
            else {
                $virtualMachine.operatingSystem = $OperatingSystem
            }

            $users = get-list2 -DeployConfig $oldConfig | Where-Object { $_.domainUser } | Select-Object -ExpandProperty domainUser -Unique
            [int]$i = 1
            $userPrefix = $oldConfig.vmOptions.prefix.toLower() + "user"
            $userNoPrefix = "user"
            while ($true) {
                $preferredUserName = $userPrefix + $i
                $noPrefixUserName = $userNoPrefix + $i
                if ($users -contains $preferredUserName -or $users -contains $noPrefixUserName) {
                    write-log -verbose "$preferredUserName already exists Trying next"
                    $i++
                }
                else {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'domainUser' -Value $noPrefixUserName -force
                    break
                }

            }

            $virtualMachine.Memory = "2GB"
            if ($virtualMachine.operatingSystem.Contains("Windows 11") ) {
                $virtualMachine.Memory = "4GB"
            }
        }
        "OSDClient" {
            $virtualMachine.memory = "2GB"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'vmGeneration' -Value "2" -force
            $virtualMachine.PsObject.Members.Remove('operatingSystem')
        }
        "SiteSystem" {
            $virtualMachine.memory = "3GB"
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'InstallDP' -Value $true -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'InstallMP' -Value $true -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'InstallSUP' -Value $false -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'InstallRP' -Value $false -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'InstallSMSProv' -Value $false -force
            if (-not $SiteCode) {
                $SiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).SiteCode
                if ($test) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $SiteCode -Force
                }
                else {
                    #This sets the virtualmachine.Sitecode property.. Make sure to read this back in when done.
                    Get-SiteCodeMenu -property $virtualMachine -name "siteCode" -CurrentValue $SiteCode -ConfigToCheck $configToModify -test:$false
                }

                if (-not $($virtualMachine.SiteCode)) {
                    Write-RedX "Could not add SiteCode to SiteSystem $($virtualMachine.vmName). Cancelling"
                    return
                }

                if ((get-RoleForSitecode -ConfigToCheck $ConfigToModify -siteCode $virtualMachine.siteCode) -eq "CAS") {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installDP' -Value $false -force
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installMP' -Value $false -force
                }

                if ($virtualMachine.installDP) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'enablePullDP' -Value $false
                }
            }
            else {
                #write-log "Adding new DPMP for sitecode $newSiteCode"
                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $SiteCode -Force
            }
            # Needed when expanding an existing domain
            $siteCode = $virtualMachine.siteCode
            if ((get-RoleForSitecode -ConfigToCheck $ConfigToModify -siteCode $siteCode) -eq "Secondary") {
                $virtualMachine.installMP = $false
            }
        }
        "FileServer" {
            $virtualMachine.memory = "3GB"
            $disk = [PSCustomObject]@{"E" = "600GB"; "F" = "200GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
            $virtualMachine.tpmEnabled = $false
        }
        "DC" {
            $virtualMachine.memory = "4GB"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'InstallCA' -Value $true -force
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'ForestTrust' -Value "NONE" -force
            $virtualMachine.tpmEnabled = $false
        }
        "BDC" {
            $virtualMachine.memory = "4GB"
            $virtualMachine.tpmEnabled = $false
        }
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        if ($virtualMachine.InstallMP -or $virtualMachine.InstallDP) {
            $machineName = Get-NewMachineName -ConfigToCheck $oldConfig -vm $virtualMachine
        }
        else {
            $machineName = Get-NewMachineName -ConfigToCheck $oldConfig -vm $virtualMachine
        }
        Write-Verbose "Machine Name Generated $machineName"
    }
    else {
        $machineName = $Name
    }
    $virtualMachine.vmName = $machineName

    if ($null -eq $ConfigToModify.VirtualMachines) {
        $ConfigToModify | Add-Member -MemberType NoteProperty -Name "VirtualMachines" -Value @() -Force
    }
    
    if ($ConfigToModify.domainDefaults.UseDynamicMemory) {
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'dynamicMinRam' -Value "1GB" -force
    }
    else {
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'dynamicMinRam' -Value $virtualMachine.memory -force
    }

    $ConfigToModify.virtualMachines += $virtualMachine

    if ($role -eq "Primary" -or $role -eq "CAS" -or $role -eq "PassiveSite" -or $role -eq "SiteSystem" -or $role -eq "Secondary") {
        if ($null -eq $ConfigToModify.cmOptions) {
            $latestVersion = Get-CMLatestBaselineVersion
            $newCmOptions = [PSCustomObject]@{
                Version                   = $latestVersion
                Install                   = $true
                PushClientToDomainMembers = $true
                PrePopulateObjects        = $true
                EVALVersion               = $false
                #InstallSCP                = $true
                OfflineSCP                = $false
                OfflineSUP                = $false
                UsePKI                    = $false
            }
            $ConfigToModify | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $newCmOptions -force
        }
    }

    if ($role -eq "CAS") {
        Add-NewVMForRole -Role Primary -Domain $Domain -ConfigToModify $ConfigToModify -OperatingSystem $OperatingSystem -Quiet:$Quiet -parentSiteCode $virtualMachine.SiteCode -network:$virtualMachine.network
    }

    #if ($existingPrimary -gt 0) {
    #    ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).parentSiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Select-Object -First 1).siteCode
    #}

    if ($existingDPMP -eq 0) {
        if (-not $newSiteCode) {
            $newSiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).SiteCode
        }
        if (-not $test) {
            Write-Host "New Primary server found. Adding new DPMP for sitecode $newSiteCode"
        }
        Add-NewVMForRole -Role SiteSystem -Domain $Domain -ConfigToModify $ConfigToModify -OperatingSystem $OperatingSystem -SiteCode $newSiteCode -Quiet:$Quiet
    }
    if ($Role -eq "PassiveSite") {
        $SiteCode = $virtualMachine.SiteCode

        $primaryNode = $ConfigToModify.virtualMachines | Where-Object { $_.Role -in ("Primary", "CAS") -and $_.siteCode -eq $SiteCode }
        if ($primaryNode.Role -eq "Primary") {                 
            $DPsForSiteCode = $ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "SiteSystem" -and $_.siteCode -eq $SiteCode -and $_.installDP -eq $true }
            if (-not $DPsForSiteCode) {
                Add-NewVMForRole -Role SiteSystem -Domain $Domain -ConfigToModify $ConfigToModify -OperatingSystem $OperatingSystem -SiteCode $SiteCode -Quiet:$Quiet
            }
        }
    }
    if ($Role -eq "SQLAO" -and (-not $secondSQLAO)) {
        write-host "$($virtualMachine.VmName) is the 1st SQLAO"
        $SQLAONode = Add-NewVMForRole -Role SQLAO -Domain $Domain -ConfigToModify $ConfigToModify -OperatingSystem $OperatingSystem -Name $Name2 -secondSQLAO:$true -Quiet:$Quiet -ReturnMachineName:$true -network:$network
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'OtherNode' -Value $SQLAONode -force
        if ($test -eq $false ) {
            $FSName = select-FileServerMenu -ConfigToModify $ConfigToModify -HA:$false
            if ($FSName -eq "ESCAPE") {
                Remove-VMFromConfig -vmName $virtualMachine.vmName -ConfigToModify $ConfigToModify
                Remove-VMFromConfig -vmName $SQLAONode -ConfigToModify $ConfigToModify
                return
            }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'fileServerVM' -Value $FSName -force
        }
        #$virtualMachine | Add-Member -MemberType NoteProperty -Name 'SQLAgentAccount' -Value "SqlAgentUser"
        #$virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlServiceAccount' -Value "SqlServiceUser"
        $ClusterName = Get-NewMachineName -vm $virtualMachine -ConfigToCheck $ConfigToModify -ClusterName:$true -SkipOne:$true
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'ClusterName' -Value $ClusterName -force
        $AOName = Get-NewMachineName -vm $virtualMachine -ConfigToCheck $ConfigToModify -AOName:$true -SkipOne:$true
        $AGName = "SQL"
        if ($SiteCode) {
            $AGName = $siteCode
        }
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'AlwaysOnGroupName' -Value $($AGName + " Availibility Group") -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'AlwaysOnListenerName' -Value $AOName -force

        $ServiceAccount = "$($ClusterName)Svc"
        $AgentAccount = "$($ClusterName)Agent"

        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlServiceAccount' -Value $ServiceAccount -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlAgentAccount' -Value $AgentAccount -force

        $otherNode = $ConfigToModify.VirtualMachines | Where-Object { $_.vmName -eq $SQLAONode }
        $otherNode | Add-Member -MemberType NoteProperty -Name 'SqlServiceAccount' -Value $ServiceAccount -force
        $otherNode | Add-Member -MemberType NoteProperty -Name 'SqlAgentAccount' -Value $AgentAccount -force


    }
    if ($NewFSServer -eq $true) {
        #Get-PSCallStack | out-host
        $FSName = select-FileServerMenu -ConfigToModify $ConfigToModify -HA:$true
        if ($FSName -eq "ESCAPE") {
            Remove-VMFromConfig -vmName $virtualMachine.vmName -ConfigToModify $ConfigToModify
            return
        }
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'remoteContentLibVM' -Value $FSName
    }
    #Get-PSCallStack | out-host
    if (-not $Quiet) {
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigNotice "New Virtual Machine $machineName ($role) was added"
    }
    Write-verbose "[Add-NewVMForRole] Config: $ConfigToModify"
    if ($ReturnMachineName) {
        return $machineName
    }
}


function select-PullDPMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "CurrentValue")]
        [string] $CurrentValue = $null,
        [Parameter(Mandatory = $true, HelpMessage = "CurrentVM")]
        [object] $CurrentVM
    )
    #Get-PSCallStack | Out-Host
    $result = $null
    if ((Get-ListOfPossibleDPMP -Config $ConfigToModify -siteCode $CurrentVM.SiteCode).Count -eq 0) {
        $result = "n"
    }

    $additionalOptions += @{ "N" = "Create a DP VM" }

    while ([string]::IsNullOrWhiteSpace($result) -or $result -eq "ESCAPE") {
        Write-Log -Activity "Pull DP Source DP selection" -NoNewLine
        $result = Get-Menu2 -MenuName "Pull DP Source DP selection" -prompt "Select Source DP VM" -optionArray $(Get-ListOfPossibleDPMP -Config $ConfigToModify -siteCode $CurrentVM.SiteCode) -Test:$false -additionalOptions $additionalOptions -currentValue $CurrentValue
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            write-Log "Added new DPMP for SiteCode $($currentVM.SiteCode)"
            $result = Add-NewVMForRole -Role "SiteSystem" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true -SiteCode $CurrentVM.SiteCode
        }
    }
    return $result
}
function select-RemoteSQLMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "CurrentValue")]
        [string] $CurrentValue = $null
    )
    #Get-PSCallStack | Out-Host
    $result = $null
    if ((Get-ListOfPossibleSQLServers -Config $ConfigToModify).Count -eq 0) {
        $result = "n"
    }

    $additionalOptions = @{}

    $additionalOptions += @{ 
        "N"  = "Create new SQL Server" 
        "HN" = "Adds a new SQL VM to configuration"
    }

    while ([string]::IsNullOrWhiteSpace($result)) {
        Write-Log -Activity -NoNewLine "Remote SQL Server Selection"
        $result = Get-Menu2 -MenuName "Remote SQL Server Selection" -prompt "Select SQL VM" -optionArray $(Get-ListOfPossibleSQLServers -Config $ConfigToModify) -Test:$false -additionalOptions $additionalOptions -currentValue $CurrentValue
    }
    if ($result -eq "ESCAPE") {
        return "ESCAPE"
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            $result = Add-NewVMForRole -Role "SqlServer" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true
        }
    }
    return $result
}

function select-FileServerMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Display HA message")]
        [bool] $HA = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "CurrentValue")]
        [string] $CurrentValue = $null
    )
    #Get-PSCallStack | Out-Host
    $result = $null
    if (((Get-ListOfPossibleFileServers -Config $ConfigToModify).Count -eq 0) -and [string]::IsNullOrWhiteSpace($CurrentValue)) {
        $result = "n"
    }

    $additionalOptions = @{}
    if ($HA) {
        $additionalOptions += @{ 
            "N"  = "Create new FileServer to host Content Library (Needed for HA)"
            "HN" = "ContentLib must be moved to a remote server to enable High Availability"
        }
    }
    else {
        $additionalOptions += @{
            "N"  = "Create a New FileServer VM"
            "HN" = "SQL Always On needs a quorum share. This will be stored on a FileServer" 
        }
    }
    while ([string]::IsNullOrWhiteSpace($result) ) {
        #Allow ESCAPE to pass thru.. handled by caller
        #Write-Log -Activity "Fileserver selection.  FileServer is needed for Remote ContentLib (HA), and Quorum for SQLAO"
        $result = Get-Menu2 -MenuName "Fileserver selection.  FileServer is needed for Remote ContentLib (HA), and Quorum for SQLAO" -prompt "Select FileServer VM" -optionArray $(Get-ListOfPossibleFileServers -Config $ConfigToModify) -Test:$false -additionalOptions $additionalOptions -currentValue $CurrentValue
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            $result = Add-NewVMForRole -Role "FileServer" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true
        }
    }
    return $result
}

function Get-ListOfPossibleSQLServers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $Config = $global:config
    )
    $SQLList = @()
    $SQL = $Config.virtualMachines | Where-Object { $_.sqlVersion }
    foreach ($item in $SQL) {
        $existing = @()
        $existing += $Config.virtualMachines | Where-Object { ($_.Role -eq "WSUS" -and ($_.RemoteSQLVM -eq $item.vmName)) -or ($_.InstallSUP -and $item.vmName -eq $_.vmName) }
        if (-not $existing) {
            $SQLList += $item.vmName
        }
    }
    $domain = $Config.vmOptions.DomainName
    if ($null -ne $domain) {
        $SQLFromList = get-list -type VM -domain $domain | Where-Object { $_.sqlVersion }
        foreach ($item in $SQLFromList) {
            $existing = @()
            $existing += get-list -type VM -domain $domain | Where-Object { ($_.Role -eq "WSUS" -and ($_.RemoteSQLVM -eq $item.vmName)) -or ($_.InstallSUP -and $item.vmName -eq $_.vmName) }
            $existing += $Config.virtualMachines | Where-Object { ($_.Role -eq "WSUS" -and ($_.RemoteSQLVM -eq $item.vmName)) -or ($_.InstallSUP -and $item -eq $_.vmName) }
            if (-not $existing) {
                $SQLList += $item.vmName
            }
        }
    }
    else {
        if ($null -ne $Config ) {
            Write-Verbose $Config | ConvertTo-Json | Out-Host
        }
        else {
            write-host "Config was null!"
            Get-PSCallStack | Out-Host
        }
    }
    return $SQLList
}
function Get-ListOfPossibleFileServers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $Config = $global:config
    )
    $FSList = @()
    $FS = $Config.virtualMachines | Where-Object { $_.role -eq "FileServer" }
    foreach ($item in $FS) {
        $FSList += $item.vmName
    }
    $domain = $Config.vmOptions.DomainName
    if ($null -ne $domain) {
        $FSFromList = get-list -type VM -domain $domain | Where-Object { $_.role -eq "FileServer" }
        foreach ($item in $FSFromList) {
            $FSList += $item.vmName
        }
    }
    else {
        if ($null -ne $Config ) {
            Write-Verbose $Config | ConvertTo-Json | Out-Host
        }
        else {
            write-host "Config was null!"
            Get-PSCallStack | Out-Host
        }
    }
    return $FSList
}

function Get-ListOfPossibleDPMP {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $Config = $global:config,
        [Parameter(Mandatory = $true, HelpMessage = "SiteCode")]
        [string] $siteCode


    )
    $FSList = @()
    $FS = $Config.virtualMachines | Where-Object { $_.InstallDP -eq $true -and -not $_.enablePullDP -and $_.SiteCode -eq $SiteCode }
    foreach ($item in $FS) {

        $FSList += $item.vmName

    }
    $domain = $Config.vmOptions.DomainName
    if ($null -ne $domain) {
        $FSFromList = get-list -type VM -domain $domain | Where-Object { $_.InstallDP -eq $true -and -not $_.enablePullDP -and $_.SiteCode -eq $SiteCode }
        foreach ($item in $FSFromList) {
            $FSList += $item.vmName
        }
    }
    else {
        if ($null -ne $Config ) {
            Write-Verbose $Config | ConvertTo-Json | Out-Host
        }
        else {
            write-host "Config was null!"
            Get-PSCallStack | Out-Host
        }
    }
    return $FSList
}


function show-NewVMMenu {

    param (
        [string]$role,
        [string]$SiteCode
    )

    write-log -Verbose "show-NewVMMenu called wite $role $SiteCode"
    if (-not $role) {
        $role = Select-RolesForExisting -enhance:$true
        if (-not $role) {
            return
        }
        if ($role -eq "H") {
            $role = "PassiveSite"
        }
        if ($role -eq "L") {
            $role = "Linux"
        }
    }

    $parentSiteCode = Get-ParentSiteCodeMenu -role $role -CurrentValue $null -Domain $Global:Config.vmOptions.domainName

    if ($role -eq "Secondary") {
        if (-not $parentSiteCode) {
            return
        }
    }

    if ($role -eq "PassiveSite") {
        $existingPassive = @()
        $existingSS = @()


        $existingPassive += Get-List2 -deployConfig $global:config | Where-Object { $_.Role -eq "PassiveSite" }
        $existingSS += Get-List2 -deployConfig $global:config | Where-Object { $_.Role -eq "CAS" -or $_.Role -eq "Primary" }

        $existingSS = $existingSS | Where-Object { $_ }
        $exisitingPassive = $exisitingPassive | Where-Object { $_ }

        $PossibleSS = @()
        foreach ($item in $existingSS) {
            if ($existingPassive.SiteCode -contains $item.Sitecode) {
                continue
            }
            $PossibleSS += $item
        }

        if ($PossibleSS.Count -eq 0) {
            Write-Host
            Write-Host "No siteservers found that are eligible for HA"
            return
        }
        if (-not $SiteCode) {
            #Write-Log -Activity -NoNewLine "Enable CM High Availability"
            $result = Get-Menu2 -MenuName "Enable CM High Availability" -Prompt "Select sitecode to expand to HA" -OptionArray $PossibleSS.Sitecode -Test $false -return
            if ([string]::IsNullOrWhiteSpace($result) -or $result -eq "ESCAPE") {
                return
            }
            $SiteCode = $result
        }
    }
    #$os = Select-OSForNew -Role $role

    $machineName = Add-NewVMForRole -Role $Role -Domain $Global:Config.vmOptions.domainName -ConfigToModify $global:config  -parentSiteCode $parentSiteCode -SiteCode $siteCode -ReturnMachineName $true
    if ($role -eq "DC") {
        while ($true) {
            $domain = select-NewDomainName
            if (-not [string]::IsNullOrEmpty($domain) -and $domain -ne "ESCAPE") {   
                $Global:Config.vmOptions.domainName = $domain
            }
            else {
                continue
            }
            $Global:Config.vmOptions.prefix = get-PrefixForDomain -Domain $($Global:Config.vmOptions.domainName)
            $netbiosName = $Global:Config.vmOptions.domainName.Split(".")[0]
            $Global:Config.vmOptions.DomainNetBiosName = $netbiosName
            break
        }
    }
    Get-TestResult -SuccessOnError | out-null
    if (-not $machineName) {
        return
    }
    write-log -verbose "Returned machineName $machineName"
    return $machineName
}


function Select-VirtualMachines {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "pre supplied response")]
        [string] $response = $null
    )

    if (-not $response) {
        
        Write-Log -LogOnly "Select VirtualMachines NO response = $response"
        return
    }

    Write-Log -Activity -NoNewLine "Select VirtualMachines"
    #Write-Host
    Write-Verbose "8 Select-VirtualMachines"
    
    Write-Log -LogOnly "Select VirtualMachines response = $response"
    if ([String]::IsNullOrWhiteSpace($response)) {
        return
    }
    if (-not [String]::IsNullOrWhiteSpace($response)) {
        if ($response.ToLowerInvariant() -eq "n") {
            $machineName = show-NewVMMenu
            write-log  -verbose "Got MachineName $machineName from show-NewVMMenu"

            if (-not $machineName) {
                return
            }
        }
        :VMLoop while ($true) {
            $i = 0
            $existingVM = $false

            if (-not $machineName) {
                $machineName = $response
            }
            foreach ($virtualMachine in $global:existingMachines) {
                $i = $i + 1
                if (($i -eq $response) -or ($machineName -and $machineName -eq $virtualMachine.vmName) ) {
                    $machineName = $virtualMachine.vmName
                    $response = $null
                    $existingVM = $true
                    $customOptions = [ordered] @{}
                    $customOptions += [ordered]@{
                        "D"  = "Delete this VM from Hyper-V"
                        "HD" = "Danger: This will permanently delete the VM from Hyper-V"
                    }
                    $customOptions += [ordered]@{
                        "*N2" = ""
                        "*BN" = "Add new Disk%$($Global:Common.Colors.GenConfigHeader)"
                        "N"   = "Add a new VHDX to this VM" 
                        "HN"  = "This will stop the VM, create a new drive, and add it to the vm, the start it."
                    }
                    if ($virtualMachine.OperatingSystem -and $virtualMachine.OperatingSystem.Contains("Server")) {


                        if ($virtualMachine.Role -in ("Primary", "CAS")) {
                            $existingPassive += Get-List2 -deployConfig $global:config | Where-Object { $_.SiteCode -eq $virtualMachine.SiteCode -and $_.Role -eq "PassiveSite" }
                            if (-not $existingPassive) {
                                
                                # No Passive Site for this sitecode.. We can offer it here.
                                $customOptions += [ordered]@{"*B2" = ""; "*BS" = "CM High Availability%$($Global:Common.Colors.GenConfigHeader)"; "H" = "Add a Passive Node for this Site Server" }

                            }
                        }

                        if ($virtualMachine.Role -notin ("DC", "BDC")) {
                            if ($null -eq $virtualMachine.sqlVersion) {
                                switch ($virtualMachine.Role) {
                                    "Secondary" {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "S" = "Use Full SQL for Secondary Site" }
                                    }
                                    "WSUS" {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "S" = "Configure WSUS SQL Server" }
                                    }
                                    Default {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "S" = "Add SQL" }
                                    }
                                }
                            }
                            else {

                                switch ($virtualMachine.Role) {
                                    "Secondary" {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "X" = "Remove Full SQL and use SQL Express for Secondary Site" }
                                    }
                                    "WSUS" {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "S" = "Configure WSUS SQL Server" }
                                    }
                                    Default {
                                        #$customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%$($Global:Common.Colors.GenConfigHeader)"; "X" = "Remove SQL" }
                                    }
                                }
                            }
                        }
                    }

                    $newValue = "Start"
                    $virtualMachine  | Add-Member -MemberType NoteProperty -Name "ExistingVM" -Value $true -Force
                    if ($machineName) {
                        $machineName = $virtualMachine.vmName
                    }
                    #Write-Log -Activity -NoNewLine "Modify Properties for $($virtualMachine.VMName)"
                    $newValue = Select-Options -MenuName "Modify Properties for $($virtualMachine.VMName)" -propertyEnum $virtualMachine -PropertyNum 1 -prompt "Which VM property to modify" -additionalOptions $customOptions -Test:$true -HelpFunction "Get-GenericHelp"
                    #$newValue = Select-Options -Property $clone -prompt "Which Existing VM property to modify" -additionalOptions $customOptions -Test:$true
                    if ([string]::IsNullOrEmpty($newValue) -or $newValue -eq "ESCAPE") {
                        return
                    }
                    if ($newValue -eq "REFRESH") {
                        continue VMLoop
                    }

                    if ($newValue -contains "NEWNAME:") {
                        if ($machineName) {
                            $machineName = $newValue.Split(":")[1]
                        }
                        continue VMLoop
                    }

                    write-log -logonly "Modify properties returned $newValue"
                    if ($newValue -eq "D") {
                        $response2 = Read-YesorNoWithTimeout -Prompt "Delete VM $($virtualMachine.vmName)? (Y/n)" -HideHelp -timeout 180 -Default "y"

                        if ($response2 -and ($response2.ToLowerInvariant() -eq "n" -or $response2.ToLowerInvariant() -eq "no")) {
                            continue VMLoop
                        }
                        else {
                            Remove-VirtualMachine -VmName $virtualMachine.vmName
                            if ($global:Config.existingVirtualMachines) {
                                $global:Config.existingVirtualMachines = $global:Config.existingVirtualMachines | where-object { $_.vmName -ne $virtualMachine.vmName }
                            }
                            Get-List -type VM -SmartUpdate | Out-Null
                            New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
                            return
                        }                        
                    }
                    if ($newValue -eq "H") {
                        Write-Log -Verbose "Calling show-NewVMMenu to add passive node"
                        show-NewVMMenu -SiteCode $virtualMachine.SiteCode -role "PassiveSite"
                        return
                    }
                    if ($newValue -eq "N") {

                        Write-Log -Verbose "Adding new disk to VM"
                        $count = 0
                        $VmName = $virtualMachine.vmName
                        $vmObject = get-vm2 -name $VmName
                        Write-Log "Stopping $VmName"
                        $stopped = Stop-Vm2 -Name $VmName -Passthru
                        if (-not $stopped) {
                            Write-Log "$VmName`: VM Not Stopped."
                            return $false
                        }
                        while ($true) {
                            $count++

                            $Label = "NewDisk_$count"                        
                            $newDiskName = "$VmName`_$label.vhdx"
                            $newDiskPath = Join-Path $vmObject.Path $newDiskName
                            if (Test-Path $newDiskPath) {
                                continue
                            }
                            break
                        }
                        $size = "500GB"
                        Write-Log "$VmName`: Adding $newDiskPath"
                        if (-not $Migrate) {
                            New-VHD -Path $newDiskPath -SizeBytes ($size / 1) -Dynamic | out-null
                        }
                        if (-not (Test-Path $newDiskPath)) {
                            Write-Log "Failed to find $newDiskPath" -Failure
                            return
                        }
                        Add-VMHardDiskDrive -VMName $VmName -Path $newDiskPath | out-null
                        Write-Log "Starting $VmName"
                        $Started = Start-Vm2 -Name $VmName -Passthru
                        if (-not $Started) {
                            Write-Log "$VmName`: VM Not Started."
                            return $false
                        }
                        $connected = Wait-ForVM -VmName $VMname -PathToVerify "C:\Users" -VmDomainName $virtualMachine.Domain -TimeoutMinutes 2 -Quiet
                        if (-not $connected) {
                            #Write-Progress2 -Log -PercentComplete 0 -Activity "StartVM" -Status "Could not connect to the VM after waiting for 2 minutes."
                            Write-Log "$VmName`: Could not connect to the VM after waiting for 2 minutes."
                            return $false
                        }
                        Write-Log "Initializing disk.." -NoNewLine
                        $result = Invoke-VmCommand -VmName $VmName -VmDomainName $virtualMachine.Domain -ScriptBlock $global:Initialize_Disk -SuppressLog -ArgumentList @("AUTO", $size, $label)
                        if ($result.ScriptBlockFailed) {
                            Write-Log "Could not Initialize new disk" -LogOnly
                        }
                        else {
                            Write-Log ".done"
                        }
                        return
                    }
                    return
                }
            }


            $found = $false
            if ($machineName) {
                foreach ($virtualMachine in $global:config.virtualMachines | Where-Object { -not $_.Hidden }) {
                    if ($machineName -eq $virtualMachine.vmName) {
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    return
                }
            }


            $ii = 0
            foreach ($virtualMachine in $global:config.virtualMachines | Where-Object { -not $_.Hidden }) {
                $i = $i + 1
                $ii++
                if ($i -eq $response -or ($machineName -and $machineName -eq $virtualMachine.vmName)) {
                    $newValue = "Start"
                    $machineName = $virtualMachine.vmName                    
                    while ($newValue -ne "D" -and -not ([string]::IsNullOrWhiteSpace($($newValue)))) {
                        Write-Log -HostOnly -Verbose "NewValue = '$newvalue'"
                        $customOptions = [ordered]@{ 
                            "*B1" = ""
                            "*B"  = "Disks%$($Global:Common.Colors.GenConfigHeader)"
                            "A"   = "Add Additional Disk"
                            "HA"  = "Add an additional VHDX to this VMs configuration"
                        }
                        if ($null -eq $virtualMachine.additionalDisks) {
                        }
                        else {
                            $customOptions += [ordered]@{
                                "R"  = "Remove Last Additional Disk"
                                "HR" = "The last disk added to this configuration will be removed"
                            }
                        }
                        if (($virtualMachine.Role -eq "Primary") -or ($virtualMachine.Role -eq "CAS")) {
                            $customOptions += [ordered]@{
                                "*B2" = ""
                                "*BS" = "ConfigMgr%$($Global:Common.Colors.GenConfigHeader)"
                                "S"   = "Configure SQL (Set local or remote [Standalone or Always-On] SQL)" 
                                "HS"  = "Opens the SQL configuration menu for this VM"
                            }
                            $PassiveNode = $global:config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $virtualMachine.siteCode }
                            if ($PassiveNode) {
                                $customOptions += [ordered]@{
                                    "H"  = "Remove High Availibility (HA) - Removes the Passive Site Server" 
                                    "HH" = "Removes the PassiveSite VM from the configuration."
                                }
                            }
                            else {
                                $customOptions += [ordered]@{
                                    "H"  = "Enable High Availibility (HA) - Adds a Passive Site Server"
                                    "HH" = "Adds a PassiveSite VM to configuration, when deployed will be automatically configured for High Availability"
                                }
                            }
                        }
                        else {
                            if ($virtualMachine.Role -eq "DomainMember") {
                                if (-not $virtualMachine.domainUser) {
                                    $customOptions += [ordered]@{
                                        "*U"   = ""
                                        "*BU2" = "Domain User (This account will be made a local admin)%$($Global:Common.Colors.GenConfigHeader)"
                                        "U"    = "Add domain user as admin on this machine" 
                                        "HU"   = "Create a new Active Directory user who will be configured as an admin on this VM"
                                    }
                                }
                                else {
                                    $customOptions += [ordered]@{"*U" = ""
                                        "*BU2"                        = "Domain User%$($Global:Common.Colors.GenConfigHeader)"
                                        "U"                           = "Remove domainUser from this machine"
                                        "HU"                          = "Do not add a admin user to this machine.  Only the domain admin account will be a local admin"
                                    }
                                }
                            }
                            if ($virtualMachine.OperatingSystem -and $virtualMachine.OperatingSystem.Contains("Server")) {


                                if ($virtualMachine.Role -notin ("DC", "BDC")) {
                                    if ($null -eq $virtualMachine.sqlVersion) {
                                        switch ($virtualMachine.Role) {
                                            "Secondary" {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "S"   = "Use Full SQL for Secondary Site" 
                                                    "HS"  = "Adds a SQL instance on this VM and uses it for the CM Secondary Database"
                                                }
                                            }
                                            "WSUS" {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "S"   = "Configure WSUS SQL Server" 
                                                    "HS"  = "Opens a menu to select the SQL instance WSUS will use"
                                                }
                                            }
                                            Default {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "S"   = "Add SQL" 
                                                    "HS"  = "Adds a SQL instance to this machine"
                                                }
                                            }
                                        }
                                    }
                                    else {

                                        switch ($virtualMachine.Role) {
                                            "Secondary" {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "X"   = "Remove Full SQL and use SQL Express for Secondary Site" 
                                                    "HX"  = "Remove the SQL configuration from this VM, and instruct the secondary site to install SQL Express"
                                                }
                                            }
                                            "WSUS" {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "S"   = "Configure WSUS SQL Server"
                                                    "HS"  = "Opens a menu to select the SQL instance WSUS will use" 
                                                }
                                            }
                                            Default {
                                                $customOptions += [ordered]@{
                                                    "*B2" = ""
                                                    "*BS" = "SQL%$($Global:Common.Colors.GenConfigHeader)"
                                                    "X"   = "Remove SQL" 
                                                    "HX"  = "Removes the SQL configuraion from this VM"
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        $customOptions += [ordered]@{
                            "*B3" = ""
                            "*BD" = "VM Management%$($Global:Common.Colors.GenConfigHeader)"
                            "Z"   = "Remove this VM from config%$($Global:Common.Colors.GenConfigDangerous)%$($Global:Common.Colors.GenConfigDangerous)" 
                            "HZ"  = "Deletes this VM from the current configuration"
                        }
                        #Write-Log -Activity -NoNewLine "Modify Properties for $($virtualMachine.VMName)"
                        $newValue = Select-Options -MenuName "Modify Properties for $($virtualMachine.VMName)" -propertyEnum $global:config.virtualMachines -PropertyNum $ii -prompt "Which VM property to modify" -additionalOptions $customOptions -Test:$false -HelpFunction "Get-GenericHelp"
                        if ([string]::IsNullOrEmpty($newValue) -or $newValue -eq "ESCAPE") {
                            return
                        }
                        if ($newValue -eq "REFRESH") {
                            if ($machineName) {
                                return
                            }
                            continue VMLoop
                        }
                        if ($null -ne $newValue -and $newValue -is [string]) {
                            $newValue = [string]$newValue.Trim()
                            #Write-Host "NewValue = '$newValue'"
                            $newValue = [string]$newValue.ToUpper()
                        }
                        if (([string]::IsNullOrEmpty($newValue))) {
                            break VMLoop
                        }
                        if ($newValue -eq "H") {
                            $PassiveNode = $global:config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $virtualMachine.siteCode }
                            if ($PassiveNode) {
                                $FSVM = $global:config.virtualMachines | Where-Object { $_.vmName -eq $PassiveNode.remoteContentLibVM }
                                if ($FSVM) {
                                    $OtherVMs = $global:config.virtualMachines | Where-Object { $_.fileServerVM -eq $FSVM.vmName } 
                                    $OtherVMs2 = $global:config.virtualMachines | Where-Object { $_.remoteContentLibVM -eq $FSVM.vmName -and $_.vmname -ne $PassiveNode.vmName } 
                                    if (-not $OtherVMs -and -not $OtherVMs2) {
                                        write-host
                                        Write-OrangePoint "$($FSVM.vmName) is not in use by any other vm's.  Removing from config"
                                        Remove-VMFromConfig -vmName $FSVM.vmName -ConfigToModify $global:config
                                    }
                                }
                                #$virtualMachine.psobject.properties.remove('remoteContentLibVM')
                                Remove-VMFromConfig -vmName $PassiveNode.vmName -ConfigToModify $global:config
                            }
                            else {
                                Add-NewVMForRole -Role "PassiveSite" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $($virtualMachine.vmName + "-P")  -SiteCode $virtualMachine.siteCode -OperatingSystem $virtualMachine.OperatingSystem
                            }
                            continue VMLoop

                        }
                        if ($newValue -eq "U") {
                            if ($virtualMachine.domainUser) {
                                $virtualMachine.psobject.properties.remove('domainUser')
                            }
                            else {
                                Get-DomainUser -property $virtualMachine -name "domainUser"
                                #$virtualMachine | Add-Member -MemberType NoteProperty -Name 'domainUser' -Value "bob"
                            }
                        }
                        if ($newValue -eq "S") {
                            if ($virtualMachine.Role -in ("Primary", "CAS", "WSUS")) {
                                Get-remoteSQLVM -property $virtualMachine
                                continue VMLoop
                            }
                            else {
                                $SqlVersion = "SQL Server 2022"
                                if ($ConfigToModify.domainDefaults.DefaultSqlVersion) {
                                    $SqlVersion = $ConfigToModify.domainDefaults.DefaultSqlVersion
                                }
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value $SqlVersion -force
                                if ($virtualMachine.AdditionalDisks.E) {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "E:\SQL" -force
                                }
                                else {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "C:\SQL" -force
                                }
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlServiceAccount' -Value "LocalSystem" -force
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SqlAgentAccount' -Value "LocalSystem" -force
                                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $true -force
                                }
                                if ($virtualMachine.Role -ne "Secondary") {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlPort' -Value "1433" -force
                                }
                                $virtualMachine.virtualProcs = 4
                                if ($($virtualMachine.memory) / 1GB -lt "4GB" / 1GB) {
                                    $virtualMachine.memory = "4GB"
                                }
                                if ($virtualMachine.role -eq "Secondary") {
                                    if ($($virtualMachine.memory) / 1GB -lt "4GB" / 1GB) {
                                        $virtualMachine.memory = "4GB"
                                    }
                                }

                                $newName = Rename-VirtualMachine -vm $virtualMachine

                            }
                        }
                        if ($newValue -eq "X") {
                            $virtualMachine.psobject.properties.remove('sqlversion')
                            $virtualMachine.psobject.properties.remove('sqlInstanceDir')
                            $virtualMachine.psobject.properties.remove('sqlInstanceName')
                            $virtualMachine.psobject.properties.remove('sqlPort')
                            $virtualMachine.psobject.properties.remove('SqlServiceAccount')
                            $virtualMachine.psobject.properties.remove('SqlAgentAccount')
                            if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                            }
                            $newName = Rename-VirtualMachine -vm $virtualMachine
                        }
                        if ($newValue -eq "A") {
                            if ($null -eq $virtualMachine.additionalDisks) {
                                $disk = [PSCustomObject]@{"E" = "400GB" }
                                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk -force
                            }
                            else {
                                $letters = 69
                                $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                    $letters++
                                }
                                if ($letters -lt 90) {
                                    $letter = $([char]$letters).ToString()
                                    $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name $letter -Value "250GB" -force
                                }
                            }
                        }
                        if ($newValue -eq "R") {
                            $diskscount = 0
                            $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                $diskscount++
                            }
                            if ($virtualMachine.Role -eq "FileServer") {
                                if ($diskscount -le 2) {
                                    write-host
                                    write-redx "FileServers must have at least 2 disks"
                                    Continue VMLoop
                                }
                            }
                            if ($virtualMachine.SqlInstanceDir) {
                                $neededDisks = 0
                                if ($virtualMachine.SqlInstanceDir.StartsWith("E:")) {
                                    $neededDisks = 1
                                }
                                if ($virtualMachine.SqlInstanceDir.StartsWith("F:")) {
                                    $neededDisks = 2
                                }
                                if ($virtualMachine.SqlInstanceDir.StartsWith("G:")) {
                                    $neededDisks = 3
                                }
                                if ($diskscount -le $neededDisks) {
                                    write-host
                                    write-redx "SQL is configured to install to the disk we are trying to remove. Can not remove"
                                    Continue VMLoop
                                }
                            }

                            if ($virtualMachine.cmInstallDir) {
                                $neededDisks = 0
                                if ($virtualMachine.cmInstallDir.StartsWith("E:")) {
                                    $neededDisks = 1
                                }
                                if ($virtualMachine.cmInstallDir.StartsWith("F:")) {
                                    $neededDisks = 2
                                }
                                if ($virtualMachine.cmInstallDir.StartsWith("G:")) {
                                    $neededDisks = 3
                                }
                                if ($diskscount -le $neededDisks) {
                                    write-host
                                    write-redx "ConfigMgr is configured to install to the disk we are trying to remove. Can not remove"
                                    Continue VMLoop
                                }
                            }

                            if ($virtualMachine.wsusContentDir) {
                                $neededDisks = 0
                                if ($virtualMachine.wsusContentDir.StartsWith("E:")) {
                                    $neededDisks = 1
                                }
                                if ($virtualMachine.wsusContentDir.StartsWith("F:")) {
                                    $neededDisks = 2
                                }
                                if ($virtualMachine.wsusContentDir.StartsWith("G:")) {
                                    $neededDisks = 3
                                }
                                if ($diskscount -le $neededDisks) {
                                    write-host
                                    write-redx "WSUS is configured to use to the disk we are trying to remove. Can not remove"
                                    Continue VMLoop
                                }
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
                        if (-not ($newValue -eq "Z")) {
                            Get-TestResult -SuccessOnError | out-null
                        }
                        else {
                            break VMLoop
                        }
                    }
                    break VMLoop
                }
            }
        }
        if ($newValue -eq "Z") {
            write-log -verbose "Removing machine $response or $machineName"
            $i = 0
            $removeVM = $true
            foreach ($virtualMachine in $global:existingMachines) {
                $i = $i + 1
            }
            foreach ($virtualMachine in $global:config.virtualMachines) {
                $i = $i + 1
                if ($i -eq $response -or ($machineName -and $machineName -eq $virtualMachine.vmName)) {
                    #if ($i -eq $response) {
                    Write-Log -Activity -NoNewLine "Remove $($virtualMachine.vmName) from current config"
                    $response = Read-YesorNoWithTimeout -Prompt "Are you sure you want to remove $($virtualMachine.vmName)? (Y/n)" -HideHelp -Default "y"
                    if ($response -and ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no")) {
                    }
                    else {
                        if ($virtualMachine.role -eq "FileServer") {

                            foreach ($testVM in $global:config.virtualMachine) {
                                if ($testVM.remoteContentLibVM -eq $virtualMachine.vmName) {
                                    Write-Host
                                    write-host2 -ForegroundColor Khaki "This VM is currently used as the RemoteContentLib for $($testVM.vmName) and can not be deleted at this time."
                                    $removeVM = $false
                                }
                                if ($testVM.fileServerVM -eq $virtualMachine.vmName) {
                                    Write-Host
                                    write-host2 -ForegroundColor Khaki "This VM is currently used as the fileServerVM for $($testVM.vmName) and can not be deleted at this time."
                                    $removeVM = $false
                                }
                            }

                            $SQLAOVMs = $global:config.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.fileServerVM }
                            if ($SQLAOVMs) {
                                foreach ($SQLAOVM in $SQLAOVMs) {
                                    if ($SQLAOVM.fileServerVM -eq $virtualMachine.vmName) {
                                        Write-Host
                                        write-host2 -ForegroundColor Khaki "This VM is currently used as the fileServerVM for $($SQLAOVM.vmName) and can not be deleted at this time."
                                        $removeVM = $false
                                    }
                                }
                            }
                        }
                        if ($virtualMachine.role -eq "SQLAO") {
                            if (-not ($virtualMachine.OtherNode)) {
                                Write-Host
                                write-host2 -ForegroundColor Khaki "This VM is Secondary node in a SQLAO cluster. Please delete the Primary node to remove both VMs"
                                $removeVM = $false
                            }
                            else {
                                Remove-VMFromConfig -vmName $virtualMachine.OtherNode -ConfigToModify $global:config
                            }
                        }
                        if ($removeVM -eq $true) {
                            Remove-VMFromConfig -vmName $virtualMachine.vmName -ConfigToModify $global:config
                        }

                    }
                }
            }
            return
        }
    }
    else {
        Get-TestResult -SuccessOnError | Out-Null
        return
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
        $children = ($ConfigToModify.virtualMachines | Where-Object { $_.ParentSiteCode -eq $DeletedVM.SiteCode })

        foreach ($child in $children ) {
            $child.parentSiteCode = $null
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
        #    Write-Log -HostOnly -Verbose "(1)Returning File: $fileName"
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
        $config | ConvertTo-Json -Depth 5 | Out-File $fullfilename
        Write-Host "Saved to $fullfilename"
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

    $config | ConvertTo-Json -Depth 5 | Out-File $filename
    #$return.ConfigFileName = Split-Path -Path $fileName -Leaf
    Write-Host "Saved to $filename"
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
    $Global:Config = Select-ConfigMenu


    # $DeployConfig = (Test-Configuration -InputObject $Global:Config).DeployConfig

    $valid = $false
    while ($valid -eq $false) {
        $global:StartOver = $false
        $return.DeployNow = Select-MainMenu
        if ($global:StartOver -eq $true) {
            Write-Host2 -ForegroundColor MediumAquamarine "Saving Configuration... use ""!"" to return."
            $Global:SavedConfig = $global:config
            $DeployConfig = $null
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
            $response = Read-YesorNoWithTimeout -Prompt "Everything correct? (Y/n)" -HideHelp -timeout 180 -Default "y"
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
} while ($null -ne $Global:SavedConfig -and $global:StartOver -eq $true)

$return.ConfigFileName = Save-Config $Global:Config


if (-not $InternalUseOnly.IsPresent) {
    Write-Host "You may deploy this configuration by running the following command:"
    Write-Host "$($PSScriptRoot)\New-Lab.ps1 -Configuration ""$($return.ConfigFileName)"""
    Add-CmdHistory "$($PSScriptRoot)\New-Lab.ps1 -Configuration ""$($return.ConfigFileName)"""
}

#================================= NEW LAB SCENERIO ============================================
if ($InternalUseOnly.IsPresent) {
    $domainExists = Get-List -Type VM -DomainName $Global:Config.vmOptions.domainName
    if ($domainExists -and ($return.DeployNow)) {
        write-host2 -ForegroundColor $Global:Common.Colors.GenConfigNotice "This configuration will make modifications to $($Global:Config.vmOptions.DomainName)"
        Write-OrangePoint -NoIndent "Without a snapshot, if something fails it may not be possible to recover"
        $response = Read-YesorNoWithTimeout -Prompt "Do you wish to take a Hyper-V snapshot of the domain now? (y/N)" -HideHelp -Default "n" -timeout 30
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

