# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
############################
### Menu Functions ###
############################
#Common.menu.ps1

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
        [object] $color2,
        [switch] $MultiSelect = $false,
        [switch] $MultiSelected = $false
    )

    Write-Log -verbose "Write-Option called with option: $option, text: $text, color: $color, color2: $color2, MultiSelect: $MultiSelect, MultiSelected: $MultiSelected"
    if ($null -eq $color) {
        $color = $Global:Common.Colors.GenConfigNormal
        $color2 = $Global:Common.Colors.GenConfigNormalNumber
    }
    if ($null -eq $color2) {
        $color2 = $color
    }
    #trim the colors to remove spaces
    $color = $color.Trim()
    $color2 = $color2.Trim()
    
    if ($MultiSelect) {
        $optionInt = $option -as [int]
        if ($optionInt) {                    
            write-host2 "[" -NoNewline -ForegroundColor Yellow
            if ($MultiSelected) {
                $CHECKMARK = ([char]8730)
                Write-Host2 -ForegroundColor green $CHECKMARK -NoNewline
            }
            else {
                Write-Host2 -ForegroundColor Yellow " " -NoNewline
            }
            write-host2 "] " -NoNewline -ForegroundColor Yellow
        }
        else {
            write-host "    " -NoNewline
        }
    }
    write-host2 "[" -NoNewline -ForegroundColor $Global:Common.Colors.GenConfigBrackets
    Write-Host2 -ForegroundColor $color2 $option -NoNewline
    Write-Host2 "] ".PadRight(4 - $option.Length) -NoNewLine -ForegroundColor $Global:Common.Colors.GenConfigBrackets

    # Truncate text to fit terminal width (accounts for prefix already written).
    # Prefix width: 3 (arrow/spaces) + 1 ([) + option.Length + PadRight(4-len) + already at column ~8.
    # MultiSelect prepends an extra "[X] " or "    " (4 chars) before the brackets.
    $prefixLen = 3 + 1 + $option.Length + [Math]::Max(0, 4 - $option.Length)
    if ($MultiSelect) { $prefixLen += 4 }
    # Get-LiveWindowSize (from Common.NewMenu.ps1) reads a fresh CONOUT$ handle
    # so it reflects post-resize width even when the .NET console cache is stale.
    # Both [Console]::WindowWidth and $host.UI.RawUI.WindowSize.Width can return
    # the old size after a resize, causing this truncation to use the wrong
    # budget and let rows wrap onto the next line.
    $termWidth = 0
    try {
        if (Get-Command Get-LiveWindowSize -ErrorAction Ignore) {
            $live = Get-LiveWindowSize
            if ($live) { $termWidth = [int]$live.Width }
        }
    } catch { }
    if (-not $termWidth) { $termWidth = [Console]::WindowWidth }
    if (-not $termWidth) { $termWidth = $host.UI.RawUI.WindowSize.Width }
    # Subtract 2 (not 1) so we never write to the final column. Writing the
    # last cell on Windows conhost triggers an automatic newline; the explicit
    # Write-Host at the end of this function would then add a SECOND newline,
    # shifting every later menu row down by 1 and breaking arrow positioning.
    $availWidth = $termWidth - $prefixLen - 2
    if ($availWidth -gt 0 -and $text) {
        $hasAnsi = $text.Contains([char]27)
        if ($hasAnsi) {
            $ansiPat = [char]27 + '\[[0-9;]*[A-Za-z]'
            $plainLen = [regex]::Replace($text, $ansiPat, '').Length
        }
        else {
            $plainLen = $text.Length
        }
        if ($plainLen -gt $availWidth) {
            # Walk the string counting visible chars (skipping ANSI), cut at limit.
            # ANSI CSI sequences end on any letter (A-Z, a-z), not just 'm' --
            # cursor moves (e.g. ESC[12A) and erases (ESC[2K) would otherwise
            # leave $inEsc=$true and silently consume all later visible chars.
            $visCount = 0
            $cutIdx = $text.Length
            $inEsc = $false
            for ($ci = 0; $ci -lt $text.Length; $ci++) {
                if ($text[$ci] -eq [char]27) { $inEsc = $true; continue }
                if ($inEsc) {
                    $ch = $text[$ci]
                    if (($ch -ge 'A' -and $ch -le 'Z') -or ($ch -ge 'a' -and $ch -le 'z')) {
                        $inEsc = $false
                    }
                    continue
                }
                $visCount++
                if ($visCount -ge $availWidth - 3) {
                    $cutIdx = $ci + 1
                    break
                }
            }
            $suffix = if ($hasAnsi) { "...$([char]27)[0m" } else { "..." }
            $text = $text.Substring(0, $cutIdx) + $suffix
        }
    }

    Write-ColorizedBrackets -ForeGroundColor $color $text
    write-host
}


