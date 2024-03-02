Function Get-SupportedOperatingSystemsForRole {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "role")]
        [string] $role
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
        "SQLAO" { return $ServerList }
        "SiteSystem" { return $ServerList }
        "DomainMember" { return $AllList }
        "DomainMember (Server)" { return $ServerList }
        "DomainMember (Client)" { return $ClientList }
        "WorkgroupMember" { return $AllList }
        "InternetClient" { return $ClientList }
        "AADClient" { return $ClientList }
        "OSDClient" { return $null }
        default {
            return $AllList
        }
    }
    return $AllList
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
    if (-not $AllowEscape) {
        if ($return) {
            Write-Host2 -ForegroundColor $color "Press " -NoNewline
            Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Enter]" -NoNewline
            Write-Host2 -ForegroundColor $color " to return to the previous menu or " -NoNewline
            Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
            Write-Host2 -ForegroundColor $color " to exit without saving."
        }
        else {
            Write-Host2 -ForegroundColor $color "Select an option or " -NoNewline
            Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
            Write-Host2 -ForegroundColor $color " to exit without saving."
        }
    }
    else {
        if ($return) {
            Write-Host2 -ForegroundColor $color "Press " -NoNewline
            Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Enter]" -NoNewline
            Write-Host2 -ForegroundColor $color " to return to the previous menu or " -NoNewline
            Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
            Write-Host2 -ForegroundColor $color " to exit without saving."
        }
        else {
            Write-Host2 -ForegroundColor $color "Press " -NoNewline
            Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Enter]" -NoNewline
            Write-Host2 -ForegroundColor $color " to skip this section or " -NoNewline
            Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigHelpHighlight "[Ctrl-C]" -NoNewline
            Write-Host2 -ForegroundColor $color " to exit without saving."
        }
    }
}

function Read-YesorNoWithTimeout {
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
            write-help -AllowEscape -timeout:$timeoutHelp
        }
        else {
            write-help -timeout:$timeoutHelp
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


function Invoke-AutoSnapShotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain,
        [Parameter(Mandatory = $true, HelpMessage = "Snapshot name (Must Contain MemLabs)")]
        [string] $comment
    )

    #Get Critical Server list.  These VM's should be stopped before snapshot
    $critlist = Get-CriticalVMs -domain $deployConfig.vmOptions.domainName -vmNames $nodes

    #Stop all VMs in Domain
    Invoke-StopVMs -domain $domain -quiet:$true

    #Take Snapshot
    $failures = Invoke-SnapshotDomain -domain $domain -comment $comment -quiet:$true
    if ($failures -ne 0) {
        write-log "$failures VM(s) could not be snapshotted" -Failure
    }

    #Start VMs in correct order
    $failures = Invoke-SmartStartVMs -CritList $critlist
    if ($failures -ne 0) {
        write-log "$failures VM(s) could not be started" -Failure
    }
}

function Invoke-SnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "Comment")]
        [string] $comment = "",
        [Parameter(Mandatory = $false, HelpMessage = "Quiet Mode")]
        [bool] $quiet = $false
    )



    $vms = get-list -type vm -DomainName $domain

    $date = Get-Date -Format "yyyy-MM-dd hh.mmtt"
    $snapshot = $date + " (MemLabs) " + $comment

    $failures = 0
    if (-not $quiet) {
        Write-Log "Snapshotting Virtual Machines in '$domain'" -Activity
        Write-Log "Domain $domain has $(($vms | Measure-Object).Count) resources"
    }
    foreach ($vm in $vms) {
        $complete = $false
        $tries = 0
        While ($complete -ne $true) {
            try {
                if ($tries -gt 10) {
                    $failures++
                    return $failures
                }
                if (-not $quiet) {
                    Show-StatusEraseLine "Checkpointing $($vm.VmName) to [$($snapshot)]" -indent
                }

                Checkpoint-VM2 -Name $vm.VmName -SnapshotName $snapshot -ErrorAction Stop
                $complete = $true
                if (-not $quiet) {
                    Write-GreenCheck "Checkpoint $($vm.VmName) to [$($snapshot)] Complete"
                }
            }
            catch {
                Write-RedX "Checkpoint $($vm.VmName) to [$($snapshot)] Failed. Retrying. See Logs for error."
                write-log "Error: $_" -LogOnly
                $tries++
                stop-vm2 -name $vm.VmName
                Start-Sleep 10
            }
        }
    }
    return $failures
}

