# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
Function Get-ValidSubnets {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $configToCheck = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "Allow Existing")]
        [bool] $AllowExisting = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Networks to Exclude")]
        [object] $excludeList = @(),
        [Parameter(Mandatory = $false, HelpMessage = "VM to Check")]
        [object] $vmToCheck = $null

    )


    $usedSubnets = @()
    $usedSubnets += (Get-NetworkList).Network

    #exclude any networks that already exist on the host
    $usedSubnets += ((Get-NetIPAddress -AddressFamily IPV4).IPAddress | ForEach-Object { $_ -replace "\d{1,3}$", "0" } )
    $usedSubnets += $excludeList
    if (-not $AllowExisting) {
        $usedSubnets += $configToCheck.vmOptions.network
        foreach ($vm in $configToCheck.VirtualMachines) {
            if ($vm.network) {
                $usedSubnets += $vm.network
            }
        }
    }

    $subnetlist = @()
    if ($vmToCheck) {
        $subnetlist = Get-ValidNetworksForVM -ConfigToCheck $configToCheck -Currentvm $vmToCheck
    }

    # An OSDClient can only PXE-boot from a DP on its own subnet, so
    # Get-ValidNetworksForVM already limited the list to subnets that have a DP.
    # Do NOT append brand-new empty subnets for it (a fresh subnet has no DP and
    # can never do OSD/PXE); return the DP-restricted list as-is.
    if ($vmToCheck -and $vmToCheck.Role -eq 'OSDClient') {
        return @($subnetlist | Where-Object { $_ } | Sort-Object -Property { [System.Version]$_ } | Get-Unique)
    }

    $usedSubnets += $subnetList
    $subnetList = @($subnetList | Sort-Object -Property { [System.Version]$_ } | Get-Unique)
    $addedsubnets = 0

    for ($i = 1; $i -lt 200; $i++) {
        $newSubnet = "192.168." + $i + ".0"
        $found = $false
        if ($usedSubnets -contains $newSubnet) {
            $found = $true
            continue
        }
        if (-not $found) {
            $subnetlist += $newSubnet
            $addedsubnets++
            if ($addedsubnets -gt 2) {
                break
            }

        }

    }

    for ($i = 1; $i -lt 200; $i++) {
        $newSubnet = "172.16." + $i + ".0"
        $found = $false
        if ($usedSubnets -contains $newSubnet) {
            $found = $true
            continue
        }
        if (-not $found) {
            $subnetlist += $newSubnet
            $addedsubnets++
            if ($addedsubnets -gt 5) {
                break
            }

        }
    }

    for ($i = 1; $i -lt 200; $i++) {
        $newSubnet = "10.0." + $i + ".0"
        $found = $false
        if ($usedSubnets -contains $newSubnet) {
            $found = $true
            continue
        }
        if (-not $found) {
            $subnetlist += $newSubnet
            $addedsubnets++
            if ($addedsubnets -gt 8) {
                break
            }
        }
    }
    return $subnetlist | Where-Object { $_ }
}
function Get-ValidDomainNames {
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
        "vanarsdelltd.com" = "VAN-" ; "wingtiptoys.com" = "WTT-" ; "woodgrovebank.com" = "WGB-"
        # techpreview.com / "CTP-" intentionally omitted -- ConfigMgr Tech Preview
        # builds are no longer supported, and leaving it in this dict caused the
        # New Domain wizard to default to techpreview.com once shorter domains
        # got consumed by other deployments.
    }
    foreach ($domain in (Get-DomainList)) {
        if ($domain) {
            $ValidDomainNames.Remove($domain.ToLowerInvariant())
        }
    }

    $usedPrefixes = Get-List -Type UniquePrefix
    $ValidDomainNamesClone = $ValidDomainNames.Clone()
    foreach ($dname in $ValidDomainNamesClone.Keys) {
        foreach ($usedPrefix in $usedPrefixes) {
            if ($usedPrefix -and $ValidDomainNames[$dname]) {
                if ($ValidDomainNames[$dname].ToLowerInvariant() -eq $usedPrefix.ToLowerInvariant()) {
                    Write-Verbose ("Removing $dname")
                    $ValidDomainNames.Remove($dname)
                }
            }
        }
    }
    return $ValidDomainNames
}


Function Show-JobsProgress {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Activity Name")]
        [string] $Activity
    )
    #get-job | out-host
    $jobs = get-job | Where-Object { $_.state -ne "completed" -and $_.state -ne "stopped" -and $_.state -ne "failed" }
    [int]$total = $jobs.count -as [int]
    [int]$runningjobs = $jobs.count -as [int]
    #Write-Host "Total $total Running $runningjobs"
    while ($runningjobs -gt 0) {
        $percent = [math]::Round((($total - $runningjobs) / $total * 100), 2)
        Write-Progress2 -activity $Activity -status "Progress: $percent%" -percentcomplete $percent

        [int]$runningjobs = (get-job | Where-Object { $_.state -ne "completed" -and $_.state -ne "stopped" -and $_.state -ne "failed" }).Count -as [int]
    }
    Write-Progress2 -activity $Activity -Completed
}


Function Read-SingleKeyWithTimeout {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "timeout")]
        [int] $timeout = 10,
        [Parameter(Mandatory = $false, HelpMessage = "Valid Keys")]
        [string[]] $ValidKeys,
        [Parameter(Mandatory = $false, HelpMessage = "Prompt")]
        [string] $Prompt,
        [Parameter(Mandatory = $false, HelpMessage = "Returns the string BACKSPACE on backspace")]
        [switch] $backspace,
        [Parameter(Mandatory = $false, HelpMessage = "Does not flush input buffer")]
        [switch] $NoFlush,
        [Parameter(Mandatory = $false, HelpMessage = "Use ReadHost after keypress")]
        [bool] $UseReadHost = $false
    )


    if ($Global:EnterKey) {
        $UseReadHost = $true
    }
    Function Write-Prompt {
        param (
            [Parameter(Mandatory = $true, HelpMessage = "color")]
            [string] $color

        )
        [int]$charsToDelete = $Prompt.Length + $charsToDeleteNextTime

        #Write-Host -NoNewline ("`b" * $charsToDelete)
        $deleteChars = ("`b" * $charsToDelete)
        if ($timeout -ne 0) {
            if ($timeoutLeft -le 3) {
                Write-Host ($deleteChars + "[") -NoNewline
                write-Host2 -Foregroundcolor DarkRed $timeoutLeft -NoNewline
                Write-Host "]" -NoNewline
            }
            else {
                write-Host ($deleteChars + "[" + $timeoutLeft + "]") -NoNewline
            }
            $deleteChars = ""
            $charsToDeleteNextTime = "[$timeoutLeft]".Length
        }
        Write-Host2 -NoNewline -ForegroundColor $color ($deleteChars + $Prompt)
        return $charsToDeleteNextTime
    }

    $stopTimeout = $false
    if ($timeout -eq 0) {
        $stopTimeout = $true
    }
    $key = $null
    $secs = 0
    $charsToDeleteNextTime = 0
    if ($Prompt) {
        if ($timeout) {
            Write-Host "[$timeout]" -NoNewline
            $charsToDeleteNextTime = "[$timeout]".Length
        }
        Write-Host $Prompt -NoNewline
    }
    $i = 0
    if (-not $NoFlush) {
        start-sleep -Milliseconds 200
        $host.ui.RawUI.FlushInputBuffer()
    }
    While ($secs -le ($timeout * 40)) {
        $timeoutLeft = [Math]::Round(($timeout) - $secs / 40, 0)
        if ([Console]::KeyAvailable) {
            if ($UseReadHost) {
                $read = Read-Host
                #write-host "read = $read"
                if ($read -eq [string]::empty) {
                    return $null
                }
                return $read
            }
            $key = $host.UI.RawUI.ReadKey()
            $host.ui.RawUI.FlushInputBuffer()
            if ($key.VirtualKeyCode -eq 13) {
                write-host
                return $null
            }
            if ($key.VirtualKeyCode -eq 8) {
                if ($backspace) {
                    Write-Host -NoNewline (" `b `b")
                    return "BACKSPACE"
                }
                else {
                    Write-Host " " -NoNewline
                    continue
                }
            }

            if ($key.Character) {
                if ($ValidKeys) {
                    if ($key.Character.ToString() -in $ValidKeys) {
                        return $key.Character.ToString()
                    }
                    else {
                        $stopTimeout = $true
                        Write-Host -NoNewline ("`b `b")
                    }
                }
                else {
                    #$key | out-host
                    return $key.Character.ToString()
                }
            }
            else {
                $key = $null
            }
        }
        if ($Prompt -and -not $stopTimeout) {
            switch (($i++ % 128) / 32) {
                0 { $charsToDeleteNextTime = Write-Prompt -Color MediumSpringGreen }
                1 { $charsToDeleteNextTime = Write-Prompt -Color Red }
                2 { $charsToDeleteNextTime = Write-Prompt -Color Yellow }
                3 { $charsToDeleteNextTime = Write-Prompt -Color Blue }
            }
        }
        #Write-Host -NoNewline ("`b `b{0}" -f '/?\|'[($i++ % 4)])
        start-sleep -Milliseconds 25
        if ($timeout -ne 0) {
            #infinite wait
            if (-not $stopTimeout) {
                $secs++
            }
        }
    }

    if (-not $key) {
        write-host
        return $null
    }

}

