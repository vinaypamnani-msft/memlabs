############################
### Menu Functions ###
############################
#Common.menu.ps1

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
        [Parameter(Mandatory = $false, HelpMessage = "Pre Menu options, in dictionary format.. X = Exit")]
        [object] $preOptions = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Run a configuration test. Default True")]
        [bool] $Test = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Supress newline")]
        [switch] $NoNewLine,
        [Parameter(Mandatory = $false, HelpMessage = "Split response")]
        [switch] $split,
        [Parameter(Mandatory = $false, HelpMessage = "timeout")]
        [int] $timeout = 0,
        [Parameter(Mandatory = $false, HelpMessage = "Hide Help")]
        [bool] $HideHelp = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Hint for help to show we will return from this menu on enter")]
        [switch] $return
    )



    if (!$NoNewLine) {
        write-Host
        Write-Verbose "4 Get-Menu"
    }

    if ($null -ne $preOptions) {
        foreach ($item in $preOptions.keys) {
            $value = $preOptions."$($item)"
            $color1 = $Global:Common.Colors.GenConfigDefault
            $color2 = $Global:Common.Colors.GenConfigDefaultNumber

            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $value -split "%"

                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $color1 = $TextValue[1]
                    if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                        $color2 = $TextValue[2]
                    }
                    else {
                        $color2 = $color1
                    }
                }

                if ($TextValue[0].StartsWith("$")) {
                    continue
                }

                if ($item.StartsWith("*B")) {
                    $breakPrefix = " t───── "
                    Write-Host2 -ForegroundColor "MediumPurple" $breakPrefix -NoNewline
                    write-host2 -ForeGroundColor $color1 $TextValue[0] -NoNewline
                    Write-Host2 -ForegroundColor "MediumPurple" $breakPrefix
                }
                else {
                    if ($item.StartsWith("*")) {
                        write-host2 -ForeGroundColor $color1 $TextValue[0]
                        continue
                    }
                }
                Write-Option $item $TextValue[0] -color $color1 -Color2 $color2
            }
        }
    }


    $i = 0

    foreach ($option in $OptionArray) {
        if (-not [String]::IsNullOrWhiteSpace($option)) {
            $i = $i + 1
            $item = $option
            $color1 = $Global:Common.Colors.GenConfigNormal
            $color2 = $Global:Common.Colors.GenConfigNormalNumber
            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $item -split "%"

                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $color1 = $TextValue[1]
                    if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                        $color2 = $TextValue[2]
                    }
                    else {
                        $color2 = $color1
                    }
                }
                Write-Option $i $TextValue[0] -color $color1 -Color2 $color2
            }
        }
    }

    if ($null -ne $additionalOptions) {
        foreach ($item in $additionalOptions.keys) {
            $value = $additionalOptions."$($item)"

            $color1 = $Global:Common.Colors.GenConfigDefault
            $color2 = $Global:Common.Colors.GenConfigDefaultNumber

            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $value -split "%"

                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $color1 = $TextValue[1]
                    if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                        $color2 = $TextValue[2]
                    }
                    else {
                        $color2 = $color1
                    }
                }

                if ($TextValue[0].StartsWith("$")) {
                    continue
                }
                if ($item.StartsWith("*")) {
                    write-host2 -ForeGroundColor $color1 $TextValue[0]
                    continue
                }
                Write-Option $item $TextValue[0] -color $color1 -Color2 $color2
            }
        }
    }
    $totalOptions = $preOptions + $additionalOptions


    #Show-GenConfigErrorMessages
    #Write-Verbose "Calling Get-ValidResponse with -return:true"
    $response = get-ValidResponse -Prompt $Prompt -max $i -CurrentValue $CurrentValue -AdditionalOptions $totalOptions -TestBeforeReturn:$Test -timeout:$timeout -HideHelp:$HideHelp -return:$return

    if (-not [String]::IsNullOrWhiteSpace($response)) {
        $i = 0
        foreach ($option in $OptionArray) {
            $i = $i + 1
            if ($i -eq $response) {
                if ($split) {
                    $option = $option -Split " " | Select-Object -First 1
                }
                Write-Verbose "[Get-Menu] Returned (O) '$option'"
                return $option
            }
        }
        if ($split) {
            $response = $response -Split " " | Select-Object -First 1
        }
        Write-Log -LogOnly "[$prompt] Returned (R) '$response'"

        return $response
    }
    else {
        Write-Log -LogOnly  "[$prompt] Returned (CV) '$CurrentValue'"
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
        [switch] $TestBeforeReturn,
        [Parameter(Mandatory = $false, HelpMessage = "timeout")]
        [int] $timeout = 0,
        [Parameter(Mandatory = $false, HelpMessage = "Hide Help")]
        [bool] $HideHelp = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Hint for help to show we will return")]
        [bool] $return = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Hint for help to show we will continue")]
        [bool] $ContinueMode = $false

    )

    $responseValid = $false
    while ($responseValid -eq $false) {
        Write-Host
        Write-Verbose "5 get-ValidResponse max = $max $($additionalOptions.Keys -join ",")"
        $response = $null
        $response2 = $null
        $first = $true
        while (-not $response) {
            $response = $null
            $response2 = $null

            Write-Verbose "5 else get-ValidResponse max = $max"
            if ($first) {
                Write-Verbose "6 else get-ValidResponse max = $max"
                $response = Read-Single -Prompt $prompt $currentValue -timeout:$timeout -HideHelp:$HideHelp -return:$return -ContinueMode:$ContinueMode
            }
            else {
                Write-Verbose "7 else get-ValidResponse max = $max"
                $response = Read-SingleKeyWithTimeout -timeout 0
            }
            $first = $false
            if ([string]::isnullorwhitespace($response)) {
                Write-Verbose "return null"
                return $null
            }
            else {
                Write-Verbose "got $response"
            }
            #$response = Read-Host2 -Prompt $prompt $currentValue
            if (-not $Global:EnterKey) {
                if (($response -as [int]) -is [int]) {

                    [int]$testmax = ([string]$response + "0" -as [int])
                    Write-Verbose "Testing $testmax -le $max"
                    if ([int]$testmax -le [int]$max) {
                        # Write-Verbose "Reading Another Key"
                        $response2 = Read-SingleKeyWithTimeout -timeout 2 -backspace -noflush
                        #Write-Verbose "Next Key was '$response2'"
                    }
                }
                foreach ($key in $additionalOptions.Keys) {
                    if ($key.length -gt 1 -and ($key.StartsWith($response))) {
                        $response2 = Read-SingleKeyWithTimeout -timeout 2 -backspace -noflush
                        break
                    }
                }
                if ($response2 -eq "BACKSPACE") {
                    $response = $null
                    $response2 = $null
                }
                if ($response2) {
                    $response = $response + $response2
                    if ([String]::IsNullOrWhiteSpace($response2)) {
                        write-host
                    }
                }
            }
        }

        Write-Host
        #Write-Host "`r --------------- Processing Response $response -------------"

        try {
            if ([String]::IsNullOrWhiteSpace($response)) {
                $responseValid = $true
            }
            else {
                try {
                    if (($response -as [int]) -is [int]) {
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
                    if ($response) {
                        if ($response.ToLowerInvariant() -eq $i.ToLowerInvariant()) {
                            $responseValid = $true
                        }
                    }
                }
            }
            if ($responseValid -eq $false -and $currentValue -is [bool]) {
                if ($currentValue) {
                    if ($currentValue.ToLowerInvariant() -eq "true" -or $currentValue.ToLowerInvariant() -eq "false") {
                        $responseValid = $false
                        if ($response) {
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
            }
        }
        catch {}
        if (-not $responseValid) {
            $validResponses = @()
            if ($max -gt 0) {
                $validResponses += 1..$max
            }
            if ($additionalOptions) {
                $validResponses += $additionalOptions.Keys | Where-Object { -not $_.StartsWith("*") }
            }
            write-host2 -ForegroundColor $Global:Common.Colors.GenConfigInvalidResponse "Invalid response '$response'.  " -NoNewline
            write-host "Valid Responses are: " -NoNewline
            write-host2 -ForegroundColor $Global:Common.Colors.GenConfigValidResponses "$($validResponses -join ",")"
        }
        if ($TestBeforeReturn.IsPresent -and $responseValid) {
            $responseValid = Get-TestResult -SuccessOnError
        }
    }
    #Write-Host "Returning: $response"
    return $response
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
        [object] $color2,
        [switch] $MultiSelect = $false,
        [switch] $MultiSelected = $false
    )

    if ($null -eq $color) {
        $color = $Global:Common.Colors.GenConfigNormal
        $color2 = $Global:Common.Colors.GenConfigNormalNumber
    }
    if ($null -eq $color2) {
        $color2 = $color
    }
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

    Write-ColorizedBrackets -ForeGroundColor $color $text
    write-host
}


function Get-GenConfigErrorMessagesLineCount {
    $count = ($global:GenConfigErrorMessages | Measure-Object).Count

    if ($count -gt 0) {
        $count+=4 #Add 1 line for header, Add 3 for extra lines
    }
    return $count
}

function Show-GenConfigErrorMessages {

    $count = ($global:GenConfigErrorMessages | Measure-Object).Count
    if ($count -gt 0) {
        #Write-host2 "┃" -NoNewline -ForegroundColor Crimson
        Write-Verbose "Showing Show-GenConfigErrorMessages"
        Write-Host2 "┍━━━━━━━━━━━━━━━━━━━  ERROR: Validation Failures were encountered:" -ForegroundColor Crimson
        Write-host2 "│" -ForegroundColor Crimson
        foreach ($err in $global:GenConfigErrorMessages) {
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
        [Parameter(Mandatory = $false, HelpMessage = "Dont display the help before the prompt")]
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
        [Parameter(Mandatory = $false, HelpMessage = "Dont display the help before the prompt")]
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

        $notRunning = $vms | Where-Object { $_.State -ne "Running" }
        if ($notRunning -and ($notRunning | Measure-Object).count -gt 0) {
            Write-OrangePoint "$(($notRunning | Measure-Object).count) VM's in '$domain' are not Running"
        }
        else {
            $customOptions = [ordered]@{"*B" = "*** All VM's in '$domain' are already Running ***" }
            #Write-GreenCheck "All VM's in '$domain' are already Running"
            #return
        }


        $vmsname = $notRunning | Select-Object -ExpandProperty vmName
        #$customOptions = [ordered]@{"A" = "Start All VMs" ; "C" = "Start Critial VMs only (DC/SiteServers/Sql)" ; "X" = "Do not start any VMs" }

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


        if ([string]::IsNullOrWhiteSpace($ReturnVal) -or $ReturnVal -eq "X" -or $ReturnVal -eq "ESCAPE") {
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
            Write-host "$(($running| Measure-Object).count) VM's in '$domain' are currently running."
        }
        else {
            Write-host "All VM's in '$domain' are already turned off."
            $customOptions = [ordered]@{"*B" = "*** All VM's in '$domain' are already turned off. ***" }
            
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
            }
        }

    }
}

function Select-DeleteDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
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

        if ([string]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE") {
            return
        }
        if ($response -eq "D") {
            Write-Host "Selecting 'Yes' will permantently delete all VMs and scopes."
            $response2 = Read-YesorNoWithTimeout -Prompt "Are you sure? (y/N)" -HideHelp -timeout 180 -Default "n"
            if (-not [String]::IsNullOrWhiteSpace($response)) {
                if ($response2.ToLowerInvariant() -eq "y" -or $response2.ToLowerInvariant() -eq "yes") {
                    Remove-Domain -DomainName $domain
                    return
                }
            }
        }
        else {
            $response2 = Read-YesorNoWithTimeout -Prompt "Delete VM(s) $($response -Join ",")? (y/N)" -HideHelp -timeout 180 -Default "n"

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