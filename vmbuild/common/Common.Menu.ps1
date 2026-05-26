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
    $prefixLen = 3 + 1 + $option.Length + [Math]::Max(0, 4 - $option.Length)
    $termWidth = [Console]::WindowWidth
    if (-not $termWidth) { $termWidth = $host.UI.RawUI.WindowSize.Width }
    $availWidth = $termWidth - $prefixLen - 1
    if ($availWidth -gt 0 -and $text) {
        $hasAnsi = $text.Contains([char]27)
        if ($hasAnsi) {
            $ansiPat = [char]27 + '\[[0-9;]*m'
            $plainLen = [regex]::Replace($text, $ansiPat, '').Length
        }
        else {
            $plainLen = $text.Length
        }
        if ($plainLen -gt $availWidth) {
            # Walk the string counting visible chars (skipping ANSI), cut at limit
            $visCount = 0
            $cutIdx = $text.Length
            $inEsc = $false
            for ($ci = 0; $ci -lt $text.Length; $ci++) {
                if ($text[$ci] -eq [char]27) { $inEsc = $true }
                if ($inEsc) {
                    if ($text[$ci] -eq 'm') { $inEsc = $false }
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

    $Errors = $global:GenConfigErrorMessages | Select-Object -Unique
    $count = ($Errors | Measure-Object).Count
    if ($LineCount) {
        if ($count -eq 0) { return 0 }
        return $count + 4
    }
    if ($count -gt 0) {
        #Write-host2 "┃" -NoNewline -ForegroundColor Crimson
        Write-Verbose "Showing Show-GenConfigErrorMessages"
        Write-Host2 "┍━━━━━━━━━━━━━━━━━━━  ERROR: Validation Failures were encountered:" -ForegroundColor Crimson
        Write-host2 "│" -ForegroundColor Crimson
        foreach ($err in $Errors) {
            Write-host2 "│" -NoNewline -ForegroundColor Crimson
            write-redx $err.message -ForegroundColor White
        }
        Write-host2 "│" -ForegroundColor Crimson
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
        [string] $response = $null
    )

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
            #Write-GreenCheck "All VMs in '$domain' are already Running"
            #return
        }


        $vmsname = $notRunning | Select-Object -ExpandProperty vmName
        #$customOptions = [ordered]@{"A" = "Start All VMs" ; "C" = "Start Critical VMs only (DC/SiteServers/Sql)" ; "X" = "Do not start any VMs" }

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

            $failures = Invoke-SmartStartVMs -CritList $crit -CriticalOnly:$CriticalOnly

            if ($failures -ne 0) {
                Write-RedX "$failures VM(s) could not be started" -foregroundColor red
            }

            return

        }
        else {
            write-Log -Verbose "$($ReturnVal.Count) VMs returned $ReturnVal"
            $crit = Get-CriticalVMs -domain $domain -vmNames $ReturnVal            
            
            $failures = Invoke-SmartStartVMs -CritList $crit -CriticalOnly:$CriticalOnly

            if ($failures -ne 0) {
                Write-RedX "$failures VM(s) could not be started" -foregroundColor red
            }
            #start-vm2 $response
            #get-job | wait-job | out-null
            #Show-JobsProgress -Activity "Starting VMs"
            #get-job | remove-job | out-null
            #get-list -type VM -SmartUpdate | out-null
            $ReturnVal = $null
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
        [switch] $AllSelected
    )

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
        #$customOptions = [ordered]@{"A" = "Stop All VMs" ; "N" = "Stop non-critical VMs (All except: DC/SiteServers/SQL)"; "C" = "Stop Critical VMs (DC/SiteServers/SQL)" }
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

            Invoke-StopVMs -domain $domain -vmList $vmList

            return
        }
        else {
            If ($results -and $results.Count -ge 1) {
                Invoke-StopVMs -domain $domain -vmList $results
                get-list -type VM -SmartUpdate | out-null
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