function write-help {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Default Value")]
        [String] $WRCurrentValue = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Can Enter escape this menu")]
        [switch] $AllowEscape,
        [Parameter(Mandatory = $false, HelpMessage = "hint for help to show we will return")]
        [bool] $return = $false,
        [Parameter(Mandatory = $false, HelpMessage = "hint for help to show we will return")]
        [bool] $timeout = $false

    )
    $color = $Global:Common.Colors.GenConfigHelp
    if ($timeout) {
        Write-Host2 -ForegroundColor $color "Press " -NoNewline
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Space]" -NoNewline
        Write-Host2 -ForegroundColor $color " to stop the countdown or " -NoNewline
    }

    if ($WRCurrentValue) {
        Write-Host2 -ForegroundColor $color "Press " -NoNewline
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Enter]" -NoNewline
        Write-Host2 -ForegroundColor $color " to use the DEFAULT value of '" -NoNewline
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "$WRCurrentValue" -NoNewLine
        Write-Host2 -ForegroundColor $color "' "
        #Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
        #Write-Host2 -ForegroundColor $color " to exit without saving."
    }
    else {
        if (-not $AllowEscape) {
            if ($return) {
                Write-Host2 -ForegroundColor $color "Press " -NoNewline
                Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Enter]" -NoNewline
                Write-Host2 -ForegroundColor $color " to return to the previous menu "
                #Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
                #Write-Host2 -ForegroundColor $color " to exit without saving."
            }
            else {
                Write-Host2 -ForegroundColor $color "Select an option or " -NoNewline
                Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
                Write-Host2 -ForegroundColor $color " to exit the script without saving."
            }
        }
        else {
            if ($return) {
                Write-Host2 -ForegroundColor $color "Press " -NoNewline
                Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Enter]" -NoNewline
                Write-Host2 -ForegroundColor $color " to return to the previous menu "
                #Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
                #Write-Host2 -ForegroundColor $color " to exit without saving."
            }
            else {
                Write-Host2 -ForegroundColor $color "Press " -NoNewline
                Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Enter]" -NoNewline
                Write-Host2 -ForegroundColor $color " to skip this section "
                #Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
                #Write-Host2 -ForegroundColor $color " to exit without saving."
            }
        }
    }
}

function Read-YesOrNoWithTimeout {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "shows current value in []")]
        [string] $currentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Dont display the help before the prompt")]
        [switch] $HideHelp,
        [Parameter(Mandatory = $false, HelpMessage = "Default Value")]
        [string] $Default,
        [Parameter(Mandatory = $false, HelpMessage = "Timeout")]
        [int] $timeout = 10

    )
    if ($timeout -gt 0) {
        $TimeoutHelp = $true
    }
    if (-not $HideHelp.IsPresent) {
        if ($Default) {
            write-help -AllowEscape -timeout:$timeoutHelp -WRCurrentValue:$currentValue
        }
        else {
            write-help -timeout:$timeoutHelp -WRCurrentValue:$currentValue
        }
    }
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPrompt $prompt -NoNewline
    if (-not [String]::IsNullOrWhiteSpace($currentValue)) {
        Write-Host " [" -NoNewline
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPromptCurrentItem $currentValue -NoNewline
        Write-Host "] " -NoNewline
    }


    $valid = $false
    while (-not $valid) {
        $YNresponse = Read-SingleKeyWithTimeout -timeout $timeout -ValidKeys "Y", "y", "N", "n" -Prompt ": "
        if ($null -eq $YNresponse -or $YNresponse -eq 'Y' -or $YNresponse -eq 'y' -or $YNresponse -eq 'N' -or $YNresponse -eq 'n') {
            $valid = $true
        }
    }

    if ($YNresponse) {
        Write-Host
    }
    Write-Host "------------------------------------------"
    if ([String]::IsNullOrWhiteSpace($YNresponse)) {
        if ($Default) {
            return $Default
        }
    }
    return $YNresponse
}




function Get-CriticalVMs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "VMs to bucketize, names only")]
        [object] $vmNames = $null
    )

    $return = [pscustomObject]@{
        DC      = @()
        FS      = @()
        SQL     = @()
        CAS     = @()
        PRI     = @()
        ALLCRIT = @()
        NONCRIT = @()
    }

    $allvms = @()
    if ($vmNames) {
        # These are the names ASKED for, not what Get-List matched below.
        write-log -LogOnly "[Get-CriticalVMs] Requested $vmNames"
        $allvms += get-list -type vm -SmartUpdate
    }
    else {
        $allvms += get-list -type vm -DomainName $domain -SmartUpdate
    }

    $vms = @()
    if ($vmNames) {
        #foreach ($vm in $vmNames) {
        $vms += $allvms | Where-Object { $_.vmName -in $vmNames }
        write-log -verbose "[Get-CriticalVMs] Adding $($vms.VmName)"
        #}
    }
    else {
        $vms += $allvms
    }


    # Exclude Offline Root CA - it should only be started manually via Hyper-V
    $vms = $vms | Where-Object { $_.Role -ne "StandaloneRootCA" }

    $return.dc += $vms | Where-Object { $_.Role -in "DC", "BDC" }
    $return.ALLCRIT += $vms | Where-Object { $_.Role -in "DC", "BDC" }
    $vms = $vms | Where-Object { $_.Role -notin "DC", "BDC" }

    #$sqlServers = $vms | Where-Object { $_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion }
    $sqlServerNames = ($vms | Where-Object { $_.remoteSQLVM }).remoteSQLVM | Select-Object -Unique

    foreach ($sqlName in $sqlServerNames) {
        $thisSql = $vms | Where-Object { $_.vmName -eq $sqlName }
        $vms = $vms | Where-Object { $_.vmName -ne $sqlName }
        $return.SQL += $thisSql
        $return.ALLCRIT += $thisSql
        if ($thisSql.OtherNode) {
            $return.SQL += $vms | Where-Object { $_.vmName -eq $thisSql.OtherNode }
            $return.ALLCRIT += $vms | Where-Object { $_.vmName -eq $thisSql.OtherNode }
            $vms = $vms | Where-Object { $_.vmName -ne $thisSql.OtherNode }
        }
    }


    $fileServerNames = @()
    $fileServerNames += ($vms | Where-Object { $_.remoteContentLibVM }).remoteContentLibVM
    $fileServerNames += ($vms | Where-Object { $_.fileServerVM }).fileServerVM
    $fileServerNames += ($vms | Where-Object { $_.patchMyPCFileServer }).patchMyPCFileServer
    $fileServerNames = $fileServerNames | Select-Object -Unique

    foreach ($fsName in $fileServerNames) {
        $thisfs = $vms | Where-Object { $_.vmName -eq $fsName }
        $vms = $vms | Where-Object { $_.vmName -ne $fsName }
        $return.FS += $thisfs
        $return.ALLCRIT += $thisfs
    }

    $return.CAS += $vms | Where-Object { $_.Role -eq "CAS" }
    $return.ALLCRIT += $vms | Where-Object { $_.Role -eq "CAS" }
    $vms = $vms | Where-Object { $_.Role -ne "CAS" }
    $return.PRI += $vms | Where-Object { $_.Role -eq "Primary" }
    $return.ALLCRIT += $vms | Where-Object { $_.Role -eq "Primary" }
    $vms = $vms | Where-Object { $_.Role -ne "Primary" }
    $return.NONCRIT += $vms

    #$return | ConvertTo-Json | Out-Host
    return $return
}