function Get-GenConfigErrorMessagesLineCount {
    $count = ($global:GenConfigErrorMessages | Measure-Object).Count

    if ($count -gt 0) {
        $count += 4 #Add 1 line for header, Add 3 for extra lines
    }
    return $count
}

function Show-GenConfigErrorMessages {
    param(
        [switch] $LineCount
    )

    # Select-Object -Unique compares these PSCustomObjects by ToString(), which
    # is empty for all of them, so it collapsed the whole list to one message.
    # Dedupe on the text instead; first occurrence wins.
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($global:GenConfigErrorMessages)) {
        if (-not $e) { continue }
        $key = "$($e.Message)"
        if (-not $key) { $key = "$e" }
        if ($seen.Add($key)) { $unique.Add($e) }
    }
    $Errors = $unique.ToArray()
    $count = $Errors.Count
    if ($LineCount) {
        if ($count -eq 0) { return 0 }
        return $count + 4
    }
    if ($count -gt 0) {
        #Write-host2 "┃" -NoNewline -ForegroundColor Crimson
        Write-Verbose "Showing Show-GenConfigErrorMessages"
        # A notice (auto-add/auto-remove) must not be dressed up as a validation failure.
        $failures = @($Errors | Where-Object { $_.Level -ne "WARNING" })
        $color = "Crimson"
        $header = "ERROR: Validation Failures were encountered:"
        if ($failures.Count -eq 0) {
            $color = "Orange"
            $header = "NOTICE: The configuration was changed for you:"
        }
        Write-Host2 "┍━━━━━━━━━━━━━━━━━━━  $header" -ForegroundColor $color
        Write-host2 "│" -ForegroundColor $color
        foreach ($err in $Errors) {
            Write-host2 "│" -NoNewline -ForegroundColor $color
            if ($err.Level -eq "WARNING") {
                Write-OrangePoint $err.message -ForegroundColor White
            }
            else {
                write-redx $err.message -ForegroundColor White
            }
        }
        Write-host2 "│" -ForegroundColor $color
        Write-Host
        $global:GenConfigErrorMessages = $null
    }

}

function Read-Host2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "shows current value in []")]
        [string] $currentValue = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Do not display the help before the prompt")]
        [switch] $HideHelp
    )
    if (-not $HideHelp.IsPresent) {
        if ($currentValue) {
            write-help -AllowEscape -WRCurrentValue:$currentValue
        }
        else {
            write-help
        }
    }
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPrompt $prompt -NoNewline
    if (-not [String]::IsNullOrWhiteSpace($currentValue)) {
        Write-Host " [" -NoNewline
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPromptCurrentItem $currentValue -NoNewline
        Write-Host "]" -NoNewline
    }
    Write-Host " : " -NoNewline
    $response = Read-Host
    Write-Host "------------------------------------------"
    return $response
}