function Get-CriticalVMs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "VMs to bucketize, names only")]
        [string[]] $vmNames = $null
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

    if ($vmNames) {
        $allvms += get-list -type vm -SmartUpdate
    }
    else {
        $allvms += get-list -type vm -DomainName $domain -SmartUpdate
    }

    $vms = @()
    if ($vmNames) {
        foreach ($vm in $vmNames) {
            $vms += $allvms | Where-Object { $_.vmName -eq $vm }
        }
    }
    else {
        $vms += $allvms
    }


    $return.dc += $vms | Where-Object { $_.Role -eq "DC" }
    $return.ALLCRIT += $vms | Where-Object { $_.Role -eq "DC" }
    $vms = $vms | Where-Object { $_.Role -ne "DC" }

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
        [Parameter(Mandatory = $true, HelpMessage = "Vms To Start, from Get-CriticalVMs")]
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
    foreach ($vm in $vmList) {
        if ($vm.State -eq "Running") {
            $vm2 = Get-VM2 -Name $vm.vmName -ErrorAction SilentlyContinue
            if (-not $quiet) {
                Write-GreenCheck "$($vm.vmName) is [$($vm2.State)]. Shutting down VM. Will forcefully stop after 5 mins"
            }
            stop-vm -VM $VM2 -force -AsJob | Out-Null
        }
    }

    Show-JobsProgress -Activity "Stopping VMs"

    try {
        get-job | remove-job | Out-Null
    }
    catch {}
    get-list -type VM -SmartUpdate | out-null
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
                $ODC = Get-list -Type VM | Where-Object {$_.vmName -eq $thisVm.VmName }
                $thisParams | Add-Member -MemberType NoteProperty -Name "Domain" -Value $ODC.domain
                $ODCIP = $ODC.network -replace "\d{1,3}$","1"

                $thisParams | Add-Member -MemberType NoteProperty -Name "IPAddr" -Value $ODCIP
            }
            "DC" {
                $DomainAccountsUPN = @()
                $DomainComputers = @()
                if ($SQLAO) {
                    foreach ($sql in $SQLAO) {
                        if ($sql.OtherNode) {

                            $ClusterName = $sql.ClusterName

                            $DomainAccountsUPN += @($sql.SqlServiceAccount, $sql.SqlAgentAccount)

                            $DomainComputers += @($ClusterName)
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

                #$accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.domainUser } | Select-Object -ExpandProperty domainUser -Unique
                #$accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.SQLAgentAccount } | Select-Object -ExpandProperty SQLAgentAccount -Unique
                #$accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.SqlServiceAccount } | Select-Object -ExpandProperty SqlServiceAccount -Unique
                #$accountLists.DomainAccounts = $accountLists.DomainAccounts | Select-Object -Unique

                $ServersToWaitOn = @()
                $thisPSName = $null
                $thisCSName = $null
                foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in "Primary", "Secondary", "CAS", "PassiveSite", "SQLAO" -and -not $_.hidden }) {
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
                        $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $ActiveVM.siteCode }
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
                $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $thisVM.siteCode }
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
                $reportingSecondaries = @()
                $reportingSecondaries += ($deployConfig.virtualMachines | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $thisVM.siteCode }).siteCode
                $reportingSecondaries += (get-list -type vm -domain $deployConfig.vmOptions.domainName | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $thisVM.siteCode }).siteCode
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
                $CASVM = $deployConfig.virtualMachines | Where-Object { $_.role -in "CAS" -and $thisVM.ParentSiteCode -eq $_.SiteCode }
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

                $ClientNames = get-list2 -DeployConfig $deployConfig | Where-Object { $_.role -eq "DomainMember" -and -not ($_.SqlVersion) }
                $clientPush = @()
                $clientPush += ($ClientNames | Where-Object { $_.network -eq $thisVMNetwork }).vmName


                $Secondaries = get-list2 -deployConfig $deployConfig | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $thisVM.siteCode }
                foreach ($second in $Secondaries) {
                    $clientPush += ($ClientNames | Where-Object { $_.network -eq $second.network }).vmName
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
            $backupSolutionURL = "https://ola.hallengren.com/scripts/MaintenanceSolution.sql"
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
            }
            if (-not $SiteServerVM -and $thisVM.Role -eq "Secondary") {
                $SiteServerVM = Get-PrimarySiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            }
            if (-not $SiteServerVM -and $thisVM.Role -in "Primary", "CAS") {
                $SiteServerVM = $thisVM
            }

            foreach ($SSVM in $SiteServerVM) {
                if ($SSVM -and $SSVM.SiteCode) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $SSVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                    $passiveNodeVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SSVM.siteCode -type VM
                    if ($passiveNodeVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $passiveNodeVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                    }

                    if ($SSVM.Role -eq "Primary") {
                        $CASVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "CAS" -and $_.SiteCode -eq $SSVM.ParentSiteCode }
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
                        $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $SSVM.siteCode }
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
        if ($thisVM.siteCode) {
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
        if ($thisVM.parentSiteCode) {
            $parentSiteServerVM = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            $thisParams | Add-Member -MemberType NoteProperty -Name "ParentSiteServer" -Value $parentSiteServerVM.vmName -Force
            $passiveSiteServerVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            if ($passiveSiteServerVM) {
                $thisParams | Add-Member -MemberType NoteProperty -Name "ParentSiteServerPassive" -Value $passiveSiteServerVM.vmName -Force
            }
        }

        #If we have a passive server for a site server, record it here, only check config, as it couldnt already exist
        if ($thisVM.role -in "CAS", "Primary") {
            $passiveVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" -and $_.SiteCode -eq $thisVM.siteCode }
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