function Invoke-SmartStartVMs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMs To Start, from Get-CriticalVMs")]
        [psCustomObject] $CritList,
        [Parameter(Mandatory = $false, HelpMessage = "Critical Only")]
        [switch] $CriticalOnly = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Non Critical Only")]
        [switch] $NonCriticalOnly = $false,
        [Parameter(Mandatory = $false, HelpMessage = "quiet mode")]
        [bool] $quiet = $false
    )
    $waitSecondsDC = 20
    $waitSeconds = 10

    function invoke-StartVM {
        param(
            [object] $vm,
            [bool] $quiet,
            [int] $wait = 0
        )

        $worked = $true
        $returnWait = $null
        if ($vm.State -ne "Running") {
            if (-not $quiet ) { Show-StatusEraseLine "$($vm.Role) [$($vm.vmName)] state is [$($vm.State)]. Starting VM" -indent }
            $worked = start-vm2 $vm.vmName -PassThru
            if (-not $quiet) {
                if ($worked) {
                    if ($wait -ne 0) {
                        Write-GreenCheck "VM [$($vm.vmName)] has been started. Waiting $wait Seconds.                                                                "
                        $returnWait = $wait
                    }
                    else {
                        Write-GreenCheck "VM [$($vm.vmName)] has been started.                                                                 "
                    }
                }
                else {
                    Write-Redx "VM [$($vm.vmName)] could not be started."
                }

            }
        }
        if (-not $worked) {
            if ($quiet) {
                Write-Log -Failure "Failed to start $($vm.vmName)" -LogOnly
            }
            else {
                Write-Log -Failure "Failed to start $($vm.vmName)"
            }
        }
        if ($returnWait) {
            return $returnWait
        }
        else {
            return $worked
        }
    }


    $worked = $true
    $failures = 0
    if ($NonCriticalOnly) {
        foreach ($vm in $CritList.NONCRIT) {
            $worked = invoke-StartVM -vm $vm -quiet:$quiet
            if (-not $worked) {
                $failures++
            }
            if ($worked -is [int]) {
                $sleepSecs = $worked
            }
        }
        return $failures
    }

    $sleepSecs = $null
    if ($CritList.DC) {
        foreach ($dc in $CritList.DC) {
            $worked = invoke-StartVM -vm $dc -quiet:$quiet -wait $waitSecondsDC
            if (-not $worked) {
                $failures++
            }
            else {
                if ($worked -is [int]) {
                    $sleepSecs = $worked
                }
            }
        }
        if ($sleepSecs) {
            start-Sleep -Seconds $sleepSecs
        }
    }
    $sleepSecs = $null
    if ($CritList.FS) {
        foreach ($fs in $CritList.FS) {
            $worked = invoke-StartVM -vm $fs -quiet:$quiet -wait $waitSeconds
            if (-not $worked) {
                $failures++
            }
            else {
                if ($worked -is [int]) {
                    $sleepSecs = $worked
                }
            }
        }
        if ($sleepSecs) {
            start-Sleep -Seconds $sleepSecs
        }
    }
    $sleepSecs = $null
    if ($CritList.SQL) {
        foreach ($sql in $CritList.SQL) {
            $worked = invoke-StartVM -vm $sql -quiet:$quiet -wait $waitSeconds
            if (-not $worked) {
                $failures++
            }
            else {
                if ($worked -is [int]) {
                    $sleepSecs = $worked
                }
            }
        }
        if ($sleepSecs) {
            start-Sleep -Seconds $sleepSecs
        }
    }
    $sleepSecs = $null
    if ($CritList.CAS) {
        foreach ($ss in $CritList.CAS) {
            $worked = invoke-StartVM -vm $ss -quiet:$quiet -wait $waitSeconds
            if (-not $worked) {
                $failures++
            }
            else {
                if ($worked -is [int]) {
                    $sleepSecs = $worked
                }
            }
        }
        if ($sleepSecs) {
            start-Sleep -Seconds $sleepSecs
        }
    }
    $sleepSecs = $null
    if ($CritList.PRI) {
        foreach ($ss in $CritList.PRI) {
            $worked = invoke-StartVM -vm $ss -quiet:$quiet -wait $waitSeconds
            if (-not $worked) {
                $failures++
            }
            else {
                if ($worked -is [int]) {
                    $sleepSecs = $worked
                }
            }
        }
        if ($sleepSecs) {
            start-Sleep -Seconds $sleepSecs
        }
    }
    if ($CriticalOnly -eq $false) {
        foreach ($vm in $CritList.NONCRIT) {
            $worked = invoke-StartVM -vm $vm -quiet:$quiet
            if (-not $worked) {
                $failures++
            }
        }
    }
    $global:vm_List_LastUpdate = $null
    get-list -type VM -SmartUpdate | out-null
    return $failures
}

function Invoke-StopVMs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "List OF VMs objects to stop.  Otherwise the entire domain")]
        [object[]] $vmList = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Quiet Moden")]
        [bool] $quiet = $false
    )


    if (-not $vmList) {
        $vmList = get-list -type vm -DomainName $domain -SmartUpdate
    }
    $vmNames = @()
    $stopJobs = @()
    foreach ($vm in $vmList) {
        $vm2 = $null
        if ($vm -is [String]) {
            $vm = Get-VM2 -name $vm -ErrorAction SilentlyContinue
            $vm2 = $vm
        }
        if ($vm.State -eq "Running") {
            if (-not $vm2) {
                $vm2 = Get-VM2 -Name $vm.vmName -ErrorAction SilentlyContinue
            }
            if (-not $quiet) {
                Write-GreenCheck "$($vm.vmName) is [$($vm2.State)]. Shutting down VM. Will forcefully stop after 5 mins"
            }
            $vmNames += $vm2.Name
            $stopJobs += @(stop-vm -VM $VM2 -force -AsJob)
        }
    }

    # Show-JobsProgress but break out early when all target VMs are actually off.
    # Stop-VM jobs can hang even after the VM has stopped (Hyper-V WMI quirk).
    # Count only this call's jobs: abandoned stragglers from an earlier call are
    # deliberately left in the session (see the disposal note below) and must not be
    # mistaken for work in progress here.
    $jobs = @($stopJobs | Where-Object { $_.State -notin @('Completed', 'Stopped', 'Failed') })
    [int]$total = $jobs.Count
    if ($total -gt 0) {
        $stallCheck = [System.Diagnostics.Stopwatch]::StartNew()
        [int]$lastRunning = $total
        while ($true) {
            [int]$runningjobs = @($stopJobs | Where-Object { $_.State -notin @('Completed', 'Stopped', 'Failed') }).Count
            if ($runningjobs -eq 0) { break }

            $percent = [math]::Round((($total - $runningjobs) / $total * 100), 2)
            Write-Progress2 -activity "Stopping VMs" -status "Progress: $percent%" -percentcomplete $percent

            # Reset stall timer whenever a job finishes
            if ($runningjobs -lt $lastRunning) {
                $lastRunning = $runningjobs
                $stallCheck.Restart()
            }

            # If no job has finished in 30 seconds, check whether the VMs are actually off
            if ($stallCheck.Elapsed.TotalSeconds -ge 30 -and $vmNames.Count -gt 0) {
                $stillRunning = @($vmNames | ForEach-Object { Get-VM2 -Name $_ -ErrorAction SilentlyContinue } | Where-Object { $_.State -eq "Running" })
                if ($stillRunning.Count -eq 0) {
                    # All VMs are off; the zombie jobs are Hyper-V's problem now. Leave
                    # them alone -- see the disposal note below.
                    break
                }
                $stallCheck.Restart()
            }

            Start-Sleep -Milliseconds 500
        }
        Write-Progress2 -activity "Stopping VMs" -Completed
    }

    # Reap only jobs Hyper-V has finished with. A Stop-VM VMJob still in flight
    # completes on a threadpool thread that calls SetJobState on this object; dispose
    # it first and that callback throws PSObjectDisposedException with no handler
    # above it, killing the process. The stragglers go when this process does.
    foreach ($doneJob in @($stopJobs | Where-Object { $_.State -in @('Completed', 'Failed') })) {
        try { Remove-Job -Job $doneJob -Force -ErrorAction SilentlyContinue } catch {}
    }
    # Invalidate the Get-List cache so the refresh below picks up
    # the new VM states without being blocked by the throttle.
    $global:vm_List_LastUpdate = $null
    get-list -type VM -SmartUpdate | out-null
}