function Read-Single {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "shows current value in []")]
        [string] $currentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Do not display the help before the prompt")]
        [switch] $HideHelp,
        [Parameter(Mandatory = $false, HelpMessage = "timeout")]
        [int] $timeout = 0,
        [Parameter(Mandatory = $false, HelpMessage = "Use Read-Host after keypress")]
        [switch] $useReadHost,
        [Parameter(Mandatory = $false, HelpMessage = "hint for help to show we will return")]
        [bool] $return = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Hint for help to show we will continue")]
        [bool] $ContinueMode = $false
    )

    if (-not $HideHelp.IsPresent) {
        if ($currentValue) {
            write-help -AllowEscape -return:$return -timeout:$useReadHost -WRCurrentValue:$currentValue
        }
        else {
            if ($ContinueMode) {
                write-help -return:$return -timeout:$useReadHost -AllowEscape
            }
            else {
                write-help -return:$return -timeout:$useReadHost
            }
            
        }
    }
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPrompt $prompt -NoNewline
    if (-not [String]::IsNullOrWhiteSpace($currentValue)) {
        Write-Host " [" -NoNewline
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPromptCurrentItem $currentValue -NoNewline
        Write-Host "] " -NoNewline
    }

    $response = Read-SingleKeyWithTimeout -timeout $timeout -Prompt ": " -useReadHost:$useReadHost
    if ($response) {
        Write-Host
    }
    Write-Host "------------------------------------------"
    return $response
}

function Select-RDCSettingsMenu {
    [CmdletBinding()]
    param()

    # Each toggle is a multi-select checkbox: [OrderedSettingKey] -> label.
    # Checkbox items get numeric itemNames (1..N) so Show-Menu renders the
    # [√]/[ ] check mark and space/enter toggles them. [A]=all, [N]=none,
    # [D]=Done (commit + exit), [R]=regenerate now. State lives in the passed
    # menuItems ArrayList, so the live check marks (not just saved settings)
    # drive both Done and Regenerate.
    $groupingItems = [ordered]@{
        DefaultGrouping = "Default grouping: Domain / MECM sites / Servers / Clients"
        AllVMsGroup     = "'All VMs' group"
        RoleGroups      = "Role groups: Clients/SiteServers/DPs/MPs/Sql/Wsus/Reporting"
        OSGroups        = "OS groups (one folder per OS)"
        SubnetGroups    = "Subnet groups (one folder per network)"
        SiteCodeGroups  = "Site code groups (one folder per ConfigMgr site)"
    }
    $displayItems = [ordered]@{
        ShowRole       = "Show role tag (DC/PRI/CAS/...)"
        ShowOS         = "Show OS tag (S22/W11/...)"
        ShowCMVersion  = "Show ConfigMgr version (CM22)"
        ShowSiteRoles  = "Show site system roles (MP/DP/SUP/RP/CA/Proxy)"
        ShowSiteCode   = "Show site code (PS1->CAS)"
        ShowUser       = "Show user, only if non-default (domain\user)"
        ShowSqlVersion = "Show SQL version (SQL2019)"
    }

    while ($true) {
        $settings = Get-RDCSettings

        $headerColor = $Global:Common.Colors.GenConfigHeader
        $optColor = $Global:Common.Colors.GenConfigNonDefault
        $optNum = $Global:Common.Colors.GenConfigNonDefaultNumber

        # Build the menu items by hand so section headers can sit between the
        # checkbox groups (Get-MenuItems only allows headers before/after a
        # single OptionArray block).
        $menuItems = [System.Collections.ArrayList]@()
        $textToKey = @{}
        $num = 0

        $null = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "*BREAKG" -text "Grouping (folders created in RDCMan / mRemoteNG)%$headerColor"
        foreach ($key in $groupingItems.Keys) {
            $num++
            $label = $groupingItems[$key]
            $textToKey[$label] = $key
            $mi = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "$num" -text $label -color1 $optColor -color2 $optNum -selectable
            $mi.MultiSelected = [bool]$settings.$key
        }

        $null = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "*BGAP1"
        $null = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "*BREAKD" -text "Display Name Elements (all on = today's layout)%$headerColor"
        foreach ($key in $displayItems.Keys) {
            $num++
            $label = $displayItems[$key]
            $textToKey[$label] = $key
            $mi = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "$num" -text $label -color1 $optColor -color2 $optNum -selectable
            $mi.MultiSelected = [bool]$settings.$key
        }

        $null = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "*BGAP2"
        $null = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "*BREAKR" -text "Actions%$headerColor"
        $null = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "A" -text "All Entries" -color1 $Global:Common.Colors.GenConfigTrue -color2 $Global:Common.Colors.GenConfigTrue -selectable -helptext "Check every setting"
        $null = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "N" -text "No Entries" -color1 $Global:Common.Colors.GenConfigFalse -color2 $Global:Common.Colors.GenConfigFalse -selectable -helptext "Uncheck every setting"
        $null = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "R" -text "Regenerate connection files now (RDCMan / mRemoteNG)" -color1 $optColor -color2 $optNum -selectable -helptext "Save the checked settings and rebuild memlabs.rdg + memlabs-mremoteng.xml"
        $doneItem = New-MenuItem -MenuItems ([ref]$menuItems) -itemName "D" -text "Done - save settings" -color1 $Global:Common.Colors.GenConfigDefault -color2 $Global:Common.Colors.GenConfigDefaultNumber -selectable -helptext "Save the checked settings and return"
        $doneItem.Selected = $true

        $response = Get-Menu2 -MenuName "RDC / Remote Connection Settings" -Prompt "Space/Enter toggles a setting, [D] saves, [R] regenerates" -menuItems $menuItems -MultiSelect -Test:$false -SplitEscapeFromGoBack

        $resp = "$response".ToUpperInvariant()

        # ESC / go-back = cancel without saving.
        if ($resp -in "ESCAPE", "GOBACK") { return }

        # Read the live check-mark state back into the settings object. Works
        # for Done (array / single label / NOITEMS) and for Regenerate alike.
        foreach ($mi in $menuItems) {
            if ($mi.Text -and $textToKey.ContainsKey($mi.Text)) {
                $settings.($textToKey[$mi.Text]) = [bool]$mi.MultiSelected
            }
        }
        Save-RDCSettings -Settings $settings

        if ($resp -eq "R") {
            New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$true
            New-MRemoteNGFileFromHyperV -MRemoteNGFile $Global:Common.MRemoteNGFilePath -OverWrite:$true
            Restore-TerminalFocus
            continue
        }

        # Any other response (Done via array / single label / NOITEMS / empty)
        # means the user committed -- settings are saved above, so exit.
        return
    }
}