function Complete-PendingVMOperation {
    <#
    .SYNOPSIS
        Checks whether any background Stop/Start VM operations have finished
        and displays the results. Only consumes (removes) completed ops when
        ALL ops are done, so completed domains stay visible in the banner
        while other ops are still running.
    .OUTPUTS
        $true if any completed operations were consumed, $false otherwise.
    #>
    if (-not $global:PendingVMOperations -or $global:PendingVMOperations.Count -eq 0) { return $false }

    # Check if any ops are still active
    $hasActive = $false
    foreach ($domainKey in @($global:PendingVMOperations.Keys)) {
        $op = $global:PendingVMOperations[$domainKey]
        if (-not $op.Completed) {
            # Check for vanished jobs
            $job = Get-Job -Name $op.JobName -ErrorAction SilentlyContinue
            if (-not $job) {
                Write-Log "Background $($op.Type) operation for '$domainKey': job disappeared unexpectedly." -Warning
                $op.Completed = $true
                $op.Failures = $op.VMCount
                $op.Elapsed = (Get-Date) - $op.StartTime
            }
            else {
                $hasActive = $true
            }
        }
    }

    # Don't consume yet if some ops are still running — keep completed
    # ops in the hashtable so the banner can show them with a checkmark.
    if ($hasActive) { return $false }

    # All ops are done — consume and display results for each
    $consumed = $false
    foreach ($domainKey in @($global:PendingVMOperations.Keys)) {
        $op = $global:PendingVMOperations[$domainKey]
        if ($op.Completed) {
            Write-Host
            if ($op.Failures -eq 0) {
                Write-GreenCheck "Background $($op.Type): All $($op.VMCount) VM(s) in '$($op.Domain)' completed successfully. ($([math]::Round($op.Elapsed.TotalSeconds))s)"
            }
            else {
                Write-RedX "Background $($op.Type): $($op.Failures) of $($op.VMCount) VM(s) in '$($op.Domain)' had issues. ($([math]::Round($op.Elapsed.TotalSeconds))s)" -ForegroundColor Red
            }
            # Clean up the job
            $job = Get-Job -Name $op.JobName -ErrorAction SilentlyContinue
            if ($job) {
                try { Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null } catch {}
                try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
            }
            $consumed = $true
        }
    }

    if ($consumed) {
        $global:PendingVMOperations = @{}
        $global:vm_List_Dirty = $true
    }
    return $consumed
}

function Invoke-StopVMsBackground {
    <#
    .SYNOPSIS
        Non-blocking wrapper around Invoke-StopVMs. Fires Stop-VM for
        each target VM and monitors completion in a background ThreadJob.
        Returns immediately so the caller can continue rendering the menu.
    .DESCRIPTION
        If Start-ThreadJob is not available (PS5), falls back to the
        synchronous Invoke-StopVMs so behaviour is never worse than today.
        Only one background VM operation may be active at a time.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string] $domain,
        [Parameter(Mandatory = $false)] [object[]] $vmList = $null
    )

    # Guard: only one background operation per domain
    if (-not $global:PendingVMOperations) { $global:PendingVMOperations = @{} }
    $existingOp = $global:PendingVMOperations[$domain]
    if ($existingOp -and -not $existingOp.Completed) {
        Write-OrangePoint "A background $($existingOp.Type) operation is already in progress for '$domain'."
        return
    }

    # Fallback: if ThreadJob is unavailable, run synchronously
    if (-not (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)) {
        Invoke-StopVMs -domain $domain -vmList $vmList
        return
    }

    # Resolve VM list and collect names
    if (-not $vmList) {
        $vmList = get-list -type vm -DomainName $domain -SmartUpdate
    }
    $targetNames = @()
    foreach ($vm in $vmList) {
        if ($vm -is [string]) { $targetNames += $vm }
        elseif ($vm.vmName)   { $targetNames += $vm.vmName }
    }
    if ($targetNames.Count -eq 0) { return }

    $jobName = "MemLabs-StopVMs-$(Get-Date -Format 'HHmmss')"
    $global:PendingVMOperations[$domain] = @{
        Type         = "Stop"
        Domain       = $domain
        VMNames      = $targetNames
        VMCount      = $targetNames.Count
        StillActive  = $targetNames.Count
        StateChanged = $false
        StartTime    = Get-Date
        Completed    = $false
        Failures     = 0
        Elapsed      = $null
        JobName      = $jobName
    }

    # Capture the hashtable reference so the ThreadJob can modify it.
    # ThreadJobs run in a separate runspace — $global: variables and
    # custom functions (Get-VM2, Write-Log, etc.) are NOT available.
    # Only built-in / module cmdlets (Get-VM, Stop-VM) work.
    $opRef = $global:PendingVMOperations[$domain]

    $null = Start-ThreadJob -Name $jobName -ScriptBlock {
        $op = $using:opRef
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # Issue Stop-VM for each running target VM (in parallel via -AsJob)
            foreach ($name in $op.VMNames) {
                $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
                if ($vm -and $vm.State -eq "Running") {
                    Stop-VM -VM $vm -Force -AsJob | Out-Null
                }
            }

            # Poll until all target VMs reach Off/Saved or hard timeout
            $previousActive = $op.VMCount
            while ($sw.Elapsed.TotalMinutes -lt 10) {
                Start-Sleep -Seconds 2
                $stillActive = 0
                foreach ($name in $op.VMNames) {
                    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
                    if ($vm -and $vm.State -notin @("Off", "Saved")) {
                        $stillActive++
                    }
                }
                $op.StillActive = $stillActive
                if ($stillActive -ne $previousActive) { $op.StateChanged = $true }
                $previousActive = $stillActive
                if ($stillActive -eq 0) { break }
            }

            # Don't Remove-Job on Hyper-V WMI jobs — disposing them can crash
            # the process (PSObjectDisposedException on a threadpool callback).
            # They'll be cleaned up when the ThreadJob's runspace is torn down.

            # Count failures
            $failures = 0
            foreach ($name in $op.VMNames) {
                $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
                if ($vm -and $vm.State -notin @("Off", "Saved")) { $failures++ }
            }
            $op.Failures = $failures
        }
        catch {
            $op.Failures = $op.VMCount
        }
        finally {
            $op.Elapsed = $sw.Elapsed
            $op.Completed = $true
        }
    }

    Write-Log "Background Stop: launched job '$jobName' for $($targetNames.Count) VM(s) in '$domain'" -LogOnly
}

function Invoke-SmartStartVMsBackground {
    <#
    .SYNOPSIS
        Non-blocking wrapper around Invoke-SmartStartVMs. Starts VMs in
        dependency order (DC → FS → SQL → CAS → PRI → NONCRIT) inside a
        background ThreadJob and returns immediately.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]  [psCustomObject] $CritList,
        [Parameter(Mandatory = $false)] [switch] $CriticalOnly,
        [Parameter(Mandatory = $true)]  [string] $domain
    )

    # Guard: only one background operation per domain
    if (-not $global:PendingVMOperations) { $global:PendingVMOperations = @{} }
    $existingOp = $global:PendingVMOperations[$domain]
    if ($existingOp -and -not $existingOp.Completed) {
        Write-OrangePoint "A background $($existingOp.Type) operation is already in progress for '$domain'."
        return
    }

    # Fallback: if ThreadJob is unavailable, run synchronously
    if (-not (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)) {
        return Invoke-SmartStartVMs -CritList $CritList -CriticalOnly:$CriticalOnly
    }

    # Count total VMs
    $allNames = @()
    foreach ($bucket in @('DC', 'FS', 'SQL', 'CAS', 'PRI')) {
        $allNames += @($CritList.$bucket | ForEach-Object { $_.vmName }) | Where-Object { $_ }
    }
    if (-not $CriticalOnly) {
        $allNames += @($CritList.NONCRIT | ForEach-Object { $_.vmName }) | Where-Object { $_ }
    }
    if ($allNames.Count -eq 0) { return }

    $jobName = "MemLabs-StartVMs-$(Get-Date -Format 'HHmmss')"
    $global:PendingVMOperations[$domain] = @{
        Type         = "Start"
        Domain       = $domain
        VMNames      = $allNames
        VMCount      = $allNames.Count
        StillActive  = $allNames.Count
        StateChanged = $false
        StartTime    = Get-Date
        Completed    = $false
        Failures     = 0
        Elapsed      = $null
        JobName      = $jobName
    }

    # Capture references for the ThreadJob via $using:.
    # ThreadJobs run in a separate runspace — $global: variables and
    # custom functions (Start-VM2, Invoke-SmartStartVMs, Write-Log, etc.)
    # are NOT available. Only built-in / module cmdlets work.
    $opRef = $global:PendingVMOperations[$domain]
    $critListCopy = $CritList
    $critOnlyCopy = [bool]$CriticalOnly

    $null = Start-ThreadJob -Name $jobName -ScriptBlock {
        $op = $using:opRef
        $crit = $using:critListCopy
        $critOnly = $using:critOnlyCopy
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $failures = 0
            $waitSecondsDC = 20
            $waitSeconds = 10

            # Start VMs in dependency order: DC > FS > SQL > CAS > PRI > NONCRIT
            $buckets = @('DC', 'FS', 'SQL', 'CAS', 'PRI')
            if (-not $critOnly) { $buckets += 'NONCRIT' }
            $startedNames = @()  # Track VMs where Start-VM succeeded

            # Live-refresh the banner's progress counter from the ACTUAL running
            # state of every target VM. Called repeatedly while VMs are still
            # being issued Start-VM so the count climbs as each VM powers on,
            # instead of staying pinned at 0/N until the whole start loop (which
            # includes ~60s of inter-bucket sleeps and can take minutes to issue
            # Start-VM for every VM on a loaded host) finishes.
            $updateActive = {
                $runningNow = 0
                foreach ($n in $op.VMNames) {
                    $v = Get-VM -Name $n -ErrorAction SilentlyContinue
                    if ($v -and $v.State -eq "Running") { $runningNow++ }
                }
                $newActive = $op.VMCount - $runningNow
                if ($newActive -ne $op.StillActive) {
                    $op.StillActive = $newActive
                    $op.StateChanged = $true
                }
            }

            foreach ($bucket in $buckets) {
                $vms = @($crit.$bucket | Where-Object { $_ })
                if ($vms.Count -eq 0) { continue }
                $waitSecs = if ($bucket -eq 'DC') { $waitSecondsDC } elseif ($bucket -ne 'NONCRIT') { $waitSeconds } else { 0 }
                $startedAny = $false

                foreach ($vm in $vms) {
                    $hvVm = Get-VM -Name $vm.vmName -ErrorAction SilentlyContinue
                    if ($hvVm -and $hvVm.State -eq "Running") {
                        # Already running — not a failure, just skip
                        $startedNames += $vm.vmName
                    }
                    elseif ($hvVm) {
                        try {
                            Start-VM -Name $vm.vmName -ErrorAction Stop
                            $startedAny = $true
                            $startedNames += $vm.vmName
                        }
                        catch {
                            $failures++
                        }
                    }
                    else {
                        $failures++  # VM doesn't exist
                    }
                    # Reflect the new running count in the banner as we go.
                    & $updateActive
                }

                if ($startedAny -and $waitSecs -gt 0) {
                    # Refresh the counter across the inter-bucket wait so VMs
                    # that finish powering on during the sleep show up promptly.
                    for ($w = 0; $w -lt $waitSecs; $w++) {
                        Start-Sleep -Seconds 1
                        & $updateActive
                    }
                }
            }

            # Poll only VMs where Start-VM succeeded until they reach Running.
            # VMs that failed Start-VM are already counted as failures.
            $pendingNames = @($startedNames | Where-Object {
                $v = Get-VM -Name $_ -ErrorAction SilentlyContinue
                $v -and $v.State -ne "Running"
            })
            $op.StillActive = $pendingNames.Count + $failures
            $previousActive = $op.StillActive
            if ($pendingNames.Count -gt 0) {
                while ($sw.Elapsed.TotalMinutes -lt 10) {
                    Start-Sleep -Seconds 2
                    $stillActive = 0
                    foreach ($name in $pendingNames) {
                        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
                        if ($vm -and $vm.State -ne "Running") {
                            $stillActive++
                        }
                    }
                    $op.StillActive = $stillActive + $failures
                    if (($stillActive + $failures) -ne $previousActive) { $op.StateChanged = $true }
                    $previousActive = $stillActive + $failures
                    if ($stillActive -eq 0) { break }
                }
            }

            # Count final failures (VMs that never reached Running)
            foreach ($name in $startedNames) {
                $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
                if ($vm -and $vm.State -ne "Running") { $failures++ }
            }
            $op.Failures = $failures
        }
        catch {
            $op.Failures = $op.VMCount
        }
        finally {
            $op.Elapsed = $sw.Elapsed
            $op.Completed = $true
        }
    }

    Write-Log "Background Start: launched job '$jobName' for $($allNames.Count) VM(s) in '$domain'" -LogOnly
}