function select-ChangeDynamicMemory {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain,
        [switch] $enable,
        [switch] $disable
    )

    while ($true) {
        Write-Host

        $vms = get-list -type vm -DomainName $domain -SmartUpdate
        $CustomOptions = [ordered]@{}

        $vmsname = $vms | Select-Object -ExpandProperty vmName

        $enabled = $vms | Where-Object { ($_.Memory / 1 ) -gt ($_.DynamicMinRam / 1) } | Select-Object -ExpandProperty vmName
        $disabled = $vms | Where-Object { ($_.Memory / 1 ) -le ($_.DynamicMinRam / 1) } | Select-Object -ExpandProperty vmName

        $vmsname = $enabled
        $ReturnVal = $null
        $verb = "Disable"
        if ($enable) {
            $verb = "Enable"
            $vmsname = $disabled
        }
        if ($vmsname -and ($vmsname | Measure-Object).count -gt 0) {
            Write-OrangePoint "$(($vmsname | Measure-Object).count) VMs in '$domain' are in state: $verb"
        }
        else {
            $customOptions = [ordered]@{"*B" = "*** All VMs in '$domain' already have Dynamic Memory $($verb)d ***" }
        }
        $ReturnVal = Get-Menu2 -MenuName "$verb Dynamic Memory on VMs in $domain" -Prompt "Select VMs" -OptionArray $vmsname -AdditionalOptions $customOptions -Test:$false -MultiSelect -AllSelected
        Write-Log -Verbose "Returned $ReturnVal of type $($ReturnVal.GetType()) with $($ReturnVal.Count) items"

        if ([string]::IsNullOrWhiteSpace($ReturnVal) -or $ReturnVal -eq "X" -or $ReturnVal -eq "ESCAPE" -or $ReturnVal -eq "NOITEMS") {
            return
        }

        $vmRestartList = @()
        foreach ($vmName in $ReturnVal) {    
            $vmNotes = $vms | Where-Object { $_.VmName -eq $vmName }
            $vm = Get-Vm2 -Name $vmName
            if (-not $vm) {
                continue
            }
            if ($vm.State -eq "Running") {
                stop-vm2 -name $vm.VmName
                $vmRestartList += @($vmName)
            }
            $Memory = $vmNotes.Memory
            if ($enable) {
                $role = $vm.role
                if ($vm.sqlVersion) {
                    $role = "SqlServer"
                }
                # SQL workloads default to a 4GB floor; everything else 1GB
                if ($role -in ("SqlServer", "Primary", "SQLAO", "CAS")) {
                    $dynamicMinRam = "4GB"
                }
                else {
                    $dynamicMinRam = "1GB"
                }
                $dynamicRamInBytes = ($dynamicMinRam / 1)
                $Memory = $vmNotes.Memory
                if ($dynamicRamInBytes -gt ($Memory / 1)) {
                    $dynamicMinRam = $Memory
                    $dynamicRamInBytes = ($Memory / 1)
                }
                $priority = 25
                $buffer = 10
                if ($role -in ("DC", "SqlServer", "Primary", "SQLAO", "CAS")) {
                    $priority = 50
                    $buffer = 20
                }
                if ($dynamicRamInBytes -gt 40MB) {
                    Write-log  "$VmName` Setting Dynamic Ram to $dynamicMinRam / $Memory"
                    try {
                    $vm | Set-VMMemory -DynamicMemoryEnabled $true -MinimumBytes $dynamicRamInBytes -maximumbytes ($Memory / 1) -startupbytes ($Memory / 1) -Priority $priority -buffer $buffer -ErrorAction Stop   
                    }
                    catch {
                        Write-Log "Failed to set Dynamic Memory on $vmName $_"
                        continue
                    }
                    Update-VMNoteProperty -VmName $vmName -PropertyName "DynamicMinRam" -PropertyValue $dynamicMinRam            
                }
                else {
                    Write-log -logonly "$VmName` Not Setting Dynamic Ram to $dynamicMinRam / $Memory"
                }
            }
            else {
                Write-log  "$VmName` Disable Dynamic Ram $Memory"
                try {
                $vm | Set-VMMemory -DynamicMemoryEnabled $false -StartupBytes $memory -ErrorAction Stop
                }
                catch {
                    Write-Log "Failed to set Dynamic Memory on $vmName $_"
                    continue
                }
                Update-VMNoteProperty -VmName $vmName -PropertyName "DynamicMinRam" -PropertyValue $Memory
            }                
        }
        if ($vmRestartList -and ($vmRestartList | Measure-Object).count -gt 0) {
            $crit = Get-CriticalVMs -domain $domain -vmNames $vmRestartList            
            
            $failures = Invoke-SmartStartVMs -CritList $crit -CriticalOnly:$false 
        }
        
    }
}