Function Show-StatusEraseLine {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "role")]
        [string] $data,
        [Parameter(Mandatory = $false, HelpMessage = "role")]
        [switch] $indent
    )
    if ($indent) {
        Write-Host "  " -NoNewline
    }
    Write-Host $data -NoNewline
    #start-Sleep -seconds 2 | out-null
    Write-Host "`r" -NoNewline
    #Write-GreenCheck "Check Point Complete for ADA-DC1" -ForeGroundColor Green
}

function ConvertTo-DeployConfigEx {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config to Convert")]
        [object] $deployConfig
    )


    $deployConfigEx = $deployConfig | ConvertTo-Json -depth 5 | ConvertFrom-Json

    foreach ($thisVM in $deployConfigEx.virtualMachines) {

        if (-not $thisVM) {
            throw "Blank VM returned from deployconfig"
        }

        if (-not $thisVM.vmName) {
            write-host "$thisVM"
            throw "VM with no vmName property found."

        }
        $cm_svc = "cm_svc"
        $accountLists = [pscustomobject]@{
            SQLSysAdminAccounts = @()
            LocalAdminAccounts  = @($cm_svc)
            WaitOnDomainJoin    = @()
            DomainAccounts      = @($deployConfig.vmOptions.adminName, "cm_svc", "vmbuildadmin", "administrator")
            DomainAdmins        = @($deployConfig.vmOptions.adminName)
            SchemaAdmins        = @($deployConfig.vmOptions.adminName)
        }
        $thisParams = [pscustomobject]@{}
        if ($thisVM.domainUser) {
            $accountLists.LocalAdminAccounts += $thisVM.domainUser
            $accountLists.SQLSysAdminAccounts += $deployConfig.vmOptions.domainNetBiosName + "\" + $thisVM.domainUser
        }

        #Get the current network from get-list or config
        $thisVMObject = Get-VMFromList2 -deployConfig $deployConfig -vmName $thisVM.vmName
        if ($thisVMObject.network) {
            $thisParams | Add-Member -MemberType NoteProperty -Name "vmNetwork" -Value $thisVMObject.network -Force
        }
        else {
            $thisParams | Add-Member -MemberType NoteProperty -Name "vmNetwork" -Value $deployConfig.vmOptions.network -Force
        }

        $SQLAO = $deployConfig.virtualMachines | Where-Object { $_.role -eq "SQLAO" }

        switch ($thisVM.role) {
            "FileServer" {
                if ($SQLAO) {
                    foreach ($sql in $SQLAO) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $sql -accountLists $accountLists -deployConfig $deployconfig -WaitOnDomainJoin
                    }
                }
            }

            "OtherDC" {
                $ODC = Get-list -Type VM | Where-Object { $_.vmName -eq $thisVm.VmName }
                $thisParams | Add-Member -MemberType NoteProperty -Name "Domain" -Value $ODC.domain -force
                $ODCIP = $ODC.network -replace "\d{1,3}$", "1"

                $thisParams | Add-Member -MemberType NoteProperty -Name "IPAddr" -Value $ODCIP -force
            }
            "DC" {
                $DomainAccountsUPN = @()
                $DomainComputers = @()
                if ($SQLAO) {
                    foreach ($sql in $SQLAO) {
                        if ($sql.OtherNode) {

                            $ClusterName = $sql.ClusterName

                            $DomainAccountsUPN += @($sql.SqlServiceAccount, $sql.SqlAgentAccount)

                            # Prestage both the CNO (cluster name) and the VCO
                            # (listener) as disabled computer objects so the
                            # cluster service doesn't need Create Computer Objects
                            # permission on the container.
                            $DomainComputers += @($ClusterName)
                            if ($sql.AlwaysOnListenerName) {
                                $DomainComputers += @($sql.AlwaysOnListenerName)
                            }
                        }
                    }
                }
                foreach ($vm in $deployConfig.virtualMachines) {
                    if ($vm.SqlServiceAccount -and $vm.SqlServiceAccount -ne "LocalSystem") {
                        $DomainAccountsUPN += @($vm.SqlServiceAccount)
                    }

                    if ($vm.SqlAgentAccount -and $vm.SqlAgentAccount -ne "LocalSystem") {
                        $DomainAccountsUPN += @($vm.SqlAgentAccount)
                    }
                }
                $DomainAccountsUPN += get-list2 -DeployConfig $deployConfig | Where-Object { $_.domainUser } | Select-Object -ExpandProperty domainUser -Unique
                $DomainAccountsUPN = $DomainAccountsUPN | Where-Object { $_ } | Select-Object -Unique

                if ($DomainAccountsUPN.Count -gt 0) {
                    $DomainAccountsUPN = $DomainAccountsUPN | Select-Object -Unique
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DomainAccountsUPN" -Value $DomainAccountsUPN -Force
                }
                if ($DomainComputers.Count -gt 0) {
                    $DomainComputers = $DomainComputers | Select-Object -Unique
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DomainComputers" -Value  $DomainComputers -Force
                }


                if ($thisVM.externalDomainJoinSiteCode) {

                    $OtherCAVM = (Get-list -type vm -DomainName $ThisVM.ForestTrust | Where-Object { $_.InstallCA })
                    if ($OtherCAVM) {
                        #ADA-DC1.adatum.com\adatum-ADA-DC1-CA
                        $OtherDomainShort = $($ThisVM.ForestTrust).Split(".")[0]
                        $OtherRootCA = "$($OtherCAVM.VmName).$($ThisVM.ForestTrust)\$($OtherDomainShort)-$($OtherCAVM.VmName)-CA"
                        $thisParams | Add-Member -MemberType NoteProperty -Name "RootCA" -Value $OtherRootCA -Force

                        # RootCA above is only a best-effort GUESS (assumes the CA
                        # lives on the InstallCA VM and that its CN follows
                        # <netbios>-<vm>-CA). With multi-tier PKI the issuing CA can
                        # live on any member server with a custom CN, so the DSC
                        # resource AUTHORITATIVELY rediscovers it from the remote
                        # forest's AD Enrollment Services container. Give it the
                        # remote DC to query and a host hint to disambiguate when
                        # multiple Enterprise issuing CAs are published.
                        $OtherDCForCA = (Get-list -type vm -DomainName $ThisVM.ForestTrust | Where-Object { $_.Role -eq "DC" } | Select-Object -First 1)
                        if ($OtherDCForCA) {
                            $thisParams | Add-Member -MemberType NoteProperty -Name "RootCADC" -Value "$($OtherDCForCA.VmName).$($ThisVM.ForestTrust)" -Force
                        }
                        $thisParams | Add-Member -MemberType NoteProperty -Name "IssuingCAHint" -Value "$(($OtherCAVM | Select-Object -First 1).VmName)" -Force
                    }

                    if ($thisVM.externalDomainJoinSiteCode -ne "NONE") {
                        $RemoteSS = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.externalDomainJoinSiteCode -DomainName $thisVM.ForestTrust -type VM
                        if (-not $RemoteSS.VmName) {
                            Write-log "Could not find a site server with SiteCode $($thisVM.externalDomainJoinSiteCode) in domain $($thisVM.ForestTrust)" -Failure
                            return $false
                        }
                        $ExternalSiteServer = "$($RemoteSS.VmName).$($thisVM.ForestTrust)"
                        $ExternalTopLevelSiteServer = $ExternalSiteServer
                        $OtherDCVM = (Get-list -type vm -DomainName $ThisVM.ForestTrust | Where-Object { $_.Role -eq "DC" })
                        $otherDC = "$($OtherDCVM.VmName).$($ThisVM.ForestTrust)"
                        $thisParams | Add-Member -MemberType NoteProperty -Name "OtherDC" -Value $otherDC -Force

                        $thisParams | Add-Member -MemberType NoteProperty -Name "ExternalSiteServer" -Value $ExternalSiteServer -Force
                        if ($RemoteSS.ParentSiteCode) {
                            $RemoteCAS = Get-TopSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $RemoteSS.ParentSiteCode -DomainName $thisVM.ForestTrust -type VM
                            #$RemoteCAS = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $RemoteSS.ParentSiteCode -DomainName $thisVM.ForestTrust -type VM
                            $ExternalTopLevelSiteServer = "$($RemoteCAS.VmName).$($thisVM.ForestTrust)"
                        }
                        $thisParams | Add-Member -MemberType NoteProperty -Name "ExternalTopLevelSiteServer" -Value $ExternalTopLevelSiteServer -Force
                    }
                }
                #$accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.domainUser } | Select-Object -ExpandProperty domainUser -Unique
                #$accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.SQLAgentAccount } | Select-Object -ExpandProperty SQLAgentAccount -Unique
                #$accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.SqlServiceAccount } | Select-Object -ExpandProperty SqlServiceAccount -Unique
                #$accountLists.DomainAccounts = $accountLists.DomainAccounts | Select-Object -Unique

                $ServersToWaitOn = @()
                $thisPSName = $null
                $thisCSName = $null
                foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in "Primary", "Secondary", "CAS", "PassiveSite", "SQLAO", "SiteSystem" -and -not $_.hidden }) {
                    $ServersToWaitOn += $vm.vmName
                    if ($vm.Role -eq "Primary") {
                        $thisPSName = $vm.vmName
                        if ($vm.ParentSiteCode) {
                            $thisCSName = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $vm.ParentSiteCode
                        }
                    }
                    if ($vm.Role -eq "CAS") {
                        $thisCSName = $vm.vmName
                    }
                }

                $thisParams | Add-Member -MemberType NoteProperty -Name "ServersToWaitOn" -Value $ServersToWaitOn -Force
                if ($thisPSName) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "PSName" -Value $thisPSName -Force
                }
                if ($thisCSName) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "CSName" -Value $thisCSName -Force
                }
                if ($thisVM.hidden) {
                    $DC = get-list -type VM -DomainName $deployConfig.vmOptions.DomainName | Where-Object { $_.Role -eq "DC" }
                    $addr = $dc.Network.Substring(0, $dc.Network.LastIndexOf(".")) + ".1"
                    $gateway = $dc.Network.Substring(0, $dc.Network.LastIndexOf(".")) + ".200"
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DCIPAddress" -Value $addr  -Force
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DCDefaultGateway" -Value $gateway  -Force
                }
                else {
                    #This is Okay.. since the vmOptions.network for the DC is correct
                    $addr = $deployConfig.vmOptions.network.Substring(0, $deployConfig.vmOptions.network.LastIndexOf(".")) + ".1"
                    $gateway = $deployConfig.vmOptions.network.Substring(0, $deployConfig.vmOptions.network.LastIndexOf(".")) + ".200"
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DCIPAddress" -Value $addr  -Force
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DCDefaultGateway" -Value $gateway  -Force
                }

            }
            "SQLAO" {
                $AlwaysOn = Get-SQLAOConfig -deployConfig $deployConfig -vmName $thisVM.vmName
                if ($AlwaysOn) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "SQLAO" -Value $AlwaysOn -Force
                }


            }
            "PassiveSite" {
                $ActiveVM = Get-ActiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.siteCode -type VM
                if ($ActiveVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "ActiveNode" -Value $ActiveVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $ActiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    if ($ActiveVM.Role -eq "CAS") {
                        $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $ActiveVM.siteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) }
                        if ($primaryVM) {
                            Add-VMToAccountLists -thisVM $thisVM -VM $primaryVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                            $PassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $primaryVM.siteCode -type VM
                            if ($PassiveVM) {
                                Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                            }
                        }
                    }
                }
            }
            "SiteSystem" {
                if ($thisVM.InstallSUP) {
                    $SS = Get-SiteServerForSiteCode -siteCode $thisVM.SiteCode -deployConfig $deployConfig -type VM
                    Add-VMToAccountLists -thisVM $thisVM -VM $SS -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts

                    $PassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.SiteCode -type VM
                    if ($PassiveVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts
                    }

                    $ActiveVM = Get-ActiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.siteCode -type VM

                    $sql = Get-SqlServerForSiteCode -siteCode $thisVM.SiteCode -deployConfig $deployConfig -type VM
                    if (-not $ActiveVM.InstallSUP) {
                        if (-not $sql.InstallSUP) {
                            $thisParams | Add-Member -MemberType NoteProperty -Name "WSUSSqlServer" -Value $($sql.vmName)  -Force
                        }
                    }
                }
                if ($thisVM.wsusDataBaseServer -and $thisVM.wsusDataBaseServer -ne "WID") {
                    $sqlVM = $deployConfig.virtualMachines | Where-Object { $_.VmName -eq $thisVM.wsusDataBaseServer }

                    Add-VMToAccountLists -thisVM $thisVM -VM $sqlVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts -SQLSysAdminAccounts -WaitOnDomainJoin
                }
            }
            "WSUS" {
                if ($thisVM.InstallSUP) {
                    $SS = Get-SiteServerForSiteCode -siteCode $thisVM.SiteCode -deployConfig $deployConfig -type VM
                    Add-VMToAccountLists -thisVM $thisVM -VM $SS -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts

                    $PassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.SiteCode -type VM
                    if ($PassiveVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts
                    }
                }
            }
            "CAS" {
                $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $thisVM.siteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) }
                if ($primaryVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "Primary" -Value $primaryVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $primaryVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    $PassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $primaryVM.siteCode -type VM
                    if ($PassiveVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts -WaitOnDomainJoin
                    }
                }
                $url = Get-CMBaselineVersion -CMVersion $deployConfig.cmOptions.version
                $thisParams | Add-Member -MemberType NoteProperty -Name "cmDownloadVersion" -Value $url  -Force
            }
            "Primary" {
                if ($_.Hidden) {
                    break
                }
                $reportingSecondaries = @()
                $reportingSecondaries += ($deployConfig.virtualMachines | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $thisVM.siteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) }).siteCode
                $reportingSecondaries += (get-list -type vm -domain $deployConfig.vmOptions.domainName | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $thisVM.siteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) }).siteCode
                $reportingSecondaries = $reportingSecondaries | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
                $thisParams | Add-Member -MemberType NoteProperty -Name "ReportingSecondaries" -Value $reportingSecondaries -Force




                $AllSiteCodes = $reportingSecondaries
                $AllSiteCodes += $thisVM.siteCode


                foreach ($system in $deployConfig.virtualMachines | Where-Object { $_.role -eq "SiteSystem" -and $_.siteCode -in $AllSiteCodes -and -not $_.hidden }) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $system  -accountLists $accountLists -deployConfig $deployconfig -WaitOnDomainJoin
                }

                $SecondaryVM = $deployConfig.virtualMachines | Where-Object { $_.parentSiteCode -eq $ThisVM.siteCode -and $_.role -eq "Secondary" -and -not $_.hidden }

                if ($SecondaryVM) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $SecondaryVM  -accountLists $accountLists -deployConfig $deployconfig -WaitOnDomainJoin
                }
                # If we are deploying a new CAS at the same time, record it for the DSC
                $CASVM = $deployConfig.virtualMachines | Where-Object { $_.role -in "CAS" -and $thisVM.ParentSiteCode -eq $_.SiteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) }
                if ($CASVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "CSName" -Value $CASVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $CASVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts -WaitOnDomainJoin

                    $CASPassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $CASVM.siteCode -type VM
                    if ($CASPassiveVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $CASPassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    }
                }
                else {
                    $url = Get-CMBaselineVersion -CMVersion $deployConfig.cmOptions.version
                    $thisParams | Add-Member -MemberType NoteProperty -Name "cmDownloadVersion" -Value $url  -Force
                }

                # --- ClientPush
                $thisVMNetwork = $thisVMObject.Network

                # Push to any DomainMember (incl. SQL) or site system VM whose
                # pushClient TARGET SITE is this Primary's site or one of its
                # reporting Secondaries. pushClient is now a site code string
                # (the site to push from) or $false (no push). Resolve-PushClientSite
                # turns legacy $true / stale values into a concrete site code, so
                # a client on ANY subnet lands on the correct site (subnet no
                # longer has to match the site server's own subnet).
                $pushableRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
                $eligiblePushSites = @(Get-EligiblePushSites -Config $deployConfig -Domain $DomainName)
                $ClientNames = get-list2 -DeployConfig $deployConfig | Where-Object {
                    $_.role -in $pushableRoles -and ($_.pushClient -ne $false)
                }
                # Site codes this Primary is responsible for pushing: its own
                # site + any child Secondary (a Secondary has no client-push
                # workflow of its own; the parent Primary pushes its clients).
                $myPushSiteCodes = @($thisVM.siteCode)
                $myPushSiteCodes += (get-list2 -deployConfig $deployConfig | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $thisVM.siteCode }).siteCode
                $myPushSiteCodes = @($myPushSiteCodes | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)

                $clientPush = @()
                foreach ($cn in $ClientNames) {
                    $targetSite = Resolve-PushClientSite -VM $cn -Config $deployConfig -Domain $DomainName -EligibleSites $eligiblePushSites
                    if ($targetSite -and ($myPushSiteCodes -contains $targetSite)) {
                        $clientPush += $cn.vmName
                    }
                }
                $clientPush = ($clientPush | Where-Object { $_ -and $_.Trim() } | select-object -unique)
                if ($clientPush) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "ClientPush" -Value $clientPush -Force
                }

            }
            "Secondary" {
                $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $thisVM.parentSiteCode }
                if ($primaryVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "Primary" -Value $primaryVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $primaryVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    $PassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $primaryVM.siteCode -type VM
                    if ($PassiveVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    }
                }
            }
        }

        #add the SiteCodes and Subnets so DC can add ad sites, and primary can setup BG's
        if ($thisVM.Role -eq "DC" -or $thisVM.Role -eq "Primary") {
            $sitesAndNetworks = @()

            foreach ($vm in get-list2 -DeployConfig $deployConfig | Where-Object { $_.role -in "Primary", "Secondary" }) {
                if ($vm.SiteCode -in $sitesAndNetworks.siteCode) {
                    Write-Log "Warning: $($vm.vmName) has a sitecode already in use by another Primary or Secondary" -Warning
                    continue
                }
                if ($vm.network -in $sitesAndNetworks.Subnet) {
                    Write-Log "Warning: $($vm.vmName) has a network already in use by another Primary or Secondary" -Warning
                    continue
                }
                $sitesAndNetworks += [PSCustomObject]@{
                    SiteCode = $vm.siteCode
                    Subnet   = $vm.network
                }
            }

            # Client-subnet boundaries: a pushed client can live on a subnet that
            # hosts no site server (e.g. 172.16.1.0). Add a (pushTargetSite,
            # clientSubnet) pair for every distinct pushed subnet not already
            # mapped, so InstallBoundaryGroups builds the boundary in the right
            # site's BG and the DC creates the matching AD subnet. Without this a
            # client on a standalone subnet gets no boundary and never assigns.
            $bgPushableRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
            $bgEligibleSites = @(Get-EligiblePushSites -Config $deployConfig -Domain $DomainName)
            foreach ($vm in get-list2 -DeployConfig $deployConfig | Where-Object { $_.role -in $bgPushableRoles -and ($_.pushClient -ne $false) }) {
                $targetSite = Resolve-PushClientSite -VM $vm -Config $deployConfig -Domain $DomainName -EligibleSites $bgEligibleSites
                if (-not $targetSite) { continue }
                $vmSubnet = if ($vm.network) { $vm.network } else { $deployConfig.vmOptions.network }
                if (-not $vmSubnet) { continue }
                # Skip if this subnet is already mapped (to its own site server,
                # or already added for another pushed VM on the same subnet).
                if ($vmSubnet -in $sitesAndNetworks.Subnet) { continue }
                $sitesAndNetworks += [PSCustomObject]@{
                    SiteCode = $targetSite
                    Subnet   = $vmSubnet
                }
            }

            $thisParams | Add-Member -MemberType NoteProperty -Name "sitesAndNetworks" -Value $sitesAndNetworks -Force
        }



        #if ($thisVM.RemoteSQLVM) {

        #    $sql = get-list2 -DeployConfig $deployConfig | Where-Object { $_.vmName -eq $thisVM.RemoteSQLVM }
        #    Add-VMToAccountLists -thisVM $thisVM -VM $CASPassiveVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts  -LocalAdminAccounts
        #}

        #Get the CU URL, and SQL permissions

        if ($thisVM.sqlVersion) {
            $sqlFile = $Common.AzureFileList.ISO | Where-Object { $_.id -eq $thisVM.sqlVersion }
            $sqlCUUrl = $sqlFile.cuURL
            $thisParams | Add-Member -MemberType NoteProperty -Name "sqlCUURL" -Value $sqlCUUrl -Force
            #$backupSolutionURL = "https://ola.hallengren.com/scripts/MaintenanceSolution.sql"
            $backupSolutionURL = $($Common.AzureFileList.Urls.hallengren)
            $thisParams | Add-Member -MemberType NoteProperty -Name "backupSolutionURL" -Value $backupSolutionURL -Force

            #if ($thisvm.sqlInstanceName -eq "MSSQLSERVER" ) {
            #    $thisParams | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value 1433 -Force
            #}
            #else {
            #    $thisParams | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value 2433 -Force
            #}

            $DomainAdminName = $deployConfig.vmOptions.adminName
            $DomainName = $deployConfig.vmOptions.domainName
            #$DName = $DomainName.Split(".")[0]
            $DName = $deployConfig.vmOptions.domainNetBiosName
            $cm_admin = "$DNAME\$DomainAdminName"
            $vm_admin = "$DNAME\vmbuildadmin"
            $accountLists.SQLSysAdminAccounts = @('NT AUTHORITY\SYSTEM', $cm_admin, $vm_admin, 'BUILTIN\Administrators')
            $SiteServerVM = $deployConfig.virtualMachines | Where-Object { $_.RemoteSQLVM -eq $thisVM.vmName }

            if ($SiteServerVM) {
                Add-VMToAccountLists -thisVM $thisVM -VM $SiteServerVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
            }

            if (-not $SiteServerVM) {
                $OtherNode = $deployConfig.virtualMachines | Where-Object { $_.OtherNode -eq $thisVM.vmName }

                if ($OtherNode) {
                    $SiteServerVM = $deployConfig.virtualMachines | Where-Object { $_.RemoteSQLVM -eq $OtherNode.vmName }
                }
            }

            if (-not $SiteServerVM) {
                $SiteServerVM = Get-List -Type VM -domain $deployConfig.vmOptions.DomainName | Where-Object { $_.RemoteSQLVM -eq $thisVM.vmName }
            }

            if ($SiteServerVM) {
                Add-VMToAccountLists -thisVM $thisVM -VM $SiteServerVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin

                $siteCode = $SiteServerVM.SiteCode

                $SUP = $deployConfig.virtualMachines | Where-Object { $_.InstallSUP -and $_.SiteCode -eq $siteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) } | Select-Object -first 1
                if ($SUP) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $SUP -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                }

            }

            if (-not $SiteServerVM -and $thisVM.Role -eq "Secondary") {
                $SiteServerVM = Get-PrimarySiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            }
            if (-not $SiteServerVM -and $thisVM.Role -in "Primary", "CAS") {
                $SiteServerVM = $thisVM
            }

            $sitecode = $SiteServerVM.SiteCode

            if ($siteCode) {
                $SiteSystems = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "SiteSystem" -and $_.SiteCode -eq $siteCode }
                foreach ($SiteSys in $SiteSystems) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $SiteSys -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                }
            }

            foreach ($SSVM in $SiteServerVM) {
                if ($SSVM -and $SSVM.SiteCode) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $SSVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                    $passiveNodeVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SSVM.siteCode -type VM
                    if ($passiveNodeVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $passiveNodeVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                    }

                    if ($SSVM.Role -eq "Primary") {
                        $CASVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "CAS" -and $_.SiteCode -eq $SSVM.ParentSiteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) }
                        if ($CASVM) {
                            $thisParams | Add-Member -MemberType NoteProperty -Name "CAS" -Value $CASVM.vmName -Force
                            Add-VMToAccountLists -thisVM $thisVM -VM $CASVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                            $CASPassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $CASVM.siteCode -type VM
                            if ($CASPassiveVM) {
                                Add-VMToAccountLists -thisVM $thisVM -VM $CASPassiveVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts  -LocalAdminAccounts   -WaitOnDomainJoin
                            }
                        }
                    }

                    if ($SSVM.Role -eq "CAS") {
                        $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $SSVM.siteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) }
                        if ($primaryVM) {
                            $thisParams | Add-Member -MemberType NoteProperty -Name "Primary" -Value $primaryVM.vmName -Force
                            Add-VMToAccountLists -thisVM $thisVM -VM $primaryVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                            $primaryPassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $primaryVM.siteCode -type VM
                            if ($primaryPassiveVM) {
                                Add-VMToAccountLists -thisVM $thisVM -VM $primaryPassiveVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts  -LocalAdminAccounts   -WaitOnDomainJoin
                            }
                        }
                    }
                }
            }


        }

        #Get the SiteServer this VM's SiteCode reports to.  If it has a passive node, get that as -P
        if ($thisVM.siteCode -and -not $thisVM.Hidden) {
            $SiteServerVM = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.siteCode -type VM
            $thisParams | Add-Member -MemberType NoteProperty -Name "SiteServer" -Value $SiteServerVM.vmName -Force
            Add-VMToAccountLists -thisVM $thisVM -VM $SiteServerVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
            $passiveSiteServerVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.siteCode -type VM
            if ($passiveSiteServerVM) {
                $thisParams | Add-Member -MemberType NoteProperty -Name "SiteServerPassive" -Value $passiveSiteServerVM.vmName -Force
                Add-VMToAccountLists -thisVM $thisVM -VM $passiveSiteServerVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
            }
            #If we report to a Secondary, get the Primary as well, and passive as -P
            if ((get-RoleForSitecode -ConfigTocheck $deployConfig -siteCode $thisVM.siteCode) -eq "Secondary") {
                $PrimaryServerVM = Get-PrimarySiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.SiteCode -type VM
                if ($PrimaryServerVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "PrimarySiteServer" -Value $PrimaryServerVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $PrimaryServerVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts -WaitOnDomainJoin
                    $PassivePrimaryVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -siteCode $PrimaryServerVM.SiteCode -type VM
                    if ($PassivePrimaryVM) {
                        $thisParams | Add-Member -MemberType NoteProperty -Name "PrimarySiteServerPassive" -Value $PassivePrimaryVM.vmName -Force
                        Add-VMToAccountLists -thisVM $thisVM -VM $PassivePrimaryVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    }

                }
            }
        }
        #Get the VM Name of the Parent Site Code Site Server
        if ($thisVM.parentSiteCode -and -not $thisVM.Hidden) {
            $parentSiteServerVM = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            $thisParams | Add-Member -MemberType NoteProperty -Name "ParentSiteServer" -Value $parentSiteServerVM.vmName -Force
            $passiveSiteServerVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            if ($passiveSiteServerVM) {
                $thisParams | Add-Member -MemberType NoteProperty -Name "ParentSiteServerPassive" -Value $passiveSiteServerVM.vmName -Force
            }
        }

        #If we have a passive server for a site server, record it here, only check config, as it couldnt already exist
        if ($thisVM.role -in "CAS", "Primary") {
            $passiveVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" -and $_.SiteCode -eq $thisVM.siteCode -and (-not $_.Domain -or $_.Domain -eq $DomainName) }
            if ($passiveVM) {
                $thisParams | Add-Member -MemberType NoteProperty -Name "PassiveNode" -Value $passiveVM.vmName -Force
                Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
            }
        }


        $SQLSysAdminAccounts = $accountLists.SQLSysAdminAccounts | Sort-Object | Get-Unique
        if ($SQLSysAdminAccounts.Count -gt 0) {
            $thisParams | Add-Member -MemberType NoteProperty -Name "SQLSysAdminAccounts" -Value $SQLSysAdminAccounts -Force
        }

        $WaitOnDomainJoin = $accountLists.WaitOnDomainJoin | Sort-Object | Get-Unique
        if ($WaitOnDomainJoin.Count -gt 0) {
            $thisParams | Add-Member -MemberType NoteProperty -Name "WaitOnDomainJoin" -Value $WaitOnDomainJoin -Force
        }

        $LocalAdminAccounts = @()
        $LocalAdminAccounts += $accountLists.LocalAdminAccounts | Sort-Object | Get-Unique
        if ($LocalAdminAccounts.Count -gt 0) {
            $thisParams | Add-Member -MemberType NoteProperty -Name "LocalAdminAccounts" -Value $LocalAdminAccounts -Force
        }
        if ($thisVM.role -in "DC") {
            $thisParams | Add-Member -MemberType NoteProperty -Name "DomainAccounts" -Value $accountLists.DomainAccounts -Force
            $thisParams | Add-Member -MemberType NoteProperty -Name "DomainAdmins" -Value $accountLists.DomainAdmins -Force
            $thisParams | Add-Member -MemberType NoteProperty -Name "SchemaAdmins" -Value $accountLists.SchemaAdmins -Force
        }

        #    $thisParams | ConvertTo-Json -Depth 5 | out-Host

        $thisVM | Add-Member -MemberType NoteProperty -Name "thisParams" -Value $thisParams -Force
    }


    $IPAddresses = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
    if ($Common.CorpNetInterfaceIndex) {
        $hostDnsServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $Common.CorpNetInterfaceIndex).ServerAddresses
        $IPAddresses = $hostDnsServers #+ $IPAddresses
    }

    $deployConfigEx | Add-Member -MemberType NoteProperty -name "DNSForwarders" -Value $IPAddresses -Force
    # Add Apps
    $deployConfigEx | Add-Member -MemberType NoteProperty -name "Tools" -Value $Common.AzureFileList.Tools -Force
    $deployConfigEx | Add-Member -MemberType NoteProperty -name "URLS" -Value $Common.AzureFileList.Urls -Force

    return $deployConfigEx
}