function Select-StartDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "Prepopulate response")]
        [string] $response = $null,
        [switch] $Sync
    )

    # If a background VM operation is already running for this domain, warn and return
    if (-not $Sync -and $global:PendingVMOperations -and $global:PendingVMOperations[$domain] -and -not $global:PendingVMOperations[$domain].Completed) {
        Write-Host
        Write-OrangePoint "A background $($global:PendingVMOperations[$domain].Type) operation is already in progress for '$domain'."
        return
    }

    $preResponse = $null
    if ($response) {
        $preResponse = $response
    }
    $response = $null
    while ($true) {
        Write-Host

        $vms = get-list -type vm -DomainName $domain -SmartUpdate
        $CustomOptions = [ordered]@{}

        $notRunning = $vms | Where-Object { $_.State -ne "Running" -and $_.Role -ne "StandaloneRootCA" }
        if ($notRunning -and ($notRunning | Measure-Object).count -gt 0) {
            Write-OrangePoint "$(($notRunning | Measure-Object).count) VMs in '$domain' are not Running"
        }
        else {
            $customOptions = [ordered]@{"*B" = "*** All VMs in '$domain' are already Running ***" }
            return
        }


        $vmsname = $notRunning | Select-Object -ExpandProperty vmName

        if (-not $preResponse) {
            $response = $null
            $ReturnVal = $null
            $ReturnVal = Get-Menu2 -MenuName "Start VMs in $domain" -Prompt "Select VM to Start" -OptionArray $vmsname -AdditionalOptions $customOptions -Test:$false -MultiSelect -AllSelected
            Write-Log -Verbose "Returned $ReturnVal of type $($ReturnVal.GetType()) with $($ReturnVal.Count) items"
        }
        else {
            $ReturnVal = $preResponse
            $preResponse = $null
        }


        if ([string]::IsNullOrWhiteSpace($ReturnVal) -or $ReturnVal -eq "X" -or $ReturnVal -eq "ESCAPE" -or $ReturnVal -eq "NOITEMS") {
            return
        }
        if ($ReturnVal -eq "A" -or $ReturnVal -eq "C") {
            $CriticalOnly = $false
            if ($ReturnVal -eq "C") {
                $CriticalOnly = $true
            }
            $ReturnVal = $null
            $crit = Get-CriticalVMs -domain $domain

            if ($Sync) {
                $failures = Invoke-SmartStartVMs -CritList $crit -CriticalOnly:$CriticalOnly
                if ($failures -ne 0) {
                    Write-RedX "$failures VM(s) could not be started" -foregroundColor red
                }
            }
            else {
                Invoke-SmartStartVMsBackground -CritList $crit -CriticalOnly:$CriticalOnly -domain $domain
                $count = @($crit.ALLCRIT).Count
                if (-not $CriticalOnly) { $count += @($crit.NONCRIT).Count }
                Write-GreenCheck "Starting $count VM(s) in '$domain' in the background..."
            }

            return

        }
        else {
            write-Log -Verbose "$($ReturnVal.Count) VMs returned $ReturnVal"
            $crit = Get-CriticalVMs -domain $domain -vmNames $ReturnVal

            if ($Sync) {
                $failures = Invoke-SmartStartVMs -CritList $crit -CriticalOnly:$CriticalOnly
                if ($failures -ne 0) {
                    Write-RedX "$failures VM(s) could not be started" -foregroundColor red
                }
            }
            else {
                Invoke-SmartStartVMsBackground -CritList $crit -CriticalOnly:$CriticalOnly -domain $domain
                Write-GreenCheck "Starting $($ReturnVal.Count) VM(s) in '$domain' in the background..."
            }
            return
        }
    }
    get-list -type VM -SmartUpdate | out-null
}


function Select-StopDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "Prepopulate response")]
        [string] $response = $null,
        [switch] $AllSelected,
        [switch] $Sync
    )

    # If a background VM operation is already running for this domain, warn and return
    if (-not $Sync -and $global:PendingVMOperations -and $global:PendingVMOperations[$domain] -and -not $global:PendingVMOperations[$domain].Completed) {
        Write-Host
        Write-OrangePoint "A background $($global:PendingVMOperations[$domain].Type) operation is already in progress for '$domain'."
        return
    }

    $customOptions = @{}
    if ($response) {
        $preResponse = $response
    }

    While ($true) {
        $response = $null
        Write-Host
        $vms = get-list -type vm -DomainName $domain -SmartUpdate
        $running = $vms | Where-Object { $_.State -ne "Off" }
        if ($running -and ($running | Measure-Object).count -gt 0) {
            Write-host "$(($running| Measure-Object).count) VMs in '$domain' are currently running."
        }
        else {
            Write-host "All VMs in '$domain' are already turned off."
            $customOptions = [ordered]@{"*B" = "*** All VMs in '$domain' are already turned off. ***" }  
            return "NOITEMS"
        }

        $vmsname = $running | Select-Object -ExpandProperty vmName
        if (-not $preResponse) {
            $results = @()
            $results = Get-Menu2 -MenuName "Select VMs to Stop in $domain" -Prompt "Select VMs to Stop" -additionalOptions $CustomOptions -OptionArray $vmsname -test:$false -MultiSelect -AllSelected:$AllSelected
        }
        else {
            $results = $preResponse
            $preResponse = $null
        }
        write-log -Verbose "StopVMs returned '$results' $($results.Count) $($results.GetType())"
        if ($results -eq "ESCAPE") {
            return "ESCAPE"
        }
        if ($results -eq "NOITEMS" -or [string]::IsNullOrWhiteSpace($results)) {
            return "NOITEMS"
        }
        if ([string]::IsNullOrWhiteSpace($results) -or $results -eq "None" -or $results -eq "ESCAPE") {
            write-log -Verbose "StopVMs Escape"
            return
        }
        if ($results -eq "A" -or $results -eq "C" -or $results -eq "N") {

            $vmList = @()

            if ($results -eq "A") {
                $vmList = $running
            }
            else {
                $crit = Get-CriticalVMs -domain $domain

                if ($results -eq "N") {
                    $vmList = $crit.NONCRIT

                }
                if ($results -eq "C") {
                    $vmList = $crit.ALLCRIT
                }
            }

            if ($Sync) {
                Invoke-StopVMs -domain $domain -vmList $vmList
            }
            else {
                Invoke-StopVMsBackground -domain $domain -vmList $vmList
                Write-GreenCheck "Stopping $(@($vmList).Count) VM(s) in '$domain' in the background..."
            }

            return
        }
        else {
            If ($results -and $results.Count -ge 1) {
                if ($Sync) {
                    Invoke-StopVMs -domain $domain -vmList $results
                    get-list -type VM -SmartUpdate | out-null
                }
                else {
                    Invoke-StopVMsBackground -domain $domain -vmList $results
                    Write-GreenCheck "Stopping $($results.Count) VM(s) in '$domain' in the background..."
                }
                return
            }
        }

    }
}