function Set-RdcManMin {

    $TypeDef = @"

using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Api
{

 public class WinStruct
 {
   public string WinTitle {get; set; }
   public int WinHwnd { get; set; }
 }

 public class ApiDef
 {
   private delegate bool CallBackPtr(int hwnd, int lParam);
   private static CallBackPtr callBackPtr = Callback;
   private static List<WinStruct> _WinStructList = new List<WinStruct>();

   [DllImport("User32.dll")]
   [return: MarshalAs(UnmanagedType.Bool)]
   private static extern bool EnumWindows(CallBackPtr lpEnumFunc, IntPtr lParam);

   [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
   static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

   private static bool Callback(int hWnd, int lparam)
   {
       StringBuilder sb = new StringBuilder(256);
       int res = GetWindowText((IntPtr)hWnd, sb, 256);
      _WinStructList.Add(new WinStruct { WinHwnd = hWnd, WinTitle = sb.ToString() });
       return true;
   }

   public static List<WinStruct> GetWindows()
   {
      _WinStructList = new List<WinStruct>();
      EnumWindows(callBackPtr, IntPtr.Zero);
      return _WinStructList;
   }

 }
}
"@
    try {
        Add-Type -TypeDefinition $TypeDef -ErrorAction SilentlyContinue
    }
    catch {}

    $Win32ShowWindowAsync = Add-Type -memberDefinition @"
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
"@ -name "Win32ShowWindowAsync" -namespace Win32Functions -passThru

    $wnd = [Api.Apidef]::GetWindows() | Where-Object { $_.WinTitle -like "memlabs - Remote Desktop Connection Manager*" }

    foreach ($window in $wnd) {
        $Win32ShowWindowAsync::ShowWindowAsync($window.WinHwnd, 6) | Out-Null
    }
}