function Select-DeleteDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Delete")]
        [string] $domain
    )

    while ($true) {
        $vms = get-list -type vm -DomainName $domain -SmartUpdate | Select-Object -ExpandProperty vmName
        if (-not $vms) {
            return
        }
        # $customOptions = [ordered]@{"D" = "Delete All VMs" }
        $customOptions = $null
        $response = Get-Menu2 -MenuName "Delete VMs in $domain" -Prompt "Select VM to Delete" -OptionArray $vms -AdditionalOptions $customOptions -Test:$false -return -MultiSelect

        if ([string]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE" -or $response -eq "NOITEMS") {
            return
        }
        if ($response -eq "D") {
            Write-Host "Selecting 'Yes' will permanently all VMs and scopes."
            $response2 = Read-YesOrNoWithTimeout -Prompt "Are you sure? (y/N)" -HideHelp -timeout 180 -Default "n"
            if (-not [String]::IsNullOrWhiteSpace($response)) {
                if ($response2.ToLowerInvariant() -eq "y" -or $response2.ToLowerInvariant() -eq "yes") {
                    Remove-Domain -DomainName $domain
                    return
                }
            }
        }
        else {
            $response2 = Read-YesOrNoWithTimeout -Prompt "Delete VM(s) $($response -Join ",")? (y/N)" -HideHelp -timeout 180 -Default "n"

            if ($response2 -and ($response2.ToLowerInvariant() -eq "n" -or $response2.ToLowerInvariant() -eq "no")) {
                continue
            }
            else {
                Remove-Domain -DomainName $domain -vmList $response
                #Remove-VirtualMachine -VmName $response
                #Get-List -type VM -SmartUpdate | Out-Null
                #New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
                continue
            }
        }
    }
}